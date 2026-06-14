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

### Task 3: Group sessions by workspace (desktop parity) ✅

**Files:**
- Modify: `Session.swift` (+`cwd`, `startedAt`), `HermesRESTClient.swift` (map `cwd`),
  `SessionListFeature.swift` (computed `groups`/`isSearching`), `SessionListView.swift`
- Create: `SessionGroup.swift`, `SessionGroupTests.swift`
- Modify: `HermesRESTClientTests.swift`, `PreviewSnapshotTests.swift`

- [x] added `cwd`/`startedAt` to `Session`; mapped `cwd` (`started_at` was already decoded)
  in `SessionListDTO` (`/api/sessions` returns `cwd` via `SELECT s.*` — verified)
- [x] `SessionGroup.grouped(_:)` mirrors desktop `workspaceGroupsFor`: group by trimmed
  `cwd`, label = basename (root `/` → path, empty → "No workspace"), groups in first-seen
  recency order, rows within a group sorted by `startedAt` desc
- [x] `SessionListView` renders a `Section` per workspace group; search results stay flat
  (`State.isSearching`)
- [x] tests: `SessionGroupTests` (5 — basename labels, recency group order, in-group
  ordering, no-workspace bucket, trailing-slash/root labels); REST DTO maps `cwd`/`started_at`
- [x] recorded the grouped session-list snapshot (shared in chat)
- [x] run tests — **112 pass**; app `BUILD SUCCEEDED`

### Task 4: Tool/skill activity rows + detail sheet (fix empty bubbles) ✅

**Files:**
- Modify: `ChatRow.swift` (+`ToolDetail`, enriched `.tool`), `GatewayEvent.swift`,
  `GatewayLogEntry.swift`, `JSONRPC.swift` (+`displayString`), `ChatFeature.swift`
- Create: `StringExtensions.swift` (consolidated internal `nonEmpty`), `ToolDetailSheet.swift`
- Modify: `ToolStatusView.swift` (titled row), `ChatView.swift` (sheet)
- Modify: `ChatReductionTests.swift`, `GatewayEventDecodingTests.swift`, `PreviewSnapshotTests.swift`

- [x] enriched `GatewayEvent.toolStart` (`context`→title, `args_text`) / `toolComplete`
  (`summary`→title, `args`, `result_text`/stringified `result`, `inline_diff`); added
  `ToolDetail` + `JSONValue.displayString` (pretty JSON for objects)
- [x] `ChatRow.tool` now carries `title` (summary/context → fallback `name`) + optional
  `ToolDetail`; fold merges start args_text with complete result/diff
- [x] **empty-bubble fix**: `message.start` no longer creates a row; the assistant row is
  materialised lazily on the first `message.delta` (or finalised directly from
  `message.complete` when non-streamed). A tool-only turn leaves **no** empty bubble.
- [x] `ToolStatusView`: icon + human title + raw name + spinner/duration + chevron (only
  when there's detail); tap → `.toolTapped(id)`
- [x] `ToolDetailSheet`: read-only Arguments / Result / Diff sections (monospaced)
- [x] tests: enriched tool fold + title fallback + tap-presents-detail; tool-only-turn
  leaves no bubble; lazy/streamed message rows; richer tool payload decoding + object-result
  stringification — **115 pass**
- [x] snapshots: tool rows (running/complete/no-detail) + detail sheet (shared in chat)
- [x] run tests — **115 pass**; app `BUILD SUCCEEDED`

### Task 5: Scroll-to-bottom button ✅

**Files:**
- Create: `ScrollToBottomButton.swift`; Modify: `ChatView.swift`, `PreviewSnapshotTests.swift`

- [x] scroll-position detection via a bottom anchor + `GeometryReader`/`PreferenceKey`
  (works on the iOS 17 floor, no version branch) — `isAtBottom` when the anchor is within
  ~60pt of the viewport bottom
- [x] `ScrollToBottomButton`: circular down-chevron, `.glassEffect(.regular.interactive())`
  on iOS 26+, material + hairline + shadow fallback below; `.buttonStyle(.plain)` keeps the
  chevron `.primary`
- [x] overlaid bottom-trailing over the transcript, shown only when `!isAtBottom` (spring
  transition); tap scrolls to the bottom anchor; auto-scroll-on-new-message preserved
- [x] snapshot of the button over a gradient (so the glass refraction is visible)
- [x] run tests — **115 unit + 16 snapshot pass**; app `BUILD SUCCEEDED`

### Task 6: Composer redesign (layout, brand send, disabled voice) ✅

**Files:**
- Create: `Assets.xcassets/HermesAccent.colorset`, `Color+Hermes.swift`
- Modify: `ComposerView.swift`, `ChatView.swift`, `ChatFeature.swift` (fold `session.info`
  + `modelChipTapped` stub), `GatewayEvent.swift` (`SessionInfo.reasoningEffort`)
- Modify: `ChatReductionTests.swift`, `PreviewSnapshotTests.swift`

- [x] `Color.hermesAccent` (asset-catalog colour `#F5A524`, yellow-orange from the icon)
- [x] folded `session.info` into `ChatFeature.State` (`model`, `reasoningEffort`); later
  partial `session.info` events don't clobber present values; added `reasoning_effort`
  decoding to `SessionInfo`
- [x] rebuilt `ComposerView`: multiline field over a toolbar row — left **model · effort
  chip** (tappable → `.modelChipTapped`), **disabled mic** placeholder, **send** button in
  `Color.hermesAccent` (red stop while streaming)
- [x] tests: `sessionInfoUpdatesModelAndReasoningChip` (incl. partial-update preservation);
  split the unknown-event test
- [x] snapshots: composer idle + typing/sending; updated `testChatView` for the new composer
- [x] run tests — **116 unit + 18 snapshot pass**; app `BUILD SUCCEEDED`

### Task 7: Interactive model + reasoning-effort picker ✅

**Protocol verified against `tui_gateway/server.py`:** `model.options {session_id}` →
`{providers:[{name, slug, models:[String], authenticated}], model}`. Switch via
`config.set {session_id, key, value}` — **`key:"model"`** for the model and
**`key:"reasoning"`** (NOT `reasoning_effort`) for effort; valid efforts =
`none/minimal/low/medium/high/xhigh`. Mid-turn switches are rejected (4009).

**Files:**
- Create: `ModelOptions.swift`, `ModelPickerSheet.swift`
- Modify: `ChatFeature.swift` (picker state + RPCs + `configSet` helper), `ChatView.swift`,
  `ChatInteractionTests.swift`, `PreviewSnapshotTests.swift`

- [x] `.modelChipTapped` → `model.options(session_id)` into `State.ModelPicker`; lenient
  `ModelOptions` decoding (`usableProviders` filters to authenticated + non-empty)
- [x] `modelSelected` → `config.set key=model`; `reasoningSelected` → `config.set
  key=reasoning`; optimistic state update, reconciled by the next `session.info`
- [x] guarded while `isSending` (no-op + the sheet disables selection with an "finish the
  turn" note)
- [x] `ModelPickerSheet`: reasoning-effort section + per-provider model sections, current
  selections checkmarked in `Color.hermesAccent`
- [x] tests: chip-tap loads options; model + reasoning selection send exact `config.set`
  params (key/value/session_id); busy-state guard blocks both — **120 pass**
- [x] recorded the picker-sheet snapshot (shared in chat)
- [x] ➕ **reasoning is per-model** (review follow-up): `model.options` carries a
  `capabilities` map (`capabilities[model].reasoning: Bool`). Decoded it +
  `ModelOptions.supportsReasoning(_:)` (default true when unknown), and `ModelPickerSheet`
  now hides the effort section for non-reasoning models — matches desktop
  `caps?.reasoning ?? true`. Added `ModelOptionsTests` (decode + capability gating) + a
  non-reasoning-model snapshot.
- [x] run tests — **122 unit + 20 snapshot pass**; app `BUILD SUCCEEDED`
- [x] ➕ **picker layout refinements** (review follow-up): (a) reasoning-effort options now
  drop down **inline under the selected model** (not a separate top section); (b) providers
  ordered **configured-first (selectable), then unconfigured (disabled)** — unconfigured
  providers come back from `model.options` with empty model lists + a `warning`
  (e.g. "paste ANTHROPIC_API_KEY to activate"), so they render grayed with the hint rather
  than fake model rows (mobile can't configure providers). `ModelOptions.orderedProviders`
  + `Provider.isConfigured`/`warning`; updated `ModelOptionsTests` + picker snapshot.
- [x] run tests — **123 unit + 20 snapshot pass**; app `BUILD SUCCEEDED`

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
