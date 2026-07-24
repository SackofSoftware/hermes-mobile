# Message Copy + Branch-in-New-Chat Buttons (issue #34)

## Overview

Add a per-message action row under completed **assistant** messages with two buttons:

1. **Copy** — copies the message's raw Markdown to the clipboard (surfaces the existing
   long-press context-menu action as a visible affordance, with checkmark feedback).
2. **Branch in new chat** — desktop-parity branch: creates a **new session seeded with
   only that message's text** via `session.create` (`messages` seed +
   `parent_session_id`), then opens the new chat. No dedicated branch RPC exists —
   the desktop (upstream `main`, ~v0.17) does exactly this.

Additionally, the session list must display branch sessions **nested under their
parent** (desktop-style `└─`/`├─` elbow + indent), driven by the `parent_session_id`
field already present in the REST `GET /api/sessions` payload.

## Context (from discovery)

Verified against hermes-agent upstream `main` (fast-forwarded 2026-07-24) and the
mobile codebase:

- **Desktop branch mechanics** (`apps/desktop/src/app/session/hooks/use-session-actions/index.ts:1058-1171`):
  per-message `GitForkIcon` button → `session.create` with
  `{cols, source: 'desktop', cwd?, messages: [{content, role}], parent_session_id}` —
  **no `title`** (server auto-titles on first submit via the LLM titler;
  `get_next_title_in_lineage` only disambiguates collisions). Seeds **only the selected
  message** (`slice(at, at+1)`). Client shows an optimistic list row titled
  `"draft: branch #N"` (literal i18n string, N = sibling count + 1).
- **Server side** (`tui_gateway/server.py:6158-6307`): `session.create` stores
  `parent_session_id` in memory; the DB row is created **lazily on first prompt**
  (`_ensure_session_db_row`, stamps `parent_session_id` + `model_config._branched_from`,
  backfills cwd from parent). Seed transcript is persisted on first submit.
  ⇒ **A branch that never receives a prompt has no DB row and won't appear in the
  session list.** Old agents ignore the unknown `messages`/`parent_session_id` params
  silently (no `-32601` — the method exists), degrading to a plain empty chat.
- **Parent link on the wire**: REST `GET /api/sessions` rows carry `parent_session_id`
  (compact projection includes it). Gateway `session.list` does NOT — mobile's list is
  REST-fed, so we're fine.
- **Desktop nesting** (`apps/desktop/src/lib/session-branch-tree.ts`): pure client-side
  flatten — group children by `parent_session_id` within the rendered slice, siblings
  sorted by recency, a parent group sorts by its freshest member, recursive
  branch-of-branch, elbow stem `'└─ '` (last sibling) / `'├─ '`, children indented and
  non-reorderable. **Orphans** (parent archived/absent from the slice) de-nest to normal
  top-level rows — nothing is hidden.
- **No chat-side branch indicators** on desktop (no "branched from" back-link, no marker
  in the parent transcript) — sidebar nesting is the only expression of the relation.
- **Mobile pieces already in place**: `ChatFeature.copyRow(id:)` +
  `PasteboardClient` (`ChatFeature.swift:908-910`), triggered today from
  `.contextMenu` (`ChatView.swift:152-154`); `ChatRow.copyText` returns raw Markdown for
  message rows; checkmark-feedback pattern exists for code blocks
  (`recentlyCopiedToken` + 1.5s expiry, `ChatFeature.swift:912-924`); profile threading
  convention for `session.create` (omit `profile` for `"default"`); `AppFeature`
  live-chat slot rules (slot replacement must run `teardownSlot`; navigation via
  `openSession`).

Files involved:
- `HermesKit/Sources/HermesKit/Models/Session.swift`, `Clients/HermesRESTClient.swift`
  (SessionListDTO) — decode `parent_session_id`
- `HermesKit/Sources/HermesKit/Models/SessionBranchTree.swift` (new) — pure flatten
- `HermesKit/Sources/HermesKit/Features/SessionListFeature.swift` — sectioned rows with stems
- `HermesKit/Sources/HermesKit/Features/ChatFeature.swift` — copy feedback + branch action
- `HermesKit/Sources/HermesKit/Features/AppFeature.swift` (wherever `openSession` lives) — open-branch routing
- `HermesMobile/Sources/Features/Chat/ChatView.swift` (+ new `MessageActionBar.swift`) — action row UI
- `HermesMobile/Sources/Features/SessionListView.swift` — nested row rendering
- `HermesMobileTests/` — snapshot tests

## Development Approach

- **Testing approach**: Regular (implement, then tests in the same task) — matches the
  repo's existing style; TCA `TestStore` + dependency overrides + `TestClock` per
  project conventions.
- Complete each task fully before moving to the next; small focused changes.
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
  — success and error scenarios, new code paths, updated expectations when behavior
  changes. Tests are a required deliverable, not optional.
- **CRITICAL: all tests must pass before starting the next task** — no exceptions.
- **CRITICAL: update this plan file when scope changes during implementation.**
- Run tests after each change (`script -q /dev/null swift test --package-path HermesKit`
  for live output, or `make test`).
- Maintain backward compatibility: old agents without seed support degrade to a plain
  empty chat (accepted; no capability gate — params are silently ignored, not `-32601`).

## Testing Strategy

- **Unit tests** (HermesKit `swift test`): required for every task — DTO decoding,
  `flattenSessionsWithBranches`, reducer flows (copy feedback, branch guards/success/
  failure, list sectioning with stems).
- **Snapshot tests** (`make snapshot` / `make snapshot-record` in `HermesMobileTests`):
  message action row under an assistant message; session list with a nested branch row
  (elbow + indent). Re-record only for intentional UI changes; timestamps pinned.
- No e2e suite in this project.

## Progress Tracking

- Mark completed items `[x]` immediately when done.
- Add newly discovered tasks with ➕ prefix; blockers with ⚠️ prefix.
- Keep the plan in sync with actual work; commit at each task completion (per repo
  convention), messages: capitalized verb, no conventional-commit prefixes.

## Solution Overview

- **Copy**: a visible `MessageActionBar` under completed assistant rows reuses the
  existing `.copyRow` reducer path; feedback generalizes the `recentlyCopiedToken`
  mechanism so the copy icon swaps to a checkmark for ~1.5s.
- **Branch**: `.branchFromMessage(id:)` in `ChatFeature` — guards (turn not running,
  non-empty text, session exists), then a **one-shot** `session.create` RPC (convention:
  outbound RPCs are discrete one-shot effects) with the single-message seed +
  `parent_session_id` + threaded `profile`. Success emits a delegate
  (`.branchCreated(sessionID:)`) that `AppFeature` routes through the existing
  `openSession` slot-replacement flow (`teardownSlot` → push marker — the nil-out is
  mandatory per slot rules). Failure sets `errorBanner` (never a swallowed `try?`).
  **No confirmation dialog** (desktop parity; non-destructive — worst case the user
  archives the branch).
- **List nesting**: decode `parent_session_id` → pure
  `flattenSessionsWithBranches(_:)` helper in HermesKit mirroring the desktop
  algorithm; applied per rendered lane (pinned / workspace groups / chronological)
  **after** the cron partition. Search and the archived sheet stay flat (matches the
  desktop's "nesting only within the rendered slice" behavior; orphans de-nest).
- **No optimistic list insert** (v1 simplification vs desktop): after branching we
  navigate straight into the new chat; the server has no DB row until the first prompt,
  so the list simply shows the branch (nested) once it exists server-side, via the
  normal refetch/poll. Documented behavior: a branch abandoned before any prompt
  never appears in the list.

## Technical Details

- **Branch RPC params** (mirror the existing `session.create` call byte-for-byte and
  add): `messages: [["role": "assistant", "content": <ChatRow copyText>]]`,
  `parent_session_id: <current stored session id>`; `profile` threaded per convention
  (omitted for `"default"`); do NOT add a `source` param unless the existing create
  already sends one (a novel source id would leak into the desktop sidebar's
  source-grouping).
- **`Session.parentSessionID: String?`** decoded from `parent_session_id` (lenient —
  absent on old agents → `nil`, never fails decode).
- **`SessionBranchEntry`** = `(session: Session, branchStem: String?)`; stems are
  `"└─ "` / `"├─ "`; children sorted by recency; parent-group recency = freshest
  member; recursion for branch-of-branch; cycle-safe (visited set); trailing sweep so
  no session is ever dropped.
- **Row identity/IDs unchanged** — nesting is display-only; pin/archive/rename/swipe
  affordances keep working on branch rows (a pinned branch renders de-nested in the
  Pinned lane because its parent isn't in that slice).
- **Copy feedback state**: reuse/generalize `recentlyCopiedToken: String?` with a
  row-scoped token (e.g. `"row:<id>"`), same 1.5s `continuousClock` expiry +
  `cancelInFlight` so the latest copy owns the feedback.
- **Action-row visibility**: only on `.message(role: .assistant, isComplete: true)`
  rows; hidden while the row is streaming. Buttons are plain small secondary-tinted
  icons (`document.on.document`, `arrow.triangle.branch`), always visible (no hover on
  iOS), respecting the bubble-less assistant layout.

## What Goes Where

- **Implementation Steps** (`[ ]`): all code/test/doc changes in this repo.
- **Post-Completion** (no checkboxes): manual device verification, upstream/desktop
  observations, issue bookkeeping.

## Implementation Steps

### Task 1: Decode parent_session_id onto Session

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Models/Session.swift`
- Modify: `HermesKit/Sources/HermesKit/Clients/HermesRESTClient.swift` (SessionListDTO)
- Modify: `HermesKit/Tests/HermesKitTests/` (session decoding tests)

- [x] add `parentSessionID: String?` to `Session` (public init update; lenient decode)
- [x] map `parent_session_id` in `SessionListDTO` → `Session`
- [x] write tests: payload with `parent_session_id` decodes it; payload without → `nil` (old-agent compat)
- [x] run tests - must pass before task 2

### Task 2: SessionBranchTree flatten helper

**Files:**
- Create: `HermesKit/Sources/HermesKit/Models/SessionBranchTree.swift`
- Create: `HermesKit/Tests/HermesKitTests/SessionBranchTreeTests.swift`

- [x] implement `flattenSessionsWithBranches(_ sessions: [Session]) -> [SessionBranchEntry]` mirroring the desktop algorithm (children grouped by `parentSessionID`, sibling recency sort, group-recency lift, recursive nesting, `└─`/`├─` stems, trailing sweep)
- [x] handle orphans (parent absent from slice → de-nest, no stem) and self/cycle references safely
- [x] write tests: nested ordering, last-vs-middle sibling stems, branch-of-branch, orphan de-nest, cycle safety, empty/flat input passthrough, group recency lift
- [x] run tests - must pass before task 3

### Task 3: SessionListFeature emits stemmed entries per lane

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/SessionListFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/SessionListFeatureTests.swift`

- [x] apply `flattenSessionsWithBranches` inside the computed section state (pinned / workspace groups / chronological), after the cron partition — cron lanes and `unmatchedCronSessions` stay flat
- [x] keep search results flat (existing convention) and leave `ArchivedSessionsFeature` untouched
- [x] write tests: a branch renders nested under its parent in the correct lane; a pinned branch de-nests in the Pinned lane; search stays flat
- [x] run tests - must pass before task 4

### Task 4: SessionListView nested row rendering

**Files:**
- Modify: `HermesMobile/Sources/Features/SessionListView.swift`
- Modify: `HermesMobileTests/` (session list snapshot tests)

- [x] render the stem as a monospaced caption in quaternary/tertiary color + leading indent on stemmed rows (row content, swipe actions, context menu unchanged)
- [x] run `tuist generate` if any new source file was added (no new source file — existing files only, workspace already generated)
- [x] write/update snapshot tests: list with one parent + two branch children (stems `├─`, `└─`); re-record intentionally changed list snapshots (no existing snapshots changed — the stem wrapper is layout-neutral for stem-less rows; only the new baseline was recorded)
- [x] run `make snapshot` + full `swift test` - must pass before task 5

### Task 5: Row-copy checkmark feedback in ChatFeature

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/ChatReductionTests.swift`

- [x] generalize the copy-feedback state so `.copyRow` sets a row-scoped token (e.g. `"row:<id>"`) with the same 1.5s clock expiry + `cancelInFlight` semantics as `.copyCode` (shared `copyWithFeedback` helper; public `ChatFeature.rowCopyToken(_:)` so the view derives the same token)
- [x] write tests: copy sets token + pasteboard receives raw Markdown; token clears after 1.5s via `TestClock`; re-copy restarts the timer; empty-text row is a no-op
- [x] run tests - must pass before task 6

### Task 6: branchFromMessage action + delegate in ChatFeature

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift`
- Create: `HermesKit/Tests/HermesKitTests/ChatBranchTests.swift`

- [x] add `.branchFromMessage(id: ChatRow.ID)`: guard completed assistant row with non-empty text, guard no running turn (mirror desktop's "stop the current turn first" → set `errorBanner` when running), guard a live/stored session id exists
- [x] one-shot `session.create` effect with the single-message seed + `parent_session_id` + threaded `profile` (byte-identical to the existing create otherwise; `[gateway]` captured explicitly)
- [x] on success emit `Delegate.branchCreated(sessionID:)`; on failure set `errorBanner` and clear any in-flight flag (no swallowed `try?`)
- [x] add a double-fire guard (in-flight flag: public `isBranching`) so a second tap is a no-op while the RPC runs
- [x] write tests: success path (RPC params asserted incl. seed + parent + profile-omitted-for-default, delegate emitted), failure → errorBanner, running-turn guard, empty-text guard, double-tap guard (new `ChatBranchTests.swift` — the plan's `ChatFeatureTests.swift` doesn't exist; chat reducer tests are split by topic)
- [x] run tests - must pass before task 7

### Task 7: AppFeature routes branchCreated through the slot flow

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/AppFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/AppFeatureTests.swift`

- [x] handle `.liveChat(.delegate(.branchCreated(sessionID:)))`: open the new session via the existing `openSession`/slot-replacement policy (`teardownSlot` → `.clearLiveChat` → new slot + path marker — never swap slot state directly; routed as `.send(.home(.delegate(.openSession(...))))` — the same flow a list tap uses; note: `AppFeature.swift` lives at `HermesKit/Sources/HermesKit/AppFeature.swift`, not under `Features/`)
- [x] trigger a session-list refetch so the branch shows (nested) once its DB row exists (`.home(.pulledToRefresh)` concatenated after the open)
- [x] write tests: branch from the open slot replaces the slot and sets the path to the single new marker; list reload requested (+ profile threading into the replacement chat, and a no-home defensive no-op)
- [x] run tests - must pass before task 8

### Task 8: MessageActionBar UI in ChatView

**Files:**
- Create: `HermesMobile/Sources/Features/Chat/MessageActionBar.swift`
- Modify: `HermesMobile/Sources/Features/Chat/ChatView.swift`
- Modify: `HermesMobileTests/` (chat snapshot tests)

- [x] build `MessageActionBar` (copy button with checkmark-swap driven by the row token; branch button `arrow.triangle.branch`) — small secondary-tinted icons, leading-aligned under the assistant text, a11y labels
- [x] show it only under completed assistant `.message` rows in `rowView`; keep the existing context-menu copy
- [x] disable/hide branch while the turn is running (disabled + dimmed, also while `isBranching` — mirrors the reducer guard for instant affordance feedback)
- [x] run `tuist generate` (new source file)
- [x] write snapshot tests: completed assistant message with action bar (device); copied state + branch-disabled (component); streaming row without the bar (component `rowView` cell — a full-device streaming capture is flaky: the spinner keeps animations alive while the collection view re-pins, occasionally compositing the cell twice; `rowView` made internal for the test)
- [x] run `make snapshot` + full test suite - must pass before task 9 (assistant-message baselines re-recorded for the new action row; all other baselines byte-identical)

### Task 9: Verify acceptance criteria

- [x] verify all Overview requirements: visible copy with feedback, branch creates seeded session and opens it, session list nests branches with elbow stems, orphans de-nest
- [x] verify edge cases: old-agent degradation (params ignored → empty chat opens, no crash — by design, no capability gate; client-side covered by the malformed-result failure test), running-turn guard, empty-text guard, branch-of-branch rendering
- [x] run full suite: `script -q /dev/null swift test --package-path HermesKit` (760 tests, all pass)
- [x] run `make snapshot` (TEST SUCCEEDED)
- [x] build the app target (`tuist generate` + xcodebuild) to confirm the new view files compile (BUILD SUCCEEDED, exit 0)

### Task 10: [Final] Update documentation

- [x] add the message-action-row + branch conventions to `CLAUDE.md` (branch = desktop-parity `session.create` seed; list nesting is display-only client-side flatten)
- [x] update `README.md` feature list if it enumerates chat features (added a "Branch a reply into a new chat" bullet after the copy bullet)
- [x] issue #34 closed via PR (comment deferred to the PR)
- [x] move this plan to `docs/plans/completed/`

## Review-phase amendments (post-implementation)

The code-review phase reworked the branch-open flow and hardened the nesting:

- **Branch open no longer routes through `openSession`/`session.resume`** — the server
  creates the branch's DB row lazily on the first prompt, so resuming the fresh stored id
  4007s and the not-found self-heal stranded the user in an unrelated empty session.
  `Delegate.branchCreated` now carries the full `SessionHandle`; `AppFeature` fills the
  slot with a chat primed from the create response (`resumeStoredID` +
  `attachLiveSessionID`), and the chat hydrates via `session.activate` by LIVE id (which
  re-binds the new socket's transport and returns the seeded history) until the first
  `message.start`. Mirrors the desktop's "skip the redundant resume" fork flow.
- **Branching requires `storedSessionID`** (`canBranch`) — a live-only parent handle could
  never match a REST list row, so the branch would never nest; the live-id fallback was
  removed (banner instead of silent no-op on a race).
- **`_lineage_root_id` aliasing added** (`Session.lineageRootID` + `byVisibleID` in the
  flatten) so branches keep nesting under a parent whose list row was
  compression-projected forward to its continuation tip (desktop parity).
- **Flatten recency unified with the lanes** (`updatedAt ?? .distantPast`, no `started_at`
  fallback) so nesting never reorders flat rows the lanes already placed.
- **Action-bar hit targets padded** (8pt + `contentShape`) and reducer/view guards aligned.

Iteration 2 (orphan-reap resilience):

- **Unpersisted branches can't be branched again** — `canBranch` (and the reducer guard)
  now also requires `attachLiveSessionID == nil`: the branch's `session_key` has no DB
  row, so a grandchild's `parent_session_id` would dangle forever once the slot
  replacement lets the server reap the never-prompted middle branch.
- **The client-held seed survives the server's ~20s orphan reap** — `branchCreated`
  carries a `BranchSeed` (text + parent id) that `AppFeature` copies onto the primed
  chat; a "session not found" while unattached replays the SEEDED `session.create`
  (hydrate path: `branchReplayResult` → re-attach; submit path: the heal recreates with
  the seed and keeps attach-by-live-id mode), rebuilding context + nesting. One replay
  per hydrate (`hasReplayedBranchSeed`); a failed replay or `-32601` degrades to a fresh
  create with an honest "Couldn’t restore the branch" banner — never the old silent swap
  under the still-painted seed.
- **An interrupted replay can't bypass the recovery guards** (iteration 3) — recovery
  keys on the DURABLE `branchSeed`, not the transient `attachLiveSessionID` the replay
  trigger consumes before its create resolves: the hydrate not-found gate, the degrade
  banner/seed-clear, and the `.ready` bare-create fallback all check the seed, so a
  socket drop mid-replay still recovers the branch on the next hydrate (never a silent
  bare create, never a dangling seed that could mis-arm attach mode via
  `liveSessionIDRefreshed`). A transport-shaped `branchReplayResult` failure
  (`.disconnected`/`.notConnected`/`.timedOut`) KEEPS the seed and refunds the replay
  budget (status-only, mirroring `.sessionResult(.failure(.disconnected))`; timeout
  redials itself against a half-open socket) instead of destroying the only copy of the
  branch and firing a `createSession` into a dead socket; the seed-dropping banner
  degrade is reserved for genuine server rejections.

Iteration 6 (external codex review, 4 findings — 3 confirmed, 1 false positive):

- **CONFIRMED (most important) — a hydrate not-found could discard a persisted branch's
  real history.** The server persists a branch's DB row in `prompt.submit`
  (`_ensure_session_db_row`/`_persist_branch_seed`) BEFORE `message.start` reaches the
  client, under the SAME id as the live `session_key`. A socket drop/server restart
  landing in that window left `attachLiveSessionID`/`branchSeed` still standing even
  though a durable first turn already existed server-side; the not-found handler took
  this as proof the branch was never prompted and replayed the bare seed, silently
  creating an unrelated sibling and losing the real follow-up turn. Fix: a one-shot
  probe (`hasProbedBranchResume`, budgeted like the replay) tries `session.resume` by
  the SAME id FIRST — `session.activate` is live-only (no DB fallback) so it 404s
  regardless of a persisted row, but `session.resume` DOES fall back to the DB. A probe
  success is treated exactly like `message.start` (clears the unpersisted-branch
  bookkeeping, hydrates wholesale); only a not-found from the probe ITSELF proves the
  branch is truly unpersisted and falls through to the existing seed-replay/degrade
  logic, extracted into `handleActivateFailure(_:into:)` so both the plain not-found
  path and the post-probe path share it verbatim.
- **CONFIRMED — `canBranch`/the reducer guard didn't require a connected socket.**
  `.gatewayClosed` finalizes a mid-stream row as `isComplete` and clears `isSending` the
  instant the socket drops, so a truncated reply looked branchable while
  `.reconnecting` (and the RPC would just fail against the dead socket instead of being
  blocked up front). Fix: added `status == .ready` to `canBranch` and the
  `.branchFromMessage` guard (same "This chat can't be branched yet." banner).
- **CONFIRMED — `canSend` allowed a new parent turn while a branch `session.create` was
  in flight.** `AppFeature` tears down the WHOLE slot on `branchCreated` to open the
  replacement chat; a turn submitted during that window would be silently lost
  (cancelled effects, no server response ever observed). Fix: added `!isBranching` to
  `canSend`.
- **FALSE POSITIVE — branch omitting `cwd`.** Verified: the mobile client's PLAIN
  (non-branch) `session.create` also sends no `cwd` at all (`fields: [:]` in
  `createSession(profile:)`) — mobile is a thin remote client with no workspace state to
  send in the first place, so the branch omitting it is consistent, not a regression.
  No code change.

## Post-Completion

**Manual verification:**
- On-device: branch from an assistant message against a live agent; confirm the new
  chat opens seeded with that message, the server auto-title lands after the first
  prompt, and the session list shows the nested row on next refresh.
- Verify against an older agent build (no seed support): branch yields an empty new
  chat, no error, no crash.
- VoiceOver pass on the action bar.

**External observations (no action in this repo):**
- Desktop shows an optimistic `"draft: branch #N"` row immediately; mobile v1
  deliberately skips optimistic insert — a branch abandoned before any prompt never
  materializes server-side. If that feels off in practice, a follow-up issue can add
  the optimistic row.
- A "branched from …" back-link inside the chat does not exist on desktop either; if
  wanted, it needs `parent_session_id` surfaced on `session.resume` info — upstream ask.
