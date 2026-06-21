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
    await store.receive(\.serverStatusResponse) {
      $0.capability = .tokenOnly
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
    await store.receive(\.serverStatusResponse) { $0.status = .unreachable }
  }

  @Test func reachableButNotHermes() async {
    let store = TestStore(initialState: ConnectionFeature.State(serverURL: "http://something.local:80")) {
      ConnectionFeature()
    } withDependencies: {
      $0.hermesREST.status = { @Sendable _ in throw RESTError.decoding }
    }

    await store.send(.serverFieldCommitted)
    await store.receive(\.checkServer) { $0.status = .checking }
    await store.receive(\.serverStatusResponse) { $0.status = .notHermes }
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
    await store.receive(\.serverStatusResponse) {
      $0.capability = .tokenOnly
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

  // MARK: Capability gating (Task 4)

  @Test func tokenOnlyServerDisablesPasswordAndPreselectsToken() async {
    let store = TestStore(initialState: ConnectionFeature.State(serverURL: "mac:9119")) {
      ConnectionFeature()
    } withDependencies: {
      // No `auth_required` → token-only; providers should not even be probed.
      $0.hermesREST.status = { @Sendable _ in okStatus() }
    }

    await store.send(.serverFieldCommitted)
    await store.receive(\.checkServer) { $0.status = .checking }
    await store.receive(\.serverStatusResponse) {
      $0.capability = .tokenOnly
      $0.status = .reachable(version: "0.16.0")
    }

    #expect(store.state.method == .token)
    #expect(store.state.isPasswordEnabled == false)
    #expect(store.state.isTokenEnabled == true)
    #expect(store.state.isTokenDeemphasized == false)
  }

  @Test func gatedServerEnablesAndPreselectsPassword() async {
    let store = TestStore(initialState: ConnectionFeature.State(serverURL: "mac:9119")) {
      ConnectionFeature()
    } withDependencies: {
      $0.hermesREST.status = { @Sendable _ in
        ServerStatus(version: "0.16.0", authRequired: true, authProviders: ["basic"])
      }
      $0.hermesREST.authProviders = { @Sendable _ in
        [AuthProvider(name: "basic", displayName: "Username & Password", supportsPassword: true)]
      }
    }

    await store.send(.serverFieldCommitted)
    await store.receive(\.checkServer) { $0.status = .checking }
    await store.receive(\.serverStatusResponse) {
      $0.capability = .passwordAvailable(provider: "basic", displayName: "Username & Password")
      $0.method = .password
      $0.status = .reachable(version: "0.16.0")
    }

    #expect(store.state.isPasswordEnabled == true)
    #expect(store.state.isTokenDeemphasized == true)
  }

  @Test func passwordLoginSuccessConnectsWithCookieSession() async {
    let keychain = KeychainClient.inMemory()
    let preferences = PreferencesClient.inMemory()
    let cookieSession = CookieSession(
      cookies: [SerializedCookie(name: "hermes_session_at", value: "abc", domain: "mac", path: "/")],
      username: "alice",
      provider: "basic"
    )
    let store = TestStore(
      initialState: ConnectionFeature.State(
        serverURL: "http://mac:9119",
        username: "alice",
        password: "pw",
        method: .password,
        capability: .passwordAvailable(provider: "basic", displayName: "Password"),
        status: .reachable(version: "0.16.0")
      )
    ) {
      ConnectionFeature()
    } withDependencies: {
      $0.hermesREST.passwordLogin = { @Sendable _, provider, username, _ in
        #expect(provider == "basic")
        #expect(username == "alice")
        return cookieSession
      }
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in [] }
      $0.keychain = keychain
      $0.preferences = preferences
    }

    await store.send(.connectTapped) { $0.status = .validating }
    await store.receive(\.passwordLoginResponse.success)
    await store.receive(\.delegate.connected)

    // Persisted as a cookie session, not a bare token.
    #expect(keychain.loadSession(.shared) == .cookie(cookieSession))
    #expect(preferences.loadServerURL() == "http://mac:9119")
  }

  @Test func passwordLoginInvalidCredentials() async {
    let keychain = KeychainClient.inMemory()
    let store = TestStore(
      initialState: ConnectionFeature.State(
        serverURL: "http://mac:9119",
        username: "alice",
        password: "wrong",
        method: .password,
        capability: .passwordAvailable(provider: "basic", displayName: "Password"),
        status: .reachable(version: "0.16.0")
      )
    ) {
      ConnectionFeature()
    } withDependencies: {
      $0.hermesREST.passwordLogin = { @Sendable _, _, _, _ in throw RESTError.unauthorized }
      $0.keychain = keychain
    }

    await store.send(.connectTapped) { $0.status = .validating }
    await store.receive(\.passwordLoginResponse.failure) { $0.status = .invalidCredentials }

    #expect(keychain.loadSession(.shared) == nil)
  }

  @Test func passwordLoginRateLimitedSurfacesServerCopy() async {
    let store = TestStore(
      initialState: ConnectionFeature.State(
        serverURL: "http://mac:9119",
        username: "alice",
        password: "pw",
        method: .password,
        capability: .passwordAvailable(provider: "basic", displayName: "Password"),
        status: .reachable(version: "0.16.0")
      )
    ) {
      ConnectionFeature()
    } withDependencies: {
      $0.hermesREST.passwordLogin = { @Sendable _, _, _, _ in throw RESTError.rateLimited }
    }

    await store.send(.connectTapped) { $0.status = .validating }
    await store.receive(\.passwordLoginResponse.failure) {
      $0.status = .failed(RESTError.rateLimited.message)
    }
  }

  @Test func passwordLoginServiceUnavailableSurfacesServerCopy() async {
    let store = TestStore(
      initialState: ConnectionFeature.State(
        serverURL: "http://mac:9119",
        username: "alice",
        password: "pw",
        method: .password,
        capability: .passwordAvailable(provider: "basic", displayName: "Password"),
        status: .reachable(version: "0.16.0")
      )
    ) {
      ConnectionFeature()
    } withDependencies: {
      $0.hermesREST.passwordLogin = { @Sendable _, _, _, _ in throw RESTError.serviceUnavailable }
    }

    await store.send(.connectTapped) { $0.status = .validating }
    await store.receive(\.passwordLoginResponse.failure) {
      $0.status = .failed(RESTError.serviceUnavailable.message)
    }
  }
}
