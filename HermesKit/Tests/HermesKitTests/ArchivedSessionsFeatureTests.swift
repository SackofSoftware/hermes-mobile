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

  // MARK: Delete (permanent, immediate — no confirmation)

  @Test func deleteOptimisticallyRemovesWipesSnapshotAndCallsDelete() async {
    let deletedID = LockIsolated<String?>(nil)
    let wiped = LockIsolated<[String]>([])
    var state = ArchivedSessionsFeature.State(connection: connection)
    state.sessions = [Session(id: "a", title: "Old"), Session(id: "b", title: "Older")]
    let store = TestStore(initialState: state) {
      ArchivedSessionsFeature()
    } withDependencies: {
      $0.hermesREST.deleteSession = { @Sendable _, id, _ in deletedID.setValue(id) }
      $0.chatSnapshot.deleteSnapshot = { @Sendable id in wiped.withValue { $0.append(id) } }
    }

    // Immediate: the tap itself removes the row — no confirmation dialog in between.
    await store.send(.deleteButtonTapped(id: "a")) {
      $0.sessions.remove(id: "a") // optimistic removal
      $0.deletingIDs = ["a"]
    }
    await store.receive(\.deleteSucceeded) {
      $0.deletingIDs = []
    }
    #expect(deletedID.value == "a")
    #expect(wiped.value == ["a"]) // cached snapshot + turn anchor wiped (Task-4 endpoint)
  }

  @Test func deleteUnderProfilePassesProfileToDeleteSession() async {
    let profile = LockIsolated<String??>(nil)
    var state = ArchivedSessionsFeature.State(connection: connection, profileName: "work")
    state.sessions = [Session(id: "a", title: "Old")]
    let store = TestStore(initialState: state) {
      ArchivedSessionsFeature()
    } withDependencies: {
      $0.hermesREST.deleteSession = { @Sendable _, _, p in profile.setValue(.some(p)) }
    }

    await store.send(.deleteButtonTapped(id: "a")) {
      $0.sessions.remove(id: "a")
      $0.deletingIDs = ["a"]
    }
    await store.receive(\.deleteSucceeded) {
      $0.deletingIDs = []
    }
    #expect(profile.value == .some("work"))
  }

  @Test func deleteUnderDefaultPassesNilProfileToDeleteSession() async {
    let profile = LockIsolated<String??>(nil)
    var state = ArchivedSessionsFeature.State(connection: connection)
    state.sessions = [Session(id: "a", title: "Old")]
    let store = TestStore(initialState: state) {
      ArchivedSessionsFeature()
    } withDependencies: {
      $0.hermesREST.deleteSession = { @Sendable _, _, p in profile.setValue(.some(p)) }
    }

    await store.send(.deleteButtonTapped(id: "a")) {
      $0.sessions.remove(id: "a")
      $0.deletingIDs = ["a"]
    }
    await store.receive(\.deleteSucceeded) {
      $0.deletingIDs = []
    }
    #expect(profile.value == .some(nil)) // default profile → omitted
  }

  @Test func deleteFailureReinsertsAndSetsBanner() async {
    var state = ArchivedSessionsFeature.State(connection: connection)
    state.sessions = [Session(id: "a", title: "Old"), Session(id: "b", title: "Older")]
    let store = TestStore(initialState: state) {
      ArchivedSessionsFeature()
    } withDependencies: {
      $0.hermesREST.deleteSession = { @Sendable _, _, _ in throw RESTError.unreachable }
    }

    await store.send(.deleteButtonTapped(id: "a")) {
      $0.sessions.remove(id: "a")
      $0.deletingIDs = ["a"]
    }
    await store.receive(\.deleteFailed) {
      $0.deletingIDs = []
      $0.sessions.insert(Session(id: "a", title: "Old"), at: 0) // restored at saved index
      $0.loadError = "Couldn’t delete the session."
    }
  }

  @Test(arguments: [RESTError.notFound, RESTError.server(status: 405, detail: "Method Not Allowed")])
  func deleteCapabilityVerdictFlipsFlagSilentlyAndMirrorsBack(error: RESTError) async {
    var state = ArchivedSessionsFeature.State(connection: connection)
    state.sessions = [Session(id: "a", title: "Old")]
    let store = TestStore(initialState: state) {
      ArchivedSessionsFeature()
    } withDependencies: {
      $0.hermesREST.deleteSession = { @Sendable _, _, _ in throw error }
    }

    await store.send(.deleteButtonTapped(id: "a")) {
      $0.sessions.remove(id: "a")
      $0.deletingIDs = ["a"]
    }
    // Definitive 404/405 = agent lacks the endpoint: restore the row SILENTLY (no banner),
    // hide Delete for the rest of the sheet's lifetime, and mirror the verdict to the list.
    await store.receive(\.deleteFailed) {
      $0.deletingIDs = []
      $0.sessions.insert(Session(id: "a", title: "Old"), at: 0)
      $0.deleteSupported = false
    }
    await store.receive(\.delegate.deleteUnsupported)
    #expect(store.state.loadError == nil)
  }

  @Test func deleteTapIsNoOpWhenUnsupported() async {
    var state = ArchivedSessionsFeature.State(connection: connection, deleteSupported: false)
    state.sessions = [Session(id: "a", title: "Old")]
    let store = TestStore(initialState: state) { ArchivedSessionsFeature() }

    await store.send(.deleteButtonTapped(id: "a")) // guard: no removal, no request
  }

  @Test func refreshDuringDeleteExcludesTheInFlightRow() async {
    var state = ArchivedSessionsFeature.State(connection: connection)
    state.deletingIDs = ["a"] // DELETE in flight — its row was optimistically removed
    let store = TestStore(initialState: state) {
      ArchivedSessionsFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.hermesREST.archivedSessions = { @Sendable _, _, _ in
        // A stale listing still carries the deleted row — it must not resurrect it.
        [Session(id: "a", title: "Old"), Session(id: "b", title: "Older")]
      }
    }

    await store.send(.task) {
      $0.now = self.now
      $0.isLoading = true
    }
    await store.receive(\.archivedResponse.success) {
      $0.isLoading = false
      $0.sessions = [Session(id: "b", title: "Older")] // "a" filtered while in flight
    }
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
