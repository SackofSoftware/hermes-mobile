# Connection-Failed Screen with Retry and Logout (#62)

## Overview

- When launch auto-connect fails because the server is unreachable (Tailscale/VPN off,
  no internet, server down), the app currently drops to onboarding and — in password
  mode — forces the user to re-type credentials that are still perfectly valid.
- Add a dedicated "Can't reach the server" screen shown instead: it names the server
  URL, explains why the connection failed (offline vs server unreachable), offers a
  manual **Retry** button, auto-retries on app foreground, and offers **Log Out** for
  users who genuinely want to abandon the stored session.
- A clean auth rejection (401) keeps today's behavior: fall back to onboarding for
  re-entry — retrying won't fix dead credentials.
- Scope is strictly the **launch auto-connect path**. Manual login failures keep the
  onboarding inline footer; post-login socket drops keep the chat reconnect banner.

## Context (from discovery)

- `HermesKit/Sources/HermesKit/AppFeature.swift:177-213` — launch auto-connect probes
  `rest.sessions(connection, 1, 0, .recent)`; **any** error lands in
  `.autoConnectFailed(connection)` which discards the error and resets to onboarding
  (`ConnectionFeature.State(serverURL:token:)` — password never prefills).
- `HermesKit/Sources/HermesKit/Clients/HermesRESTClient.swift:61-88` — `RESTError`
  distinguishes `.unauthorized` from `.unreachable`, but every transport catch
  (`login:364`, `get:400`, and the sibling `post`/`patch`/`delete` helpers) throws a
  bare `.unreachable`, discarding the `URLError` — so "no internet" and "server not
  responding" are indistinguishable today.
- Full-logout recipe exists twice: `SettingsFeature.clearTokenTapped`
  (`SettingsFeature.swift:229-242` — keychain session, server URL, pins, seen counts,
  grouping, profile, `chatSnapshot.wipeAll()`) and the reauth-quit path
  (`AppFeature.swift:489-506` — adds badge reset + `unregisterPushOnLogout`).
- `HermesMobile/Sources/AppView.swift` — root branches `home` → `autoConnecting`
  spinner → onboarding `ConnectionView`. New screen slots in as another branch.
- `AppFeature.State.onboarding` is a non-optional `Scope`; `home`/`liveChat` are
  optional `ifLet` children — the new feature follows the `ifLet` pattern.
- Patterns: `@DependencyClient` injection, TCA `TestStore` reducer tests in
  `HermesKit/Tests/HermesKitTests/`, snapshot tests in `HermesMobileTests/`.

## Development Approach

- **Testing approach**: Regular (code first, then tests, per task)
- Complete each task fully before moving to the next
- Make small, focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
  - tests are not optional — they are a required part of the checklist
  - cover both success and error scenarios
- **CRITICAL: all tests must pass before starting next task** — no exceptions
- **CRITICAL: update this plan file when scope changes during implementation**
- Run `script -q /dev/null swift test --package-path HermesKit` after each HermesKit
  change; `make snapshot` for view changes
- Maintain backward compatibility: the 401 fallback-to-onboarding path must stay
  byte-identical to today's behavior

## Testing Strategy

- **Unit tests (HermesKit, `swift test`)**: transport-error mapping,
  `ConnectionFailedFeature` reducer, `AppFeature` routing/logout — `TestStore` with
  dependency overrides.
- **Snapshot tests (`HermesMobileTests`, `make snapshot`)**: the new view in its
  offline and unreachable variants. New baselines via the run-twice recipe (first run
  records + fails, second asserts) — do NOT use `make snapshot-record`.
- No e2e suite in this project.

## Progress Tracking

- Mark completed items with `[x]` immediately when done
- Add newly discovered tasks with ➕ prefix
- Document issues/blockers with ⚠️ prefix
- Keep plan in sync with actual work done

## Solution Overview

- **Enrich transport errors**: add `RESTError.offline` and map `URLError` codes in one
  shared helper used by every transport catch — `.notConnectedToInternet` /
  `.dataNotAllowed` / `.internationalRoamingOff` → `.offline`; everything else
  (timeout, DNS, connection refused, non-HTTP response) stays `.unreachable`. Adding a
  *case* (not an associated value) keeps every existing `.unreachable` match compiling.
- **New `ConnectionFailedFeature`** (HermesKit reducer + thin SwiftUI view): holds the
  failed `ServerConnection` + the `RESTError` reason + `isRetrying`. Retry re-runs the
  same `rest.sessions` probe. Success → delegate `.connected`; another retryable
  failure → update the reason in place; a credentials verdict → delegate
  `.credentialsRejected`. "Change server" → delegate `.changeServerRequested`. Logout →
  confirmation dialog → delegate `.logoutConfirmed`. Foreground auto-retry re-enters the
  same probe, **superseding** any in-flight one (`cancelInFlight`).
- **`AppFeature` routing**: `.autoConnectFailed` gains the `RESTError` payload.
  `ConnectionFailedFeature.isRetryable` — the single shared rule — populates the new
  `connectionFailed: ConnectionFailedFeature.State?` slot; only a credentials verdict
  (401/403) keeps today's onboarding fallback. Delegates: `.connected` mirrors `.autoConnectSucceeded`
  (build home, replay pending push tap); `.credentialsRejected` /
  `.changeServerRequested` fall back to onboarding prefilled (nothing cleared);
  `.logoutConfirmed` runs the full-logout recipe (keychain + all prefs + snapshot wipe +
  badge reset + push unregister) and lands on a **fresh** onboarding.
- Key decisions: prefs/keychain clearing lives in `AppFeature.fullLogout` — one helper
  shared with the reauth "Quit to start" path (they had already drifted over
  `chatSnapshot.wipeAll()`) — keeping the child reducer pure routing + retry.
- **[decision, review phase 1] 5xx from a reverse proxy DOES get the screen.** The
  original scope note excluded all non-transport errors; review pushed back that the
  Overview names "server down" as a target scenario, and a Caddy/nginx/Tailscale-Serve
  deployment answers **502/503/504** while the agent is down — never an auth rejection.
  Those three statuses (plus `.serviceUnavailable`) became retryable, with their own
  reason copy. *(Superseded by the iteration-2 decision below, which generalised it.)*
- **[decision, review phase 1 iteration 2] The rule is INVERTED: only a credentials
  verdict (401/403) falls back to onboarding; everything else gets the retry screen.**
  Iteration 1 kept 500 / 404 / 429 / `.decoding` on the onboarding path. Review pushed
  back that none of those is a verdict on the credentials — a 500 from the agent's DB, a
  404 from a proxy whose upstream route vanished, a captive portal's HTML — yet each one
  forces a password-mode user to retype a password that never expired, which is issue
  #62's exact symptom. The iteration-1 rationale ("a 500 is an application bug and
  retrying hides it") stopped holding once the screen gained honest per-status copy plus
  **Change server** and **Log Out**: the retry screen surfaces `HTTP 500` explicitly,
  where prefilled onboarding surfaces nothing at all. The decisive argument is that a
  stored connection was a *working* Hermes agent when onboarding persisted it, so a
  non-401/403 launch failure means the network or the server changed. The cost is one
  extra tap (**Change server**) in the genuine wrong-URL case; the saving is never
  demanding credentials for a network condition. `ConnectionFailedFeature.reasonText`
  gained honest copy for 404 / 429 / `.decoding`, and `credentialsRejectionStatuses` (now private)
  ({401, 403}) replaced `retryableServerStatuses`.
- **[decision, review phase 1] A third, non-destructive affordance: "Change server".**
  `.unreachable` covers "the agent moved host/port", for which Retry can never succeed
  and Log Out was a full wipe as the price of editing a URL. It lands on the same
  prefilled onboarding `.credentialsRejected` does — which also restores access to the
  `AgentSetupGuideView` help sheet, whose only entry points live there (so no second
  connection-help surface is introduced). *(Amended in iteration 3: the retry screen
  links the SAME guide sheet directly, as a tertiary link — still one help surface, one
  fewer screen transition to reach it. Amended in iteration 5: the transition is
  REVERSIBLE — `AppFeature` stashes the retry screen and onboarding offers a "Back to the
  connection screen" row while the stash exists, so the non-destructive escape hatch isn't
  a one-way door into re-typing a password that never expired; see Task 9.)*

## Technical Details

- `RESTError.offline` message: `"No internet connection."`; keep `.unreachable` as
  `"Couldn't reach the server."`
- `ConnectionFailedFeature.State`: `connection: ServerConnection`,
  `reason: RESTError`, `isRetrying: Bool = false`. Display strings are computed:
  title `"Can't reach the server"`, the URL from `connection.baseURL.absoluteString`,
  and a reason line — `.offline` → "You appear to be offline.", `.unreachable` → "The
  server didn't respond. If it's on a private network (VPN/Tailscale), make sure that
  connection is on." (copy final wording adjustable at view time).
  **[shipped]** `reasonText` is exhaustive over `RESTError`, and `.server` splits **4xx
  from 5xx**: a 5xx keeps "may be down or restarting — try again in a moment", while a
  4xx says the server *refused* the request and retrying won't change that, surfacing the
  server's own `detail` verbatim when present (review phase 1 iteration 3 — the agent's
  `host_header_middleware` 400 "Invalid Host header…" fires on every request when the
  agent is restarted without `--host 0.0.0.0`, and that sentence is the only actionable
  fact available).
- **[shipped]** Actions: `.retryTapped`,
  `.sceneBecameActive`, `.changeServerTapped`, `.logoutButtonTapped`,
  `.confirmationDialog(PresentationAction<Dialog>)` (Log Out confirms first — project
  convention for destructive actions), `.retrySucceeded` / `.retryFailed(RESTError)`
  (two plain cases, not one `.retryResult(Result<…>)`), `.delegate(Delegate)` with
  **four** cases: `connected(ServerConnection)`, `credentialsRejected(ServerConnection)`,
  `changeServerRequested(ServerConnection)`, `logoutConfirmed`.
- Retry effect: `rest.sessions(connection, 1, 0, .recent)`, error normalised through
  `asRESTError` (typed `RESTError` first, then `RESTError(transport:)`), `.cancellable`
  on a `CancelID.probe` with `cancelInFlight: true`. **`.retryTapped` guards on
  `isRetrying`; `.sceneBecameActive` deliberately does NOT** — it always re-probes and
  supersedes whatever is in flight, because a probe whose result never lands (60s
  `URLSession` default) would otherwise latch the spinner and brick the screen (review
  phase 1 iteration 1). `.sceneBecameActive` is forwarded by `AppFeature` from
  `.scenePhaseChanged(.active)` only when the slot exists.
- `AppFeature` auto-connect effect catch becomes
  `await send(.autoConnectFailed(connection, error as? RESTError ?? .unreachable))`.
- `AppView` branch order: `home` → `autoConnecting` → `connectionFailed` → onboarding.
- `ConnectionFeature`'s failure-footer mapping must handle `.offline` like
  `.unreachable` (compiler will flag if its switch is exhaustive).

## What Goes Where

- **Implementation Steps** (`[ ]` checkboxes): code, tests, docs in this repo.
- **Post-Completion** (no checkboxes): manual device verification, issue closure.

## Implementation Steps

### Task 1: Distinguish offline from unreachable in the REST transport

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Clients/HermesRESTClient.swift`
- Modify: `HermesKit/Sources/HermesKit/Features/ConnectionFeature.swift` (only if its
  `RESTError` switch is exhaustive)
- Modify: `HermesKit/Tests/HermesKitTests/HermesRESTClientTests.swift`

- [x] add `RESTError.offline` case + `message` copy ("No internet connection.")
- [x] add `RESTError.init(transport: Error)` (or a free `mapTransportError`) mapping
      `URLError.notConnectedToInternet`/`.dataNotAllowed`/`.internationalRoamingOff` →
      `.offline`, everything else → `.unreachable`
- [x] replace every bare `catch { throw RESTError.unreachable }` transport catch in
      the file's request helpers with the shared mapping (`login`, `get`, `postJSON`,
      `send`; the non-transport `guard let http` / `makeURL` throws stay `.unreachable`)
- [x] check `ConnectionFeature`'s failure classification handles `.offline` (map to
      the same footer as `.unreachable`)
- [x] write tests: mapping for each offline `URLError` code, a non-offline `URLError`
      (e.g. `.cannotConnectToHost`, `.timedOut`), and a non-URLError input
- [x] run `swift test --package-path HermesKit` — must pass before task 2

➕ [decision] `MockURLProtocol`'s `fail: true` stub raised `URLError(.notConnectedToInternet)`,
which now maps to `.offline` and would have flipped three existing "transport failure →
unreachable" assertions. Gave the stub a `failCode` parameter defaulting to the generic
`.cannotConnectToHost`, so those tests keep their original meaning and the offline codes
are opt-in.

### Task 2: `ConnectionFailedFeature` reducer

**Files:**
- Create: `HermesKit/Sources/HermesKit/Features/ConnectionFailedFeature.swift`
- Create: `HermesKit/Tests/HermesKitTests/ConnectionFailedFeatureTests.swift`

- [x] create the reducer: State (`connection`, `reason`, `isRetrying`), Actions and
      Delegate per Technical Details, `@Dependency(\.hermesREST)` probe effect
- [x] `.retryTapped` / `.sceneBecameActive`: set spinner, run probe; `.retrySucceeded`
      → `.delegate(.connected)`; on `.retryFailed`, **`ConnectionFailedFeature.isRetryable`
      decides**: retryable (everything that isn't a credentials verdict) → update
      `reason`, clear spinner; `.unauthorized` / `.server(401|403)` →
      `.delegate(.credentialsRejected)`
      — *shipped shape, superseding this bullet's original wording: the routing rule is
      INVERTED (see the iteration-2 decision in Solution Overview), and only `.retryTapped`
      guards on `isRetrying` — `.sceneBecameActive` supersedes via `cancelInFlight`
      (iteration-1 latch fix)*
- [x] `.logoutButtonTapped` → confirmation dialog → `.confirmationDialog(.presented(
      .confirmLogout))` → `.delegate(.logoutConfirmed)` (clears live in AppFeature);
      `.changeServerTapped` → `.delegate(.changeServerRequested)`
- [x] public inits for State (app/snapshot targets need them)
- [x] write TestStore tests: retry success, retry transport failure updates reason,
      retry auth failure delegates rejection, `sceneBecameActive` triggers retry,
      double-fire guarded while `isRetrying`, logout delegates
- [x] run `swift test --package-path HermesKit` — must pass before task 3

### Task 3: Route auto-connect failures in `AppFeature`

**Files:**
- Modify: `HermesKit/Sources/HermesKit/AppFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/AppFeatureTests.swift`

- [x] add `connectionFailed: ConnectionFailedFeature.State?` + `ifLet` composition +
      `.connectionFailed(ConnectionFailedFeature.Action)` case
- [x] extend `.autoConnectFailed` with the `RESTError` payload; route via
      `ConnectionFailedFeature.isRetryable` → populate `connectionFailed` for **every**
      failure that isn't a credentials verdict; only `.unauthorized` / `.server(401|403)`
      keeps the existing onboarding fallback verbatim
      — *shipped shape, superseding this bullet's original wording ("`.offline`/`.unreachable`
      → the screen; all other errors → onboarding"), which is the rejected non-inverted
      rule; see the iteration-2 decision in Solution Overview*
- [x] handle delegates: `.connected` → clear slot, `makeHomeState`, replay pending
      push tap (mirror `.autoConnectSucceeded`); `.credentialsRejected` → clear slot,
      onboarding prefilled (same shape as today's fallback) — as does the fourth,
      later-added `.changeServerRequested`, which prefills identically but clears
      nothing; `.logoutConfirmed` → full
      logout (delete keychain session, `clearServerURL`, `clearIdentityScopedPrefs`,
      `saveGroupingMode(.default)`, `chatSnapshot.wipeAll()`, badge reset,
      `unregisterPushOnLogout`) → fresh onboarding
- [x] forward `.scenePhaseChanged(.active)` → `.connectionFailed(.sceneBecameActive)`
      when the slot exists
- [x] write TestStore tests: unreachable → new screen, offline → new screen,
      unauthorized → onboarding fallback unchanged, `.connected` builds home and
      replays a stashed push tap, `.credentialsRejected` → onboarding prefilled,
      logout clears keychain/prefs/snapshots and lands on fresh onboarding,
      foreground forwards retry
- [x] run `swift test --package-path HermesKit` — must pass before task 4

### Task 4: `ConnectionFailedView` + root wiring

**Files:**
- Create: `HermesMobile/Sources/Features/ConnectionFailedView.swift`
- Modify: `HermesMobile/Sources/AppView.swift`
- Create: `HermesMobileTests/ConnectionFailedSnapshotTests.swift`

- [x] build the view: `wifi.exclamationmark` icon, "Can't reach the server" title,
      server URL (monospaced, breaks long URLs), reason line, prominent Retry button
      (swaps to `ProgressView` while `isRetrying`), plain/secondary Log Out button
      — *shipped additionally: a bordered "Change server" button and a tertiary
      "Need help setting up your agent?" link opening `AgentSetupGuideView` in a
      view-local `@State` sheet (review phase 1 iteration 3 — this screen now absorbs
      the launch failures the guide explains, so help must not require a detour through
      onboarding)*
- [x] add the `connectionFailed` branch to `AppView.content` (after `autoConnecting`,
      before onboarding)
- [x] run `tuist generate` so the new source file joins the app target
- [x] write snapshot tests: offline variant, unreachable variant with a long URL,
      retrying state — record via `make snapshot` run twice (never
      `make snapshot-record`)
- [x] run `make snapshot` — `ConnectionFailedSnapshotTests` records then asserts clean
      (3/3 green on the second run); see the ⚠️ note below for the pre-existing
      failures in the rest of the suite

⚠️ **Pre-existing snapshot drift, unrelated to this branch.** The first full
`make snapshot` reported 60/119 failures spread across `SettingsSnapshotTests`,
`ThinkingIndicatorSnapshotTests`, `ChatSnapshotTests` and friends. None of those views
are touched by this branch — `git diff --stat main...HEAD` lists only HermesKit sources,
HermesKit tests and this plan, plus the new `ConnectionFailedView`/`AppView` branch that
those suites never render. Two candidate causes were ruled out:
- **Dependency bump:** `tuist generate` had silently re-resolved swift-snapshot-testing
  1.19.3 → 1.19.4 (the only `HermesKit/Package.resolved` churn). Reverted to the
  committed 1.19.3 pin and regenerated — `ThinkingIndicatorSnapshotTests` still fails
  5/5, so the bump is not the cause. `Package.resolved` is left at 1.19.3, uncommitted
  churn discarded.
- **Simulator contention:** another agent's `xcodebuild` was running against the same
  simulator, but `ThinkingIndicatorSnapshotTests` uses the `componentImage()` layer
  render (no host app / key window), so it can't explain those failures either.
The remaining likely cause is environment drift (the baselines date to 2026-06-17 and
two iOS 26.x runtimes — 26.2 and 26.5 — are now installed, so `scripts/snapshot.sh`'s
`SIM_OS=26` major-version match can resolve to a different runtime than the one that
recorded them). Re-recording the whole suite is out of scope here (CLAUDE.md forbids
`make snapshot-record` for a targeted change); the new baselines were verified in
isolation with `-only-testing:HermesMobileTests/ConnectionFailedSnapshotTests`.

### Task 5: Verify acceptance criteria

- [x] transport failure at launch shows the screen with URL + reason + Retry + Log Out —
      routing: `AppFeatureTests.autoConnectUnreachableRaisesRetryScreen` /
      `.autoConnectOfflineRaisesRetryScreenWithOfflineReason` (slot populated with the
      stored `ServerConnection`, `onboarding` left untouched, so no password re-entry);
      URL + reason copy: `ConnectionFailedFeatureTests.displayStringsNameTheServerAndTheReason`;
      the transport classification that feeds the reason:
      `HermesRESTClientTests.offlineURLErrorCodesMapToOffline` + siblings; Retry/Log Out
      affordances + spinner state: the three `ConnectionFailedSnapshotTests` baselines.
      (`AppView`'s branch ordering is pinned by `HermesKitTests/AppRootScreenTests`
      over the computed `AppFeature.State.rootScreen` — `onboardingIsTheFallback`,
      `connectionFailedBeatsOnboarding`, `connectingBeatsConnectionFailed`,
      `homeBeatsEverything` — added in Task 7; there is no *image* snapshot of `AppView`
      itself, which is why the ordering is asserted as a pure function instead. It started
      out as `AppView.RootScreen.resolve` in the app target and moved into the package
      during review — pure logic belongs in HermesKit, and it cost a simulator run.)
- [x] 401 at launch still lands on onboarding exactly as before —
      `AppFeatureTests.autoLoginWithInvalidTokenFallsBackToPrefilledOnboarding` (asserts
      `connectionFailed == nil` alongside the unchanged prefilled onboarding) and
      `.autoLoginWithDeadCookieSessionFallsBackToOnboarding`. Note the **inverted** routing
      rule shipped in Task 7: a credentials verdict is the ONLY thing that falls back —
      `.autoConnectCredentialsVerdictStillFallsBackToOnboarding` (401 + a raw 403) — while
      every other server-side failure now raises the retry screen instead
      (`.autoConnectServerSideStatusRaisesRetryScreen` for 500/502/503/504/404/429 and
      `.autoConnectServerSideErrorRaisesRetryScreen` for `.serviceUnavailable`/`.notFound`/
      `.rateLimited`/`.decoding`)
- [x] retry success lands in the session list; a stashed push tap still replays —
      `AppFeatureTests.retrySuccessBuildsHomeAndReplaysStashedTap`
      (home built + `.pushTapped` replayed + slot/path land on the pushed session)
- [x] foregrounding the app auto-retries; rapid taps don't fan out into parallel probes —
      `AppFeatureTests.foregroundAutoRetriesOnTheConnectionFailedScreen` (probe → connected)
      and `.foregroundWithoutRetryScreenEmitsNoRetry`; the rapid-tap guard by
      `ConnectionFailedFeatureTests.rapidTapsAreGuardedWhileOneIsInFlight`. A **foreground
      deliberately DOES start a second probe** and supersedes the first
      (`.cancellable(cancelInFlight:)`, Task 7) rather than being swallowed by `isRetrying` —
      pinned end-to-end through the composed `.scenePhaseChanged(.active)` path by the **new**
      `AppFeatureTests.foregroundWhileRetryingSupersedesTheStalledProbe`. Re-entrancy on the
      *launch* probe is a separate, strictly once-per-process guard
      (`State.didRunLaunchProbe`): `.taskDoesNotRelaunchTheProbeWhileTheRetryScreenIsUp` and
      `.taskAfterChangeServerDoesNotRelaunchTheProbe`
- [x] logout from the screen leaves no keychain session, prefs, or snapshot cache —
      `AppFeatureTests.logoutFromRetryScreenClearsEverythingAndShowsFreshOnboarding`
      (keychain delete, server URL, pins, seen counts, profile, grouping reset, snapshot
      wipe, badge 0, push unregister with the stored token, fresh onboarding)
- [x] run full suite: `script -q /dev/null swift test --package-path HermesKit` — **1071
      tests in 58 suites passed** (as of the review-phase follow-ups; the count grew with each
      review iteration); `make snapshot` → `ConnectionFailedSnapshotTests` green
      **3/3** (verified in isolation with
      `-only-testing:HermesMobileTests/ConnectionFailedSnapshotTests` → `** TEST SUCCEEDED **`).
      The full `HermesMobileTests` run still reports the Task-4 pre-existing failures (see
      the ⚠️ note above) — now spread across `ComposerSnapshotTests`,
      `ConnectionSnapshotTests`, `ContextUsageSnapshotTests`, `HydrationSnapshotTests`,
      `SessionSnapshotTests`, `SettingsSnapshotTests`, `ThinkingIndicatorSnapshotTests`,
      none of which this branch touches. The single **non**-snapshot casualty
      (`ComposerTextViewTests.testAPasteThatLoadsNothingStillReportsAnEmptyBatch`) passes
      in isolation (29/29 for that class), confirming full-run environment contention
      rather than a regression. Re-recording the whole suite stays out of scope
      (CLAUDE.md forbids `make snapshot-record` for a targeted change).

### Task 6: [Final] Update documentation

- [x] add the connection-failed screen convention to `CLAUDE.md` (routing rule: launch
      failures → retry screen, credentials verdicts → onboarding) — added next to the
      `AgentSetupGuideView` login bullet and rewritten in Task 7 to the **inverted** rule
      that shipped: `ConnectionFailedFeature.isRetryable` sends ONLY a 401/403 credentials
      verdict to the byte-identical prefilled onboarding and raises the retry screen for
      everything else (`.offline`/`.unreachable`, a proxy's 5xx, a 404, a 429, `.decoding`);
      plus the launch-auto-connect-only scope limit (manual login keeps the onboarding
      footer, post-login drops keep the chat reconnect banner), the 4xx/5xx/transient reason
      split with its sanitized `detail`, the once-per-process launch probe, and the note that
      logout clearing lives in `AppFeature.fullLogout`
- [x] comment on issue #62 and close it (or note for closure after TestFlight) —
      commented (#62 comment 5238735643) with what shipped; **deliberately left OPEN**:
      the Post-Completion device checks (Tailscale off, airplane mode, password-mode
      session) are not done, so the comment states it is implemented on branch
      `connection-failed-screen` and pending manual device verification / TestFlight
- [ ] move this plan to `docs/plans/completed/` — handled by the exec orchestrator after
      the review phases (not moved here)

### Task 7: Review phase 1 follow-ups

- [x] add the non-destructive **Change server** affordance (action + delegate + `AppFeature`
      handler reusing the shared `fallBackToOnboarding` helper) and its tests
- [x] route a proxy's 502/503/504 (+ `.serviceUnavailable`) to the screen behind the single
      `ConnectionFailedFeature.isRetryable` rule, with its own reason copy; make `reasonText`
      exhaustive so a new `RESTError` case can't inherit VPN advice
- [x] make the probe `.cancellable(cancelInFlight:)` and let `.sceneBecameActive` supersede an
      in-flight one (the `isRetrying` guard now covers rapid *taps* only) — a probe whose result
      never lands can no longer latch the spinner; stop disabling Log Out / Change server while
      probing
- [x] `Log Out` now confirms via `ConfirmationDialogState` (project convention for destructive
      actions) and drops the inert `role: .destructive` on the plain-styled button
- [x] `.task` guards on `connectionFailed == nil`; `.autoConnectSucceeded` clears the slot;
      the two full-logout copies collapse into `AppFeature.fullLogout` (settling the
      `chatSnapshot.wipeAll()` divergence) and the two onboarding-fallback copies into
      `fallBackToOnboarding`
- [x] `asRESTError` defers to `RESTError(transport:)` instead of a blanket `.unreachable`, so a
      raw `URLError` still classifies as `.offline`
- [x] view: unlimited lines on the server URL (the `.byCharWrapping` comment claimed a wrap
      guarantee `.lineLimit(3)` didn't give) and a `ScrollView` so the buttons stay reachable at
      accessibility Dynamic Type sizes
- [x] `EmptySuccess` replaced by plain `.retrySucceeded` / `.retryFailed(RESTError)` cases
- [x] tests added: cookie/password-mode routing + retry (the headline #62 story), probe argument
      assertions, non-retryable `default:` arms, `.offline` on both manual-login paths, a raw
      `URLError` at launch, logout-while-probing, the stashed-tap origin guard (match + mismatch),
      the `.task` guard, `autoConnectSucceeded` clearing the slot, the exhaustive logout assertion
- [x] docs: README "Connect once." bullet, `docs/architecture.md` feature tree + a
      "Launch-probe failures split by kind" prose section, the CLAUDE.md bullet rewritten
- [x] `AppView`'s root branch decision extracted to the computed `AppFeature.State.rootScreen`
      (HermesKit), pinned by the new `HermesKitTests/AppRootScreenTests` — the screen is
      reachable *only* by sitting between `autoConnecting` and onboarding, and nothing guarded
      that ordering; the view is a bare `switch` over it
- [x] re-recorded ONLY the three `ConnectionFailedSnapshotTests` baselines (targeted
      `-only-testing` record-then-assert; `make snapshot-record` not used)

➕ [decision] **The `retrying` baseline gets a 1% pixel budget** (`deviceImage(precision:)`,
new optional parameter, default still a strict `1`). An indeterminate `ProgressView` is
captured at whatever rotation the render server is at, so that one baseline is inherently
non-deterministic — it failed the record-then-assert cycle at 0.4% differing pixels, all of
them inside the spinner (the previous run's green was luck). The other two baselines, and
every other pixel of this one, stay strict.

➕ [decision] **`ConnectionFeature`'s server-URL footer still folds `.offline` into
`.unreachable`.** Review noted `.offline` is computed at four catch sites but read by one
string. It is read by two now — the retry screen's reason line and, via `error.message`, the
manual-login `default:` arm ("No internet connection."), both newly pinned by tests. The
server-URL *footer* keeps mapping `.offline` → `.unreachable` deliberately: that status is
what renders the "trouble connecting to your agent?" help link, which an offline user wants
just as much.

➕ [decision] **`SIM_OS` is left unpinned.** The review flagged that the machine has both iOS
26.2 and 26.5 installed and `scripts/snapshot.sh` matches only the major version, so these
baselines encode whichever runtime resolved at record time (26.5 here). Pinning a full runtime
identifier is an environment/tooling change affecting **every** suite — it would immediately
break any machine or CI image without that exact runtime, and it can't be validated from inside
this feature's diff. Recording it here instead: the three baselines were recorded and asserted
on **iPhone 17 Pro / iOS 26.5**.

### Task 8: Review phase 1, iteration 4 follow-ups

- [x] **clamp + sanitize the quoted 4xx `detail`** (`ConnectionFailedFeature.State
      .sanitizedServerDetail`, `maxServerDetailLength = 200`): `serverDetail(from:)` falls
      back to the ENTIRE trimmed response body, and an intermediary (nginx/Cloudflare/captive
      portal) answers 4xx with a whole HTML page — which the reason line, sitting above the
      screen's three escape routes inside the `ScrollView`, would push below the fold along
      with whatever internal hostnames the proxy printed. Markup (leading `<`) is dropped
      outright, only the first line survives, and it's capped. `.lineLimit(6)` on the reason
      `Text` is the belt-and-braces half. Tests:
      `ConnectionFailedFeatureTests.fourXXDetailIsClampedAndMarkupIsDropped` (HTML/XML drop,
      first-line-only, 5 000-char truncation, and the good-case host-header passthrough)
- [x] **transient 4xx statuses get "try again" copy** (`transientRefusalStatuses = [408, 425,
      429]`): `validate` maps 429/503 to `.rateLimited`/`.serviceUnavailable` only when
      `loginSpecific`, and the launch/retry probe is a plain `get`, so a reverse proxy's
      `limit_req` 429 reached the permanent-refusal branch and was told retrying can't help.
      5xx is now matched explicitly as `500..<600` so a 3xx can't inherit it, and anything
      outside both bands gets neutral copy. Tests:
      `.transientFourXXStatusesGetTryAgainCopy`, `.outOfBandStatusesGetNeutralCopy`
- [x] **the launch probe is strictly once-per-process** (`AppFeature.State.didRunLaunchProbe`,
      set when the probe starts). The old guard inferred "already ran" from `home` /
      `connectionFailed` / `autoConnecting`, all of which are satisfied again the moment the
      user takes **Change server** — which deliberately clears nothing — so a re-sent `.task`
      would restart the launch probe and bounce them back onto the retry screen, discarding
      the URL they were editing (`fallBackToOnboarding` rebuilds `onboarding` from scratch).
      Test: `AppFeatureTests.taskAfterChangeServerDoesNotRelaunchTheProbe`
- [x] docs of record corrected: this plan's Tasks 5/6 (inverted rule, real test names, the
      foreground-supersedes semantics, `AppRootScreenTests` coverage, test count),
      `docs/architecture.md` (the manual-login `.offline` parenthetical is true of the
      **server-URL auto-probe footer only** — the token/password arms map `.offline` through
      `default:` to `.failed("No internet connection.")`, which carries no help link), and the
      CLAUDE.md bullet (three-way status split, sanitization, once-per-process probe)

## Post-Completion

**Manual verification:**
- Real device with Tailscale OFF: launch → screen appears with the server URL and the
  "server didn't respond" reason; enable Tailscale, tap Retry → session list.
- Airplane mode: launch → "offline" reason; disable, foreground → auto-retry connects.
- Password-mode session: confirm no password re-entry is ever required for a pure
  network failure.

**External systems:**
- None — no server/plugin changes involved.

### Task 9: Review phase 1, iteration 5 follow-ups

- [x] **Change server is no longer a one-way door within a process.** It clears nothing (by
      design) and the launch probe is once-per-process, so a password-mode user who tapped it
      exploratorily landed on prefilled onboarding with an EMPTY password field, no retry
      screen, and no way back short of force-quitting — re-creating #62's symptom from one tap.
      `AppFeature` now stashes the screen (`State.connectionFailedStash`, filled exactly as
      `connectionFailed` is nil'd) and sets `ConnectionFeature.State.canReturnToConnectionFailed`,
      which renders a "Back to the connection screen" row above everything else on
      `ConnectionView`; `.returnToConnectionFailedTapped` → `.delegate(...Requested)` → the
      parent restores it, normalized (`isRetrying = false`, dialog dismissed) and WITHOUT an
      auto re-probe. A **credentials rejection deliberately does not stash** (going back to a
      Retry the server already answered with a 401 is a loop, not an escape), and a successful
      manual login or a `fullLogout` drops the stash so it can never point at an abandoned
      server. `didRunLaunchProbe` is untouched — it is correct as written; this adds the
      missing route rather than re-arming the probe. Tests:
      `AppFeatureTests.returningFromOnboardingRestoresTheStashedRetryScreen`,
      `.returningWithoutAStashOnlyClearsTheFlag`, `.manualLoginDropsTheStashedRetryScreen`,
      `.fullLogoutDropsTheStashedRetryScreen`, the stash assertions added to
      `.changeServerLandsOnPrefilledOnboardingWithoutClearingAnything` /
      `.retryCredentialsRejectedFallsBackToPrefilledOnboarding`,
      `ConnectionFeatureTests.returnToConnectionFailedIsPureRouting`, and the new
      `ConnectionSnapshotTests.testConnectionView_returnToConnectionFailed` baseline (the row is
      flag-gated, so the other six baselines in that suite are byte-identical)
- [x] the last two `asRESTError` stragglers routed through the funnel:
      `SessionListFeature`'s push-register catch and the shared cron-action catch, which both
      hardcoded `.unreachable` for a non-`RESTError`. Only the cron one is observable (its
      `loadError` banner now reads "No internet connection." offline — test
      `SessionListCronTests.offlineActionFailureUsesTheOfflineCopy`); `pushRegisterFailed` only
      ever compares against `.notFound`, so that half is consistency, not behaviour
