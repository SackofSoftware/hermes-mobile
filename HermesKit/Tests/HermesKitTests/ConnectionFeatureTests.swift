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
    let store = TestStore(initialState: ConnectionFeature.State()) {
      ConnectionFeature()
    } withDependencies: {
      $0.hermesREST.status = { @Sendable _ in okStatus() }
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in [] }
      $0.keychain = keychain
      $0.preferences = preferences
    }

    await store.send(\.binding.serverURL, "mac.tailnet:9119") {
      $0.serverURL = "mac.tailnet:9119"
    }
    await store.send(.checkServerTapped) { $0.status = .checking }
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

    await store.send(.checkServerTapped) { $0.status = .checking }
    await store.receive(\.serverStatusResponse.failure) { $0.status = .unreachable }
  }

  @Test func reachableButNotHermes() async {
    let store = TestStore(initialState: ConnectionFeature.State(serverURL: "http://something.local:80")) {
      ConnectionFeature()
    } withDependencies: {
      $0.hermesREST.status = { @Sendable _ in throw RESTError.decoding }
    }

    await store.send(.checkServerTapped) { $0.status = .checking }
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
    let store = TestStore(initialState: ConnectionFeature.State()) {
      ConnectionFeature()
    }
    await store.send(.checkServerTapped) { $0.status = .invalidURL }
  }

  @Test func editingURLResetsStatusToIdle() async {
    let store = TestStore(
      initialState: ConnectionFeature.State(serverURL: "http://a.local", status: .reachable(version: "0.16.0"))
    ) {
      ConnectionFeature()
    }
    await store.send(\.binding.serverURL, "http://b.local") {
      $0.serverURL = "http://b.local"
      $0.status = .idle
    }
  }
}
