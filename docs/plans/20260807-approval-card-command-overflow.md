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

### Task 3b: Code-review fixes (four reviewers, all four agreed on the same defects)

- [x] **the fade never cleared** — it was keyed on the measured content height, so past the cap
      it was on for the block's whole lifetime and the command's LAST line sat permanently
      inside the ramp (unreadable at exactly the place `&& rm -rf /` would be). Replaced by the
      live-geometry `hasBottomOverflow(visibleRect:contentHeight:)` fed from
      `onScrollGeometryChange`, i.e. the half of the #59 precedent Task 1 had not copied.
- [x] **the rigid `.frame(height:)` made the card taller than its region** — incompressible at
      ~458pt against the ~290pt `ChatView`'s fixed region has with the keyboard up on an SE, so
      the card over-subscribed its container and pushed Deny/Approve (and the composer) under
      the keyboard: `.fixedSize`'s failure by another route. Replaced by `BoundedHeightLayout`,
      which reports `min(content, cap)` and **yields to a shorter proposal** down to a 44pt
      floor — shrinking a scroll *viewport* loses nothing.
- [x] **the `@ScaledMetric` cap had no ceiling** (~730pt at AX5, taller than any iPhone's fixed
      region). Clamped to `TranscriptLayout.shortestLayoutHeight / 2` — derived, not typed, the
      `MarkdownTableView.columnMaxWidthCeiling` convention; `shortestLayoutHeight` added
      alongside `narrowestLayoutWidth` (same Display-Zoom SE metric, 320×568).
- [x] **`@State` and scroll offset survived one approval replacing another** — `.id(request)` on
      the card in `ChatView.pendingCard` (`ApprovalRequest` gained `Hashable`); previously
      command B could open scrolled into its middle with A's "Approve all" still on.
- ➕ **the `commandSizer` twin turned out to be unnecessary and was deleted.** The real fact is
      narrower than Task 3 recorded: a `ScrollView` does not have *no* ideal height, it
      swallows whatever concrete proposal it is handed. Probed with the height **unspecified**
      — which a custom `Layout` can do and a `ZStack` cannot — the scroll view reports its own
      content's ideal. So the twin, its `maxHeight` clamp, and the double TextKit layout it
      cost all go away. Red-checked: making the probe concrete again fails 4 assertions.
- [x] tests: 11 measured cases (was 8). New — the tight-region repro (red-checked: with the
      layout made incompressible it fails at 458 > 290), the unwindowed-`sizeThatFits` case
      (the shape that caught the collapsed-ideal regression, now in the suite instead of only
      in a snapshot), the AX5 ceiling case (Dynamic Type was a dead parameter before), the
      cap boundary from **both** sides with non-zero geometry asserted (the old
      `testCommandAtTheCapDoesNotScroll` passed on a collapsed block and its fixture was 37pt
      shy of the cap), a pure `BoundedHeightLayout` arithmetic case, and a positive control
      making the "no scroll view" absence assertion non-vacuous. Dropped
      `testUncappedCommandBlockWouldBlowTheBudget` (it exercised no production code) and the
      test-only `commandBlockAccessibilityID` + a11y-tree walker (one plain `subviews` walk now
      serves both presence and absence, the `MarkdownTableLayoutTests` convention). The 20-line
      fixture is shared with `ChatSnapshotTests` instead of duplicated.
- [x] docs: the CLAUDE.md bullet halved and re-pointed at the code for its derivations, the
      "byte-identical snapshot" claim corrected to a **size** guard, the scrollable-snapshot
      rule generalised to either axis, the `ScrollView`-proposal trap filed as a Gotcha, and the
      environment-wide baseline drift given a standing note (it was only in this plan).
- [x] validation: HermesKit 1016/1016, `ApprovalCardLayoutTests` 11/11,
      `testApprovalCard_longCommandScrolls` still matches its baseline **unchanged** (so the
      render, fade included, is identical), `testApprovalCard` / `_recovered` differ from their
      baselines by 60 / 67 px at max channel delta **1** at the **same** render size — the
      documented drift floor, not a sizing change.

### Task 3c: Second-round code-review fixes (two reviewers, same defect)

- [x] **the block collapsed to its floor in exactly #65's condition, and the suite said fine.**
      Both reviewers derived it independently; **measured** it here by hosting the real `ChatView`
      with an approval standing, in windows the size of the screen area left when the keyboard is
      up: the content region landed on **44pt on every iPhone** (SE 320×352, 15 393×516, 6.7"
      430×590 — all identical), because a `VStack` offers each child `remaining / remainingCount`
      in flexibility order and the card is less flexible than the greedy transcript. Fixed by
      `.layoutPriority` on `pendingCard` **at the `VStack` call site** — a trait written inside the
      `@ViewBuilder` `switch` does **not** reach the enclosing stack (measured: identical numbers).
      Region with the fix, at the same window sizes: **227pt** (iPhone 15), **301pt** (6.7"),
      **320pt** (cap, keyboard down), **88pt** on the shortest screen where the region genuinely
      cannot hold more.
- [x] **the card's rigid chrome pushed Deny/Approve off screen anyway** — only the *command* was
      bounded; the header, the unbounded `detail` (the server's `description`) and the session
      toggle were rigid, and their sum alone outgrew the fixed region at AX3/AX5 and on any phone
      with a long detail (measured: composer bottom 176pt past the window at AX5 on the shortest
      screen; 85pt past it with a 1000-char detail at `.large`). **Restructured: header + detail +
      command + toggle now share ONE bounded `ScrollView`; only the Deny/Approve row is rigid.**
      One scroll, no nesting, and the detail is bounded for free. Accepted cost, logged as a
      decision: with a long command the "Approve all in this session" toggle sits below the fold
      (one scroll away, behind the fade) — keeping it rigid is precisely what put the buttons off
      screen at AX sizes, and the buttons are the safety-critical half.
- [x] **the 24pt fade was 55% of the 44pt floor** — the hint had eaten the content it was hinting
      about. `fadeRampHeight(viewportHeight:)` now returns `min(24, viewport / 4)`, so three
      quarters of any viewport stay fully opaque at any size; the constant/fraction relationship is
      pinned by its own test rather than left to drift.
- [x] **`.id(request)` could not tell two *equal* back-to-back approvals apart** — the one case
      where a replacement does not pass through `nil`. Replaced by the reducer's monotonic
      `ChatFeature.State.pendingInteractionToken`, bumped by a single `present(_:)` mutator on
      every presentation (approval / clarify / sudo / secret / the #30-recovered synthesis).
- [x] **the floor is 88pt, chosen by measurement, not by taste.** 44 → 63pt region on the shortest
      screen; 130 → 221pt there but the button row is clipped on a landscape SE (the floor drives
      the card's *claim*, so a bigger one over-subscribes a genuinely tiny region). 88 is the
      largest value that kept the button row inside the window in **every** configuration measured
      — portrait and landscape, `.large` through AX5.
- [x] tests: 16 measured cases (was 11). Four host the **real `ChatView`** — the composition is
      where the defect lived and the card-alone harness could not see it — asserting a *line-count
      floor* on the readable (un-ramped) viewport and that the composer, which sits below the
      button row, is still fully inside the window. Red-checked all three fixes: removing
      `.layoutPriority` → 6 failures (readable height 66 < 167); restoring the rigid chrome → 11
      failures (composer 176pt off screen at AX5); a constant fade ramp → the ramp test fails at
      every squeezed viewport. The old tight-region test, which passed on the degenerate 44pt
      outcome, now asserts ≥ 3 `.callout` lines outside the ramp.
- [x] snapshots: the card's content region is now compressible **vertically**, and
      `componentImage()` renders at `.sizeThatFits`, i.e. UIKit's *compressed* fitting size — which
      for a compressible view is its FLOOR. `testApprovalCard` recorded 39pt short (1170×493 vs
      1170×611) with the region already scrolling: the blank-sliver gotcha, vertical edition. Both
      component approval snapshots now pin an explicit height (the long-command one already did),
      all three baselines re-recorded via the run-twice recipe, and all three are green.
      `make snapshot` is 89 red, all of it the documented environment-wide drift (was 92 — the
      three approval baselines are now the only ones recorded on the current runtime).

### Task 3d: Third-round code-review fixes (the merged scroll traded one bug for another)

Two reviewers found that Task 3c's "everything in one scroll" restructure created new problems.
All of it **measured** in the hosted harness (windows the size of the screen area a keyboard
leaves), by rendering the region and reading the *command block's own painted band* — the
suite's old line-count floors were on the **viewport**, which the header and detail satisfy on
their own.

- [x] **the viewport opened on chrome, not on the command.** At 320×352 with the keyboard up the
      region sat on its floor and the title + a two-line detail filled it: measured **12pt of the
      command block above the ramp, i.e. ~0 lines of text**. With a 1000-char `detail` at 393×516,
      **zero command pixels** were painted at all. Fixed by ordering the scroll **command →
      detail → toggle** and lifting the title out of the scroll as one rigid, Dynamic-Type-clamped
      line. Now: 3.1 command lines at the floor, ~5.6 at 393×516, and **identical with a 26- and a
      1020-character detail**.
- [x] **the floor is now derived, not tuned**: `commandPadding` (8) + 3 × 20.9 + the 24pt ramp
      ≈ 95 → **96** (was 88, which yields 2.8 lines).
- [x] **the transcript was starved to 0pt on every phone** by the card's `.layoutPriority(1)` (a
      priority-1 child is offered everything the others do not strictly *need*, and the greedy
      transcript's minimum is zero). `BoundedHeightLayout.claim` hands a quarter of the offer
      back, floor-outranked: 393×516 keyboard-up goes region 227 → 149pt, transcript 0 → 50pt.
- [x] **`.layoutPriority(1)` was applied to the clarify/secret card too.** Measured: it does *not*
      push the composer off screen (the overflow one reviewer predicted is pre-existing and caused
      by a long *choice list*, identical with and without priority) but it does take the
      transcript's room (160pt → 13pt) while a rigid card can use none of it. Scoped to
      `.approval` via `ChatFeature.State.isApprovalPending`.
- [x] **the toggle could be flipped, scrolled away from and committed unseen.** The Approve
      button's title now mirrors it ("Approve all"), so the state is legible on the rigid row where
      the decision is made. Keeping the toggle itself rigid is what put the buttons off screen at
      AX sizes, so it stays in the scroll.
- [x] **`.id(pendingInteractionToken)` only covered the approval branch**, so a secret prompt
      replacing another carried the typed password over. Moved to `pendingCard` at the call site.
      `pendingInteractionToken` is now `public internal(set)` with a public `present(_:)`.
- [x] **`ApprovalRequest: Hashable`** was vestigial with a comment describing the deleted design →
      back to `Equatable`.
- [x] **landscape with the keyboard up**: the plan's claim that the 88pt floor kept the buttons
      inside the window "in every configuration measured, portrait and landscape" is **false** —
      measured at 568×200 the composer was already 26pt off screen *before* this branch (44pt
      after, the card being ~250pt compressed against ~100pt of fixed region). It cannot be fixed
      by tuning: a card plus a composer does not fit. Documented as a limitation with the right
      precedence (Deny/Approve stay inside the window; the composer is what yields) and pinned by a
      compressed-fitting-size test so it cannot drift further. ⚠️ **The precedence claim's stated
      justification — "the composer is disabled while a card is up" — was itself false, and the
      landscape claim had no test. Both fixed in Task 3e.**
- [x] tests: 22 measured cases (was 16). New: the command's painted band on the shortest screen
      and against an unbounded detail, the command band at AX sizes, the transcript's height, the
      clarify card's transcript share, the Approve-title mirror, the claim arithmetic, the
      compressed fitting size. **Red-checked**: pre-fix content order → **7 failures, every one
      "0.0 lines of command"**; `claim = 1` → transcript 0.0 < 40; unscoped priority → clarify
      transcript 12.7 < 100. Green after, 22/22.
- [x] **known harness limitation** (measured identically before this branch, so not a regression):
      on the 320×352 window at AX3+ the card over-subscribes its container and the offscreen
      harness renders the region's content blank while reporting a viewport taller than the card is
      painted. The command-band assertions therefore run at 393×516 for AX sizes; the composer /
      button-row assertions still cover the short window.

### Task 3e: Fourth-round code-review fixes (claims the branch had not earned)

Two reviewers confirmed the mechanism is sound (the layout arithmetic, the nil-height probe, token
integrity across all five presentation paths, command-first ordering proven non-vacuously). What was
left was mostly **things documented as verified that were not**, plus one real regression in the
reserve.

- [x] **the composer was never disabled while a card is up** — three doc sites (the compressed-
      fitting-size test, CLAUDE.md, Task 3d above) justified the landscape trade-off with "the
      composer, disabled while a card is up, is what yields". `ComposerView` applies `.disabled`
      only to `sendButton`; the field stays editable and first responder, which is *why* the
      keyboard is up. So the 44pt going off screen there was the user's own focused input.
      Fixed at the root rather than in prose: **raising a card now hands the keyboard back**
      (`ChatView` → `ComposerView` → `ComposerTextView.blockingCardToken` → `resignFirstResponder`).
      A **resign, not a disable** — `canSend` is already false, but the field stays live so a draft
      is still possible — and keyed on `pendingInteractionToken`, not on `pendingInteraction != nil`:
      `ChatView` re-renders on every streamed token, and an unkeyed resign fires on each one, which
      bounces a user out of the field before they can type (a replacement card, which never passes
      through `nil`, still drops it). This is the cheapest room the whole branch buys — the keyboard
      is what shrinks the region the card lives in, i.e. #65's own root cause. Verified it does not
      touch the clarify/secret card's own field (a separate `TextField`/`SecureField` inside
      `ClarifyCardView`) and does not disable the interrupt button.
- [x] **`BoundedHeightLayout.claim` was a proportional reserve where a fixed one was wanted.** It
      applied unconditionally, so for `offer − 25% < natural ≤ offer` it cut a region that had room
      to fit: `height(natural: 320, offered: 320)` → 240, i.e. 80pt (about four `.callout` command
      lines) handed to a transcript that had not asked for it, on the surface whose rule is "the
      user must be able to read what they are approving". Replaced by an **absolute**
      `reserve` = `ApprovalCardView.transcriptReserve` (44pt, one HIG tap target). The band was
      constrained by no test in either direction — the roomy cases sit far under it and the squeezed
      ones land on the floor, which outranks both forms — so the arithmetic case now states the
      invariant over the whole band (`height ≥ min(wanted, offer − reserve)` and `≤ wanted`) rather
      than at sampled points. **Red-checked**: restoring the proportional form fails it (explicit
      cases plus ~hundreds of band points).
      Measured effect at 393×516 keyboard-up: region 155pt (was 149), transcript 44pt (was ~50).
- [x] **the landscape safety claim had no test**, and the floor had moved 88 → 96 *past* the
      previously-measured safe maximum. Added `testLandscapeWithTheKeyboardUpKeepsTheAnswerInsideTheWindow`
      at 568×200, `.large` + AX3. It asserts the **Deny/Approve row's own frame**, read off the
      **accessibility tree** — SwiftUI draws the buttons into a shared layer (no `UIView`), and the
      hosted scroll view is not a usable proxy here: once the card over-subscribes its container the
      backing `HostingScrollView` reports 141.7pt while the layout places 96 (the same harness
      artifact Task 3d filed for 320×352 at AX3+). The a11y frame is where a tap would actually
      land. Measured: row at y 151.7…186.0 in a 200pt window at `.large` — inside, with the
      composer 44pt out, exactly the documented precedence. **Red-checked**: at
      `contentMinHeight = 200` the row lands at 238/229.7 and both sizes fail. The same assertion
      was folded into `assertNothingIsPushedOffScreen`, so every composition test now checks the
      buttons directly instead of inferring them from the composer.
- [x] **the "three legible command lines" contract is `.large`-only** — the floor is deliberately
      unscaled, so the readable band is a constant 64pt while a `.callout` line is not (~20.9pt at
      `.large`, ~48 at AX3, ~69 at AX5). Qualified in the source doc, CLAUDE.md and here, and pinned
      by `testTheFloorsReadableBandDegradesWithDynamicType`, which measures the real font metric per
      content-size category: ≥3 lines at `.large`, ~1.3 at AX3, ~0.9 at AX5. **Not** fixed by
      scaling the floor: three AX5 lines are ~210pt, and reserving that on the shortest keyboard-up
      screen is measurably what pushes Deny/Approve off it (Task 3c measured that failure). The cap,
      not the floor, is what undoes the degradation as soon as the region has any room.
- [x] **stale doc comments**: `TranscriptLayout.shortestLayoutHeight` said the card's ceiling was
      "half of it" (it is `* 0.6`), and `BoundedHeightLayout`'s summary said "sizes to
      `min(natural, cap)` when there is room" without mentioning the reserve that overrides it.
- [x] **`pendingInteraction` is now `public internal(set)`**, so the "raise a card only through
      `present(_:)`" invariant is structural for everything outside HermesKit — the app target,
      which is where the carried-over-`@State` bug manifests, can no longer assign one without its
      token. [decision] **not** `private(set)`: ~20 `TestStore` expectation and initial-state sites
      across three HermesKit test files assign it directly, and rewriting them to `present(_:)`
      shifts every token expectation — churn with a real chance of masking a regression rather than
      catching one. No public dismissal mutator was added (nothing outside the module dismisses;
      dead API).
- [x] tests: 25 measured cases (was 22) + 2 in `ComposerTextViewTests`. New: the keyboard hand-back
      end to end through the real `ChatView` (raise → resign, re-focus → sticks across a re-render,
      replacement card → resign again), the landscape answer-row containment, the floor's Dynamic
      Type degradation, the reserve's band invariant; plus the coordinator's edge rule and a
      "a card standing at `makeUIView` does not fight a later focus" case in the composer suite.
- [x] validation: HermesKit 1017/1017 unchanged, `ApprovalCardLayoutTests` 25/25,
      `ComposerTextViewTests` 32/32. **One baseline re-recorded**: the absolute reserve gives the
      region ~298pt instead of ~257 inside `testApprovalCard_longCommandScrolls`'s pinned 460pt
      frame — about two more command lines, which is the point — so that PNG was re-recorded via
      the run-twice recipe (delete the one file, `make snapshot` records + fails by design,
      `make snapshot` again asserts clean). `testApprovalCard` / `_recovered` are unchanged.
      Proven to be the only render difference by running the **whole** `HermesMobileTests` suite
      at `HEAD` and on the branch and diffing the pass/fail set per test: identical apart from the
      new/renamed cases, all passing. `make snapshot` stays red only with the documented
      environment-wide drift (89 of it, unchanged in both runs).

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
