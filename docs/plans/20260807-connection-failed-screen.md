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
  same `rest.sessions` probe. Success → delegate `.connected`; another transport
  failure → update the reason in place; auth rejection → delegate
  `.credentialsRejected`. Logout → delegate `.logoutTapped`. Foreground auto-retry is
  a guarded re-entry into the same retry effect.
- **`AppFeature` routing**: `.autoConnectFailed` gains the `RESTError` payload.
  Transport failures (`.offline`/`.unreachable`) populate the new
  `connectionFailed: ConnectionFailedFeature.State?` slot; every other error keeps
  today's onboarding fallback. Delegates: `.connected` mirrors `.autoConnectSucceeded`
  (build home, replay pending push tap); `.credentialsRejected` falls back to
  onboarding prefilled; `.logoutTapped` runs the full-logout recipe (keychain +
  all prefs + snapshot wipe + badge reset + push unregister) and lands on a **fresh**
  onboarding.
- Key decisions: prefs/keychain clearing lives in `AppFeature`'s delegate handler
  (next to the two existing logout paths and the push unregister helper), keeping the
  child reducer pure routing + retry. `.decoding`/5xx deliberately do NOT get the new
  screen (kept minimal per review; captive portals will surface as onboarding fallback
  exactly as today).

## Technical Details

- `RESTError.offline` message: `"No internet connection."`; keep `.unreachable` as
  `"Couldn't reach the server."`
- `ConnectionFailedFeature.State`: `connection: ServerConnection`,
  `reason: RESTError`, `isRetrying: Bool = false`. Display strings are computed:
  title `"Can't reach the server"`, the URL from `connection.baseURL.absoluteString`,
  and a reason line — `.offline` → "You appear to be offline.", `.unreachable` → "The
  server didn't respond. If it's on a private network (VPN/Tailscale), make sure that
  connection is on." (copy final wording adjustable at view time).
- Actions: `.retryTapped`, `.sceneBecameActive`, `.logoutTapped`,
  `.retryResult(Result<Void, RESTError>)` (internal), `.delegate(Delegate)` with
  `Delegate { connected(ServerConnection), credentialsRejected(ServerConnection),
  logoutTapped }`.
- Retry effect: `rest.sessions(connection, 1, 0, .recent)`, error mapped
  `error as? RESTError ?? .unreachable`. `.retryTapped`/`.sceneBecameActive` guard on
  `isRetrying` (no double-fire); `.sceneBecameActive` is forwarded by `AppFeature`
  from `.scenePhaseChanged(.active)` only when the slot exists.
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
- [x] `.retryTapped` / `.sceneBecameActive`: guard `!isRetrying`, set spinner, run
      probe; `.retryResult(.success)` → `.delegate(.connected)`;
      `.offline`/`.unreachable` failure → update `reason`, clear spinner;
      any other `RESTError` → `.delegate(.credentialsRejected)`
- [x] `.logoutTapped` → `.delegate(.logoutTapped)` (clears live in AppFeature)
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
- [x] extend `.autoConnectFailed` with the `RESTError` payload; route
      `.offline`/`.unreachable` → populate `connectionFailed`; all other errors keep
      the existing onboarding fallback verbatim
- [x] handle delegates: `.connected` → clear slot, `makeHomeState`, replay pending
      push tap (mirror `.autoConnectSucceeded`); `.credentialsRejected` → clear slot,
      onboarding prefilled (same shape as today's fallback); `.logoutTapped` → full
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
      (`AppView`'s branch ordering is code-verified — `AppView` has no snapshot coverage
      for any of its branches in this project.)
- [x] 401 at launch still lands on onboarding exactly as before —
      `AppFeatureTests.autoLoginWithInvalidTokenFallsBackToPrefilledOnboarding` (asserts
      `connectionFailed == nil` alongside the unchanged prefilled onboarding) and
      `.autoLoginWithDeadCookieSessionFallsBackToOnboarding`;
      `.autoConnectServerErrorStillFallsBackToOnboarding` pins the same for non-transport,
      non-auth errors
- [x] retry success lands in the session list; a stashed push tap still replays —
      `AppFeatureTests.retrySuccessBuildsHomeAndReplaysStashedTap`
      (home built + `.pushTapped` replayed + slot/path land on the pushed session)
- [x] foregrounding the app auto-retries; no double-probe while one is in flight —
      `AppFeatureTests.foregroundAutoRetriesOnTheConnectionFailedScreen` (probe → connected)
      and `.foregroundWithoutRetryScreenEmitsNoRetry`; the in-flight guard by
      `ConnectionFailedFeatureTests.retryIsGuardedWhileOneIsInFlight` plus the **new**
      `AppFeatureTests.foregroundWhileRetryingDoesNotDoubleProbe`, added here because
      nothing covered the guard through the composed `.scenePhaseChanged(.active)` path
- [x] logout from the screen leaves no keychain session, prefs, or snapshot cache —
      `AppFeatureTests.logoutFromRetryScreenClearsEverythingAndShowsFreshOnboarding`
      (keychain delete, server URL, pins, seen counts, profile, grouping reset, snapshot
      wipe, badge 0, push unregister with the stored token, fresh onboarding)
- [x] run full suite: `script -q /dev/null swift test --package-path HermesKit` — **1042
      tests in 58 suites passed**; `make snapshot` → `ConnectionFailedSnapshotTests` green
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

- [ ] add the connection-failed screen convention to `CLAUDE.md` (routing rule: launch
      transport failures → retry screen, auth failures → onboarding)
- [ ] comment on issue #62 and close it (or note for closure after TestFlight)
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion

**Manual verification:**
- Real device with Tailscale OFF: launch → screen appears with the server URL and the
  "server didn't respond" reason; enable Tailscale, tap Retry → session list.
- Airplane mode: launch → "offline" reason; disable, foreground → auto-retry connects.
- Password-mode session: confirm no password re-entry is ever required for a pure
  network failure.

**External systems:**
- None — no server/plugin changes involved.
