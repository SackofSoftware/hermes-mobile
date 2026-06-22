import ComposableArchitecture

/// Root feature: onboarding until connected, then a session list that pushes chat
/// screens. Wires the child features together via their delegate actions.
@Reducer
public struct AppFeature {
  @ObservableState
  public struct State: Equatable {
    public var onboarding: ConnectionFeature.State
    public var home: SessionListFeature.State?
    public var path: StackState<ChatFeature.State>
    /// True during the launch auto-connect probe — `AppView` shows a brief placeholder
    /// instead of flashing the onboarding screen.
    public var autoConnecting: Bool
    /// The re-auth modal, presented when a live (gated) session dies mid-use. While shown,
    /// the dead chat's reconnect stays paused (it pauses itself via `awaitingReauth`).
    @Presents public var reauth: ReauthFeature.State?
    /// Session ids with a pending approval surfaced via a push tap, not yet viewed. The app-icon
    /// badge mirrors `pendingApprovalSessionIDs.count`; tapping/opening a session clears its
    /// entry (and recomputes the badge). A small dedicated count — distinct from the list's
    /// per-session *unread* (`seenCounts`) concept, which tracks message deltas, not approvals.
    public var pendingApprovalSessionIDs: Set<String>

    public init(
      onboarding: ConnectionFeature.State = .init(),
      home: SessionListFeature.State? = nil,
      path: StackState<ChatFeature.State> = .init(),
      autoConnecting: Bool = false,
      reauth: ReauthFeature.State? = nil,
      pendingApprovalSessionIDs: Set<String> = []
    ) {
      self.onboarding = onboarding
      self.home = home
      self.path = path
      self.autoConnecting = autoConnecting
      self.reauth = reauth
      self.pendingApprovalSessionIDs = pendingApprovalSessionIDs
    }

    /// The session the user is currently viewing — the top chat's session key
    /// (`storedSessionID ?? liveSessionID`), or `nil` when no chat is open (or a new chat whose
    /// id hasn't resolved yet). Drives foreground push suppression via `.onChange`.
    var currentViewingSessionID: String? {
      path.last.flatMap { $0.storedSessionID ?? $0.liveSessionID }
    }
  }

  /// App lifecycle phase, mirrored from SwiftUI's `ScenePhase` by the thin app shell so
  /// HermesKit never imports SwiftUI. The shell maps `.active/.inactive/.background` onto
  /// these cases and dispatches `scenePhaseChanged`.
  public enum ScenePhase: Equatable {
    case active
    case inactive
    case background
  }

  public enum Action {
    case task
    case autoConnectSucceeded(ServerConnection)
    case autoConnectFailed(ServerConnection)
    /// The app's scene phase changed (foreground/background) — observed at the app shell and
    /// fanned out: `.active` reconnects + re-hydrates the open chat and refreshes the list;
    /// `.background`/`.inactive` flushes the open chat's snapshot + anchor immediately.
    case scenePhaseChanged(ScenePhase)
    /// A push notification was tapped — deep-link to its session (same path as a list tap) and,
    /// for an approval, clear its pending-approval badge entry (the user is now viewing it).
    case pushTapped(PushTap)
    case onboarding(ConnectionFeature.Action)
    case home(SessionListFeature.Action)
    case path(StackActionOf<ChatFeature>)
    case reauth(PresentationAction<ReauthFeature.Action>)
  }

  /// One id for the long-running incoming-tap observer.
  private enum CancelID { case pushTaps }

  @Dependency(\.keychain) var keychain
  @Dependency(\.preferences) var preferences
  @Dependency(\.hermesREST) var rest
  @Dependency(\.push) var push

  public init() {}

  public var body: some ReducerOf<Self> {
    Scope(state: \.onboarding, action: \.onboarding) {
      ConnectionFeature()
    }
    Reduce { state, action in
      switch action {
      case .task:
        // Observe push taps for the whole app lifetime (a tap can arrive cold-launch or while
        // running) and deep-link them; the actual nav happens in `.pushTapped`.
        let tapObserver: Effect<Action> = .run { [push] send in
          for await tap in push.incomingTaps() {
            await send(.pushTapped(tap))
          }
        }
        .cancellable(id: CancelID.pushTaps, cancelInFlight: true)
        // Launch auto-connect: if a persisted session (token *or* gated cookie) + server
        // URL exist, silently validate and skip onboarding. Only runs once, before we have
        // a home. `loadSession` rehydrates a `.cookie` session's cookies into `.shared` so
        // the REST/WS transports authenticate on this fresh launch.
        guard state.home == nil, !state.autoConnecting,
              let session = keychain.loadSession(.shared),
              let urlString = preferences.loadServerURL(),
              let url = parseServerURL(urlString)
        else { return tapObserver }
        // A `.token` session with an empty token is treated as "no creds" (matches the old
        // `loadToken()`-non-empty guard) so we stay on onboarding rather than probe blindly.
        if case .token("") = session { return tapObserver }
        state.autoConnecting = true
        let connection = ServerConnection(baseURL: url, auth: session)
        return .merge(
          tapObserver,
          .run { [rest] send in
            do {
              _ = try await rest.sessions(connection, 1, 0, .recent)
              await send(.autoConnectSucceeded(connection))
            } catch {
              await send(.autoConnectFailed(connection))
            }
          }
        )

      case let .autoConnectSucceeded(connection):
        state.autoConnecting = false
        state.home = SessionListFeature.State(connection: connection)
        return .none

      case let .autoConnectFailed(connection):
        // Stored creds didn't validate (expired token / dead cookies / server moved) — fall
        // back to onboarding. Token mode prefills the fields so the user can fix them; cookie
        // mode prefills only the URL (the password is never persisted), so they re-enter it.
        state.autoConnecting = false
        state.onboarding = ConnectionFeature.State(
          serverURL: connection.baseURL.absoluteString,
          token: connection.auth.token ?? ""
        )
        return .none

      case let .scenePhaseChanged(phase):
        // Fan lifecycle out to the currently-open chat (top of the nav path, if any) and the
        // session list. We do NOT auto-restore the nav stack on cold launch — opening a session
        // is enough; this only re-syncs what's already on screen.
        let topChatID = state.path.ids.last
        switch phase {
        case .active:
          // Foreground: reconnect + re-hydrate (via `session.resume`) the open chat (re-reads
          // running/inflight/usage) and refresh the list immediately (don't wait for the poll).
          return .merge(
            topChatID.map { .send(.path(.element(id: $0, action: .foreground))) } ?? .none,
            state.home != nil ? .send(.home(.pulledToRefresh)) : .none
          )
        case .background, .inactive:
          // Backgrounding: flush the open chat's snapshot + anchor IMMEDIATELY (don't rely on
          // the 1s debounce) so a process kill can't lose the latest paint or the timer anchor.
          return topChatID.map { .send(.path(.element(id: $0, action: .persistNow))) } ?? .none
        }

      case let .pushTapped(tap):
        // Deep-link a tapped push to its session via the SAME path a list tap uses, so taps and
        // list-taps share one open-session flow. Prefer the loaded `Session` (carries a title);
        // fall back to a minimal `Session(id:)` if it isn't in the list (the chat resumes by
        // stored id and hydrates the title from `session.info`).
        //
        // Badge bookkeeping: an approval tap first MARKS the session pending (it's a relevant
        // approval), then opening it CLEARS that entry below — so a tap that opens nets to zero,
        // while an approval that can't be opened (no list yet) stays badged until viewed.
        if tap.isApproval {
          state.pendingApprovalSessionIDs.insert(tap.sessionID)
        }
        guard state.home != nil else {
          // No session list yet (e.g. still on onboarding) — can't open; the badge reflects the
          // now-pending approval.
          return setBadge(state)
        }
        let session = state.home?.sessions[id: tap.sessionID] ?? Session(id: tap.sessionID)
        // Opening clears the badge entry + marks current-viewing (handled in the openSession case).
        return .send(.home(.delegate(.openSession(session))))

      case let .onboarding(.delegate(.connected(connection))):
        state.home = SessionListFeature.State(connection: connection)
        return .none

      case let .home(.delegate(.openSession(session))):
        guard let home = state.home else { return .none }
        state.path.append(
          // `resolvedTitle` keeps the server's "Untitled" placeholder out of the header
          // (and the rename pre-fill); a real title arrives via `session.info` on resume.
          // Carry the active profile so resume/history scope to the right `state.db`.
          ChatFeature.State(
            connection: home.connection,
            resumeStoredID: session.id,
            profileName: home.scopedProfileName,
            title: session.resolvedTitle
          )
        )
        // Opening a session clears its pending-approval badge entry (the user is now viewing it).
        // The current-viewing marker is updated by the `.onChange(of: currentViewingSessionID)`
        // modifier below (one source of truth for nav-derived state).
        state.pendingApprovalSessionIDs.remove(session.id)
        return setBadge(state)

      case .home(.delegate(.createSession)):
        guard let home = state.home else { return .none }
        // New chats are created under the currently-selected profile.
        state.path.append(
          ChatFeature.State(connection: home.connection, profileName: home.scopedProfileName)
        )
        return .none

      case .home(.delegate(.disconnect)):
        // Token cleared in Settings → tear down and return to onboarding.
        let connection = state.home?.connection
        state.path = .init()
        state.home = nil
        state.onboarding = .init()
        return unregisterPushOnLogout(connection: connection)

      case .path(.element(id: _, action: .delegate(.sessionExpired))):
        // A live (gated) session died. The chat already paused its own reconnect; raise the
        // re-auth modal seeded from that chat's connection (server URL + regime + identity).
        // Ignore if a modal is already up (only the first dead session raises it).
        guard state.reauth == nil, let chat = state.path.last else { return .none }
        state.reauth = makeReauthState(for: chat.connection)
        return .none

      case let .reauth(.presented(.delegate(.reauthenticated(connection, sameUser)))):
        state.reauth = nil
        if sameUser {
          // Same user → resume the dead chat in place with the fresh auth regime.
          guard let id = state.path.ids.last else { return .none }
          return .send(.path(.element(id: id, action: .resumeAfterReauth(connection))))
        }
        // Different user signed in → drop everything identity-scoped and force a fresh list.
        preferences.clearIdentityScopedPrefs()
        state.path = .init()
        state.home = SessionListFeature.State(connection: connection)
        return .none

      case .reauth(.presented(.delegate(.quit))):
        // "Quit to start" → full logout (Keychain session + every pref) → onboarding.
        let connection = state.home?.connection ?? state.path.last?.connection
        try? keychain.deleteSession()
        preferences.clearServerURL()
        preferences.clearIdentityScopedPrefs()
        preferences.saveGroupingMode(.default)
        state.reauth = nil
        state.path = .init()
        state.home = nil
        state.onboarding = .init()
        return unregisterPushOnLogout(connection: connection)

      case let .path(.element(id: _, action: .delegate(.runningChanged(sessionID, running)))):
        // Route the open chat's authoritative working-state change to the session list so its
        // row glow clears/lights INSTANTLY (event-driven), without waiting for the next poll.
        // The poll stays the backstop for not-open sessions. No `home` → nothing to patch.
        guard state.home != nil else { return .none }
        return .send(.home(.setSessionRunning(id: sessionID, running: running)))

      case .onboarding, .home, .path, .reauth:
        return .none
      }
    }
    .ifLet(\.home, action: \.home) {
      SessionListFeature()
    }
    .ifLet(\.$reauth, action: \.reauth) {
      ReauthFeature()
    }
    .forEach(\.path, action: \.path) {
      ChatFeature()
    }
    // Keep the push bridge's "currently viewing" session in sync with the top of the nav stack
    // (one source of truth, evaluated AFTER the child reducers so pops/dismissals AND a new chat
    // resolving its `liveSessionID` are reflected) so a foreground push for the on-screen session
    // is suppressed. Opening, popping back to the list, and id-resolution all flow through here.
    .onChange(of: \.currentViewingSessionID) { _, newValue in
      Reduce { _, _ in
        .run { [push] _ in push.setCurrentSession(newValue) }
      }
    }
  }

  /// Best-effort push cleanup on logout: unregister the last-known device token with the
  /// agent's push plugin (failures ignored — the server prunes dead tokens on a 410 anyway),
  /// then clear the persisted push secret (Keychain) + token (prefs). Part of
  /// "logout clears everything". Uses the persisted token so it works even when the live
  /// `register()` stream isn't producing; a `nil` connection (nothing to talk to) still clears
  /// local push state.
  private func unregisterPushOnLogout(connection: ServerConnection?) -> Effect<AppFeature.Action> {
    let token = preferences.loadPushDeviceToken()
    preferences.clearPushDeviceToken()
    guard let connection, let token else { return .none }
    return .run { [rest] _ in
      try? await rest.unregisterPush(connection, token)
    }
  }

  /// Push the app-icon badge to the current pending-approval count (the only side effect; the
  /// count itself lives in `state.pendingApprovalSessionIDs`, kept testable in the reducer).
  private func setBadge(_ state: State) -> Effect<AppFeature.Action> {
    let count = state.pendingApprovalSessionIDs.count
    return .run { [push] _ in await push.setBadgeCount(count) }
  }

  /// Seed a `ReauthFeature.State` from the connection of the expired chat: a fixed server
  /// URL, the matching auth regime, and (cookie mode) the prefilled username + provider used
  /// for the same-user vs user-switch decision.
  private func makeReauthState(for connection: ServerConnection) -> ReauthFeature.State {
    switch connection.auth {
    case .token:
      return ReauthFeature.State(serverURL: connection.baseURL, method: .token)
    case let .cookie(session):
      return ReauthFeature.State(
        serverURL: connection.baseURL,
        method: .password,
        provider: session.provider,
        previousUsername: session.username
      )
    }
  }
}
