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

  @Test func openingSessionFillsSlotAndPushesMarker() async {
    let store = TestStore(
      initialState: AppFeature.State(home: SessionListFeature.State(connection: connection))
    ) {
      AppFeature()
    }
    let session = Session(id: "20260610_abc", title: "Protocol chat")

    await store.send(.home(.delegate(.openSession(session)))) {
      // The chat state fills the app-level live slot; the path only gets a thin marker.
      $0.liveChat = ChatFeature.State(
        connection: self.connection,
        resumeStoredID: "20260610_abc",
        // Default profile → unscoped (nil), so the chat is byte-identical to single-profile.
        profileName: nil,
        title: "Protocol chat"
      )
      $0.path.append(ChatScreen.State(sessionKey: "20260610_abc"))
    }
  }

  @Test func creatingSessionFillsSlotWithNewChat() async {
    let store = TestStore(
      initialState: AppFeature.State(home: SessionListFeature.State(connection: connection))
    ) {
      AppFeature()
    }

    await store.send(.home(.delegate(.createSession(initialComposerText: nil)))) {
      $0.liveChat = ChatFeature.State(connection: self.connection, profileName: nil, composerText: "")
      // A brand-new chat has no session key yet — the marker resolves later.
      $0.path.append(ChatScreen.State(sessionKey: nil))
    }
  }

  @Test func creatingSessionWithPrefilledComposerSeedsDraft() async {
    let store = TestStore(
      initialState: AppFeature.State(home: SessionListFeature.State(connection: connection))
    ) {
      AppFeature()
    }

    await store.send(.home(.delegate(.createSession(initialComposerText: PushSetup.installPrompt)))) {
      $0.liveChat = ChatFeature.State(
        connection: self.connection, profileName: nil, composerText: PushSetup.installPrompt
      )
      $0.path.append(ChatScreen.State(sessionKey: nil))
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
      $0.liveChat = ChatFeature.State(
        connection: self.connection,
        resumeStoredID: "20260610_abc",
        profileName: "work",
        title: "Protocol chat"
      )
      $0.path.append(ChatScreen.State(sessionKey: "20260610_abc"))
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

    await store.send(.home(.delegate(.createSession(initialComposerText: nil)))) {
      $0.liveChat = ChatFeature.State(connection: self.connection, profileName: "work", composerText: "")
      $0.path.append(ChatScreen.State(sessionKey: nil))
    }
  }

  // MARK: - Live chat slot lifecycle (keep-alive plan, Tasks 1–2)

  /// Popping back to the list with an IDLE chat tears the slot down (nothing to keep
  /// alive): flush the snapshot, cancel everything, clear the slot.
  @Test func popTearsDownAndClearsSlot() async {
    let store = TestStore(
      initialState: AppFeature.State(home: SessionListFeature.State(connection: connection))
    ) {
      AppFeature()
    } withDependencies: {
      // The pop flushes the snapshot (`.persistNow`), which stamps `updatedAt`.
      $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off
    let session = Session(id: "s1", title: "Chat")

    await store.send(.home(.delegate(.openSession(session))))
    #expect(store.state.liveChat != nil)

    await store.send(.path(.popFrom(id: store.state.path.ids.last!)))
    await store.receive(\.liveChat.persistNow)
    await store.receive(\.liveChat.teardown)
    await store.receive(\.clearLiveChat) {
      $0.liveChat = nil
    }
    #expect(store.state.path.isEmpty)
  }

  /// Opening a different session while the slot is occupied flushes the old chat's snapshot
  /// and tears it down FIRST (its socket must not leak into the replacement), then fills the
  /// slot + resets the marker.
  @Test func openingAnotherSessionReplacesSlotAfterTeardown() async {
    let snapshotClient = ChatSnapshotClient.inMemory()
    var liveChat = ChatFeature.State(connection: connection, resumeStoredID: "old")
    liveChat.liveSessionID = "old-live"
    liveChat.model = "claude-opus-4-8"
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection),
        path: StackState([ChatScreen.State(sessionKey: "old")]),
        liveChat: liveChat
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.chatSnapshot = snapshotClient
      $0.date = .constant(Date(timeIntervalSince1970: 55))
    }
    store.exhaustivity = .off

    await store.send(.home(.delegate(.openSession(Session(id: "new", title: "New chat")))))
    await store.receive(\.liveChat.persistNow)
    await store.receive(\.liveChat.teardown)
    await store.receive(\.fillLiveChat) {
      $0.liveChat = ChatFeature.State(
        connection: self.connection, resumeStoredID: "new", profileName: nil, title: "New chat"
      )
    }
    #expect(store.state.path.count == 1)
    #expect(store.state.path.last?.sessionKey == "new")
    // The outgoing chat's snapshot was flushed before the replacement filled the slot.
    #expect(snapshotClient.loadSnapshot("old")?.model == "claude-opus-4-8")
  }

  /// Logout (disconnect from Settings) clears the slot unconditionally along with the path.
  @Test func disconnectClearsLiveChatSlot() async {
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection),
        path: StackState([ChatScreen.State(sessionKey: "s1")]),
        liveChat: ChatFeature.State(connection: connection, resumeStoredID: "s1")
      )
    ) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.home(.delegate(.disconnect))) {
      $0.home = nil
      $0.liveChat = nil
      $0.path = .init()
    }
    await store.finish()
  }

  /// Popping mid-turn KEEPS the slot untouched — no persist/teardown/clear fires (the send
  /// is exhaustive: any follow-up action would fail it), and the detached slot's fold still
  /// reduces streaming events, so rows keep accumulating while the user sits on the list.
  @Test func popWhileRunningKeepsSlotAndKeepsStreaming() async {
    var chat = ChatFeature.State(connection: connection, resumeStoredID: "s1")
    chat.liveSessionID = "live1"
    chat.isSending = true

    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection),
        path: StackState([ChatScreen.State(sessionKey: "s1")]),
        liveChat: chat
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
    }

    // Exhaustive: the pop only empties the path — the running slot is untouched.
    await store.send(.path(.popFrom(id: store.state.path.ids.last!))) {
      $0.path = StackState()
    }
    #expect(store.state.liveChat != nil)

    // A streaming delta arriving after the pop still mutates the detached slot's transcript
    // (the socket fold is slot-rooted, not screen-rooted).
    let rowID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    await store.send(.liveChat(.gatewayEvent(.messageDelta(text: "still streaming")))) {
      $0.liveChat?.transcript.append(ChatRow(
        id: rowID, kind: .message(role: .assistant, text: "still streaming", isComplete: false)
      ))
      $0.liveChat?.streamingRowID = rowID
    }
    // The delta's debounced persist is still pending — living proof the slot's effects
    // survived the pop. Cancel it via an explicit app-policy teardown at test end.
    await store.send(.liveChat(.teardown))
  }

  /// A detached slot (user popped to the list) is torn down the moment its turn ends — the
  /// authoritative `runningChanged(running: false)` (message.complete / error / a hydrate
  /// confirming stopped) flushes the snapshot, cancels the effects, and clears the slot.
  /// A `running: true` change must NOT tear anything down.
  @Test func turnEndingWhileDetachedTearsDownSlot() async {
    let snapshotClient = ChatSnapshotClient.inMemory()
    var chat = ChatFeature.State(connection: connection, resumeStoredID: "s1")
    chat.liveSessionID = "live1"
    chat.isSending = true
    chat.model = "claude-opus-4-8"

    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(
          connection: connection, sessions: [Session(id: "s1", isActive: true)]
        ),
        // Empty path — the chat streams detached.
        liveChat: chat
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.chatSnapshot = snapshotClient
      $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off

    // Still running → glow routing only; the detached slot stays.
    await store.send(.liveChat(.delegate(.runningChanged(sessionID: "s1", running: true))))
    await store.receive(\.home.setSessionRunning)
    #expect(store.state.liveChat != nil)

    // Turn ended while detached → glow clears, then flush + teardown + clear.
    await store.send(.liveChat(.delegate(.runningChanged(sessionID: "s1", running: false))))
    await store.receive(\.home.setSessionRunning) {
      $0.home?.sessions[id: "s1"]?.isActive = false
    }
    await store.receive(\.liveChat.persistNow)
    await store.receive(\.liveChat.teardown)
    await store.receive(\.clearLiveChat) {
      $0.liveChat = nil
    }
    // The snapshot flush landed before the slot cleared.
    #expect(snapshotClient.loadSnapshot("s1")?.model == "claude-opus-4-8")
  }

  /// Archiving the slot's session from the list tears the (detached) slot down FIRST — its
  /// socket must not keep streaming into a now-archived session. Archiving a DIFFERENT
  /// session leaves the slot alone.
  @Test func archivingSlotSessionTearsDownSlot() async {
    var chat = ChatFeature.State(connection: connection, resumeStoredID: "s1")
    chat.liveSessionID = "live1"
    chat.isSending = true

    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(
          connection: connection, sessions: [Session(id: "s1"), Session(id: "other")]
        ),
        // Empty path — the user is on the list (where archive lives).
        liveChat: chat
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.preferences = .inMemory()
      $0.hermesREST.archive = { @Sendable _, _, _, _ in }
      $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off

    // Archiving an unrelated session: the slot survives.
    await store.send(.home(.archiveButtonTapped(id: "other")))
    await store.send(.home(.confirmationDialog(.presented(.confirmArchive(id: "other")))))
    await store.receive(\.home.delegate.sessionArchived)
    await store.skipReceivedActions()
    #expect(store.state.liveChat != nil)

    // Archiving the slot's session: flush + teardown + clear.
    await store.send(.home(.archiveButtonTapped(id: "s1")))
    await store.send(.home(.confirmationDialog(.presented(.confirmArchive(id: "s1")))))
    await store.receive(\.home.delegate.sessionArchived)
    await store.receive(\.liveChat.persistNow)
    await store.receive(\.liveChat.teardown)
    await store.receive(\.clearLiveChat) {
      $0.liveChat = nil
    }
  }

  /// Re-opening the slot's OWN session from the list (tapping the glowing row of a detached
  /// running turn) must NOT build a fresh `ChatFeature.State` — the accumulated detached
  /// rows and composer draft survive. The marker is pushed back and `.reattached` hydrates
  /// against the live socket without redialing it.
  @Test func reopeningSlotSessionReattachesKeepingDetachedRows() async {
    let connectCalls = LockIsolated(0)
    var chat = ChatFeature.State(connection: connection, resumeStoredID: "s1")
    chat.liveSessionID = "live1"
    chat.status = .ready
    chat.hasRequestedSession = true
    chat.hasStarted = true
    chat.isSending = true
    chat.composerText = "unsent draft"
    // Rows accumulated while detached: the live thinking row the server's payload can't
    // rebuild (#26) — a re-init would lose it.
    let thinkingID = UUID(uuidString: "00000000-0000-0000-0000-00000000AAAA")!
    chat.transcript = [
      ChatRow(id: thinkingID, kind: .thinking(
        reasoning: "detached reasoning", status: nil, elapsedSeconds: 3, isComplete: false
      ))
    ]
    chat.thinkingRowID = thinkingID

    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection, sessions: [Session(id: "s1")]),
        // Empty path — the user popped to the list; the slot streams detached.
        liveChat: chat
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.connect = { @Sendable _, _ in
        connectCalls.withValue { $0 += 1 }
        return AsyncStream { _ in }
      }
      $0.hermesGateway.send = { @Sendable method, _ in
        // The hydrate may fan out a follow-up (e.g. `session.usage`) — only the resume
        // payload matters here.
        guard method == "session.resume" else { return .object([:]) }
        return .object([
          "session_id": .string("live1"),
          "stored_session_id": .string("s1"),
          "messages": .array([
            .object(["id": .number(1), "role": .string("user"), "content": .string("the question")]),
          ]),
          "running": .bool(true),
          "info": .object(["model": .string("claude-opus-4-8")]),
        ])
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.home(.delegate(.openSession(Session(id: "s1")))))
    // Marker re-pushed; the slot state itself was NOT re-inited (draft survives).
    #expect(store.state.path.count == 1)
    #expect(store.state.path.last?.sessionKey == "s1")
    #expect(store.state.liveChat?.composerText == "unsent draft")

    await store.receive(\.liveChat.reattached)
    await store.receive(\.liveChat.activateResult.success)

    // The healthy socket was never redialed, the hydrate landed, and the detached live
    // thinking row survived the server-authoritative rebuild (#26 preservation).
    #expect(connectCalls.value == 0)
    #expect(store.state.liveChat?.model == "claude-opus-4-8")
    #expect(store.state.liveChat?.composerText == "unsent draft")
    #expect(store.state.liveChat?.transcript.contains { row in
      if case let .thinking(reasoning, _, _, isComplete) = row.kind {
        return reasoning == "detached reasoning" && !isComplete
      }
      return false
    } == true)

    await store.send(.liveChat(.teardown))
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
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: cookieConnection),
        path: StackState([ChatScreen.State()]),
        liveChat: ChatFeature.State(connection: cookieConnection)
      )
    ) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.liveChat(.delegate(.sessionExpired))) {
      $0.reauth = ReauthFeature.State(
        serverURL: URL(string: "http://mac.tailnet:9119")!,
        method: .password,
        provider: "basic",
        previousUsername: "alice"
      )
    }
  }

  /// The slot chat can be DETACHED (user popped to the list) when the session dies — the
  /// re-auth modal must still surface at root (locked decision: reauth surfaces at root
  /// even while detached).
  @Test func sessionExpiredWhileDetachedStillPresentsReauthModal() async {
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: cookieConnection),
        // Empty path — the chat lives only in the slot.
        liveChat: ChatFeature.State(connection: cookieConnection)
      )
    ) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.liveChat(.delegate(.sessionExpired))) {
      $0.reauth = ReauthFeature.State(
        serverURL: URL(string: "http://mac.tailnet:9119")!,
        method: .password,
        provider: "basic",
        previousUsername: "alice"
      )
    }
  }

  @Test func sameUserReauthResumesChatInPlace() async {
    let fresh = freshCookieConnection(username: "alice")
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: cookieConnection),
        path: StackState([ChatScreen.State()]),
        liveChat: ChatFeature.State(connection: cookieConnection),
        reauth: ReauthFeature.State(
          serverURL: URL(string: "http://mac.tailnet:9119")!, method: .password,
          provider: "basic", previousUsername: "alice"
        )
      )
    ) {
      AppFeature()
    } withDependencies: {
      // A never-finishing socket so the resume's `connect` effect stays alive (no trailing
      // `gatewayClosed`/reconnect churn); we cancel it via `.teardown` at the end.
      $0.hermesGateway.connect = { @Sendable _, _ in AsyncStream { _ in } }
    }
    store.exhaustivity = .off

    await store.send(.reauth(.presented(.delegate(.reauthenticated(connection: fresh, sameUser: true))))) {
      $0.reauth = nil
    }
    // Same user → the slot chat is told to resume with the fresh connection (stays in place).
    await store.receive(\.liveChat.resumeAfterReauth) {
      $0.liveChat?.connection = fresh
      $0.liveChat?.awaitingReauth = false
      $0.liveChat?.status = .reconnecting
    }
    // Tear down the live socket the resume opened.
    await store.send(.liveChat(.teardown))
  }

  @Test func differentUserReauthPopsToListAndClearsIdentityPrefs() async {
    let fresh = freshCookieConnection(username: "bob")
    let pinsCleared = LockIsolated(false)
    let seenCleared = LockIsolated(false)
    let profileCleared = LockIsolated(false)
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: cookieConnection),
        path: StackState([ChatScreen.State()]),
        liveChat: ChatFeature.State(connection: cookieConnection),
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
      $0.liveChat = nil
      $0.home = SessionListFeature.State(connection: fresh)
    }
    #expect(pinsCleared.value)
    #expect(seenCleared.value)
    #expect(profileCleared.value)
  }

  @Test func quitFromReauthFullyLogsOutToOnboarding() async {
    let sessionDeleted = LockIsolated(false)
    let urlCleared = LockIsolated(false)
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: cookieConnection),
        path: StackState([ChatScreen.State()]),
        liveChat: ChatFeature.State(connection: cookieConnection),
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
      $0.liveChat = nil
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
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection),
        path: StackState([ChatScreen.State()]),
        liveChat: ChatFeature.State(connection: connection) // `.token` connection
      )
    ) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.liveChat(.delegate(.sessionExpired))) {
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

    await store.send(.home(.delegate(.createSession(initialComposerText: nil)))) {
      $0.liveChat = ChatFeature.State(connection: self.connection, profileName: nil, composerText: "")
      $0.path.append(ChatScreen.State(sessionKey: nil))
    }
  }

  // MARK: Event-driven working glow routing (Task 7)

  // The live chat's `runningChanged` delegate is routed to the session list, which patches the
  // row's working flag (glow) INSTANTLY — no poll required.
  @Test func chatRunningChangedRoutesToSessionListGlow() async {
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(
          connection: connection,
          sessions: [Session(id: "s1", isActive: true)]
        ),
        path: StackState([ChatScreen.State(sessionKey: "s1")]),
        liveChat: ChatFeature.State(connection: connection, resumeStoredID: "s1")
      )
    ) {
      AppFeature()
    }

    // A finished turn in the live chat → clear the row glow immediately.
    await store.send(.liveChat(.delegate(.runningChanged(sessionID: "s1", running: false))))
    await store.receive(\.home.setSessionRunning) {
      $0.home?.sessions[id: "s1"]?.isActive = false
    }

    // A started turn → light it again.
    await store.send(.liveChat(.delegate(.runningChanged(sessionID: "s1", running: true))))
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
    let painted = withDependencies {
      $0.chatSnapshot = snapshotClient
    } operation: {
      ChatFeature.State(connection: connection, resumeStoredID: "s1")
    }

    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(
          connection: connection,
          sessions: [Session(id: "s1", isActive: false)]
        ),
        path: StackState([ChatScreen.State(sessionKey: "s1")]),
        liveChat: painted
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

  // `.active` (foreground) fans out: the live chat reconnects + re-activates (`.foreground`),
  // and the session list refreshes immediately (`.pulledToRefresh`) — no waiting for the poll.
  // The thin view scenePhase wiring isn't unit-tested; this `scenePhaseChanged` action is the
  // covered behaviour.
  @Test func foregroundReconnectsOpenChatAndRefreshesList() async {
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection, sessions: [Session(id: "s1")]),
        path: StackState([ChatScreen.State(sessionKey: "s1")]),
        liveChat: ChatFeature.State(connection: connection, resumeStoredID: "s1")
      )
    ) {
      AppFeature()
    } withDependencies: {
      // The chat reconnect opens a never-yielding socket; the list refresh hits REST.
      $0.hermesGateway.connect = { @Sendable _, _ in AsyncStream { _ in } }
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in [] }
      $0.hermesREST.cronJobs = { @Sendable _, _ in throw RESTError.notFound }
      $0.hermesProfiles.list = { @Sendable _ in throw RESTError.notFound }
      $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.scenePhaseChanged(.active))
    // Live chat told to reconnect + re-activate.
    await store.receive(\.liveChat.foreground)
    // List refreshed immediately.
    await store.receive(\.home.pulledToRefresh)

    await store.send(.liveChat(.teardown))
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
      $0.hermesREST.cronJobs = { @Sendable _, _ in throw RESTError.notFound }
      $0.hermesProfiles.list = { @Sendable _ in throw RESTError.notFound }
      $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.scenePhaseChanged(.active))
    await store.receive(\.home.pulledToRefresh)

    await store.send(.home(.onDisappear))
  }

  // `.background` routes `.persistNow` to the live chat, which flushes its snapshot + anchor to
  // the cache immediately (verified end-to-end via the in-memory snapshot store below).
  @Test func backgroundRoutesPersistNowToOpenChat() async {
    let snapshotClient = ChatSnapshotClient.inMemory()
    var chat = ChatFeature.State(connection: connection, resumeStoredID: "s1")
    chat.storedSessionID = "s1"
    chat.liveSessionID = "live1"
    chat.model = "claude-opus-4-8"

    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection, sessions: [Session(id: "s1")]),
        path: StackState([ChatScreen.State(sessionKey: "s1")]),
        liveChat: chat
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.chatSnapshot = snapshotClient
      $0.date = .constant(Date(timeIntervalSince1970: 999))
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.scenePhaseChanged(.background))
    await store.receive(\.liveChat.persistNow)

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

    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection, sessions: [Session(id: "s1")]),
        path: StackState([ChatScreen.State(sessionKey: "s1")]),
        liveChat: chat
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.chatSnapshot = snapshotClient
      $0.date = .constant(Date(timeIntervalSince1970: 4242))
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    #expect(snapshotClient.turnAnchor("s1") == nil)

    await store.send(.scenePhaseChanged(.background))
    await store.receive(\.liveChat.persistNow)

    // Anchor written at the current date.
    #expect(snapshotClient.turnAnchor("s1") == Date(timeIntervalSince1970: 4242))
  }

  // `.inactive` is treated like background (immediate flush) — no foreground reconnect.
  @Test func inactiveFlushesSnapshot() async {
    let snapshotClient = ChatSnapshotClient.inMemory()
    var chat = ChatFeature.State(connection: connection, resumeStoredID: "s1")
    chat.storedSessionID = "s1"
    chat.liveSessionID = "live1"

    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection),
        path: StackState([ChatScreen.State(sessionKey: "s1")]),
        liveChat: chat
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.chatSnapshot = snapshotClient
      $0.date = .constant(Date(timeIntervalSince1970: 7))
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.scenePhaseChanged(.inactive))
    await store.receive(\.liveChat.persistNow)

    #expect(snapshotClient.loadSnapshot("s1")?.updatedAt == Date(timeIntervalSince1970: 7))
  }

  // MARK: Background grace window (Task 5)

  /// `.background` with a RUNNING turn begins the finite background window and leaves the
  /// socket streaming: the snapshot flush lands, the grace task starts, and a gateway event
  /// arriving while backgrounded still mutates the slot (nothing was torn down).
  @Test func backgroundWhileRunningBeginsGraceAndKeepsSocketStreaming() async {
    let background = BackgroundTaskClient.inMemory()
    let socketClosed = LockIsolated(false)
    var chat = ChatFeature.State(connection: connection, resumeStoredID: "s1")
    chat.liveSessionID = "live1"
    chat.isSending = true

    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection, sessions: [Session(id: "s1")]),
        path: StackState([ChatScreen.State(sessionKey: "s1")]),
        liveChat: chat
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.backgroundTask = background.client
      $0.chatSnapshot = .inMemory()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.hermesGateway.connect = { @Sendable _, _ in
        AsyncStream { continuation in
          continuation.onTermination = { _ in socketClosed.setValue(true) }
        }
      }
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in [] }
      $0.hermesREST.cronJobs = { @Sendable _, _ in throw RESTError.notFound }
      $0.hermesProfiles.list = { @Sendable _ in throw RESTError.notFound }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    // Dial the slot's socket (first appearance).
    await store.send(.liveChat(.task))

    await store.send(.scenePhaseChanged(.background))
    await store.receive(\.liveChat.persistNow)

    // The grace task was begun...
    while background.beginCount == 0 { await Task.yield() }
    #expect(background.activeTaskName == "hermes.chat.background-grace")
    // ...and the socket is untouched: a streaming delta still reduces into the slot.
    #expect(socketClosed.value == false)
    await store.send(.liveChat(.gatewayEvent(.messageDelta(text: "still streaming"))))
    #expect(store.state.liveChat?.transcript.isEmpty == false)

    // Cleanup: returning active cancels the grace listener + ends the task.
    await store.send(.scenePhaseChanged(.active))
    await store.send(.liveChat(.teardown))
    await store.send(.home(.onDisappear))
  }

  /// The window expiring while still backgrounded flushes the snapshot one final time,
  /// disconnects the socket cleanly (`.teardownSocketOnly` — cancelled, so no trailing
  /// `.gatewayClosed` backoff), ends the task, and RETAINS the chat state in memory —
  /// transcript, live thinking-row pointer, composer draft — so the foreground hydrate's
  /// #26 preservation still applies.
  @Test func graceExpiryDisconnectsSocketAndRetainsChatState() async {
    let background = BackgroundTaskClient.inMemory()
    let snapshotClient = ChatSnapshotClient.inMemory()
    let socketClosed = LockIsolated(false)
    var chat = ChatFeature.State(connection: connection, resumeStoredID: "s1")
    chat.liveSessionID = "live1"
    chat.isSending = true
    chat.model = "claude-opus-4-8"
    chat.composerText = "unsent draft"
    let thinkingID = UUID(uuidString: "00000000-0000-0000-0000-00000000AAAA")!
    chat.transcript = [
      ChatRow(id: thinkingID, kind: .thinking(
        reasoning: "live reasoning", status: nil, elapsedSeconds: 3, isComplete: false
      ))
    ]
    chat.thinkingRowID = thinkingID

    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection, sessions: [Session(id: "s1")]),
        path: StackState([ChatScreen.State(sessionKey: "s1")]),
        liveChat: chat
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.backgroundTask = background.client
      $0.chatSnapshot = snapshotClient
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.hermesGateway.connect = { @Sendable _, _ in
        AsyncStream { continuation in
          continuation.onTermination = { _ in socketClosed.setValue(true) }
        }
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.liveChat(.task))
    await store.send(.scenePhaseChanged(.background))
    await store.receive(\.liveChat.persistNow)
    while background.beginCount == 0 { await Task.yield() }

    // iOS expires the window while still backgrounded.
    background.expire()
    await store.receive(\.backgroundGraceExpired)
    await store.receive(\.liveChat.persistNow)
    await store.receive(\.liveChat.teardownSocketOnly) {
      $0.liveChat?.status = .reconnecting
    }

    // The socket effect was cancelled (stream terminated) with no `.gatewayClosed` backoff,
    // the task was ended, and the chat state survived in memory.
    while !socketClosed.value { await Task.yield() }
    #expect(background.endCount == 1)
    #expect(background.activeTaskName == nil)
    #expect(store.state.liveChat != nil)
    #expect(store.state.liveChat?.composerText == "unsent draft")
    #expect(store.state.liveChat?.thinkingRowID == thinkingID)
    #expect(store.state.liveChat?.transcript[id: thinkingID] != nil)
    // The final flush landed before the disconnect.
    #expect(snapshotClient.loadSnapshot("s1")?.model == "claude-opus-4-8")
  }

  /// Returning `.active` before the window expires ends the background task (and cancels
  /// the expiry listener) WITHOUT the grace teardown — no socket-only disconnect fires, and
  /// a stale expiry after the fact is a no-op. The existing `.foreground` fan-out runs
  /// unchanged.
  @Test func activeBeforeExpiryEndsGraceTaskWithoutSocketTeardown() async {
    let background = BackgroundTaskClient.inMemory()
    var chat = ChatFeature.State(connection: connection, resumeStoredID: "s1")
    chat.liveSessionID = "live1"
    chat.isSending = true

    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection, sessions: [Session(id: "s1")]),
        path: StackState([ChatScreen.State(sessionKey: "s1")]),
        liveChat: chat
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.backgroundTask = background.client
      $0.chatSnapshot = .inMemory()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.hermesGateway.connect = { @Sendable _, _ in AsyncStream { _ in } }
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in [] }
      $0.hermesREST.cronJobs = { @Sendable _, _ in throw RESTError.notFound }
      $0.hermesProfiles.list = { @Sendable _ in throw RESTError.notFound }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.scenePhaseChanged(.background))
    await store.receive(\.liveChat.persistNow)
    while background.beginCount == 0 { await Task.yield() }

    await store.send(.scenePhaseChanged(.active))
    await store.receive(\.liveChat.foreground)
    await store.receive(\.home.pulledToRefresh)

    // Task ended by `.active`; a stale expiry can no longer fire (nothing active).
    while background.endCount == 0 { await Task.yield() }
    #expect(background.activeTaskName == nil)
    background.expire()
    #expect(background.endCount == 1)
    // No socket-only disconnect happened (it would have flipped status to `.reconnecting`).
    #expect(store.state.liveChat?.status == .connecting)

    await store.send(.liveChat(.teardown))
    await store.send(.home(.onDisappear))
  }

  /// `.background` with an IDLE chat flushes only — no background task is begun (nothing to
  /// keep alive, no battery burn).
  @Test func backgroundWhileIdleStartsNoGraceTask() async {
    let background = BackgroundTaskClient.inMemory()
    var chat = ChatFeature.State(connection: connection, resumeStoredID: "s1")
    chat.liveSessionID = "live1"

    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection),
        path: StackState([ChatScreen.State(sessionKey: "s1")]),
        liveChat: chat
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.backgroundTask = background.client
      $0.chatSnapshot = .inMemory()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.scenePhaseChanged(.background))
    await store.receive(\.liveChat.persistNow)
    #expect(background.beginCount == 0)
  }

  /// `.background` with no slot at all is a no-op (exhaustive: no state change, no effects —
  /// in particular no background task).
  @Test func backgroundWithNoSlotIsNoOp() async {
    let background = BackgroundTaskClient.inMemory()
    let store = TestStore(
      initialState: AppFeature.State(home: SessionListFeature.State(connection: connection))
    ) {
      AppFeature()
    } withDependencies: {
      $0.backgroundTask = background.client
    }

    await store.send(.scenePhaseChanged(.background))
    #expect(background.beginCount == 0)
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
    #expect(store.state.liveChat?.storedSessionID == "20260620_xyz")
    #expect(store.state.path.last?.sessionKey == "20260620_xyz")
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
    #expect(store.state.liveChat?.storedSessionID == "from-stream")
    #expect(store.state.path.last?.sessionKey == "from-stream")
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
      // The pop flushes the snapshot (`.persistNow`), which stamps `updatedAt`.
      $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off
    let session = Session(id: "20260610_abc", title: "Chat")

    await store.send(.home(.delegate(.openSession(session))))
    await store.finish()
    #expect(push.currentSession == "20260610_abc")

    // Pop the chat (path empties) → current-viewing marker cleared (and, for now, the
    // slot is torn down unconditionally — Task 2 adds the keep-while-running policy).
    await store.send(.path(.popFrom(id: store.state.path.ids.last!)))
    // Drain the pop's follow-up actions (persistNow → teardown → clearLiveChat) so the
    // asserted state reflects the completed teardown.
    await store.skipReceivedActions()
    await store.finish()
    #expect(push.currentSession == nil)
    #expect(store.state.liveChat == nil)
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

  /// A tap for the session that is ALREADY on screen (slot match + marker in the path) must
  /// not navigate at all (#32) — no `openSession`, no duplicate marker, no slot re-init. An
  /// approval tap still runs its badge bookkeeping (mark-then-clear nets zero: the user is
  /// viewing the session).
  @Test func pushTapForOnScreenSessionDoesNotNavigate() async {
    let push = PushClient.inMemory()
    var chat = ChatFeature.State(connection: connection, resumeStoredID: "s1")
    chat.liveSessionID = "live1"

    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection),
        path: StackState([ChatScreen.State(sessionKey: "s1")]),
        liveChat: chat
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.push = push.client
    }

    // Exhaustive: any follow-up action (an `openSession`, a path mutation) would fail the
    // test. The approval's mark-then-clear leaves the state byte-identical; only the badge
    // side effect runs.
    await store.send(.pushTapped(PushTap(sessionID: "s1", type: "approval")))
    await store.finish()
    #expect(store.state.path.count == 1)
    #expect(store.state.path.last?.sessionKey == "s1")
    #expect(store.state.liveChat?.storedSessionID == "s1")
    #expect(push.badgeCount == 0)

    // A plain (non-approval) tap for the on-screen session is equally a no-nav no-op.
    await store.send(.pushTapped(PushTap(sessionID: "s1")))
    await store.finish()
    #expect(store.state.path.count == 1)
  }

  /// A tap matching the DETACHED slot's session (user popped to the list mid-turn) routes
  /// through `openSession`'s re-attach branch: the marker is pushed back exactly once (no
  /// duplicate) and the slot state — accumulated rows, composer draft — is NOT re-inited.
  @Test func pushTapForDetachedSlotSessionReattachesWithoutDuplicate() async {
    var chat = ChatFeature.State(connection: connection, resumeStoredID: "s1")
    chat.liveSessionID = "live1"
    chat.status = .ready
    chat.hasRequestedSession = true
    chat.hasStarted = true
    chat.composerText = "unsent draft"

    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection, sessions: [Session(id: "s1")]),
        // Empty path — the user is on the list; the slot streams detached.
        liveChat: chat
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable method, _ in
        guard method == "session.resume" else { return .object([:]) }
        return .object([
          "session_id": .string("live1"),
          "stored_session_id": .string("s1"),
          "messages": .array([]),
          "running": .bool(false),
        ])
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.pushTapped(PushTap(sessionID: "s1")))
    await store.receive(\.home.delegate.openSession)
    await store.receive(\.liveChat.reattached)
    // Marker pushed back exactly once; the slot state survived (no fresh `ChatFeature.State`).
    #expect(store.state.path.count == 1)
    #expect(store.state.path.last?.sessionKey == "s1")
    #expect(store.state.liveChat?.composerText == "unsent draft")

    await store.send(.liveChat(.teardown))
  }

  /// A tap for a DIFFERENT session while the slot is occupied replaces the slot (flush +
  /// teardown first) and SETS the path to the single new marker — never appends on top of
  /// the old one (#32's stacking bug).
  @Test func pushTapForDifferentSessionReplacesSlotAndSetsPath() async {
    var liveChat = ChatFeature.State(connection: connection, resumeStoredID: "old")
    liveChat.liveSessionID = "old-live"

    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection),
        path: StackState([ChatScreen.State(sessionKey: "old")]),
        liveChat: liveChat
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.chatSnapshot = .inMemory()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off

    await store.send(.pushTapped(PushTap(sessionID: "new")))
    await store.receive(\.home.delegate.openSession)
    await store.receive(\.liveChat.persistNow)
    await store.receive(\.liveChat.teardown)
    await store.receive(\.fillLiveChat)
    // Path SET, not appended: exactly one marker, pointing at the new session.
    #expect(store.state.path.count == 1)
    #expect(store.state.path.last?.sessionKey == "new")
    #expect(store.state.liveChat?.storedSessionID == "new")
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
