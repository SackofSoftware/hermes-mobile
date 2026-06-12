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
    }
  }

  @Test func tappingSessionEmitsOpenDelegate() async {
    let session = Session(id: "s1", title: "Hello")
    let store = TestStore(
      initialState: SessionListFeature.State(connection: connection, sessions: [session])
    ) {
      SessionListFeature()
    }

    await store.send(.sessionTapped("s1"))
    await store.receive(\.delegate.openSession)
  }

  @Test func newSessionButtonEmitsCreateDelegate() async {
    let store = TestStore(initialState: SessionListFeature.State(connection: connection)) {
      SessionListFeature()
    }

    await store.send(.newSessionButtonTapped)
    await store.receive(\.delegate.createSession)
  }
}
