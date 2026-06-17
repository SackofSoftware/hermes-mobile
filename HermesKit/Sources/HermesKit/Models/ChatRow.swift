import Foundation

/// One row in the chat transcript. Built by `ChatFeature`'s reducer by folding
/// `GatewayEvent`s (Task 8) — not decoded directly from the wire. Identified by a
/// generated UUID (there is no message id in the stream; see "M0 findings").
public struct ChatRow: Equatable, Sendable, Identifiable {
  public let id: UUID
  public var kind: Kind
  /// Raw bytes of any images the user attached to this message (#8), rendered as
  /// thumbnails in the bubble. Only set on the user's just-sent row — reloaded history
  /// has no local bytes.
  public var attachmentImages: [Data]

  public init(id: UUID, kind: Kind, attachmentImages: [Data] = []) {
    self.id = id
    self.kind = kind
    self.attachmentImages = attachmentImages
  }

  public enum Kind: Equatable, Sendable {
    /// A user or assistant message. `isComplete` is false while it streams.
    case message(role: Role, text: String, isComplete: Bool)
    /// A tool/skill invocation. `title` is the human label (server summary/context →
    /// fallback to `name`); `detail` (args/result/diff) fills in over `tool.complete`.
    case tool(name: String, title: String, state: ToolState, detail: ToolDetail?, durationS: Double?)
    /// Live/collapsible "Thinking" indicator that owns the turn's reasoning plus the
    /// latest `status.update` line. `reasoning` accumulates over deltas; `status` is the
    /// latest context-size/compaction message (shown only in the disclosed area);
    /// `elapsedSeconds` is the frozen final elapsed (written at completion, ignored while
    /// active — the view reads the live `thinkingSeconds`); `isComplete` is false while
    /// the turn runs (live timer + shimmer) and true once frozen.
    case thinking(reasoning: String, status: String?, elapsedSeconds: Int, isComplete: Bool)
    /// A transient status line (e.g. "searching…"); `kind` is an open string.
    case status(kind: String, text: String)
  }

  /// Text put on the pasteboard when the user copies this row (Task 11). Tool rows
  /// prefer their result, then title, then name.
  public var copyText: String {
    switch kind {
    case let .message(_, text, _): return text
    case let .tool(name, title, _, detail, _):
      return detail?.resultText?.nonEmpty ?? title.nonEmpty ?? name
    case let .thinking(reasoning, status, _, _):
      guard let status, !status.isEmpty else { return reasoning }
      return reasoning.isEmpty ? status : reasoning + "\n\n" + status
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

/// Expanded detail for a tool/skill row, shown in the detail sheet. Populated from the
/// richer `tool.start`/`tool.complete` payloads (args, result, edit diff).
public struct ToolDetail: Equatable, Sendable {
  /// Human-readable args (from `tool.start` `args_text`, verbose runs).
  public var argsText: String?
  /// Structured call args (from `tool.complete`), rendered as pretty JSON.
  public var args: JSONValue?
  /// Result text (`result_text`, or a stringified `result`).
  public var resultText: String?
  /// Unified edit diff for file-editing tools (`inline_diff`).
  public var inlineDiff: String?

  public init(
    argsText: String? = nil,
    args: JSONValue? = nil,
    resultText: String? = nil,
    inlineDiff: String? = nil
  ) {
    self.argsText = argsText
    self.args = args
    self.resultText = resultText
    self.inlineDiff = inlineDiff
  }

  public var isEmpty: Bool {
    argsText == nil && (args == nil || args == .null) && resultText == nil && inlineDiff == nil
  }
}

/// Format an elapsed duration in `1h 1m 1s` style for the Thinking indicator. Omits
/// higher-order zero units but always keeps the seconds unit (so `5 → "5s"`,
/// `61 → "1m 1s"`, `3600 → "1h 0m 0s"`, `3661 → "1h 1m 1s"`). Negative inputs floor to
/// `"0s"`.
public func formatElapsed(_ seconds: Int) -> String {
  let total = max(0, seconds)
  let h = total / 3600
  let m = (total % 3600) / 60
  let s = total % 60
  if h > 0 { return "\(h)h \(m)m \(s)s" }
  if m > 0 { return "\(m)m \(s)s" }
  return "\(s)s"
}
