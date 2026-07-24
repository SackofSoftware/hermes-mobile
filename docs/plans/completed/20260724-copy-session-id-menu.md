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
    (`cancelInFlight`) and bumps the token; chat copy with `sessionKey == nil` is a no-op.
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
  copy action that calls `pasteboard.copy(...)` and bumps a `copiedIDToastToken: Int?`,
  plus a timed expiry effect (cancellable `continuousClock.sleep(for: .seconds(1.5))`
  → expiry action, `cancelInFlight: true` so rapid re-copies restart the timer).
- One small shared SwiftUI view in the app target, `CopiedToastView` (capsule,
  "Session ID copied", material background, bottom-aligned overlay with a fade/move
  transition that respects reduce-motion), driven purely by the store token on each of
  the three screens.
- Toast state is per-feature (three independent tokens) — no shared toast feature; the
  duplication is tiny and keeps the features decoupled (prefer duplication over
  premature abstraction).

## Technical Details
- New reducer surface (same shape in all three features):
  - State: `var copiedIDToastToken: Int? = nil`
  - Actions: `.copyIDButtonTapped(id: String)` (chat: `.copySessionIDTapped`, no
    payload — reads `state.sessionKey`), `.copiedIDToastExpired`
  - CancelID: `.copyIDToast` (chat: new case in the existing `CancelID` enum —
    distinct from the code-block `copyFeedback`)
  - Reduction: `copiedIDToastToken = (copiedIDToastToken ?? 0) + 1`, `.run` →
    `pasteboard.copy(id)` + clock sleep 1.5s → send expiry; expiry sets it back to `nil`
    (animated).
- Views: add `Button("Copy ID", systemImage: "doc.on.doc") { ... }` to
  - `SessionListView.row(_:)` `.contextMenu` (context menu only — no swipe action),
  - `ArchivedSessionsView` row `.contextMenu` (next to Restore),
  - `ChatView` toolbar `Menu` (below Rename, `.disabled(store.sessionKey == nil)`);
  and a `.overlay(alignment: .bottom)` `CopiedToastView` gated on the store token on
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

- [x] add `copiedIDToastToken` state, `.copyIDButtonTapped(id:)` / `.copiedIDToastExpired` actions, `CancelID.copyIDToast`
- [x] reduce: `pasteboard.copy(id)` + 1.5s `continuousClock` sleep → expiry (cancelInFlight), expiry clears the token
- [x] write TestStore test: tap → pasteboard captured id + toast shown; TestClock advance → toast hidden
- [x] write TestStore test: second copy while toast visible restarts the timer (no early dismiss)
- [x] run tests - must pass before task 2

> [decision] The dwell duration lives in `SessionListFeature.copiedFeedbackDuration`
> (`static let`, internal) rather than an inline literal — Tasks 2/3 mirror the value under
> the same name (review round 2 unified the naming; it was `copiedToastDuration` here at
> first while `ChatFeature` called it `copiedFeedbackDuration`).
> [decision] Toast dismissal is NOT animated in the reducer (no `withAnimation`); the
> animation stays a view concern in Task 4, matching how `copyFeedbackExpired` works in
> `ChatFeature`.

### Task 2: ArchivedSessionsFeature — Copy ID action + toast state

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/ArchivedSessionsFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/ArchivedSessionsFeatureTests.swift`

- [x] mirror Task 1's state/actions/effect in `ArchivedSessionsFeature`
- [x] write TestStore test: copy → pasteboard capture + toast, clock advance → dismiss
- [x] run tests - must pass before task 3

> [decision] `copiedFeedbackDuration` is duplicated as a local `static let` on
> `ArchivedSessionsFeature` rather than referencing `SessionListFeature`'s — the plan's
> "toast state is per-feature / keep the features decoupled" rule wins over de-duping a
> one-line constant.
> [decision] Also added the recopy-restarts-the-dwell test (beyond the two listed
> checkboxes) so the `cancelInFlight` behaviour is covered here as it is in Task 1.

### Task 3: ChatFeature — Copy session ID action

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/ChatInteractionTests.swift`

- [x] add `copiedIDToastToken` state, `.copySessionIDTapped` / `.copiedIDToastExpired` actions, `CancelID.copyIDToast`
- [x] reduce: copy `state.sessionKey` (guard non-nil → no-op otherwise) + timed dismiss as in Task 1
- [x] write TestStore test: with `storedSessionID` set → copies it, toast shows/auto-hides
- [x] write TestStore test: `sessionKey == nil` → no state change, no effect
- [x] run tests - must pass before task 4

> [decision] `copiedIDToastToken` is initialized in the `State.init` BODY (`= nil`), not
> added as an init parameter — `ChatFeature.State.init` only takes the caller-supplied
> subset and defaults the rest inline (unlike the list/archived features, whose inits
> enumerate every field). No call sites change.
> [decision] `copiedFeedbackDuration` is a local `static let` on `ChatFeature` (mirrors Task
> 2's per-feature duplication rule) and `CancelID` gained a distinct `copyIDToast` case
> next to the code-block `copyFeedback`.
> [decision] `.teardown` does NOT cancel `copyIDToast` — it doesn't cancel `copyFeedback`
> either; a 1.5s toast timer isn't a long-running effect worth teardown bookkeeping.
> [decision] Added a third test (recopy restarts the dwell) beyond the two listed
> checkboxes, matching Tasks 1/2's `cancelInFlight` coverage.

### Task 4: Views — CopiedToastView + menu items on all three screens

**Files:**
- Create: `HermesMobile/Sources/Features/CopiedToastView.swift`
- Modify: `HermesMobile/Sources/Features/SessionListView.swift`
- Modify: `HermesMobile/Sources/Features/ArchivedSessionsView.swift`
- Modify: `HermesMobile/Sources/Features/Chat/ChatView.swift`
- Modify: `HermesMobileTests/SessionSnapshotTests.swift`

- [x] create `CopiedToastView` (capsule + material, "Session ID copied", reduce-motion-aware transition)
- [x] add "Copy ID" to the session-list row `.contextMenu` + bottom-overlay toast gated on `store.copiedIDToastToken`
- [x] add "Copy ID" to the archived-sessions row `.contextMenu` + toast overlay
- [x] add "Copy ID" to the chat toolbar `Menu` (`.disabled(store.sessionKey == nil)`) + toast overlay above the composer
- [x] run `tuist generate` so the new source file is picked up
- [x] add snapshot test: sessions list with toast visible; `make snapshot-record` then `make snapshot`
- [x] run full snapshot suite - must pass before task 5

> [decision] `CopiedToastView` owns its own `if isPresented` conditional (plus transition and
> `.animation(value:)`), so each of the three screens is a one-liner
> `.overlay(alignment: .bottom) { CopiedToastView(token: store.copiedIDToastToken) }`.
> It's `.allowsHitTesting(false)` so it can never eat a row/composer tap.
> [decision] Background uses `#available(iOS 26, *)` `.glassEffect(.regular, in: .capsule)`
> with a `.regularMaterial` + hairline + shadow fallback (mirrors `ScrollToBottomButton`'s
> `GlassCircle`), per the CLAUDE.md Liquid-Glass gating rule — not `.interactive()`, since
> the toast isn't a control.
> [deviation] Did NOT run `make snapshot-record`: that script `rm -rf`s the whole
> `__Snapshots__` dir and re-records all 81 baselines, which would churn every PNG in the
> commit. Instead ran `make snapshot` once (the new test has no baseline → SnapshotTesting
> records it and fails, as designed), then `make snapshot` again → 81/81 pass.
> [decision] The session-list toast overlay is attached BEFORE the bottom `safeAreaInset`, so
> it floats above the "New chat" bar instead of covering it; in chat the overlay is on the
> `transcript` (not the whole `VStack`) so it sits above footer/pending-card/composer.
> [decision] Session-list "Copy ID" sits between Rename and Archive in the context menu
> (destructive Archive stays last); no swipe action, per the plan.
> [review] Added `.safeAreaPadding(.bottom)` to `CopiedToastView`: the archived-sheet snapshot
> showed the capsule landing in the home-indicator band (that `List` has no bottom
> `safeAreaInset` to lift it). It adds 0 where the host already excludes the safe area, and
> nudges the list/chat toasts up by the inset. Snapshots now cover all three surfaces.
> [review] `CopiedToastView` announces itself via `AccessibilityNotification.Announcement` —
> VoiceOver focus never lands on a transient overlay, so rendering alone gave VoiceOver users
> no confirmation at all.
> [review] The toast flag became a per-copy token (`showsCopiedIDToast: Bool` →
> `copiedIDToastToken: Int?`, `nil` = hidden, bumped by every copy) in all three features. The
> announcement is keyed on the token instead of the presented edge: a re-copy while the toast
> is still up never flipped the `Bool`, so `.onChange` didn't fire and the second copy was
> silent — and that announcement is the ONLY confirmation channel a VoiceOver user gets. The
> token also makes the re-copy an assertable state change in the `TestStore` recopy tests
> (`$0.copiedIDToastToken = 2`), where before the second `send` had no state change at all.
> Rendering is unchanged (the view derives `isPresented` from `token != nil`) — all 83
> baselines still pass untouched.
> [review] The three private glass/material `#available(iOS 26)` modifiers (`GlassCapsule`,
> `GlassCircle`, the toast's) were collapsed into one shared `GlassBackground<S: Shape>`
> (rule of three); renders are pixel-identical (all 81 pre-existing baselines still pass).

### Task 5: Verify acceptance criteria
- [x] verify all three menus offer "Copy ID" and copy the correct id
- [x] verify edge cases: chat with no session yet (disabled item), rapid re-copy restarts toast
- [x] run full test suite: `script -q /dev/null swift test --package-path HermesKit`
- [x] run snapshot tests: `make snapshot`

> [decision] Verified by code inspection + the existing reducer/snapshot suites rather than a
> device run (no human available; manual on-device checks stay in Post-Completion).
> Menus: `SessionListView.swift:500` (row `.contextMenu`, between Rename and Archive) →
> `.copyIDButtonTapped(id: session.id)`; `ArchivedSessionsView.swift:32` (row `.contextMenu`,
> next to Restore) → `.copyIDButtonTapped(id: session.id)`; `ChatView.swift:56` (toolbar
> ellipsis `Menu`, below Rename) → `.copySessionIDTapped`, which copies `state.sessionKey`
> (`storedSessionID ?? liveSessionID`).
> Edge cases: the chat item carries `.disabled(store.sessionKey == nil)` AND the reducer
> guards (`ChatFeature.swift:948` `guard let sessionID = state.sessionKey else { return .none }`)
> — belt and braces, covered by `copySessionIDWithoutASessionIsANoOp`. Rapid re-copy restarts
> the dwell via `.cancellable(id: CancelID.copyIDToast, cancelInFlight: true)` in all three
> reducers, each with its own `recopying…RestartsTheDwellTimer` test.
> Validation: 727 HermesKit tests pass; `make snapshot` TEST SUCCEEDED (81 baselines incl.
> `testSessionList_copiedIDToast`). No code gaps found — verification produced no source changes.
> [decision] Reverted an incidental `HermesKit/Package.resolved` `originHash`-only churn that
> `swift test` re-wrote; unrelated to this feature, kept out of the commit.
> [decision] Cron **job** rows (`SessionListView.swift:273`) deliberately get NO "Copy ID": a
> job id is not a session id, so the item would copy a different kind of identifier under the
> same label. Cron **run** rows go through `row(_:)` and are covered for free.

### Task 6: [Final] Update documentation
- [x] update CLAUDE.md only if a new reusable pattern emerged (toast) — one line at most
- [x] move this plan to `docs/plans/completed/` (deferred — the orchestrator performs the move at completion)

> [decision] The toast pattern IS a genuinely new binding convention (nothing in CLAUDE.md
> covered transient confirmation UI), so one bullet was added after "List-row affordances":
> the dwell lives in the reducer as a per-copy token + `cancelInFlight` `continuousClock`
> effect (never a view-local `Task.sleep`, so it's `TestClock`-drivable), rendered by the
> shared app-target `CopiedToastView`, with the token duplicated per feature rather than
> hoisted into a shared toast feature.
> [decision] README's "Copy what you need." bullet was extended with the session-id copy — it
> is a user-facing capability in the same family as message/code-block copy, so it belongs in
> the feature overview rather than as a new bullet.
> Validation: 727 HermesKit tests pass (docs-only change, no behaviour touched).

## Post-Completion
*Items requiring manual intervention or external systems - no checkboxes, informational only*

**Manual verification**:
- on device/simulator: long-press a session row → Copy ID → toast appears and the
  pasteboard holds the id; same from the Archived sheet and the chat ellipsis menu;
  VoiceOver announces the menu items sensibly, and copying twice in a row (while the toast
  is still up) speaks "Session ID copied" both times.
- on device: check the Archived sheet's nav bar for a glass-sampled ghost of the toast.
  The `testArchivedSessions_copiedIDToast` baseline bakes in a faint capsule at the very top
  edge — believed to be a deterministic offscreen-render artifact of the iOS 26 nav-bar glass
  backdrop, but that is unverified on real hardware. If the ghost is visible on device it is a
  real bug (fix the toast's z-placement); if not, the baseline is benign and only needs
  re-recording when the OS/toolchain changes the sampling.

**Follow-up (not this branch)**:
- the chat row long-press "Copy" (`ChatFeature.copyRow`) still gives no confirmation, while
  code-block copy shows a checkmark and Copy ID shows a toast — three copies, three
  confirmations. Routing `copyRow` through the toast needs a parameterized message on
  `CopiedToastView`.
