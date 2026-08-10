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

- [ ] extract the command block into a private builder: `ScrollView` +
      `fixedSize`d `Text` + `onGeometryChange` height measurement +
      `.frame(height: min(measured, cap))` (maxHeight fallback pre-measurement) +
      `.scrollBounceBehavior(.basedOnSize)`
- [ ] add the `@ScaledMetric` cap and the overflow-only bottom fade mask
- [ ] document on the type why the explicit measured frame exists (the `VStack`
      compression story) — the constraint the code can't show
- [ ] update/extend snapshots: existing short-command card stays byte-identical;
      add a long-command card at a pinned explicit frame (fade + first screenful);
      record new baselines via `make snapshot` run twice
- [ ] run `make snapshot` — must pass before task 2

### Task 2: Measured layout tests for the command block

**Files:**
- Create: `HermesMobileTests/ApprovalCardLayoutTests.swift`

- [ ] host the card in a `UIWindow` (follow `MarkdownTableLayoutTests` harness:
      hosting controller, forced layout, `.dynamicTypeSize(.large)` pinned)
- [ ] long command in a height-constrained host: the block's `UIScrollView` has
      `contentSize.height > bounds.height` (full content present, scrollable) AND
      the card's `sizeThatFits` height stays ≤ the constraint (buttons never pushed
      out)
- [ ] short command: block height equals content height (±1pt) — no dead space, no
      scroll (`contentSize.height <= bounds.height`)
- [ ] recovered card (`command == nil`): no scroll view in the hierarchy; card
      height unchanged by this work
- [ ] control test proving the harness can go red (e.g. assert a deliberately
      uncapped variant would exceed the constraint — mirror the prose control in
      `MarkdownTableLayoutTests`)
- [ ] run the `HermesMobileTests` suite — must pass before task 3

### Task 3: Verify acceptance criteria

- [ ] long command + tight vertical space: command fully readable by scrolling,
      Approve/Deny on screen, fade shown
- [ ] short command: rendering pixel-identical to before (snapshots unchanged)
- [ ] recovered/no-command card untouched
- [ ] full suites green: `script -q /dev/null swift test --package-path HermesKit`
      (unchanged, sanity), `make snapshot`, and the layout tests

### Task 4: [Final] Update documentation

- [ ] add a CLAUDE.md line to the approval-card conventions: the command block is a
      measured, capped, scrollable region (never bare `Text` in the fixed `VStack`
      region) with the fade + `@ScaledMetric` rationale
- [ ] comment on issue #65 with the root cause + fix; close after device check
- [ ] move this plan to `docs/plans/completed/`

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
