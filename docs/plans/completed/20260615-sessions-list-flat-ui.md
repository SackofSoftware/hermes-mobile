# Flat sessions list, grouping menu & Archived screen

Redesign the sessions list UI toward the Codex iOS layout (GitHub issue: UI improvement).

## Overview

- **Flat list.** Replace the grouped/inset `List` tables with a flat `.plain` list (Codex-style) — flat section headers instead of inset card sections.
- **Two grouping modes.** Add a user-selectable grouping: **By workspace** (current behaviour, flat-styled) and **Chronological** (one flat recency-ordered list, no workspace headers). Persisted per device.
- **Top-trailing menu.** A menu in the top-trailing corner (like Codex) with the grouping options, a divider, and an **Archived sessions** entry.
- **Archived screen.** A new screen (presented as a sheet with its own `NavigationStack`, mirroring Settings) listing archived sessions, with **Restore** (unarchive) and **tap-to-open** (resume).
- **Bottom new-session button.** Move the "New" button to a bottom toolbar (`ToolbarItem(placement: .bottomBar)`) like Codex's "Chat" button, and make it coexist with the **iOS 26 bottom search field** (on iOS 17–18 search stays in the nav bar).

Settings stays as its own top-leading gear button (unchanged).

## Context (from discovery)

Files/components involved:

- `HermesMobile/Sources/Features/SessionListView.swift` — grouped `List` with `Section("Pinned")` + per-workspace `groupSection` ("Show N more"); `.searchable` in the nav bar; toolbar Settings (top-leading) + New (`.primaryAction`). Rename alert, confirmation dialog, Settings sheet.
- `HermesKit/Sources/HermesKit/Features/SessionListFeature.swift` — `State` (sessions, pinnedIDs, expandedGroups, archivingIDs, …), computed `groups`/`pinnedSessions`/`unpinnedSessions`, `load()` reads persisted prefs; delegate `openSession`/`createSession`/`disconnect`. Order is `.recent`; grouping is a pure display concern over one `sessions` array.
- `HermesKit/Sources/HermesKit/Models/SessionGroup.swift` — `grouped(_:)` workspace grouping.
- `HermesKit/Sources/HermesKit/Clients/HermesRESTClient.swift` — `sessions(conn, limit, offset, order)` (no `archived` param → server default `exclude`); `archive(conn, id, archived)` = `PATCH {archived}`. DTO `SessionListDTO`.
- `HermesKit/Sources/HermesKit/Clients/PreferencesClient.swift` — UserDefaults-backed prefs (server URL, seen counts, pinned ids); `.inMemory()` test variant; cleared on logout.
- `HermesMobile/Sources/AppView.swift` — one `NavigationStack` (list root → pushes `ChatView` via TCA `path`); Settings is a `.sheet` from `SessionListFeature`.
- `HermesMobile/Sources/Features/Chat/ScrollToBottomButton.swift` — existing `#available(iOS 26.0, *)` Liquid-Glass gating pattern to mirror.

Verified against the Hermes source (`/Users/eugene/Documents/Development/Personal/hermes-agent`):

- `GET /api/sessions?archived=only` returns just archived sessions (`web_server.py:1574` — `archived ∈ {exclude, only, include}`, default `exclude`). So the Archived screen fetches with `archived=only`; **Restore = `archive(id, false)`** (the existing PATCH).

Decisions (from planning):

- Archived screen: **sheet** (own `NavigationStack`, mirrors Settings), supports **Restore + tap-to-open** (open bubbles up via the existing `openSession` delegate so chat opens in the main stack and the sheet dismisses).
- **Settings stays** as a separate top-leading button.
- New-session button: **`ToolbarItem(placement: .bottomBar)`** (system handles iOS 26 bottom-search coexistence).
- **Regular** testing.

## Development Approach

- **Testing approach: Regular.** Implement each piece, then its tests, before the next task.
- Logic in `HermesKit`; views stay thin (see `CLAUDE.md`). Grouping mode is display-only over the existing `sessions` array — no fetch/order changes.
- **Every task includes new/updated tests** (TCA `TestStore` reducer tests; REST via `URLProtocol` mock; views via snapshots).
- **All tests pass before the next task** — `make test` (HermesKit) and `make snapshot` (views) as relevant.
- Persisted grouping mode is a non-secret pref in `PreferencesClient`; **logout clears it** too (CLAUDE.md: logout clears every prefs entry).
- Gate iOS 26-only search APIs with `#available(iOS 26.0, *)`; deployment target is **iOS 17**.

## Testing Strategy

- **Unit (required each task):** `swift test` via `make test` — `TestStore` + `@Dependency` + `TestClock`; REST with `URLProtocol` mock; `PreferencesClient.inMemory()` round-trips.
- **Snapshot:** `make snapshot` / `make snapshot-record` for the flat list (both modes), the archived screen (populated + empty), and the bottom-bar button. Re-record intentionally.
- **Manual (device/sim):** the **iOS 26 bottom search field** coexistence with the bottom-bar button, and the top-trailing menu popover — not snapshot-testable on the iOS 17/18 snapshot host.

## Solution Overview

Grouping mode is a persisted enum that only changes how the existing `sessions` array is rendered (`groups` for workspace, a flat recency list for chronological). The Archived screen is a self-contained `@Reducer` presented as a sheet, reusing the REST `archive` PATCH for Restore and bubbling open-taps through the existing `openSession` delegate. The view restyles to `.plain`, moves grouping/Archived into a top-trailing `Menu`, and moves New into the bottom bar where the iOS 26 search field also lives.

## What Goes Where

- **Implementation Steps** (`[ ]`): all reducers, clients, views, tests, snapshots in this repo.
- **Post-Completion** (no checkboxes): manual iOS 26 search-layout verification; `tuist generate` before an app build when new source files are added.

## Implementation Steps

### Task 1: Add `SessionGroupingMode` + persist it in `PreferencesClient`

**Files:**
- Create: `HermesKit/Sources/HermesKit/Models/SessionGroupingMode.swift`
- Modify: `HermesKit/Sources/HermesKit/Clients/PreferencesClient.swift`
- Modify: `HermesKit/Tests/HermesKitTests/PreferencesClientTests.swift`

- [x] Create `public enum SessionGroupingMode: String, Sendable, CaseIterable, Equatable { case workspace, chronological }` (raw values for persistence; default `.workspace`).
- [x] Add `loadGroupingMode() -> SessionGroupingMode` and `saveGroupingMode(_:)` to `PreferencesClient` (live = UserDefaults under a new key, unknown/missing → `.workspace`); add to `.inMemory()` and `liveValue`.
- [x] Include the grouping-mode key in whatever logout/clear path clears prefs (so logout resets it, per CLAUDE.md). (Reset in `SettingsFeature.clearTokenTapped`.)
- [x] Write `PreferencesClient` tests: save→load round-trip, default when unset, cleared on the clear-all path (+ `SettingsFeature` logout assertion).
- [x] Run `make test` — must pass before next task. (166 tests green.)

### Task 2: Grouping-mode state + actions in `SessionListFeature`

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/SessionListFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/SessionListFeatureTests.swift`

- [x] Add `public var groupingMode: SessionGroupingMode = .workspace` to `State` (init param + memberwise init update). Load it from `preferences.loadGroupingMode()` in `load()` (alongside pins/seen counts).
- [x] Add a computed `var chronologicalSessions: [Session]` = `unpinnedSessions` sorted by `updatedAt` desc (nil last) for the chronological mode. Keep `groups`/`pinnedSessions` as-is.
- [x] Add action `setGroupingMode(SessionGroupingMode)` → set `state.groupingMode` and persist via `preferences.saveGroupingMode` (no-op when unchanged).
- [x] Write tests: `setGroupingMode` updates state + persists; `load` seeds `groupingMode` from preferences; `chronologicalSessions` ordering (pinned excluded, recency desc).
- [x] Run `make test` — must pass before next task. (169 tests green.)

### Task 3: REST `archivedSessions` method

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Clients/HermesRESTClient.swift`
- Modify: `HermesKit/Tests/HermesKitTests/HermesRESTClientTests.swift`

- [x] Add `archivedSessions: @Sendable (_ connection:, _ limit: Int, _ offset: Int) async throws -> [Session]` to the client; `live` does `GET /api/sessions?archived=only&order=recent&limit=&offset=` and maps via the existing `SessionListDTO` → `Session` path. `testValue` stays unimplemented.
- [x] Write a `HermesRESTClient` test (URLProtocol mock): asserts the request carries `archived=only` (+ order/limit/offset) and decodes results to `[Session]`; a non-2xx maps to the right `RESTError`.
- [x] Run `make test` — must pass before next task. (171 tests green.)

### Task 4: `ArchivedSessionsFeature` reducer + presentation wiring

**Files:**
- Create: `HermesKit/Sources/HermesKit/Features/ArchivedSessionsFeature.swift`
- Modify: `HermesKit/Sources/HermesKit/Features/SessionListFeature.swift`
- Create: `HermesKit/Tests/HermesKitTests/ArchivedSessionsFeatureTests.swift`
- Modify: `HermesKit/Tests/HermesKitTests/SessionListFeatureTests.swift`

- [x] Create `@Reducer ArchivedSessionsFeature`: `State { connection, sessions: IdentifiedArrayOf<Session>, isLoading, loadError, now, restoringIDs: Set<String> }`; actions `task`, `archivedResponse(Result<[Session], RESTError>)`, `restoreButtonTapped(id)`, `restoreSucceeded(id)`, `restoreFailed(id, session, index)`, `sessionTapped(id)`, `delegate(Delegate { openSession(Session) })`.
- [x] `task` → `rest.archivedSessions`; `restoreButtonTapped` → optimistically remove the row + `restoringIDs` guard, call `rest.archive(conn, id, false)`, on failure re-insert at saved index + surface error; `sessionTapped` → `.delegate(.openSession(session))`.
- [x] In `SessionListFeature`: add `@Presents var archived: ArchivedSessionsFeature.State?`, action `archivedButtonTapped` → present (seed connection + `now`); handle `archived(.presented(.delegate(.openSession(s))))` → dismiss the sheet and forward `.delegate(.openSession(s))` (so the main stack opens chat); add `.ifLet(\.$archived, action: \.archived) { ArchivedSessionsFeature() }`.
- [x] Write `ArchivedSessionsFeature` tests: load success/failure; restore optimistic-remove + rollback-on-failure; `sessionTapped` emits the delegate.
- [x] Write `SessionListFeature` tests: `archivedButtonTapped` presents; the archived `openSession` delegate dismisses + re-emits `openSession`.
- [x] Run `make test` — must pass before next task. (178 tests green.)

### Task 5: Flatten `SessionListView` + render both grouping modes

**Files:**
- Modify: `HermesMobile/Sources/Features/SessionListView.swift`
- Modify: `HermesMobileTests/PreviewSnapshotTests.swift`

- [x] Switch the `List` to `.listStyle(.plain)` and restyle headers flat (Codex-style: plain section headers, no inset cards). Keep the `Pinned` group on top in both modes.
- [x] When `store.groupingMode == .workspace`: render the existing workspace `groupSection`s (keep the "Show N more" collapse, restyled flat). When `.chronological`: render a single flat `ForEach(store.chronologicalSessions)` with no workspace headers. Search results stay flat (unchanged).
- [x] Keep row affordances (tap, pin/unpin, rename, archive) intact.
- [x] Add snapshot cases: workspace-mode flat list and chronological-mode flat list (reuse pinned reference date).
- [x] Run `make snapshot` (record new baselines intentionally) — must pass before next task.

### Task 6: Top-trailing Organize/Archived menu

**Files:**
- Modify: `HermesMobile/Sources/Features/SessionListView.swift`

- [x] Add a top-trailing `ToolbarItem` `Menu` (label e.g. `line.3.horizontal.decrease.circle` / `ellipsis.circle`): a grouping section with **By workspace** and **Chronological** (checkmark on the selected one via `store.groupingMode`), each sending `.setGroupingMode(…)`; then a `Divider()`; then an **Archived sessions** button (`archivebox`) sending `.archivedButtonTapped`.
- [x] Leave the Settings gear button in the top-leading slot unchanged.
- [x] No reducer logic added here (covered by Task 2/4 tests). Menus aren't snapshot-testable (popover) — verify the build via `make snapshot` and cover behaviour by the reducer tests; note menu interaction as manual.
- [x] Run `make snapshot` (build + existing baselines) — must pass before next task.

### Task 7: Bottom new-session button + iOS 26 search coexistence

**Files:**
- Modify: `HermesMobile/Sources/Features/SessionListView.swift`
- Modify: `HermesMobileTests/PreviewSnapshotTests.swift`

- [x] Move the **New** button from `.primaryAction` to `ToolbarItem(placement: .bottomBar)` (keeps `.searchable`). On iOS 17–18 search stays in the nav bar and New sits in the bottom bar; on iOS 26 the system places the search field in the bottom — verify the New button coexists (if needed, gate an iOS 26-only `.searchToolbarBehavior(.minimize)` / bottom-accessory tweak with `#available(iOS 26.0, *)`, mirroring the existing Liquid-Glass gating).
- [x] Ensure the new-session action and label are unchanged (`.newSessionButtonTapped`).
- [x] Update/record a snapshot showing the bottom-bar New button (iOS 17/18 host). The iOS 26 bottom-search layout is **manual** (Post-Completion) — the snapshot host can't render it.
- [x] Run `make snapshot` — must pass before next task.


  > ⚠️ Implemented via `.safeAreaInset(edge: .bottom)` instead of `ToolbarItem(.bottomBar)`: a `.bottomBar` toolbar renders blank in the iOS 17/18 snapshot host (zero coverage). `safeAreaInset` lays out in the normal hierarchy (snapshots correctly) and still sits above the iOS 26 bottom search. iOS 26 search+button coexistence remains a manual-verify item.

### Task 8: `ArchivedSessionsView` (sheet)

**Files:**
- Create: `HermesMobile/Sources/Features/ArchivedSessionsView.swift`
- Modify: `HermesMobile/Sources/Features/SessionListView.swift`
- Modify: `HermesMobileTests/PreviewSnapshotTests.swift`

- [x] Create `ArchivedSessionsView`: a `.plain` `List` of archived rows (reuse `SessionRowView`), `.swipeActions`/`.contextMenu` **Restore** (`.restoreButtonTapped`), tap → `.sessionTapped`; loading + `ContentUnavailableView("No archived sessions")` empty state; nav title "Archived"; a Done button to dismiss.
- [x] Present it from `SessionListView` via `.sheet(item: $store.scope(state: \.archived, action: \.archived))` wrapped in a `NavigationStack` (mirrors the Settings sheet).
- [x] Add snapshot cases: archived list populated and empty.
- [x] Run `make snapshot` (record new baselines) — must pass before next task.

### Task 9: Verify acceptance criteria

- [x] Flat `.plain` list renders in both modes; Pinned stays on top; search still flat.
- [x] Grouping menu (top-trailing) switches modes with a checkmark and persists across relaunch; Settings still top-leading.
- [x] Archived menu entry opens the sheet; Restore unarchives (optimistic + rollback); tap opens/resumes the session in the main stack and dismisses the sheet.
- [x] New-session button is in the bottom bar and triggers create.
- [x] Run the full suites: `make test` and `make snapshot`.

### Task 10: [Final] Update documentation

- [x] Update `CLAUDE.md` if a new convention emerged (grouping-mode pref; flat `.plain` list; bottom-bar New + iOS 26 search note).
- [x] Update `docs/architecture.md` if warranted (new `ArchivedSessionsFeature`, `archivedSessions` REST method, grouping pref).
- [x] Move this plan to `docs/plans/completed/`. (done)

## Post-Completion
*Manual / external — no checkboxes.*

**Manual verification (device/simulator):**
- **iOS 26:** the bottom search field and the bottom-bar New button lay out together correctly (no overlap/clipping); search still filters. Compare against iOS 17/18 where search is in the nav bar.
- The top-trailing menu popover (Organize options + Archived entry) renders and switches modes.
- Archived sheet: Restore removes the row and it reappears in the main list on refresh; tap-to-open resumes the session and dismisses the sheet.

**Build note:**
- New source files (`SessionGroupingMode.swift`, `ArchivedSessionsFeature.swift`, `ArchivedSessionsView.swift`) require `tuist generate` before an `xcodebuild`/snapshot run picks them up.
