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
  /// Working directory of the session — the workspace it belongs to. Used to group the
  /// list like the desktop app (see `SessionGroup`). Nil/empty → "No workspace".
  public var cwd: String?
  /// Original start time; used to order rows within a workspace group (desktop parity).
  public var startedAt: Date?
  /// Number of messages — compared against the last-seen count to flag unread activity.
  public var messageCount: Int?
  /// Whether the session is currently active (a turn ran recently).
  public var isActive: Bool?

  public init(
    id: String,
    title: String? = nil,
    updatedAt: Date? = nil,
    preview: String? = nil,
    cwd: String? = nil,
    startedAt: Date? = nil,
    messageCount: Int? = nil,
    isActive: Bool? = nil
  ) {
    self.id = id
    self.title = title
    self.updatedAt = updatedAt
    self.preview = preview
    self.cwd = cwd
    self.startedAt = startedAt
    self.messageCount = messageCount
    self.isActive = isActive
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

/// A stored message from `GET /api/sessions/{id}/messages`. Columns verified against
/// the `messages` table schema. Mapped to `ChatRow` during resume hydration (Task 8).
public struct SessionMessage: Equatable, Sendable, Decodable, Identifiable {
  public var id: Int
  public var role: String
  public var content: String?
  public var timestamp: Double?
  public var toolName: String?

  enum CodingKeys: String, CodingKey {
    case id, role, content, timestamp
    case toolName = "tool_name"
  }

  public init(id: Int, role: String, content: String? = nil, timestamp: Double? = nil, toolName: String? = nil) {
    self.id = id
    self.role = role
    self.content = content
    self.timestamp = timestamp
    self.toolName = toolName
  }
}
