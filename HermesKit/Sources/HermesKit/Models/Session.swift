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
  /// Where the session originated (`cron`, `cli`, `telegram`, `discord`, `slack`,
  /// `whatsapp`), or `nil` for local interactive sessions / older agents that omit it.
  /// Kept as a raw string (not enum-ified) so we stay lenient about unknown sources and
  /// only special-case `"cron"` (see `isCron`).
  public var source: String?

  public init(
    id: String,
    title: String? = nil,
    updatedAt: Date? = nil,
    preview: String? = nil,
    cwd: String? = nil,
    startedAt: Date? = nil,
    messageCount: Int? = nil,
    isActive: Bool? = nil,
    source: String? = nil
  ) {
    self.id = id
    self.title = title
    self.updatedAt = updatedAt
    self.preview = preview
    self.cwd = cwd
    self.startedAt = startedAt
    self.messageCount = messageCount
    self.isActive = isActive
    self.source = source
  }

  /// Whether this is a cron-scheduled session — the single source of truth for the
  /// Cron Jobs list partition (mirrors the desktop's `source === "cron"` special-case).
  public var isCron: Bool { source == "cron" }

  /// A real, user-facing title: non-empty and not the server's `"Untitled"` placeholder
  /// (the agent sends that for auto-named/cron sessions before a real title exists).
  /// Mirrors the web app's `session.title && session.title !== "Untitled"` check.
  public var resolvedTitle: String? {
    guard let title = title?.trimmedNonEmpty, title != "Untitled" else { return nil }
    return title
  }

  /// The first-message preview, trimmed, or `nil` when blank.
  public var resolvedPreview: String? { preview?.trimmedNonEmpty }

  /// The human-readable name for the session: a real title, else the first-message
  /// preview, else the raw `id` as an absolute last resort (a real session almost always
  /// has a preview, so the id should rarely surface). One shared rule for the list rows,
  /// search, and the chat header so they never diverge.
  public var displayName: String { resolvedTitle ?? resolvedPreview ?? id }
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
  /// Links a `tool` result message to the assistant `tool_calls` entry that requested it.
  public var toolCallID: String?
  /// On an assistant message: the tool calls it made (name + arguments) — used to
  /// recover the *command* shown in a tool's detail sheet on resume.
  public var toolCalls: [ToolCallRef]?

  enum CodingKeys: String, CodingKey {
    case id, role, content, timestamp
    case toolName = "tool_name"
    case toolCallID = "tool_call_id"
    case toolCalls = "tool_calls"
  }

  public init(
    id: Int, role: String, content: String? = nil, timestamp: Double? = nil,
    toolName: String? = nil, toolCallID: String? = nil, toolCalls: [ToolCallRef]? = nil
  ) {
    self.id = id
    self.role = role
    self.content = content
    self.timestamp = timestamp
    self.toolName = toolName
    self.toolCallID = toolCallID
    self.toolCalls = toolCalls
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = (try? c.decode(Int.self, forKey: .id)) ?? 0
    role = (try? c.decode(String.self, forKey: .role)) ?? ""
    content = try? c.decodeIfPresent(String.self, forKey: .content)
    timestamp = try? c.decodeIfPresent(Double.self, forKey: .timestamp)
    toolName = try? c.decodeIfPresent(String.self, forKey: .toolName)
    toolCallID = try? c.decodeIfPresent(String.self, forKey: .toolCallID)
    // tool_calls is OpenAI-shaped; tolerate absence / odd shapes.
    toolCalls = try? c.decodeIfPresent([ToolCallRef].self, forKey: .toolCalls)
  }
}

/// A tool call recorded on an assistant message (`tool_calls`): which tool was invoked
/// and with what arguments. OpenAI-shaped (`{id, function:{name, arguments}}`).
public struct ToolCallRef: Equatable, Sendable, Decodable, Identifiable {
  public var id: String?
  public var name: String?
  /// Raw arguments — a JSON string for OpenAI-style providers.
  public var arguments: String?

  enum CodingKeys: String, CodingKey { case id, function }
  enum FunctionKeys: String, CodingKey { case name, arguments }

  public init(id: String? = nil, name: String? = nil, arguments: String? = nil) {
    self.id = id
    self.name = name
    self.arguments = arguments
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try? c.decodeIfPresent(String.self, forKey: .id)
    if let fn = try? c.nestedContainer(keyedBy: FunctionKeys.self, forKey: .function) {
      name = try? fn.decodeIfPresent(String.self, forKey: .name)
      arguments = try? fn.decodeIfPresent(String.self, forKey: .arguments)
    }
  }
}
