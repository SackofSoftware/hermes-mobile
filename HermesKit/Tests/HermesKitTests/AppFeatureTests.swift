import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

@MainActor
struct AppFeatureTests {
  private let connection = ServerConnection(baseURL: URL(string: "http://mac.tailnet:9119")!, token: "tok")

  // MARK: Launch auto-connect (Task 1)

  @Test func autoLoginWithStoredCredsOpensSessionList() async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.keychain.loadSession = { @Sendable _ in .token("tok") }
      $0.preferences.loadServerURL = { "http://mac.tailnet:9119" }
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in [] }
    }

    await store.send(.task) { $0.autoConnecting = true }
    await store.receive(\.autoConnectSucceeded) {
      $0.autoConnecting = false
      $0.home = SessionListFeature.State(connection: self.connection)
    }
  }

  /// A persisted **gated (cookie) session** must auto-restore on relaunch — the production
  /// path now reads `loadSession` (rehydrating cookies), not `loadToken` (which is `nil` for
  /// cookie sessions). Without this it would force the user through onboarding every launch.
  @Test func autoLoginWithStoredCookieSessionOpensSessionList() async {
    let cookieSession = CookieSession(
      cookies: [SerializedCookie(name: "hermes_session_at", value: "abc", domain: "mac.tailnet", path: "/")],
      username: "alice", provider: "basic"
    )
    let cookieConnection = ServerConnection(
      baseURL: URL(string: "http://mac.tailnet:9119")!, auth: .cookie(cookieSession)
    )
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.keychain.loadSession = { @Sendable _ in .cookie(cookieSession) }
      $0.preferences.loadServerURL = { "http://mac.tailnet:9119" }
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in [] }
    }

    await store.send(.task) { $0.autoConnecting = true }
    await store.receive(\.autoConnectSucceeded) {
      $0.autoConnecting = false
      $0.home = SessionListFeature.State(connection: cookieConnection)
    }
  }

  @Test func autoLoginWithInvalidTokenFallsBackToPrefilledOnboarding() async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.keychain.loadSession = { @Sendable _ in .token("bad") }
      $0.preferences.loadServerURL = { "http://mac.tailnet:9119" }
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in throw RESTError.unauthorized }
    }

    await store.send(.task) { $0.autoConnecting = true }
    await store.receive(\.autoConnectFailed) {
      $0.autoConnecting = false
      $0.onboarding = ConnectionFeature.State(serverURL: "http://mac.tailnet:9119", token: "bad")
    }
  }

  /// A dead **cookie** session falls back to onboarding with only the URL prefilled (the
  /// password is never persisted, so the token field stays empty).
  @Test func autoLoginWithDeadCookieSessionFallsBackToOnboarding() async {
    let cookieSession = CookieSession(cookies: [], username: "alice", provider: "basic")
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.keychain.loadSession = { @Sendable _ in .cookie(cookieSession) }
      $0.preferences.loadServerURL = { "http://mac.tailnet:9119" }
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in throw RESTError.unauthorized }
    }

    await store.send(.task) { $0.autoConnecting = true }
    await store.receive(\.autoConnectFailed) {
      $0.autoConnecting = false
      $0.onboarding = ConnectionFeature.State(serverURL: "http://mac.tailnet:9119", token: "")
    }
  }

  @Test func launchWithoutStoredCredsStaysOnOnboarding() async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.keychain.loadSession = { @Sendable _ in nil }
      $0.preferences.loadServerURL = { nil }
    }
    // No creds → no state change, no auto-connect effect.
    await store.send(.task)
  }

  @Test func connectingShowsSessionList() async {
    let store = TestStore(initialState: AppFeature.State()) { AppFeature() }

    await store.send(.onboarding(.delegate(.connected(connection)))) {
      $0.home = SessionListFeature.State(connection: self.connection)
    }
  }

  @Test func openingSessionPushesChat() async {
    let store = TestStore(
      initialState: AppFeature.State(home: SessionListFeature.State(connection: connection))
    ) {
      AppFeature()
    }
    let session = Session(id: "20260610_abc", title: "Protocol chat")

    await store.send(.home(.delegate(.openSession(session)))) {
      $0.path.append(
        ChatFeature.State(
          connection: self.connection,
          resumeStoredID: "20260610_abc",
          // Default profile → unscoped (nil), so the chat is byte-identical to single-profile.
          profileName: nil,
          title: "Protocol chat"
        )
      )
    }
  }

  @Test func creatingSessionPushesNewChat() async {
    let store = TestStore(
      initialState: AppFeature.State(home: SessionListFeature.State(connection: connection))
    ) {
      AppFeature()
    }

    await store.send(.home(.delegate(.createSession))) {
      $0.path.append(
        ChatFeature.State(connection: self.connection, profileName: nil)
      )
    }
  }

  @Test func openingSessionUnderCustomProfilePassesProfileToChat() async {
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(
          connection: connection, selectedProfileName: "work", profilesSupported: true
        )
      )
    ) {
      AppFeature()
    }
    let session = Session(id: "20260610_abc", title: "Protocol chat")

    await store.send(.home(.delegate(.openSession(session)))) {
      $0.path.append(
        ChatFeature.State(
          connection: self.connection,
          resumeStoredID: "20260610_abc",
          profileName: "work",
          title: "Protocol chat"
        )
      )
    }
  }

  @Test func creatingSessionUnderCustomProfilePassesProfileToChat() async {
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(
          connection: connection, selectedProfileName: "work", profilesSupported: true
        )
      )
    ) {
      AppFeature()
    }

    await store.send(.home(.delegate(.createSession))) {
      $0.path.append(
        ChatFeature.State(connection: self.connection, profileName: "work")
      )
    }
  }

  // MARK: - Re-auth routing (Task 6)

  private var cookieConnection: ServerConnection {
    ServerConnection(
      baseURL: URL(string: "http://mac.tailnet:9119")!,
      auth: .cookie(CookieSession(
        cookies: [SerializedCookie(name: "hermes_session_at", value: "old", domain: "mac.tailnet", path: "/")],
        username: "alice",
        provider: "basic"
      ))
    )
  }

  private func freshCookieConnection(username: String) -> ServerConnection {
    ServerConnection(
      baseURL: URL(string: "http://mac.tailnet:9119")!,
      auth: .cookie(CookieSession(
        cookies: [SerializedCookie(name: "hermes_session_at", value: "new", domain: "mac.tailnet", path: "/")],
        username: username,
        provider: "basic"
      ))
    )
  }

  @Test func sessionExpiredPresentsReauthModalSeededFromChat() async {
    var path = StackState<ChatFeature.State>()
    path.append(ChatFeature.State(connection: cookieConnection))
    let id = path.ids.last!
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: cookieConnection), path: path
      )
    ) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.path(.element(id: id, action: .delegate(.sessionExpired)))) {
      $0.reauth = ReauthFeature.State(
        serverURL: URL(string: "http://mac.tailnet:9119")!,
        method: .password,
        provider: "basic",
        previousUsername: "alice"
      )
    }
  }

  @Test func sameUserReauthResumesChatInPlace() async {
    var path = StackState<ChatFeature.State>()
    path.append(ChatFeature.State(connection: cookieConnection))
    let id = path.ids.last!
    let fresh = freshCookieConnection(username: "alice")
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: cookieConnection),
        path: path,
        reauth: ReauthFeature.State(
          serverURL: URL(string: "http://mac.tailnet:9119")!, method: .password,
          provider: "basic", previousUsername: "alice"
        )
      )
    ) {
      AppFeature()
    } withDependencies: {
      // A never-finishing socket so the resume's `connect` effect stays alive (no trailing
      // `gatewayClosed`/reconnect churn); we cancel it via `onDisappear` at the end.
      $0.hermesGateway.connect = { @Sendable _, _ in AsyncStream { _ in } }
    }
    store.exhaustivity = .off

    await store.send(.reauth(.presented(.delegate(.reauthenticated(connection: fresh, sameUser: true))))) {
      $0.reauth = nil
    }
    // Same user → the dead chat is told to resume with the fresh connection (stays in place).
    await store.receive(\.path) {
      $0.path[id: id]?.connection = fresh
      $0.path[id: id]?.awaitingReauth = false
      $0.path[id: id]?.status = .reconnecting
    }
    // Tear down the live socket the resume opened.
    await store.send(.path(.element(id: id, action: .onDisappear)))
  }

  @Test func differentUserReauthPopsToListAndClearsIdentityPrefs() async {
    var path = StackState<ChatFeature.State>()
    path.append(ChatFeature.State(connection: cookieConnection))
    let fresh = freshCookieConnection(username: "bob")
    let pinsCleared = LockIsolated(false)
    let seenCleared = LockIsolated(false)
    let profileCleared = LockIsolated(false)
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: cookieConnection),
        path: path,
        reauth: ReauthFeature.State(
          serverURL: URL(string: "http://mac.tailnet:9119")!, method: .password,
          provider: "basic", previousUsername: "alice"
        )
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.preferences.savePinnedIDs = { @Sendable ids in if ids.isEmpty { pinsCleared.setValue(true) } }
      $0.preferences.saveSeenCounts = { @Sendable c in if c.isEmpty { seenCleared.setValue(true) } }
      $0.preferences.clearSelectedProfileID = { @Sendable in profileCleared.setValue(true) }
    }
    store.exhaustivity = .off

    await store.send(.reauth(.presented(.delegate(.reauthenticated(connection: fresh, sameUser: false))))) {
      $0.reauth = nil
      $0.path = .init()
      $0.home = SessionListFeature.State(connection: fresh)
    }
    #expect(pinsCleared.value)
    #expect(seenCleared.value)
    #expect(profileCleared.value)
  }

  @Test func quitFromReauthFullyLogsOutToOnboarding() async {
    var path = StackState<ChatFeature.State>()
    path.append(ChatFeature.State(connection: cookieConnection))
    let sessionDeleted = LockIsolated(false)
    let urlCleared = LockIsolated(false)
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: cookieConnection),
        path: path,
        reauth: ReauthFeature.State(
          serverURL: URL(string: "http://mac.tailnet:9119")!, method: .password,
          provider: "basic", previousUsername: "alice"
        )
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.keychain.deleteSession = { @Sendable in sessionDeleted.setValue(true) }
      $0.preferences.clearServerURL = { @Sendable in urlCleared.setValue(true) }
    }
    store.exhaustivity = .off

    await store.send(.reauth(.presented(.delegate(.quit)))) {
      $0.reauth = nil
      $0.path = .init()
      $0.home = nil
      $0.onboarding = .init()
    }
    #expect(sessionDeleted.value)
    #expect(urlCleared.value)
  }

  @Test func tokenSessionExpiredSeedsTokenReauthModal() async {
    var path = StackState<ChatFeature.State>()
    path.append(ChatFeature.State(connection: connection)) // `.token` connection
    let id = path.ids.last!
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection), path: path
      )
    ) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.path(.element(id: id, action: .delegate(.sessionExpired)))) {
      $0.reauth = ReauthFeature.State(
        serverURL: URL(string: "http://mac.tailnet:9119")!, method: .token
      )
    }
  }

  // When the agent lacks the profiles API, a stale custom pref must NOT leak into chats —
  // `scopedProfileName` returns nil so the chat is unscoped (matches the unscoped list).
  @Test func customProfileDoesNotLeakIntoChatWhenProfilesUnsupported() async {
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(
          connection: connection, selectedProfileName: "work", profilesSupported: false
        )
      )
    ) {
      AppFeature()
    }

    await store.send(.home(.delegate(.createSession))) {
      $0.path.append(
        ChatFeature.State(connection: self.connection, profileName: nil)
      )
    }
  }
}
