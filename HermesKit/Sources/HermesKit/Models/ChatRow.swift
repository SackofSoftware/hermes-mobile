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

  /// Text put on the pasteboard when the user copies this row (Task 11). Tool rows
  /// prefer their result; a running tool with no result yet copies its name.
  public var copyText: String {
    switch kind {
    case let .message(_, text, _): return text
    case let .tool(name, _, result, _): return (result?.isEmpty == false ? result : name) ?? name
    case let .thinking(text): return text
    case let .status(_, text): return text
    }
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
