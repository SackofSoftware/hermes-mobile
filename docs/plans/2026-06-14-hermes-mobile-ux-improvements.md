# Hermes Mobile — UX Improvements

## Overview

The MVP (see [`completed/2026-06-09-hermes-ios-mvp.md`](completed/2026-06-09-hermes-ios-mvp.md))
shipped the full loop but with several rough UX edges. This plan fixes them:

1. **Auto-login** — the token (Keychain) and server URL are effectively persisted, yet
   the app re-runs onboarding on every launch. If a usable connection is stored, skip
   onboarding and land on the session list. Logout stays the Settings "Clear token &
   disconnect" button.
2. **Auto-validating connection screen** — drop the separate "Check server" button;
   validate automatically after a typing pause, on paste, and on focus-loss/return.
3. **Session grouping** — group the list **by workspace** exactly like the Hermes desktop
   app (by the session's `cwd`, labelled by folder basename, projects in recency order).
4. **Tool/skill activity rows** — tool/skill calls currently render as empty bubbles.
   Show a titled, tappable row (icon + human title + duration) with a chevron that opens a
   detail sheet (args/result/diff) like the Claude app. Add a floating "scroll to bottom"
   button (liquid-glass on iOS 26+) shown only when the user is scrolled up.
5. **Composer redesign** — match the Claude-app composer (per screenshots) but: replace
   the "code" button with the **current model name + reasoning effort** (tappable →
   interactive picker), show a **disabled voice-input** button (placeholder), and colour
   the **send button Hermes yellow-orange**.

## Context (from discovery)

- **Stack**: TCA reducers + clients in `HermesKit` (`swift test`, no simulator); thin
  SwiftUI app in `HermesMobile` (Tuist-generated); iOS XCTest snapshot target
  `HermesMobileTests`. Regular testing (code, then tests). 101 unit + 13 snapshot tests
  currently green.
- **#1**: `AppFeature.State` gates onboarding on `home == nil`. `KeychainClient` stores
  **only the token**; the **server URL is persisted nowhere** → must add URL persistence
  and a launch-time auto-connect. `AppFeature` has no `.task`/launch hook today.
- **#2**: `ConnectionFeature` has separate `checkServerTapped` + `connectTapped` and a
  `Status` enum (idle/checking/…/reachable/validating/invalidToken). `ConnectionView` has
  two gated buttons.
- **#3**: Verified against Hermes source — `/api/sessions` returns **`cwd`** (the query is
  `SELECT s.*` and the `sessions` table has a `cwd TEXT` column; the docstring just omits
  it). Desktop `workspaceGroupsFor` (`apps/desktop/src/app/chat/sidebar/index.tsx`):
  group by `cwd?.trim()` (empty → "No workspace"), label = `baseName(path)`, **groups in
  recency order** (Map insertion over a recency-sorted list), **rows within a group sorted
  by `started_at` desc**. Mobile `Session` model lacks `cwd`; `SessionListDTO` doesn't map
  it.
- **#4**: `ChatRow.tool(name, state, result, durationS)` → `ToolStatusView` (a minimal
  `DisclosureGroup`). The server's `tool.start` carries `{tool_id, name, context,
  args_text?}` and `tool.complete` carries `{tool_id, name, args, duration_s?, result,
  summary?, result_text?, inline_diff?}` — richer than we model. Empty bubbles come from
  tool-only turns (empty assistant `message.start` rows) and/or unrendered tool titles.
  `GatewayEvent.toolStart/toolComplete` already decode `name`/`result`/`duration_s` but
  drop `args`/`summary`/`context`/`inline_diff`.
- **#5**: Composer is a plain `TextField` + send button (`ComposerView`). Model/reasoning
  switching (verified): `model.options` (list available, takes `session_id`) +
  `config.set {session_id, key:"model", value}` — **rejected with 4009 while the session is
  running**; reasoning effort via `config.set` (`reasoning_effort` key). Current values
  live on the `session.info` event (`model`, `reasoning_effort`), which `ChatFeature`
  currently ignores. `SessionInfo` decodes `model` but not `reasoning_effort`.
- App icon is yellow-orange ("HA"); no shared brand `Color` exists yet.

## Development Approach

- **Testing approach: Regular** (code first, then tests) — matches the project.
- Complete each task fully before the next; small, focused changes.
- **Every task MUST add/update tests** (reducer/unit tests as separate checklist items;
  snapshot tests for UI changes — re-record baselines when UI changes intentionally).
- **All tests must pass before starting the next task.**
- Update this plan when scope changes during implementation.
- Keep the `HermesKit` boundary clean; views stay thin.

## Testing Strategy

- **Unit tests (TCA)**: `TestStore` + `@Dependency` overrides + `TestClock`. Highest value:
  auto-connect launch flow, debounced validation, workspace grouping, tool-row folding,
  model-picker round-trips (assert exact RPC params), sessionInfo folding.
- **Snapshot tests** (`HermesMobileTests/PreviewSnapshotTests`): grouped session list, the
  new tool/skill row + detail sheet, scroll-to-bottom affordance, and the redesigned
  composer (with model/reasoning chip, disabled voice, brand send button). Re-record via
  `make snapshot-record`; verify via `make snapshot`.
- No new e2e harness (project has none).

## Progress Tracking

- Mark completed items `[x]` immediately. Add discovered tasks with ➕, blockers with ⚠️.
- Keep the plan in sync with actual work.

## Solution Overview

- **Persistence (#1)**: persist the server URL via `@Shared(.appStorage("server-url"))`
  (non-sensitive) alongside the Keychain token. On launch, `AppFeature` reads both; if a
  token + URL exist it attempts a silent validate (`GET /api/sessions?limit=1`) and, on
  success, opens the session list directly — otherwise falls back to onboarding. Settings
  "Clear token & disconnect" also clears the stored URL.
- **Auto-validation (#2)**: fold check+validate into one staged flow driven by edits.
  Debounce the URL (≈600ms via `clock.sleep` + `cancellable(cancelInFlight:)`); also
  trigger on submit/focus-loss. Remove the explicit "Check" button; keep a single
  "Connect" affordance (or auto-advance once both URL reachable + token validate).
- **Workspace grouping (#3)**: add `cwd`/`startedAt` to the `Session` domain model + map
  from `/api/sessions`; compute `SessionGroup`s in `HermesKit` (pure, testable) mirroring
  `workspaceGroupsFor`. `SessionListView` renders `Section`s per workspace.
- **Tool/skill rows (#4)**: enrich `ChatRow.tool` to carry a display `title`
  (server `summary`/`context`, fallback `name`) + a `ToolDetail` (args/result/inline diff);
  enrich `GatewayEvent.toolStart/Complete` to decode them. Stop rendering empty assistant
  message rows. New `ToolRowView` (icon + title + duration + chevron) → `ToolDetailSheet`.
  Add a `ScrollToBottomButton` overlay (liquid-glass on iOS 26+, fallback for <26),
  visibility driven by a scroll-position check.
- **Composer (#5)**: rebuild `ComposerView` to the Claude layout — multiline field, a
  bottom bar with a left **model/reasoning chip** (tappable), a **disabled mic** button,
  and a **brand-coloured send** button (`Color.hermesAccent`). `ChatFeature` folds
  `session.info` into state (`model`, `reasoningEffort`). The chip opens a
  `ModelPickerSheet` backed by `model.options`; selection sends `config.set` (guarded while
  the session is running). Add `Color.hermesAccent` as a shared asset.

## Technical Details

- **`@Shared(.appStorage)`** for the server URL (TCA Sharing, already transitively
  available). Token stays in `KeychainClient`.
- **Auto-connect** is a launch effect on `AppFeature`; reuses `HermesRESTClient.sessions`
  for the silent token check. A failure (401/unreachable) routes to onboarding with the
  URL/token prefilled so the user can fix it.
- **`SessionGroup`** = `{ id: String, label: String, sessions: [Session] }`. `id` =
  `cwd` (trimmed) or `"__no_workspace__"`; `label` = path basename or "No workspace".
  Group order = first-seen over the recency-sorted input; in-group order = `startedAt`
  desc. Search results stay flat (no cwd grouping while searching).
- **`ToolDetail`** = decoded `args` (`JSONValue`), `result`/`result_text`, optional
  `inlineDiff`, `summary`. Rendered read-only (monospaced / diff styling).
- **Model picker**: `model.options(session_id)` → `[ModelOption]` (id/label/provider/
  authenticated). `config.set {session_id, key, value}`; surface the 4009 "session busy"
  error as a disabled/explained state while `isSending`.
- **`Color.hermesAccent`**: a single asset-catalog colour sampled from the app icon
  (yellow-orange, ~`#F5A524`), used by the send button (and available for reuse).

## What Goes Where

- **Implementation Steps** (`[ ]`): all code, tests, snapshots, in-repo docs.
- **Post-Completion** (no checkboxes): on-device verification against a live server, a
  fresh TestFlight build, and any visual fine-tuning that needs a real device.

## Implementation Steps

### Task 1: Persist server URL + auto-login on launch ✅

**Deviation:** used a `PreferencesClient` (UserDefaults-backed `@DependencyClient`) for the
server URL instead of `@Shared(.appStorage)` — consistent with the codebase's all-clients
architecture and trivial to stub in tests (`.inMemory()`), avoiding `@Shared`-in-two-States
equality/isolation subtleties. Token stays in `KeychainClient`.

**Files:**
- Create: `HermesKit/Sources/HermesKit/Clients/PreferencesClient.swift`
- Modify: `ConnectionFeature.swift` (persist URL on connect), `AppFeature.swift` (launch
  auto-connect), `SettingsFeature.swift` (clear URL on disconnect), `AppView.swift`
- Create: `HermesKit/Tests/HermesKitTests/PreferencesClientTests.swift`; Modify:
  `AppFeatureTests.swift`, `ConnectionFeatureTests.swift`, `SettingsFeatureTests.swift`

- [x] `PreferencesClient` persists the server URL; `ConnectionFeature` writes it next to
  the Keychain token save on successful validation
- [x] `AppFeature.task` (launch): reads token + URL; silently validates via
  `rest.sessions(1,…)` → success sets `home`, failure → `autoConnectFailed` (onboarding
  prefilled with URL+token)
- [x] `autoConnecting` state; `AppView` shows a `ProgressView("Connecting…")` placeholder
  instead of flashing onboarding
- [x] Settings "Clear token & disconnect" clears the stored URL too
- [x] tests: stored creds → opens list; invalid token → prefilled onboarding; no creds →
  stays on onboarding; URL persisted on connect; URL cleared on logout; PreferencesClient
  round-trip (in-memory + live)
- [x] run tests — **106 pass**; app `BUILD SUCCEEDED`

### Task 2: Auto-validating connection screen (remove Check button) ✅

**Files:**
- Modify: `ConnectionFeature.swift`, `ConnectionView.swift`, `ConnectionFeatureTests.swift`
- Re-recorded: 3 `testConnectionView_*` snapshots

- [x] debounce URL edits (600ms via `clock.sleep` + `.cancellable(cancelInFlight:)`) → auto
  `/api/status` check; `.serverFieldCommitted` (submit/focus-loss) checks immediately,
  pre-empting the debounce; emptying the field cancels the pending check
- [x] removed `checkServerTapped`; new internal `checkServer` + `serverFieldCommitted`
  actions; the status request is `.cancellable(cancelInFlight:)`; kept the single
  "Connect" button (gated on reachable + token)
- [x] `ConnectionView`: dropped the Check button; `.onSubmit` + `@FocusState` focus-loss
  drive validation; inline status footer unchanged; removed unused `canCheck`
- [x] tests: happy path via `serverFieldCommitted`; unreachable/not-Hermes/empty-URL;
  debounced auto-check + reset-to-idle (TestClock); clearing-URL cancels the check
- [x] re-recorded the 3 `ConnectionView` snapshots (no Check button)
- [x] run tests — **107 pass**; app `BUILD SUCCEEDED`

### Task 3: Group sessions by workspace (desktop parity)

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Models/Session.swift` (add `cwd`, `startedAt`)
- Modify: `HermesKit/Sources/HermesKit/Clients/HermesRESTClient.swift` (map `cwd`/`started_at`)
- Create: `HermesKit/Sources/HermesKit/Models/SessionGroup.swift` (pure grouping)
- Modify: `HermesMobile/Sources/Features/SessionListView.swift` (sectioned list)
- Create: `HermesKit/Tests/HermesKitTests/SessionGroupTests.swift`
- Modify: `HermesKit/Tests/HermesKitTests/HermesRESTClientTests.swift`, `PreviewSnapshotTests.swift`

- [ ] add `cwd: String?` and `startedAt: Date?` to `Session`; map `cwd` + `started_at`
  from `SessionListDTO` (verify the `started_at` JSON key against `/api/sessions`)
- [ ] add `SessionGroup.grouped(_:)` mirroring desktop `workspaceGroupsFor` (group by
  trimmed `cwd`; label = basename or "No workspace"; group order = first-seen in recency
  order; in-group order = `startedAt` desc)
- [ ] `SessionListView`: render a `Section` per group with the workspace label header;
  keep search results flat (no grouping while a query is active)
- [ ] write tests: grouping by cwd, basename labels, no-workspace bucket, group + in-group
  ordering; REST DTO maps `cwd`/`started_at`
- [ ] record a grouped session-list snapshot
- [ ] run tests — must pass before next task

### Task 4: Tool/skill activity rows + detail sheet (fix empty bubbles)

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Models/{ChatRow,GatewayEvent}.swift` (tool title + detail)
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift` (fold; drop empty msg rows)
- Modify: `HermesMobile/Sources/Features/Chat/ToolStatusView.swift` → titled row
- Create: `HermesMobile/Sources/Features/Chat/ToolDetailSheet.swift`
- Modify: `HermesMobile/Sources/Features/Chat/ChatView.swift` (present sheet)
- Modify: `HermesKit/Tests/HermesKitTests/{ChatReductionTests,GatewayEventDecodingTests}.swift`
- Modify: `HermesMobileTests/PreviewSnapshotTests.swift`

- [ ] enrich `GatewayEvent.toolStart/toolComplete` to decode `summary`/`context`, `args`,
  `result`/`result_text`, `inline_diff`; add a `ToolDetail` payload type
- [ ] enrich `ChatRow.tool` with a display `title` (summary/context → fallback `name`) and
  optional `ToolDetail`; fold them in `ChatFeature`
- [ ] reproduce + fix the **empty bubble**: don't render an assistant message row that is
  still empty when only tool/status activity is in flight (only materialise it on first
  `message.delta`)
- [ ] `ToolStatusView`: icon + title + state + duration + a chevron; tap → `.toolTapped(id)`
- [ ] `ToolDetailSheet`: read-only args/result/inline-diff (monospaced/diff styling)
- [ ] write tests: enriched tool fold (title fallback chain, detail captured), empty-msg
  suppression, decoding of the richer tool payloads; tool-tap presents detail
- [ ] record snapshots: titled tool row (running + complete) and the detail sheet
- [ ] run tests — must pass before next task

### Task 5: Scroll-to-bottom button

**Files:**
- Create: `HermesMobile/Sources/Features/Chat/ScrollToBottomButton.swift`
- Modify: `HermesMobile/Sources/Features/Chat/ChatView.swift`
- Modify: `HermesMobileTests/PreviewSnapshotTests.swift`

- [ ] track whether the transcript is scrolled near the bottom (scroll position / last-row
  visibility via `onScrollGeometryChange` on iOS 26+, with a pre-26 fallback)
- [ ] overlay a circular down-chevron button (`.glassEffect` on iOS 26+, material fallback)
  bottom-trailing above the composer, shown only when not at bottom; tap → scroll to last
- [ ] keep the existing auto-scroll-on-new-message behaviour; hide the button at bottom
- [ ] write/snapshot: button visible (scrolled up) vs hidden (at bottom)
- [ ] run tests — must pass before next task

### Task 6: Composer redesign (layout, brand send, disabled voice)

**Files:**
- Create: `HermesMobile/Sources/Resources/Assets.xcassets/HermesAccent.colorset` + `Color+Hermes.swift`
- Modify: `HermesMobile/Sources/Features/Chat/ComposerView.swift`
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift` (fold `session.info`)
- Modify: `HermesKit/Sources/HermesKit/Models/GatewayEvent.swift` (`SessionInfo.reasoningEffort`)
- Modify: `HermesKit/Tests/HermesKitTests/ChatReductionTests.swift`, `PreviewSnapshotTests.swift`

- [ ] add `Color.hermesAccent` (asset-catalog colour, yellow-orange sampled from the icon)
- [ ] fold `session.info` into `ChatFeature.State` (`model`, `reasoningEffort`); add
  `reasoningEffort` to `SessionInfo` decoding
- [ ] rebuild `ComposerView` to the Claude layout: multiline field; bottom bar with a left
  **model/reasoning chip** (display `model · effort`, tappable → `.modelChipTapped`), a
  **disabled mic** button, and a **send** button tinted `Color.hermesAccent` (interrupt
  state unchanged)
- [ ] write tests: sessionInfo fold sets model/effort; chip reflects state; (picker wiring
  in Task 7)
- [ ] record the redesigned composer snapshot (idle / sending)
- [ ] run tests — must pass before next task

### Task 7: Interactive model + reasoning-effort picker

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Clients/HermesGatewayClient.swift` (if a typed helper helps)
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift` (picker state + RPCs)
- Create: `HermesKit/Sources/HermesKit/Models/ModelOption.swift`
- Create: `HermesMobile/Sources/Features/Chat/ModelPickerSheet.swift`
- Modify: `HermesMobile/Sources/Features/Chat/ChatView.swift`
- Modify: `HermesKit/Tests/HermesKitTests/ChatInteractionTests.swift`, `PreviewSnapshotTests.swift`

- [ ] `.modelChipTapped` → load `model.options(session_id)` into picker state; decode
  `ModelOption` (id/label/provider/authenticated)
- [ ] selecting a model → `config.set {session_id, key:"model", value}`; selecting a
  reasoning effort → `config.set {session_id, key:"reasoning_effort", value}`; update
  state optimistically and reconcile from the next `session.info`
- [ ] guard while `isSending`/running (server returns 4009) — disable selection with an
  explanatory note; ⚠️ live-verify the exact `reasoning_effort` key + allowed values
- [ ] `ModelPickerSheet`: grouped model list + reasoning-effort segment; current selection
  highlighted
- [ ] write tests: chip tap loads options; model/effort selection sends exact `config.set`
  params; busy-state guard blocks selection
- [ ] record the picker-sheet snapshot
- [ ] run tests — must pass before next task

### Task 8: Verify acceptance criteria

- [ ] verify each item: auto-login skips onboarding; connection auto-validates without a
  Check button; sessions grouped by workspace like desktop; tool/skill rows show
  title + open a detail sheet; no empty bubbles; scroll-to-bottom button appears when
  scrolled up; composer shows model/reasoning chip (interactive), disabled voice, and a
  yellow-orange send button
- [ ] verify edge cases: no stored creds → onboarding; invalid stored token → onboarding
  prefilled; search disables grouping; model switch blocked mid-turn; sessions with no cwd
  grouped under "No workspace"
- [ ] run the full suite (`make test`) + snapshots (`make snapshot`)

### Task 9: [Final] Documentation

- [ ] update `README.md` (features: auto-login, workspace grouping, tool detail, model
  picker) and `CLAUDE.md` if new patterns emerged (`@Shared(.appStorage)`, glass effect)
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion

*Items requiring manual intervention or external systems — informational only.*

**Manual verification (on a real device, against a live Hermes server):**
- Auto-login across cold launches; logout returns to onboarding and forgets the URL.
- Workspace grouping with multiple real projects; "No workspace" bucket.
- A real tool-using + skill-using turn renders titled rows; the detail sheet shows
  args/result/diff; no empty bubbles.
- Scroll-to-bottom button on a long transcript (verify liquid-glass on iOS 26+).
- Model + reasoning switch actually changes the running session; confirm the exact
  `reasoning_effort` key/values and the mid-turn "session busy" behaviour.

**External:**
- Cut a fresh TestFlight build once the above is verified.

**Out of scope (later):** real voice input (button ships disabled), file attachments in the
composer, and any backend changes (none required — `cwd` already ships in `/api/sessions`).
