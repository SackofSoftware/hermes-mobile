import ComposableArchitecture
import Foundation

/// Settings sheet (Task 12): server info, token management (re-paste / clear), a manual
/// reconnect trigger, and a live feed of decoded gateway events for debugging.
///
/// Token-clear and reconnect are surfaced to the parent via delegates: clearing returns
/// the app to onboarding, reconnect reloads the session list.
@Reducer
public struct SettingsFeature {
  @ObservableState
  public struct State: Equatable {
    public var connection: ServerConnection
    public var token: String
    /// Transient confirmation after saving the token.
    public var savedConfirmation: Bool
    /// Live debug log, newest last; fed by `DebugLogClient`.
    public var log: [GatewayLogEntry]

    public init(connection: ServerConnection) {
      self.connection = connection
      self.token = connection.token ?? ""
      self.savedConfirmation = false
      self.log = []
    }

    public var serverURLString: String { connection.baseURL.absoluteString }
    public var canSaveToken: Bool {
      !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && token != connection.token
    }
  }

  public enum Action: BindableAction {
    case binding(BindingAction<State>)
    case task
    case logUpdated([GatewayLogEntry])
    case saveTokenTapped
    case clearTokenTapped
    case reconnectTapped
    case doneTapped
    case delegate(Delegate)

    @CasePathable
    public enum Delegate {
      case disconnect             // token cleared → back to onboarding
      case reconnect              // reload the session list
      case tokenSaved(String)     // re-pasted token persisted
    }
  }

  private enum CancelID { case logStream }

  @Dependency(\.keychain) var keychain
  @Dependency(\.preferences) var preferences
  @Dependency(\.debugLog) var debugLog
  @Dependency(\.dismiss) var dismiss

  public init() {}

  public var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .task:
        return .run { [debugLog] send in
          for await entries in debugLog.stream() {
            await send(.logUpdated(entries))
          }
        }
        .cancellable(id: CancelID.logStream, cancelInFlight: true)

      case let .logUpdated(entries):
        state.log = entries
        return .none

      case .binding(\.token):
        state.savedConfirmation = false
        return .none

      case .binding:
        return .none

      case .saveTokenTapped:
        guard state.canSaveToken else { return .none }
        let token = state.token
        state.connection.token = token
        state.savedConfirmation = true
        try? keychain.saveToken(token)
        return .send(.delegate(.tokenSaved(token)))

      case .clearTokenTapped:
        try? keychain.deleteToken()
        preferences.clearServerURL()
        return .merge(
          .send(.delegate(.disconnect)),
          .run { [dismiss] _ in await dismiss() }
        )

      case .reconnectTapped:
        return .merge(
          .send(.delegate(.reconnect)),
          .run { [dismiss] _ in await dismiss() }
        )

      case .doneTapped:
        return .run { [dismiss] _ in await dismiss() }

      case .delegate:
        return .none
      }
    }
  }
}
