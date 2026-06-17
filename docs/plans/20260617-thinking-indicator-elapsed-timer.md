# Live "Thinking" indicator with elapsed timer

Resolves GitHub issue #11 — "Show 'Thinking' indicator with elapsed timer while
agent responds" — and folds in two refinements raised during planning:

1. **Reasoning currently renders as a static row that reads like "a new message each
   time."** Replace it with a single live indicator that updates in place and, when the
   turn ends, collapses into a `Thinking · 1m 3s` disclosure kept in scrollback.
2. **The context-size / `status.update` text is a permanent footer above the composer**
   that lingers until you leave the screen. Move it *inside* the Thinking indicator's
   disclosed area; drop the persistent footer.

## Overview

Today reasoning arrives as `thinkingDelta` / `reasoningAvailable` events folded into a
`ChatRow.Kind.thinking(text:)` row, rendered inline as a static
`DisclosureGroup("Thinking")` — no timer, no in-progress feel, and a fresh row appears per
turn. `status.update` events set `state.activity`, rendered as a persistent footer above
the composer (`ChatView.footer`) that only clears on messageStart/Complete/blocking — never
on leaving the screen.

This plan turns the thinking row into a **live, single, in-place indicator** driven by the
turn's in-progress window:

- Created at `.messageStart` (appears immediately, even before any reasoning text), it shows
  the label **"Thinking"** plus a **live elapsed timer** in `1h 1m 1s` format, ticking via a
  cancellable `continuousClock` effect (testable with `TestClock`, mirroring the existing
  voice-recording tick at `ChatFeature.swift:497-503`).
- A **shimmer** animation plays while active; **held flat under reduce-motion**.
- Its **disclosed area** accumulates the reasoning text **and** the latest `status.update`
  line (the context-size message) — no more persistent footer.
- On `.messageComplete` (or socket drop / error) the timer **freezes**, the row flips to a
  **static collapsed `Thinking · <elapsed>` disclosure** kept in the transcript so past
  reasoning + status stay reviewable. A turn that produced **no** reasoning and **no** status
  leaves no row.

**Design decisions (confirmed with the user):**
- *Post-turn:* collapse-to-disclosure (keep reasoning history), not ephemeral.
- *Trigger:* visible for the whole in-progress window (`isSending` / message.start →
  message.complete), so tool-only turns that emit only status updates still show it.

## Context (from discovery)

- **Files/components involved:**
  - `HermesKit/Sources/HermesKit/Models/ChatRow.swift` — `Kind.thinking(text:)` (`:27`),
    `copyText` thinking branch (`:39`). The thinking case is redefined here.
  - `HermesKit/Sources/HermesKit/Features/ChatFeature.swift`:
    - `State` (`:16-91`); `activity` field (`:22`); bookkeeping `thinkingRowID` (`:82`),
      `CancelID`/effects (`continuousClock` injected `:206`; voice-timer loop `:497-503`;
      `onDisappear` cancellation `:229-241`).
    - Event reduction: `.messageStart` (`:728-736`) resets `thinkingRowID`/`activity`;
      `.messageComplete` (`:742-754`) clears them; `.thinkingDelta`/`.reasoningAvailable`
      (`:756-762`) → `appendToThinking`; `.statusUpdate` (`:764-766`) → `state.activity`;
      blocking-interaction cases null `activity` (`:813,818,823,828`); `.error` (`:806-809`);
      `finalizeInFlight` (`:858-866`); `appendToThinking` (`:868-876`).
  - `HermesMobile/Sources/Features/Chat/ChatView.swift` — `rowView` `.thinking` →
    `DisclosureGroup("Thinking")` (`:193-198`); `footer` activity branch (`:251-266`);
    transcript `ForEach` (`:118`).
  - Reduce-motion precedent: `ComposerView.swift:183,196`, `MarkdownText.swift:100,121`.
- **Related patterns found:**
  - **Live tick effect:** voice recording's `recordingSeconds` + 1s `continuousClock` loop
    (`ChatFeature.swift:497-503`, `CancelID.voiceTimer`) is the template for the thinking
    timer. `recordingTick` increments a public `Int` the view renders.
  - **In-place row update:** `appendToStreamingMessage` / `appendToThinking` already keep a
    single in-flight row via a stored row id — extend, don't replace.
  - **`isComplete` flag on a kind:** `.message(role:text:isComplete:)` already models
    "still streaming vs done"; mirror it on `.thinking`.
  - A `public struct`/case nested in feature State needs an explicit `public init` to build
    from the app/snapshot target.
- **Dependencies identified:** none new. No protocol/RPC/client changes — purely reducer +
  view wiring over events already decoded.

## Development Approach

- **Testing approach: Regular** (code first, then tests) — matches the repo flow.
- Complete each task fully before the next; small, focused changes.
- **Every task includes new/updated tests.** Pure logic (elapsed formatter, `copyText`)
  lives in `HermesKit`, unit-tested via `swift test`; reducer + timer via `TestStore` +
  `TestClock`; the view via snapshot tests.
- **All tests pass before starting the next task.**
- Keep logic in `HermesKit`, views thin (project convention).
- Backward compatibility: a turn with no reasoning/status must render gracefully (no empty
  disclosure left behind); never crash.

## Testing Strategy

- **Unit tests (HermesKit `swift test`):**
  - `formatElapsed(_:)`: `0 → "0s"`, `5 → "5s"`, `59 → "59s"`, `60 → "1m 0s"`, `61 → "1m 1s"`,
    `3599 → "59m 59s"`, `3600 → "1h 0m 0s"`, `3661 → "1h 1m 1s"`, `7325 → "2h 2m 5s"`
    (decide & test the zero-unit-omission rule — see Technical Details).
  - `ChatRow.copyText` for the new `.thinking` shape (reasoning, with/without status).
- **Reducer tests (`TestStore` + `TestClock`):**
  - `.messageStart` creates the active thinking row (`isComplete == false`, empty reasoning,
    `nil` status) and starts the timer; advancing the `TestClock` by N seconds drives N
    `thinkingTick`s incrementing `state.thinkingSeconds`.
  - `.thinkingDelta` / `.reasoningAvailable` accumulate into the active row's `reasoning`.
  - `.statusUpdate` sets the active row's `status` (and **no longer** sets `activity`, which
    is removed).
  - `.messageComplete` bakes `elapsedSeconds = thinkingSeconds`, flips `isComplete == true`,
    cancels the timer, resets `thinkingSeconds`; a turn with empty reasoning **and** nil
    status removes the row entirely.
  - Socket drop (`finalizeInFlight`) and `.error` freeze the active row + cancel the timer.
  - `.onDisappear` cancels the timer.
- **Snapshot tests (`make snapshot`, `HermesMobileTests/`):** active (0m2s, no reasoning),
  active (reasoning + status, expanded), completed collapsed `Thinking · 1m 3s`, completed
  expanded (reasoning + status), reduce-motion active. Pin `thinkingSeconds` for determinism.
  Re-record with `make snapshot-record` (intentional UI change).
- Run command for unit/reducer: `script -q /dev/null swift test --package-path HermesKit`
  (or `make test`). Snapshots: `make snapshot`.

## Progress Tracking

- Mark completed items `[x]` immediately.
- New tasks get a ➕ prefix; blockers get ⚠️.
- Keep this plan in sync if scope shifts.

## Solution Overview

1. **Model (HermesKit, pure).** Add `formatElapsed(_ seconds: Int) -> String`. Redefine
   `ChatRow.Kind.thinking` to carry reasoning, the latest status line, the frozen elapsed
   seconds, and an `isComplete` flag.
2. **Reducer.** Add `public var thinkingSeconds: Int`, a `CancelID.thinkingTimer`, and a
   `.thinkingTick` action. Create/own the active thinking row across the turn; start/stop the
   timer; route `status.update` into the row; freeze on completion/error/drop; remove the now
   persistent `state.activity`.
3. **View.** A `ThinkingIndicatorView` rendering the live vs. frozen states (shimmer +
   reduce-motion), wired into `rowView`; drop the `activity` footer branch.

## Technical Details

- **`formatElapsed` (HermesKit, pure):** `1h 1m 1s` style. Omit higher-order zero units but
  always keep the seconds unit; floor display at `"0s"`. So `5 → "5s"`, `61 → "1m 1s"`,
  `3600 → "1h 0m 0s"`, `3661 → "1h 1m 1s"`. Lock the exact rule with the boundary tests
  above. Pure free function or static; unit-tested.
- **`ChatRow.Kind.thinking` new shape:**
  `case thinking(reasoning: String, status: String?, elapsedSeconds: Int, isComplete: Bool)`
  - `reasoning` — accumulated reasoning/thinking text (may be empty while only status has
    arrived).
  - `status` — latest `status.update` text (the context-size/compaction line); shown only in
    the disclosed area.
  - `elapsedSeconds` — frozen final elapsed, written at completion; ignored by the view while
    active (the view reads the live `store.thinkingSeconds` instead).
  - `isComplete` — `false` while the turn runs (live timer + shimmer), `true` once frozen
    (static collapsed disclosure).
  - `copyText` returns `reasoning` (append the status line if present).
- **Live timer:** `public var thinkingSeconds: Int` on `State`. A cancellable 1s
  `continuousClock` loop (`CancelID.thinkingTimer`) started at `.messageStart` sends
  `.thinkingTick` → `thinkingSeconds += 1`. The active row's view renders
  `store.thinkingSeconds`; on completion the value is baked into the row's `elapsedSeconds`
  and `thinkingSeconds` resets to 0. Mirrors `recordingSeconds`/`voiceTimer`.
- **Row ownership / lifecycle:**
  - `.messageStart`: create the active thinking row (empty reasoning, nil status, elapsed 0,
    `isComplete: false`), store `thinkingRowID`, reset `thinkingSeconds = 0`, **return the
    timer effect**. (Unlike the assistant bubble, the thinking row is created eagerly — an
    immediate "Thinking 0s" is the desired affordance.)
  - `appendToThinking` and `.statusUpdate` mutate the active row, **creating it defensively**
    if `.messageStart` was missed (so reasoning/status never gets dropped).
  - `.messageComplete`: bake `elapsedSeconds = thinkingSeconds`, set `isComplete = true`,
    **remove the row if reasoning is empty and status is nil**, cancel the timer, reset
    `thinkingSeconds`, clear `thinkingRowID`.
  - `.error` and `finalizeInFlight` (socket drop / reconnect): same freeze + cancel + reset.
  - `.onDisappear`: cancel the timer effect.
  - Blocking interactions (approval/clarify/secret/sudo): the active row stays; **pause the
    timer** while a card is the focus and **resume** it when answered (cancel/restart the same
    effect) so wall-clock excludes user think-time. *(Nice-to-have — if it complicates the
    reducer, default to letting the timer keep running and note the choice.)*
- **Remove `state.activity`:** delete the field and every assignment
  (`:733,752,765,813,818,823,828`); `status.update` now writes the row's `status`. Update any
  test/preview that referenced `activity`.
- **Ordering note:** the thinking row is appended at `.messageStart`, so it sits *above* the
  streaming answer (reasoning-then-answer, chronologically honest). It is the literal last
  item only during the pre-answer phase; this satisfies issue #11's "last item / incoming
  row" intent without a second render path.
- **View (`ThinkingIndicatorView`, HermesMobile):**
  - Active: `Label("Thinking", …)` + `formatElapsed(liveSeconds)`, shimmer on the label;
    `DisclosureGroup` body = reasoning `Text` + (if present) the status line. Shimmer gated by
    `@Environment(\.accessibilityReduceMotion)` — held flat when reduce-motion is on.
  - Complete: static `DisclosureGroup("Thinking · \(formatElapsed(elapsedSeconds))")`,
    collapsed by default, no animation; body identical (reasoning + status).
  - Takes `liveSeconds: Int` (from `store.thinkingSeconds`) and reads `isComplete` to choose
    live vs. frozen elapsed.
  - `tuist generate` after adding the file so the app/snapshot target globs it.

## What Goes Where

- **Implementation Steps** (`[ ]`): HermesKit model + formatter + tests; reducer timer/row
  lifecycle + tests; the SwiftUI indicator + footer removal; snapshots; docs.
- **Post-Completion** (no checkboxes): on-device check of a live turn (timer ticks, shimmer,
  reduce-motion, collapse-on-done, status inside the disclosure), Dynamic Type / VoiceOver
  pass, `tuist generate` before any device build.

## Implementation Steps

### Task 1: Elapsed formatter + `thinking` model in HermesKit

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Models/ChatRow.swift`
- Modify/Create: `HermesKit/Tests/HermesKitTests/` (a `ThinkingModelTests.swift` or extend an
  existing suite)

- [x] Add `formatElapsed(_ seconds: Int) -> String` (`1h 1m 1s` style; zero-unit-omission rule
      per Technical Details) — pure free function or static, public.
- [x] Redefine `ChatRow.Kind.thinking` to
      `thinking(reasoning: String, status: String?, elapsedSeconds: Int, isComplete: Bool)`.
- [x] Update `ChatRow.copyText` thinking branch to return `reasoning` (+ status line if set).
- [x] Update every existing construction/match of `.thinking(text:)` in `HermesKit` to the new
      shape (search the package) so it compiles.
- [x] Tests: `formatElapsed` boundaries (0/5/59/60/61/3599/3600/3661/7325) and `copyText`
      (reasoning only; reasoning + status).
- [x] Run tests — must pass before Task 2: `script -q /dev/null swift test --package-path HermesKit`

### Task 2: Live thinking indicator + timer in `ChatFeature`

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/ChatReductionTests.swift`

- [ ] Add `public var thinkingSeconds: Int` to `State` (default 0); update the `State` init.
- [ ] Remove `public var activity: String?` and every assignment to it
      (`:733,752,765,813,818,823,828`).
- [ ] Add `CancelID.thinkingTimer` and a `.thinkingTick` action; `.thinkingTick` →
      `state.thinkingSeconds += 1`.
- [ ] `.messageStart`: create the active thinking row (empty reasoning, nil status, elapsed 0,
      `isComplete: false`), store `thinkingRowID`, reset `thinkingSeconds = 0`, and return a
      cancellable 1s `continuousClock` loop sending `.thinkingTick` (model on the voice timer
      `:497-503`; cancel any prior `thinkingTimer` first).
- [ ] `appendToThinking`: append into the active row's `reasoning`; create the row defensively
      if `thinkingRowID` is missing.
- [ ] `.statusUpdate`: set the active row's `status` (create the row defensively if missing).
- [ ] `.messageComplete`: bake `elapsedSeconds = state.thinkingSeconds`, set
      `isComplete = true`; **remove the row if reasoning empty and status nil**; cancel
      `thinkingTimer`; reset `thinkingSeconds = 0`; clear `thinkingRowID`.
- [ ] `.error` and `finalizeInFlight`: freeze the active row (same bake + `isComplete = true`),
      cancel `thinkingTimer`, reset `thinkingSeconds`.
- [ ] `.onDisappear`: cancel `thinkingTimer` (add to the existing cancellation set `:229-241`).
- [ ] *(Nice-to-have)* On a blocking interaction, pause the timer; resume on response. Skip if
      it complicates the reducer — note the choice in a comment.
- [ ] Reducer tests (TestStore + TestClock): messageStart creates active row + ticks
      (`clock.advance` → `thinkingTick` × N → `thinkingSeconds`); thinkingDelta accumulates
      reasoning; statusUpdate sets row status; messageComplete freezes/collapses and removes an
      empty row; socket drop + `.error` freeze + cancel; `.onDisappear` cancels the timer.
- [ ] Update any existing reducer test that asserted `state.activity`.
- [ ] Run tests — must pass before Task 3.

### Task 3: `ThinkingIndicatorView` + ChatView wiring

**Files:**
- Create: `HermesMobile/Sources/Features/Chat/ThinkingIndicatorView.swift`
- Modify: `HermesMobile/Sources/Features/Chat/ChatView.swift`

- [ ] Create `ThinkingIndicatorView`: active state ("Thinking" + live `formatElapsed`, shimmer,
      `DisclosureGroup` body = reasoning + status) vs. complete state (static collapsed
      `Thinking · <elapsed>`, same body). Shimmer gated by `@Environment(\.accessibilityReduceMotion)`
      (held flat when on).
- [ ] Replace the `.thinking` branch in `ChatView.rowView` (`:193-198`) to render
      `ThinkingIndicatorView`, passing `liveSeconds: store.thinkingSeconds` and the row's
      `reasoning`/`status`/`elapsedSeconds`/`isComplete`.
- [ ] Remove the `activity` branch from `ChatView.footer` (`:258-265`); keep the error branch.
      Remove any other `store.activity` reference in the view.
- [ ] Run `tuist generate` so the new source file is picked up by the app/snapshot target.
- [ ] Run a build (`swift test` for the package still green) — must pass before Task 4.

### Task 4: Snapshot tests + reduce-motion

**Files:**
- Modify/Create: `HermesMobileTests/` chat snapshot suite (extend the existing chat snapshots
  or add `ThinkingIndicatorSnapshotTests.swift`)

- [ ] Add snapshot states with `thinkingSeconds` pinned: active (0m2s, no reasoning), active
      (reasoning + status, expanded), completed collapsed `Thinking · 1m 3s`, completed
      expanded (reasoning + status), reduce-motion active.
- [ ] Record with `make snapshot-record`, then assert with `make snapshot`.
- [ ] Run tests — must pass before Task 5.

### Task 5: Verify acceptance criteria

- [ ] Indicator appears as soon as a turn starts and shows a live `1h 1m 1s` elapsed timer.
- [ ] Reasoning accumulates in one in-place indicator (no per-burst duplicate rows).
- [ ] The context-size / `status.update` text shows **inside** the indicator's disclosure —
      not as a persistent footer above the composer.
- [ ] On completion the indicator freezes and collapses to `Thinking · <elapsed>`, kept in
      scrollback; a no-reasoning/no-status turn leaves nothing.
- [ ] Shimmer plays while active and is held flat under reduce-motion.
- [ ] `usage == nil` / old agents / tool-only turns: no crash, graceful render.
- [ ] Full unit/reducer suite: `script -q /dev/null swift test --package-path HermesKit`.
- [ ] Snapshots: `make snapshot`.

### Task 6: Documentation

- [ ] Update `README.md` chat-feature overview if it enumerates chat-screen affordances.
- [ ] Add a one-line convention to `CLAUDE.md` (e.g. "the live Thinking indicator owns the
      turn's reasoning + status; elapsed via a cancellable `continuousClock` tick, frozen into
      the row on completion; status no longer rendered as a persistent footer").
- [ ] Move this plan to `docs/plans/completed/`.

## Post-Completion

*Items requiring manual intervention or external systems — informational only.*

**Manual verification:**
- On-device live turn: confirm the timer ticks in `1h 1m 1s`, the shimmer animates,
  reduce-motion holds it flat, reasoning + a context-compaction `status.update` both land in
  the disclosed area, and the indicator collapses to `Thinking · <elapsed>` when the turn ends.
- Dynamic Type + VoiceOver pass: the label/timer must be reachable and not truncate; the
  disclosure must be operable.
- Light/dark appearance check (snapshots pin dark mode; eyeball light).

**External system updates:**
- None. No protocol, RPC, or client changes.
