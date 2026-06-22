import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

/// Pure `reconstructTranscript` over the **cooked** `session.resume` history shape
/// (`_history_to_messages`): text rows carry `text`; tool calls are pre-flattened into
/// `{role:"tool", name, context}` rows (the server already matched call → result); reasoning
/// rides on the assistant text row. Mirrors the desktop TUI `toTranscriptMessages`.
@MainActor
struct TranscriptReconstructionTests {
  private let conn = ServerConnection(baseURL: URL(string: "http://mac.tailnet:9119")!, token: "t")

  /// Deterministic, monotonically-incrementing ids so reconstructed rows are stable.
  private func makeCounter() -> () -> UUID {
    var n = 0
    return {
      defer { n += 1 }
      return UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012x", n))")!
    }
  }

  /// A cooked-shape history message: text rows use `text`; tool rows use `name`/`context`.
  private func msg(
    _ id: Int, _ role: String, text: String? = nil,
    name: String? = nil, context: String? = nil,
    reasoning: String? = nil, reasoningContent: String? = nil, reasoningDetails: String? = nil
  ) -> SessionMessage {
    SessionMessage(
      id: id, role: role,
      text: text, name: name, context: context,
      reasoning: reasoning, reasoningContent: reasoningContent, reasoningDetails: reasoningDetails
    )
  }

  // MARK: - Reasoning rows

  @Test func reasoningRowEmittedCollapsedAndComplete() {
    let rows = reconstructTranscript([
      msg(1, "user", text: "hi"),
      msg(2, "assistant", text: "hello", reasoning: "let me think"),
    ], makeID: makeCounter())

    #expect(rows.map(\.kind) == [ChatRow.Kind]([
      .message(role: .user, text: "hi", isComplete: true),
      .thinking(reasoning: "let me think", status: nil, elapsedSeconds: 0, isComplete: true),
      .message(role: .assistant, text: "hello", isComplete: true),
    ]))
  }

  @Test func reasoningFallsBackThroughVariants() {
    let fromContent = reconstructTranscript(
      [msg(1, "assistant", text: "x", reasoningContent: "via content")], makeID: makeCounter()
    )
    #expect(fromContent.first?.kind == .thinking(reasoning: "via content", status: nil, elapsedSeconds: 0, isComplete: true))

    let fromDetails = reconstructTranscript(
      [msg(1, "assistant", text: "x", reasoningDetails: "via details")], makeID: makeCounter()
    )
    #expect(fromDetails.first?.kind == .thinking(reasoning: "via details", status: nil, elapsedSeconds: 0, isComplete: true))

    // First-non-empty wins.
    let priority = reconstructTranscript(
      [msg(1, "assistant", text: "x", reasoning: "primary", reasoningContent: "secondary")], makeID: makeCounter()
    )
    #expect(priority.first?.kind == .thinking(reasoning: "primary", status: nil, elapsedSeconds: 0, isComplete: true))
  }

  @Test func reasoningElapsedIsZeroSoTheViewShowsBareThought() {
    // Re-hydration has no client-measured duration → elapsedSeconds 0; the view renders a
    // bare "Thought" (never "Thought · 0s"). The reconstruction simply emits 0.
    let rows = reconstructTranscript([msg(1, "assistant", text: "x", reasoning: "r")], makeID: makeCounter())
    guard case let .thinking(_, _, elapsed, isComplete) = rows.first?.kind else {
      Issue.record("expected a thinking row"); return
    }
    #expect(elapsed == 0)
    #expect(isComplete)
  }

  @Test func userReasoningIsIgnored() {
    // Only assistant messages emit reasoning rows.
    let rows = reconstructTranscript([msg(1, "user", text: "hi", reasoning: "ignored")], makeID: makeCounter())
    #expect(rows.map(\.kind) == [.message(role: .user, text: "hi", isComplete: true)])
  }

  // MARK: - Tool rows (cooked, pre-flattened)

  @Test func toolRowFromCookedShape() {
    // The gateway already matched the call → result and flattened it into one row with a
    // display `name` and a short `context` preview.
    let rows = reconstructTranscript([
      msg(1, "tool", name: "read_file", context: "/etc/hosts"),
    ], makeID: makeCounter())

    #expect(rows.count == 1)
    #expect(rows[0].kind == .tool(
      name: "read_file", title: "read_file", state: .complete,
      detail: ToolDetail(argsText: "/etc/hosts"), durationS: nil
    ))
  }

  @Test func toolRowWithoutContextHasNoDetail() {
    let rows = reconstructTranscript([msg(1, "tool", name: "grep")], makeID: makeCounter())
    #expect(rows.count == 1)
    #expect(rows[0].kind == .tool(name: "grep", title: "grep", state: .complete, detail: nil, durationS: nil))
  }

  @Test func toolRowWithoutNameFallsBackToToolLabel() {
    let rows = reconstructTranscript([msg(1, "tool", context: "x")], makeID: makeCounter())
    #expect(rows.count == 1)
    #expect(rows[0].kind == .tool(name: "tool", title: "tool", state: .complete, detail: ToolDetail(argsText: "x"), durationS: nil))
  }

  // MARK: - Empty / blank rows

  @Test func emptyTextRowsAreNotEmittedAsBlankBubbles() {
    let rows = reconstructTranscript([
      msg(1, "assistant", text: nil),
      msg(2, "user", text: ""),
    ], makeID: makeCounter())
    #expect(rows.isEmpty)
  }

  // MARK: - Ordering (cooked stream order is preserved)

  @Test func fullTurnPreservesCookedOrder() {
    // Cooked order for a tool-using turn: user → tool(s) → assistant(reasoning + answer).
    let rows = reconstructTranscript([
      msg(1, "user", text: "What's in /etc/hosts?"),
      msg(2, "tool", name: "read_file", context: "/etc/hosts"),
      msg(3, "assistant", text: "It maps localhost.", reasoning: "thinking…"),
    ], makeID: makeCounter())

    #expect(rows.map(\.kind) == [ChatRow.Kind]([
      .message(role: .user, text: "What's in /etc/hosts?", isComplete: true),
      .tool(name: "read_file", title: "read_file", state: .complete, detail: ToolDetail(argsText: "/etc/hosts"), durationS: nil),
      .thinking(reasoning: "thinking…", status: nil, elapsedSeconds: 0, isComplete: true),
      .message(role: .assistant, text: "It maps localhost.", isComplete: true),
    ]))
  }

  @Test func systemAndUnknownRolesAreSkipped() {
    let rows = reconstructTranscript([
      msg(1, "system", text: "you are helpful"),
      msg(2, "weird", text: "??"),
      msg(3, "user", text: "hi"),
    ], makeID: makeCounter())
    #expect(rows.map(\.kind) == [.message(role: .user, text: "hi", isComplete: true)])
  }

  // MARK: - `content` fallback (raw shape tolerance)

  @Test func contentIsUsedWhenTextAbsent() {
    // Robustness: if a payload ever carries `content` instead of the cooked `text`, the
    // body still renders (`displayText` falls back to `content`).
    let rows = reconstructTranscript([
      SessionMessage(id: 1, role: "user", content: "from content"),
    ], makeID: makeCounter())
    #expect(rows.map(\.kind) == [.message(role: .user, text: "from content", isComplete: true)])
  }

  // MARK: - Decode parity with the real wire shape

  @Test func decodesCookedResumeShapeAndReconstructs() {
    // Decode a raw `session.resume`-shaped messages array (text/name/context) and confirm
    // reconstruction yields the expected rows — guards the SessionMessage CodingKeys.
    let json = """
    [
      {"role": "user", "text": "hi"},
      {"role": "tool", "name": "read_file", "context": "/x"},
      {"role": "assistant", "text": "done", "reasoning": "ponder"}
    ]
    """.data(using: .utf8)!
    let messages = try! JSONDecoder().decode([SessionMessage].self, from: json)
    let rows = reconstructTranscript(messages, makeID: makeCounter())

    #expect(rows.map(\.kind) == [ChatRow.Kind]([
      .message(role: .user, text: "hi", isComplete: true),
      .tool(name: "read_file", title: "read_file", state: .complete, detail: ToolDetail(argsText: "/x"), durationS: nil),
      .thinking(reasoning: "ponder", status: nil, elapsedSeconds: 0, isComplete: true),
      .message(role: .assistant, text: "done", isComplete: true),
    ]))
  }
}
