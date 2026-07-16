import ComposableArchitecture

/// Root feature: onboarding until connected, then a session list that pushes chat
/// screens. Wires the child features together via their delegate actions.
@Reducer
public struct AppFeature {
  @ObservableState
  public struct State: Equatable {
    public var onboarding: ConnectionFeature.State
    public var home: SessionListFeature.State?
    /// The navigation path holds only thin session-key markers (`ChatScreen.State`) — the
    /// real chat state lives in the `liveChat` slot below, so popping a marker never
    /// destroys the chat's state or effects by itself.
    public var path: StackState<ChatScreen.State>
    /// The app-owned "live chat slot": the one open (or detached-but-live) chat. Composed
    /// via `.ifLet`, so its socket, reconnect backoff, thinking ticker, and debounced
    /// persist are slot-rooted and survive navigation pops. One live session at a time —
    /// opening a different session replaces the slot.
    public var liveChat: ChatFeature.State?
    /// True during the launch auto-connect probe — `AppView` shows a brief placeholder
    /// instead of flashing the onboarding screen.
    public var autoConnecting: Bool
    /// The re-auth modal, presented when a live (gated) session dies mid-use. While shown,
    /// the dead chat's reconnect stays paused (it pauses itself via `awaitingReauth`).
    @Presents public var reauth: ReauthFeature.State?
    /// Session ids with a pending approval surfaced via a push tap, not yet viewed. The app-icon
    /// badge mirrors `pendingApprovalSessionIDs.count`; tapping/opening a session clears its
    /// entry (and recomputes the badge). A small dedicated count — distinct from the list's
    /// per-session *unread* (`seenCounts`) concept, which tracks message deltas, not approvals.
    public var pendingApprovalSessionIDs: Set<String>

    public init(
      onboarding: ConnectionFeature.State = .init(),
      home: SessionListFeature.State? = nil,
      path: StackState<ChatScreen.State> = .init(),
      liveChat: ChatFeature.State? = nil,
      autoConnecting: Bool = false,
      reauth: ReauthFeature.State? = nil,
      pendingApprovalSessionIDs: Set<String> = []
    ) {
      self.onboarding = onboarding
      self.home = home
      self.path = path
      self.liveChat = liveChat
      self.autoConnecting = autoConnecting
      self.reauth = reauth
      self.pendingApprovalSessionIDs = pendingApprovalSessionIDs
    }

    /// The session the user is currently viewing — the live chat's session key
    /// (`storedSessionID ?? liveSessionID`) while its marker is pushed, or `nil` when no
    /// chat is on screen (or a new chat whose id hasn't resolved yet). A detached slot
    /// (user on the list) reads `nil` so pushes for that session are NOT suppressed.
    /// Drives foreground push suppression via `.onChange`.
    var currentViewingSessionID: String? {
      guard !path.isEmpty else { return nil }
      return liveChat.flatMap { $0.storedSessionID ?? $0.liveSessionID }
    }
  }

  /// App lifecycle phase, mirrored from SwiftUI's `ScenePhase` by the thin app shell so
  /// HermesKit never imports SwiftUI. The shell maps `.active/.inactive/.background` onto
  /// these cases and dispatches `scenePhaseChanged`.
  public enum ScenePhase: Equatable {
    case active
    case inactive
    case background
  }

  public enum Action {
    case task
    case autoConnectSucceeded(ServerConnection)
    case autoConnectFailed(ServerConnection)
    /// The app's scene phase changed (foreground/background) — observed at the app shell and
    /// fanned out: `.active` reconnects + re-hydrates the open chat and refreshes the list;
    /// `.background`/`.inactive` flushes the open chat's snapshot + anchor immediately, and
    /// `.background` with a RUNNING turn additionally requests a finite background window
    /// (`BackgroundTaskClient`) so the socket keeps streaming ~30s past suspension.
    case scenePhaseChanged(ScenePhase)
    /// A push notification was tapped — deep-link to its session, routed by comparing the
    /// tapped id against the live slot + path (#32): already on screen → badge bookkeeping
    /// only; detached slot match → re-attach push; different session → replace the slot and
    /// SET the path (never stack). Approval taps clear their pending-badge entry on view.
    case pushTapped(PushTap)
    case onboarding(ConnectionFeature.Action)
    case home(SessionListFeature.Action)
    case path(StackActionOf<ChatScreen>)
    /// The live chat slot's actions — the chat is composed here (via `.ifLet`), NOT in the
    /// navigation path, so its effects survive pops.
    case liveChat(ChatFeature.Action)
    /// Internal: fill the live-chat slot with a fresh chat and (re)set its path marker.
    /// Used when opening while the slot is occupied — sequenced after the old slot's
    /// `.teardown` so the outgoing chat's effects can't leak into the replacement.
    case fillLiveChat(ChatFeature.State)
    /// Internal: clear the slot after its `.teardown` ran (pop-to-list policy). Nil-ing the
    /// slot also auto-cancels any straggler child effects (`ifLet` semantics).
    case clearLiveChat
    /// Internal: the finite background window (`BackgroundTaskClient`) expired while still
    /// backgrounded — final flush, then disconnect the socket cleanly
    /// (`.teardownSocketOnly`), keeping the chat state in memory for the #26-preserving
    /// foreground re-hydrate.
    case backgroundGraceExpired
    case reauth(PresentationAction<ReauthFeature.Action>)
  }

  /// Ids for the long-running incoming-tap observer and the background-grace listener.
  private enum CancelID { case pushTaps, backgroundGrace }

  @Dependency(\.keychain) var keychain
  @Dependency(\.preferences) var preferences
  @Dependency(\.hermesREST) var rest
  @Dependency(\.push) var push
  @Dependency(\.backgroundTask) var backgroundTask

  public init() {}

  public var body: some ReducerOf<Self> {
    Scope(state: \.onboarding, action: \.onboarding) {
      ConnectionFeature()
    }
    Reduce { state, action in
      switch action {
      case .task:
        // Observe push taps for the whole app lifetime (a tap can arrive cold-launch or while
        // running) and deep-link them; the actual nav happens in `.pushTapped`.
        let tapObserver: Effect<Action> = .run { [push] send in
          for await tap in push.incomingTaps() {
            await send(.pushTapped(tap))
          }
        }
        .cancellable(id: CancelID.pushTaps, cancelInFlight: true)
        // Launch auto-connect: if a persisted session (token *or* gated cookie) + server
        // URL exist, silently validate and skip onboarding. Only runs once, before we have
        // a home. `loadSession` rehydrates a `.cookie` session's cookies into `.shared` so
        // the REST/WS transports authenticate on this fresh launch.
        guard state.home == nil, !state.autoConnecting,
              let session = keychain.loadSession(.shared),
              let urlString = preferences.loadServerURL(),
              let url = parseServerURL(urlString)
        else { return tapObserver }
        // A `.token` session with an empty token is treated as "no creds" (matches the old
        // `loadToken()`-non-empty guard) so we stay on onboarding rather than probe blindly.
        if case .token("") = session { return tapObserver }
        state.autoConnecting = true
        let connection = ServerConnection(baseURL: url, auth: session)
        return .merge(
          tapObserver,
          .run { [rest] send in
            do {
              _ = try await rest.sessions(connection, 1, 0, .recent)
              await send(.autoConnectSucceeded(connection))
            } catch {
              await send(.autoConnectFailed(connection))
            }
          }
        )

      case let .autoConnectSucceeded(connection):
        state.autoConnecting = false
        state.home = SessionListFeature.State(connection: connection)
        return .none

      case let .autoConnectFailed(connection):
        // Stored creds didn't validate (expired token / dead cookies / server moved) — fall
        // back to onboarding. Token mode prefills the fields so the user can fix them; cookie
        // mode prefills only the URL (the password is never persisted), so they re-enter it.
        state.autoConnecting = false
        state.onboarding = ConnectionFeature.State(
          serverURL: connection.baseURL.absoluteString,
          token: connection.auth.token ?? ""
        )
        return .none

      case let .scenePhaseChanged(phase):
        // Fan lifecycle out to the live chat slot (if any) and the session list — no
        // top-of-path hunting: the slot IS the one live chat, attached or not. We do NOT
        // auto-restore the nav stack on cold launch — opening a session is enough.
        switch phase {
        case .active:
          // Foreground: release the background-execution window (cancel the grace listener;
          // `end()` is idempotent — a no-op when none is active), then reconnect + re-hydrate
          // (via `session.resume`) the live chat (re-reads running/inflight/usage) and refresh
          // the list immediately (don't wait for the poll).
          return .merge(
            .cancel(id: CancelID.backgroundGrace),
            .run { [backgroundTask] _ in await backgroundTask.end() },
            state.liveChat != nil ? .send(.liveChat(.foreground)) : .none,
            state.home != nil ? .send(.home(.pulledToRefresh)) : .none
          )
        case .background:
          // Backgrounding: flush the live chat's snapshot + anchor IMMEDIATELY (don't rely on
          // the 1s debounce) so a process kill can't lose the latest paint or the timer anchor.
          guard let chat = state.liveChat else { return .none }
          let flush: Effect<Action> = .send(.liveChat(.persistNow))
          // A RUNNING turn buys itself a finite background window (~30s): the socket simply
          // keeps streaming, no `ChatFeature` changes. If iOS expires the window while still
          // backgrounded, the listener fires `.backgroundGraceExpired` → final flush + clean
          // socket-only disconnect (state stays in memory for the #26-preserving foreground
          // hydrate); catch-up is then the existing push + `.foreground` reconnect. An idle
          // chat starts NO task — nothing to keep alive, no battery burn.
          guard chat.isRunning else { return flush }
          return .merge(
            flush,
            .run { [backgroundTask] send in
              for await _ in await backgroundTask.begin("hermes.chat.background-grace") {
                await send(.backgroundGraceExpired)
              }
            }
            .cancellable(id: CancelID.backgroundGrace, cancelInFlight: true)
          )
        case .inactive:
          // Transient occlusion (app switcher, notification shade): flush only — the process
          // isn't suspending yet, so no background window is needed.
          return state.liveChat != nil ? .send(.liveChat(.persistNow)) : .none
        }

      case .backgroundGraceExpired:
        // The background window ran out while still backgrounded. Final flush, then cancel
        // the socket ONLY — `liveChat` stays in memory so the foreground re-hydrate can
        // preserve the live thinking/tool rows (#26). `end()` is the mandatory bookkeeping
        // call (the client already ended the task inside its expiration handler, so this is
        // an idempotent no-op — kept explicit).
        guard state.liveChat != nil else {
          return .run { [backgroundTask] _ in await backgroundTask.end() }
        }
        return .concatenate(
          .send(.liveChat(.persistNow)),
          .send(.liveChat(.teardownSocketOnly)),
          .run { [backgroundTask] _ in await backgroundTask.end() }
        )

      case let .pushTapped(tap):
        // Deep-link a tapped push to its session — routed by comparing `tap.sessionID`
        // against the live slot + path (#32) so a tap for the already-open session never
        // stacks a duplicate chat screen.
        //
        // Badge bookkeeping: an approval tap first MARKS the session pending (it's a relevant
        // approval), then opening it CLEARS that entry below — so a tap that opens nets to zero,
        // while an approval that can't be opened (no list yet) stays badged until viewed.
        if tap.isApproval {
          state.pendingApprovalSessionIDs.insert(tap.sessionID)
        }
        guard state.home != nil else {
          // No session list yet (e.g. cold launch still on onboarding) — can't open; the badge
          // reflects the now-pending approval.
          return setBadge(state)
        }
        // Matches the slot AND its marker is on the path (the chat is on screen) → NO
        // navigation. Badge bookkeeping only: the user is now viewing it, so the pending
        // entry clears (mark-then-clear nets zero); the content update arrives in place —
        // the live socket is already streaming, and the tap's app activation fires the
        // existing `.foreground` re-hydrate.
        if let chat = state.liveChat,
           (chat.storedSessionID ?? chat.liveSessionID) == tap.sessionID,
           !state.path.isEmpty {
          state.pendingApprovalSessionIDs.remove(tap.sessionID)
          return setBadge(state)
        }
        // Otherwise share the SAME `openSession` flow a list tap uses: a detached slot match
        // (user on the list) pushes the marker back and re-attaches live (no re-init, no dup);
        // a different session replaces the slot and SETS the path to the single new marker
        // (`fillLiveChat` resets rather than appends — no stacking on cold launch either).
        // Prefer the loaded `Session` (carries a title); fall back to a minimal `Session(id:)`
        // if it isn't in the list (the chat resumes by stored id and hydrates the title).
        let session = state.home?.sessions[id: tap.sessionID] ?? Session(id: tap.sessionID)
        // Opening clears the badge entry + marks current-viewing (handled in the openSession case).
        return .send(.home(.delegate(.openSession(session))))

      case let .onboarding(.delegate(.connected(connection))):
        state.home = SessionListFeature.State(connection: connection)
        return .none

      case let .home(.delegate(.openSession(session))):
        guard let home = state.home else { return .none }
        // Opening a session clears its pending-approval badge entry (the user is now viewing it).
        // The current-viewing marker is updated by the `.onChange(of: currentViewingSessionID)`
        // modifier below (one source of truth for nav-derived state).
        state.pendingApprovalSessionIDs.remove(session.id)
        let badge = setBadge(state)
        // Re-opening the slot's OWN session (e.g. tapping the glowing row of a detached
        // running turn): the accumulated live state must survive — a fresh
        // `ChatFeature.State` would discard the detached thinking/tool/streaming rows.
        // Push the marker back (the path is empty when coming from the list) and
        // re-attach: hydrate against the live socket, reconnecting only if it died.
        if let chat = state.liveChat,
           (chat.storedSessionID ?? chat.liveSessionID) == session.id {
          if state.path.isEmpty {
            state.path.append(ChatScreen.State(sessionKey: session.id))
          }
          return .merge(badge, .send(.liveChat(.reattached)))
        }
        // `resolvedTitle` keeps the server's "Untitled" placeholder out of the header
        // (and the rename pre-fill); a real title arrives via `session.info` on resume.
        // Carry the active profile so resume/history scope to the right `state.db`.
        let chat = ChatFeature.State(
          connection: home.connection,
          resumeStoredID: session.id,
          profileName: home.scopedProfileName,
          title: session.resolvedTitle
        )
        guard state.liveChat != nil else {
          fillLiveChat(chat, into: &state)
          return badge
        }
        // Slot occupied (e.g. a push tap while a chat is open): flush the old chat's
        // snapshot, tear it down FIRST so its socket/effects can't feed events into the
        // replacement, then fill the slot.
        return .merge(
          badge,
          .concatenate(
            .send(.liveChat(.persistNow)),
            .send(.liveChat(.teardown)),
            .send(.fillLiveChat(chat))
          )
        )

      case let .home(.delegate(.createSession(initialComposerText))):
        guard let home = state.home else { return .none }
        // New chats are created under the currently-selected profile. `initialComposerText`
        // (push "Ask agent to install") seeds the composer draft but is NOT auto-sent.
        let chat = ChatFeature.State(
          connection: home.connection,
          profileName: home.scopedProfileName,
          composerText: initialComposerText ?? ""
        )
        guard state.liveChat != nil else {
          fillLiveChat(chat, into: &state)
          return .none
        }
        // Slot occupied: flush + tear the old chat down before filling (same rule as open).
        return .concatenate(
          .send(.liveChat(.persistNow)),
          .send(.liveChat(.teardown)),
          .send(.fillLiveChat(chat))
        )

      case let .fillLiveChat(chat):
        fillLiveChat(chat, into: &state)
        return .none

      case .clearLiveChat:
        // Pop-to-list teardown completed — drop the slot state. `ifLet` auto-cancels any
        // remaining child effects on the nil-out.
        state.liveChat = nil
        return .none

      case .path(.popFrom):
        // Popped back to the session list. Keep-while-running policy: a RUNNING turn keeps
        // its slot untouched — the socket streams on, rows accumulate detached, and the
        // list's row glow tracks via `runningChanged` (whose `running: false` while
        // detached tears the slot down below). An idle chat has nothing to keep alive —
        // flush the snapshot, cancel everything, clear the slot.
        guard let chat = state.liveChat else { return .none }
        guard !chat.isRunning else { return .none }
        return teardownSlot()

      case let .home(.delegate(.sessionArchived(id))):
        // The user archived a session from the list. If it's the slot's session (possibly
        // detached mid-turn), tear the live chat down FIRST — its socket must not keep
        // streaming into a session that's now archived. Any other session → nothing to do
        // (the list's optimistic archive handles itself).
        guard let chat = state.liveChat,
              (chat.storedSessionID ?? chat.liveSessionID) == id
        else { return .none }
        return teardownSlot()

      case .home(.delegate(.disconnect)):
        // Token cleared in Settings → tear down and return to onboarding. Nil-ing the slot
        // auto-cancels its effects (socket included).
        let connection = state.home?.connection
        state.path = .init()
        state.liveChat = nil
        state.home = nil
        state.onboarding = .init()
        return unregisterPushOnLogout(connection: connection)

      case .liveChat(.delegate(.sessionExpired)):
        // The live (gated) session died — attached or detached, the slot is the one chat.
        // The chat already paused its own reconnect; raise the re-auth modal seeded from its
        // connection (server URL + regime + identity). Ignore if a modal is already up.
        guard state.reauth == nil, let chat = state.liveChat else { return .none }
        state.reauth = makeReauthState(for: chat.connection)
        return .none

      case let .reauth(.presented(.delegate(.reauthenticated(connection, sameUser)))):
        state.reauth = nil
        if sameUser {
          // Same user → resume the dead slot chat in place with the fresh auth regime.
          guard state.liveChat != nil else { return .none }
          return .send(.liveChat(.resumeAfterReauth(connection)))
        }
        // Different user signed in → drop everything identity-scoped and force a fresh list.
        preferences.clearIdentityScopedPrefs()
        state.path = .init()
        state.liveChat = nil
        state.home = SessionListFeature.State(connection: connection)
        return .none

      case .reauth(.presented(.delegate(.quit))):
        // "Quit to start" → full logout (Keychain session + every pref) → onboarding.
        let connection = state.home?.connection ?? state.liveChat?.connection
        try? keychain.deleteSession()
        preferences.clearServerURL()
        preferences.clearIdentityScopedPrefs()
        preferences.saveGroupingMode(.default)
        state.reauth = nil
        state.path = .init()
        state.liveChat = nil
        state.home = nil
        state.onboarding = .init()
        return unregisterPushOnLogout(connection: connection)

      case let .liveChat(.delegate(.runningChanged(sessionID, running))):
        // Route the live chat's authoritative working-state change to the session list so its
        // row glow clears/lights INSTANTLY (event-driven), without waiting for the next poll.
        // The poll stays the backstop for not-open sessions. No `home` → nothing to patch.
        let glow: Effect<Action> = state.home != nil
          ? .send(.home(.setSessionRunning(id: sessionID, running: running)))
          : .none
        // A DETACHED slot (no marker in the path — the user popped to the list) only
        // outlives the pop while its turn runs. The turn ending — `message.complete`,
        // `.error`, or a foreground hydrate confirming `running == false` — means there's
        // nothing left to keep alive: flush the snapshot, then tear the slot down.
        guard !running, state.path.isEmpty, state.liveChat != nil else { return glow }
        return .concatenate(glow, teardownSlot())

      case .onboarding, .home, .path, .reauth, .liveChat:
        return .none
      }
    }
    .ifLet(\.home, action: \.home) {
      SessionListFeature()
    }
    .ifLet(\.$reauth, action: \.reauth) {
      ReauthFeature()
    }
    .ifLet(\.liveChat, action: \.liveChat) {
      ChatFeature()
    }
    .forEach(\.path, action: \.path) {
      ChatScreen()
    }
    // Keep the push bridge's "currently viewing" session in sync with the slot + nav stack
    // (one source of truth, evaluated AFTER the child reducers so pops/dismissals AND a new chat
    // resolving its `liveSessionID` are reflected) so a foreground push for the on-screen session
    // is suppressed. Opening, popping back to the list, and id-resolution all flow through here.
    .onChange(of: \.currentViewingSessionID) { _, newValue in
      Reduce { _, _ in
        .run { [push] _ in push.setCurrentSession(newValue) }
      }
    }
  }

  /// The standard "slot is done" sequence (idle pop, detached turn completion, archived
  /// session): flush the snapshot + turn anchor first (the debounced persist is about to be
  /// cancelled), cancel every long-running chat effect, then clear the slot (`ifLet`
  /// auto-cancels any stragglers on the nil-out).
  private func teardownSlot() -> Effect<Action> {
    .concatenate(
      .send(.liveChat(.persistNow)),
      .send(.liveChat(.teardown)),
      .send(.clearLiveChat)
    )
  }

  /// Fill the live-chat slot and (re)set the navigation path to that chat's single marker.
  /// One slot ↔ one marker: the path never holds more than one chat screen, so replacing the
  /// contents (rather than appending) can't stack duplicates.
  private func fillLiveChat(_ chat: ChatFeature.State, into state: inout State) {
    state.liveChat = chat
    state.path.removeAll()
    state.path.append(ChatScreen.State(sessionKey: chat.storedSessionID))
  }

  /// Best-effort push cleanup on logout: unregister the last-known device token with the
  /// agent's push plugin (failures ignored — the server prunes dead tokens on a 410 anyway),
  /// then clear the persisted device token (prefs). Part of
  /// "logout clears everything". Uses the persisted token so it works even when the live
  /// `register()` stream isn't producing; a `nil` connection (nothing to talk to) still clears
  /// local push state.
  private func unregisterPushOnLogout(connection: ServerConnection?) -> Effect<AppFeature.Action> {
    let token = preferences.loadPushDeviceToken()
    preferences.clearPushDeviceToken()
    preferences.clearPushPromptSnooze() // device-local push prompt state — reset on logout
    guard let connection, let token else { return .none }
    return .run { [rest] _ in
      try? await rest.unregisterPush(connection, token)
    }
  }

  /// Push the app-icon badge to the current pending-approval count (the only side effect; the
  /// count itself lives in `state.pendingApprovalSessionIDs`, kept testable in the reducer).
  private func setBadge(_ state: State) -> Effect<AppFeature.Action> {
    let count = state.pendingApprovalSessionIDs.count
    return .run { [push] _ in await push.setBadgeCount(count) }
  }

  /// Seed a `ReauthFeature.State` from the connection of the expired chat: a fixed server
  /// URL, the matching auth regime, and (cookie mode) the prefilled username + provider used
  /// for the same-user vs user-switch decision.
  private func makeReauthState(for connection: ServerConnection) -> ReauthFeature.State {
    switch connection.auth {
    case .token:
      return ReauthFeature.State(serverURL: connection.baseURL, method: .token)
    case let .cookie(session):
      return ReauthFeature.State(
        serverURL: connection.baseURL,
        method: .password,
        provider: session.provider,
        previousUsername: session.username
      )
    }
  }
}
