import ComposableArchitecture

/// Root feature. For now a placeholder so the project generates and builds;
/// it will grow to own connection state and root navigation (ConnectionFeature,
/// SessionListFeature, ChatFeature, SettingsFeature) in later M1 tasks.
@Reducer
public struct AppFeature {
  @ObservableState
  public struct State: Equatable {
    public init() {}
  }

  public enum Action {
    case task
  }

  public init() {}

  public var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .task:
        return .none
      }
    }
  }
}
