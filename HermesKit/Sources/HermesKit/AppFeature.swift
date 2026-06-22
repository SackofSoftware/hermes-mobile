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

    public init(
      onboarding: ConnectionFeature.State = .init(),
      home: SessionListFeature.State? = nil,
      path: StackState<ChatFeature.State> = .init(),
      autoConnecting: Bool = false,
      reauth: ReauthFeature.State? = nil
    ) {
      self.onboarding = onboarding
      self.home = home
      self.path = path
      self.autoConnecting = autoConnecting
      self.reauth = reauth
    }
  }

  public enum Action {
    case task
    case autoConnectSucceeded(ServerConnection)
    case autoConnectFailed(ServerConnection)
    case onboarding(ConnectionFeature.Action)
    case home(SessionListFeature.Action)
    case path(StackActionOf<ChatFeature>)
    case reauth(PresentationAction<ReauthFeature.Action>)
  }

  @Dependency(\.keychain) var keychain
  @Dependency(\.preferences) var preferences
  @Dependency(\.hermesREST) var rest

  public init() {}

  public var body: some ReducerOf<Self> {
    Scope(state: \.onboarding, action: \.onboarding) {
      ConnectionFeature()
    }
    Reduce { state, action in
      switch action {
      case .task:
        // Launch auto-connect: if a persisted session (token *or* gated cookie) + server
        // URL exist, silently validate and skip onboarding. Only runs once, before we have
        // a home. `loadSession` rehydrates a `.cookie` session's cookies into `.shared` so
        // the REST/WS transports authenticate on this fresh launch.
        guard state.home == nil, !state.autoConnecting,
              let session = keychain.loadSession(.shared),
              let urlString = preferences.loadServerURL(),
              let url = parseServerURL(urlString)
        else { return .none }
        // A `.token` session with an empty token is treated as "no creds" (matches the old
        // `loadToken()`-non-empty guard) so we stay on onboarding rather than probe blindly.
        if case .token("") = session { return .none }
        state.autoConnecting = true
        let connection = ServerConnection(baseURL: url, auth: session)
        return .run { [rest] send in
          do {
            _ = try await rest.sessions(connection, 1, 0, .recent)
            await send(.autoConnectSucceeded(connection))
          } catch {
            await send(.autoConnectFailed(connection))
          }
        }

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
        return .none

      case .home(.delegate(.createSession)):
        guard let home = state.home else { return .none }
        // New chats are created under the currently-selected profile.
        state.path.append(
          ChatFeature.State(connection: home.connection, profileName: home.scopedProfileName)
        )
        return .none

      case .home(.delegate(.disconnect)):
        // Token cleared in Settings → tear down and return to onboarding.
        state.path = .init()
        state.home = nil
        state.onboarding = .init()
        return .none

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
        try? keychain.deleteSession()
        preferences.clearServerURL()
        preferences.clearIdentityScopedPrefs()
        preferences.saveGroupingMode(.default)
        state.reauth = nil
        state.path = .init()
        state.home = nil
        state.onboarding = .init()
        return .none

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
