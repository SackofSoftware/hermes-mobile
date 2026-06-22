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
    /// The profiles available on the connected agent (default + any custom). Populated from
    /// `profiles.list` on `.task`; empty when the agent lacks the profiles API.
    public var profiles: IdentifiedArrayOf<Profile>
    /// The device-local selected profile name. Defaults to the persisted pref or `"default"`.
    /// New chats + the scoped session list are bound to this profile.
    public var selectedProfileName: String
    /// Whether the agent exposes `/api/profiles` (set false on a 404 from `profiles.list`).
    /// When false the selector is hidden and the list uses today's unscoped `/api/sessions`.
    public var profilesSupported: Bool
    /// Custom profile currently being renamed (drives the rename alert); nil = no alert.
    public var renamingProfileName: String?
    /// The editable text bound to the profile-rename alert's `TextField`.
    public var profileRenameDraft: String
    /// Whether the connected agent exposes the `hermes-push` plugin (push registration
    /// endpoint present). `true` once a `registerPush` succeeds; `false` on a definitive 404
    /// (plugin not installed). Threaded into Settings so the notifications UI is capability-gated.
    /// Defaults to `true` (optimistic) so we attempt registration before the first probe.
    public var pushAvailable: Bool
    @Presents public var settings: SettingsFeature.State?
    @Presents public var archived: ArchivedSessionsFeature.State?
    @Presents public var addProfile: AddProfileFeature.State?
    @Presents public var confirmationDialog: ConfirmationDialogState<Action.Dialog>?

    /// The default profile name — never renamable/deletable, and the implicit fallback.
    public static let defaultProfileName = "default"

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
      profiles: IdentifiedArrayOf<Profile> = [],
      selectedProfileName: String = SessionListFeature.State.defaultProfileName,
      profilesSupported: Bool = false,
      renamingProfileName: String? = nil,
      profileRenameDraft: String = "",
      pushAvailable: Bool = true,
      settings: SettingsFeature.State? = nil,
      addProfile: AddProfileFeature.State? = nil
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
      self.profiles = profiles
      self.selectedProfileName = selectedProfileName
      self.profilesSupported = profilesSupported
      self.renamingProfileName = renamingProfileName
      self.profileRenameDraft = profileRenameDraft
      self.pushAvailable = pushAvailable
      self.settings = settings
      self.addProfile = addProfile
    }

    /// Whether the currently-selected profile is the default (no `?profile=` scoping for
    /// reads/mutations, and a `nil` profile threaded into archive/rename).
    public var isDefaultProfileSelected: Bool {
      selectedProfileName == Self.defaultProfileName
    }

    /// The profile name to thread into session-scoped REST calls (archive/rename): `nil`
    /// for the default profile or when the agent lacks the profiles API, else the name.
    public var scopedProfileName: String? {
      guard profilesSupported, !isDefaultProfileSelected else { return nil }
      return selectedProfileName
    }

    /// True while a search query is active — the list shows flat results, not workspace
    /// groups (search has no `cwd`).
    public var isSearching: Bool {
      !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Cron-scheduled sessions, pulled out of the interactive list and shown in their own
    /// always-on "Cron Jobs" section. Sorted by recency (`updatedAt` desc, `nil` last),
    /// mirroring `chronologicalSessions`.
    public var cronSessions: [Session] {
      sessions.filter(\.isCron)
        .sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
    }

    /// The non-cron remainder — everything the pinning/workspace/chronological computeds
    /// operate on, so cron sessions never feed the interactive sections (a pinned-but-cron
    /// id surfaces only under Cron Jobs).
    public var interactiveSessions: [Session] {
      sessions.filter { !$0.isCron }
    }

    /// Pinned sessions resolved from `pinnedIDs`, in pin order; stale ids are dropped. Cron
    /// sessions are excluded (they belong to the Cron Jobs section), even if pinned.
    public var pinnedSessions: [Session] {
      pinnedIDs.compactMap { id in sessions[id: id].flatMap { $0.isCron ? nil : $0 } }
    }

    /// Non-cron sessions not pinned — these feed the workspace grouping.
    public var unpinnedSessions: [Session] {
      let pinned = Set(pinnedIDs)
      return interactiveSessions.filter { !pinned.contains($0.id) }
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
    // MARK: Profiles
    /// Switch the active profile (persist, reset list UI, refetch the scoped session list).
    case selectProfile(name: String)
    /// Response from the `profiles.list` capability probe on `.task` (also fetches sessions).
    case profilesResponse(Result<[Profile], RESTError>)
    /// Refresh of the profile list WITHOUT a session fetch (after create/delete, paired with a
    /// subsequent `selectProfile` that does the single scoped fetch).
    case profilesRefreshed([Profile])
    /// Open the Add-profile sheet.
    case addProfileTapped
    case addProfile(PresentationAction<AddProfileFeature.Action>)
    /// Open the rename alert for a custom profile: seeds `profileRenameDraft` with its name.
    case renameProfileTapped(name: String)
    /// Commit the profile rename from the alert (sends the entered draft as `newName`).
    case confirmRenameProfile
    /// Dismiss the profile-rename alert without applying changes.
    case cancelRenameProfile
    /// Begin renaming a custom profile (opens the inline rename via the dialog/menu path).
    case renameProfileButtonTapped(name: String, newName: String)
    /// Rename PATCH succeeded — the optimistic profile name stands.
    case renameProfileSucceeded
    /// Rename PATCH failed — restore `previousProfiles` and surface the error.
    case renameProfileFailed(previousProfiles: IdentifiedArrayOf<Profile>, previousSelected: String)
    /// Ask to delete a custom profile (presents the confirmation dialog).
    case deleteProfileButtonTapped(name: String)
    /// Delete PATCH succeeded — remove the profile locally and, if it was active, re-home to
    /// default and refetch sessions.
    case deleteProfileSucceeded(name: String)
    /// Delete failed — surface the error (no local state was changed yet).
    case deleteProfileFailed
    /// Event-driven working-glow patch from the open chat (routed by `AppFeature` from
    /// `ChatFeature.Delegate.runningChanged`): set the row's `isActive` INSTANTLY so the glow
    /// clears/lights the moment the agent stops/starts, rather than waiting for the next poll.
    /// Always server-confirmed (the delegate only fires from `message.start`/`complete`/`error`
    /// and the `session.resume` `running` flag) — a cached `running-guess` never reaches here,
    /// so it can never start a glow on its own. The poll remains the backstop for not-open
    /// sessions. A no-op for an unknown id (the session isn't in the current list).
    case setSessionRunning(id: Session.ID, running: Bool)
    // MARK: Push notifications
    /// Kicks off contextual push setup once the list appears (right after login): prompt for
    /// authorization, and if granted, start observing the device-token stream. Fired from `.task`.
    case setupPush
    /// A device token arrived from `PushClient.register()` (initial registration OR an OS
    /// rotation) — (re-)register it with the agent. Carries the lowercase-hex token.
    case pushTokenReceived(String)
    /// `rest.registerPush` succeeded → push is available.
    case pushRegistered
    /// `rest.registerPush` failed; a `.notFound` flips `pushAvailable` off (plugin not installed).
    case pushRegisterFailed(RESTError)
    case delegate(Delegate)

    @CasePathable
    public enum Dialog: Equatable {
      case confirmArchive(id: Session.ID)
      case confirmDeleteProfile(name: String)
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
  private enum CancelID { case fetch, poll, pushTokens }

  /// How often the list auto-refreshes while visible, to keep `isActive` (working glow) fresh.
  private static let pollInterval: Duration = .seconds(10)

  @Dependency(\.hermesREST) var rest
  @Dependency(\.hermesProfiles) var profiles
  @Dependency(\.continuousClock) var clock
  @Dependency(\.date.now) var now
  @Dependency(\.preferences) var preferences
  @Dependency(\.push) var push

  public init() {}

  public var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .task:
        // Refresh "now", reload persisted prefs (incl. the device-local selected profile),
        // probe the profiles capability, and start the auto-poll loop.
        reloadPrefs(&state)
        state.selectedProfileName =
          preferences.loadSelectedProfileID() ?? Self.State.defaultProfileName
        state.isLoading = true
        return .merge(
          .run { [profiles, connection = state.connection] send in
            do {
              let result = try await profiles.list(connection)
              await send(.profilesResponse(.success(result)))
            } catch let error as RESTError {
              await send(.profilesResponse(.failure(error)))
            } catch {
              await send(.profilesResponse(.failure(.unreachable)))
            }
          }
          .cancellable(id: CancelID.fetch, cancelInFlight: true),
          .run { [clock, interval = Self.pollInterval] send in
            while true {
              try await clock.sleep(for: interval)
              await send(.pollTick)
            }
          }
          .cancellable(id: CancelID.poll, cancelInFlight: true),
          // Contextual push setup: prompt for permission now that we're past login, and (if
          // granted) start observing device tokens. Per the product decision the permission
          // prompt fires here on the sessions list — never at first launch.
          .send(.setupPush)
        )

      case .onDisappear:
        // Stop the poll (and any in-flight fetch / search debounce) when the list goes away.
        return .merge(
          .cancel(id: CancelID.poll),
          .cancel(id: CancelID.fetch),
          .cancel(id: CancelID.pushTokens)
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

      case let .setSessionRunning(id, running):
        // Patch the in-memory row's working flag (drives the glow) the instant the open chat
        // tells us this session's authoritative running state changed. No-op if the session
        // isn't in the current list (e.g. archived/filtered) — the poll handles those.
        guard state.sessions[id: id]?.isActive != running else { return .none }
        state.sessions[id: id]?.isActive = running
        return .none

      case .setupPush:
        // Contextual permission request (after login, on the list). If granted, observe the
        // device-token stream as a long-running cancellable effect — each emitted token (the
        // first registration and any OS rotation) drives a (re-)register. If denied we do
        // nothing further; the toggle in Settings can re-prompt later.
        return .run { [push] send in
          guard await push.requestAuthorization() else { return }
          for await token in push.register() {
            await send(.pushTokenReceived(token))
          }
        }
        .cancellable(id: CancelID.pushTokens, cancelInFlight: true)

      case let .pushTokenReceived(token):
        // (Re-)register this device token with the agent's push plugin, threading the
        // compile-time APNs env + app version. Persist the token (non-secret) so logout can
        // unregister with it even when the live stream isn't producing.
        preferences.savePushDeviceToken(token)
        return .run { [rest, push, connection = state.connection] send in
          let env = PushClient.apnsEnv
          let version = push.appVersion()
          do {
            try await rest.registerPush(connection, token, env, version)
            await send(.pushRegistered)
          } catch let error as RESTError {
            await send(.pushRegisterFailed(error))
          } catch {
            await send(.pushRegisterFailed(.unreachable))
          }
        }

      case .pushRegistered:
        // Plugin present → push is available. The app does not sign pushes (the plugin signs
        // with a shared secret), so there's nothing to persist on success.
        state.pushAvailable = true
        return .none

      case let .pushRegisterFailed(error):
        // A definitive 404 means the plugin isn't installed — capability-gate the push UI off.
        // Other (transient) failures leave `pushAvailable` as-is so we retry on the next token.
        if error == .notFound {
          state.pushAvailable = false
        }
        return .none

      case .binding(\.searchQuery):
        // Only the searchQuery binding drives the debounced fetch; other bound fields
        // (renameDraft) must NOT trigger a search.
        return .run { [
          rest, profiles, connection = state.connection, query = state.searchQuery, clock,
          profileName = state.selectedProfileName, profilesSupported = state.profilesSupported
        ] send in
          try await clock.sleep(for: .milliseconds(300))
          await send(fetchSessions(
            rest: rest, profiles: profiles, connection: connection, query: query,
            profileName: profileName, profilesSupported: profilesSupported
          ))
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
        let archiveProfile = state.scopedProfileName
        return .merge(
          .cancel(id: CancelID.fetch),
          .run { [rest, preferences, connection = state.connection] send in
            preferences.savePinnedIDs(pinnedIDs)
            preferences.saveSeenCounts(seenCounts)
            do {
              try await rest.archive(connection, id, true, archiveProfile)
              await send(.archiveSucceeded(id: id))
            } catch {
              await send(.archiveFailed(
                id: id, session: session, index: index, pinIndex: pinIndex, seenCount: seenCount
              ))
            }
          }
        )

      case let .confirmationDialog(.presented(.confirmDeleteProfile(name))):
        guard let profile = state.profiles[id: name], !profile.isDefault else { return .none }
        return .run { [profiles, connection = state.connection] send in
          do {
            try await profiles.delete(connection, name)
            await send(.deleteProfileSucceeded(name: name))
          } catch {
            await send(.deleteProfileFailed)
          }
        }

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
        let renameProfile = state.scopedProfileName
        return .merge(
          .cancel(id: CancelID.fetch),
          .run { [rest, connection = state.connection] send in
            do {
              try await rest.rename(connection, id, trimmed, renameProfile)
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
        state.settings = SettingsFeature.State(
          connection: state.connection, pushAvailable: state.pushAvailable
        )
        return .none

      case .archivedButtonTapped:
        state.archived = ArchivedSessionsFeature.State(
          connection: state.connection,
          profileName: state.scopedProfileName,
          now: state.now
        )
        return .none

      case let .archived(.presented(.delegate(.openSession(session)))):
        // Open from the archived sheet → dismiss it and resume in the main stack.
        state.archived = nil
        return .send(.delegate(.openSession(session)))

      case .archived:
        return .none

      // MARK: Profiles

      case let .profilesResponse(.success(result)):
        state.profilesSupported = true
        state.profiles = IdentifiedArray(uniqueElements: result)
        // If the persisted selection no longer exists on the server, re-home to default.
        if state.profiles[id: state.selectedProfileName] == nil {
          state.selectedProfileName = Self.State.defaultProfileName
          preferences.saveSelectedProfileID(state.selectedProfileName)
        }
        return load(&state)

      case .profilesResponse(.failure):
        // A 404 (old agent) or any failure → behave as today: no scoping, unscoped fetch.
        state.profilesSupported = false
        state.profiles = []
        return load(&state)

      case let .profilesRefreshed(result):
        state.profilesSupported = true
        state.profiles = IdentifiedArray(uniqueElements: result)
        return .none

      case let .selectProfile(name):
        // No-op when already selected (avoids a redundant refetch / UI reset).
        guard name != state.selectedProfileName else { return .none }
        state.selectedProfileName = name
        // Reset the list UI on switch (search + group expansion don't carry across profiles).
        state.searchQuery = ""
        state.expandedGroups = []
        preferences.saveSelectedProfileID(name)
        return load(&state)

      case .addProfileTapped:
        state.addProfile = AddProfileFeature.State(connection: state.connection)
        return .none

      case let .addProfile(.presented(.delegate(.created(name)))):
        // Dismiss the sheet, refresh the profile list (no fetch), THEN select the new profile
        // (which does the single scoped fetch). Sequential so the refreshed list is in place
        // before the switch, and avoids a redundant double fetch.
        state.addProfile = nil
        return .run { [profiles, connection = state.connection] send in
          if let result = try? await profiles.list(connection) {
            await send(.profilesRefreshed(result))
          }
          await send(.selectProfile(name: name))
        }

      case .addProfile:
        return .none

      case let .renameProfileTapped(name):
        // Open the rename alert (default profile is never renamable).
        guard let profile = state.profiles[id: name], !profile.isDefault else { return .none }
        state.renamingProfileName = name
        state.profileRenameDraft = profile.name
        return .none

      case .confirmRenameProfile:
        guard let name = state.renamingProfileName else { return .none }
        let newName = state.profileRenameDraft
        state.renamingProfileName = nil
        state.profileRenameDraft = ""
        return .send(.renameProfileButtonTapped(name: name, newName: newName))

      case .cancelRenameProfile:
        state.renamingProfileName = nil
        state.profileRenameDraft = ""
        return .none

      case let .renameProfileButtonTapped(name, newName):
        // The default profile is never renamable — guard even if the view slips up.
        guard let profile = state.profiles[id: name], !profile.isDefault else { return .none }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != name, ProfileName.isValid(trimmed) else { return .none }
        // Optimistic rename with rollback (mirrors session rename).
        let previousProfiles = state.profiles
        let previousSelected = state.selectedProfileName
        var renamed = profile
        renamed.name = trimmed
        state.profiles[id: name] = nil
        state.profiles.append(renamed)
        if state.selectedProfileName == name {
          state.selectedProfileName = trimmed
          preferences.saveSelectedProfileID(trimmed)
        }
        return .run { [profiles, connection = state.connection] send in
          do {
            try await profiles.rename(connection, name, trimmed)
            await send(.renameProfileSucceeded)
          } catch {
            await send(.renameProfileFailed(
              previousProfiles: previousProfiles, previousSelected: previousSelected
            ))
          }
        }

      case .renameProfileSucceeded:
        return .none

      case let .renameProfileFailed(previousProfiles, previousSelected):
        state.profiles = previousProfiles
        state.selectedProfileName = previousSelected
        preferences.saveSelectedProfileID(previousSelected)
        state.loadError = "Couldn’t rename the profile."
        return .none

      case let .deleteProfileButtonTapped(name):
        // The default profile is never deletable — guard even if the view slips up.
        guard let profile = state.profiles[id: name], !profile.isDefault else { return .none }
        state.confirmationDialog = ConfirmationDialogState {
          TextState("Delete profile?")
        } actions: {
          ButtonState(role: .destructive, action: .confirmDeleteProfile(name: name)) {
            TextState("Delete")
          }
          ButtonState(role: .cancel) {
            TextState("Cancel")
          }
        } message: {
          TextState("This permanently deletes the profile and its sessions on the server.")
        }
        return .none

      case let .deleteProfileSucceeded(name):
        state.profiles[id: name] = nil
        // If the deleted profile was active, re-home to default and refetch its sessions.
        if state.selectedProfileName == name {
          state.selectedProfileName = Self.State.defaultProfileName
          state.searchQuery = ""
          state.expandedGroups = []
          preferences.saveSelectedProfileID(Self.State.defaultProfileName)
          return load(&state)
        }
        return .none

      case .deleteProfileFailed:
        state.loadError = "Couldn’t delete the profile."
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
    .ifLet(\.$addProfile, action: \.addProfile) {
      AddProfileFeature()
    }
    .ifLet(\.$confirmationDialog, action: \.confirmationDialog)
  }

  /// Refresh "now", clear errors, and reload the non-secret persisted prefs (seen counts,
  /// pins, grouping). Shared by `.task` and `load()` — `.task` additionally reloads the
  /// selected profile before probing the profiles capability.
  private func reloadPrefs(_ state: inout State) {
    state.now = now
    state.loadError = nil
    state.seenCounts = preferences.loadSeenCounts()
    state.pinnedIDs = preferences.loadPinnedIDs()
    state.groupingMode = preferences.loadGroupingMode()
  }

  /// Refresh "now", clear errors, reload persisted prefs, and fetch the session list
  /// (profile-scoped when supported; unscoped otherwise — search always unscoped).
  private func load(_ state: inout State) -> Effect<Action> {
    reloadPrefs(&state)
    state.isLoading = true
    return .run { [
      rest, profiles, connection = state.connection, query = state.searchQuery,
      profileName = state.selectedProfileName, profilesSupported = state.profilesSupported
    ] send in
      await send(fetchSessions(
        rest: rest, profiles: profiles, connection: connection, query: query,
        profileName: profileName, profilesSupported: profilesSupported
      ))
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
///
/// When `profilesSupported` is true the active list is fetched via the profile-scoped
/// endpoint (`profiles.sessions(profile:…)`); otherwise it falls back to today's
/// unscoped `/api/sessions`. Search is never profile-scoped (mirrors the desktop) — it
/// always goes through `rest.search`.
private func fetchSessions(
  rest: HermesRESTClient,
  profiles: HermesProfileClient,
  connection: ServerConnection,
  query rawQuery: String,
  profileName: String,
  profilesSupported: Bool
) async -> SessionListFeature.Action {
  let query = rawQuery.trimmingCharacters(in: .whitespaces)
  do {
    let sessions: [Session]
    if !query.isEmpty {
      sessions = try await rest.search(connection, query)
    } else if profilesSupported {
      // The dedicated profiles endpoint takes the literal name (incl. "default") — unlike the
      // legacy per-session mutation endpoints, which use `scopedProfileName` (default→nil). The
      // canonical default name is `SessionListFeature.State.defaultProfileName`.
      sessions = try await profiles.sessions(connection, profileName, .exclude, .recent, 50, 0)
    } else {
      sessions = try await rest.sessions(connection, 50, 0, .recent)
    }
    return .sessionsResponse(.success(sessions))
  } catch let error as RESTError {
    return .sessionsResponse(.failure(error))
  } catch {
    return .sessionsResponse(.failure(.unreachable))
  }
}
