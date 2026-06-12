import ComposableArchitecture
import Foundation

/// Lists Hermes sessions for the connected server and supports full-text search.
/// Tapping a row or the "+" button emits a delegate the parent uses to open chat
/// (resume) or start a new session — `ChatFeature` wiring lands in Task 8.
@Reducer
public struct SessionListFeature {
  @ObservableState
  public struct State: Equatable {
    public var connection: ServerConnection
    public var sessions: IdentifiedArrayOf<Session>
    public var searchQuery: String
    public var isLoading: Bool
    public var loadError: String?
    /// Reference "now" for relative row timestamps; set from the date dependency on
    /// load so the value is controllable (deterministic snapshots/tests).
    public var now: Date

    public init(
      connection: ServerConnection,
      sessions: IdentifiedArrayOf<Session> = [],
      searchQuery: String = "",
      isLoading: Bool = false,
      loadError: String? = nil,
      now: Date = Date(timeIntervalSince1970: 0)
    ) {
      self.connection = connection
      self.sessions = sessions
      self.searchQuery = searchQuery
      self.isLoading = isLoading
      self.loadError = loadError
      self.now = now
    }
  }

  public enum Action: BindableAction {
    case binding(BindingAction<State>)
    case task
    case pulledToRefresh
    case sessionsResponse(Result<[Session], RESTError>)
    case sessionTapped(Session.ID)
    case newSessionButtonTapped
    case delegate(Delegate)

    @CasePathable
    public enum Delegate {
      case openSession(Session)
      case createSession
    }
  }

  private enum CancelID { case search }

  @Dependency(\.hermesREST) var rest
  @Dependency(\.continuousClock) var clock
  @Dependency(\.date.now) var now

  public init() {}

  public var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .task, .pulledToRefresh:
        state.now = now
        state.isLoading = true
        state.loadError = nil
        return .run { [rest, connection = state.connection, query = state.searchQuery] send in
          await send(fetchSessions(rest: rest, connection: connection, query: query))
        }

      case .binding:
        // searchQuery is the only bound field; debounce so each keystroke doesn't fire.
        return .run { [rest, connection = state.connection, query = state.searchQuery, clock] send in
          try await clock.sleep(for: .milliseconds(300))
          await send(fetchSessions(rest: rest, connection: connection, query: query))
        }
        .cancellable(id: CancelID.search, cancelInFlight: true)

      case let .sessionsResponse(.success(sessions)):
        state.isLoading = false
        state.loadError = nil
        state.sessions = IdentifiedArray(uniqueElements: sessions)
        return .none

      case let .sessionsResponse(.failure(error)):
        state.isLoading = false
        state.loadError = error.message
        return .none

      case let .sessionTapped(id):
        guard let session = state.sessions[id: id] else { return .none }
        return .send(.delegate(.openSession(session)))

      case .newSessionButtonTapped:
        return .send(.delegate(.createSession))

      case .delegate:
        return .none
      }
    }
  }

}

/// Fetch the list (or search results when a query is present) and map to a response.
private func fetchSessions(
  rest: HermesRESTClient,
  connection: ServerConnection,
  query rawQuery: String
) async -> SessionListFeature.Action {
  let query = rawQuery.trimmingCharacters(in: .whitespaces)
  do {
    let sessions = query.isEmpty
      ? try await rest.sessions(connection, 50, 0, .recent)
      : try await rest.search(connection, query)
    return .sessionsResponse(.success(sessions))
  } catch let error as RESTError {
    return .sessionsResponse(.failure(error))
  } catch {
    return .sessionsResponse(.failure(.unreachable))
  }
}
