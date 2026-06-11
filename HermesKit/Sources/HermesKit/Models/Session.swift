import Foundation

/// A session as shown in the list (domain model). REST decoding (the exact
/// `/api/sessions` JSON keys) is handled in `HermesRESTClient` (Task 4), where it's
/// verified against the live endpoint — kept out of this domain type to avoid
/// speculative `CodingKeys`.
public struct Session: Equatable, Sendable, Identifiable {
  /// The persisted id (`stored_session_id`) used by REST endpoints.
  public var id: String
  public var title: String?
  public var updatedAt: Date?
  public var preview: String?

  public init(id: String, title: String? = nil, updatedAt: Date? = nil, preview: String? = nil) {
    self.id = id
    self.title = title
    self.updatedAt = updatedAt
    self.preview = preview
  }
}

/// Result of `session.create` / `session.resume` over the WebSocket. Verified shape
/// from the M0 probe: the runtime exposes **two** ids — the short live `session_id`
/// used for all subsequent WS calls, and the persisted `stored_session_id` that REST
/// lists. `messages` is present inline (empty for a new session); whether resume
/// returns full history here is resolved in Task 8.
public struct SessionHandle: Equatable, Sendable, Decodable {
  /// Short live/runtime handle (e.g. `8680ce37`); used in all subsequent WS calls.
  public var sessionID: String
  /// Persisted id (e.g. `20260610_120231_afcca6`); the id REST lists.
  public var storedSessionID: String?
  public var messageCount: Int?

  enum CodingKeys: String, CodingKey {
    case sessionID = "session_id"
    case storedSessionID = "stored_session_id"
    case messageCount = "message_count"
  }

  public init(sessionID: String, storedSessionID: String? = nil, messageCount: Int? = nil) {
    self.sessionID = sessionID
    self.storedSessionID = storedSessionID
    self.messageCount = messageCount
  }
}
