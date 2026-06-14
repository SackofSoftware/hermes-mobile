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
  }

  @Test func loadFailureSetsError() async {
    let store = TestStore(initialState: SessionListFeature.State(connection: connection)) {
      SessionListFeature()
    } withDependencies: {
      $0.date = .constant(now)
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
    }
    await store.finish()
    #expect(archived.value.count == 1)
    #expect(archived.value.first?.0 == "a")
    #expect(archived.value.first?.1 == true)
    #expect(prefs.loadPinnedIDs() == [])
  }

  @Test func archiveFailureReinsertsSessionAndSetsError() async {
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
      $0.preferences = .inMemory()
      $0.hermesREST.archive = { @Sendable _, _, _ in throw RESTError.unreachable }
    }

    await store.send(.confirmationDialog(.presented(.confirmArchive(id: "a")))) {
      $0.confirmationDialog = nil
      $0.sessions = [Session(id: "b")]
    }
    await store.receive(\.archiveFailed) {
      $0.sessions = [Session(id: "b"), session] // re-inserted
      $0.loadError = "Couldn’t archive the session."
    }
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
