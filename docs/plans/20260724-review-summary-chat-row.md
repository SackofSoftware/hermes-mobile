# Show self-improvement review summaries (review.summary) in the chat

GitHub issue: #47

## Overview

- The agent's background self-improvement review broadcasts a **live-only** gateway event
  `{"type": "review.summary", "session_id": "...", "payload": {"text": "💾 Self-improvement review: …"}}`
  (emitted by `agent/background_review.py`, broadcast by `tui_gateway/server.py`). The desktop
  TUI renders it as a system line; Telegram persists it as an ordinary message. Mobile silently
  drops it: `GatewayEvent` has no case for it, so it decodes to `.unknown` and the reducer no-ops.
- Fix (mobile side, per issue #47): decode the event and render it as a lightweight, bubble-less
  system row while the app is live-streaming.
- **Accepted limitation**: the event is never written to session history, so `session.resume`
  cannot return it — a hydrate (open/foreground) wholesale-replaces the transcript and the row
  disappears. Durable visibility needs a hermes-agent change (persist into history), tracked as
  a separate upstream issue (see Post-Completion).

## Context (from discovery)

- `HermesKit/Sources/HermesKit/Models/GatewayEvent.swift:87-88` — unknown `type` falls to
  `.unknown`; `review.summary` needs an explicit case decoding payload `{"text": String}`.
- `HermesKit/Sources/HermesKit/Features/ChatFeature.swift:1398` — `.unknown` no-ops; the new
  event needs a handler appending a transcript row.
- `ChatRow.Kind.status(kind:text:)` already exists (`ChatRow.swift:50`) — bubble-less system
  line, `Codable` (snapshot-cache round-trip works), stable `"status"` discriminator. Already
  used for optimistic system rows ("Approved", "Already handled elsewhere", clarify/secret
  answers) appended with `uuid()` ids (`ChatFeature.swift:820,855,874,893`) — the same live-row
  id convention tool rows use.
- `ChatView.swift:189-190` renders `.status` rows as `.caption` secondary text.
- `shouldPersistSnapshot` (`ChatFeature.swift:~1876`) lists events that trigger a snapshot
  refresh — the new event must join it (it appends a transcript row).
- `reconstructTranscript` (`TranscriptReconstruction.swift:74-77`) skips non-`user/assistant/tool`
  roles — fine, the event isn't in history; `.status` stays compatible if it ever lands there.

## Development Approach

- **Testing approach**: Regular (code first, then tests) — project convention (TestStore
  reducer tests are the highest-value suite).
- **Decision (agreed)**: reuse `.status(kind: "review", text:)` — no new `ChatRow.Kind` case,
  no new discriminator, no snapshot-cache schema change. Small view tweak only: review-kind
  status rows render at `.footnote` with text selection so longer summaries stay readable.
- Complete each task fully before moving to the next; small, focused changes.
- **CRITICAL: every task MUST include new/updated tests** (success + error/edge cases); tests
  are a required deliverable, not optional.
- **CRITICAL: all tests must pass before starting the next task.**
- **CRITICAL: update this plan file when scope changes during implementation.**
- Maintain backward compatibility (unknown events must keep decoding to `.unknown`).

## Testing Strategy

- **Unit tests** (HermesKit, `swift test`): decoding tests in `GatewayEventDecodingTests`,
  reducer fold tests in `ChatReductionTests` (TestStore + dependency overrides).
- **Snapshot tests** (`HermesMobileTests`, `make snapshot`): extend the chat snapshot with a
  review status row — catches the view styling that reducer tests can't. `make snapshot-record`
  to record, then `make snapshot` to assert.
- No e2e suite in this project.

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- keep plan in sync with actual work done

## Solution Overview

1. `GatewayEvent` gets a `.reviewSummary(text: String)` case decoded from `review.summary`
   (payload `{"text": String}`, lenient: missing text → `""`).
2. `ChatFeature` folds it into an appended `ChatRow(kind: .status(kind: "review", text:))`
   with a `uuid()` id (live-row convention; the row is ephemeral by design — server wins on
   hydrate). Empty text is dropped (no empty caption row). `keepThinkingLast` keeps the live
   thinking indicator last if a summary arrives mid-turn. The event triggers a snapshot persist.
3. `ChatView` renders `.status(kind: "review")` at `.footnote` + `.textSelection(.enabled)`;
   other status kinds keep today's `.caption` styling.

## Technical Details

- Wire shape (verified in issue #47 against `tui_gateway/server.py`):
  `{"type": "review.summary", "session_id": "<sid>", "payload": {"text": "💾 Self-improvement review: ..."}}`
  — `session_id` on the frame (standard), text already carries the `💾` prefix; render verbatim,
  no client-side prefixing.
- Row id: `uuid()` (not `ChatRow.deterministicID`) — deterministic IDs are assigned by
  `reconstructTranscript` for history rows; this event never appears in history, and live-row
  `uuid()` matches every other reducer-appended system row.
- Snapshot cache: `.status` is already `Codable`, so the row round-trips into
  `ChatSnapshotClient` for instant paint; the cache is non-authoritative, so the next hydrate
  replaces it wholesale — consistent with the accepted limitation.
- No unread/badge/session-list involvement; no push trigger; no capability gating (an old agent
  simply never sends the event).

## What Goes Where

- **Implementation Steps** (`[ ]` checkboxes): code changes, tests, documentation updates in
  this repo.
- **Post-Completion** (no checkboxes): manual live verification, upstream hermes-agent issue.

## Implementation Steps

### Task 1: Decode `review.summary` in GatewayEvent

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Models/GatewayEvent.swift`
- Modify: `HermesKit/Tests/HermesKitTests/GatewayEventDecodingTests.swift`

- [x] add `case reviewSummary(text: String)` to `GatewayEvent`
- [x] decode `"review.summary"` in `init(type:payload:)` → `.reviewSummary(text: p["text"]?.stringValue ?? "")`
- [x] write test: full frame with `session_id` + payload text decodes to `.reviewSummary` (text verbatim, 💾 prefix intact)
- [x] write tests: missing/absent `text` → empty string; unrelated unknown types still decode to `.unknown` (existing `unknownEventTypeDecodesToUnknownAndNeverThrows` still passes)
- [x] run `swift test --package-path HermesKit` — must pass before task 2 (723 tests pass)
- [x] ➕ handle the new case in `GatewayLogEntry` (`eventType` → `"review.summary"`, `debugSummary` → truncated text) — exhaustive switches
- [x] ➕ add compile-only stubs in `ChatFeature` (`.reviewSummary` → `.none`; `persistRelevant` → `false`) — replaced with the real fold in Task 2

### Task 2: Fold `.reviewSummary` into a `.status` transcript row in ChatFeature

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/ChatReductionTests.swift`

- [ ] handle `.reviewSummary` in the gateway-event reduce: guard non-empty text, append `ChatRow(id: uuid(), kind: .status(kind: "review", text: text))`, then `keepThinkingLast(into: &state)`
- [ ] add `.reviewSummary` to the snapshot-persist event list (`shouldPersistSnapshot`, ~line 1876)
- [ ] write test: event appends the status row with verbatim text
- [ ] write test: empty-text event is a no-op (no row appended)
- [ ] write test: event during a running turn keeps the thinking row last
- [ ] write test: event triggers a snapshot persist (matches the existing persist-trigger test pattern)
- [ ] run `swift test --package-path HermesKit` — must pass before task 3

### Task 3: Render review status rows readably in ChatView

**Files:**
- Modify: `HermesMobile/Sources/Features/Chat/ChatView.swift`
- Modify: `HermesMobileTests/ChatSnapshotTests.swift`

- [ ] in `rowView`, render `.status(kind: "review", …)` at `.footnote` + `.textSelection(.enabled)`; other status kinds keep `.caption` secondary styling
- [ ] add/extend a chat snapshot fixture with a review status row (multi-sentence text to prove readability)
- [ ] `make snapshot-record` to record the new/changed reference images
- [ ] run `make snapshot` — must pass before task 4

### Task 4: Verify acceptance criteria

- [ ] verify issue #47 fix scope: event decoded, rendered live, no crash on old/unknown events
- [ ] verify edge cases: empty text dropped, mid-turn arrival, snapshot-cache round-trip
- [ ] run full package suite: `script -q /dev/null swift test --package-path HermesKit` (or `make test`)
- [ ] run snapshot suite: `make snapshot`

### Task 5: [Final] Update documentation

- [ ] add a brief `review.summary` note to the CLAUDE.md conventions (live-only event → `.status(kind: "review")` row; never in history)
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion

**Manual verification:**
- With the app foregrounded and connected, run a session on a self-improvement-review-enabled
  agent and confirm the `💾 Self-improvement review: …` line appears after the turn (compare
  against the desktop TUI on the same session).
- Confirm the row disappears after backgrounding/foregrounding (hydrate replaces wholesale) —
  expected, not a bug, until the upstream change lands.

**External system updates:**
- File an upstream hermes-agent issue (like #30) to persist `review.summary` into session
  history so `session.resume` returns it — that's what makes summaries durable/recoverable on
  mobile. Once it lands, extend `reconstructTranscript` to map the persisted entry to the same
  `.status(kind: "review")` row.
