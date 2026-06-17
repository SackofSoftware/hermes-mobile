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

    public init(
      onboarding: ConnectionFeature.State = .init(),
      home: SessionListFeature.State? = nil,
      path: StackState<ChatFeature.State> = .init(),
      autoConnecting: Bool = false
    ) {
      self.onboarding = onboarding
      self.home = home
      self.path = path
      self.autoConnecting = autoConnecting
    }
  }

  public enum Action {
    case task
    case autoConnectSucceeded(ServerConnection)
    case autoConnectFailed(url: String, token: String)
    case onboarding(ConnectionFeature.Action)
    case home(SessionListFeature.Action)
    case path(StackActionOf<ChatFeature>)
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
        // Launch auto-connect: if a token + server URL are persisted, silently
        // validate and skip onboarding. Only runs once, before we have a home.
        guard state.home == nil, !state.autoConnecting,
              let token = keychain.loadToken(), !token.isEmpty,
              let urlString = preferences.loadServerURL(),
              let url = parseServerURL(urlString)
        else { return .none }
        state.autoConnecting = true
        let connection = ServerConnection(baseURL: url, token: token)
        return .run { [rest] send in
          do {
            _ = try await rest.sessions(connection, 1, 0, .recent)
            await send(.autoConnectSucceeded(connection))
          } catch {
            await send(.autoConnectFailed(url: urlString, token: token))
          }
        }

      case let .autoConnectSucceeded(connection):
        state.autoConnecting = false
        state.home = SessionListFeature.State(connection: connection)
        return .none

      case let .autoConnectFailed(url, token):
        // Stored creds didn't validate (expired token / server moved) — fall back to
        // onboarding with the fields prefilled so the user can fix them.
        state.autoConnecting = false
        state.onboarding = ConnectionFeature.State(serverURL: url, token: token)
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

      case .onboarding, .home, .path:
        return .none
      }
    }
    .ifLet(\.home, action: \.home) {
      SessionListFeature()
    }
    .forEach(\.path, action: \.path) {
      ChatFeature()
    }
  }
}
