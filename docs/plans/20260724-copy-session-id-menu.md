# Copy Session ID menu item

## Overview
- Add a "Copy ID" menu item that puts the session's id on the pasteboard, on three
  surfaces: the sessions-list row context menu, the Archived-sessions sheet row context
  menu, and the chat screen's toolbar ellipsis menu.
- Solves: no way today to grab a session id from the app (useful for debugging,
  cross-referencing with the agent's CLI/logs, cron job ids, etc.).
- On copy, a small transient toast ("Session ID copied") confirms the action, then
  auto-dismisses.

## Context (from discovery)
- Files/components involved:
  - `HermesKit/Sources/HermesKit/Features/SessionListFeature.swift` (+ tests)
  - `HermesKit/Sources/HermesKit/Features/ArchivedSessionsFeature.swift` (+ tests)
  - `HermesKit/Sources/HermesKit/Features/ChatFeature.swift` (+ tests)
  - `HermesMobile/Sources/Features/SessionListView.swift` (row `.contextMenu`, line ~488)
  - `HermesMobile/Sources/Features/ArchivedSessionsView.swift` (row `.contextMenu`, line ~30)
  - `HermesMobile/Sources/Features/Chat/ChatView.swift` (toolbar `Menu`, line ~46)
- Related patterns found:
  - `PasteboardClient` already exists (`@DependencyClient`-style struct, live + test
    values) and is already used by `ChatFeature` (`copyRow`/`copyCode` at
    `ChatFeature.swift:908`) — copy goes view → action → reducer → `pasteboard.copy`.
  - Timed feedback pattern exists: `copyCode` starts a cancellable `continuousClock`
    sleep (`CancelID.copyFeedback`, `cancelInFlight: true`) that sends an expiry action.
  - No existing toast/snackbar component — a small shared view is needed.
- Dependencies identified: `PasteboardClient`, `continuousClock` (TestClock-drivable),
  TCA `TestStore`.
- ID semantics: list/archived rows copy `session.id`; chat copies
  `state.sessionKey` (`storedSessionID ?? liveSessionID`, `ChatFeature.swift:126`) —
  menu item disabled while `sessionKey == nil` (mirrors `canRename` gating).

## Development Approach
- **testing approach**: Regular (code first, then tests)
- complete each task fully before moving to the next
- make small, focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
  - tests are not optional - they are a required part of the checklist
  - TestStore tests for every new action; success + no-op/edge cases
- **CRITICAL: all tests must pass before starting next task** - no exceptions
- **CRITICAL: update this plan file when scope changes during implementation**
- run tests after each change
- maintain backward compatibility

## Testing Strategy
- **unit tests** (HermesKit, `swift test` via
  `script -q /dev/null swift test --package-path HermesKit` or `make test`):
  - per feature: copy action puts the right id on the pasteboard (override
    `\.pasteboard` with a `LockIsolated` capture), shows the toast, and a `TestClock`
    advance auto-dismisses it; re-copy while visible restarts the timer
    (`cancelInFlight`); chat copy with `sessionKey == nil` is a no-op.
- **snapshot tests** (`make snapshot` / `make snapshot-record` in `HermesMobileTests`):
  - one snapshot of the sessions list with the copied toast visible (covers the new
    `CopiedToastView` rendering).
- no e2e suite in this project.

## Progress Tracking
- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- update plan if implementation deviates from original scope
- keep plan in sync with actual work done

## Solution Overview
- Follow the established client pattern: views stay thin, each feature reducer gets a
  copy action that calls `pasteboard.copy(...)` and flips a `showsCopiedIDToast: Bool`,
  plus a timed expiry effect (cancellable `continuousClock.sleep(for: .seconds(1.5))`
  → expiry action, `cancelInFlight: true` so rapid re-copies restart the timer).
- One small shared SwiftUI view in the app target, `CopiedToastView` (capsule,
  "Session ID copied", material background, bottom-aligned overlay with a fade/move
  transition that respects reduce-motion), driven purely by the store bool on each of
  the three screens.
- Toast state is per-feature (three independent bools) — no shared toast feature; the
  duplication is tiny and keeps the features decoupled (prefer duplication over
  premature abstraction).

## Technical Details
- New reducer surface (same shape in all three features):
  - State: `var showsCopiedIDToast = false`
  - Actions: `.copyIDButtonTapped(id: String)` (chat: `.copySessionIDTapped`, no
    payload — reads `state.sessionKey`), `.copiedIDToastExpired`
  - CancelID: `.copyIDToast` (chat: new case in the existing `CancelID` enum —
    distinct from the code-block `copyFeedback`)
  - Reduction: set `showsCopiedIDToast = true`, `.run` → `pasteboard.copy(id)` +
    clock sleep 1.5s → send expiry; expiry sets the bool back to `false` (animated).
- Views: add `Button("Copy ID", systemImage: "doc.on.doc") { ... }` to
  - `SessionListView.row(_:)` `.contextMenu` (context menu only — no swipe action),
  - `ArchivedSessionsView` row `.contextMenu` (next to Restore),
  - `ChatView` toolbar `Menu` (below Rename, `.disabled(store.sessionKey == nil)`);
  and a `.overlay(alignment: .bottom)` `CopiedToastView` gated on the store bool on
  each screen (in chat, keep it above the composer inset).
- `SessionListFeature.State` / `ArchivedSessionsFeature.State` are public — ensure the
  new state has a sensible default so existing inits/tests don't break.

## What Goes Where
- **Implementation Steps** (`[ ]` checkboxes): tasks achievable within this codebase - code changes, tests, documentation updates
- **Post-Completion** (no checkboxes): items requiring external action - manual testing, changes in consuming projects, deployment configs, third-party verifications

## Implementation Steps

### Task 1: SessionListFeature — Copy ID action + toast state

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/SessionListFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/SessionListFeatureTests.swift`

- [ ] add `showsCopiedIDToast` state, `.copyIDButtonTapped(id:)` / `.copiedIDToastExpired` actions, `CancelID.copyIDToast`
- [ ] reduce: `pasteboard.copy(id)` + 1.5s `continuousClock` sleep → expiry (cancelInFlight), expiry clears the bool
- [ ] write TestStore test: tap → pasteboard captured id + toast shown; TestClock advance → toast hidden
- [ ] write TestStore test: second copy while toast visible restarts the timer (no early dismiss)
- [ ] run tests - must pass before task 2

### Task 2: ArchivedSessionsFeature — Copy ID action + toast state

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/ArchivedSessionsFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/ArchivedSessionsFeatureTests.swift`

- [ ] mirror Task 1's state/actions/effect in `ArchivedSessionsFeature`
- [ ] write TestStore test: copy → pasteboard capture + toast, clock advance → dismiss
- [ ] run tests - must pass before task 3

### Task 3: ChatFeature — Copy session ID action

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/ChatInteractionTests.swift`

- [ ] add `showsCopiedIDToast` state, `.copySessionIDTapped` / `.copiedIDToastExpired` actions, `CancelID.copyIDToast`
- [ ] reduce: copy `state.sessionKey` (guard non-nil → no-op otherwise) + timed dismiss as in Task 1
- [ ] write TestStore test: with `storedSessionID` set → copies it, toast shows/auto-hides
- [ ] write TestStore test: `sessionKey == nil` → no state change, no effect
- [ ] run tests - must pass before task 4

### Task 4: Views — CopiedToastView + menu items on all three screens

**Files:**
- Create: `HermesMobile/Sources/Features/CopiedToastView.swift`
- Modify: `HermesMobile/Sources/Features/SessionListView.swift`
- Modify: `HermesMobile/Sources/Features/ArchivedSessionsView.swift`
- Modify: `HermesMobile/Sources/Features/Chat/ChatView.swift`
- Modify: `HermesMobileTests/SessionSnapshotTests.swift`

- [ ] create `CopiedToastView` (capsule + material, "Session ID copied", reduce-motion-aware transition)
- [ ] add "Copy ID" to the session-list row `.contextMenu` + bottom-overlay toast gated on `store.showsCopiedIDToast`
- [ ] add "Copy ID" to the archived-sessions row `.contextMenu` + toast overlay
- [ ] add "Copy ID" to the chat toolbar `Menu` (`.disabled(store.sessionKey == nil)`) + toast overlay above the composer
- [ ] run `tuist generate` so the new source file is picked up
- [ ] add snapshot test: sessions list with toast visible; `make snapshot-record` then `make snapshot`
- [ ] run full snapshot suite - must pass before task 5

### Task 5: Verify acceptance criteria
- [ ] verify all three menus offer "Copy ID" and copy the correct id
- [ ] verify edge cases: chat with no session yet (disabled item), rapid re-copy restarts toast
- [ ] run full test suite: `script -q /dev/null swift test --package-path HermesKit`
- [ ] run snapshot tests: `make snapshot`

### Task 6: [Final] Update documentation
- [ ] update CLAUDE.md only if a new reusable pattern emerged (toast) — one line at most
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion
*Items requiring manual intervention or external systems - no checkboxes, informational only*

**Manual verification**:
- on device/simulator: long-press a session row → Copy ID → toast appears and the
  pasteboard holds the id; same from the Archived sheet and the chat ellipsis menu;
  VoiceOver announces the menu items sensibly.
