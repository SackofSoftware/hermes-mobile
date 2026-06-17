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
  /// Other non-2xx. `detail` carries the server's body verbatim when present (JSON
  /// `{"detail": …}`, else trimmed plain-text body) so callers can surface it.
  case server(status: Int, detail: String? = nil)
  case unreachable           // transport failure / non-HTTP response
  case decoding              // 2xx body didn't match the expected shape
  case transcriptionFailed(String) // 2xx but `{ok:false}` — carries the server's reason

  public var message: String {
    switch self {
    case .unauthorized: "Invalid or missing token."
    case .notFound: "Not found."
    // Prefer the server's detail verbatim (e.g. an Add-profile 400 reason); fall back
    // to the generic status message when the body was empty/unparseable.
    case let .server(status, detail):
      if let detail, !detail.isEmpty { detail } else { "Server error (\(status))." }
    case .unreachable: "Couldn’t reach the server."
    case .decoding: "Unexpected response — is this a Hermes server?"
    case let .transcriptionFailed(reason): reason.isEmpty ? "Couldn’t transcribe the audio." : reason
    }
  }
}

// MARK: - Client

@DependencyClient
public struct HermesRESTClient: Sendable {
  /// Unauthenticated reachability/health probe.
  public var status: @Sendable (_ baseURL: URL) async throws -> ServerStatus
  public var sessions: @Sendable (_ connection: ServerConnection, _ limit: Int, _ offset: Int, _ order: SessionOrder) async throws -> [Session]
  /// Just the archived (soft-hidden) sessions — `GET /api/sessions?archived=only`.
  public var archivedSessions: @Sendable (_ connection: ServerConnection, _ limit: Int, _ offset: Int) async throws -> [Session]
  public var search: @Sendable (_ connection: ServerConnection, _ query: String) async throws -> [Session]
  /// Fetch a session's message history. Pass `profile` (non-default) to scope the read to
  /// that profile's `state.db`; `nil` → today's exact request (no `profile` param).
  public var messages: @Sendable (_ connection: ServerConnection, _ sessionID: String, _ profile: String?) async throws -> [SessionMessage]
  /// Soft-hide (archive) or restore a session — `PATCH /api/sessions/{id}` `{"archived":…}`.
  /// Pass `profile` (non-default) to scope to that profile (added to both query and body);
  /// `nil` → today's exact request.
  public var archive: @Sendable (_ connection: ServerConnection, _ id: String, _ archived: Bool, _ profile: String?) async throws -> Void
  /// Rename a session — `PATCH /api/sessions/{id}` `{"title":…}`. An empty title clears it.
  /// The server may reject with 400 (too long / invalid chars / duplicate).
  /// Pass `profile` (non-default) to scope to that profile (added to both query and body);
  /// `nil` → today's exact request.
  public var rename: @Sendable (_ connection: ServerConnection, _ id: String, _ title: String, _ profile: String?) async throws -> Void
  /// Transcribe recorded audio — `POST /api/audio/transcribe` `{data_url, mime_type?}` →
  /// `{ok, transcript}`. Returns the transcript text; throws `.transcriptionFailed` on `ok:false`.
  public var transcribe: @Sendable (_ connection: ServerConnection, _ dataURL: String, _ mimeType: String?) async throws -> String
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
      archivedSessions: { conn, limit, offset in
        let url = try makeURL(conn.baseURL, "/api/sessions", query: [
          .init(name: "limit", value: String(limit)),
          .init(name: "offset", value: String(offset)),
          .init(name: "order", value: SessionOrder.recent.rawValue),
          .init(name: "archived", value: "only"),
        ])
        let response: SessionsResponse = try await get(url, token: conn.token, session: session)
        return response.sessions.map(\.asSession)
      },
      search: { conn, query in
        let url = try makeURL(conn.baseURL, "/api/sessions/search", query: [.init(name: "q", value: query)])
        let response: SearchResponse = try await get(url, token: conn.token, session: session)
        return response.results.map(\.asSession)
      },
      messages: { conn, sessionID, profile in
        // `nil` profile → no query item, byte-identical to today's request.
        let query = profile.map { [URLQueryItem(name: "profile", value: $0)] } ?? []
        let url = try makeURL(conn.baseURL, "/api/sessions/\(sessionID)/messages", query: query)
        let response: MessagesResponse = try await get(url, token: conn.token, session: session)
        return response.messages
      },
      archive: { conn, id, archived, profile in
        // `makeURL` percent-encodes `comps.path`, so interpolate the RAW id (matching
        // the `messages` endpoint) — pre-encoding here would double-encode reserved chars.
        // A non-nil profile is mirrored into both the query and the body (matches desktop);
        // `nil` → no `profile` anywhere, byte-identical to today's request.
        let query = profile.map { [URLQueryItem(name: "profile", value: $0)] } ?? []
        let url = try makeURL(conn.baseURL, "/api/sessions/\(id)", query: query)
        var payload: [String: Any] = ["archived": archived]
        if let profile { payload["profile"] = profile }
        let body = try JSONSerialization.data(withJSONObject: payload)
        try await send(url, method: "PATCH", body: body, token: conn.token, session: session)
      },
      rename: { conn, id, title, profile in
        // Same endpoint/shape as `archive`: interpolate the RAW id (`makeURL` percent-encodes
        // the path), send `{"title": …}` — an empty string clears the title server-side.
        // A non-nil profile is mirrored into both the query and the body (matches desktop);
        // `nil` → no `profile` anywhere, byte-identical to today's request.
        let query = profile.map { [URLQueryItem(name: "profile", value: $0)] } ?? []
        let url = try makeURL(conn.baseURL, "/api/sessions/\(id)", query: query)
        var payload: [String: Any] = ["title": title]
        if let profile { payload["profile"] = profile }
        let body = try JSONSerialization.data(withJSONObject: payload)
        try await send(url, method: "PATCH", body: body, token: conn.token, session: session)
      },
      transcribe: { conn, dataURL, mimeType in
        let url = try makeURL(conn.baseURL, "/api/audio/transcribe")
        var payload: [String: Any] = ["data_url": dataURL]
        if let mimeType { payload["mime_type"] = mimeType }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let response: TranscriptionResponse = try await postJSON(
          url, body: body, token: conn.token, session: session
        )
        guard response.ok, let transcript = response.transcript else {
          throw RESTError.transcriptionFailed(response.error ?? "")
        }
        return transcript
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
//
// These are `internal` (not `private`) so sibling clients in the package
// (e.g. `HermesProfileClient`) can reuse the exact same request/decoding/validation
// path rather than duplicating it.

func makeURL(_ base: URL, _ path: String, query: [URLQueryItem] = []) throws -> URL {
  guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
    throw RESTError.unreachable
  }
  comps.path = path
  comps.queryItems = query.isEmpty ? nil : query
  guard let url = comps.url else { throw RESTError.unreachable }
  return url
}

func get<T: Decodable>(_ url: URL, token: String?, session: URLSession) async throws -> T {
  var request = URLRequest(url: url)
  if let token { request.setValue(token, forHTTPHeaderField: "X-Hermes-Session-Token") }

  let data: Data
  let response: URLResponse
  do {
    (data, response) = try await session.data(for: request)
  } catch {
    throw RESTError.unreachable
  }

  try validate(response, data: data)

  do {
    return try JSONDecoder().decode(T.self, from: data)
  } catch {
    throw RESTError.decoding
  }
}

/// Validate an HTTP response status, mapping non-success codes to `RESTError`. The
/// response `data` is read on failure so the server's error `detail` is surfaced
/// verbatim (see `serverDetail`).
func validate(_ response: URLResponse, data: Data) throws {
  guard let http = response as? HTTPURLResponse else { throw RESTError.unreachable }
  switch http.statusCode {
  case 200..<300: break
  case 401: throw RESTError.unauthorized
  case 404: throw RESTError.notFound
  default: throw RESTError.server(status: http.statusCode, detail: serverDetail(from: data))
  }
}

/// Lenient extraction of a human-readable error reason from a non-2xx body: prefer the
/// JSON `{"detail": …}` field, else the trimmed plain-text body, else `nil` (empty body).
func serverDetail(from data: Data) -> String? {
  if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
     let detail = object["detail"] as? String,
     !detail.isEmpty {
    return detail
  }
  let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  return text.isEmpty ? nil : text
}

/// POST a JSON body and decode the response (used by `transcribe`).
func postJSON<T: Decodable>(
  _ url: URL, body: Data, token: String?, session: URLSession
) async throws -> T {
  var request = URLRequest(url: url)
  request.httpMethod = "POST"
  request.httpBody = body
  request.setValue("application/json", forHTTPHeaderField: "Content-Type")
  if let token { request.setValue(token, forHTTPHeaderField: "X-Hermes-Session-Token") }

  let data: Data
  let response: URLResponse
  do {
    (data, response) = try await session.data(for: request)
  } catch {
    throw RESTError.unreachable
  }

  try validate(response, data: data)

  do {
    return try JSONDecoder().decode(T.self, from: data)
  } catch {
    throw RESTError.decoding
  }
}

/// Fire a write request (e.g. PATCH) and validate the status, discarding the body.
func send(
  _ url: URL, method: String, body: Data?, token: String?, session: URLSession
) async throws {
  var request = URLRequest(url: url)
  request.httpMethod = method
  if let body {
    request.httpBody = body
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
  }
  if let token { request.setValue(token, forHTTPHeaderField: "X-Hermes-Session-Token") }

  let data: Data
  let response: URLResponse
  do {
    (data, response) = try await session.data(for: request)
  } catch {
    throw RESTError.unreachable
  }

  try validate(response, data: data)
}

// MARK: - DTOs (verified against hermes_cli/web_server.py + hermes_state.py)

private struct SessionsResponse: Decodable {
  let sessions: [SessionListDTO]
  let total: Int?
}

// `internal` so sibling clients (e.g. `HermesProfileClient`'s scoped-session list,
// which returns rows in the same shape) can reuse the decoding.
struct SessionListDTO: Decodable {
  let id: String
  let title: String?
  let preview: String?
  let lastActive: Double?
  let startedAt: Double?
  let messageCount: Int?
  let cwd: String?
  let isActive: Bool?
  let source: String?

  enum CodingKeys: String, CodingKey {
    case id, title, preview, cwd, source
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
      isActive: isActive,
      source: source
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

/// `/api/audio/transcribe` response — `{ok, transcript, provider?}`; `error` on failure.
private struct TranscriptionResponse: Decodable {
  let ok: Bool
  let transcript: String?
  let provider: String?
  let error: String?
}
