import Foundation

/// One row in the chat transcript. Built by `ChatFeature`'s reducer by folding
/// `GatewayEvent`s (Task 8) — not decoded directly from the wire. Identified by a
/// generated UUID (there is no message id in the stream; see "M0 findings").
public struct ChatRow: Equatable, Sendable, Identifiable {
  public let id: UUID
  public var kind: Kind

  public init(id: UUID, kind: Kind) {
    self.id = id
    self.kind = kind
  }

  public enum Kind: Equatable, Sendable {
    /// A user or assistant message. `isComplete` is false while it streams.
    case message(role: Role, text: String, isComplete: Bool)
    /// A tool invocation; `result`/`durationS` fill in on `tool.complete`.
    case tool(name: String, state: ToolState, result: String?, durationS: Double?)
    /// Collapsible reasoning/thinking content, hidden by default.
    case thinking(text: String)
    /// A transient status line (e.g. "searching…"); `kind` is an open string.
    case status(kind: String, text: String)
  }

  public enum Role: Equatable, Sendable {
    case user
    case assistant
  }

  public enum ToolState: Equatable, Sendable {
    case running
    case complete
  }
}
