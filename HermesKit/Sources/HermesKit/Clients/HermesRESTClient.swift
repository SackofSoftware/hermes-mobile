import ComposableArchitecture
import DependenciesMacros
import Foundation

// MARK: - Connection & status

/// Where and how to reach a Hermes server. `token` is nil for the unauthenticated
/// reachability probe (`/api/status`).
public struct ServerConnection: Equatable, Sendable {
  public var baseURL: URL
  public var token: String?

  public init(baseURL: URL, token: String? = nil) {
    self.baseURL = baseURL
    self.token = token
  }
}

public enum SessionOrder: String, Sendable {
  case created
  case recent
}

/// Subset of `/api/status` we use for the reachability/health check (lenient).
public struct ServerStatus: Equatable, Sendable, Decodable {
  public var version: String?
  public var gatewayRunning: Bool?
  public var gatewayState: String?
  public var activeSessions: Int?

  enum CodingKeys: String, CodingKey {
    case version
    case gatewayRunning = "gateway_running"
    case gatewayState = "gateway_state"
    case activeSessions = "active_sessions"
  }
}

public enum RESTError: Error, Equatable, Sendable {
  case unauthorized          // 401 — token missing/invalid
  case notFound              // 404
  case server(status: Int)   // other non-2xx
  case unreachable           // transport failure / non-HTTP response
  case decoding              // 2xx body didn't match the expected shape

  public var message: String {
    switch self {
    case .unauthorized: "Invalid or missing token."
    case .notFound: "Not found."
    case let .server(status): "Server error (\(status))."
    case .unreachable: "Couldn’t reach the server."
    case .decoding: "Unexpected response — is this a Hermes server?"
    }
  }
}

// MARK: - Client

@DependencyClient
public struct HermesRESTClient: Sendable {
  /// Unauthenticated reachability/health probe.
  public var status: @Sendable (_ baseURL: URL) async throws -> ServerStatus
  public var sessions: @Sendable (_ connection: ServerConnection, _ limit: Int, _ offset: Int, _ order: SessionOrder) async throws -> [Session]
  public var search: @Sendable (_ connection: ServerConnection, _ query: String) async throws -> [Session]
  public var messages: @Sendable (_ connection: ServerConnection, _ sessionID: String) async throws -> [SessionMessage]
  /// Soft-hide (archive) or restore a session — `PATCH /api/sessions/{id}` `{"archived":…}`.
  public var archive: @Sendable (_ connection: ServerConnection, _ id: String, _ archived: Bool) async throws -> Void
}

public extension HermesRESTClient {
  /// Live implementation over `URLSession`. The session is injectable so tests can
  /// supply a `URLProtocol` mock.
  static func live(session: URLSession = .shared) -> HermesRESTClient {
    HermesRESTClient(
      status: { baseURL in
        try await get(makeURL(baseURL, "/api/status"), token: nil, session: session)
      },
      sessions: { conn, limit, offset, order in
        let url = try makeURL(conn.baseURL, "/api/sessions", query: [
          .init(name: "limit", value: String(limit)),
          .init(name: "offset", value: String(offset)),
          .init(name: "order", value: order.rawValue),
        ])
        let response: SessionsResponse = try await get(url, token: conn.token, session: session)
        return response.sessions.map(\.asSession)
      },
      search: { conn, query in
        let url = try makeURL(conn.baseURL, "/api/sessions/search", query: [.init(name: "q", value: query)])
        let response: SearchResponse = try await get(url, token: conn.token, session: session)
        return response.results.map(\.asSession)
      },
      messages: { conn, sessionID in
        let url = try makeURL(conn.baseURL, "/api/sessions/\(sessionID)/messages")
        let response: MessagesResponse = try await get(url, token: conn.token, session: session)
        return response.messages
      },
      archive: { conn, id, archived in
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        let url = try makeURL(conn.baseURL, "/api/sessions/\(encoded)")
        let body = try JSONSerialization.data(withJSONObject: ["archived": archived])
        try await send(url, method: "PATCH", body: body, token: conn.token, session: session)
      }
    )
  }
}

extension HermesRESTClient: DependencyKey {
  public static var liveValue: HermesRESTClient { .live() }
  // Unimplemented by default — REST calls in tests must be stubbed explicitly.
  public static var testValue: HermesRESTClient { HermesRESTClient() }
}

public extension DependencyValues {
  var hermesREST: HermesRESTClient {
    get { self[HermesRESTClient.self] }
    set { self[HermesRESTClient.self] = newValue }
  }
}

// MARK: - Transport helpers

private func makeURL(_ base: URL, _ path: String, query: [URLQueryItem] = []) throws -> URL {
  guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
    throw RESTError.unreachable
  }
  comps.path = path
  comps.queryItems = query.isEmpty ? nil : query
  guard let url = comps.url else { throw RESTError.unreachable }
  return url
}

private func get<T: Decodable>(_ url: URL, token: String?, session: URLSession) async throws -> T {
  var request = URLRequest(url: url)
  if let token { request.setValue(token, forHTTPHeaderField: "X-Hermes-Session-Token") }

  let data: Data
  let response: URLResponse
  do {
    (data, response) = try await session.data(for: request)
  } catch {
    throw RESTError.unreachable
  }

  guard let http = response as? HTTPURLResponse else { throw RESTError.unreachable }
  switch http.statusCode {
  case 200..<300: break
  case 401: throw RESTError.unauthorized
  case 404: throw RESTError.notFound
  default: throw RESTError.server(status: http.statusCode)
  }

  do {
    return try JSONDecoder().decode(T.self, from: data)
  } catch {
    throw RESTError.decoding
  }
}

/// Fire a write request (e.g. PATCH) and validate the status, discarding the body.
private func send(
  _ url: URL, method: String, body: Data?, token: String?, session: URLSession
) async throws {
  var request = URLRequest(url: url)
  request.httpMethod = method
  if let body {
    request.httpBody = body
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
  }
  if let token { request.setValue(token, forHTTPHeaderField: "X-Hermes-Session-Token") }

  let response: URLResponse
  do {
    (_, response) = try await session.data(for: request)
  } catch {
    throw RESTError.unreachable
  }

  guard let http = response as? HTTPURLResponse else { throw RESTError.unreachable }
  switch http.statusCode {
  case 200..<300: break
  case 401: throw RESTError.unauthorized
  case 404: throw RESTError.notFound
  default: throw RESTError.server(status: http.statusCode)
  }
}

// MARK: - DTOs (verified against hermes_cli/web_server.py + hermes_state.py)

private struct SessionsResponse: Decodable {
  let sessions: [SessionListDTO]
  let total: Int?
}

private struct SessionListDTO: Decodable {
  let id: String
  let title: String?
  let preview: String?
  let lastActive: Double?
  let startedAt: Double?
  let messageCount: Int?
  let cwd: String?
  let isActive: Bool?

  enum CodingKeys: String, CodingKey {
    case id, title, preview, cwd
    case lastActive = "last_active"
    case startedAt = "started_at"
    case messageCount = "message_count"
    case isActive = "is_active"
  }

  var asSession: Session {
    Session(
      id: id,
      title: title?.nonEmpty,
      updatedAt: (lastActive ?? startedAt).map { Date(timeIntervalSince1970: $0) },
      preview: preview?.nonEmpty,
      cwd: cwd?.nonEmpty,
      startedAt: startedAt.map { Date(timeIntervalSince1970: $0) },
      messageCount: messageCount,
      isActive: isActive
    )
  }
}

private struct SearchResponse: Decodable {
  let results: [SearchResultDTO]
}

/// Search results carry a `snippet`, not a `title` (different shape from the list).
private struct SearchResultDTO: Decodable {
  let sessionID: String
  let snippet: String?
  let sessionStarted: Double?

  enum CodingKeys: String, CodingKey {
    case sessionID = "session_id"
    case snippet
    case sessionStarted = "session_started"
  }

  var asSession: Session {
    Session(
      id: sessionID,
      title: nil,
      updatedAt: sessionStarted.map { Date(timeIntervalSince1970: $0) },
      preview: snippet?.nonEmpty
    )
  }
}

private struct MessagesResponse: Decodable {
  let messages: [SessionMessage]
}
