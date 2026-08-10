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
      copiedIDToastToken: Int? = nil
    ) {
      self.connection = connection
      self.profileName = profileName
      self.sessions = sessions
      self.isLoading = isLoading
      self.loadError = loadError
      self.now = now
      self.restoringIDs = restoringIDs
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
          } catch {
            await send(.archivedResponse(.failure(asRESTError(error))))
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
