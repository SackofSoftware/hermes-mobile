# Approval Card: Scrollable Command Block (#65)

## Overview

- TestFlight feedback (issue #65): the approval card's command text is sometimes cut
  off, and the user has to leave and re-enter the chat to read the whole command.
- Root cause: `ApprovalCardView` sits in `ChatView`'s outer `VStack` between the
  transcript and the composer (`ChatView.swift:21`) — the non-scrolling region. The
  command `Text` (`ApprovalCardView.swift:29`) has no `.fixedSize(horizontal: false,
  vertical: true)`, so when the fixed region runs out of room (long command, keyboard
  up, suggestion panel visible) the `VStack` compresses the card and SwiftUI truncates
  the `Text` with no way to read the rest. Re-entering works because the keyboard is
  down then — more room. Adding `fixedSize` alone would be worse: a very long command
  would push the composer and the Approve/Deny buttons off-screen.
- Fix (Option A, agreed): a **bounded, scrollable command block**. The command keeps
  its natural height when it fits; past a cap it scrolls vertically in place with a
  bottom fade hinting at the overflow (mirroring the #59 table treatment). Every byte
  of the command stays reachable and Approve/Deny always stay on screen — the user
  must be able to read what they're approving before they approve it.
- View-only change: no reducer, model, or protocol work.

## Context (from discovery)

- `HermesMobile/Sources/Features/Chat/ApprovalCardView.swift` — the card: detail text
  (already `fixedSize`-wrapped), command `Text` (`.callout.monospaced()`,
  `.textSelection(.enabled)`, secondary-background rounded rect), content-gated
  "Approve all" toggle, Deny/Approve buttons.
- `HermesMobile/Sources/Features/Chat/ChatView.swift:21` — `pendingCard` placement in
  the outer `VStack(spacing: 0)`: transcript (greedy `UICollectionView`
  representable) above, composer below; the card shares the fixed region with
  footer/suggestion panel/divider.
- Precedents: `MarkdownTableView` (#59) — capped dimension + scroll + overflow fade,
  `@ScaledMetric` caps; `MarkdownTableLayoutTests` — measured `UIWindow`-hosted
  geometry assertions (`UIScrollView.contentSize` vs `bounds`), pinned
  `.dynamicTypeSize(.large)`; `SnapshotTestSupport` + existing approval snapshots in
  `ChatSnapshotTests.swift:420-445` (`testApprovalCard`, `testApprovalCard_recovered`).
- Snapshot gotcha (CLAUDE.md): a scrollable view snapshotted at `.sizeThatFits`
  records a blank sliver along its flexible axis — pin explicit frames.
- iOS 18 deployment target: `onGeometryChange(for:of:action:)` is available directly.

## Development Approach

- **Testing approach**: Regular (code first, then tests, per task)
- Complete each task fully before moving to the next; small focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that
  task — success and error scenarios both
- **CRITICAL: all tests must pass before starting next task** — no exceptions
- **CRITICAL: update this plan file when scope changes during implementation**
- New snapshot baselines via the run-twice `make snapshot` recipe (first run records
  and fails by design, second asserts) — never `make snapshot-record`
- Behavior below the cap must be pixel-identical to today for short commands (the
  common case) — existing snapshots guard that

## Testing Strategy

- **Measured layout tests** (`HermesMobileTests`, `UIWindow`-hosted XCTest): the facts
  a snapshot cannot prove — "scrollable with full content present" vs "clipped" are
  the same first screenful. Assert geometry: the command block's
  `UIScrollView.contentSize.height` vs `bounds.height`, and the card's total height
  staying within a constrained host while the buttons remain laid out inside it.
  Pin `.dynamicTypeSize(.large)` (thresholds must not follow the simulator's text
  size).
- **Snapshot tests** (`ChatSnapshotTests`): short command (unchanged look), long
  command at a pinned explicit frame (first screenful + fade visible).
- No HermesKit reducer tests — no reducer change.

## Progress Tracking

- Mark completed items with `[x]` immediately when done
- Add newly discovered tasks with ➕ prefix; blockers with ⚠️ prefix
- Keep plan in sync with actual work done

## Solution Overview

- Wrap the command `Text` in a vertical `ScrollView` whose height is
  `min(measuredContentHeight, cap)`:
  - the `Text` gains `.fixedSize(horizontal: false, vertical: true)` (inside the
    scroll content it sizes to its ideal, never truncates);
  - its ideal height is read with `onGeometryChange(for: CGFloat.self,
    of: \.size.height)` into local `@State`;
  - the `ScrollView` gets `.frame(height: min(measured, cap))` — explicit height, so
    the `VStack` compression that truncated the `Text` can no longer squeeze it below
    the cap, and a short command hugs its content exactly as today (no dead space,
    no scroll);
  - `.scrollBounceBehavior(.basedOnSize)` so a fitting command never bounces.
- **Bottom fade when overflowing** (`measured > cap`): a mask that fades the last
  ~24pt of the block, mirroring `MarkdownTableView`'s rationale — iOS only flashes
  the scroll indicator mid-drag, so a scrollable command would otherwise look exactly
  like the clipped one the issue reported. Vertical fade — no layout-direction
  mirroring concern (unlike #59's horizontal one).
- **The cap is `@ScaledMetric(relativeTo: .callout)`** (base ~220pt) so larger
  Dynamic Type sizes keep a similar visible line count rather than showing ever
  fewer lines.
- Key decision: an explicit measured `.frame(height:)` over `ViewThatFits(in:
  .vertical)` — `ViewThatFits` picks per the incoming *proposal*, which in this
  compressed `VStack` is exactly the negotiated squeezed size, reintroducing the
  ambiguity we're fixing; the measured frame makes the card's height deterministic
  and testable.
- `.textSelection(.enabled)` stays on the command text. Whether the selection
  gesture beats the new scroll gesture is a manual-check item (same caveat family as
  the #59 table cells) — not a tested contract.

## Technical Details

- `ApprovalCardView` additions: `@State private var commandContentHeight: CGFloat?`,
  `@ScaledMetric(relativeTo: .callout) private var commandMaxHeight = 220` (clamped
  ceiling optional — the card, unlike the table, competes only vertically and the
  scroll makes any cap safe), private `commandBlock(command:)` builder, private
  `bottomFadeMask(active:)`.
- Until the first measurement lands (`commandContentHeight == nil`), propose
  `maxHeight: commandMaxHeight` instead of a hard height — avoids a zero-height
  first frame.
- The fade mask: `LinearGradient`-based mask on the `ScrollView`, active only when
  `measured > cap`; keep the measurement-driven condition in a small pure helper so
  it's unit-assertable if extracted (nice-to-have, not required).
- The recovered-approval card (`command == nil`) renders no command block — path
  untouched.
- Files: view change in `HermesMobile` only; tests in `HermesMobileTests` (real
  UIKit host needed) — nothing moves into HermesKit.

## What Goes Where

- **Implementation Steps** (`[ ]` checkboxes): view rework, measured tests,
  snapshots, docs.
- **Post-Completion** (no checkboxes): on-device verification of the original
  repro + selection-vs-scroll manual check.

## Implementation Steps

### Task 1: Scrollable, capped command block in `ApprovalCardView`

**Files:**
- Modify: `HermesMobile/Sources/Features/Chat/ApprovalCardView.swift`
- Modify: `HermesMobileTests/ChatSnapshotTests.swift`

- [x] extract the command block into a private builder: `ScrollView` +
      `fixedSize`d `Text` + `onGeometryChange` height measurement +
      `.frame(height: min(measured, cap))` (maxHeight fallback pre-measurement) +
      `.scrollBounceBehavior(.basedOnSize)`
- [x] add the `@ScaledMetric` cap and the overflow-only bottom fade mask
- [x] document on the type why the explicit measured frame exists (the `VStack`
      compression story) — the constraint the code can't show
- [x] update/extend snapshots: existing short-command card stays byte-identical;
      add a long-command card at a pinned explicit frame (fade + first screenful);
      record new baselines via `make snapshot` run twice
- [x] run `make snapshot` — must pass before task 2
- ⚠️ `make snapshot` has **pre-existing** unrelated failures in this environment
      (`AddProfileSnapshotTests` ×3, `AuthSnapshotTests` ×5–9 — `drawHierarchyInKeyWindow`
      renders drifting against baselines recorded on an older iOS 26 runtime). Verified
      pre-existing by re-running both suites with this task's changes stashed: identical
      failures. Every `ChatSnapshotTests` case passes, including both existing approval
      baselines (byte-identical) and the new `testApprovalCard_longCommandScrolls`.

### Task 2: Measured layout tests for the command block

**Files:**
- Create: `HermesMobileTests/ApprovalCardLayoutTests.swift`

- [x] host the card in a `UIWindow` (follow `MarkdownTableLayoutTests` harness:
      hosting controller, forced layout, `.dynamicTypeSize(.large)` pinned)
- [x] long command in a height-constrained host: the block's `UIScrollView` has
      `contentSize.height > bounds.height` (full content present, scrollable) AND
      the card's `sizeThatFits` height stays ≤ the constraint (buttons never pushed
      out)
- [x] short command: block height equals content height (±1pt) — no dead space, no
      scroll (`contentSize.height <= bounds.height`)
- [x] recovered card (`command == nil`): no scroll view in the hierarchy; card
      height unchanged by this work
- [x] control test proving the harness can go red (e.g. assert a deliberately
      uncapped variant would exceed the constraint — mirror the prose control in
      `MarkdownTableLayoutTests`)
- [x] run the `HermesMobileTests` suite — must pass before task 3
- ➕ the block is found by `ApprovalCardView.commandBlockAccessibilityID` through the
      **accessibility** children, not `subviews`: SwiftUI only stamps the identifier onto
      the backing `UIScrollView` once the accessibility tree is materialised (measured —
      a plain `subviews` walk reads it back as `nil`). The absence assertion for the
      command-less card uses a plain `subviews` walk, which is the only way to prove
      *no* scroll view exists.
- ➕ red-check beyond the in-suite control: with the cap removed from the production view
      (`.frame(height: commandContentHeight)`) the suite goes red on exactly the
      cap-dependent assertions — 5 failures across
      `testLongCommandScrollsInsteadOfBeingTruncated` (block 1258pt, not 220pt) and
      `testCardHeightIsBoundedByTheCapNotTheCommandLength` (card 1497pt vs 12837pt for a
      10× command, both past the 480pt budget). Production file restored afterwards.
- ⚠️ the **pre-existing** snapshot drift noted under Task 1 has widened on this machine:
      `make snapshot` now reports 92/161 failures across *every* snapshot suite
      (`ChatSnapshotTests` included, which passed during Task 1). Verified unrelated to
      this task: `ChatSnapshotTests` alone fails 22/27 identically **with this task's new
      file deleted and the project regenerated**, and no tracked file differs from the
      Task-1 commit. Ruled out: simulator contention with a concurrent run (re-ran with
      the simulator idle — same 92) and a dark-appearance simulator (reset to light —
      same 92). The two measured suites are green: `ApprovalCardLayoutTests` 8/8 and
      `MarkdownTableLayoutTests` 19/19. Out of scope here; Task 3's `make snapshot` gate
      needs the baselines re-recorded on the current runtime first.

### Task 3: Verify acceptance criteria

- [x] long command + tight vertical space: command fully readable by scrolling,
      Approve/Deny on screen, fade shown — `ApprovalCardLayoutTests` 8/8 green
      (`contentSize.height` 1258pt > `bounds.height` 220pt, card height ≤ budget) and the
      `testApprovalCard_longCommandScrolls` baseline shows the capped first screenful, the
      bottom fade, and the toggle + Deny/Approve row on the card
- [x] short command: rendering pixel-identical to before (snapshots unchanged) — **this
      criterion initially FAILED and found a real bug in Task 1's view; fixed here** (see ➕
      below). No baseline file was re-recorded; `testApprovalCard` now renders at the
      baseline's exact 1170×611 with a 47px / 0.007% / **1-of-255** residual, i.e. the same
      environment noise floor as every untouched suite
- [x] recovered/no-command card untouched — `testRecoveredCardRendersNoCommandBlock` green
      (no scroll view in the hierarchy); `testApprovalCard_recovered` differs from its
      baseline by 56px / 0.010% / 1-of-255, drift only
- [x] full suites green: `script -q /dev/null swift test --package-path HermesKit`
      (1016 tests / 57 suites, 0 failures — unchanged, no HermesKit file touched),
      the layout suites (`ApprovalCardLayoutTests` 8/8, `MarkdownTableLayoutTests` 19/19,
      `ComposerTextViewTests` 30/30, `MarkdownTableSnapshotTests` 6/6), and `make snapshot`
      **with the caveat below**
- ➕ **Real regression found and fixed: the block reported a collapsed ideal height.** A
      `ScrollView` is fully flexible along its scroll axis, so its *own* ideal height is
      **zero** — `.frame(maxHeight:)` can cap an ideal but cannot supply one. Task 1's block
      therefore sized to its 16pt padding alone on any pass that ran **before**
      `onGeometryChange` had fired, and the whole card under-reported its height by exactly
      one command. Measured: `testApprovalCard` rendered 1170×**553** against a 1170×611
      baseline — the card clipped 9.7pt off *each* end, cutting its own rounded border. This
      is a one-frame squeeze of precisely the content #65 is about, and it was invisible to
      the Task-2 layout tests because their harness forces a window layout pass (so the
      measurement has already landed) before asserting. Proved it was ours, not drift, by
      swapping the production `commandBlock` back to main's bare `Text`: the same test then
      rendered 1170×611, byte-for-byte the baseline's size. Fix: a hidden, layout-only
      `commandSizer(_:)` twin of the command text inside the block's `ZStack`, supplying the
      ideal the `ScrollView` cannot. The twin carries **its own** `maxHeight` clamp — without
      it the `.fixedSize` text answers every proposal with its full natural height, the
      `ZStack` reports ~1258pt, the sibling `ScrollView` is handed all of it and the outer
      frame merely clips: the cap defeated and nothing scrolling (measured that failure mode
      too, en route). Both the twin and the real text come from one `commandText(_:)` builder
      so they cannot drift apart.
- ⚠️ `make snapshot` is **92/161 red, and 0 of those failures belong to this branch.** The
      drift is environment-wide against baselines recorded on an older iOS 26 runtime. Ruled
      out as ours three independent ways: (1) `git diff main...HEAD` touches only
      `ApprovalCardView.swift`, `ApprovalCardLayoutTests.swift`, an additive
      `ChatSnapshotTests` case, one new PNG and this plan — so `AuthSnapshotTests` (9/9 red)
      and `SettingsSnapshotTests` (7/7 red) are byte-identical to main, inputs and baselines
      alike, and fail on main by construction; (2) pixel-diffing every produced-vs-baseline
      pair shows the failures are sub-perceptual (`AddProfileSnapshotTests`: 662 of 2.96M px,
      max channel delta **3**) through to genuinely visible but unrelated
      (`SessionSnapshotTests`: up to 4.2% of px, delta 255 — list chrome); (3) the one
      baseline recorded on the *current* runtime, `testApprovalCard_longCommandScrolls`,
      **passes**. Not re-recorded: CLAUDE.md reserves `make snapshot-record` for a deliberate
      global re-render, and re-recording drifted baselines wholesale would bury real
      regressions — exactly the one this task just caught. A deliberate global re-record on
      the current runtime is the follow-up, and it must be its own commit.

### Task 4: [Final] Update documentation

- [x] add a CLAUDE.md line to the approval-card conventions: the command block is a
      measured, capped, scrollable region (never bare `Text` in the fixed `VStack`
      region) with the fade + `@ScaledMetric` rationale — added directly after the
      push-tap approval-recovery bullet, covering the `VStack`-compression root cause,
      the explicit-measured-frame-over-`ViewThatFits` decision, the `@ScaledMetric` cap
      and unconditional overflow-only fade, and the hidden `commandSizer` twin (why a
      `ScrollView` has no ideal height of its own, and why the twin needs its own clamp)
- [x] comment on issue #65 with the root cause + fix; close after device check —
      posted (`#65 issuecomment-5239424122`); left **open** deliberately, the plan
      closes it only after the device repro
- [x] move this plan to `docs/plans/completed/` (deferred to the orchestrator's
      end-of-run move)

## Post-Completion

**Manual verification (device):**
- Reproduce the original report: trigger an approval with a long multi-line command
  while the keyboard is up → the whole command is readable by scrolling the block;
  no exit/re-enter needed.
- Selection-vs-scroll gesture check: long-press text selection inside the scrollable
  command block still works (or degrades gracefully) — untested contract, manual
  only.
- Dynamic Type at largest accessibility size: card still leaves the composer and
  buttons reachable.
