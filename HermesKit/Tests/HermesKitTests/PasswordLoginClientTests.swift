import Foundation
import Testing

@testable import HermesKit

/// Exercises `rest.passwordLogin` over the process-global `MockURLProtocol` stub, so it
/// joins the serialized `RESTTransportSuite` to avoid clobbering other client tests.
extension RESTTransportSuite {
struct PasswordLoginClientTests {
  private let baseURL = URL(string: "http://test.local:9119")!

  private func makeClient() -> HermesRESTClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return .live(session: URLSession(configuration: config))
  }

  /// Read the (possibly streamed) request body back as `Data`.
  private func bodyData(_ req: URLRequest) -> Data {
    req.httpBody ?? req.httpBodyStream.map { stream -> Data in
      stream.open()
      defer { stream.close() }
      var data = Data()
      let bufSize = 1024
      let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
      defer { buffer.deallocate() }
      while stream.hasBytesAvailable {
        let read = stream.read(buffer, maxLength: bufSize)
        if read <= 0 { break }
        data.append(buffer, count: read)
      }
      return data
    } ?? Data()
  }

  @Test func postsToEndpointWithJSONBody() async throws {
    MockURLProtocol.set(json: #"{"ok":true,"next":"/"}"#)
    _ = try await makeClient().passwordLogin(baseURL, "basic", "alice", "hunter2")
    let req = try #require(MockURLProtocol.lastRequest)
    #expect(req.httpMethod == "POST")
    #expect(req.url?.path == "/auth/password-login")
    #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
    let json = try JSONSerialization.jsonObject(with: bodyData(req)) as? [String: String]
    #expect(json == ["provider": "basic", "username": "alice", "password": "hunter2"])
  }

  @Test func captures200SetCookieIntoSession() async throws {
    MockURLProtocol.set(
      status: 200,
      json: #"{"ok":true,"next":"/"}"#,
      headers: [
        "Set-Cookie": "hermes_session_at=ACCESS; Path=/; HttpOnly, hermes_session_rt=REFRESH; Path=/; HttpOnly",
      ]
    )
    let session = try await makeClient().passwordLogin(baseURL, "basic", "alice", "hunter2")
    #expect(session.username == "alice")
    #expect(session.provider == "basic")
    let byName = Dictionary(uniqueKeysWithValues: session.cookies.map { ($0.name, $0.value) })
    #expect(byName["hermes_session_at"] == "ACCESS")
    #expect(byName["hermes_session_rt"] == "REFRESH")
  }

  @Test func successWithNoCookiesStillReturnsSession() async throws {
    // Defensive: a 200 with no Set-Cookie yields an empty jar (UI/persistence handle it).
    MockURLProtocol.set(status: 200, json: #"{"ok":true}"#)
    let session = try await makeClient().passwordLogin(baseURL, "basic", "alice", "pw")
    #expect(session.cookies.isEmpty)
    #expect(session.username == "alice")
  }

  @Test func invalidCredentialsMapsToUnauthorized() async throws {
    MockURLProtocol.set(status: 401, json: #"{"detail":"Invalid credentials"}"#)
    await #expect(throws: RESTError.unauthorized) {
      _ = try await makeClient().passwordLogin(baseURL, "basic", "alice", "wrong")
    }
  }

  @Test func unknownProviderMapsToNotFound() async throws {
    MockURLProtocol.set(status: 404, json: #"{"detail":"Unknown provider"}"#)
    await #expect(throws: RESTError.notFound) {
      _ = try await makeClient().passwordLogin(baseURL, "nope", "alice", "pw")
    }
  }

  @Test func rateLimitedMapsToRateLimited() async throws {
    MockURLProtocol.set(status: 429, json: #"{"detail":"Too many login attempts."}"#)
    await #expect(throws: RESTError.rateLimited) {
      _ = try await makeClient().passwordLogin(baseURL, "basic", "alice", "pw")
    }
  }

  @Test func providerUnreachableMapsToServiceUnavailable() async throws {
    MockURLProtocol.set(status: 503, json: #"{"detail":"Provider unreachable"}"#)
    await #expect(throws: RESTError.serviceUnavailable) {
      _ = try await makeClient().passwordLogin(baseURL, "basic", "alice", "pw")
    }
  }

  @Test func transportFailureMapsToUnreachable() async throws {
    MockURLProtocol.set(fail: true)
    await #expect(throws: RESTError.unreachable) {
      _ = try await makeClient().passwordLogin(baseURL, "basic", "alice", "pw")
    }
  }

  /// The login path shares the same transport mapping as the other helpers (#62).
  @Test func offlineTransportFailureMapsToOffline() async throws {
    MockURLProtocol.set(fail: true, failCode: .notConnectedToInternet)
    await #expect(throws: RESTError.offline) {
      _ = try await makeClient().passwordLogin(baseURL, "basic", "alice", "pw")
    }
  }
}
} // extension RESTTransportSuite
