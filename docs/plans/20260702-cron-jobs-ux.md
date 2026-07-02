# Cron Jobs UX: unread indicators + desktop-style job grouping (#24)

## Overview

Cron sessions currently render as a flat, dot-less list at the bottom of the session list, so
daily cron output is effectively invisible: no unread indicator ever lights up (cron sessions are
never seeded into `seenCounts`), and the section requires deliberate scrolling. This plan ships
issue #24's direction **A (unread parity)** plus **desktop-style job→runs grouping**:

- Cron sessions join the unread pipeline (per-row dots) and the "Cron Jobs" section header gets an
  **aggregate unread badge** (count of cron sessions with unseen output), mirroring the desktop's
  `CRON JOBS 4` badge.
- The section's rows become cron **jobs** (name + state dot + relative next-run countdown, e.g.
  "in 7 hr"), sorted by soonest next run. Tapping a job expands a **single-open inline peek** of
  its most recent runs (~5); tapping a run opens that session's chat via the existing
  `openSession` delegate.
- Job rows get **manage actions** via context menu (and swipe where sensible): **Run now**
  (trigger), **Pause/Resume**.
- Everything is **capability-gated**: agents whose `GET /api/cron/jobs` is missing/failing fall
  back to today's flat cron section unchanged. The section **stays at the bottom** of the list
  (no tray/layout change — issue direction B is out of scope, deferred).

## Context (from discovery)

- **Grouping key (verified in hermes-agent source):** cron run sessions are ordinary sessions with
  id `cron_{job_id}_{YYYYMMDD_HHMMSS}` (`cron/scheduler.py:1491`, job_id = 12-char hex). Newer
  agents also expose `GET /api/cron/jobs/{job_id}/runs?limit=` (rows shaped like `/api/sessions`),
  but since the mobile client already receives all cron sessions in the one `/api/sessions` fetch,
  **grouping is done client-side by id-prefix match** — no new per-job fetch, works on older agents.
- **Jobs metadata:** `GET /api/cron/jobs` (present in v0.16.0+, takes `?profile=`, default `all`)
  returns per-job dicts: `id`, `name`, `prompt`, `schedule_display`, `enabled`, `state`
  (`scheduled`/`running`/`paused`/`error`/`completed`/`disabled`), `next_run_at`, `last_run_at`,
  `last_status`, plus annotations `profile`/`is_default_profile`. Actions:
  `POST /api/cron/jobs/{id}/trigger`, `/pause`, `/resume` (all take optional `?profile=`).
- **Desktop reference** (`apps/desktop/src/app/chat/sidebar/cron-jobs-section.tsx` on upstream
  main): collapsible section, count label in header, jobs sorted by soonest `next_run_at`
  (no-next-run sinks to bottom, then alphabetical), single-open peek of last 5 runs, relative-time
  countdown, `jobTitle` fallback chain name → prompt(60) → script(60) → id, `jobState` = explicit
  `state` else `enabled == false ? disabled : scheduled`.
- **Mobile current state:**
  - Partition: `SessionListFeature.State.cronSessions` / `interactiveSessions`
    (`HermesKit/Sources/HermesKit/Features/SessionListFeature.swift:147-157`).
  - Unread: `unreadSessionIDs` (`:184`) covers all sessions, but seeding writes only non-cron
    sessions into `seenCounts` (see `:523` and `:538` paths) — the cron bug to fix.
  - Rendering: `cronJobsSection` reuses `row(_:)`
    (`HermesMobile/Sources/Features/SessionListView.swift:151-178`).
  - REST client: `HermesRESTClient` (`@DependencyClient`), endpoints as `@Sendable` closures,
    `RESTError` taxonomy incl. `.notFound` for capability probes (profiles pattern).
  - Profile scoping: `scopedProfileName` (nil for default/unsupported) threads `?profile=`.
- Dependencies: no new packages. `now: Date` already in state for relative timestamps
  (deterministic snapshots); poll refreshes it.

## Development Approach

- **Testing approach: Regular** (code first, then tests in the same task)
- Complete each task fully before moving to the next
- Make small, focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
  - tests are not optional — they are a required part of the checklist
  - unit tests for new and modified functions; new cases for new code paths
  - tests cover both success and error scenarios
- **CRITICAL: all tests must pass before starting next task** — no exceptions
- **CRITICAL: update this plan file when scope changes during implementation**
- Run tests after each change (`script -q /dev/null swift test --package-path HermesKit` or `make test`)
- Maintain backward compatibility: old agents (no `/api/cron/jobs`) keep today's flat section

## Testing Strategy

- **Unit tests** (HermesKit SPM suite): required for every task — model decoding, pure helpers
  (job-id parse, title/state/countdown), reducer event reduction with `TestStore` + `TestClock` +
  `@Dependency` overrides.
- **Snapshot tests** (`HermesMobileTests`, `make snapshot` / `make snapshot-record`): grouped cron
  section (collapsed + expanded peek, unread badge, paused job), and fallback flat section. Pin
  `now`/timestamps for determinism. Re-record intentionally changed session-list snapshots.
- No e2e suite in this project.

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- update plan if implementation deviates from original scope
- keep plan in sync with actual work done

## Solution Overview

- **New `CronJob` model** in HermesKit decoded leniently from `/api/cron/jobs` (unknown fields
  ignored; unknown `state` strings pass through as raw). Pure helpers mirror the desktop:
  `title` (name → prompt-clip → id), `effectiveState`, and a session-id parser
  `CronJob.jobID(fromSessionID:)` that extracts `{job_id}` from `cron_{job_id}_{timestamp}`
  (lenient: returns nil for non-cron ids).
- **REST endpoints on `HermesRESTClient`:** `cronJobs(connection, profile)` +
  `triggerCronJob` / `pauseCronJob` / `resumeCronJob` (each `(connection, id, profile)`),
  threading `?profile=` per the existing scoping convention (omitted for default).
- **Reducer:** fetch jobs alongside the session fetch on `.task`/`.pulledToRefresh`/`.pollTick`;
  a definitive 404 sets `cronJobsSupported = false` (flat fallback), transport errors keep the
  previous jobs (don't flap the UI). Computed state groups `cronSessions` under jobs by id-prefix;
  runs that match no known job stay in a flat "other" bucket rendered like today. Single-open
  `expandedCronJobID`. Aggregate `cronUnreadCount` drives the header badge. **Unread fix:** cron
  sessions are seeded into `seenCounts` exactly like interactive ones, and opening a run marks it
  seen through the existing `sessionTapped` path.
- **Job actions:** context menu on job rows → Run now / Pause / Resume; fire the RPC, then refetch
  jobs (+ sessions for trigger) on success; failure surfaces via the existing `loadError` banner.
  No optimistic mutation (job state is server-computed; a refetch is cheap and the poll would
  reconcile anyway).
- **View:** `cronJobsSection` becomes job rows (state dot, title, `next_run_at` countdown derived
  from `state.now` — no per-second ticker; the poll refresh is enough), unread dot when any of the
  job's runs are unread, header badge, inline peek listing the job's latest runs via the standard
  `row(_:)` builder. Expansion animation respects reduce-motion. Capability-gated fallback renders
  today's flat section.

## Technical Details

- **`CronJob` decoding** (subset): `id: String`, `name: String?`, `prompt: String?`,
  `scheduleDisplay: String?` (`schedule_display`), `enabled: Bool?`, `state: String?`,
  `nextRunAt: Date?` (`next_run_at`, ISO8601 w/ fractional-seconds tolerance),
  `lastRunAt: Date?`, `lastStatus: String?`, `profile: String?`. Decode via explicit
  `CodingKeys`; never crash on unknowns.
- **Session→job matching:** primary = `CronJob.jobID(fromSessionID:)` string parse
  (`cron_` prefix, next segment up to the `_{8 digits}_{6 digits}` tail); a run whose parsed id
  matches no fetched job (deleted job, legacy id) lands in `unmatchedCronSessions`.
- **Grouped computed state:** `cronJobGroups: [CronJobGroup]` where
  `CronJobGroup { job: CronJob; runs: [Session] }`, jobs sorted desktop-style (soonest
  `nextRunAt` first, nil-next-run last, then title), runs sorted `updatedAt` desc capped at 5 for
  the peek; `cronUnreadCount = cron sessions ∩ unreadSessionIDs`.
- **Countdown formatting:** pure helper `relativeRunLabel(from:to:)` (RelativeDateTimeFormatter or
  manual coarse units — minute/hour/day, "in 7 hr." / "2 hr. ago") unit-tested in HermesKit;
  view feeds it `state.now`.
- **Capability gating:** `cronJobsSupported: Bool` defaults true (optimistic, like
  `pushAvailable`); set false only on `RESTError.notFound`. When false or `cronJobGroups` can't
  be built (no jobs fetched yet), render the flat section.
- **Processing flow:** `.task`/`.pollTick` → parallel `sessions` + `cronJobs` fetches →
  `.cronJobsResponse(Result<[CronJob], RESTError>)` → state.cronJobs / supported flag →
  computed groups → view.

## What Goes Where

- **Implementation Steps** (`[ ]` checkboxes): code changes, tests, documentation updates in this repo
- **Post-Completion** (no checkboxes): manual device verification, issue #24 update, agent-version matrix checks

## Implementation Steps

### Task 1: CronJob model + pure helpers

**Files:**
- Create: `HermesKit/Sources/HermesKit/Models/CronJob.swift`
- Create: `HermesKit/Tests/HermesKitTests/CronJobTests.swift`

- [x] add `CronJob` Decodable/Equatable/Sendable/Identifiable with lenient `CodingKeys` decoding (`schedule_display`, `next_run_at`, `last_run_at`, ISO8601 dates with/without fractional seconds)
- [x] add `title` (name → 60-char prompt clip → id) and `effectiveState` (explicit `state` else `enabled == false ? "disabled" : "scheduled"`) mirroring the desktop's `jobTitle`/`jobState`
- [x] add `CronJob.jobID(fromSessionID:)` static parser for `cron_{job_id}_{YYYYMMDD_HHMMSS}` ids (nil for non-matching/interactive ids)
- [x] add `relativeRunLabel(for:now:)` coarse relative-time helper (sec/min/hr/day, past + future, locale-deterministic manual strings)
- [x] write tests: decoding (full payload, minimal payload, unknown fields/state), title/state fallback chains
- [x] write tests: jobID parse (valid, legacy/odd ids, non-cron ids → nil), relativeRunLabel units + past/future
- [x] run tests — must pass before task 2 (13/13 pass)

### Task 2: REST endpoints for cron jobs + actions

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Clients/HermesRESTClient.swift`
- Modify: `HermesKit/Tests/HermesKitTests/HermesRESTClientTests.swift`

- [x] add `cronJobs: (ServerConnection, _ profile: String?) async throws -> [CronJob]` hitting `GET /api/cron/jobs` (`?profile=` only when non-nil, per `scopedProfileName` convention)
- [x] add `triggerCronJob` / `pauseCronJob` / `resumeCronJob` `(ServerConnection, _ id: String, _ profile: String?)` POSTs via a shared `cronJobAction` helper, errors through the existing `RESTError` taxonomy (404 → `.notFound`)
- [x] provide `testValue` no-ops consistent with the client's existing pattern (`@DependencyClient` unimplemented defaults)
- [x] write tests: cronJobs success decode + profile query threading (present when scoped, absent for default)
- [x] write tests: 404 → `.notFound`, non-2xx → `.server`, action endpoints hit the right paths/methods
- [x] run tests — must pass before task 3 (53/53 REST suite passes)

### Task 3: Reducer — fetch jobs, capability gate, grouped computed state, unread fix

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/SessionListFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/SessionListFeatureTests.swift`

- [x] add state: `cronJobs: IdentifiedArrayOf<CronJob>`, `cronJobsSupported: Bool = true`, `expandedCronJobID: String?`
- [x] fetch cron jobs alongside sessions on `.task`, `.pulledToRefresh`, and `.pollTick`; add `.cronJobsResponse(Result<[CronJob], RESTError>)` — success stores jobs, `.notFound` sets `cronJobsSupported = false`, other errors keep previous jobs (no UI flap). ➕ Implemented INSIDE the session-load effect (sequential, after `.sessionsResponse`) rather than a merged parallel effect, so TestStore receive order is deterministic and one CancelID covers both.
- [x] add computed `cronJobGroups: [CronJobGroup]` (desktop sort: soonest next-run first, nil last, then title; runs = id-prefix-matched cron sessions, `updatedAt` desc, peek-capped at 5) and `unmatchedCronSessions`
- [x] add computed `cronUnreadCount` (cron sessions in `unreadSessionIDs`)
- [x] unread seeding: ➕ verified the `:523` seeding loop and `unreadSessionIDs` ALREADY cover cron sessions (the gap in the issue text predates the ChatView-rewrite refactor) — locked in with regression tests (seed-on-discovery, seen-on-open, badge count) instead of re-fixing
- [x] add `.cronJobTapped(id:)` toggling the single-open `expandedCronJobID`
- [x] reset cron state on profile switch (selectProfile + delete-profile re-home); logout recreates state
- [x] write tests: jobs fetched with sessions (profile scoping both ways), 404 flips supported flag + skips later fetches, transport error keeps previous jobs
- [x] write tests: grouping (match, unmatched bucket, sort order, peek cap + unread-outside-peek), `cronUnreadCount`, cron seeding + seen-on-open, expand/collapse toggling (12 tests in `SessionListCronTests.swift`)
- [x] ➕ update 16 existing SessionListFeature tests + 2 AppFeature foreground tests for the new fetch (stub + one `.cronJobsResponse` receive each)
- [x] run tests — must pass before task 4 (full suite: 646 tests / 48 suites pass)

### Task 4: Reducer — job manage actions (trigger / pause / resume)

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/SessionListFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/SessionListFeatureTests.swift`

- [x] add actions `.triggerCronJob(id:)`, `.pauseCronJob(id:)`, `.resumeCronJob(id:)` firing the REST call (profile scoping = literal selected name when supported, matching the jobs fetch)
- [x] on success refetch: full load after trigger (new run session), jobs-only for pause/resume; on failure surface `loadError` with the server detail — funneled through one `.cronJobActionFinished` action
- [x] guard double-fire: `cronActionInFlightIDs` transient set (mirrors `archivingIDs`)
- [x] write tests: trigger (sessions+jobs refetch), pause/resume (jobs-only — unstubbed sessions dependency proves no list fetch), failure (banner, no refetch)
- [x] write tests: in-flight double-fire guard (all three actions)
- [x] run tests — must pass before task 5 (651 tests / 48 suites pass)

### Task 5: View — grouped cron section, badge, peek, fallback + snapshots

**Files:**
- Modify: `HermesMobile/Sources/Features/SessionListView.swift`
- Modify: `HermesMobileTests/SessionListSnapshotTests.swift` (name per existing suite)

- [x] replace `cronJobsSection` rows with job rows when groups exist: state dot (➕ live states are GREEN, not accent — the app accent is orange and would be indistinguishable from the amber paused pip), `title`, `relativeRunLabel` countdown (schedule line when no next run), unread dot when the job has unread runs; expand animation respects reduce-motion
- [x] section header: clock icon + aggregate unread badge (`cronUnreadCount`, hidden at 0)
- [x] tap job → `.cronJobTapped` inline peek (indented, single-open, "No runs yet" empty state): runs via the standard `row(_:)` builder; `unmatchedCronSessions` flat below the groups
- [x] context menu on job rows: Run now / Pause (or Resume when paused)
- [x] fallback: `!cronJobsSupported` (or no jobs yet) renders today's flat section unchanged; search continues to hide the cron section
- [x] add snapshot tests: grouped collapsed w/ badge + paused row, expanded peek w/ unread run, unsupported-agent flat fallback w/ badge (pinned `now`; existing baselines unchanged)
- [x] run snapshot record + assert (all pass; ➕ stale generated project needed `tuist generate` after the transcript-renderer removal; spurious swift-snapshot-testing lockfile pin reverted per prior convention) — before task 6

### Task 6: Verify acceptance criteria

- [x] unread dots light up on cron runs and the header badge counts them (issue gap 1 closed — reducer tests + grouped/fallback snapshots)
- [x] section groups by job with next-run countdown and expandable runs (issue gap 2, desktop parity within the list — grouping tests + snapshots)
- [x] old-agent fallback verified (cronJobs 404 → supported flag off, later fetches skipped, flat section snapshot w/ working badge)
- [x] regular session-list UX unchanged (all pre-existing tests pass; existing snapshot baselines byte-identical)
- [x] run full test suite: 651 tests / 48 suites pass
- [x] run snapshot suite: all pass

### Task 7: [Final] Update documentation

- [ ] update `CLAUDE.md` cron-sessions bullet (grouping model, capability gate, unread badge)
- [ ] update `docs/architecture.md` / `README.md` if the feature overview mentions the cron section
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion

*Items requiring manual intervention or external systems — no checkboxes, informational only*

**Manual verification:**
- On-device against a real agent with ≥2 cron jobs (one paused): badge counts, countdown sanity ("in 7 hr" style), trigger-now produces a new run that appears in the peek and lights unread, pause/resume flips the state dot
- Against an older agent build lacking `/api/cron/jobs`: flat section fallback
- Multi-profile agent: jobs scoped correctly when a non-default profile is selected

**External system updates:**
- Comment on / close issue #24 noting direction B (bottom tray) was deliberately deferred — file a follow-up issue if still wanted after living with the badge
