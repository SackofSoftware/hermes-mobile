import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

@MainActor
struct SessionListFeatureTests {
  private let connection = ServerConnection(baseURL: URL(string: "http://mac.tailnet:9119")!, token: "tok")

  private let now = Date(timeIntervalSince1970: 1_749_600_000)

  @Test func loadSuccess() async {
    let store = TestStore(initialState: SessionListFeature.State(connection: connection)) {
      SessionListFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.continuousClock = TestClock()
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in
        [Session(id: "s1", title: "Hello", preview: "hi")]
      }
    }

    await store.send(.task) {
      $0.now = now
      $0.isLoading = true
    }
    await store.receive(\.sessionsResponse.success) {
      $0.isLoading = false
      $0.sessions = [Session(id: "s1", title: "Hello", preview: "hi")]
      $0.seenCounts = ["s1": 0] // seeded so the session isn't shown unread on first sight
    }
    await store.send(.onDisappear) // cancels the auto-poll loop
  }

  @Test func loadFailureSetsError() async {
    let store = TestStore(initialState: SessionListFeature.State(connection: connection)) {
      SessionListFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.continuousClock = TestClock()
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in throw RESTError.unreachable }
    }

    await store.send(.task) {
      $0.now = now
      $0.isLoading = true
    }
    await store.receive(\.sessionsResponse.failure) {
      $0.isLoading = false
      $0.loadError = RESTError.unreachable.message
    }
    await store.send(.onDisappear) // cancels the auto-poll loop
  }

  // MARK: Auto-poll (working glow freshness)

  @Test func pollRefreshesAfterIntervalAndStopsOnDisappear() async {
    let clock = TestClock()
    let fetchCount = LockIsolated(0)
    let store = TestStore(initialState: SessionListFeature.State(connection: connection)) {
      SessionListFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.continuousClock = clock
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in
        fetchCount.withValue { $0 += 1 }
        return [Session(id: "s1", isActive: true)]
      }
    }

    // .task does the initial load and starts the 10s poll loop.
    await store.send(.task) {
      $0.now = self.now
      $0.isLoading = true
    }
    await store.receive(\.sessionsResponse.success) {
      $0.isLoading = false
      $0.sessions = [Session(id: "s1", isActive: true)]
      $0.seenCounts = ["s1": 0]
    }
    #expect(fetchCount.value == 1)

    // Advancing the clock by the interval fires a poll tick → refresh → re-fetch.
    await clock.advance(by: .seconds(10))
    await store.receive(\.pollTick)
    await store.receive(\.pulledToRefresh) {
      $0.isLoading = true
    }
    await store.receive(\.sessionsResponse.success) {
      $0.isLoading = false
    }
    #expect(fetchCount.value == 2)

    // Disappearing cancels the loop — advancing further triggers no more refreshes.
    await store.send(.onDisappear)
    await clock.advance(by: .seconds(30))
    #expect(fetchCount.value == 2)
  }

  @Test func pollTickIsSkippedWhileSearching() async {
    let fetchCount = LockIsolated(0)
    let store = TestStore(
      initialState: SessionListFeature.State(connection: connection, searchQuery: "foo")
    ) {
      SessionListFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in
        fetchCount.withValue { $0 += 1 }
        return []
      }
      $0.hermesREST.search = { @Sendable _, _ in
        fetchCount.withValue { $0 += 1 }
        return []
      }
    }
    // While a query is active the poll tick is a no-op — no refresh, no fetch of any kind.
    await store.send(.pollTick)
    await store.finish()
    #expect(fetchCount.value == 0)
  }

  @Test func pollResumesAfterSuccessfulArchive() async {
    // The archiving guard is transient: once archiveSucceeded clears it, a pollTick (not
    // searching, archivingIDs empty) DOES refresh — the poll isn't permanently disabled.
    let store = TestStore(
      initialState: SessionListFeature.State(connection: connection, archivingIDs: ["a"])
    ) {
      SessionListFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.preferences = .inMemory()
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in [] }
    }

    // While the archive is in flight, the poll skips (guard non-empty).
    await store.send(.pollTick)

    // Success clears the transient guard (and cancels any in-flight fetch).
    await store.send(.archiveSucceeded(id: "a")) {
      $0.archivingIDs = []
    }

    // Now a poll tick refreshes again — the poll was only paused, not killed.
    await store.send(.pollTick)
    await store.receive(\.pulledToRefresh) {
      $0.now = self.now
      $0.isLoading = true
    }
    await store.receive(\.sessionsResponse.success) {
      $0.isLoading = false
    }
  }

  @Test func searchIsCancelledOnDisappear() async {
    let clock = TestClock()
    let fetchCount = LockIsolated(0)
    let store = TestStore(initialState: SessionListFeature.State(connection: connection)) {
      SessionListFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.hermesREST.search = { @Sendable _, _ in
        fetchCount.withValue { $0 += 1 }
        return []
      }
    }

    // Typing schedules a 300ms-debounced search…
    await store.send(\.binding.searchQuery, "foo") { $0.searchQuery = "foo" }
    // …but disappearing before the debounce fires cancels it.
    await store.send(.onDisappear)
    await clock.advance(by: .milliseconds(300))
    await store.finish()
    #expect(fetchCount.value == 0) // no .sessionsResponse — the debounced search was cancelled
  }

  @Test func searchIsDebouncedAndHitsSearchEndpoint() async {
    let clock = TestClock()
    let store = TestStore(initialState: SessionListFeature.State(connection: connection)) {
      SessionListFeature()
    } withDependencies: {
      $0.hermesREST.search = { @Sendable _, query in
        [Session(id: "r1", title: nil, preview: query)]
      }
      $0.continuousClock = clock
    }

    await store.send(\.binding.searchQuery, "foo") { $0.searchQuery = "foo" }
    await clock.advance(by: .milliseconds(300))
    await store.receive(\.sessionsResponse.success) {
      $0.sessions = [Session(id: "r1", title: nil, preview: "foo")]
      $0.seenCounts = ["r1": 0]
    }
  }

  @Test func tappingSessionEmitsOpenDelegateAndMarksSeen() async {
    let session = Session(id: "s1", title: "Hello", messageCount: 7)
    let store = TestStore(
      initialState: SessionListFeature.State(connection: connection, sessions: [session], seenCounts: ["s1": 3])
    ) {
      SessionListFeature()
    }

    await store.send(.sessionTapped("s1")) {
      $0.seenCounts = ["s1": 7] // opening marks the session read at its current count
    }
    await store.receive(\.delegate.openSession)
  }

  // MARK: Unread + pagination

  @Test func unreadReflectsMessageCountAboveSeen() {
    var state = SessionListFeature.State(
      connection: connection,
      sessions: [
        Session(id: "a", messageCount: 5),  // seen 5 → read
        Session(id: "b", messageCount: 8),  // seen 5 → unread
        Session(id: "c", messageCount: 2),  // no seen entry → not unread (unseeded)
      ],
      seenCounts: ["a": 5, "b": 5]
    )
    #expect(state.unreadSessionIDs == ["b"])
    state.seenCounts["b"] = 8
    #expect(state.unreadSessionIDs.isEmpty)
  }

  // MARK: Pinning

  @Test func pinMovesSessionIntoPinnedSetAndOutOfGroup() async {
    let prefs = PreferencesClient.inMemory()
    let sessions = [
      Session(id: "a", cwd: "/w", startedAt: Date(timeIntervalSince1970: 1)),
      Session(id: "b", cwd: "/w", startedAt: Date(timeIntervalSince1970: 2)),
    ]
    let store = TestStore(
      initialState: SessionListFeature.State(connection: connection, sessions: IdentifiedArray(uniqueElements: sessions))
    ) {
      SessionListFeature()
    } withDependencies: {
      $0.preferences = prefs
    }

    #expect(store.state.pinnedSessions.isEmpty)
    #expect(store.state.groups[0].sessions.map(\.id) == ["a", "b"])

    await store.send(.pinSession(id: "a")) {
      $0.pinnedIDs = ["a"]
    }
    #expect(store.state.pinnedSessions.map(\.id) == ["a"])
    #expect(store.state.groups[0].sessions.map(\.id) == ["b"]) // pinned dropped from group
    #expect(prefs.loadPinnedIDs() == ["a"]) // persisted
  }

  @Test func unpinRestoresSessionToGroup() async {
    let prefs = PreferencesClient.inMemory()
    let sessions = [
      Session(id: "a", cwd: "/w", startedAt: Date(timeIntervalSince1970: 1)),
      Session(id: "b", cwd: "/w", startedAt: Date(timeIntervalSince1970: 2)),
    ]
    let store = TestStore(
      initialState: SessionListFeature.State(
        connection: connection,
        sessions: IdentifiedArray(uniqueElements: sessions),
        pinnedIDs: ["a"]
      )
    ) {
      SessionListFeature()
    } withDependencies: {
      $0.preferences = prefs
    }

    #expect(store.state.pinnedSessions.map(\.id) == ["a"])

    await store.send(.unpinSession(id: "a")) {
      $0.pinnedIDs = []
    }
    #expect(store.state.pinnedSessions.isEmpty)
    #expect(store.state.groups[0].sessions.map(\.id) == ["a", "b"]) // restored to group
    #expect(prefs.loadPinnedIDs() == []) // persisted
  }

  @Test func pinnedSessionsFollowPinInsertionOrder() async {
    let prefs = PreferencesClient.inMemory()
    // `sessions` array order is a, b — but pinning b first then a should yield [b, a].
    let sessions = [Session(id: "a"), Session(id: "b")]
    let store = TestStore(
      initialState: SessionListFeature.State(connection: connection, sessions: IdentifiedArray(uniqueElements: sessions))
    ) {
      SessionListFeature()
    } withDependencies: {
      $0.preferences = prefs
    }

    await store.send(.pinSession(id: "b")) { $0.pinnedIDs = ["b"] }
    await store.send(.pinSession(id: "a")) { $0.pinnedIDs = ["b", "a"] }
    // Pin order, not session-array order.
    #expect(store.state.pinnedSessions.map(\.id) == ["b", "a"])
  }

  @Test func stalePinnedIDIsIgnored() {
    let state = SessionListFeature.State(
      connection: connection,
      sessions: [Session(id: "a")],
      pinnedIDs: ["a", "ghost"] // "ghost" no longer exists
    )
    #expect(state.pinnedSessions.map(\.id) == ["a"]) // stale id dropped
  }

  @Test func taskLoadsPinnedIDsFromPreferences() async {
    let prefs = PreferencesClient.inMemory()
    prefs.savePinnedIDs(["s1"])
    let store = TestStore(initialState: SessionListFeature.State(connection: connection)) {
      SessionListFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.continuousClock = TestClock()
      $0.preferences = prefs
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in [Session(id: "s1")] }
    }

    await store.send(.task) {
      $0.now = self.now
      $0.isLoading = true
      $0.pinnedIDs = ["s1"]
    }
    await store.receive(\.sessionsResponse.success) {
      $0.isLoading = false
      $0.sessions = [Session(id: "s1")]
      $0.seenCounts = ["s1": 0]
    }
    await store.send(.onDisappear) // cancels the auto-poll loop
  }

  @Test func toggleGroupExpansionExpandsThenCollapses() async {
    let sessions = (0..<7).map { Session(id: "s\($0)", cwd: "/w", startedAt: Date(timeIntervalSince1970: Double($0))) }
    let store = TestStore(
      initialState: SessionListFeature.State(connection: connection, sessions: IdentifiedArray(uniqueElements: sessions))
    ) {
      SessionListFeature()
    }
    let group = store.state.groups[0]
    #expect(store.state.visibleSessions(in: group).count == 5) // collapsed

    await store.send(.toggleGroupExpansion(groupID: group.id)) {
      $0.expandedGroups = [group.id]
    }
    #expect(store.state.visibleSessions(in: store.state.groups[0]).count == 7) // expanded

    await store.send(.toggleGroupExpansion(groupID: group.id)) {
      $0.expandedGroups = []
    }
    #expect(store.state.visibleSessions(in: store.state.groups[0]).count == 5) // re-collapsed
  }

  // MARK: Archiving

  @Test func archiveButtonPresentsConfirmationDialog() async {
    let store = TestStore(
      initialState: SessionListFeature.State(connection: connection, sessions: [Session(id: "a")])
    ) {
      SessionListFeature()
    }

    await store.send(.archiveButtonTapped(id: "a")) {
      $0.confirmationDialog = ConfirmationDialogState {
        TextState("Archive session?")
      } actions: {
        ButtonState(role: .destructive, action: .confirmArchive(id: "a")) {
          TextState("Archive")
        }
        ButtonState(role: .cancel) {
          TextState("Cancel")
        }
      } message: {
        TextState("This hides the session from the list. You can restore it from the server.")
      }
    }
  }

  @Test func cancellingDialogKeepsSession() async {
    let store = TestStore(
      initialState: SessionListFeature.State(connection: connection, sessions: [Session(id: "a")])
    ) {
      SessionListFeature()
    }

    await store.send(.archiveButtonTapped(id: "a")) {
      $0.confirmationDialog = ConfirmationDialogState {
        TextState("Archive session?")
      } actions: {
        ButtonState(role: .destructive, action: .confirmArchive(id: "a")) {
          TextState("Archive")
        }
        ButtonState(role: .cancel) {
          TextState("Cancel")
        }
      } message: {
        TextState("This hides the session from the list. You can restore it from the server.")
      }
    }
    // Dismissing (cancel) clears the dialog and leaves the session in place.
    await store.send(.confirmationDialog(.dismiss)) {
      $0.confirmationDialog = nil
    }
    #expect(store.state.sessions.map(\.id) == ["a"])
  }

  @Test func confirmArchiveRemovesSessionOptimisticallyAndCallsRPC() async {
    let prefs = PreferencesClient.inMemory()
    let archived = LockIsolated<[(String, Bool)]>([])
    var initial = SessionListFeature.State(
      connection: connection,
      sessions: [Session(id: "a"), Session(id: "b")],
      seenCounts: ["a": 1, "b": 2],
      pinnedIDs: ["a"]
    )
    initial.confirmationDialog = ConfirmationDialogState {
      TextState("Archive session?")
    } actions: {
      ButtonState(role: .destructive, action: .confirmArchive(id: "a")) { TextState("Archive") }
    }
    let store = TestStore(initialState: initial) {
      SessionListFeature()
    } withDependencies: {
      $0.preferences = prefs
      $0.hermesREST.archive = { @Sendable _, id, flag in
        archived.withValue { $0.append((id, flag)) }
      }
    }

    await store.send(.confirmationDialog(.presented(.confirmArchive(id: "a")))) {
      $0.confirmationDialog = nil
      $0.sessions = [Session(id: "b")]
      $0.pinnedIDs = []
      $0.seenCounts = ["b": 2]
      $0.archivingIDs = ["a"] // in-flight guard while the PATCH runs
    }
    // Success clears the transient guard (so the poll resumes) and cancels any stale in-flight
    // fetch — no permanent filter (server now excludes the archived session anyway).
    await store.receive(\.archiveSucceeded) {
      $0.archivingIDs = []
    }
    await store.finish()
    #expect(store.state.archivingIDs.isEmpty)
    #expect(archived.value.count == 1)
    #expect(archived.value.first?.0 == "a")
    #expect(archived.value.first?.1 == true)
    #expect(prefs.loadPinnedIDs() == [])
    #expect(prefs.loadSeenCounts() == ["b": 2]) // archived session's seen baseline persisted-cleared
  }

  @Test func staleLoadAfterArchiveDoesNotResurrectSession() async {
    // A list fetch already in flight (gated behind a continuation) when the user archives
    // a session must NOT land afterward and re-add the just-removed row.
    let prefs = PreferencesClient.inMemory()
    let gate = AsyncStream.makeStream(of: Void.self)
    var initial = SessionListFeature.State(
      connection: connection,
      sessions: [Session(id: "a"), Session(id: "b")]
    )
    initial.confirmationDialog = ConfirmationDialogState {
      TextState("Archive session?")
    } actions: {
      ButtonState(role: .destructive, action: .confirmArchive(id: "a")) { TextState("Archive") }
    }
    let store = TestStore(initialState: initial) {
      SessionListFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.continuousClock = TestClock()
      $0.preferences = prefs
      $0.hermesREST.archive = { @Sendable _, _, _ in }
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in
        // Block until released, then return the OLD list (both sessions) — stale data.
        var iterator = gate.stream.makeAsyncIterator()
        await iterator.next()
        return [Session(id: "a"), Session(id: "b")]
      }
    }

    // Kick off a load that parks inside the fetch (the response can't land yet).
    await store.send(.pulledToRefresh) {
      $0.now = self.now
      $0.isLoading = true
    }

    // Archive "a" — this cancels the in-flight load and optimistically drops the row.
    await store.send(.confirmationDialog(.presented(.confirmArchive(id: "a")))) {
      $0.confirmationDialog = nil
      $0.sessions = [Session(id: "b")]
      $0.archivingIDs = ["a"]
    }
    // Success clears the guard but cancels the in-flight fetch, so its stale response still
    // can't land afterward to resurrect "a".
    await store.receive(\.archiveSucceeded) {
      $0.archivingIDs = []
    }

    // Release the parked fetch; its (now-cancelled) response must never arrive, so "a"
    // stays archived. No `.sessionsResponse` is received — TestStore would fail otherwise.
    gate.continuation.yield()
    gate.continuation.finish()
    await store.finish()
    #expect(store.state.sessions.map(\.id) == ["b"])
  }

  @Test func archiveFailureRestoresSessionLocallyAndSetsError() async {
    // On failure the optimistic removal is reversed LOCALLY (no reliance on a reload): the
    // session is re-inserted at its saved index, the guard is lifted, and the error is set.
    // `rest.sessions` throws on reload — proving the row is back purely from the local restore.
    let session = Session(id: "a", title: "Keep me")
    var initial = SessionListFeature.State(
      connection: connection,
      sessions: [session, Session(id: "b")]
    )
    initial.confirmationDialog = ConfirmationDialogState {
      TextState("Archive session?")
    } actions: {
      ButtonState(role: .destructive, action: .confirmArchive(id: "a")) { TextState("Archive") }
    }
    let store = TestStore(initialState: initial) {
      SessionListFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.preferences = .inMemory()
      $0.hermesREST.archive = { @Sendable _, _, _ in throw RESTError.unreachable }
      // No reload happens; if one did, it would throw — the row must come back regardless.
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in throw RESTError.unreachable }
    }

    await store.send(.confirmationDialog(.presented(.confirmArchive(id: "a")))) {
      $0.confirmationDialog = nil
      $0.sessions = [Session(id: "b")]
      $0.archivingIDs = ["a"]
    }
    // Failure restores the session at its original index (no reload), lifts the guard, sets error.
    await store.receive(\.archiveFailed) {
      $0.sessions = [session, Session(id: "b")]
      $0.archivingIDs = []
      $0.loadError = "Couldn’t archive the session."
    }
    await store.finish()
    #expect(store.state.sessions.map(\.id) == ["a", "b"])
  }

  @Test func archiveFailureRestoresPinAndSeenState() async {
    let prefs = PreferencesClient.inMemory()
    let session = Session(id: "a", title: "Keep me", messageCount: 5)
    var initial = SessionListFeature.State(
      connection: connection,
      sessions: [session, Session(id: "b")],
      seenCounts: ["a": 3, "b": 2],
      pinnedIDs: ["a"]
    )
    initial.confirmationDialog = ConfirmationDialogState {
      TextState("Archive session?")
    } actions: {
      ButtonState(role: .destructive, action: .confirmArchive(id: "a")) { TextState("Archive") }
    }
    let store = TestStore(initialState: initial) {
      SessionListFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.preferences = prefs
      $0.hermesREST.archive = { @Sendable _, _, _ in throw RESTError.unreachable }
      // No reload happens; if one did it would throw — restore must be purely local.
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in throw RESTError.unreachable }
    }

    // Optimistic removal clears pin + seen and persists the cleared prefs.
    await store.send(.confirmationDialog(.presented(.confirmArchive(id: "a")))) {
      $0.confirmationDialog = nil
      $0.sessions = [Session(id: "b")]
      $0.pinnedIDs = []
      $0.seenCounts = ["b": 2]
      $0.archivingIDs = ["a"]
    }
    // Failure restores the session + pin + seen baseline LOCALLY (no reload), persists them,
    // lifts the guard, and sets the error.
    await store.receive(\.archiveFailed) {
      $0.sessions = [session, Session(id: "b")]
      $0.pinnedIDs = ["a"]
      $0.seenCounts = ["a": 3, "b": 2]
      $0.archivingIDs = []
      $0.loadError = "Couldn’t archive the session."
    }
    await store.finish()
    // The restored prefs are persisted (not left as the cleared prefs).
    #expect(prefs.loadPinnedIDs() == ["a"])
    #expect(prefs.loadSeenCounts() == ["a": 3, "b": 2])
  }

  @Test func successResponseDuringArchiveIsFilteredButGuardIsTransient() async {
    // A fetch that completes mid-PATCH (its response still carrying the archiving session)
    // must be filtered WHILE the id is in flight. The guard is transient: archiveSucceeded
    // clears it, so a LATER response would include the id again (no permanent filter).
    var initial = SessionListFeature.State(
      connection: connection,
      sessions: [Session(id: "b")],
      isLoading: true,
      seenCounts: ["b": 2]
    )
    initial.archivingIDs = ["a"]
    let store = TestStore(initialState: initial) {
      SessionListFeature()
    } withDependencies: {
      $0.preferences = .inMemory()
    }

    // A stale response landing DURING the in-flight window still includes "a" (and "b"); only
    // "b" survives, and "a" is NOT re-seeded into seenCounts (filtered before the seeding loop).
    await store.send(.sessionsResponse(.success([Session(id: "a"), Session(id: "b")]))) {
      $0.isLoading = false
      $0.sessions = [Session(id: "b")] // "a" filtered out while in flight
    }
    #expect(store.state.seenCounts["a"] == nil)

    // Success clears the transient guard (cancelling any in-flight fetch).
    await store.send(.archiveSucceeded(id: "a")) {
      $0.archivingIDs = []
    }
    #expect(store.state.archivingIDs.isEmpty)

    // With the guard cleared, a LATER authoritative response is no longer filtered — there is
    // no permanent filter (the server is the source of truth for archived state now).
    await store.send(.sessionsResponse(.success([Session(id: "a"), Session(id: "b")]))) {
      $0.sessions = [Session(id: "a"), Session(id: "b")]
      $0.seenCounts = ["a": 0, "b": 2]
    }
    #expect(store.state.sessions.map(\.id) == ["a", "b"])
  }

  // MARK: Rename (optimistic + rollback, mirroring archive)

  @Test func renameOptimisticallyUpdatesTitleAndCallsRPC() async {
    let renamed = LockIsolated<[(String, String)]>([])
    let store = TestStore(
      initialState: SessionListFeature.State(
        connection: connection,
        sessions: [Session(id: "a", title: "Old"), Session(id: "b")]
      )
    ) {
      SessionListFeature()
    } withDependencies: {
      $0.hermesREST.rename = { @Sendable _, id, title in
        renamed.withValue { $0.append((id, title)) }
      }
    }

    // Tapping rename seeds the draft with the row's current title and opens the alert.
    await store.send(.renameButtonTapped(id: "a")) {
      $0.renamingID = "a"
      $0.renameDraft = "Old"
    }

    // Edit the draft (pure binding, no side effect).
    await store.send(\.binding.renameDraft, "New name") {
      $0.renameDraft = "New name"
    }

    // Confirm optimistically updates the title, clears the alert, marks in-flight, and fires the RPC.
    await store.send(.confirmRename) {
      $0.sessions[id: "a"]?.title = "New name"
      $0.renamingID = nil
      $0.renameDraft = ""
      $0.renamingInFlightIDs = ["a"]
    }
    await store.receive(\.renameSucceeded) {
      $0.renamingInFlightIDs = [] // guard lifted, poll resumes
    }
    #expect(renamed.value.count == 1)
    #expect(renamed.value.first?.0 == "a")
    #expect(renamed.value.first?.1 == "New name")
  }

  @Test func renameFailureRestoresPreviousTitleAndSetsError() async {
    let store = TestStore(
      initialState: SessionListFeature.State(
        connection: connection,
        sessions: [Session(id: "a", title: "Keep me")],
        renamingID: "a",
        renameDraft: "Too long"
      )
    ) {
      SessionListFeature()
    } withDependencies: {
      $0.hermesREST.rename = { @Sendable _, _, _ in throw RESTError.server(status: 400) }
    }

    // Optimistic update, then the RPC throws → renameFailed restores the previous title.
    await store.send(.confirmRename) {
      $0.sessions[id: "a"]?.title = "Too long"
      $0.renamingID = nil
      $0.renameDraft = ""
      $0.renamingInFlightIDs = ["a"]
    }
    await store.receive(\.renameFailed) {
      $0.renamingInFlightIDs = [] // guard lifted on failure too
      $0.sessions[id: "a"]?.title = "Keep me"
      $0.loadError = "Couldn’t rename the session."
    }
  }

  @Test func pollTickIsSkippedWhileRenameInFlight() async {
    // While a rename PATCH is in flight a pollTick must not fetch — a fetch landing mid-PATCH
    // would clobber the optimistic title with the server's old one.
    let store = TestStore(
      initialState: SessionListFeature.State(
        connection: connection,
        sessions: [Session(id: "a", title: "New name")],
        renamingInFlightIDs: ["a"]
      )
    ) {
      SessionListFeature()
    }
    // No .pulledToRefresh / fetch follows — the guard short-circuits the tick.
    await store.send(.pollTick)
  }

  @Test func cancelRenameDismissesAlertWithoutChange() async {
    let store = TestStore(
      initialState: SessionListFeature.State(
        connection: connection,
        sessions: [Session(id: "a", title: "Old")],
        renamingID: "a",
        renameDraft: "Edited"
      )
    ) {
      SessionListFeature()
    }

    await store.send(.cancelRename) {
      $0.renamingID = nil
      $0.renameDraft = ""
    }
    #expect(store.state.sessions[id: "a"]?.title == "Old")
  }

  @Test func newSessionButtonEmitsCreateDelegate() async {
    let store = TestStore(initialState: SessionListFeature.State(connection: connection)) {
      SessionListFeature()
    }

    await store.send(.newSessionButtonTapped)
    await store.receive(\.delegate.createSession)
  }

  // MARK: Settings presentation (Task 12)

  @Test func settingsButtonPresentsSettings() async {
    let store = TestStore(initialState: SessionListFeature.State(connection: connection)) {
      SessionListFeature()
    }

    await store.send(.settingsButtonTapped) {
      $0.settings = SettingsFeature.State(connection: self.connection)
    }
  }

  @Test func settingsDisconnectDismissesAndBubblesUp() async {
    var initial = SessionListFeature.State(connection: connection)
    initial.settings = SettingsFeature.State(connection: connection)
    let store = TestStore(initialState: initial) { SessionListFeature() }

    await store.send(.settings(.presented(.delegate(.disconnect)))) {
      $0.settings = nil
    }
    await store.receive(\.delegate.disconnect)
  }

  @Test func settingsReconnectTriggersReload() async {
    var initial = SessionListFeature.State(connection: connection)
    initial.settings = SettingsFeature.State(connection: connection)
    let store = TestStore(initialState: initial) {
      SessionListFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in [Session(id: "s1")] }
    }

    await store.send(.settings(.presented(.delegate(.reconnect))))
    await store.receive(\.pulledToRefresh) {
      $0.now = self.now
      $0.isLoading = true
    }
    await store.receive(\.sessionsResponse.success) {
      $0.isLoading = false
      $0.sessions = [Session(id: "s1")]
      $0.seenCounts = ["s1": 0]
    }
  }

  @Test func settingsTokenSavedUpdatesConnection() async {
    var initial = SessionListFeature.State(connection: connection)
    initial.settings = SettingsFeature.State(connection: connection)
    let store = TestStore(initialState: initial) { SessionListFeature() }

    await store.send(.settings(.presented(.delegate(.tokenSaved("newtok"))))) {
      $0.connection.token = "newtok"
    }
  }
}
