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

  @Test func showMoreExpandsGroup() async {
    let sessions = (0..<7).map { Session(id: "s\($0)", cwd: "/w", startedAt: Date(timeIntervalSince1970: Double($0))) }
    let store = TestStore(
      initialState: SessionListFeature.State(connection: connection, sessions: IdentifiedArray(uniqueElements: sessions))
    ) {
      SessionListFeature()
    }
    let group = store.state.groups[0]
    #expect(store.state.visibleSessions(in: group).count == 5) // collapsed

    await store.send(.showMoreTapped(groupID: group.id)) {
      $0.expandedGroups = [group.id]
    }
    #expect(store.state.visibleSessions(in: store.state.groups[0]).count == 7) // expanded
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
