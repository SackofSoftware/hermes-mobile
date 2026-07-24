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
    // The delegate carries the FULL handle: the stored id is the branch's list/marker
    // identity, and the live id is what the replacement chat attaches to (the branch has
    // no DB row until its first prompt, so it can't be resumed by stored id).
    await store.receive(
      \.delegate.branchCreated,
      SessionHandle(sessionID: "branch-live", storedSessionID: "branch-stored")
    )

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

  @Test func branchThreadsSelectedProfile() async {
    let sent = LockIsolated<JSONValue?>(nil)
    var initial = ChatFeature.State(connection: conn, profileName: "work", status: .ready)
    initial.liveSessionID = "live"
    initial.storedSessionID = "stored123"
    initial.transcript = [
      ChatRow(id: uuid(0), kind: .message(role: .assistant, text: "answer", isComplete: true))
    ]
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.hermesGateway.send = { @Sendable _, params in
        sent.setValue(params)
        return .object([
          "session_id": .string("branch-live"),
          "stored_session_id": .string("branch-stored"),
        ])
      }
    }

    await store.send(.branchFromMessage(id: uuid(0))) { $0.isBranching = true }
    await store.receive(\.branchResult.success) { $0.isBranching = false }
    await store.receive(
      \.delegate.branchCreated,
      SessionHandle(sessionID: "branch-live", storedSessionID: "branch-stored")
    )

    // A non-default profile is threaded (same convention as create/resume), and the
    // parent link is the PERSISTED id (the one REST list rows carry, so nesting works).
    #expect(sent.value?["profile"]?.stringValue == "work")
    #expect(sent.value?["parent_session_id"]?.stringValue == "stored123")
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

  @Test func nonGatewayErrorSurfacesAsDisconnected() async {
    // A throw that isn't a `GatewayError` (e.g. a transport-layer Cocoa error) maps to
    // the generic `.disconnected` failure — surfaced, never swallowed.
    let store = TestStore(initialState: branchableState()) { ChatFeature() } withDependencies: {
      $0.hermesGateway.send = { @Sendable _, _ in throw CocoaError(.fileNoSuchFile) }
    }

    await store.send(.branchFromMessage(id: uuid(0))) { $0.isBranching = true }
    await store.receive(\.branchResult.failure) {
      $0.isBranching = false
      $0.errorBanner = "Couldn’t branch the chat: \(GatewayError.disconnected.message)"
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

  @Test func missingStoredIDShowsBannerNotSilentNoOp() async {
    var initial = ChatFeature.State(connection: conn) // no stored id yet
    initial.transcript = [
      ChatRow(id: uuid(0), kind: .message(role: .assistant, text: "answer", isComplete: true))
    ]
    let store = TestStore(initialState: initial) { ChatFeature() }

    // Nothing persisted to parent to → no RPC, but honest feedback (the view normally
    // disables the button via `canBranch`; a race must not be a silent no-op).
    await store.send(.branchFromMessage(id: uuid(0))) {
      $0.errorBanner = "This chat can’t be branched yet."
    }
  }

  @Test func liveOnlySessionCannotBranch() async {
    // Old-agent shape: `session.create` returned no stored id. A live-only handle would
    // stamp a `parent_session_id` no REST list row ever matches (the branch could never
    // nest), so branching requires the persisted id — banner, no RPC.
    var initial = ChatFeature.State(connection: conn, status: .ready)
    initial.liveSessionID = "live"
    initial.transcript = [
      ChatRow(id: uuid(0), kind: .message(role: .assistant, text: "answer", isComplete: true))
    ]
    #expect(initial.canBranch == false)
    let store = TestStore(initialState: initial) { ChatFeature() }

    await store.send(.branchFromMessage(id: uuid(0))) {
      $0.errorBanner = "This chat can’t be branched yet."
    }
  }

  // MARK: Opening the branch (attach by live id — no DB row until the first prompt)

  /// A chat primed from the branch create response (`attachLiveSessionID`) must hydrate
  /// via `session.activate` with the LIVE id — `session.resume` by stored id would 4007
  /// (the server creates the branch's DB row lazily on the first prompt) and the
  /// not-found self-heal would strand the user in an unrelated fresh session.
  @Test func branchPrimedChatAttachesByLiveIDOnReady() async {
    let sent = LockIsolated<(method: String, params: JSONValue)?>(nil)
    var initial = ChatFeature.State(connection: conn, resumeStoredID: "branch-stored")
    initial.attachLiveSessionID = "branch-live"
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.date = .constant(.init(timeIntervalSince1970: 0))
      $0.hermesGateway.send = { @Sendable method, params in
        sent.setValue((method, params))
        // `session.activate` live payload: stored id under `session_key`, seeded history.
        return .object([
          "session_id": .string("branch-live"),
          "session_key": .string("branch-stored"),
          "messages": .array([.object([
            "id": .number(1), "role": .string("assistant"), "text": .string("seeded answer"),
          ])]),
          "running": .bool(false),
          "info": .object([
            "model": .string("claude-opus-4-8"),
            "usage": .object([
              "context_used": .number(0), "context_max": .number(200_000), "context_percent": .number(0),
            ]),
          ]),
        ])
      }
    }

    await store.send(.gatewayEvent(.ready)) {
      $0.status = .ready
      $0.hasRequestedSession = true
    }
    await store.receive(\.activateResult.success) {
      $0.liveSessionID = "branch-live"
      $0.storedSessionID = "branch-stored"
      $0.status = .ready
      $0.model = "claude-opus-4-8"
      $0.usage = Usage(contextUsed: 0, contextMax: 200_000, contextPercent: 0)
      $0.transcript = [ChatRow(
        id: ChatRow.deterministicID(sequenceIndex: 0, role: .assistant, kindDiscriminator: "message"),
        kind: .message(role: .assistant, text: "seeded answer", isComplete: true)
      )]
      // The branch is still unpersisted — a later foreground must attach again.
    }
    #expect(sent.value?.method == "session.activate")
    #expect(sent.value?.params == .object(["session_id": .string("branch-live")]))
    #expect(store.state.attachLiveSessionID == "branch-live")
    await store.receive(\.delegate.runningChanged)
    await store.send(.teardown)
  }

  /// A foreground re-hydrate of a still-unpersisted branch re-attaches by live id over
  /// the healthy socket (never `session.resume` by the row-less stored id).
  @Test func foregroundRehydratesUnpersistedBranchViaActivate() async {
    let methods = LockIsolated<[String]>([])
    var initial = ChatFeature.State(connection: conn, resumeStoredID: "branch-stored", status: .ready)
    initial.attachLiveSessionID = "branch-live"
    initial.liveSessionID = "branch-live"
    initial.hasStarted = true
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.date = .constant(.init(timeIntervalSince1970: 0))
      $0.hermesGateway.send = { @Sendable method, _ in
        methods.withValue { $0.append(method) }
        return .object([
          "session_id": .string("branch-live"),
          "session_key": .string("branch-stored"),
          "messages": .array([]),
          "running": .bool(false),
          "info": .object([
            "model": .string("claude-opus-4-8"),
            "usage": .object([
              "context_used": .number(0), "context_max": .number(200_000), "context_percent": .number(0),
            ]),
          ]),
        ])
      }
    }

    await store.send(.foreground) {
      $0.hasRequestedSession = true
    }
    await store.receive(\.activateResult.success) {
      $0.model = "claude-opus-4-8"
      $0.usage = Usage(contextUsed: 0, contextMax: 200_000, contextPercent: 0)
    }
    #expect(methods.value == ["session.activate"])
    await store.receive(\.delegate.runningChanged)
    await store.send(.teardown)
  }

  /// The first `message.start` means the first prompt landed — the server persisted the
  /// branch's DB row, so the attach bookkeeping clears and subsequent hydrates use the
  /// standard `session.resume` by stored id.
  @Test func messageStartClearsUnpersistedBranchBookkeeping() async {
    let clock = TestClock()
    var initial = ChatFeature.State(connection: conn, resumeStoredID: "branch-stored", status: .ready)
    initial.attachLiveSessionID = "branch-live"
    initial.liveSessionID = "branch-live"
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = clock
      $0.date = .constant(.init(timeIntervalSince1970: 0))
    }

    await store.send(.gatewayEvent(.messageStart)) {
      $0.isSending = true
      $0.attachLiveSessionID = nil
      $0.transcript = [ChatRow(
        id: uuid(0), kind: .thinking(reasoning: "", status: nil, elapsedSeconds: 0, isComplete: false)
      )]
      $0.thinkingRowID = uuid(0)
    }
    await store.receive(\.delegate.runningChanged)
    await store.send(.teardown)
  }

  /// "Session not found" on the attach (the live session was reaped before the first
  /// prompt — e.g. the app sat backgrounded past the server's orphan grace) degrades to
  /// the standard #17 self-heal: a fresh `session.create`, with the branch bookkeeping
  /// cleared so it can't redirect later hydrates at a dead id.
  @Test func attachNotFoundSelfHealsToFreshCreate() async {
    var initial = ChatFeature.State(connection: conn, resumeStoredID: "branch-stored", status: .ready)
    initial.attachLiveSessionID = "branch-live"
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.hermesGateway.send = { @Sendable _, _ in
        .object(["session_id": .string("fresh-live"), "stored_session_id": .string("fresh-stored")])
      }
    }

    await store.send(.activateResult(.failure(.server("session not found")))) {
      $0.status = .reconnecting
      $0.liveSessionID = nil
      $0.attachLiveSessionID = nil
      $0.hasRequestedSession = true
    }
    await store.receive(\.sessionResult.success) {
      $0.liveSessionID = "fresh-live"
      $0.storedSessionID = "fresh-stored"
      $0.status = .ready
    }
  }

  /// An old agent without `session.activate` (`-32601`) degrades the same way — it
  /// ignored the seed params anyway, so the fresh create matches its plain-chat behavior.
  @Test func attachUnknownMethodSelfHealsToFreshCreate() async {
    var initial = ChatFeature.State(connection: conn, resumeStoredID: "branch-stored", status: .ready)
    initial.attachLiveSessionID = "branch-live"
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.hermesGateway.send = { @Sendable _, _ in
        .object(["session_id": .string("fresh-live"), "stored_session_id": .string("fresh-stored")])
      }
    }

    await store.send(.activateResult(.failure(.server("unknown method: session.activate")))) {
      $0.status = .reconnecting
      $0.liveSessionID = nil
      $0.attachLiveSessionID = nil
      $0.hasRequestedSession = true
    }
    await store.receive(\.sessionResult.success) {
      $0.liveSessionID = "fresh-live"
      $0.storedSessionID = "fresh-stored"
      $0.status = .ready
    }
  }
}
