import Foundation
import Testing

@testable import HermesKit

/// A `URLProtocol` stub so REST tests run fully offline. Serialized because the stub
/// state is process-global.
final class MockURLProtocol: URLProtocol {
  struct Stub: Sendable {
    var statusCode = 200
    var body = Data()
    var failWithError = false
  }

  nonisolated(unsafe) static var stub = Stub()
  nonisolated(unsafe) static var lastRequest: URLRequest?

  static func set(status: Int = 200, json: String = "", fail: Bool = false) {
    stub = Stub(statusCode: status, body: Data(json.utf8), failWithError: fail)
    lastRequest = nil
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() {}

  override func startLoading() {
    MockURLProtocol.lastRequest = request
    if MockURLProtocol.stub.failWithError {
      client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
      return
    }
    let http = HTTPURLResponse(
      url: request.url!, statusCode: MockURLProtocol.stub.statusCode,
      httpVersion: nil, headerFields: nil
    )!
    client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: MockURLProtocol.stub.body)
    client?.urlProtocolDidFinishLoading(self)
  }
}

@Suite(.serialized)
struct HermesRESTClientTests {
  private let baseURL = URL(string: "http://test.local:9119")!
  private var connection: ServerConnection { ServerConnection(baseURL: baseURL, token: "tok") }

  private func makeClient() -> HermesRESTClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return .live(session: URLSession(configuration: config))
  }

  @Test func statusDecodes() async throws {
    MockURLProtocol.set(json: #"{"version":"0.16.0","gateway_running":true,"gateway_state":"running","active_sessions":2}"#)
    let status = try await makeClient().status(baseURL)
    #expect(status.version == "0.16.0")
    #expect(status.gatewayRunning == true)
    #expect(status.activeSessions == 2)
  }

  @Test func statusProbeSendsNoToken() async throws {
    MockURLProtocol.set(json: #"{"version":"0.16.0"}"#)
    _ = try await makeClient().status(baseURL)
    #expect(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "X-Hermes-Session-Token") == nil)
    #expect(MockURLProtocol.lastRequest?.url?.path == "/api/status")
  }

  @Test func sessionsMapsListToDomain() async throws {
    MockURLProtocol.set(json: #"""
    {"sessions":[{"id":"20260610_120231_afcca6","title":"My chat","preview":"hello there","last_active":1749556800.0,"started_at":1749550000.0,"message_count":4,"is_active":true,"archived":false}],"total":1,"limit":20,"offset":0}
    """#)
    let sessions = try await makeClient().sessions(connection, 20, 0, .recent)
    #expect(sessions.count == 1)
    let s = try #require(sessions.first)
    #expect(s.id == "20260610_120231_afcca6")
    #expect(s.title == "My chat")
    #expect(s.preview == "hello there")
    #expect(s.updatedAt == Date(timeIntervalSince1970: 1749556800.0))
  }

  @Test func sessionsAttachesSessionTokenHeaderAndQuery() async throws {
    MockURLProtocol.set(json: #"{"sessions":[],"total":0}"#)
    _ = try await makeClient().sessions(connection, 20, 0, .recent)
    let req = try #require(MockURLProtocol.lastRequest)
    #expect(req.value(forHTTPHeaderField: "X-Hermes-Session-Token") == "tok")
    #expect(req.url?.path == "/api/sessions")
    let query = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
    #expect(query.contains(URLQueryItem(name: "order", value: "recent")))
    #expect(query.contains(URLQueryItem(name: "limit", value: "20")))
  }

  @Test func searchMapsSnippetToPreviewWithNoTitle() async throws {
    MockURLProtocol.set(json: #"""
    {"results":[{"session_id":"20260610_120231_afcca6","snippet":"matched text","role":"user","model":"gpt-5.5","session_started":1749550000.0}]}
    """#)
    let results = try await makeClient().search(connection, "matched")
    let s = try #require(results.first)
    #expect(s.id == "20260610_120231_afcca6")
    #expect(s.title == nil)
    #expect(s.preview == "matched text")
    #expect(s.updatedAt == Date(timeIntervalSince1970: 1749550000.0))
  }

  @Test func messagesDecodes() async throws {
    MockURLProtocol.set(json: #"""
    {"session_id":"sid","messages":[{"id":1,"role":"user","content":"hi","timestamp":1749550000.0},{"id":2,"role":"assistant","content":"hello","timestamp":1749550001.0,"tool_name":null}]}
    """#)
    let messages = try await makeClient().messages(connection, "sid")
    #expect(messages.count == 2)
    #expect(messages.first == SessionMessage(id: 1, role: "user", content: "hi", timestamp: 1749550000.0))
  }

  @Test func unauthorizedMapsToTypedError() async throws {
    MockURLProtocol.set(status: 401, json: #"{"detail":"Unauthorized"}"#)
    await #expect(throws: RESTError.unauthorized) {
      _ = try await makeClient().sessions(connection, 20, 0, .recent)
    }
  }

  @Test func transportFailureMapsToUnreachable() async throws {
    MockURLProtocol.set(fail: true)
    await #expect(throws: RESTError.unreachable) {
      _ = try await makeClient().status(baseURL)
    }
  }

  @Test func malformedBodyMapsToDecodingError() async throws {
    MockURLProtocol.set(json: "not json")
    await #expect(throws: RESTError.decoding) {
      _ = try await makeClient().status(baseURL)
    }
  }
}

@Suite struct KeychainClientTests {
  @Test func inMemoryRoundTrip() throws {
    let kc = KeychainClient.inMemory()
    #expect(kc.loadToken() == nil)
    try kc.saveToken("abc")
    #expect(kc.loadToken() == "abc")
    try kc.saveToken("def") // overwrite
    #expect(kc.loadToken() == "def")
    try kc.deleteToken()
    #expect(kc.loadToken() == nil)
  }
}
