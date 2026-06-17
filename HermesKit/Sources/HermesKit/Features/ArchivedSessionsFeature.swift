import ComposableArchitecture
import Foundation

/// The Archived sessions screen (presented as a sheet from the session list). Lists the
/// server's soft-archived sessions (`GET /api/sessions?archived=only`) and lets the user
/// **Restore** them (un-archive via the same `PATCH {archived:false}`) or **open** one
/// (bubbled up through `delegate.openSession`, so the main navigation stack resumes it).
@Reducer
public struct ArchivedSessionsFeature {
  @ObservableState
  public struct State: Equatable {
    public var connection: ServerConnection
    public var sessions: IdentifiedArrayOf<Session>
    public var isLoading: Bool
    public var loadError: String?
    /// Reference "now" for relative row timestamps (injected so it's controllable in tests).
    public var now: Date
    /// Ids whose restore (un-archive) PATCH is in flight — guards against a double tap.
    public var restoringIDs: Set<String>

    public init(
      connection: ServerConnection,
      sessions: IdentifiedArrayOf<Session> = [],
      isLoading: Bool = false,
      loadError: String? = nil,
      now: Date = Date(timeIntervalSince1970: 0),
      restoringIDs: Set<String> = []
    ) {
      self.connection = connection
      self.sessions = sessions
      self.isLoading = isLoading
      self.loadError = loadError
      self.now = now
      self.restoringIDs = restoringIDs
    }
  }

  public enum Action {
    case task
    case archivedResponse(Result<[Session], RESTError>)
    case restoreButtonTapped(id: Session.ID)
    /// Restore PATCH succeeded — the optimistic removal stands.
    case restoreSucceeded(id: Session.ID)
    /// Restore PATCH failed — re-insert the session at its saved index and surface the error.
    case restoreFailed(id: Session.ID, session: Session, index: Int)
    case sessionTapped(id: Session.ID)
    case delegate(Delegate)

    @CasePathable
    public enum Delegate {
      /// Open/resume an archived session — the parent dismisses the sheet and navigates.
      case openSession(Session)
    }
  }

  @Dependency(\.hermesREST) var rest
  @Dependency(\.date.now) var now

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .task:
        state.now = now
        state.isLoading = true
        state.loadError = nil
        return .run { [rest, connection = state.connection] send in
          do {
            let sessions = try await rest.archivedSessions(connection, 100, 0)
            await send(.archivedResponse(.success(sessions)))
          } catch let error as RESTError {
            await send(.archivedResponse(.failure(error)))
          } catch {
            await send(.archivedResponse(.failure(.unreachable)))
          }
        }

      case let .archivedResponse(.success(sessions)):
        state.isLoading = false
        state.loadError = nil
        // Drop any row whose restore is still in flight, so a refresh can't resurrect it.
        let visible = state.restoringIDs.isEmpty
          ? sessions
          : sessions.filter { !state.restoringIDs.contains($0.id) }
        state.sessions = IdentifiedArray(uniqueElements: visible)
        return .none

      case let .archivedResponse(.failure(error)):
        state.isLoading = false
        state.loadError = error.message
        return .none

      case let .restoreButtonTapped(id):
        guard let index = state.sessions.index(id: id) else { return .none }
        // Optimistic removal + in-flight guard; re-insert at `index` if the PATCH fails.
        let session = state.sessions[index]
        state.sessions.remove(id: id)
        state.restoringIDs.insert(id)
        return .run { [rest, connection = state.connection] send in
          do {
            try await rest.archive(connection, id, false, nil) // archived:false = restore
            await send(.restoreSucceeded(id: id))
          } catch {
            await send(.restoreFailed(id: id, session: session, index: index))
          }
        }

      case let .restoreSucceeded(id):
        state.restoringIDs.remove(id)
        return .none

      case let .restoreFailed(id, session, index):
        state.restoringIDs.remove(id)
        let insertAt = min(index, state.sessions.count)
        state.sessions.insert(session, at: insertAt)
        state.loadError = "Couldn’t restore the session."
        return .none

      case let .sessionTapped(id):
        guard let session = state.sessions[id: id] else { return .none }
        return .send(.delegate(.openSession(session)))

      case .delegate:
        return .none
      }
    }
  }
}
