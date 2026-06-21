import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

@MainActor
struct ReauthFeatureTests {
  private let url = URL(string: "http://mac.tailnet:9119")!

  private func cookieSession(username: String) -> CookieSession {
    CookieSession(
      cookies: [SerializedCookie(name: "hermes_session_at", value: "abc", domain: "mac.tailnet", path: "/")],
      username: username,
      provider: "basic"
    )
  }

  // MARK: - Pure identity-compare helper

  @Test func identityCompareNormalizesCaseAndWhitespace() {
    #expect(isSameUser("alice", "alice"))
    #expect(isSameUser("Alice", "alice"))
    #expect(isSameUser("  alice ", "alice"))
    #expect(isSameUser("", ""))
    #expect(!isSameUser("alice", "bob"))
    #expect(!isSameUser("alice", ""))
  }

  // MARK: - Password re-auth → same user

  @Test func passwordReauthSameUserBubblesReauthenticated() async {
    let session = cookieSession(username: "alice")
    let store = TestStore(
      initialState: ReauthFeature.State(
        serverURL: url, method: .password, provider: "basic", previousUsername: "alice"
      )
    ) {
      ReauthFeature()
    } withDependencies: {
      $0.hermesREST.passwordLogin = { @Sendable _, _, _, _ in session }
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in [] }
    }

    await store.send(.binding(.set(\.password, "pw"))) { $0.password = "pw" }
    await store.send(.signInTapped) { $0.status = .validating }

    let expected = ServerConnection(baseURL: url, auth: .cookie(session))
    await store.receive(\.reauthResponse.success)
    await store.receive(\.delegate, .reauthenticated(connection: expected, sameUser: true))
  }

  @Test func passwordReauthDifferentUserReportsNotSameUser() async {
    // The re-login authenticated as "bob", not the expired "alice" — sameUser must be false.
    let session = cookieSession(username: "bob")
    let store = TestStore(
      initialState: ReauthFeature.State(
        serverURL: url, method: .password, provider: "basic",
        previousUsername: "alice", username: "bob", password: "pw"
      )
    ) {
      ReauthFeature()
    } withDependencies: {
      $0.hermesREST.passwordLogin = { @Sendable _, _, _, _ in session }
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in [] }
    }

    await store.send(.signInTapped) { $0.status = .validating }
    let expected = ServerConnection(baseURL: url, auth: .cookie(session))
    await store.receive(\.reauthResponse.success)
    await store.receive(\.delegate, .reauthenticated(connection: expected, sameUser: false))
  }

  @Test func badCredentialsSurfaceInvalidCredentials() async {
    let store = TestStore(
      initialState: ReauthFeature.State(
        serverURL: url, method: .password, provider: "basic",
        previousUsername: "alice", username: "alice", password: "wrong"
      )
    ) {
      ReauthFeature()
    } withDependencies: {
      $0.hermesREST.passwordLogin = { @Sendable _, _, _, _ in throw RESTError.unauthorized }
    }

    await store.send(.signInTapped) { $0.status = .validating }
    await store.receive(\.reauthResponse.failure) { $0.status = .invalidCredentials }
  }

  @Test func rateLimitedSurfacesServerCopy() async {
    let store = TestStore(
      initialState: ReauthFeature.State(
        serverURL: url, method: .password, provider: "basic",
        previousUsername: "alice", username: "alice", password: "pw"
      )
    ) {
      ReauthFeature()
    } withDependencies: {
      $0.hermesREST.passwordLogin = { @Sendable _, _, _, _ in throw RESTError.rateLimited }
    }

    await store.send(.signInTapped) { $0.status = .validating }
    await store.receive(\.reauthResponse.failure) {
      $0.status = .failed(RESTError.rateLimited.message)
    }
  }

  // MARK: - Token re-auth parity (identity compare skipped)

  @Test func tokenReauthValidatesAndReportsSameUser() async {
    let store = TestStore(
      initialState: ReauthFeature.State(serverURL: url, method: .token, token: "newtok")
    ) {
      ReauthFeature()
    } withDependencies: {
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in [] }
    }

    await store.send(.signInTapped) { $0.status = .validating }
    let expected = ServerConnection(baseURL: url, token: "newtok")
    await store.receive(\.reauthResponse.success)
    await store.receive(\.delegate, .reauthenticated(connection: expected, sameUser: true))
  }

  // MARK: - Quit

  @Test func quitBubblesQuitDelegate() async {
    let store = TestStore(
      initialState: ReauthFeature.State(serverURL: url, method: .password, previousUsername: "alice")
    ) {
      ReauthFeature()
    }

    await store.send(.quitTapped)
    await store.receive(\.delegate.quit)
  }
}
