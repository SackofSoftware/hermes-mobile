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
    /// Last-seen message count per session id (persisted) — drives the unread indicator.
    public var seenCounts: [String: Int]
    /// Pinned session ids (persisted), order = display order in the top "Pinned" section.
    public var pinnedIDs: [String]
    /// Workspace group ids the user expanded past the collapsed limit.
    public var expandedGroups: Set<String>
    @Presents public var settings: SettingsFeature.State?

    /// Collapsed groups show at most this many rows before a "Show more".
    public static let collapsedLimit = 5

    public init(
      connection: ServerConnection,
      sessions: IdentifiedArrayOf<Session> = [],
      searchQuery: String = "",
      isLoading: Bool = false,
      loadError: String? = nil,
      now: Date = Date(timeIntervalSince1970: 0),
      seenCounts: [String: Int] = [:],
      pinnedIDs: [String] = [],
      expandedGroups: Set<String> = [],
      settings: SettingsFeature.State? = nil
    ) {
      self.connection = connection
      self.sessions = sessions
      self.searchQuery = searchQuery
      self.isLoading = isLoading
      self.loadError = loadError
      self.now = now
      self.seenCounts = seenCounts
      self.pinnedIDs = pinnedIDs
      self.expandedGroups = expandedGroups
      self.settings = settings
    }

    /// True while a search query is active — the list shows flat results, not workspace
    /// groups (search has no `cwd`).
    public var isSearching: Bool {
      !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Pinned sessions resolved from `pinnedIDs`, in pin order; stale ids are dropped.
    public var pinnedSessions: [Session] {
      pinnedIDs.compactMap { sessions[id: $0] }
    }

    /// Sessions not pinned — these feed the workspace grouping.
    public var unpinnedSessions: [Session] {
      let pinned = Set(pinnedIDs)
      return sessions.filter { !pinned.contains($0.id) }
    }

    /// Sessions grouped by workspace for the (non-search) list, desktop-style.
    /// Pinned sessions are excluded — they render in the top "Pinned" section.
    public var groups: [SessionGroup] {
      SessionGroup.grouped(unpinnedSessions)
    }

    /// Sessions with new activity since the user last opened them.
    public var unreadSessionIDs: Set<Session.ID> {
      Set(sessions.compactMap { session in
        guard let count = session.messageCount, let seen = seenCounts[session.id], count > seen
        else { return nil }
        return session.id
      })
    }

    /// Rows to show for a group given its collapsed/expanded state.
    public func visibleSessions(in group: SessionGroup) -> [Session] {
      guard !expandedGroups.contains(group.id), group.sessions.count > Self.collapsedLimit
      else { return group.sessions }
      return Array(group.sessions.prefix(Self.collapsedLimit))
    }
  }

  public enum Action: BindableAction {
    case binding(BindingAction<State>)
    case task
    case pulledToRefresh
    case sessionsResponse(Result<[Session], RESTError>)
    case sessionTapped(Session.ID)
    case newSessionButtonTapped
    case pinSession(id: Session.ID)
    case unpinSession(id: Session.ID)
    case toggleGroupExpansion(groupID: String)
    case settingsButtonTapped
    case settings(PresentationAction<SettingsFeature.Action>)
    case delegate(Delegate)

    @CasePathable
    public enum Delegate {
      case openSession(Session)
      case createSession
      case disconnect
    }
  }

  private enum CancelID { case search }

  @Dependency(\.hermesREST) var rest
  @Dependency(\.continuousClock) var clock
  @Dependency(\.date.now) var now
  @Dependency(\.preferences) var preferences

  public init() {}

  public var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .task, .pulledToRefresh:
        state.now = now
        state.isLoading = true
        state.loadError = nil
        state.seenCounts = preferences.loadSeenCounts()
        state.pinnedIDs = preferences.loadPinnedIDs()
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
        // Seed last-seen counts for newly-discovered sessions so they don't all show as
        // unread on first sight; only later increases flag unread.
        var seeded = false
        for session in sessions where state.seenCounts[session.id] == nil {
          state.seenCounts[session.id] = session.messageCount ?? 0
          seeded = true
        }
        guard seeded else { return .none }
        return persistSeenCounts(state.seenCounts)

      case let .sessionsResponse(.failure(error)):
        state.isLoading = false
        state.loadError = error.message
        return .none

      case let .sessionTapped(id):
        guard let session = state.sessions[id: id] else { return .none }
        // Opening clears the unread flag (mark seen at the current count).
        state.seenCounts[id] = session.messageCount ?? state.seenCounts[id] ?? 0
        return .merge(
          persistSeenCounts(state.seenCounts),
          .send(.delegate(.openSession(session)))
        )

      case let .pinSession(id):
        guard !state.pinnedIDs.contains(id) else { return .none }
        state.pinnedIDs.append(id)
        return persistPinnedIDs(state.pinnedIDs)

      case let .unpinSession(id):
        state.pinnedIDs.removeAll { $0 == id }
        return persistPinnedIDs(state.pinnedIDs)

      case let .toggleGroupExpansion(groupID):
        if !state.expandedGroups.insert(groupID).inserted {
          state.expandedGroups.remove(groupID)
        }
        return .none

      case .newSessionButtonTapped:
        return .send(.delegate(.createSession))

      case .settingsButtonTapped:
        state.settings = SettingsFeature.State(connection: state.connection)
        return .none

      case let .settings(.presented(.delegate(.tokenSaved(token)))):
        state.connection.token = token
        return .none

      case .settings(.presented(.delegate(.disconnect))):
        state.settings = nil
        return .send(.delegate(.disconnect))

      case .settings(.presented(.delegate(.reconnect))):
        // Manual reconnect = re-fetch the list over REST.
        return .send(.pulledToRefresh)

      case .settings:
        return .none

      case .delegate:
        return .none
      }
    }
    .ifLet(\.$settings, action: \.settings) {
      SettingsFeature()
    }
  }

  private func persistSeenCounts(_ counts: [String: Int]) -> Effect<Action> {
    .run { [preferences] _ in preferences.saveSeenCounts(counts) }
  }

  private func persistPinnedIDs(_ ids: [String]) -> Effect<Action> {
    .run { [preferences] _ in preferences.savePinnedIDs(ids) }
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
