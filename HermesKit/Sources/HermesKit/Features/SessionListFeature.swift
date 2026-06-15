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
    /// Ids whose archive PATCH is currently IN FLIGHT. Transient: an id is added when its
    /// PATCH starts and removed on BOTH success and failure. While an id is here, a list/search
    /// response that lands during the in-flight window filters it out (suppressing a stale row),
    /// and the poll skips. On success the in-flight fetch is cancelled so no stale response can
    /// land after the id is cleared; future authoritative fetches exclude archived sessions
    /// server-side (`archived=exclude`), so no permanent filter is needed.
    public var archivingIDs: Set<String>
    /// Ids whose rename PATCH is currently IN FLIGHT. Transient: added when the PATCH starts,
    /// removed on success/failure. While non-empty the poll skips (like `archivingIDs`) so a
    /// fetch landing mid-PATCH can't clobber the optimistic title with the server's old one.
    public var renamingInFlightIDs: Set<String>
    /// Session currently being renamed (drives the rename alert's presentation); nil = no alert.
    public var renamingID: Session.ID?
    /// The editable title text bound to the rename alert's `TextField`.
    public var renameDraft: String
    /// How the list groups its rows (workspace vs chronological); persisted, loaded on `task`.
    public var groupingMode: SessionGroupingMode
    @Presents public var settings: SettingsFeature.State?
    @Presents public var archived: ArchivedSessionsFeature.State?
    @Presents public var confirmationDialog: ConfirmationDialogState<Action.Dialog>?

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
      archivingIDs: Set<String> = [],
      renamingInFlightIDs: Set<String> = [],
      renamingID: Session.ID? = nil,
      renameDraft: String = "",
      groupingMode: SessionGroupingMode = .default,
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
      self.archivingIDs = archivingIDs
      self.renamingInFlightIDs = renamingInFlightIDs
      self.renamingID = renamingID
      self.renameDraft = renameDraft
      self.groupingMode = groupingMode
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

    /// Flat, last-active-ordered list of the unpinned sessions — the chronological mode's
    /// rows (pinned sessions still render in the top "Pinned" section). `nil` dates sort last.
    public var chronologicalSessions: [Session] {
      unpinnedSessions.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
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
    case onDisappear
    case pulledToRefresh
    case pollTick
    case sessionsResponse(Result<[Session], RESTError>)
    case sessionTapped(Session.ID)
    case newSessionButtonTapped
    case pinSession(id: Session.ID)
    case unpinSession(id: Session.ID)
    case toggleGroupExpansion(groupID: String)
    /// Switch the list grouping (workspace/chronological) and persist the choice.
    case setGroupingMode(SessionGroupingMode)
    case archiveButtonTapped(id: Session.ID)
    /// Archive RPC succeeded — clear the transient in-flight guard and cancel any fetch that
    /// started during the PATCH window so a stale response can't land after the guard is gone.
    case archiveSucceeded(id: Session.ID)
    /// Archive RPC failed — the server still has the session. Clear the in-flight guard and
    /// restore everything locally: re-insert the `session` at its saved `index`, restore the
    /// pin at `pinIndex` (nil if it wasn't pinned) and the prior `seenCount`, persist, and
    /// surface the error. Local restore guarantees the row is present regardless of network.
    case archiveFailed(id: Session.ID, session: Session, index: Int, pinIndex: Int?, seenCount: Int?)
    /// Open the rename alert for a row: seeds `renameDraft` with the row's current title.
    case renameButtonTapped(id: Session.ID)
    /// Commit the rename: optimistically update the row's title and fire the REST PATCH.
    case confirmRename
    /// Rename PATCH succeeded — the optimistic value stands.
    case renameSucceeded(id: Session.ID)
    /// Rename PATCH failed — restore `previousTitle` and surface the error.
    case renameFailed(id: Session.ID, previousTitle: String?)
    /// Dismiss the rename alert without applying changes.
    case cancelRename
    case confirmationDialog(PresentationAction<Dialog>)
    case settingsButtonTapped
    case settings(PresentationAction<SettingsFeature.Action>)
    /// Open the Archived sessions sheet (from the top-trailing menu).
    case archivedButtonTapped
    case archived(PresentationAction<ArchivedSessionsFeature.Action>)
    case delegate(Delegate)

    @CasePathable
    public enum Dialog: Equatable {
      case confirmArchive(id: Session.ID)
    }

    @CasePathable
    public enum Delegate {
      case openSession(Session)
      case createSession
      case disconnect
    }
  }

  // One id for BOTH the list fetch and the search fetch: any new fetch (list refresh, poll,
  // or search) cancels the previous in-flight one, so a late list response can't overwrite
  // active search results (and vice versa). `poll` is the separate timer loop.
  private enum CancelID { case fetch, poll }

  /// How often the list auto-refreshes while visible, to keep `isActive` (working glow) fresh.
  private static let pollInterval: Duration = .seconds(10)

  @Dependency(\.hermesREST) var rest
  @Dependency(\.continuousClock) var clock
  @Dependency(\.date.now) var now
  @Dependency(\.preferences) var preferences

  public init() {}

  public var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .task:
        // Load now AND start the auto-poll loop that keeps `isActive` fresh while visible.
        return .merge(
          load(&state),
          .run { [clock, interval = Self.pollInterval] send in
            while true {
              try await clock.sleep(for: interval)
              await send(.pollTick)
            }
          }
          .cancellable(id: CancelID.poll, cancelInFlight: true)
        )

      case .onDisappear:
        // Stop the poll (and any in-flight fetch / search debounce) when the list goes away.
        return .merge(
          .cancel(id: CancelID.poll),
          .cancel(id: CancelID.fetch)
        )

      case .pollTick:
        // Skip the auto-refresh while searching (don't fight the user's query), while an
        // archive is in flight (don't churn / risk resurrecting the archiving row), or while a
        // rename PATCH is in flight (a fetch could clobber the optimistic title with the old one).
        guard !state.isSearching, state.archivingIDs.isEmpty, state.renamingInFlightIDs.isEmpty
        else { return .none }
        return .send(.pulledToRefresh)

      case .pulledToRefresh:
        // A plain reload — does NOT (re)start the poll loop.
        return load(&state)

      case .binding(\.searchQuery):
        // Only the searchQuery binding drives the debounced fetch; other bound fields
        // (renameDraft) must NOT trigger a search.
        return .run { [rest, connection = state.connection, query = state.searchQuery, clock] send in
          try await clock.sleep(for: .milliseconds(300))
          await send(fetchSessions(rest: rest, connection: connection, query: query))
        }
        // Shared `fetch` id: cancels any in-flight list load so a late list response can't
        // overwrite these search results.
        .cancellable(id: CancelID.fetch, cancelInFlight: true)

      case .binding:
        // Other bindings (e.g. renameDraft) are pure state edits — no side effects.
        return .none

      case let .sessionsResponse(.success(sessions)):
        state.isLoading = false
        state.loadError = nil
        // Belt-and-suspenders: drop any session whose archive PATCH is still in flight, so a
        // fetch that completes during the PATCH window can't repopulate the removed row.
        let visible = state.archivingIDs.isEmpty
          ? sessions
          : sessions.filter { !state.archivingIDs.contains($0.id) }
        state.sessions = IdentifiedArray(uniqueElements: visible)
        // Seed last-seen counts for newly-discovered sessions so they don't all show as
        // unread on first sight; only later increases flag unread.
        var seeded = false
        for session in visible where state.seenCounts[session.id] == nil {
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

      case let .setGroupingMode(mode):
        guard state.groupingMode != mode else { return .none }
        state.groupingMode = mode
        return .run { [preferences] _ in preferences.saveGroupingMode(mode) }

      case let .toggleGroupExpansion(groupID):
        if !state.expandedGroups.insert(groupID).inserted {
          state.expandedGroups.remove(groupID)
        }
        return .none

      case let .archiveButtonTapped(id):
        state.confirmationDialog = ConfirmationDialogState {
          TextState("Archive session?")
        } actions: {
          ButtonState(role: .destructive, action: .confirmArchive(id: id)) {
            TextState("Archive")
          }
          ButtonState(role: .cancel) {
            TextState("Cancel")
          }
        } message: {
          TextState("This hides the session from the list. You can restore it from the server.")
        }
        return .none

      case let .confirmationDialog(.presented(.confirmArchive(id))):
        guard let index = state.sessions.index(id: id) else { return .none }
        // Capture rollback info BEFORE mutating: the session + its list index, the pin position
        // (if pinned) and prior seen baseline — so a failed RPC can restore everything locally.
        let session = state.sessions[index]
        let pinIndex = state.pinnedIDs.firstIndex(of: id)
        let seenCount = state.seenCounts[id]
        // Optimistic removal: drop from the list + clear its pin/seen entries, persist,
        // then run the RPC. On failure we re-insert and surface the error.
        state.sessions.remove(id: id)
        state.pinnedIDs.removeAll { $0 == id }
        state.seenCounts[id] = nil
        // Mark as in-flight so a fetch landing during the PATCH window filters it out and the
        // poll skips — closing the window where a reload could resurrect the removed row.
        state.archivingIDs.insert(id)
        let pinnedIDs = state.pinnedIDs
        let seenCounts = state.seenCounts
        // Cancel any in-flight fetch (list load OR search) too: one started before this
        // archive could land afterward and resurrect the row we just optimistically removed.
        return .merge(
          .cancel(id: CancelID.fetch),
          .run { [rest, preferences, connection = state.connection] send in
            preferences.savePinnedIDs(pinnedIDs)
            preferences.saveSeenCounts(seenCounts)
            do {
              try await rest.archive(connection, id, true)
              await send(.archiveSucceeded(id: id))
            } catch {
              await send(.archiveFailed(
                id: id, session: session, index: index, pinIndex: pinIndex, seenCount: seenCount
              ))
            }
          }
        )

      case .confirmationDialog:
        return .none

      case let .archiveSucceeded(id):
        // PATCH landed — clear the transient guard so the poll resumes. Cancel any fetch that
        // started during the PATCH window: with the guard now gone, its (stale) response could
        // otherwise resurrect the archived row. Future authoritative fetches exclude archived
        // sessions server-side (`archived=exclude`), so no permanent filter is needed.
        state.archivingIDs.remove(id)
        return .cancel(id: CancelID.fetch)

      case let .archiveFailed(id, session, index, pinIndex, seenCount):
        // The archive didn't take — the server still has the session. Lift the in-flight guard
        // and restore everything LOCALLY (no reliance on a reload): re-insert the session at its
        // saved index, restore the pin and seen baseline, persist, and surface the error. Local
        // restore guarantees the row is present regardless of network; a later poll/refresh
        // reconciles ordering/context (self-healing).
        state.archivingIDs.remove(id)
        let insertAt = min(index, state.sessions.count)
        state.sessions.insert(session, at: insertAt)
        if let pinIndex {
          let pinAt = min(pinIndex, state.pinnedIDs.count)
          state.pinnedIDs.insert(id, at: pinAt)
        }
        state.seenCounts[id] = seenCount
        state.loadError = "Couldn’t archive the session."
        preferences.savePinnedIDs(state.pinnedIDs)
        preferences.saveSeenCounts(state.seenCounts)
        return .none

      case let .renameButtonTapped(id):
        guard let session = state.sessions[id: id] else { return .none }
        state.renamingID = id
        state.renameDraft = session.title ?? ""
        return .none

      case .confirmRename:
        guard let id = state.renamingID, let session = state.sessions[id: id] else {
          state.renamingID = nil
          state.renameDraft = ""
          return .none
        }
        // Capture the previous title for rollback, then optimistically apply the trimmed draft
        // (an empty draft clears the title, mirroring the server's null/empty behaviour).
        let previousTitle = session.title
        let trimmed = state.renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        state.sessions[id: id]?.title = trimmed.isEmpty ? nil : trimmed
        state.renamingID = nil
        state.renameDraft = ""
        // Mark as in-flight (poll skips while set) and cancel any in-flight fetch — one started
        // before this PATCH could land mid-window and clobber the optimistic title with the
        // server's old one. Mirrors archive's protection.
        state.renamingInFlightIDs.insert(id)
        return .merge(
          .cancel(id: CancelID.fetch),
          .run { [rest, connection = state.connection] send in
            do {
              try await rest.rename(connection, id, trimmed)
              await send(.renameSucceeded(id: id))
            } catch {
              await send(.renameFailed(id: id, previousTitle: previousTitle))
            }
          }
        )

      case let .renameSucceeded(id):
        // PATCH landed — the optimistic title stands; lift the in-flight guard so the poll resumes.
        // Cancel any fetch that started during the PATCH window: with the guard now gone, its
        // (stale) response could otherwise clobber the optimistic title with the server's pre-rename
        // value. Mirrors archiveSucceeded's protection.
        state.renamingInFlightIDs.remove(id)
        return .cancel(id: CancelID.fetch)

      case let .renameFailed(id, previousTitle):
        // The rename didn't take (e.g. a 400 for an over-long/duplicate title) — lift the guard,
        // restore the previous title locally, and surface the error.
        state.renamingInFlightIDs.remove(id)
        state.sessions[id: id]?.title = previousTitle
        state.loadError = "Couldn’t rename the session."
        return .none

      case .cancelRename:
        state.renamingID = nil
        state.renameDraft = ""
        return .none

      case .newSessionButtonTapped:
        return .send(.delegate(.createSession))

      case .settingsButtonTapped:
        state.settings = SettingsFeature.State(connection: state.connection)
        return .none

      case .archivedButtonTapped:
        state.archived = ArchivedSessionsFeature.State(connection: state.connection, now: state.now)
        return .none

      case let .archived(.presented(.delegate(.openSession(session)))):
        // Open from the archived sheet → dismiss it and resume in the main stack.
        state.archived = nil
        return .send(.delegate(.openSession(session)))

      case .archived:
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
    .ifLet(\.$archived, action: \.archived) {
      ArchivedSessionsFeature()
    }
    .ifLet(\.$confirmationDialog, action: \.confirmationDialog)
  }

  /// Refresh "now", clear errors, reload persisted prefs, and fetch the session list.
  private func load(_ state: inout State) -> Effect<Action> {
    state.now = now
    state.isLoading = true
    state.loadError = nil
    state.seenCounts = preferences.loadSeenCounts()
    state.pinnedIDs = preferences.loadPinnedIDs()
    state.groupingMode = preferences.loadGroupingMode()
    return .run { [rest, connection = state.connection, query = state.searchQuery] send in
      await send(fetchSessions(rest: rest, connection: connection, query: query))
    }
    // Shared `fetch` id: a newer load/search/poll cancels this one, so an older in-flight
    // fetch finishing late can't overwrite `state.sessions` (stale list or search results).
    .cancellable(id: CancelID.fetch, cancelInFlight: true)
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
