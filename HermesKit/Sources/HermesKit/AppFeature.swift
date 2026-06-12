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

    public init(
      onboarding: ConnectionFeature.State = .init(),
      home: SessionListFeature.State? = nil,
      path: StackState<ChatFeature.State> = .init()
    ) {
      self.onboarding = onboarding
      self.home = home
      self.path = path
    }
  }

  public enum Action {
    case onboarding(ConnectionFeature.Action)
    case home(SessionListFeature.Action)
    case path(StackActionOf<ChatFeature>)
  }

  public init() {}

  public var body: some ReducerOf<Self> {
    Scope(state: \.onboarding, action: \.onboarding) {
      ConnectionFeature()
    }
    Reduce { state, action in
      switch action {
      case let .onboarding(.delegate(.connected(connection))):
        state.home = SessionListFeature.State(connection: connection)
        return .none

      case let .home(.delegate(.openSession(session))):
        guard let connection = state.home?.connection else { return .none }
        state.path.append(
          ChatFeature.State(connection: connection, resumeStoredID: session.id, title: session.title)
        )
        return .none

      case .home(.delegate(.createSession)):
        guard let connection = state.home?.connection else { return .none }
        state.path.append(ChatFeature.State(connection: connection))
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
