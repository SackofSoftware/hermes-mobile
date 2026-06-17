# Multi-Profile Switching for New Chats

GitHub issue: #1 — "Need to have ability to switch/select profiles for new chats"

## Overview

Let the user keep **multiple Hermes profiles** on a single agent and switch between
them from the sessions list. Each profile is an independent Hermes environment
(separate config, skills, SOUL.md) with **its own list of sessions**. New chats are
created under the currently-selected profile.

The default profile always exists and can't be renamed/deleted; custom profiles can
be created, renamed, and deleted.

**Key divergence from the desktop:** the desktop relaunches its local backend under a
new `HERMES_HOME`. The mobile app is a **thin remote client over Tailscale and cannot
relaunch the agent** — it uses Hermes' **per-call profile scoping** instead:

- Selected profile is **device-local** (a persisted pref, the profile *name*) — we do
  **not** call `POST /api/profiles/active` (that changes the server's sticky default and
  affects other clients).
- List sessions per profile via `GET /api/profiles/sessions?profile={name}&…`.
- `session.create` / `session.resume` pass a `profile` param so the agent binds that
  profile's `HERMES_HOME` + `state.db` for the turn.
- Session-scoped reads/mutations (messages, archive, rename) take an optional
  `?profile={name}` query param when the active profile isn't the default.

The color setting (desktop has one) is **intentionally omitted** on mobile.

## Context (from discovery)

### Codebase facts (verified)

- **`HermesRESTClient`** (`HermesKit/Sources/HermesKit/Clients/HermesRESTClient.swift`)
  is a flat `@DependencyClient`-style struct of `@Sendable` closures taking a
  `ServerConnection`. Has `live(session:)`, `liveValue`, `testValue`. Helpers
  `makeURL`, `get`, `postJSON`, `send` + private DTOs (`SessionListDTO`, etc.).
- **`PreferencesClient`** (`Clients/PreferencesClient.swift`) uses paired
  `loadX`/`saveX` closures (e.g. `loadGroupingMode`/`saveGroupingMode`), with
  `live(defaults:)` + `inMemory()`. This is the exact shape for the selected-profile
  pref.
- **`SessionListFeature.State`** (`Features/SessionListFeature.swift`) already holds
  `connection`, `sessions: IdentifiedArrayOf<Session>`, search/grouping state, and
  uses `@Presents` for `settings`, `archived`, `confirmationDialog`. `fetchSessions(...)`
  (line ~511) is the fetch helper; `.task`/refresh paths call it (lines ~239, ~494).
- **`ChatFeature.bootstrapSession(stored:)`** (line ~1009) chooses
  `session.create`/`session.resume` and builds `params: JSONValue` as an object —
  threading a `profile` key is a one-line change. `gateway.send(method, params)` takes
  a `JSONValue`.
- **`GatewayError.isUnknownMethod`** exists for old-agent gating. REST gating needs a
  404 check on `/api/profiles`.
- **Logout** clears prefs in `SettingsFeature.swift:92-97`
  (`clearServerURL`/`savePinnedIDs([])`/`saveSeenCounts([:])`/`saveGroupingMode(.default)`)
  — the selected-profile clear goes here.
- **`Session`** model has **no** `profileName` field; only needed for the out-of-scope
  `profile=all` unified mode, so we skip adding it.

### Desktop reference (resolves the issue's open questions)

Source: `/Users/eugene/Documents/Development/Personal/hermes-agent/apps/desktop`

1. **SOUL.md is NOT a `POST /api/profiles` field.** The create flow is two calls
   (`create-profile-dialog.tsx`):
   ```
   createProfile({ name, clone_from_default })           // POST /api/profiles
   if (soul.trim()) updateProfileSoul(name, soul)         // PUT /api/profiles/{name}/soul  { content }
   ```
2. **Profile scoping** (`hermes.ts`):
   - List per profile: `GET /api/profiles/sessions?profile={name}&limit=&offset=&min_messages=&archived=&order=`
     (`archived` ∈ `exclude|include|only` — archived list is the same endpoint with `archived=only`).
   - Messages: `GET /api/sessions/{id}/messages?profile={name}` (omit for default).
   - Archive/rename (`PATCH /api/sessions/{id}`): pass `profile` (query/body) when non-default.
   - **Search is NOT profile-scoped** on desktop (`searchSessions` sends no profile) — mirror that.
   - Omitting `profile` (or empty) → default/primary, so single-profile users are unaffected.
3. **Validation regex** (confirmed): `^[a-z0-9][a-z0-9_-]{0,63}$`; hint text:
   _"Lowercase letters, digits, hyphens, and underscores. Must start with a letter or digit."_
4. **Gating:** missing `/api/profiles` (404) → hide the selector, behave as today.

### REST API surface (base URL, `X-Hermes-Session-Token` header)

| Operation | Endpoint | Method | Request | Response |
|-----------|----------|--------|---------|----------|
| List profiles | `/api/profiles` | GET | — | `{ profiles: ProfileInfo[] }` |
| Create | `/api/profiles` | POST | `{ name, clone_from_default }` | `{ ok, name, path }` |
| Set SOUL.md | `/api/profiles/{name}/soul` | PUT | `{ content }` | `{ ok }` |
| Rename | `/api/profiles/{name}` | PATCH | `{ new_name }` | `{ ok, name, path }` |
| Delete | `/api/profiles/{name}` | DELETE | — | `{ ok, path }` |
| Sessions for profile | `/api/profiles/sessions?profile={name}&archived=&order=&limit=&offset=` | GET | — | `{ sessions, profile_totals }` |

`ProfileInfo` fields we use: `name`, `is_default`, `model?`, `provider?`,
`skill_count`, `has_env`.

## Development Approach

- **Testing approach: Regular** (implement a unit, then write/update its tests in the
  same task before moving on — matches the existing `TestStore` + snapshot workflow).
- Complete each task fully before the next; small focused changes.
- **CRITICAL: every task includes new/updated tests** (success + error paths) and **all
  tests must pass before the next task.** Run via
  `script -q /dev/null swift test --package-path HermesKit` (or `make test`); snapshots
  via `make snapshot` / `make snapshot-record`.
- Commit at each task completion (per project convention — don't batch).
- Maintain backward compatibility: on agents without the profiles API the UI is
  identical to today.
- **New source files require `tuist generate`** before an `xcodebuild`/snapshot run
  picks them up.

## Testing Strategy

- **Unit tests (HermesKit, required every task):** TCA reducers via `TestStore` +
  `@Dependency` overrides + `TestClock`; client request-building / DTO decoding;
  pure name validation. Event-reduction tests are the highest-value suite.
- **Snapshot tests (`HermesMobileTests`):** the profile pill + menu in
  `SessionListView`, and the Add-profile form (valid / inline-error / server-banner
  states). Row timestamps stay pinned for determinism. Re-record with
  `make snapshot-record` when UI changes intentionally.
- No project e2e/UI-automation suite beyond snapshots.

## Progress Tracking

- mark completed items `[x]` immediately when done
- add newly discovered tasks with ➕ prefix; blockers with ⚠️
- keep this file in sync if scope changes

## Solution Overview

- A new **`HermesProfileClient`** `@DependencyClient` owns all profile REST (CRUD +
  SOUL.md + profile-scoped session lists), keeping `HermesRESTClient` focused.
- A pure **`ProfileName`** validator (regex + hint) lives in HermesKit, unit-tested and
  shared by the Add-profile reducer and view.
- **`PreferencesClient`** gains a device-local selected-profile pref, cleared on logout.
- **`SessionListFeature`** holds `profiles` + `selectedProfile`, fetches the scoped
  list, gates the selector on capability, presents an `AddProfileFeature` sheet and
  rename/delete `ConfirmationDialogState`, and resets list UI on switch.
- **`AddProfileFeature`** is a self-contained TCA reducer (name + clone toggle + soul),
  doing create-then-PUT-soul and mapping server 400 → an error banner.
- **`ChatFeature`** threads the selected profile into `session.create`/`session.resume`.
- Existing session-scoped REST calls (messages/archive/rename) take an optional
  `profile` arg, defaulting to today's behavior.

## Technical Details

- **`Profile`** Codable model: `name`, `isDefault`, `model?`, `provider?`,
  `skillCount`, `hasEnv` — `CodingKeys` map snake_case (`is_default`, `skill_count`,
  `has_env`). `Identifiable` by `name`.
- **Scoped-list query:** reuse `SessionListDTO` decoding; the response wrapper exposes
  `sessions` (ignore `profile_totals` for MVP). `archived` param ∈ `exclude|only`.
- **Profile param threading:** a non-nil/non-default profile name adds
  `?profile={name}` (reads) or includes it in the body/query (PATCH). Default/`nil` →
  no param (today's exact requests).
- **Capability flag:** `SessionListFeature.State.profilesSupported: Bool` — set false
  when `profiles.list` throws a 404-equivalent (`RESTError` for 404 / unknown route);
  when false, the pill renders as the static `Sessions` title and no scoping is applied.
- **Gateway profile param:** in `bootstrapSession`, when a non-default profile is
  active, add `"profile": .string(name)` to the create/resume params object.

## What Goes Where

- **Implementation Steps** (`[ ]`): models, clients, reducers, views, tests, docs.
- **Post-Completion** (no checkboxes): manual on-device verification against the live
  agent, and SOUL.md/profile-scope behaviors that can only be confirmed against a real
  multi-profile server.

## Implementation Steps

### Task 1: `Profile` model

**Files:**
- Create: `HermesKit/Sources/HermesKit/Models/Profile.swift`
- Create: `HermesKit/Tests/HermesKitTests/ProfileTests.swift`

- [x] add `public struct Profile: Equatable, Sendable, Identifiable, Decodable` with
      `name`, `isDefault`, `model: String?`, `provider: String?`, `skillCount: Int`,
      `hasEnv: Bool`; `id` = `name`; explicit `public init`
- [x] `CodingKeys` mapping `is_default`/`skill_count`/`has_env`; tolerate missing
      optional fields (lenient decode, never crash)
- [x] write tests: decode a full `ProfileInfo` JSON payload (default + custom)
- [x] write tests: decode with missing optionals (`model`/`provider` absent) succeeds
- [x] run tests — must pass before next task

### Task 2: `ProfileName` validation (pure)

**Files:**
- Create: `HermesKit/Sources/HermesKit/Models/ProfileName.swift`
- Create: `HermesKit/Tests/HermesKitTests/ProfileNameTests.swift`

- [x] add `public enum ProfileName` with `static let hint: String` (verbatim desktop
      copy) and `static func isValid(_:) -> Bool` using `^[a-z0-9][a-z0-9_-]{0,63}$`
      (validate the trimmed string)
- [x] write tests: valid names (`my-profile`, `a`, `a_b-c`, 64-char max)
- [x] write tests: invalid (`testOS` uppercase, leading `-`/`_`, empty, 65 chars, spaces)
- [x] run tests — must pass before next task

### Task 3: `HermesProfileClient` — CRUD + SOUL.md + scoped sessions

**Files:**
- Create: `HermesKit/Sources/HermesKit/Clients/HermesProfileClient.swift`
- Create: `HermesKit/Tests/HermesKitTests/HermesProfileClientTests.swift`

- [x] add `public struct HermesProfileClient: Sendable` with `@Sendable` closures:
      `list(ServerConnection) -> [Profile]`,
      `create(ServerConnection, name, cloneFromDefault) -> Void`,
      `updateSoul(ServerConnection, name, content) -> Void`,
      `rename(ServerConnection, name, newName) -> Void`,
      `delete(ServerConnection, name) -> Void`,
      `sessions(ServerConnection, profile, archived, order, limit, offset) -> [Session]`
- [x] implement `live(session:)` hitting the endpoints in the API table (reuse the
      existing `makeURL`/`get`/`postJSON`/`send` helpers — promote to internal or
      duplicate minimally; prefer reuse); `archived` enum → `exclude|only`
- [x] add `liveValue`, `testValue` (empty), `inMemory()` (in-memory profile store) and a
      `DependencyValues.hermesProfiles` accessor
- [x] write tests: `list` decodes `{ profiles: [...] }` via an injected stub
      `URLSession`/transport; request hits `/api/profiles`
- [x] write tests: `create` posts `{ name, clone_from_default }`; `updateSoul` PUTs
      `{ content }` to `/api/profiles/{name}/soul`; `rename` PATCHes `{ new_name }`;
      `sessions` builds the `?profile=&archived=&order=` query and decodes rows
- [x] write tests: a 404 from `list` surfaces a `RESTError` the caller can detect for
      gating
- [x] run tests — must pass before next task

### Task 4: Profile-scope existing session-scoped REST calls

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Clients/HermesRESTClient.swift`
- Modify: `HermesKit/Tests/HermesKitTests/HermesRESTClientTests.swift` (or create if absent)

- [x] add an optional `profile: String?` parameter (default `nil`) to `messages`,
      `archive`, and `rename`; when non-nil add `?profile={name}` (reads) / include in
      body+query (PATCH). `nil` → byte-identical to today's request
- [x] update existing call sites that don't pass a profile (defaulted — no behavior change)
- [x] leave `search` un-scoped (mirrors desktop)
- [x] write tests: with `profile` nil the URL/body is unchanged (regression guard)
- [x] write tests: with a profile name the query/body carries `profile`
- [x] run tests — must pass before next task

### Task 5: `PreferencesClient` selected-profile pref

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Clients/PreferencesClient.swift`
- Modify: `HermesKit/Tests/HermesKitTests/PreferencesClientTests.swift` (or create)

- [x] add `loadSelectedProfileID: @Sendable () -> String?` / `saveSelectedProfileID:
      @Sendable (String) -> Void` / `clearSelectedProfileID: @Sendable () -> Void`
      using key `hermes.selected-profile-id`; wire into `live(defaults:)` and `inMemory()`
- [x] write tests: save → load round-trip; clear removes it; `inMemory` variant behaves
      identically
- [x] run tests — must pass before next task

### Task 6: Clear selected profile on logout

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/SettingsFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/SettingsFeatureTests.swift`

- [x] in the `.clearTokenTapped` handler (line ~92) add
      `preferences.clearSelectedProfileID()` alongside the existing prefs clears
- [x] update/extend the logout test to assert the selected profile is cleared
- [x] run tests — must pass before next task

### Task 7: `AddProfileFeature` reducer

**Files:**
- Create: `HermesKit/Sources/HermesKit/Features/AddProfileFeature.swift`
- Create: `HermesKit/Tests/HermesKitTests/AddProfileFeatureTests.swift`

- [x] State: `name`, `cloneFromDefault: Bool = true`, `soul: String`, `isCreating: Bool`,
      `errorBanner: String?`, `connection: ServerConnection`; computed
      `nameError: String?` (nil unless non-empty & invalid → `ProfileName.hint`) and
      `canCreate: Bool` (non-empty, valid, not creating)
- [x] Actions: `binding`, `createTapped`, `createResponse(Result<String, …>)`,
      `cancelTapped`; delegate `.created(name:)` so the parent refreshes/selects
- [x] `createTapped` effect: `profiles.create` then, if `soul` non-blank,
      `profiles.updateSoul`; success → `.delegate(.created(name))`; failure → map to
      `errorBanner` (surface server 400 `detail` verbatim via `RESTError.message`)
- [x] use `@Dependency(\.hermesProfiles)`; capture it explicitly in the `@Sendable` effect
- [x] write tests: typing `testOS` sets `nameError` and `canCreate == false`; valid name
      enables create
- [x] write tests: create success emits `.delegate(.created)` and calls `updateSoul` only
      when soul non-blank
- [x] write tests: server 400 sets `errorBanner` to the server `detail` and clears `isCreating`
- [x] run tests — must pass before next task

### Task 7b: Surface server error `detail` in `RESTError` (discovered during Task 7)

Task 7's banner requires the server's JSON `detail` verbatim, but `RESTError` discarded
the response body — the banner only ever showed the generic `Server error (400).`.

- [x] `validate` reads the response body; `RESTError` carries the server `detail`; `.message` shows it verbatim
- [x] updated `HermesProfileClientTests` 400 assertion + added detail-vs-fallback tests
- [x] full suite green

### Task 8: `SessionListFeature` — profiles state, switching, capability gating, presentation

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/SessionListFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/SessionListFeatureTests.swift`

- [x] State: add `profiles: IdentifiedArrayOf<Profile>`, `selectedProfileName: String`
      (default the persisted value or `"default"`), `profilesSupported: Bool`,
      `@Presents var addProfile: AddProfileFeature.State?`; reuse existing
      `confirmationDialog` for delete
- [x] on `.task`: load persisted selected profile; fetch `profiles.list` → on success
      populate `profiles`/`profilesSupported = true`, on 404 set
      `profilesSupported = false` (selector hidden); fetch sessions via the scoped
      endpoint when supported, else today's `/api/sessions`
- [x] `selectProfile(name)`: persist via `saveSelectedProfileID`, set
      `selectedProfileName`, reset list UI (clear `searchQuery`, `expandedGroups`),
      refetch scoped sessions
- [x] route session-scoped reads/mutations (messages-open path stays in ChatFeature;
      archive/rename here) through the active profile when non-default
- [x] add `addProfileTapped` → present `AddProfileFeature`; handle
      `.addProfile(.presented(.delegate(.created(name))))` → refresh profiles, select
      the new one
- [x] add rename/delete for custom profiles: rename via `profiles.rename` (optimistic
      with rollback, mirroring session rename); delete behind `ConfirmationDialogState`
      → `profiles.delete`, then if the deleted profile was active fall back to `default`
      and refetch. Guard: default profile is never renamable/deletable
- [x] `.ifLet(\.$addProfile, action: …)` scope; ensure logout/disappear cancels nothing
      new (no extra effects)
- [x] write tests: `.task` populates profiles + scoped sessions (TestStore + stub clients)
- [x] write tests: 404 from `profiles.list` sets `profilesSupported = false` and falls
      back to the unscoped session fetch
- [x] write tests: `selectProfile` persists the pref, resets search/expanded, refetches
- [x] write tests: created-profile delegate refreshes + selects; delete confirmation
      flow deletes and re-homes to default; default profile cannot be renamed/deleted
- [x] run tests — must pass before next task

### Task 9: `ChatFeature` — thread profile into `session.create`/`session.resume`

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/ChatFeatureTests.swift`

- [x] add a `profileName: String?` to ChatFeature State (passed in by the parent when
      opening/creating a chat under the selected profile)
- [x] in `bootstrapSession`, when `profileName` is non-nil/non-default add
      `"profile": .string(name)` to the create/resume params object; default → unchanged
- [x] route the chat's history hydration (REST `messages`) through the same profile
- [x] write tests: create/resume params include `profile` when set; absent when nil
      (regression guard against today's exact params)
- [x] run tests — must pass before next task

### Task 10: Wire the selected profile through navigation (AppFeature / parent)

**Files:**
- Modify: `HermesKit/Sources/HermesKit/AppFeature.swift` (or wherever SessionList opens Chat)
- Modify: relevant feature tests

- [ ] when `SessionListFeature` opens a chat (`openSession` / new chat), pass
      `selectedProfileName` into the `ChatFeature.State`
- [ ] write tests: opening a session under a non-default profile constructs Chat state
      with that profile
- [ ] run tests — must pass before next task

### Task 11: `SessionListView` — profile pill + menu (UI)

**Files:**
- Modify: `HermesMobile/Sources/.../SessionListView.swift`
- Modify: `HermesMobileTests/.../SessionListSnapshotTests.swift`

- [ ] replace `navigationTitle("Sessions")` with a centered **profile pill** (principal
      toolbar item): icon + profile name + chevron. Default profile shows
      `house`/`house.fill`; custom profiles show no leading icon. When
      `profilesSupported == false`, render the static `Sessions` title (no pill)
- [ ] tapping the pill opens a `Menu`: profiles list with a checkmark on the active one,
      a divider, then a `+ Add profile` row → `addProfileTapped`
- [ ] add rename/delete affordances for custom profiles (context menu / menu actions),
      hidden/disabled for default
- [ ] present the `AddProfileFeature` sheet via `.sheet(item: $store.scope(...))`; keep
      existing Settings (leading) + Organize (trailing) toolbar items
- [ ] run `tuist generate`; add/record snapshots: pill default state, menu open
      (with custom profiles + checkmark + divider + Add row), single-profile fallback
- [ ] `make snapshot` — must pass before next task

### Task 12: `AddProfileView` — form (UI)

**Files:**
- Create: `HermesMobile/Sources/.../AddProfileView.swift`
- Modify: `HermesMobileTests/.../AddProfileSnapshotTests.swift`

- [ ] build the form: Name field (with inline error styling + `ProfileName.hint` helper
      text), "Clone from default" toggle (default on, with the desktop helper copy),
      optional multiline SOUL.md field (placeholder copy), a server-error warning banner
      below the form, primary **Create profile** (disabled unless `canCreate`) +
      secondary **Cancel**
- [ ] run `tuist generate`; add/record snapshots: pristine, inline-invalid-name
      (`testOS`), and server-400-banner states
- [ ] `make snapshot` — must pass before next task

### Task 13: Verify acceptance criteria

- [ ] header shows the active profile as a Safari-style pill; tap lists all profiles
      (checkmark on active) + divider + `+ Add profile`
- [ ] default profile shows a home icon; custom profiles don't
- [ ] switching reloads the scoped session list; new chats create under it
- [ ] Add-profile form matches desktop fields with inline regex validation **and**
      server-400 banner
- [ ] custom profiles rename/delete (delete confirmed); default cannot
- [ ] selected profile persists across launches and clears on logout
- [ ] graceful fallback (selector hidden) on agents without the profiles API
- [ ] run full suite: `script -q /dev/null swift test --package-path HermesKit` and
      `make snapshot`; color setting confirmed omitted

### Task 14: [Final] Documentation

**Files:**
- Modify: `CLAUDE.md`, `docs/architecture.md` (if profile scoping warrants a note)

- [ ] add a CLAUDE.md convention note: profiles are device-local (selected name pref,
      cleared on logout), per-call scoping over `/api/profiles/sessions` +
      `?profile=`, create-then-PUT-soul, capability-gated selector, color omitted
- [ ] update `docs/architecture.md`/`README.md` feature list if needed
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion

*Items requiring manual intervention or a live multi-profile agent — no checkboxes.*

**Manual verification (live agent over Tailscale):**
- Create a custom profile from the app; confirm it appears on the desktop and that its
  SOUL.md took the supplied text (verifies the create-then-PUT-soul sequence).
- Switch profiles and confirm the session list is genuinely scoped (sessions differ per
  profile) and that a new chat lands in the selected profile's `state.db`.
- Open/resume/rename/archive a session under a non-default profile and confirm the
  `?profile=` scoping resolves the correct `state.db` (issue open-question #2 — desktop
  scopes messages/archive/rename but not search; confirm search behavior is acceptable
  for mobile or revisit).
- Trigger a reserved-name server 400 (e.g. name `test`) and confirm the banner shows the
  server `detail` verbatim.
- Point the app at an **older agent without `/api/profiles`** and confirm the selector is
  hidden and behavior is identical to today.

**External:** none — server-side profile API already exists on the Hermes agent.
