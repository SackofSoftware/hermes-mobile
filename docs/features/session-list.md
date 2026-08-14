# Session list: grouping, cron jobs, branch nesting, delete & swipe polish (#24, #34, #73)

Normative invariants moved out of `CLAUDE.md` (2026-08-14 restructure). The short rules live in
`CLAUDE.md` → "Session list"; this doc is the full contract. Design history:
`docs/plans/completed/`.

## Grouping & archived

Session-list grouping is a persisted UI pref (`SessionGroupingMode`: `.workspace` /
`.chronological`) in `PreferencesClient` — display-only over the one fetched `sessions` array
(no fetch/order change), reset on logout. The list is a flat `.listStyle(.plain)`; grouping
options + the **Archived sessions** entry live in a top-trailing `Menu`; "New chat" is a bottom
bar via **`.safeAreaInset(edge: .bottom)`** (a `.bottomBar` toolbar renders blank in the
snapshot host). **Archived** is a server query (`?archived=only`) shown in a sheet
(`ArchivedSessionsFeature`); restore = `archive(id, false)`; tap-to-open bubbles up the existing
`openSession` delegate.

## Cron sessions & the Cron Jobs section (#24)

**Cron sessions** (`source == "cron"`, decoded onto `Session` via `SessionListDTO`) are pulled
into an **always-on, separate "Cron Jobs" section** — orthogonal to the grouping mode (no new
`SessionGroupingMode` case). The partition lives in the reducer's computed state (`cronSessions`
vs the non-cron `interactiveSessions` that feeds
`pinnedSessions`/`groups`/`chronologicalSessions`), so cron rows never appear in
Pinned/workspace/chronological. Rendered with a `clock`-icon header below the interactive
sections, and **not shown during search** (search stays flat).

**The Cron Jobs section groups runs under their *jobs*, desktop-style**: `GET /api/cron/jobs` is
fetched sequentially INSIDE the session-load effect (after `.sessionsResponse`, same CancelID —
deterministic TestStore order, no racy merge); a run session binds to its job via the
id-embedded prefix (`cron_{job_id}_{ts}` → `CronJob.jobID(fromSessionID:)`) — upstream has a
`/runs` endpoint, but the client groups from the already-fetched sessions so **older agents work
too**. Job rows: state pip (**green live / amber paused** — deliberately NOT the accent, which
is orange and would be indistinguishable from amber; red error, gray inactive),
`relativeRunLabel` next-run countdown off `state.now` (poll-refreshed — no per-second ticker),
unread dot judged over ALL the job's runs (not just the peeked 5), and a context menu (Run now /
Pause / Resume → `cronActionInFlightIDs` double-fire guard; success refetches — full load after
trigger, jobs-only for pause/resume; **no optimistic job-state mutation**). Tap = single-open
inline peek (`expandedCronJobID`) of the newest `cronPeekLimit` runs via the standard `row(_:)`;
runs matching no fetched job render flat below (`unmatchedCronSessions` — never hide output).
The header carries the aggregate `cronUnreadCount` badge; cron sessions ride the same
`seenCounts` unread pipeline as interactive rows. **Capability-gated**: a 404 flips
`cronJobsSupported` off → flat run list, fetch skipped thereafter; transient failures keep the
previous jobs (no flapping). Jobs are fetched with the LITERAL selected profile name when
`profilesSupported` (matching the scoped session list, so a job's runs are actually present),
unscoped otherwise.

## Branch nesting is display-only (#34)

`parent_session_id` decodes leniently from REST onto `Session.parentSessionID`
(`trimmedNonEmpty`); pure `flattenSessionsWithBranches` (desktop algorithm — sibling recency
sort, group-recency lift, recursion, cycle-safe, trailing sweep, **`byVisibleID` lineage
aliasing**: `_lineage_root_id` → `Session.lineageRootID` keeps a branch nested after its parent
auto-compresses and the row id rotates to the continuation tip) runs per rendered lane (pinned /
workspace / chronological) after the cron partition, emitting `└─`/`├─` stems. Recency is
`updatedAt ?? .distantPast` — deliberately the SAME rule the lanes sort by (no desktop
`started_at` fallback), so nesting never reorders flat rows. Orphans (parent absent from the
lane) de-nest — never hidden; the Pinned lane keeps pin order (`sortTopLevelByRecency: false`; a
pinned branch nests only when its parent is also pinned, otherwise it de-nests); search /
archived / cron stay flat. Row identity and swipe/context affordances are unchanged.

## Session delete (#73)

**Delete is permanent and server-side**: REST `DELETE /api/sessions/{id}` (+`?profile=` only
when non-default — same per-call scoping rule as archive), idempotent upstream (`already_absent`
is success by contract; a ghost row never 404s). The main-list flow **mirrors archive exactly**:
`deleteButtonTapped` raises a `ConfirmationDialogState` ("This permanently deletes the session
and its history."), `confirmDelete` captures a full rollback payload (session + index + pin
index + seen count), removes optimistically, inserts into the **`deletingIDs` in-flight guard**
(fetch/poll results filter out `archivingIDs ∪ deletingIDs` — either window can resurrect a
removed row), sends `delegate.sessionDeleted` FIRST, and cancels the in-flight fetch before
running the RPC. A transient failure restores the row + pin + seen count and sets the
"Couldn't delete the session." banner. Delete is offered on every row variant (pinned, cron
runs, branch children) — all sections funnel through the one `row(_:)` builder.

**Capability gate — the 405 wrinkle**: `deleteSupported` defaults `true` and flips off lazily
on a definitive verdict from an actual delete (no pre-probe). The verdict is `.notFound` **or**
`.server(status: 405)` — on older agents the path `/api/sessions/{id}` already exists for
`PATCH`/`GET`, so an unsupported `DELETE` returns **405 Method Not Allowed**, not the usual
404. Both flip the flag **silently** (row restored, NO banner — mirror the other silent
capability flips) and hide every Delete affordance plus the Settings row from then on. The flag
mirrors **both ways** with the archived sheet: the sheet's `deleteSupported` is seeded from the
list's flag on present, and a verdict inside the sheet mirrors back via
`ArchivedSessionsFeature.Delegate.deleteUnsupported`.

**`AppFeature` on `sessionDeleted`**: ALWAYS wipe the session's cached snapshot + turn anchor
(`ChatSnapshotClient.deleteSnapshot(sessionID:)`) — a deleted session must never repaint from
the non-authoritative cache. When the deleted id matches the live-chat slot, tear it down too
with **`teardownSlot(flushSnapshot: false)`** — skipping the `persistNow` flush is the point:
the flush would re-save the very snapshot the wipe deletes. Every other teardown keeps the
flush. Same deliberate asymmetry as archive: if the DELETE later fails, the list restores the
row but the slot and cache stay cleared — re-opening simply resumes the session fresh.

**Archived-sheet delete is immediate — no confirmation (deliberate)**: those sessions are
already tucked away and the sheet is the bulk-cleanup surface. Same optimistic shape as
restore (`deletingIDs` guard, rollback + banner on transient failure, refresh-during-delete
exclusion), threading `profileName` into the RPC. The sheet calls `chatSnapshot.deleteSnapshot`
directly — no slot teardown needed, since archiving already tore the slot down (an archived
session can never be the live slot); the wipe stays even if the DELETE later fails.

## Swipe default, row polish & confirmation presentation (#73)

**The default swipe action is a device-local pref**: `SessionSwipeAction` (`archive` |
`delete`, `.archive` default) persisted via `PreferencesClient`, reset in **all three logout
recipes** (Settings clear-token, retry-screen logout, reauth quit). Views must read the
computed **`effectiveSwipeAction`**, which clamps back to `.archive` while
`!deleteSupported` — the stored pref survives the clamp, so it re-activates if a capable agent
returns. Settings exposes a "Default swipe action" `Picker`, rendered only when
`deleteSupported` (the flag is passed in when presenting the sheet); a change persists and
bubbles a delegate so the list mirrors the value immediately.

**Trailing swipe order is destructive-first**: [default action (Archive or Delete per
`effectiveSwipeAction`, destructive, listed FIRST), Rename]. SwiftUI places the first listed
button nearest the edge and makes it the **full-swipe target** — a full swipe must trigger the
destructive default (which still confirms via the dialog), never Rename (Mail-style layout).
Leading swipe (Pin) unchanged. The context menu always offers BOTH Archive and Delete
(Delete capability-gated) regardless of the swipe pref. In the archived sheet Delete is
likewise listed first (full-swipe deletes, immediately).

**Row min-height floor**: `SessionRowView.contentMinHeight = 48` pt on the row *content* — a
one-line row's natural ~46pt total is short enough that iOS collapses trailing swipe buttons
into cramped text-only capsules; 48pt of content clears the icon-over-label threshold
(verified in the iOS 26.5 simulator). It is a **floor, never a cap** — two-line previews and
large Dynamic Type grow past it freely. The fact is pinned by a measured `UIWindow`-hosted
XCTest (`SessionRowLayoutTests`: exact floor at `.large`, floor-not-cap, AX3 grows).

**Confirmations present via `BottomActionSheet`, not `.confirmationDialog`**: on iOS 26 no
system presentation docks at the bottom any more — SwiftUI's `confirmationDialog` renders as a
floating popover anchored to whatever view carries the modifier, **dropping the title and the
Cancel button** (FB20644893); UIKit's `UIAlertController(.actionSheet)` anchors to any popover
`sourceView` the same way and presents CENTERED without one. So `BottomActionSheet.swift`
renders the same reducer-owned `ConfirmationDialogState` in a height-fitted SwiftUI sheet
(content-measured detent, destructive button styled red) — **the state model and every reducer
test against it are untouched**; only the presentation layer differs, and it behaves
identically on iOS 18. Keep raising dialogs through `ConfirmationDialogState`; present them
with `.bottomActionSheet($store.scope(...))`.
