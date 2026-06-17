# Group cron sessions into a Cron Jobs section

GitHub issue: https://github.com/goncharik/hermes-mobile/issues/12

## Overview

The Hermes server tags every session with a `source` field (`cron`, `cli`,
`telegram`, `discord`, `slack`, `whatsapp`, or `null` for local interactive
sessions). The desktop/web app breaks **cron** sessions out into their own group
(Clock icon, warning color — see `web/src/pages/SessionsPage.tsx` `SOURCE_CONFIG`).

The mobile app currently ignores `source` entirely: the `Session` model doesn't
decode it, and grouping only supports `.workspace` / `.chronological`.

This change:

1. **Decodes `source`** onto the `Session` domain model (via the REST list DTO).
2. **Surfaces a dedicated, always-on "Cron Jobs" section** for `source == "cron"`
   sessions — separate from the regular interactive list in **both** grouping
   modes (cron jobs are conceptually distinct from interactive chats). Cron
   sessions are pulled out *before* pinning/workspace/chronological grouping, so
   they never double-appear.
3. **Renders the section** in `SessionListView` with the Clock (`clock`) icon to
   mirror desktop.

**Scope (decided):** cron-only. We do **not** generalize to per-source grouping
for telegram/discord/etc. — that remains a future open question (YAGNI). We do
**not** add a new `SessionGroupingMode` case — the Cron Jobs section is always-on,
orthogonal to the selected grouping mode.

## Context (from discovery)

Files/components involved:
- `HermesKit/Sources/HermesKit/Models/Session.swift` — domain model (`Session`),
  needs `source` + an `isCron` helper.
- `HermesKit/Sources/HermesKit/Clients/HermesRESTClient.swift` — `SessionListDTO`
  decodes `/api/sessions` rows (reused by `HermesProfileClient`'s profile-scoped
  list). Add `source` here → flows to every list path.
- `HermesKit/Sources/HermesKit/Features/SessionListFeature.swift` — computed
  state (`pinnedSessions`, `unpinnedSessions`, `groups`, `chronologicalSessions`).
  Add `cronSessions` and base the interactive computeds on the non-cron remainder.
- `HermesMobile/Sources/Features/SessionListView.swift` — renders the list; already
  carries scaffolding comments anticipating a "Cron jobs" sibling section.
- Tests: `HermesKit/Tests/HermesKitTests/SessionGroupTests.swift`,
  `SessionListFeatureTests.swift`, and snapshot test
  `HermesMobileTests/SessionSnapshotTests.swift`.

Related patterns found:
- Web reference: `cron` → Clock icon, warning color (`SOURCE_CONFIG`).
- `resolvedTitle` already strips the server's `"Untitled"` placeholder (used for
  auto-named/cron sessions) — cron rows will fall back to preview/id naming, which
  is fine.
- `SessionListDTO.asSession` is the single REST→domain mapping; the profile-scoped
  list reuses it, so one edit covers both list sources.

Dependencies identified:
- Gateway `SessionHandle` (`session.create`/`session.resume` result) is **not** a
  list row and carries no `source` — no gateway decode change is needed for the
  list. The list is always populated from REST.

## Development Approach

- **Testing approach: Regular** (code first, then tests) — per planning decision.
- Complete each task fully before moving to the next; small, focused changes.
- **Every task includes new/updated tests** — success and error/edge scenarios.
- **All tests must pass before starting the next task.**
- Run `script -q /dev/null swift test --package-path HermesKit` (or `make test`)
  after each change; `make snapshot` for view changes.
- Maintain backward compatibility: old agents that omit `source` decode to `nil`
  (no cron section) — byte-identical behavior to today.
- Keep this plan in sync if scope shifts during implementation.

## Testing Strategy

- **Unit tests (HermesKit):** required every task.
  - `Session` decode/`isCron` helper.
  - `SessionListDTO` decoding `source` (present + absent).
  - `SessionListFeature` computeds: cron pulled out of pinned/groups/chronological;
    `cronSessions` sorted by recency; non-cron list unaffected when no cron present.
- **Snapshot tests (HermesMobileTests):** `SessionListView` with a cron fixture in
  both grouping modes; re-record (`make snapshot-record`) since the list UI gains a
  section. Add a case asserting no Cron Jobs section renders when no cron sessions
  exist (regression guard against an empty header).
- Treat snapshots with the same rigor as unit tests — must pass before next task.

## Solution Overview

- **Decode once, low in the stack:** `source` lands on `Session` via the shared
  `SessionListDTO`, so REST + profile-scoped lists both get it for free.
- **Cron is filtered first in the reducer's computed state**, not in the view: a new
  `cronSessions` computed returns recency-sorted cron rows; `pinnedSessions` /
  `unpinnedSessions` (and thus `groups` / `chronologicalSessions`) operate on the
  **non-cron remainder**. This keeps the view declarative and the partition logic
  unit-testable, and guarantees a cron session never appears in two places.
- **Always-on section in the view:** below the interactive sessions/groups (matching
  the selected layout), gated on `!cronSessions.isEmpty && !isSearching`, with a
  `clock`-icon header. Search stays flat and **not** cron-partitioned (mirrors the
  flat search list today).

## Technical Details

- `Session.source: String?` — raw server value (don't enum-ify; we only special-case
  `"cron"` and want to stay lenient about unknown sources).
- `Session.isCron: Bool { source == "cron" }` — single source of truth for the
  partition, used by the reducer and testable in isolation.
- `SessionListDTO`: add `let source: String?`, `case source` in `CodingKeys`
  (key is literally `source`), map `source: source` in `asSession`.
- `SessionListFeature.State`:
  - `interactiveSessions` (or inline): `sessions.filter { !$0.isCron }`.
  - `cronSessions: [Session]` — `sessions.filter(\.isCron)` sorted by `updatedAt`
    desc (nil last), mirroring `chronologicalSessions`.
  - Rebase `pinnedSessions` / `unpinnedSessions` on the non-cron remainder so a
    pinned-but-cron id surfaces only under Cron Jobs (edge case; keep it simple).
- View: a `Section` with header `Label("Cron Jobs", systemImage: "clock")` (match
  the existing `sessionsSectionHeader` styling for visual parity), iterating
  `store.cronSessions` via the existing `row(_:)` builder (swipe/context actions,
  unread/active styling all reused). Rendered after the interactive sections.

## Progress Tracking

- Mark completed items `[x]` immediately when done.
- New tasks: ➕ prefix. Blockers: ⚠️ prefix.
- Update this plan if implementation deviates from scope.

## What Goes Where

- **Implementation Steps** (`[ ]`): model decode, reducer computeds, view section,
  tests, snapshots — all in this repo.
- **Post-Completion** (no checkboxes): manual on-device check against a live agent
  that actually has cron sessions; bumping build for TestFlight (out of scope here).

## Implementation Steps

### Task 1: Decode `source` onto `Session` + REST DTO

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Models/Session.swift`
- Modify: `HermesKit/Sources/HermesKit/Clients/HermesRESTClient.swift`
- Modify: `HermesKit/Tests/HermesKitTests/` (DTO/decoding test — extend the existing
  REST client test file if present, else add `SessionSourceTests.swift`)

- [ ] add `public var source: String?` to `Session` with a default-`nil` param in
      the memberwise `init` (keep it last so existing call sites compile unchanged)
- [ ] add `public var isCron: Bool { source == "cron" }` to `Session`
- [ ] add `let source: String?` + `case source` to `SessionListDTO.CodingKeys` and
      pass `source: source` in `asSession`
- [ ] write a test decoding a `/api/sessions` row JSON with `"source":"cron"` →
      `Session.isCron == true`
- [ ] write a test decoding a row with `source` **absent** and `source: null` →
      `source == nil`, `isCron == false` (backward-compat / leniency)
- [ ] run tests — must pass before Task 2

### Task 2: Partition cron sessions in `SessionListFeature` computed state

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/SessionListFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/SessionListFeatureTests.swift`
- Modify: `HermesKit/Tests/HermesKitTests/SessionGroupTests.swift` (only if a pure
  grouping helper is added there; otherwise leave untouched)

- [ ] add a private/computed `interactiveSessions` = non-cron sessions, and rebase
      `pinnedSessions` / `unpinnedSessions` onto it (so cron never feeds pinned or
      the workspace/chronological groups)
- [ ] add `public var cronSessions: [Session]` — cron sessions sorted by
      `updatedAt` desc (nil last), matching `chronologicalSessions`
- [ ] verify `groups` / `chronologicalSessions` now derive from the non-cron
      remainder (no separate change if they already build on `unpinnedSessions`)
- [ ] write a test: mixed cron + interactive sessions → `cronSessions` contains only
      cron (recency-ordered) and `groups`/`chronologicalSessions`/`pinnedSessions`
      exclude them
- [ ] write a test: a pinned id that is also cron → appears in `cronSessions`, not
      in `pinnedSessions` (documents the edge-case resolution)
- [ ] write a test: zero cron sessions → `cronSessions == []`, interactive list
      identical to pre-change behavior (regression guard)
- [ ] run tests — must pass before Task 3

### Task 3: Render the Cron Jobs section in `SessionListView`

**Files:**
- Modify: `HermesMobile/Sources/Features/SessionListView.swift`

- [ ] add a `cronJobsSection` (a `Section` with a `clock`-icon header styled like
      `sessionsSectionHeader`) iterating `store.cronSessions` via the existing
      `row(_:)` builder
- [ ] render it (non-search branch only) after the interactive sections, gated on
      `!store.cronSessions.isEmpty`
- [ ] confirm `tuist generate` is run if the build needs the source picked up
      (no new file here, so regeneration is likely unnecessary — note if it is)
- [ ] build the app target to confirm it compiles (`make` / `xcodebuild` per
      `docs/development.md`)
- [ ] (no unit tests in the app target — view behavior is covered by Task 4
      snapshots; note this here so the no-test slot is intentional)

### Task 4: Snapshot tests for the Cron Jobs section

**Files:**
- Modify: `HermesMobileTests/SessionSnapshotTests.swift`
- Modify: `HermesMobileTests/__Snapshots__/` (recorded images)

- [ ] add `testSessionList_cronSection` with a fixture mixing cron + interactive
      sessions (pin/timestamps pinned for determinism, mirroring existing cases)
- [ ] add a case asserting the Cron Jobs section is absent when no cron sessions
      exist (e.g. reuse `testSessionList` expectations — guards an empty header)
- [ ] record snapshots: `make snapshot-record`, then verify with `make snapshot`
- [ ] visually inspect the recorded image (Clock icon, section placement)
- [ ] run snapshot suite — must pass before Task 5

### Task 5: Verify acceptance criteria

- [ ] cron sessions appear only under "Cron Jobs", in both `.workspace` and
      `.chronological` modes (not in Pinned/groups/chronological)
- [ ] agents without `source` (or `source: null`) show no Cron Jobs section and
      behave exactly as before
- [ ] search remains flat and un-partitioned
- [ ] run full HermesKit suite: `script -q /dev/null swift test --package-path HermesKit`
- [ ] run snapshot suite: `make snapshot`

### Task 6: [Final] Update documentation

- [ ] update `CLAUDE.md` session-list grouping note if the Cron Jobs partition is a
      convention worth recording (always-on, cron-only, filtered in the reducer)
- [ ] update `README.md` feature overview if it enumerates session-list grouping
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion

*Items requiring manual intervention or external systems — informational only.*

**Manual verification:**
- Run against a live Hermes agent that actually has cron-scheduled sessions and
  confirm they land in the Cron Jobs section with correct titles/timestamps.
- Confirm dark/light appearance of the Clock-icon header looks right on device
  (snapshots cover layout, not necessarily every appearance).

**External system updates:**
- None — this is a client-only display change; no server/API changes.
- A TestFlight build bump (build number) is a separate, out-of-scope step when
  shipping.
