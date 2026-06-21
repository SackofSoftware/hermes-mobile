import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

/// Pure `reconstructTranscript` reconstruction + keying-parity with the live fold.
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

  private func msg(
    _ id: Int, _ role: String, content: String? = nil,
    toolName: String? = nil, toolCallID: String? = nil,
    toolCalls: [ToolCallRef]? = nil,
    reasoning: String? = nil, reasoningContent: String? = nil, reasoningDetails: String? = nil
  ) -> SessionMessage {
    SessionMessage(
      id: id, role: role, content: content,
      toolName: toolName, toolCallID: toolCallID, toolCalls: toolCalls,
      reasoning: reasoning, reasoningContent: reasoningContent, reasoningDetails: reasoningDetails
    )
  }

  // MARK: - Reasoning rows

  @Test func reasoningRowEmittedCollapsedAndComplete() {
    let rows = reconstructTranscript([
      msg(1, "user", content: "hi"),
      msg(2, "assistant", content: "hello", reasoning: "let me think"),
    ], makeID: makeCounter())

    let kinds = rows.map(\.kind)
    #expect(kinds == [ChatRow.Kind]([
      .message(role: .user, text: "hi", isComplete: true),
      .thinking(reasoning: "let me think", status: nil, elapsedSeconds: 0, isComplete: true),
      .message(role: .assistant, text: "hello", isComplete: true),
    ]))
  }

  @Test func reasoningFallsBackThroughVariants() {
    let fromContent = reconstructTranscript(
      [msg(1, "assistant", content: "x", reasoningContent: "via content")], makeID: makeCounter()
    )
    #expect(fromContent.first?.kind == .thinking(reasoning: "via content", status: nil, elapsedSeconds: 0, isComplete: true))

    let fromDetails = reconstructTranscript(
      [msg(1, "assistant", content: "x", reasoningDetails: "via details")], makeID: makeCounter()
    )
    #expect(fromDetails.first?.kind == .thinking(reasoning: "via details", status: nil, elapsedSeconds: 0, isComplete: true))

    // First-non-empty wins.
    let priority = reconstructTranscript(
      [msg(1, "assistant", content: "x", reasoning: "primary", reasoningContent: "secondary")], makeID: makeCounter()
    )
    #expect(priority.first?.kind == .thinking(reasoning: "primary", status: nil, elapsedSeconds: 0, isComplete: true))
  }

  @Test func userReasoningIsIgnored() {
    // Only assistant messages emit reasoning rows.
    let rows = reconstructTranscript([msg(1, "user", content: "hi", reasoning: "ignored")], makeID: makeCounter())
    #expect(rows.map(\.kind) == [.message(role: .user, text: "hi", isComplete: true)])
  }

  // MARK: - Tool-only turns are kept

  @Test func toolOnlyAssistantTurnIsKept() {
    // An assistant turn with no text but a tool call must NOT be dropped.
    let rows = reconstructTranscript([
      msg(1, "assistant", content: nil, toolCalls: [
        ToolCallRef(id: "call_1", name: "read_file", arguments: "{\"path\":\"/x\"}"),
      ]),
    ], makeID: makeCounter())

    #expect(rows.count == 1)
    #expect(rows[0].kind == .tool(
      name: "read_file", title: "read_file", state: .complete,
      detail: ToolDetail(args: .object(["path": .string("/x")])), durationS: nil
    ))
  }

  @Test func emptyUserAndAssistantTextRowsAreNotEmittedAsBlankBubbles() {
    // Empty/nil content with no tool calls and no reasoning produces nothing for that row.
    let rows = reconstructTranscript([
      msg(1, "assistant", content: nil),
      msg(2, "user", content: ""),
    ], makeID: makeCounter())
    #expect(rows.isEmpty)
  }

  // MARK: - Backward tool-result matching

  @Test func toolResultMatchedBackwardByID() {
    let rows = reconstructTranscript([
      msg(1, "assistant", content: nil, toolCalls: [
        ToolCallRef(id: "call_1", name: "read_file", arguments: "{\"path\":\"/x\"}"),
      ]),
      msg(2, "tool", content: "file contents", toolName: "read_file", toolCallID: "call_1"),
    ], makeID: makeCounter())

    #expect(rows.count == 1)
    #expect(rows[0].kind == .tool(
      name: "read_file", title: "read_file", state: .complete,
      detail: ToolDetail(args: .object(["path": .string("/x")]), resultText: "file contents"),
      durationS: nil
    ))
  }

  @Test func toolResultMatchedBackwardByNameWhenNoID() {
    // No tool_call_id on the result → fall back to the nearest same-name unfilled tool row.
    let rows = reconstructTranscript([
      msg(1, "assistant", content: nil, toolCalls: [
        ToolCallRef(id: nil, name: "grep", arguments: nil),
      ]),
      msg(2, "tool", content: "2 matches", toolName: "grep", toolCallID: nil),
    ], makeID: makeCounter())

    #expect(rows.count == 1)
    #expect(rows[0].kind == .tool(
      name: "grep", title: "grep", state: .complete,
      detail: ToolDetail(resultText: "2 matches"), durationS: nil
    ))
  }

  @Test func backwardMatchPicksNearestUnfilledSameNameTool() {
    // Two grep calls; two results without ids. The first result fills the *nearest*
    // (latest) unfilled grep; the second then fills the earlier one.
    let rows = reconstructTranscript([
      msg(1, "assistant", content: nil, toolCalls: [ToolCallRef(id: nil, name: "grep", arguments: nil)]),
      msg(2, "assistant", content: nil, toolCalls: [ToolCallRef(id: nil, name: "grep", arguments: nil)]),
      msg(3, "tool", content: "result-A", toolName: "grep", toolCallID: nil),
      msg(4, "tool", content: "result-B", toolName: "grep", toolCallID: nil),
    ], makeID: makeCounter())

    #expect(rows.count == 2)
    // First result fills the latest (row index 1), second fills the earlier (row index 0).
    #expect(rows[1].kind == .tool(name: "grep", title: "grep", state: .complete, detail: ToolDetail(resultText: "result-A"), durationS: nil))
    #expect(rows[0].kind == .tool(name: "grep", title: "grep", state: .complete, detail: ToolDetail(resultText: "result-B"), durationS: nil))
  }

  @Test func idMatchTakesPrecedenceOverName() {
    // Two tools with the same name but distinct ids; the result targets the *first* by id
    // even though the second is the nearest by name.
    let rows = reconstructTranscript([
      msg(1, "assistant", content: nil, toolCalls: [
        ToolCallRef(id: "call_1", name: "exec", arguments: nil),
        ToolCallRef(id: "call_2", name: "exec", arguments: nil),
      ]),
      msg(2, "tool", content: "for call_1", toolName: "exec", toolCallID: "call_1"),
    ], makeID: makeCounter())

    #expect(rows.count == 2)
    #expect(rows[0].kind == .tool(name: "exec", title: "exec", state: .complete, detail: ToolDetail(resultText: "for call_1"), durationS: nil))
    // call_2 stays unfilled (no result).
    #expect(rows[1].kind == .tool(name: "exec", title: "exec", state: .complete, detail: nil, durationS: nil))
  }

  // MARK: - Ordering reasoning → text → tools

  @Test func orderingReasoningThenTextThenTools() {
    let rows = reconstructTranscript([
      msg(1, "assistant", content: "Here you go", toolCalls: [
        ToolCallRef(id: "call_1", name: "read_file", arguments: nil),
      ], reasoning: "thinking…"),
    ], makeID: makeCounter())

    #expect(rows.map(\.kind) == [ChatRow.Kind]([
      .thinking(reasoning: "thinking…", status: nil, elapsedSeconds: 0, isComplete: true),
      .message(role: .assistant, text: "Here you go", isComplete: true),
      .tool(name: "read_file", title: "read_file", state: .complete, detail: nil, durationS: nil),
    ]))
  }

  @Test func unknownRoleIsSkipped() {
    let rows = reconstructTranscript([
      msg(1, "system", content: "you are helpful"),
      msg(2, "user", content: "hi"),
    ], makeID: makeCounter())
    #expect(rows.map(\.kind) == [.message(role: .user, text: "hi", isComplete: true)])
  }

  // MARK: - Keying parity: reconstructed turn == live-folded turn

  /// A shared fixture turn folded live (tool.start → tool.complete) must produce a row
  /// whose `kind` is byte-identical to the same turn reconstructed from history, and the
  /// tool must be keyed by the same stable id in both paths.
  @Test func keyingParityWithLiveFold() async {
    let toolID = "call_1"
    let toolName = "read_file"
    let args = JSONValue.object(["path": .string("/x")])
    let argsJSON = "{\"path\":\"/x\"}"
    let resultText = "ok"

    // --- Live fold: drive the reducer through the gateway events for one tool turn. ---
    let store = TestStore(initialState: ChatFeature.State(connection: conn)) {
      ChatFeature()
    } withDependencies: { $0.uuid = .incrementing; $0.continuousClock = TestClock() }
    store.exhaustivity = .off

    await store.send(.gatewayEvent(.toolStart(toolID: toolID, name: toolName, title: nil, argsText: nil)))
    await store.send(.gatewayEvent(.toolComplete(
      toolID: toolID, name: toolName, title: nil,
      args: args, resultText: resultText, inlineDiff: nil, durationS: nil
    )))

    let liveToolRow = store.state.transcript.first { if case .tool = $0.kind { return true }; return false }
    let liveKey = store.state.toolRowIDs.keys.first

    // --- Reconstruction: same logical turn from stored history. ---
    let reconstructed = reconstructTranscript([
      msg(1, "assistant", content: nil, toolCalls: [
        ToolCallRef(id: toolID, name: toolName, arguments: argsJSON),
      ]),
      msg(2, "tool", content: resultText, toolName: toolName, toolCallID: toolID),
    ], makeID: makeCounter())

    let reconstructedToolRow = reconstructed.first { if case .tool = $0.kind { return true }; return false }

    // The live fold keys `toolRowIDs` by the gateway tool id; reconstruction keys by the
    // same `tool_call_id`. Same key in both paths.
    #expect(liveKey == toolID)

    // And the resulting row content is identical.
    #expect(liveToolRow?.kind == reconstructedToolRow?.kind)
    #expect(reconstructedToolRow?.kind == .tool(
      name: toolName, title: toolName, state: .complete,
      detail: ToolDetail(args: args, resultText: resultText), durationS: nil
    ))
  }
}
