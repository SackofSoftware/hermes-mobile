import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

/// Branch-in-new-chat (#34): `.branchFromMessage(id:)` fires a one-shot desktop-parity
/// `session.create` seeded with ONLY that assistant message + `parent_session_id`, then
/// emits `Delegate.branchCreated` for `AppFeature`'s slot-replacement open. Guards:
/// completed assistant row with text, no running turn, a session to parent to, and a
/// double-fire in-flight flag.
@MainActor
struct ChatBranchTests {
  private let conn = ServerConnection(baseURL: URL(string: "http://mac.tailnet:9119")!, token: "t")
  private func uuid(_ n: Int) -> UUID {
    UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012x", n))")!
  }

  /// A ready chat holding one completed assistant message to branch from.
  private func branchableState(text: String = "# The answer\n\nUse *plan B*.") -> ChatFeature.State {
    var state = ChatFeature.State(connection: conn, status: .ready)
    state.liveSessionID = "live"
    state.storedSessionID = "stored123"
    state.transcript = [
      ChatRow(id: uuid(0), kind: .message(role: .assistant, text: text, isComplete: true))
    ]
    return state
  }

  // MARK: Success

  @Test func branchSendsSeededCreateAndEmitsDelegate() async {
    let sent = LockIsolated<(method: String, params: JSONValue)?>(nil)
    let store = TestStore(initialState: branchableState()) { ChatFeature() } withDependencies: {
      $0.hermesGateway.send = { @Sendable method, params in
        sent.setValue((method, params))
        return .object([
          "session_id": .string("branch-live"),
          "stored_session_id": .string("branch-stored"),
        ])
      }
    }

    await store.send(.branchFromMessage(id: uuid(0))) {
      $0.isBranching = true
    }
    await store.receive(\.branchResult.success) {
      $0.isBranching = false
    }
    // The delegate carries the persisted id — what REST lists and the open flow resumes by.
    await store.receive(\.delegate.branchCreated, "branch-stored")

    #expect(sent.value?.method == "session.create")
    let params = sent.value?.params
    // Single-message seed: only the tapped assistant message, raw Markdown intact.
    guard case let .array(messages)? = params?["messages"] else {
      Issue.record("missing messages seed")
      return
    }
    #expect(messages.count == 1)
    #expect(messages.first?["role"]?.stringValue == "assistant")
    #expect(messages.first?["content"]?.stringValue == "# The answer\n\nUse *plan B*.")
    #expect(params?["parent_session_id"]?.stringValue == "stored123")
    // No title (server auto-names on first submit), no source, and the default/nil
    // profile is OMITTED — byte-identical to the plain create otherwise.
    #expect(params?["title"] == nil)
    #expect(params?["source"] == nil)
    #expect(params?["profile"] == nil)
    #expect(store.state.errorBanner == nil)
  }

  @Test func branchThreadsSelectedProfileAndFallsBackToLiveID() async {
    let sent = LockIsolated<JSONValue?>(nil)
    var initial = ChatFeature.State(connection: conn, profileName: "work", status: .ready)
    initial.liveSessionID = "live"
    // No stored id (a brand-new live chat) → the live handle parents the branch.
    initial.transcript = [
      ChatRow(id: uuid(0), kind: .message(role: .assistant, text: "answer", isComplete: true))
    ]
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.hermesGateway.send = { @Sendable _, params in
        sent.setValue(params)
        // Old-agent shape: no stored id at create time → delegate falls back to the
        // live handle.
        return .object(["session_id": .string("branch-live")])
      }
    }

    await store.send(.branchFromMessage(id: uuid(0))) { $0.isBranching = true }
    await store.receive(\.branchResult.success) { $0.isBranching = false }
    await store.receive(\.delegate.branchCreated, "branch-live")

    // A non-default profile is threaded (same convention as create/resume).
    #expect(sent.value?["profile"]?.stringValue == "work")
    #expect(sent.value?["parent_session_id"]?.stringValue == "live")
  }

  // MARK: Failure

  @Test func branchFailureSetsErrorBanner() async {
    let store = TestStore(initialState: branchableState()) { ChatFeature() } withDependencies: {
      $0.hermesGateway.send = { @Sendable _, _ in
        throw GatewayError.server("boom")
      }
    }

    await store.send(.branchFromMessage(id: uuid(0))) { $0.isBranching = true }
    // Failure surfaces — never a swallowed `try?` — and clears the in-flight flag so the
    // user can retry.
    await store.receive(\.branchResult.failure) {
      $0.isBranching = false
      $0.errorBanner = "Couldn’t branch the chat: boom"
    }
  }

  @Test func malformedCreateResultIsAFailure() async {
    let store = TestStore(initialState: branchableState()) { ChatFeature() } withDependencies: {
      $0.hermesGateway.send = { @Sendable _, _ in .string("not an object") }
    }

    await store.send(.branchFromMessage(id: uuid(0))) { $0.isBranching = true }
    await store.receive(\.branchResult.failure) {
      $0.isBranching = false
      $0.errorBanner = "Couldn’t branch the chat: Malformed session.create result"
    }
  }

  // MARK: Guards

  @Test func runningTurnBlocksBranchWithBanner() async {
    var initial = branchableState()
    initial.isSending = true
    let store = TestStore(initialState: initial) { ChatFeature() }
    // No dependency override needed — the guard must fire BEFORE any RPC.

    await store.send(.branchFromMessage(id: uuid(0))) {
      $0.errorBanner = "Stop the current turn before branching."
    }
  }

  @Test func emptyTextRowIsANoOp() async {
    let store = TestStore(initialState: branchableState(text: "   \n  ")) { ChatFeature() }
    await store.send(.branchFromMessage(id: uuid(0))) // whitespace-only → no RPC, no state change
  }

  @Test func streamingUserAndUnknownRowsAreNoOps() async {
    var initial = branchableState()
    initial.transcript = [
      ChatRow(id: uuid(0), kind: .message(role: .assistant, text: "half an ans", isComplete: false)),
      ChatRow(id: uuid(1), kind: .message(role: .user, text: "my prompt", isComplete: true)),
      ChatRow(id: uuid(2), kind: .status(kind: "approval", text: "Approved")),
    ]
    let store = TestStore(initialState: initial) { ChatFeature() }

    await store.send(.branchFromMessage(id: uuid(0))) // still streaming
    await store.send(.branchFromMessage(id: uuid(1))) // user message
    await store.send(.branchFromMessage(id: uuid(2))) // not a message row
    await store.send(.branchFromMessage(id: uuid(9))) // no such row
  }

  @Test func secondTapWhileBranchInFlightIsANoOp() async {
    var initial = branchableState()
    initial.isBranching = true // first tap's RPC still outstanding
    let store = TestStore(initialState: initial) { ChatFeature() }

    await store.send(.branchFromMessage(id: uuid(0))) // double-fire guard → no second RPC
  }

  @Test func missingSessionIDIsANoOp() async {
    var initial = ChatFeature.State(connection: conn) // no live/stored id yet
    initial.transcript = [
      ChatRow(id: uuid(0), kind: .message(role: .assistant, text: "answer", isComplete: true))
    ]
    let store = TestStore(initialState: initial) { ChatFeature() }

    await store.send(.branchFromMessage(id: uuid(0))) // nothing to parent to → no RPC
  }
}
