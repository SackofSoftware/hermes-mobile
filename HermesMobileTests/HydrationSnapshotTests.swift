import ComposableArchitecture
import HermesKit
import SnapshotTesting
import SwiftUI
import XCTest

@testable import HermesMobile

/// Snapshot coverage for the session state-sync / live-resume work (plan Task 10):
///
/// - **Re-hydration parity** — a chat rebuilt from stored history via
///   `reconstructTranscript` renders the *same* `ChatRow`s (and therefore the same image)
///   as the live fold of the equivalent gateway-event stream. For a plain
///   user → streamed-answer → tool-call(+result) turn the live fold and the reconstruction
///   produce byte-identical rows in the same order, so both views are asserted against one
///   shared baseline.
/// - **Re-hydrated chat with tool calls + thinking** — the full rehydration layout
///   (reasoning row + assistant text + completed tool row with its recovered command/result).
/// - **Instant-paint** — the cached snapshot painted from `ChatSnapshotClient` *before*
///   `session.activate` lands (shown with the subtle "reconnecting" status).
///
/// Row timestamps aren't shown in `ChatView` rows, so determinism only requires the pinned
/// dark traits + immediate clock from `SnapshotTestCase`.
final class HydrationSnapshotTests: SnapshotTestCase {
  /// A deterministic incrementing `UUID` factory for `reconstructTranscript`'s `makeID`
  /// (row identity is never load-bearing for reconstruction — rows match by key).
  private func incrementingIDs() -> () -> UUID {
    let counter = LockIsolated(0)
    return {
      let n = counter.withValue { value -> Int in
        value += 1
        return value
      }
      return UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012x", n))")!
    }
  }

  // MARK: Fixtures

  /// Stored history for a turn: a user prompt, then an assistant message that both answered
  /// and called one tool, followed by the tool's result message. No reasoning — so the
  /// reconstruction's row order (user → assistant text → tool) matches the live fold's final
  /// order exactly, enabling a pixel-identical parity assertion.
  private func storedHistory_noThinking() -> [SessionMessage] {
    [
      SessionMessage(id: 1, role: "user", content: "What's in server.py?"),
      SessionMessage(
        id: 2, role: "assistant",
        content: "It defines the WebSocket gateway.",
        toolCalls: [ToolCallRef(id: "call_1", name: "read_file",
                                arguments: #"{"path":"server.py"}"#)]
      ),
      SessionMessage(id: 3, role: "tool", content: "def app(): ...",
                     toolName: "read_file", toolCallID: "call_1"),
    ]
  }

  /// Build a `ChatView` over a fixed set of rows, with the socket stubbed so no real
  /// connection opens during render.
  private func chatView(rows: [ChatRow], status: ChatFeature.State.Status = .ready) -> some View {
    NavigationStack {
      ChatView(
        store: Store(
          initialState: ChatFeature.State(
            connection: connection,
            title: "Hydration chat",
            transcript: IdentifiedArray(uniqueElements: rows),
            status: status
          )
        ) {
          ChatFeature()
        } withDependencies: {
          $0.hermesGateway.connect = { _, _ in AsyncStream { _ in } }
          $0.continuousClock = ImmediateClock()
        }
      )
    }
  }

  /// The transcript a live turn yields after folding the equivalent gateway-event stream
  /// for `storedHistory_noThinking`. Mirrors `ChatFeature`'s fold exactly:
  ///   - the prompt's user row,
  ///   - `message.start` creates an eager (empty) thinking row + starts the timer,
  ///   - `message.delta` lazily creates the assistant row,
  ///   - `tool.start` → running tool row, `tool.complete` merges its structured args +
  ///     result into that row,
  ///   - `message.complete` finalizes the assistant row and, since the thinking row carried
  ///     no reasoning/status, *removes* it.
  /// Final rows: `[user][assistant complete][tool complete]` — byte-identical (by `kind`)
  /// to the reconstruction of the same stored history. Built directly (no live `TestStore`)
  /// so the never-terminating thinking-timer loop can't hang the snapshot test.
  private func liveFoldedRows_noThinking() -> [ChatRow] {
    [
      ChatRow(id: id(0), kind: .message(role: .user, text: "What's in server.py?", isComplete: true)),
      ChatRow(id: id(1), kind: .message(role: .assistant, text: "It defines the WebSocket gateway.", isComplete: true)),
      ChatRow(id: id(2), kind: .tool(
        name: "read_file", title: "read_file", state: .complete,
        detail: ToolDetail(args: .object(["path": .string("server.py")]), resultText: "def app(): ..."),
        durationS: nil
      )),
    ]
  }

  // MARK: Re-hydration parity (history == live)

  /// A re-hydrated transcript (rebuilt from stored history) renders identically to the same
  /// turn folded live from gateway events. Both views are asserted against the SAME baseline
  /// image: record once from the reconstruction, then assert the live fold matches it.
  func testRehydrated_matchesLiveStreamedTurn() {
    let reconstructed = reconstructTranscript(storedHistory_noThinking(), makeID: incrementingIDs())
    let live = liveFoldedRows_noThinking()

    // Sanity: the rendered content (row kinds) is identical regardless of generated ids.
    XCTAssertEqual(
      reconstructed.map { $0.kind }, live.map { $0.kind },
      "Re-hydrated rows must equal the live-folded rows for a no-thinking turn"
    )

    // The reconstruction records/asserts the shared baseline...
    assertSnapshot(of: chatView(rows: reconstructed), as: deviceImage(),
                   named: "rehydratedVsLive")
    // ...and the live fold must match the very same image.
    assertSnapshot(of: chatView(rows: live), as: deviceImage(),
                   named: "rehydratedVsLive")
  }

  // MARK: Re-hydrated chat with tool calls + thinking

  /// The full rehydration layout: a reasoning row, the assistant's answer, and a completed
  /// tool row with the command/result recovered from stored `tool_calls` + the `role:"tool"`
  /// result message.
  func testRehydrated_toolCallsAndThinking() {
    let history: [SessionMessage] = [
      SessionMessage(id: 1, role: "user", content: "Summarize the streaming protocol."),
      SessionMessage(
        id: 2, role: "assistant",
        content: "Here's the gist: it's a WebSocket JSON-RPC stream.",
        toolCalls: [ToolCallRef(id: "call_a", name: "read_file",
                                arguments: #"{"path":"tui_gateway/server.py"}"#)],
        reasoning: "Let me look at the gateway server first, then the event types."
      ),
      SessionMessage(id: 3, role: "tool", content: "tui_gateway/server.py",
                     toolName: "read_file", toolCallID: "call_a"),
    ]
    let rows = reconstructTranscript(history, makeID: incrementingIDs())
    assertSnapshot(of: chatView(rows: rows), as: deviceImage())
  }

  // MARK: Instant-paint from the snapshot cache

  /// What the user sees the instant a session opens, painted from the `ChatSnapshotClient`
  /// cache before `session.activate` lands — the cached tail + model/usage with a subtle
  /// "reconnecting" status (never blank).
  func testInstantPaint_fromCache() {
    let cached = ChatSnapshot(
      model: "claude-sonnet-4",
      usage: Usage(contextUsed: 42_000, contextMax: 200_000, contextPercent: 21),
      rows: [
        ChatRow(id: id(0), kind: .message(role: .user, text: "Cached from a previous open.", isComplete: true)),
        ChatRow(id: id(1), kind: .message(
          role: .assistant,
          text: "This tail was painted instantly from the SQLite snapshot.",
          isComplete: true
        )),
      ]
    )
    let view = NavigationStack {
      ChatView(
        store: Store(
          initialState: ChatFeature.State(
            connection: connection,
            resumeStoredID: "20260610_120231_afcca6",
            title: "Cached chat",
            // No explicit transcript → init reads the snapshot synchronously and paints it.
            status: .reconnecting
          )
        ) {
          ChatFeature()
        } withDependencies: {
          $0.hermesGateway.connect = { _, _ in AsyncStream { _ in } }
          $0.continuousClock = ImmediateClock()
          $0.chatSnapshot.loadSnapshot = { _ in cached }
        }
      )
    }
    assertSnapshot(of: view, as: deviceImage())
  }
}
