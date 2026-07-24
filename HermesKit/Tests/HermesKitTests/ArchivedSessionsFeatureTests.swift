import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

@MainActor
struct ArchivedSessionsFeatureTests {
  private let connection = ServerConnection(baseURL: URL(string: "http://mac.tailnet:9119")!, token: "tok")
  private let now = Date(timeIntervalSince1970: 1_749_600_000)

  @Test func loadPopulatesArchivedSessions() async {
    let store = TestStore(initialState: ArchivedSessionsFeature.State(connection: connection)) {
      ArchivedSessionsFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.hermesREST.archivedSessions = { @Sendable _, _, _ in
        [Session(id: "a", title: "Old"), Session(id: "b", title: "Older")]
      }
    }

    await store.send(.task) {
      $0.now = self.now
      $0.isLoading = true
    }
    await store.receive(\.archivedResponse.success) {
      $0.isLoading = false
      $0.sessions = [Session(id: "a", title: "Old"), Session(id: "b", title: "Older")]
    }
  }

  @Test func loadFailureSetsError() async {
    let store = TestStore(initialState: ArchivedSessionsFeature.State(connection: connection)) {
      ArchivedSessionsFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.hermesREST.archivedSessions = { @Sendable _, _, _ in throw RESTError.unreachable }
    }

    await store.send(.task) {
      $0.now = self.now
      $0.isLoading = true
    }
    await store.receive(\.archivedResponse.failure) {
      $0.isLoading = false
      $0.loadError = RESTError.unreachable.message
    }
  }

  @Test func restoreOptimisticallyRemovesAndCallsArchiveFalse() async {
    let restored = LockIsolated<(String, Bool)?>(nil)
    var state = ArchivedSessionsFeature.State(connection: connection)
    state.sessions = [Session(id: "a", title: "Old"), Session(id: "b", title: "Older")]
    let store = TestStore(initialState: state) {
      ArchivedSessionsFeature()
    } withDependencies: {
      $0.hermesREST.archive = { @Sendable _, id, archived, _ in restored.setValue((id, archived)) }
    }

    await store.send(.restoreButtonTapped(id: "a")) {
      $0.sessions.remove(id: "a") // optimistic removal
      $0.restoringIDs = ["a"]
    }
    await store.receive(\.restoreSucceeded) {
      $0.restoringIDs = []
    }
    #expect(restored.value?.0 == "a")
    #expect(restored.value?.1 == false) // archived:false = restore
  }

  @Test func restoreFailureReinsertsAndSetsError() async {
    var state = ArchivedSessionsFeature.State(connection: connection)
    state.sessions = [Session(id: "a", title: "Old"), Session(id: "b", title: "Older")]
    let store = TestStore(initialState: state) {
      ArchivedSessionsFeature()
    } withDependencies: {
      $0.hermesREST.archive = { @Sendable _, _, _, _ in throw RESTError.unreachable }
    }

    await store.send(.restoreButtonTapped(id: "a")) {
      $0.sessions.remove(id: "a")
      $0.restoringIDs = ["a"]
    }
    await store.receive(\.restoreFailed) {
      $0.restoringIDs = []
      $0.sessions.insert(Session(id: "a", title: "Old"), at: 0) // restored at saved index
      $0.loadError = "Couldn’t restore the session."
    }
  }

  @Test func loadUnderProfileUsesProfileScopedListing() async {
    let captured = LockIsolated<(String, ProfileArchivedFilter)?>(nil)
    let store = TestStore(
      initialState: ArchivedSessionsFeature.State(connection: connection, profileName: "work")
    ) {
      ArchivedSessionsFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.hermesREST.archivedSessions = { @Sendable _, _, _ in
        Issue.record("default endpoint must not be used when a profile is scoped")
        return []
      }
      $0.hermesProfiles.sessions = { @Sendable _, profile, archived, _, _, _ in
        captured.setValue((profile, archived))
        return [Session(id: "p", title: "Profile-archived")]
      }
    }

    await store.send(.task) {
      $0.now = self.now
      $0.isLoading = true
    }
    await store.receive(\.archivedResponse.success) {
      $0.isLoading = false
      $0.sessions = [Session(id: "p", title: "Profile-archived")]
    }
    #expect(captured.value?.0 == "work")
    #expect(captured.value?.1 == .only)
  }

  @Test func loadUnderDefaultUsesRESTArchivedSessions() async {
    let usedREST = LockIsolated(false)
    let store = TestStore(initialState: ArchivedSessionsFeature.State(connection: connection)) {
      ArchivedSessionsFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.hermesREST.archivedSessions = { @Sendable _, _, _ in
        usedREST.setValue(true)
        return [Session(id: "a", title: "Old")]
      }
      $0.hermesProfiles.sessions = { @Sendable _, _, _, _, _, _ in
        Issue.record("profile endpoint must not be used for the default profile")
        return []
      }
    }

    await store.send(.task) {
      $0.now = self.now
      $0.isLoading = true
    }
    await store.receive(\.archivedResponse.success) {
      $0.isLoading = false
      $0.sessions = [Session(id: "a", title: "Old")]
    }
    #expect(usedREST.value)
  }

  @Test func restoreUnderProfilePassesProfileToArchive() async {
    let restored = LockIsolated<(String, Bool, String?)?>(nil)
    var state = ArchivedSessionsFeature.State(connection: connection, profileName: "work")
    state.sessions = [Session(id: "a", title: "Old")]
    let store = TestStore(initialState: state) {
      ArchivedSessionsFeature()
    } withDependencies: {
      $0.hermesREST.archive = { @Sendable _, id, archived, profile in
        restored.setValue((id, archived, profile))
      }
    }

    await store.send(.restoreButtonTapped(id: "a")) {
      $0.sessions.remove(id: "a")
      $0.restoringIDs = ["a"]
    }
    await store.receive(\.restoreSucceeded) {
      $0.restoringIDs = []
    }
    #expect(restored.value?.0 == "a")
    #expect(restored.value?.1 == false)
    #expect(restored.value?.2 == "work")
  }

  @Test func restoreUnderDefaultPassesNilProfileToArchive() async {
    let restored = LockIsolated<String??>(nil)
    var state = ArchivedSessionsFeature.State(connection: connection)
    state.sessions = [Session(id: "a", title: "Old")]
    let store = TestStore(initialState: state) {
      ArchivedSessionsFeature()
    } withDependencies: {
      $0.hermesREST.archive = { @Sendable _, _, _, profile in restored.setValue(profile) }
    }

    await store.send(.restoreButtonTapped(id: "a")) {
      $0.sessions.remove(id: "a")
      $0.restoringIDs = ["a"]
    }
    await store.receive(\.restoreSucceeded) {
      $0.restoringIDs = []
    }
    #expect(restored.value == .some(nil))
  }

  // MARK: Copy session ID (transient toast)

  // Like the session list, the reducer copies the tapped id verbatim (no `state.sessions`
  // lookup — the id comes from a rendered row), so no fixture is seeded.
  @Test func copyIDPutsSessionIDOnPasteboardAndAutoDismissesToast() async {
    let copied = LockIsolated<String?>(nil)
    let clock = TestClock()
    let store = TestStore(initialState: ArchivedSessionsFeature.State(connection: connection)) {
      ArchivedSessionsFeature()
    } withDependencies: {
      $0.pasteboard.copy = { @Sendable text in copied.setValue(text) }
      $0.continuousClock = clock
    }

    await store.send(.copyIDButtonTapped(id: "a")) { $0.copiedIDToastToken = 1 }

    await clock.advance(by: .seconds(1.5))
    await store.receive(\.copiedIDToastExpired) { $0.copiedIDToastToken = nil }
    // Asserted after the effects have been drained — `send` alone doesn't guarantee the
    // merged copy effect has run.
    #expect(copied.value == "a")
  }

  @Test func recopyingWhileToastVisibleRestartsTheDwellTimer() async {
    let copied = LockIsolated<[String]>([])
    let clock = TestClock()
    let state = ArchivedSessionsFeature.State(connection: connection)
    let store = TestStore(initialState: state) {
      ArchivedSessionsFeature()
    } withDependencies: {
      $0.pasteboard.copy = { @Sendable text in copied.withValue { $0.append(text) } }
      $0.continuousClock = clock
    }

    await store.send(.copyIDButtonTapped(id: "a")) { $0.copiedIDToastToken = 1 }
    await clock.advance(by: .seconds(1)) // first dwell is 2/3 elapsed…
    // …a second copy cancels it (cancelInFlight) so the toast does NOT dismiss early. The
    // token bumps even though the toast never hid — that bump is what the view turns into
    // a second VoiceOver announcement.
    await store.send(.copyIDButtonTapped(id: "b")) { $0.copiedIDToastToken = 2 }
    await clock.advance(by: .seconds(1)) // past the first timer's deadline — still visible
    #expect(store.state.copiedIDToastToken == 2)

    await clock.advance(by: .seconds(0.5)) // completes the restarted dwell
    await store.receive(\.copiedIDToastExpired) { $0.copiedIDToastToken = nil }
    #expect(copied.value == ["a", "b"])
  }

  @Test func tappingSessionEmitsOpenDelegate() async {
    let session = Session(id: "a", title: "Old")
    var state = ArchivedSessionsFeature.State(connection: connection)
    state.sessions = [session]
    let store = TestStore(initialState: state) { ArchivedSessionsFeature() }

    await store.send(.sessionTapped(id: "a"))
    await store.receive(\.delegate.openSession)
  }
}
