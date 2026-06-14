import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

private func okStatus() -> ServerStatus {
  ServerStatus(version: "0.16.0", gatewayRunning: true, gatewayState: "running", activeSessions: 0)
}

@MainActor
struct ConnectionFeatureTests {
  @Test func reachableThenValidTokenConnectsAndStoresToken() async {
    let keychain = KeychainClient.inMemory()
    let preferences = PreferencesClient.inMemory()
    let store = TestStore(initialState: ConnectionFeature.State(serverURL: "mac.tailnet:9119")) {
      ConnectionFeature()
    } withDependencies: {
      $0.hermesREST.status = { @Sendable _ in okStatus() }
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in [] }
      $0.keychain = keychain
      $0.preferences = preferences
    }

    // Submit/focus-loss checks immediately, pre-empting the typing debounce.
    await store.send(.serverFieldCommitted)
    await store.receive(\.checkServer) { $0.status = .checking }
    await store.receive(\.serverStatusResponse.success) {
      $0.status = .reachable(version: "0.16.0")
    }

    await store.send(\.binding.token, "secret") { $0.token = "secret" }
    await store.send(.connectTapped) { $0.status = .validating }
    await store.receive(\.tokenValidationResponse.success)
    await store.receive(\.delegate.connected)

    #expect(keychain.loadToken() == "secret")
    #expect(preferences.loadServerURL() == "http://mac.tailnet:9119")
  }

  @Test func unreachableServer() async {
    let store = TestStore(initialState: ConnectionFeature.State(serverURL: "http://nope.local:1")) {
      ConnectionFeature()
    } withDependencies: {
      $0.hermesREST.status = { @Sendable _ in throw RESTError.unreachable }
    }

    await store.send(.serverFieldCommitted)
    await store.receive(\.checkServer) { $0.status = .checking }
    await store.receive(\.serverStatusResponse.failure) { $0.status = .unreachable }
  }

  @Test func reachableButNotHermes() async {
    let store = TestStore(initialState: ConnectionFeature.State(serverURL: "http://something.local:80")) {
      ConnectionFeature()
    } withDependencies: {
      $0.hermesREST.status = { @Sendable _ in throw RESTError.decoding }
    }

    await store.send(.serverFieldCommitted)
    await store.receive(\.checkServer) { $0.status = .checking }
    await store.receive(\.serverStatusResponse.failure) { $0.status = .notHermes }
  }

  @Test func invalidTokenDoesNotStore() async {
    let keychain = KeychainClient.inMemory()
    let store = TestStore(
      initialState: ConnectionFeature.State(
        serverURL: "http://mac.tailnet:9119",
        token: "wrong",
        status: .reachable(version: "0.16.0")
      )
    ) {
      ConnectionFeature()
    } withDependencies: {
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in throw RESTError.unauthorized }
      $0.keychain = keychain
    }

    await store.send(.connectTapped) { $0.status = .validating }
    await store.receive(\.tokenValidationResponse.failure) { $0.status = .invalidToken }

    #expect(keychain.loadToken() == nil)
  }

  @Test func emptyURLIsInvalid() async {
    let store = TestStore(initialState: ConnectionFeature.State(serverURL: "   ")) {
      ConnectionFeature()
    }
    await store.send(.serverFieldCommitted)
    await store.receive(\.checkServer) { $0.status = .invalidURL }
  }

  // MARK: Auto-validation (Task 2 — no Check button)

  @Test func editingURLResetsToIdleThenDebouncesAutoCheck() async {
    let clock = TestClock()
    let store = TestStore(
      initialState: ConnectionFeature.State(status: .reachable(version: "0.16.0"))
    ) {
      ConnectionFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.hermesREST.status = { @Sendable _ in okStatus() }
    }

    // Typing resets to idle immediately…
    await store.send(\.binding.serverURL, "mac.tailnet:9119") {
      $0.serverURL = "mac.tailnet:9119"
      $0.status = .idle
    }
    // …then auto-checks once typing pauses (debounced).
    await clock.advance(by: .milliseconds(600))
    await store.receive(\.checkServer) { $0.status = .checking }
    await store.receive(\.serverStatusResponse.success) {
      $0.status = .reachable(version: "0.16.0")
    }
  }

  @Test func clearingURLCancelsCheckAndStaysIdle() async {
    let clock = TestClock()
    let store = TestStore(
      initialState: ConnectionFeature.State(serverURL: "x", status: .reachable(version: "0.16.0"))
    ) {
      ConnectionFeature()
    } withDependencies: {
      $0.continuousClock = clock
    }
    // Emptying the field cancels any pending debounced check; no request fires.
    await store.send(\.binding.serverURL, "") {
      $0.serverURL = ""
      $0.status = .idle
    }
  }
}
