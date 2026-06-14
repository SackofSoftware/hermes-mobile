# Hermes Mobile — Session List: Ordering, Collapse, Pin, Archive, Working Glow

## Overview

The next milestone polishes the session list to match the Hermes desktop sidebar and fix
two ordering/expansion bugs found on-device:

1. **Ordering bug** — within a workspace group, rows are sorted by `startedAt` (creation)
   but display `updatedAt` (last-active), so a recently-active session sinks below
   older-created ones (e.g. "Hermes Blog Post · 2h ago" below "… · yesterday"). Fix:
   sort by last-active.
2. **Collapse** — `expandedGroups` only grows; once "Show more" is tapped a group can't be
   re-collapsed until app restart. Add a collapse affordance.
3. **Pin sessions** — desktop parity: pin/unpin sessions into a top "Pinned" section.
4. **Archive sessions** — desktop parity: archive (soft-hide) sessions; server-persisted.
5. **Working glow** — a subtle glow on sessions that are currently active, so the user can
   see the agent working from the list.

## Context (from discovery)

- **Stack**: TCA reducers/clients in `HermesKit` (`swift test`, no simulator); thin SwiftUI
  in `HermesMobile`; iOS XCTest snapshot target `HermesMobileTests`. Regular testing.
  Prior milestones (MVP + UX) complete under `docs/plans/completed/`.
- **Session list**: `SessionListFeature` (state + reducer), `SessionListView`,
  `SessionGroup` (workspace grouping — `grouped(_:)` sorts in-group by `startedAt` desc),
  `SessionRowView`. Client-side persistence via `PreferencesClient` (UserDefaults) — already
  used for the server URL + per-session unread `seenCounts`.
- **`Session` model** already carries `updatedAt` (`last_active`), `startedAt`,
  `messageCount`, **`isActive`** (`is_active`: server-computed active & last-activity <5min),
  `cwd`.
- **#3 Pin** — verified the desktop keeps pins in a **client-side store**
  (`$pinnedSessionIds`, keyed by durable id), shown in a top "Pinned" section. **No server
  pin API exists** (only `pinned_message_id` for messages). → mobile pin is client-side.
- **#4 Archive** — **server-side**: `PATCH /api/sessions/{id}` with `{ "archived": bool }`;
  `GET /api/sessions?archived=exclude|only|include` (default `exclude` already hides them).
  The mobile `HermesRESTClient` has no PATCH method yet.
- **#5 Working** — the desktop derives "working" from `session.info` `running` events, but
  Hermes routes events **to the session owner only** (`write_json`) and the only fan-out
  (`/api/pub`→`/api/events`) is **per-chat-tab** — there is **no global live status feed**.
  The only globally-available signal is REST **`is_active`**. Per the product decision,
  reflecting **client-driven / recently-active** sessions is sufficient → use `is_active`
  + auto-poll (no backend change).

## Development Approach

- **Testing: Regular** (code first, then tests) — matches the project.
- Complete each task fully before the next; small, focused changes.
- **Every task MUST add/update tests** (reducer/unit tests as separate checklist items;
  snapshot tests for UI changes — re-record baselines when UI changes intentionally).
- **All tests pass before the next task.** Update this plan as scope shifts.

## Testing Strategy

- **Unit (TCA)**: `TestStore` + `@Dependency` overrides + `TestClock`. Cover: in-group
  ordering, expand/collapse toggle, pin/unpin persistence + ordering, archive RPC +
  optimistic removal, auto-poll timer, working-set derivation.
- **Snapshots** (`PreviewSnapshotTests`): pinned section, collapse control, archive swipe
  action, working glow row. Re-record via `make snapshot-record`.
- No new e2e harness (project has none).

## Progress Tracking

- Mark `[x]` immediately; ➕ for new tasks, ⚠️ for blockers; keep the plan in sync.

## Solution Overview

- **Ordering (#1)**: `SessionGroup.grouped(_:)` sorts in-group by **`updatedAt` desc**
  (last-active, nil last) so display order matches the shown timestamp. Pinned section uses
  pin order; groups use last-active.
- **Collapse (#2)**: keep `expandedGroups: Set<String>`; the per-group footer becomes a
  toggle — "Show N more" when collapsed, "Show less" when expanded → `toggleGroupExpansion`.
- **Pin (#3)**: `PreferencesClient` gains `pinnedSessionIDs` (ordered `[String]`).
  `SessionListFeature` loads them on appear, exposes a computed **pinned section** (resolved
  from `sessions`, in pin order) rendered **above** the workspace groups, **only when
  non-empty**. Pinned sessions are excluded from their workspace group. Pin/unpin via **both
  a leading swipe action and a long-press context menu**; the context menu also offers
  Archive (mirroring the desktop's row menu). Pinned rows show a small pin glyph.
- **Archive (#4)**: `HermesRESTClient.archive(connection, id, archived:)` → `PATCH`.
  Trailing swipe "Archive" → **a confirmation dialog** (archive is destructive-ish) →
  on confirm, optimistic removal from the list + the RPC; list keeps the default
  `archived=exclude`. Use TCA `ConfirmationDialogState` (`@Presents`) so the confirm/cancel
  flow is testable. (Unarchive/viewing archived is a fast-follow — see Post-Completion.)
- **Working glow (#5)**: `SessionListFeature` auto-polls (`continuousClock`, ~10s) while
  visible, re-fetching the list so `isActive` stays fresh; `SessionRowView` renders a subtle
  animated glow when `session.isActive == true`. The glow reflects server-side recent
  activity (covers sessions this client drives).

## Technical Details

- **Pin storage**: `PreferencesClient.loadPinnedIDs() -> [String]` /
  `savePinnedIDs([String])` (UserDefaults array, order = display order). Cleared on logout
  alongside the URL/seen-counts.
- **Pinned resolution**: `State.pinnedSessions` = `pinnedIDs.compactMap { sessions[id:$0] }`
  (drops stale ids); `State.unpinnedSessions` feeds `SessionGroup.grouped`.
- **Archive RPC**: `PATCH /api/sessions/{id}` body `{"archived": true}`; reuse `RESTError`
  mapping. On success keep the optimistic removal; on failure re-insert + show the error.
- **Auto-poll**: a cancellable timer effect started on `.task`, cancelled on `.onDisappear`
  (new action) — `clock.sleep(10s)` loop → `.pulledToRefresh`. Pull-to-refresh + open still
  work. Guard against polling while searching.
- **Glow**: `SessionRowView` adds an `isActive` overlay/border with a gentle pulsing
  opacity animation (respects reduce-motion). Brand-tinted.

## What Goes Where

- **Implementation Steps** (`[ ]`): all code, tests, snapshots, in-repo docs.
- **Post-Completion** (no checkboxes): on-device verification, a TestFlight build, and
  fast-follows (viewing/unarchiving archived sessions; pin reordering; true real-time glow
  via a backend status feed).

## Implementation Steps

### Task 1: Fix in-group ordering (sort by last-active)

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Models/SessionGroup.swift`
- Modify: `HermesKit/Tests/HermesKitTests/SessionGroupTests.swift`

- [x] sort each group's `sessions` by `updatedAt` desc (nil last) instead of `startedAt`
- [x] update the grouping doc comment to reflect last-active ordering
- [x] update/extend tests: in-group order follows `updatedAt` desc; mixed nil handling
- [x] run tests — must pass before next task

### Task 2: Collapse/expand toggle for groups

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/SessionListFeature.swift`
- Modify: `HermesMobile/Sources/Features/SessionListView.swift`
- Modify: `HermesKit/Tests/HermesKitTests/SessionListFeatureTests.swift`
- Modify: `HermesMobileTests/PreviewSnapshotTests.swift`

- [x] rename/repurpose `showMoreTapped` → `toggleGroupExpansion(groupID:)` (insert/remove
  from `expandedGroups`)
- [x] `SessionListView`: footer shows "Show N more" (collapsed) / "Show less" (expanded)
- [x] tests: toggle expands then collapses; `visibleSessions(in:)` respects it
- [x] re-record the grouped session-list snapshot (expanded state)
- [x] run tests — must pass before next task

### Task 3: Pin sessions (client-side, top "Pinned" section)

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Clients/PreferencesClient.swift` (pinned ids)
- Modify: `HermesKit/Sources/HermesKit/Features/SessionListFeature.swift` (state + actions)
- Modify: `HermesMobile/Sources/Features/SessionListView.swift` (pinned section + swipe)
- Modify: `HermesMobile/Sources/Features/SessionRowView.swift` (pin glyph)
- Modify: `HermesKit/Tests/HermesKitTests/{PreferencesClientTests,SessionListFeatureTests}.swift`
- Modify: `HermesMobileTests/PreviewSnapshotTests.swift`

- [x] `PreferencesClient`: `loadPinnedIDs`/`savePinnedIDs` (UserDefaults ordered array);
  in-memory variant; cleared on logout
- [x] `SessionListFeature`: load pins on `.task`; `pinSession`/`unpinSession` actions persist
  + update state; computed `pinnedSessions` (in pin order) and `unpinnedSessions` (feed
  grouping); pinned excluded from groups
- [x] `SessionListView`: a "Pinned" `Section` above groups, **shown only when non-empty**;
  pin/unpin via a **leading swipe action** and a **long-press context menu** (the menu also
  includes Archive); `SessionRowView` shows a pin glyph when pinned
- [x] tests: pin persists + moves the session to the pinned set + out of its group; unpin
  restores; stale pinned id ignored; PreferencesClient round-trip
- [x] snapshot: list with a non-empty Pinned section
- [x] run tests — must pass before next task

### Task 4: Archive sessions (server PATCH + swipe)

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Clients/HermesRESTClient.swift` (`archive`)
- Modify: `HermesKit/Sources/HermesKit/Features/SessionListFeature.swift`
- Modify: `HermesMobile/Sources/Features/SessionListView.swift` (trailing swipe)
- Modify: `HermesKit/Tests/HermesKitTests/{HermesRESTClientTests,SessionListFeatureTests}.swift`

- [x] `HermesRESTClient.archive(_:_:archived:)` → `PATCH /api/sessions/{id}` `{"archived":…}`
  with the existing auth header + `RESTError` mapping
- [x] `SessionListFeature`: trailing swipe → `archiveButtonTapped(id:)` presents a
  `ConfirmationDialogState` (`@Presents var confirmationDialog`); confirm →
  `archiveConfirmed(id:)` does optimistic removal + RPC; on failure re-insert + `loadError`;
  also clears its pin/seen entry
- [x] `SessionListView`: trailing swipe "Archive" **and** the row's long-press context-menu
  "Archive" both route through `archiveButtonTapped` + `.confirmationDialog` bound to state
- [x] tests: swipe presents the dialog; cancel = no-op; confirm sends PATCH (body + path) +
  optimistic removal; failure re-inserts; REST client PATCH (success/401)
- [x] run tests — must pass before next task

### Task 5: Working glow (is_active + auto-poll)

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/SessionListFeature.swift` (poll timer)
- Modify: `HermesMobile/Sources/Features/SessionRowView.swift` (glow)
- Modify: `HermesMobile/Sources/Features/SessionListView.swift` (drive `.onDisappear`)
- Modify: `HermesKit/Tests/HermesKitTests/SessionListFeatureTests.swift`
- Modify: `HermesMobileTests/PreviewSnapshotTests.swift`

- [x] auto-poll: cancellable timer effect on `.task` (`clock.sleep(10s)` → `.pulledToRefresh`
  loop), cancelled on a new `.onDisappear`; paused while searching
- [x] `SessionRowView`: subtle brand-tinted pulsing glow/border when `session.isActive`
  (respects reduce-motion)
- [x] tests: poll fires a refresh after the interval (TestClock) and stops on disappear;
  active session flagged for glow
- [x] snapshot: a row in the active/glowing state
- [x] run tests — must pass before next task

### Task 6: Verify acceptance criteria

- [x] verify: in-group rows ordered by last-active; groups collapse + expand; pin/unpin with
  a top Pinned section (hidden when empty); archive removes a session (server-persisted);
  active sessions glow and refresh on the poll
- [x] verify edge cases: stale pinned id; archive failure re-inserts; search disables
  grouping/poll; logout clears pins + seen counts (➕ fixed: logout now also clears seen
  counts — was only clearing the URL + pins; extended SettingsFeatureTests to assert both)
- [x] run full suite (`make test`) + snapshots (`make snapshot`)

### Task 7: [Final] Documentation

- [x] update `README.md` (pin/archive/working glow, list behaviours) and `CLAUDE.md` if new
  patterns emerge (auto-poll, swipe actions, client-side pin store)
- [x] move this plan to `docs/plans/completed/`

## Post-Completion

*Items requiring manual intervention or external systems — informational only.*

**Manual verification (real device, live Hermes):**
- In-group ordering with real last-active times; collapse persists within a session.
- Pin/unpin across launches (per-device); archived sessions disappear and stay gone.
- Drive a session from mobile → it glows in the list within the poll interval; another
  surface's (Telegram/desktop) recent activity also reflects via `is_active`.

**External / fast-follows:**
- Viewing & unarchiving archived sessions (a filter/settings screen).
- Pin drag-reordering (desktop supports it).
- True real-time working glow — needs a Hermes backend change (a global session-status feed
  or a `live_status` field on `/api/sessions`), since events are owner-routed today.
- Cut a TestFlight build once verified.
