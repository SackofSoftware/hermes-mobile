import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

/// Task 5: instant-paint from the non-authoritative snapshot on `init`, server-wins wholesale
/// replacement on hydrate, offline keeping the cache with a reconnecting status, and the
/// debounced write-back.
@MainActor
struct HydrateTests {
  private let conn = ServerConnection(baseURL: URL(string: "http://mac.tailnet:9119")!, token: "t")
  private func uuid(_ n: Int) -> UUID {
    UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012x", n))")!
  }

  // MARK: Instant paint

  @Test func initPaintsTranscriptModelUsageFromCache() async {
    // A snapshot persisted for the stored session id must paint into the initial state so the
    // chat renders instantly — before any `session.activate` lands.
    let snapshotClient = ChatSnapshotClient.inMemory()
    let cachedRows = [
      ChatRow(id: uuid(10), kind: .message(role: .user, text: "earlier question", isComplete: true)),
      ChatRow(id: uuid(11), kind: .message(role: .assistant, text: "earlier answer", isComplete: true)),
    ]
    snapshotClient.saveSnapshot("stored123", ChatSnapshot(
      model: "claude-opus-4-8",
      reasoningEffort: "high",
      usage: Usage(contextUsed: 1_000, contextMax: 200_000, contextPercent: 0),
      rows: cachedRows
    ))

    // Constructing State inside a dependency scope lets `init` read the seeded cache.
    let state = withDependencies {
      $0.chatSnapshot = snapshotClient
    } operation: {
      ChatFeature.State(connection: conn, resumeStoredID: "stored123")
    }

    #expect(Array(state.transcript) == cachedRows)
    #expect(state.model == "claude-opus-4-8")
    #expect(state.reasoningEffort == "high")
    #expect(state.usage == Usage(contextUsed: 1_000, contextMax: 200_000, contextPercent: 0))
  }

  @Test func initWithNoCacheLeavesEmptyTranscript() async {
    // No snapshot → no paint (empty transcript, nil model/usage). Regression guard.
    let state = withDependencies {
      $0.chatSnapshot = .inMemory()
    } operation: {
      ChatFeature.State(connection: conn, resumeStoredID: "unknown")
    }
    #expect(state.transcript.isEmpty)
    #expect(state.model == nil)
    #expect(state.usage == nil)
  }

  // MARK: Hydrate replaces the cache wholesale

  @Test func hydrateReplacesCachedRowsWholesale() async {
    // The init-painted cache rows must be fully replaced by the server's `messages` on
    // activate (server wins, no merge): cached rows gone, server rows present.
    let snapshotClient = ChatSnapshotClient.inMemory()
    let cachedRows = [
      ChatRow(id: uuid(10), kind: .message(role: .user, text: "stale cached", isComplete: true)),
    ]
    snapshotClient.saveSnapshot("stored123", ChatSnapshot(
      model: "old-model",
      usage: Usage(contextUsed: 9_999, contextMax: 200_000, contextPercent: 5),
      rows: cachedRows
    ))

    let initial = withDependencies {
      $0.chatSnapshot = snapshotClient
    } operation: {
      ChatFeature.State(connection: conn, resumeStoredID: "stored123")
    }
    // Sanity: the cache painted.
    #expect(Array(initial.transcript) == cachedRows)
    #expect(initial.model == "old-model")

    let store = TestStore(initialState: initial) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.chatSnapshot = snapshotClient
      $0.hermesGateway.send = { @Sendable _, _ in
        .object([
          "session_id": .string("live123"),
          "stored_session_id": .string("stored123"),
          "messages": .array([
            .object(["id": .number(1), "role": .string("user"), "content": .string("fresh server msg")]),
            .object(["id": .number(2), "role": .string("assistant"), "content": .string("fresh server reply")]),
          ]),
          "running": .bool(false),
          "info": .object([
            "model": .string("claude-opus-4-8"),
            "usage": .object(["context_used": .number(42), "context_max": .number(200_000), "context_percent": .number(0)]),
          ]),
        ])
      }
    }

    await store.send(.gatewayEvent(.ready)) {
      $0.status = .ready
      $0.hasRequestedSession = true
    }
    await store.receive(\.activateResult.success) {
      $0.liveSessionID = "live123"
      $0.storedSessionID = "stored123"
      $0.status = .ready
      // Model + usage overwritten by the server (not merged with the cache).
      $0.model = "claude-opus-4-8"
      $0.usage = Usage(contextUsed: 42, contextMax: 200_000, contextPercent: 0)
      // Cached row gone; server rows present (wholesale replace).
      $0.transcript = [
        ChatRow(id: self.uuid(0), kind: .message(role: .user, text: "fresh server msg", isComplete: true)),
        ChatRow(id: self.uuid(1), kind: .message(role: .assistant, text: "fresh server reply", isComplete: true)),
      ]
    }
    // The stale cached row id is gone entirely.
    #expect(store.state.transcript[id: self.uuid(10)] == nil)
    await store.send(.onDisappear)
  }

  // MARK: Offline keeps the cache + reconnecting status

  @Test func offlineKeepsCachedPaintAndShowsReconnecting() async {
    // When `session.activate` fails (offline / connection error) we must NOT blank the
    // screen: keep the cached instant-paint rows + model/usage and show a reconnecting status.
    let snapshotClient = ChatSnapshotClient.inMemory()
    let cachedRows = [
      ChatRow(id: uuid(10), kind: .message(role: .user, text: "cached question", isComplete: true)),
      ChatRow(id: uuid(11), kind: .message(role: .assistant, text: "cached answer", isComplete: true)),
    ]
    snapshotClient.saveSnapshot("stored123", ChatSnapshot(
      model: "claude-opus-4-8",
      usage: Usage(contextUsed: 7, contextMax: 200_000, contextPercent: 0),
      rows: cachedRows
    ))

    let initial = withDependencies {
      $0.chatSnapshot = snapshotClient
    } operation: {
      ChatFeature.State(connection: conn, resumeStoredID: "stored123")
    }

    let store = TestStore(initialState: initial) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.chatSnapshot = snapshotClient
      $0.hermesGateway.send = { @Sendable _, _ in throw GatewayError.disconnected }
    }

    await store.send(.gatewayEvent(.ready)) {
      $0.status = .ready
      $0.hasRequestedSession = true
    }
    await store.receive(\.activateResult.failure) {
      $0.errorBanner = GatewayError.disconnected.message
      $0.status = .reconnecting
    }
    // Cache still on screen — never blanked.
    #expect(Array(store.state.transcript) == cachedRows)
    #expect(store.state.model == "claude-opus-4-8")
    #expect(store.state.usage == Usage(contextUsed: 7, contextMax: 200_000, contextPercent: 0))
  }

  // MARK: Debounced write-back

  @Test func contentUpdatePersistsSnapshotAfterDebounce() async {
    // A content-changing gateway event schedules a debounced persist; after the debounce
    // interval the fresh snapshot (model/usage/rows) is written to the cache.
    let snapshotClient = ChatSnapshotClient.inMemory()
    let clock = TestClock()
    var initial = ChatFeature.State(connection: conn)
    initial.liveSessionID = "live123"
    initial.storedSessionID = "stored123"
    initial.status = .ready
    initial.model = "claude-opus-4-8"

    let store = TestStore(initialState: initial) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = clock
      $0.date = .constant(Date(timeIntervalSince1970: 123))
      $0.chatSnapshot = snapshotClient
    }

    // A completed (non-streamed) assistant message changes the transcript + usage.
    await store.send(.gatewayEvent(.messageComplete(
      text: "hello there",
      usage: Usage(contextUsed: 50, contextMax: 200_000, contextPercent: 0)
    ))) {
      $0.usage = Usage(contextUsed: 50, contextMax: 200_000, contextPercent: 0)
      $0.isSending = false
      $0.transcript = [ChatRow(id: self.uuid(0), kind: .message(role: .assistant, text: "hello there", isComplete: true))]
    }

    // Nothing persisted yet (still inside the debounce window).
    #expect(snapshotClient.loadSnapshot("stored123") == nil)

    // Advance past the debounce → the write-back fires.
    await clock.advance(by: .seconds(1))
    await store.receive(\.persistSnapshotTick)

    let saved = snapshotClient.loadSnapshot("stored123")
    #expect(saved?.model == "claude-opus-4-8")
    #expect(saved?.usage == Usage(contextUsed: 50, contextMax: 200_000, contextPercent: 0))
    #expect(saved?.rows == [ChatRow(id: self.uuid(0), kind: .message(role: .assistant, text: "hello there", isComplete: true))])
    #expect(saved?.updatedAt == Date(timeIntervalSince1970: 123))

    await store.send(.onDisappear)
  }

  @Test func burstOfDeltasCoalescesIntoOnePersist() async {
    // Heavy streaming must coalesce into a single write (cancel-in-flight debounce): a burst
    // of deltas within the window yields exactly one persist tick.
    let snapshotClient = ChatSnapshotClient.inMemory()
    let clock = TestClock()
    var initial = ChatFeature.State(connection: conn)
    initial.liveSessionID = "live123"
    initial.storedSessionID = "stored123"
    initial.status = .ready

    let store = TestStore(initialState: initial) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = clock
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.chatSnapshot = snapshotClient
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    // Three deltas back-to-back (no clock advance between) — each resets the debounce.
    await store.send(.gatewayEvent(.messageDelta(text: "a")))
    await store.send(.gatewayEvent(.messageDelta(text: "b")))
    await store.send(.gatewayEvent(.messageDelta(text: "c")))

    await clock.advance(by: .seconds(1))
    // Exactly one persist tick lands (the prior two were cancelled in flight).
    await store.receive(\.persistSnapshotTick)

    let saved = snapshotClient.loadSnapshot("stored123")
    #expect(saved?.rows.last?.copyText == "abc")

    await store.send(.onDisappear)
  }

  // MARK: Task 6 — turn-start anchor + timer continuity

  /// Build an activate-shaped response with the given `running` flag, empty messages and no
  /// inflight, so the only row applyActivate adds is the reconciled live thinking row.
  nonisolated private static func activateResponse(running: Bool) -> JSONValue {
    .object([
      "session_id": .string("live123"),
      "stored_session_id": .string("stored123"),
      "messages": .array([]),
      "running": .bool(running),
      "info": .object([
        "model": .string("claude-opus-4-8"),
        "usage": .object(["context_used": .number(1), "context_max": .number(200_000), "context_percent": .number(0)]),
      ]),
    ])
  }

  @Test func hydrateResumesTimerSeededAtElapsedAndTicksOn() async {
    // running == true with a persisted anchor at `now − 7s` → the live thinking row resumes
    // seeded at 7s and keeps ticking (8s, 9s, …) rather than restarting at 0.
    let snapshotClient = ChatSnapshotClient.inMemory()
    let clock = TestClock()
    let nowDate = Date(timeIntervalSince1970: 1_000)
    snapshotClient.setTurnAnchor("stored123", nowDate.addingTimeInterval(-7))

    let store = TestStore(initialState: ChatFeature.State(connection: conn, resumeStoredID: "stored123")) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = clock
      $0.date = .constant(nowDate)
      $0.chatSnapshot = snapshotClient
      $0.hermesGateway.send = { @Sendable _, _ in Self.activateResponse(running: true) }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.gatewayEvent(.ready))
    await store.receive(\.activateResult.success) {
      $0.isSending = true
      // Live thinking row recreated, seeded at 7s elapsed, still in flight.
      $0.thinkingSeconds = 7
      $0.thinkingRowID = self.uuid(0)
      $0.transcript = [ChatRow(
        id: self.uuid(0),
        kind: .thinking(reasoning: "", status: nil, elapsedSeconds: 7, isComplete: false)
      )]
    }
    // The resumed tick continues from 7 (not 0): two more seconds → 8, 9.
    await clock.advance(by: .seconds(2))
    await store.receive(\.thinkingTick) { $0.thinkingSeconds = 8 }
    await store.receive(\.thinkingTick) { $0.thinkingSeconds = 9 }

    await store.send(.onDisappear)
  }

  @Test func hydrateRunningWithNoAnchorTicksFromZero() async {
    // running == true but no persisted anchor → the timer anchors at `now`, seeding the row
    // at 0s and ticking 1, 2 from there.
    let snapshotClient = ChatSnapshotClient.inMemory() // no anchor seeded
    let clock = TestClock()

    let store = TestStore(initialState: ChatFeature.State(connection: conn, resumeStoredID: "stored123")) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = clock
      $0.date = .constant(Date(timeIntervalSince1970: 1_000))
      $0.chatSnapshot = snapshotClient
      $0.hermesGateway.send = { @Sendable _, _ in Self.activateResponse(running: true) }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.gatewayEvent(.ready))
    await store.receive(\.activateResult.success) {
      $0.isSending = true
      $0.thinkingSeconds = 0
      $0.thinkingRowID = self.uuid(0)
      $0.transcript = [ChatRow(
        id: self.uuid(0),
        kind: .thinking(reasoning: "", status: nil, elapsedSeconds: 0, isComplete: false)
      )]
    }
    await clock.advance(by: .seconds(2))
    await store.receive(\.thinkingTick) { $0.thinkingSeconds = 1 }
    await store.receive(\.thinkingTick) { $0.thinkingSeconds = 2 }

    await store.send(.onDisappear)
  }

  @Test func hydrateNotRunningWithStaleAnchorFreezesAndDiscardsAnchor() async {
    // The phantom-timer bug: running == false but a stale anchor lingers. The timer must NOT
    // resume (no live thinking row, no tick); the stale anchor is discarded from the cache so
    // a later hydrate can't resurrect it.
    let snapshotClient = ChatSnapshotClient.inMemory()
    let clock = TestClock()
    let nowDate = Date(timeIntervalSince1970: 1_000)
    snapshotClient.setTurnAnchor("stored123", nowDate.addingTimeInterval(-30)) // stale

    let store = TestStore(initialState: ChatFeature.State(connection: conn, resumeStoredID: "stored123")) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = clock
      $0.date = .constant(nowDate)
      $0.chatSnapshot = snapshotClient
      $0.hermesGateway.send = { @Sendable _, _ in Self.activateResponse(running: false) }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.gatewayEvent(.ready))
    await store.receive(\.activateResult.success) {
      $0.isSending = false
      $0.thinkingSeconds = 0
    }
    // No live thinking row was created and no tick fires (a leaked tick loop would fail here).
    #expect(store.state.thinkingRowID == nil)
    #expect(store.state.transcript.isEmpty)
    await clock.advance(by: .seconds(5))
    // The stale anchor was discarded from the cache.
    #expect(snapshotClient.turnAnchor("stored123") == nil)

    await store.send(.onDisappear)
  }

  @Test func submitWritesAnchorAndCompleteClearsIt() async {
    // The anchor is persisted on prompt.submit (so a hydrate mid-turn resumes the timer) and
    // dropped on message.complete (so a stopped turn leaves no stale anchor).
    let snapshotClient = ChatSnapshotClient.inMemory()
    let clock = TestClock()
    let nowDate = Date(timeIntervalSince1970: 5_000)
    var initial = ChatFeature.State(connection: conn, status: .ready)
    initial.liveSessionID = "live"
    initial.storedSessionID = "stored123"
    initial.composerText = "hello"

    let store = TestStore(initialState: initial) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = clock
      $0.date = .constant(nowDate)
      $0.chatSnapshot = snapshotClient
      $0.hermesGateway.send = { @Sendable _, _ in .object(["status": .string("streaming")]) }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.composerSubmitted)
    // Anchor written at `now`.
    #expect(snapshotClient.turnAnchor("stored123") == nowDate)

    // The turn ends → the anchor is cleared.
    await store.send(.gatewayEvent(.messageComplete(text: "done", usage: nil)))
    #expect(snapshotClient.turnAnchor("stored123") == nil)

    await store.send(.onDisappear)
  }
}
