# Cold-launch push-tap replay (issue #46)

## Overview
- Tapping a push for a session the phone hasn't seen (new cron run, desktop-started chat)
  when the tap **launches the app** lands on the sessions list — the chat never opens.
- The "unknown session" case already works warm (placeholder `Session(id:)` +
  `session.resume`); the bug is that on cold launch the tap is **dropped before routing**
  in two independent places and never replayed:
  1. `AppFeature.pushTapped` bails badge-only when `state.home == nil`
     (`AppFeature.swift:265-269`); `.autoConnectSucceeded` sets `home` later but doesn't
     re-process the dropped tap.
  2. `PushBridge.tapStream()` doesn't buffer for late subscribers
     (`PushClient.swift:304-308`) — on a true launch-from-push the app delegate's
     `tapReceived` can fire before the reducer's `.task` subscribes, so with zero
     continuations the tap is silently discarded. `tokenStream()` already caches
     `lastToken` for exactly this reason.
- Fix both holes: buffer the last undelivered tap in `PushBridge` (consume-once), and
  stash a pre-`home` tap in `AppFeature.State` for replay once `home` exists.
- No REST single-session fetch needed — the existing placeholder + `session.resume` path
  hydrates title/history once the tap reaches `openSession`.
- Closes goncharik/hermes-mobile#46.

## Context (from discovery)
- Files/components involved:
  - `HermesKit/Sources/HermesKit/Clients/PushClient.swift` — `PushBridge`
    (`tapStream`/`tapReceived`, lines 304-325) currently inside `#if canImport(UIKit)`.
  - `HermesKit/Sources/HermesKit/AppFeature.swift` — `.pushTapped` guard (265-269),
    `.autoConnectSucceeded` (177-180), `.onboarding(.delegate(.connected))` (300-302),
    tap observer in `.task` (145-150).
  - `HermesKit/Tests/HermesKitTests/AppFeatureTests.swift` — existing `pushTapped`
    TestStore coverage to extend.
  - `HermesKit/Tests/HermesKitTests/PushClientTests.swift` — existing pure push tests.
- Related patterns found:
  - `tokenStream()` late-subscriber replay (`PushClient.swift:293-302`) is the exact
    mirror for the tap-side fix — but a tap must be **consume-once** (re-yielding a stale
    tap to a later re-subscriber would re-navigate), unlike the token which is idempotent.
  - Pure payload helpers (`hexToken`, `tap(fromPayload:)`, `sessionID(fromPayload:)`,
    `shouldPresentForeground`) already live OUTSIDE the UIKit guard — `PushBridge` itself
    uses only Foundation (`NSLock`, `AsyncStream`) + those helpers, so it can move outside
    the guard too, making the new buffering logic unit-testable on macOS (`swift test`).
- Dependencies identified: none new — TCA `TestStore`, existing `PushClient` test doubles.

## Development Approach
- **Testing approach**: TDD (tests first) — per task, write the failing test, then the
  implementation, then verify green.
- Complete each task fully before moving to the next.
- Make small, focused changes.
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
  - tests are not optional — they are a required part of the checklist
  - tests cover both success and error scenarios
- **CRITICAL: all tests must pass before starting next task** — no exceptions.
- **CRITICAL: update this plan file when scope changes during implementation.**
- Run tests after each change (`script -q /dev/null swift test --package-path HermesKit`).
- Maintain backward compatibility (badge bookkeeping for undeliverable taps unchanged).

## Testing Strategy
- **Unit tests**: required for every task. `PushBridge` buffering → direct unit tests
  (possible once it's outside the UIKit guard); reducer replay → `TestStore`
  event-reduction tests in `AppFeatureTests.swift`.
- **Snapshot tests**: not applicable — no view changes.
- **e2e**: none in this project; manual cold-launch verification listed under
  Post-Completion.

## Progress Tracking
- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- update plan if implementation deviates from original scope

## Solution Overview
- **`PushBridge` tap buffering (consume-once)**: `tapReceived` with zero subscribed
  continuations caches the tap in `pendingTap`; the first `tapStream()` subscriber
  drains it (yield + clear under the lock — mirror `tokenStream()`'s shape but clear
  after delivery). A tap delivered to at least one live continuation is NOT cached —
  buffering exists only for the launch race, not for replay to re-subscribers.
- **Reducer stash-and-replay**: `pushTapped` with `state.home == nil` keeps today's badge
  bookkeeping but also stores the tap in `state.pendingPushTap`. Both places that create
  `home` — `.autoConnectSucceeded` and `.onboarding(.delegate(.connected))` (auto-connect
  failure falls back to onboarding, so a manual login must also replay) — consume the
  stash by re-sending `.pushTapped(tap)` through the normal routing (slot compare, #32
  dedup, approval hint arming all reuse the one code path). Replaying re-runs the
  `isApproval` badge insert — idempotent (`Set` insert + the open clears it, netting zero
  exactly as a warm tap does).
- **Why replay via `.pushTapped` and not `.openSession` directly**: the full routing case
  already handles approval-hint arming, slot/path dedup, and the placeholder-session
  fallback; duplicating any of it would drift.

## Technical Details
- `PushBridge` (moved outside `#if canImport(UIKit)`, stays in `PushClient.swift`):
  - `private var pendingTap: PushTap?`
  - `tapReceived`: `lock.withLock` — if `tapContinuations.isEmpty`, set `pendingTap`;
    else yield to all continuations (and leave `pendingTap` nil).
  - `tapStream()`: under the lock, append the continuation and take-and-clear
    `pendingTap`; yield the drained tap after releasing the lock (same shape as
    `tokenStream()`).
  - The UIKit-only `liveValue` extension keeps referencing `PushBridge.shared` unchanged.
- `AppFeature.State`: `var pendingPushTap: PushTap?` (not persisted — process-lifetime
  only, the race it covers is intra-launch).
- `AppFeature` reducer:
  - `.pushTapped` `home == nil` branch: `state.pendingPushTap = tap` before the existing
    `setBadge(state)` return.
  - `.autoConnectSucceeded` / `.onboarding(.delegate(.connected))`: after setting
    `state.home`, if `let tap = state.pendingPushTap` → clear it and
    `return .send(.pushTapped(tap))` (merged with any existing effect).
- `PushTap` already `Equatable`/`Sendable` as used by the stream — no model changes.

## What Goes Where
- **Implementation Steps** (`[ ]` checkboxes): code + tests in this repo.
- **Post-Completion** (no checkboxes): manual on-device cold-launch verification.

## Implementation Steps

### Task 1: Move PushBridge outside the UIKit guard

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Clients/PushClient.swift`

- [x] move the `PushBridge` class above the `#if canImport(UIKit)` block; keep the
      `liveValue` extension and app-delegate-facing UIKit code inside the guard
- [x] verify `PushBridge` compiles on macOS: only Foundation + pure `PushClient` helpers
      (`hexToken`, `tap(fromPayload:)`, `sessionID(fromPayload:)`,
      `shouldPresentForeground`) — no UIKit/UserNotifications symbols
- [x] write a smoke unit test in `PushClientTests.swift`: `tokenStream()` late-subscriber
      replay via `PushBridge` (locks in existing behavior now that it's testable)
- [x] run tests — must pass before task 2

### Task 2: Buffer the last undelivered tap in PushBridge (TDD)

**Files:**
- Modify: `HermesKit/Tests/HermesKitTests/PushClientTests.swift`
- Modify: `HermesKit/Sources/HermesKit/Clients/PushClient.swift`

- [ ] write failing test: `tapReceived` before any subscriber → first `tapStream()`
      subscriber receives the buffered tap
- [ ] write failing test: buffered tap is consume-once — a second, later `tapStream()`
      subscriber does NOT receive it again
- [ ] write failing test: a tap delivered to a live subscriber is not buffered — a
      subsequent new subscriber receives nothing
- [ ] write test (existing behavior guard): tap with live subscribers reaches all of them
- [ ] implement `pendingTap` cache in `tapReceived` + drain in `tapStream()` per
      Technical Details
- [ ] run tests — must pass before task 3

### Task 3: Stash and replay the pre-home tap in AppFeature (TDD)

**Files:**
- Modify: `HermesKit/Tests/HermesKitTests/AppFeatureTests.swift`
- Modify: `HermesKit/Sources/HermesKit/AppFeature.swift`

- [ ] write failing TestStore test: cold-launch order — `.pushTapped(tap)` with
      `home == nil` stashes the tap (badge bookkeeping unchanged), then
      `.autoConnectSucceeded` clears the stash and replays into
      `.home(.delegate(.openSession))` with the placeholder `Session(id:)`
- [ ] write failing TestStore test: same replay through
      `.onboarding(.delegate(.connected))` (auto-connect-failed → manual login path)
- [ ] write failing TestStore test: approval tap pre-home — badge set on the drop,
      replay arms `expectsPendingApproval` through the normal open flow and nets the
      badge entry to zero
- [ ] write test (existing behavior guard): warm-path `.pushTapped` with `home` present
      never touches `pendingPushTap`; `.autoConnectSucceeded` without a stash emits no
      replay
- [ ] add `pendingPushTap` to `AppFeature.State`; stash in the `home == nil` branch;
      consume + re-send `.pushTapped` from `.autoConnectSucceeded` and
      `.onboarding(.delegate(.connected))`
- [ ] run tests — must pass before task 4

### Task 4: Verify acceptance criteria

- [ ] verify both drop sites from issue #46 are closed (bridge buffer + reducer replay)
- [ ] verify edge cases: tap for the session already in the slot after replay (slot-match
      short-circuit still applies — replay goes through the same `.pushTapped` case);
      non-approval tap replay; approval badge netting
- [ ] run full test suite: `script -q /dev/null swift test --package-path HermesKit`
- [ ] confirm no view changes → snapshot suite untouched, no re-record needed

### Task 5: [Final] Update documentation

- [ ] update `CLAUDE.md` push-notifications bullet: note the cold-launch tap replay
      (bridge consume-once buffer + `pendingPushTap` reducer stash)
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion
*Items requiring manual intervention or external systems — no checkboxes, informational only*

**Manual verification:**
- On-device: force-quit the app, trigger a push for a session the phone has never loaded
  (e.g. a cron run), tap the notification → app cold-launches directly into that chat
  with hydrated history.
- Same flow while logged out / expired creds: tap should land on onboarding, and
  completing login should then open the pushed session.

**External system updates:**
- None — no push-payload changes (generic-body privacy rule untouched), no plugin or
  gateway changes.
