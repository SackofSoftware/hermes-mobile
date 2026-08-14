# Session deletion + session-list swipe/dialog polish (issue #73)

## Overview

Add permanent session deletion (server `DELETE /api/sessions/{id}`) to the session
list and the archived-sessions sheet, plus a batch of session-list interaction fixes:

- The archive confirmation must present as a bottom **action sheet**, not the
  centered/anchored popup it currently renders as on iOS 26.
- Session rows get a slightly larger **minimum height** so trailing swipe-action
  buttons always render in the full icon-over-label style (today short rows collapse
  them into cramped capsules).
- **Full swipe** on the trailing edge triggers the destructive default action
  (Archive today; Archive *or* Delete once the setting exists) instead of Rename.
- A **Settings toggle** picks the default swipe action: Archive (default) or Delete.
  The trailing swipe shows Rename + only the default action; the long-press context
  menu always shows both Archive and Delete.
- Delete from the main list confirms via the same action-sheet style as archive.
  Delete in the Archived list is immediate (no confirmation — decided in planning:
  those sessions are already tucked away and it's the bulk-cleanup surface).
- Delete is offered on any row (pinned, cron-section, branch children alike).

## Context (from discovery)

- Server endpoint exists: `DELETE /api/sessions/{session_id}` (`web_server.py:11522`
  in the hermes-agent clone), optional `profile` query param (same per-call scoping
  rule as archive: **omit for default profile**). Idempotent: deleting an
  already-absent session returns `{ok, already_absent}` — no 404 for a ghost row.
  The desktop does optimistic-remove-then-restore-on-error, same as our archive.
- **Capability gate wrinkle**: on older agents the path `/api/sessions/{id}` exists
  for `PATCH`/`GET`, so an unsupported `DELETE` returns **405 Method Not Allowed**
  (`RESTError.server(status: 405)`), not the usual 404. The `deleteSupported` flag
  must flip off on 404 *or* 405.
- Archive flow to mirror: `SessionListFeature.swift` `.archiveButtonTapped` →
  `ConfirmationDialogState` → `.confirmArchive` does optimistic removal with full
  rollback capture (session + index + pin index + seen count), an `archivingIDs`
  in-flight guard that filters fetch results, `delegate.sessionArchived` (AppFeature
  tears down the live-chat slot BEFORE the RPC), fetch cancellation, and
  local restore + `loadError` banner on failure.
- The archive dialog is *already* `ConfirmationDialogState` presented via
  `.confirmationDialog($store.scope(...))` at `SessionListView.swift:97` — the
  popup look is an iOS 26 presentation problem, not a state-model problem.
- Trailing swipe order today (`SessionListView.swift:507-515`): Rename listed first,
  Archive second. SwiftUI's full-swipe triggers the **first listed** action and
  places it nearest the edge — reordering fixes both the full-swipe target and
  gives Mail-style layout (destructive nearest edge).
- Archived sheet (`ArchivedSessionsFeature.swift` / `ArchivedSessionsView.swift`):
  swipe has Restore only; context menu has Restore + Copy ID. Restore already does
  optimistic removal + `restoringIDs` guard + rollback — delete follows the same
  shape. An archived session can never be the live-chat slot (archiving already
  tears the slot down), so no slot teardown is needed there.
- Prefs: `PreferencesClient` holds non-secret prefs, has `.inMemory()`, and **logout
  must clear every entry**. Settings UI: `SettingsFeature.swift` (HermesKit) +
  `SettingsView.swift` (app target).
- Capability-flag pattern to copy: `cronJobsSupported` (default `true`, flipped off
  by a definitive `.notFound`).

## Development Approach

- **Testing approach**: Regular (code first, then tests) — project convention:
  `TestStore` + `@Dependency` overrides; event-reduction tests are the
  highest-value suite.
- Complete each task fully before moving to the next.
- **CRITICAL: every task MUST include new/updated tests** for code changes in that
  task — success and error scenarios, listed as separate checklist items.
- **CRITICAL: all tests must pass before starting the next task**
  (`script -q /dev/null swift test --package-path HermesKit` for the SPM suite).
- **CRITICAL: update this plan file when scope changes during implementation.**
- Maintain backward compatibility: older agents without `DELETE` keep working
  (delete UI hidden after the capability flip; archive path byte-identical).

## Testing Strategy

- **Unit tests** (SPM, macOS): reducer paths for delete confirm/success/failure/
  rollback, capability flip on 404/405, preference round-trip, settings toggle,
  archived-list delete. REST client tests with an injected `URLSession` mock
  asserting method/path/query (profile omitted for default).
- **Snapshot/layout tests** (iOS target): the min-height change alters
  `SessionRowView` geometry — re-record the affected session-list snapshots only
  (targeted: run `make snapshot`, accept intended size diffs for those tests; do
  NOT global `snapshot-record`, baselines are in the known-drift state). A measured
  `UIWindow`-hosted XCTest pins the row-min-height fact a snapshot can't prove.
- No e2e suite in this project.

## Progress Tracking

- Mark completed items with `[x]` immediately when done.
- Add newly discovered tasks with ➕ prefix; blockers with ⚠️ prefix.
- Keep the plan in sync with actual work done.

## Solution Overview

- New `HermesRESTClient.deleteSession` endpoint; delete flow in
  `SessionListFeature` mirrors archive exactly (dialog → optimistic removal +
  rollback + in-flight guard + slot teardown delegate + fetch cancellation), with a
  `deleteSupported` capability flag (default `true`, flipped by 404/405 — the
  standard lazy flip, no pre-probe).
- A `SessionSwipeAction` enum (`archive` | `delete`) persisted in
  `PreferencesClient` drives which destructive action the trailing swipe shows and
  full-swipe triggers. Context menu always shows both (Delete gated on
  `deleteSupported`).
- Settings gets a capability-gated picker for the default action.
- Archived sheet gets Delete (swipe + context menu), immediate, optimistic with
  rollback.
- View polish: swipe-action reorder, row `minHeight`, and the iOS 26
  action-sheet presentation fix.

## Technical Details

- **REST**: `deleteSession(connection, id, profile)` → `DELETE
  /api/sessions/{id}` (+ `?profile=` when non-default, same threading rule as
  archive). 2xx → success (body ignored; `already_absent` is success by contract).
- **Capability flip**: treat `RESTError.notFound` OR `.server(status: 405, _)` from
  a delete as "unsupported" → `deleteSupported = false`, restore the row
  (rollback path), NO error banner (mirror the silent capability flips), hide
  Delete affordances + settings row from then on. Any other error → rollback +
  "Couldn't delete the session." banner.
- **Delegate**: new `SessionListFeature.Delegate.sessionDeleted(id:)`, handled in
  `AppFeature` identically to `sessionArchived` (tear down the live-chat slot when
  it matches) **plus** wiping the session's cached snapshot + turn anchor from
  `ChatSnapshotClient` (a deleted session must not repaint from cache).
- **Preference**: `SessionSwipeAction: String, Codable, CaseIterable`
  (`.archive` default). Stored via `PreferencesClient`
  (`defaultSessionSwipeAction` get/save), cleared on logout, effective value
  clamps to `.archive` while `deleteSupported == false`.
- **Dialog presentation**: goal state is a bottom action sheet on iPhone.
  Investigate why iOS 26 renders the current root-attached
  `.confirmationDialog` as a popup; expected fix is anchoring the modifier to the
  originating row (scoped to the same store state) or the iOS 26 source-anchor
  API — verify in the simulator, keep the `ConfirmationDialogState` model as-is.
- **Swipe rows (main list)**: trailing = [default action (destructive, first —
  full-swipe target), Rename]; leading = Pin (unchanged). Context menu: Pin,
  Rename, Copy ID, Archive, Delete(gated).
- **Row height**: `.frame(minHeight:)` on the row content in `SessionRowView`,
  value chosen so iOS renders trailing swipe buttons icon-over-label even for
  one-line rows (determine empirically in the simulator, ~56–60pt; respect
  Dynamic Type — floor only, never a cap).

## What Goes Where

- **Implementation Steps** (`[ ]`): code, tests, docs in this repo.
- **Post-Completion** (no checkboxes): manual device verification, issue closure.

## Implementation Steps

### Task 1: Add `deleteSession` to the REST client

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Clients/HermesRESTClient.swift`
- Modify: `HermesKit/Tests/HermesKitTests/HermesRESTClientTests.swift` (or the
  existing REST client test file)

- [x] add `deleteSession: @Sendable (ServerConnection, _ id: String, _ profile: String?) async throws -> Void`
      with doc comment covering the 405-on-older-agents contract
- [x] `liveValue`: `DELETE /api/sessions/{id}`, `?profile=` appended only when
      non-nil (caller passes `nil` for default — same rule as `archive`)
- [x] map non-2xx through the existing error mapping (404 → `.notFound`, 405 →
      `.server(status: 405, …)`)
- [x] write tests: success (method/path asserted), profile threading (omitted for
      nil, present otherwise)
- [x] write tests: 404 and 405 map to the expected `RESTError` cases
- [x] run tests — must pass before task 2 (full suite: 1127 tests, 60 suites, all pass)

### Task 2: Persist the default swipe action preference

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Clients/PreferencesClient.swift`
- Modify: `HermesKit/Sources/HermesKit/Models/` (new `SessionSwipeAction` — colocate
  where similar small prefs enums live, e.g. next to grouping pref if one exists)
- Modify: the `PreferencesClient` test file

- [x] add `SessionSwipeAction` enum (`archive` | `delete`, raw `String`,
      default `.archive`)
- [x] add `defaultSessionSwipeAction` load/save to `PreferencesClient`
      (+ `.inMemory()` support)
- [x] add the key to the logout wipe (**logout must clear every prefs entry** — all
      three logout recipes: Settings clear-token, retry-screen logout, reauth quit)
- [x] write tests: round-trip, default when unset, cleared by logout wipe
- [x] run tests — must pass before task 3 (full suite: 1130 tests, 60 suites, all pass)

### Task 3: Delete flow in `SessionListFeature`

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/SessionListFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/SessionListFeatureTests.swift`

- [x] state: `deleteSupported: Bool = true`, `deletingIDs: Set<String>`,
      `defaultSwipeAction: SessionSwipeAction` (loaded with the other prefs on
      `.task`; computed `effectiveSwipeAction` clamps to `.archive` when
      `!deleteSupported`)
- [x] actions: `deleteButtonTapped(id:)` raises a `ConfirmationDialogState`
      ("Delete session?" / destructive Delete / message "This permanently deletes
      the session and its history."), `Dialog.confirmDelete(id:)`,
      `deleteSucceeded(id:)`, `deleteFailed(...)` carrying the same rollback
      payload as archive (session, index, pinIndex, seenCount) plus the `error`
      (so the reducer can tell a capability verdict from a transient failure)
- [x] `confirmDelete`: mirror `confirmArchive` — capture rollback, optimistic
      removal (list + pin + seen + persist), `deletingIDs` insert, send
      `.delegate(.sessionDeleted(id:))` FIRST, cancel in-flight fetch, run
      `rest.deleteSession` with `scopedProfileName`
- [x] fetch/poll guards: extend the `archivingIDs` filtering to also exclude
      `deletingIDs` (both windows can resurrect a removed row)
- [x] `deleteFailed`: on `.notFound`/`.server(405)` flip `deleteSupported = false`,
      restore the row silently (no banner); any other error restores + sets
      `loadError = "Couldn't delete the session."`
- [x] write tests: confirm→success (optimistic removal, delegate order, prefs
      persisted, guard cleared)
- [x] write tests: failure rollback (row/pin/seen restored, banner), capability
      flip on 404 and on 405 (row restored, no banner, flag off)
- [x] write tests: fetch landing during the delete window excludes the row
- [x] run tests — must pass before task 4 (full suite: 1138 tests, 60 suites, all pass)

### Task 4: `AppFeature` teardown + snapshot wipe on delete

**Files:**
- Modify: `HermesKit/Sources/HermesKit/AppFeature.swift`
- Modify: `HermesKit/Sources/HermesKit/Clients/ChatSnapshotClient.swift` (only if a
  per-session wipe doesn't already exist)
- Modify: `HermesKit/Tests/HermesKitTests/AppFeatureTests.swift`

- [ ] handle `.sessionDeleted` like `.sessionArchived` (slot teardown via
      `teardownSlot` when the deleted id matches the live slot — nil-out is
      mandatory per the slot rules)
- [ ] additionally wipe the deleted session's snapshot + turn anchor from
      `ChatSnapshotClient` (add a `deleteSnapshot(sessionID:)` if missing,
      incl. `.inMemory()`)
- [ ] write tests: delete of the slot session tears down + wipes snapshot; delete
      of a non-slot session leaves the slot untouched but still wipes its snapshot
- [ ] run tests — must pass before task 5

### Task 5: Settings toggle for the default action

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/SettingsFeature.swift`
- Modify: `HermesMobile/Sources/Features/Settings/SettingsView.swift`
- Modify: `HermesKit/Tests/HermesKitTests/SettingsFeatureTests.swift`

- [ ] `SettingsFeature.State`: `defaultSwipeAction` + `deleteSupported` (passed in
      by `SessionListFeature` when presenting the sheet)
- [ ] action `defaultSwipeActionChanged(SessionSwipeAction)` persists via
      `PreferencesClient` and bubbles a delegate so the list updates immediately
      on sheet dismissal (mirror how other settings changes propagate)
- [ ] `SettingsView`: a "Default swipe action" `Picker` (Archive/Delete), rendered
      only when `deleteSupported`
- [ ] write tests: change persists + delegate fires; row hidden state when
      unsupported (reducer-level: state exposes the flag)
- [ ] run tests — must pass before task 6

### Task 6: Main-list view changes — swipe order, default action, context menu, dialog presentation

**Files:**
- Modify: `HermesMobile/Sources/Features/SessionListView.swift`
- Modify: `HermesMobile/Sources/Features/SessionRowView.swift`
- Modify: `HermesMobileTests/` (snapshot + measured layout tests)

- [ ] reorder trailing swipe: destructive default action FIRST (nearest edge,
      full-swipe target), then Rename; button is Archive or Delete per
      `store.effectiveSwipeAction`
- [ ] context menu: Pin, Rename, Copy ID, Archive, and Delete (Delete only when
      `deleteSupported`; both destructive-styled)
- [ ] `SessionRowView`: add `minHeight` floor so trailing swipe buttons always
      render icon-over-label (tune in simulator; floor not cap, Dynamic Type safe)
- [ ] fix the archive/delete confirmation to present as a bottom action sheet on
      iOS 26 (investigate anchor: row-attached `.confirmationDialog` scoped to the
      same store state, or the iOS 26 source-anchor API); verify in simulator for
      both swipe-button and context-menu entry points
- [ ] re-record affected session-list/row snapshots (targeted `make snapshot`
      double-run for new ones; judge existing diffs by render-size rule)
- [ ] write a measured `UIWindow`-hosted XCTest pinning the row min-height at
      `.dynamicTypeSize(.large)`
- [ ] run `make snapshot` + SPM suite — must pass before task 7

### Task 7: Delete in the Archived sessions sheet

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/ArchivedSessionsFeature.swift`
- Modify: `HermesMobile/Sources/Features/ArchivedSessionsView.swift`
- Modify: `HermesKit/Tests/HermesKitTests/ArchivedSessionsFeatureTests.swift`

- [ ] state/actions: `deletingIDs`, `deleteButtonTapped(id:)` (NO confirmation —
      immediate, decided in planning), `deleteSucceeded`/`deleteFailed(id:session:index:)`
      mirroring the restore flow's optimistic removal + rollback
- [ ] thread `profileName` into `rest.deleteSession`; on 404/405 restore silently
      and hide Delete affordances for the rest of the sheet's lifetime
      (`deleteSupported` on the sheet state, seeded from the list's flag)
- [ ] `ArchivedSessionsView`: trailing swipe gains Delete (destructive, full-swipe
      target, gated), context menu gains Delete (gated)
- [ ] wipe the deleted session's snapshot via the Task-4 client endpoint
- [ ] write tests: delete success (optimistic removal, guard), failure rollback +
      banner, capability flip, refresh-during-delete exclusion
- [ ] run tests — must pass before task 8

### Task 8: Verify acceptance criteria

- [ ] all issue-#73 + polish requirements from Overview implemented (walk the list)
- [ ] edge cases: delete last row, delete pinned row, delete while offline
      (banner + rollback), delete on old agent (silent flip, UI hides), full-swipe
      archive still confirms, archived-sheet delete does not
- [ ] run full SPM suite: `script -q /dev/null swift test --package-path HermesKit`
- [ ] run `make snapshot` — judge failures by the render-size rule
- [ ] `tuist generate` + app build to confirm no target breakage

### Task 9: Update documentation

- [ ] update `docs/features/session-list.md` (delete flow, capability gate incl.
      the 405 wrinkle, swipe-default setting, archived-sheet delete, row height)
- [ ] update `CLAUDE.md` session-list bullet if the compressed rules change
- [ ] close issue #73 reference: note in the plan that the GitHub issue can be
      closed on merge
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion

**Manual verification:**
- On-device iOS 26 check that both confirmations present as bottom action sheets
  from swipe and context-menu entry points.
- Against a real agent: delete an active session mid-turn (slot teardown, no
  stray socket), delete from a non-default profile, delete on an older agent
  build if one is around (405 flip).

**External systems:**
- None — server endpoint already shipped in hermes-agent.
