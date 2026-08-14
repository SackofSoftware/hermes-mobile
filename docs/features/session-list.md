# Session list: grouping, cron jobs, branch nesting (#24, #34)

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
