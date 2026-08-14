import ComposableArchitecture
import Foundation

/// The Archived sessions screen (presented as a sheet from the session list). Lists the
/// server's soft-archived sessions (`GET /api/sessions?archived=only`) and lets the user
/// **Restore** them (un-archive via the same `PATCH {archived:false}`), **Delete** them
/// permanently (immediate, no confirmation — this is the bulk-cleanup surface and the
/// rows are already tucked away), or **open** one (bubbled up through
/// `delegate.openSession`, so the main navigation stack resumes it).
@Reducer
public struct ArchivedSessionsFeature {
  @ObservableState
  public struct State: Equatable {
    public var connection: ServerConnection
    /// Active profile to scope the archived list/restore to — `nil` for the default
    /// profile or when profiles are unsupported (matches `scopedProfileName`). When set,
    /// listing/restore go through the profile-scoped endpoints so they hit the right
    /// profile's `state.db` rather than the default's.
    public var profileName: String?
    public var sessions: IdentifiedArrayOf<Session>
    public var isLoading: Bool
    public var loadError: String?
    /// Reference "now" for relative row timestamps (injected so it's controllable in tests).
    public var now: Date
    /// Ids whose restore (un-archive) PATCH is in flight — guards against a double tap.
    public var restoringIDs: Set<String>
    /// Ids whose permanent DELETE is in flight — same double-tap/refresh guard as restore.
    public var deletingIDs: Set<String>
    /// Whether the agent has the `DELETE /api/sessions/{id}` endpoint. Seeded from the
    /// session list's flag when the sheet is presented; a definitive 404/405 here flips
    /// it off for the rest of the sheet's lifetime (and mirrors back to the list via
    /// `delegate.deleteUnsupported`), hiding the Delete affordances.
    public var deleteSupported: Bool
    /// Non-`nil` while the transient "Session ID copied" toast is showing. Purely transient
    /// confirmation state: raised by a copy, cleared by the timed expiry. It's a counter
    /// rather than a `Bool` so a re-copy while the toast is already up is still an
    /// observable change — that's what re-announces the copy to VoiceOver (a `Bool` would
    /// stay `true` and the announcement would be swallowed).
    public var copiedIDToastToken: Int?

    public init(
      connection: ServerConnection,
      profileName: String? = nil,
      sessions: IdentifiedArrayOf<Session> = [],
      isLoading: Bool = false,
      loadError: String? = nil,
      now: Date = Date(timeIntervalSince1970: 0),
      restoringIDs: Set<String> = [],
      deletingIDs: Set<String> = [],
      deleteSupported: Bool = true,
      copiedIDToastToken: Int? = nil
    ) {
      self.connection = connection
      self.profileName = profileName
      self.sessions = sessions
      self.isLoading = isLoading
      self.loadError = loadError
      self.now = now
      self.restoringIDs = restoringIDs
      self.deletingIDs = deletingIDs
      self.deleteSupported = deleteSupported
      self.copiedIDToastToken = copiedIDToastToken
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
    /// Permanently delete a row — IMMEDIATE, no confirmation (decided in planning: the
    /// archived sheet is the bulk-cleanup surface and its rows are already tucked away).
    case deleteButtonTapped(id: Session.ID)
    /// DELETE landed (an `already_absent` body is success by contract) — the optimistic
    /// removal stands.
    case deleteSucceeded(id: Session.ID)
    /// DELETE failed — re-insert at the saved index. A 404/405 `error` is the capability
    /// verdict (flip `deleteSupported` off silently); anything else surfaces the banner.
    case deleteFailed(id: Session.ID, session: Session, index: Int, error: RESTError)
    case sessionTapped(id: Session.ID)
    /// Put a row's session id on the pasteboard and raise the transient confirmation toast.
    case copyIDButtonTapped(id: Session.ID)
    /// The copy toast's dwell time elapsed — hide it.
    case copiedIDToastExpired
    case delegate(Delegate)

    @CasePathable
    public enum Delegate {
      /// Open/resume an archived session — the parent dismisses the sheet and navigates.
      case openSession(Session)
      /// A delete answered 404/405 (agent lacks the DELETE endpoint) — the parent mirrors
      /// its own `deleteSupported` flag off so the main list hides Delete too.
      case deleteUnsupported
    }
  }

  private enum CancelID { case copyIDToast }

  /// How long a copy confirmation (the "Session ID copied" toast) stays up before
  /// auto-dismissing. Same name/value in every feature that confirms a copy.
  static let copiedFeedbackDuration: Duration = .seconds(1.5)

  @Dependency(\.hermesREST) var rest
  @Dependency(\.hermesProfiles) var profiles
  @Dependency(\.date.now) var now
  @Dependency(\.continuousClock) var clock
  @Dependency(\.pasteboard) var pasteboard
  @Dependency(\.chatSnapshot) var chatSnapshot

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .task:
        state.now = now
        state.isLoading = true
        state.loadError = nil
        return .run { [rest, profiles, connection = state.connection, profileName = state.profileName] send in
          do {
            let sessions: [Session]
            if let profileName {
              // Profile-scoped list → hits this profile's `state.db`, not the default's.
              sessions = try await profiles.sessions(connection, profileName, .only, .recent, 100, 0)
            } else {
              sessions = try await rest.archivedSessions(connection, 100, 0)
            }
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
        // Drop any row whose restore OR delete is still in flight, so a refresh landing
        // during either window can't resurrect the optimistically removed row.
        let inFlight = state.restoringIDs.union(state.deletingIDs)
        let visible = inFlight.isEmpty
          ? sessions
          : sessions.filter { !inFlight.contains($0.id) }
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
        return .run { [rest, connection = state.connection, profileName = state.profileName] send in
          do {
            try await rest.archive(connection, id, false, profileName) // archived:false = restore
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

      case let .deleteButtonTapped(id):
        guard state.deleteSupported, let index = state.sessions.index(id: id) else { return .none }
        // Immediate — no confirmation dialog (planning decision; see the action doc).
        // Optimistic removal + in-flight guard, re-insert at `index` if the DELETE fails.
        // No live-chat slot concern here: archiving already tore the slot down, so an
        // archived session can never be the slot — but its cached snapshot + turn anchor
        // must still be wiped so a deleted session can't repaint from the cache. The wipe
        // runs up front and deliberately stays even if the DELETE later fails (same
        // asymmetry as the main list's delete: re-opening resumes fresh).
        let session = state.sessions[index]
        state.sessions.remove(id: id)
        state.deletingIDs.insert(id)
        return .run { [rest, chatSnapshot, connection = state.connection, profileName = state.profileName] send in
          chatSnapshot.deleteSnapshot(id)
          do {
            try await rest.deleteSession(connection, id, profileName)
            await send(.deleteSucceeded(id: id))
          } catch {
            await send(.deleteFailed(
              id: id, session: session, index: index,
              error: (error as? RESTError) ?? .unreachable
            ))
          }
        }

      case let .deleteSucceeded(id):
        state.deletingIDs.remove(id)
        return .none

      case let .deleteFailed(id, session, index, error):
        // The delete didn't take — the server still has the session. Lift the guard and
        // re-insert at the saved index. A definitive 404/405 means the agent lacks the
        // DELETE endpoint (older agents answer 405 — the path exists for PATCH/GET) →
        // flip the capability off SILENTLY (no banner, like the other capability flips),
        // hide the Delete affordances for the rest of the sheet's lifetime, and mirror
        // the verdict back to the session list. Anything else surfaces the banner.
        state.deletingIDs.remove(id)
        let reinsertAt = min(index, state.sessions.count)
        state.sessions.insert(session, at: reinsertAt)
        switch error {
        case .notFound, .server(status: 405, detail: _):
          state.deleteSupported = false
          return .send(.delegate(.deleteUnsupported))
        default:
          state.loadError = "Couldn’t delete the session."
          return .none
        }

      case let .sessionTapped(id):
        guard let session = state.sessions[id: id] else { return .none }
        return .send(.delegate(.openSession(session)))

      case let .copyIDButtonTapped(id):
        state.copiedIDToastToken = (state.copiedIDToastToken ?? 0) + 1
        // Copy now; hide the confirmation after a beat. A second copy while the toast is
        // up restarts the dwell (cancelInFlight) so the latest copy owns the countdown.
        return .merge(
          .run { [pasteboard] _ in pasteboard.copy(id) },
          .run { [clock] send in
            try await clock.sleep(for: Self.copiedFeedbackDuration)
            await send(.copiedIDToastExpired)
          }
          .cancellable(id: CancelID.copyIDToast, cancelInFlight: true)
        )

      case .copiedIDToastExpired:
        state.copiedIDToastToken = nil
        return .none

      case .delegate:
        return .none
      }
    }
  }
}
