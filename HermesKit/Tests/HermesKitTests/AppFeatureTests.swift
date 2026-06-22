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

  // MARK: Push cleanup on logout (Task C4)

  @Test func disconnectUnregistersPushAndClearsPushState() async {
    let unregistered = LockIsolated<String?>(nil)
    let tokenCleared = LockIsolated(false)
    let store = TestStore(
      initialState: AppFeature.State(home: SessionListFeature.State(connection: connection))
    ) {
      AppFeature()
    } withDependencies: {
      $0.preferences.loadPushDeviceToken = { "cafef00d" }
      $0.preferences.clearPushDeviceToken = { @Sendable in tokenCleared.setValue(true) }
      $0.hermesREST.unregisterPush = { @Sendable _, token in unregistered.setValue(token) }
    }
    store.exhaustivity = .off

    await store.send(.home(.delegate(.disconnect))) {
      $0.home = nil
    }
    await store.finish()
    #expect(unregistered.value == "cafef00d") // best-effort unregister with the stored token
    #expect(tokenCleared.value) // device-token pref wiped
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

  // MARK: Event-driven working glow routing (Task 7)

  // The open chat's `runningChanged` delegate is routed to the session list, which patches the
  // row's working flag (glow) INSTANTLY — no poll required.
  @Test func chatRunningChangedRoutesToSessionListGlow() async {
    var path = StackState<ChatFeature.State>()
    path.append(ChatFeature.State(connection: connection, resumeStoredID: "s1"))
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(
          connection: connection,
          sessions: [Session(id: "s1", isActive: true)]
        ),
        path: path
      )
    ) {
      AppFeature()
    }
    let id = store.state.path.ids[0]

    // A finished turn in the open chat → clear the row glow immediately.
    await store.send(.path(.element(id: id, action: .delegate(.runningChanged(sessionID: "s1", running: false)))))
    await store.receive(\.home.setSessionRunning) {
      $0.home?.sessions[id: "s1"]?.isActive = false
    }

    // A started turn → light it again.
    await store.send(.path(.element(id: id, action: .delegate(.runningChanged(sessionID: "s1", running: true)))))
    await store.receive(\.home.setSessionRunning) {
      $0.home?.sessions[id: "s1"]?.isActive = true
    }
  }

  // CRITICAL RULE: painting a chat from its cache must NEVER start a list glow on its own. The
  // list only ever lights a glow from a server-confirmed source (the delegate above, or a poll).
  // Painting a chat from its cache (`ChatFeature.State.init` reading the snapshot) does NOT push
  // any `runningChanged` delegate, so no glow appears until the server confirms via
  // `session.resume`.
  @Test func cachedPaintAloneDoesNotGlow() async {
    let snapshotClient = ChatSnapshotClient.inMemory()
    // A persisted snapshot for the session (cache never carries a running hint).
    snapshotClient.saveSnapshot("s1", ChatSnapshot(
      model: "claude-opus-4-8",
      rows: [ChatRow(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, kind: .message(role: .user, text: "hi", isComplete: true))]
    ))

    // Opening the session paints the chat from cache (no server contact yet). The session list
    // row starts NOT active.
    var path = StackState<ChatFeature.State>()
    let painted = withDependencies {
      $0.chatSnapshot = snapshotClient
    } operation: {
      ChatFeature.State(connection: connection, resumeStoredID: "s1")
    }
    path.append(painted)

    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(
          connection: connection,
          sessions: [Session(id: "s1", isActive: false)]
        ),
        path: path
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.chatSnapshot = snapshotClient
    }

    // No delegate was emitted by the cache paint, so the glow stays off. (Sending `.task` on the
    // app would try to auto-connect; we only assert that no glow was set purely from the cache.)
    #expect(store.state.home?.sessions[id: "s1"]?.isActive == false)
  }

  // MARK: App lifecycle — scenePhase (Task 8)

  // `.active` (foreground) fans out: the open chat reconnects + re-activates (`.foreground`),
  // and the session list refreshes immediately (`.pulledToRefresh`) — no waiting for the poll.
  // The thin view scenePhase wiring isn't unit-tested; this `scenePhaseChanged` action is the
  // covered behaviour.
  @Test func foregroundReconnectsOpenChatAndRefreshesList() async {
    var path = StackState<ChatFeature.State>()
    path.append(ChatFeature.State(connection: connection, resumeStoredID: "s1"))
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection, sessions: [Session(id: "s1")]),
        path: path
      )
    ) {
      AppFeature()
    } withDependencies: {
      // The chat reconnect opens a never-yielding socket; the list refresh hits REST.
      $0.hermesGateway.connect = { @Sendable _, _ in AsyncStream { _ in } }
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in [] }
      $0.hermesProfiles.list = { @Sendable _ in throw RESTError.notFound }
      $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    let id = store.state.path.ids[0]

    await store.send(.scenePhaseChanged(.active))
    // Open chat told to reconnect + re-activate.
    await store.receive(\.path[id: id].foreground)
    // List refreshed immediately.
    await store.receive(\.home.pulledToRefresh)

    await store.send(.path(.element(id: id, action: .onDisappear)))
    await store.send(.home(.onDisappear))
  }

  // `.active` with no open chat still refreshes the list (and doesn't crash on the empty path).
  @Test func foregroundWithNoOpenChatStillRefreshesList() async {
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection)
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in [] }
      $0.hermesProfiles.list = { @Sendable _ in throw RESTError.notFound }
      $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.scenePhaseChanged(.active))
    await store.receive(\.home.pulledToRefresh)

    await store.send(.home(.onDisappear))
  }

  // `.background` routes `.persistNow` to the open chat, which flushes its snapshot + anchor to
  // the cache immediately (verified end-to-end via the in-memory snapshot store below).
  @Test func backgroundRoutesPersistNowToOpenChat() async {
    let snapshotClient = ChatSnapshotClient.inMemory()
    var chat = ChatFeature.State(connection: connection, resumeStoredID: "s1")
    chat.storedSessionID = "s1"
    chat.liveSessionID = "live1"
    chat.model = "claude-opus-4-8"
    var path = StackState<ChatFeature.State>()
    path.append(chat)

    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection, sessions: [Session(id: "s1")]),
        path: path
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.chatSnapshot = snapshotClient
      $0.date = .constant(Date(timeIntervalSince1970: 999))
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    let id = store.state.path.ids[0]

    await store.send(.scenePhaseChanged(.background))
    await store.receive(\.path[id: id].persistNow)

    // Snapshot was written synchronously (not waiting for the debounce).
    let saved = snapshotClient.loadSnapshot("s1")
    #expect(saved?.model == "claude-opus-4-8")
    #expect(saved?.updatedAt == Date(timeIntervalSince1970: 999))
  }

  // A turn in flight (`isSending`) when backgrounding reaffirms the turn-start anchor, so a kill
  // mid-turn keeps the elapsed-timer start instant for the next hydrate.
  @Test func backgroundMidTurnPersistsAnchor() async {
    let snapshotClient = ChatSnapshotClient.inMemory()
    var chat = ChatFeature.State(connection: connection, resumeStoredID: "s1")
    chat.storedSessionID = "s1"
    chat.liveSessionID = "live1"
    chat.isSending = true
    var path = StackState<ChatFeature.State>()
    path.append(chat)

    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection, sessions: [Session(id: "s1")]),
        path: path
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.chatSnapshot = snapshotClient
      $0.date = .constant(Date(timeIntervalSince1970: 4242))
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    let id = store.state.path.ids[0]

    #expect(snapshotClient.turnAnchor("s1") == nil)

    await store.send(.scenePhaseChanged(.background))
    await store.receive(\.path[id: id].persistNow)

    // Anchor written at the current date.
    #expect(snapshotClient.turnAnchor("s1") == Date(timeIntervalSince1970: 4242))
  }

  // `.inactive` is treated like background (immediate flush) — no foreground reconnect.
  @Test func inactiveFlushesSnapshot() async {
    let snapshotClient = ChatSnapshotClient.inMemory()
    var chat = ChatFeature.State(connection: connection, resumeStoredID: "s1")
    chat.storedSessionID = "s1"
    chat.liveSessionID = "live1"
    var path = StackState<ChatFeature.State>()
    path.append(chat)

    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection),
        path: path
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.chatSnapshot = snapshotClient
      $0.date = .constant(Date(timeIntervalSince1970: 7))
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    let id = store.state.path.ids[0]

    await store.send(.scenePhaseChanged(.inactive))
    await store.receive(\.path[id: id].persistNow)

    #expect(snapshotClient.loadSnapshot("s1")?.updatedAt == Date(timeIntervalSince1970: 7))
  }

  // MARK: Push tap deep-link + foreground suppression + badge (C5)

  /// A push tap routes through the SAME `openSession` delegate path a list tap uses, opening
  /// (resuming) the tapped session. A loaded `Session` is reused (so its title carries over);
  /// here the session isn't loaded, so a minimal `Session(id:)` is resumed.
  @Test func pushTapDeepLinksThroughOpenSession() async {
    let push = PushClient.inMemory()
    let store = TestStore(
      initialState: AppFeature.State(home: SessionListFeature.State(connection: connection))
    ) {
      AppFeature()
    } withDependencies: {
      $0.push = push.client
    }
    store.exhaustivity = .off

    await store.send(.pushTapped(PushTap(sessionID: "20260620_xyz")))
    await store.receive(\.home.delegate.openSession)
    #expect(store.state.path.last?.storedSessionID == "20260620_xyz")
    // The reducer marked the now-open session as currently-viewing (foreground suppression).
    #expect(push.currentSession == "20260620_xyz")
  }

  /// Feeding a tap through `PushClient.incomingTaps()` (the live bridge stream) drives the same
  /// deep-link — taps observed on `.task` and direct `.pushTapped` share one code path.
  @Test func incomingTapStreamDrivesDeepLink() async {
    let push = PushClient.inMemory()
    let store = TestStore(
      initialState: AppFeature.State(home: SessionListFeature.State(connection: connection))
    ) {
      AppFeature()
    } withDependencies: {
      // No stored creds → `.task` only starts the tap observer (no auto-connect).
      $0.keychain.loadSession = { @Sendable _ in nil }
      $0.preferences.loadServerURL = { nil }
      $0.push = push.client
    }
    store.exhaustivity = .off

    await store.send(.task)
    push.emit(tap: PushTap(sessionID: "from-stream"))
    await store.receive(\.pushTapped)
    await store.receive(\.home.delegate.openSession)
    #expect(store.state.path.last?.storedSessionID == "from-stream")
    // The tap observer is a long-running effect on the in-memory stream — drop it at teardown.
    await store.skipInFlightEffects()
  }

  /// Foreground suppression: opening a chat marks it currently-viewing; popping back to the list
  /// (empty path) clears the marker so a later foreground push presents again.
  @Test func openAndCloseChatSetsAndClearsCurrentViewingSession() async {
    let push = PushClient.inMemory()
    let store = TestStore(
      initialState: AppFeature.State(home: SessionListFeature.State(connection: connection))
    ) {
      AppFeature()
    } withDependencies: {
      $0.push = push.client
    }
    store.exhaustivity = .off
    let session = Session(id: "20260610_abc", title: "Chat")

    await store.send(.home(.delegate(.openSession(session))))
    await store.finish()
    #expect(push.currentSession == "20260610_abc")

    // Pop the chat (path empties) → current-viewing marker cleared.
    await store.send(.path(.popFrom(id: store.state.path.ids.last!)))
    await store.finish()
    #expect(push.currentSession == nil)
  }

  /// An approval tap with no session list yet (can't open) bumps the pending-approval badge;
  /// then opening that session clears it back to zero.
  @Test func approvalBadgeSetsWhenUnopenedAndClearsOnView() async {
    let push = PushClient.inMemory()
    // Onboarding (no home) — the tap can't open a session, so the badge reflects the pending approval.
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.push = push.client
    }
    store.exhaustivity = .off

    await store.send(.pushTapped(PushTap(sessionID: "s-approve", type: "approval"))) {
      $0.pendingApprovalSessionIDs = ["s-approve"]
    }
    await store.finish()
    #expect(push.badgeCount == 1) // badge shows the pending approval

    // Now sign in and open that session → badge clears.
    await store.send(.autoConnectSucceeded(connection)) {
      $0.home = SessionListFeature.State(connection: self.connection)
    }
    await store.send(.home(.delegate(.openSession(Session(id: "s-approve"))))) {
      $0.pendingApprovalSessionIDs = []
    }
    await store.finish()
    #expect(push.badgeCount == 0)
  }

  /// An approval tap that immediately opens its session nets to a zero badge (mark-then-clear).
  @Test func approvalTapThatOpensNetsZeroBadge() async {
    let push = PushClient.inMemory()
    let store = TestStore(
      initialState: AppFeature.State(home: SessionListFeature.State(connection: connection))
    ) {
      AppFeature()
    } withDependencies: {
      $0.push = push.client
    }
    store.exhaustivity = .off

    await store.send(.pushTapped(PushTap(sessionID: "s-approve", type: "approval")))
    await store.receive(\.home.delegate.openSession)
    await store.finish()
    #expect(push.badgeCount == 0)
    #expect(store.state.pendingApprovalSessionIDs.isEmpty)
  }

  /// Two distinct pending approvals → badge count 2; opening one → badge drops to 1.
  @Test func multiplePendingApprovalsSetBadgeThenClearOne() async {
    let push = PushClient.inMemory()
    // Onboarding (no home) so the approval taps can't open and just accumulate as pending.
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.push = push.client
    }
    store.exhaustivity = .off

    await store.send(.pushTapped(PushTap(sessionID: "s-one", type: "approval"))) {
      $0.pendingApprovalSessionIDs = ["s-one"]
    }
    await store.send(.pushTapped(PushTap(sessionID: "s-two", type: "approval"))) {
      $0.pendingApprovalSessionIDs = ["s-one", "s-two"]
    }
    await store.finish()
    #expect(push.badgeCount == 2) // two pending approvals

    // Sign in and open one of them → badge drops to the remaining pending count.
    await store.send(.autoConnectSucceeded(connection)) {
      $0.home = SessionListFeature.State(connection: self.connection)
    }
    await store.send(.home(.delegate(.openSession(Session(id: "s-one"))))) {
      $0.pendingApprovalSessionIDs = ["s-two"]
    }
    await store.finish()
    #expect(push.badgeCount == 1)
  }
}
