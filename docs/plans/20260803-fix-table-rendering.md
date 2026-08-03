# Fix chat Markdown table rendering (issue #59)

> ## ⚠️ MUST TRAVEL WITH THE PR DESCRIPTION — read before merging
>
> 1. **The 6 new table snapshot baselines were recorded on a different iOS runtime (26.5)**
>    than the other 121 in `__Snapshots__/`. `scripts/snapshot.sh` only pins the *major*
>    version, so nothing catches the mismatch: **on any machine where the other 121 pass,
>    these 6 will fail**, and on this machine the reverse (92 pre-existing failures on a
>    clean checkout too). They **must not be deleted or re-recorded** here — fold them into
>    the next deliberate global `make snapshot-record`. Details under *Known caveats* below.
> 2. **Two things are still unverified and need a device before #59 is closed**:
>    text selection inside table cells (gesture arbitration — the code change made so far is
>    a no-op by construction), and the intermittent gap under **live streaming/hydration**
>    (the automated guard measures width-invariance, which is a proxy, not the symptom).
>    Both are itemised under *Post-Completion → Manual verification*.

## Overview
- Fixes GitHub issue #59: chat tables render with a large intermittent blank gap
  above/below the table, and wide tables get clipped at the screen edge with cell
  content truncated.
- Root cause is the view layer, not parsing: `MarkdownText.tableView` renders a
  SwiftUI `Grid` where every cell is `.frame(maxWidth: .infinity)` — all columns
  claim equal flexible width, nothing constrains the grid to the screen width (so a
  wide table overflows and clips), and the grid's unstable measured size inside the
  `UIHostingConfiguration`-hosted `UICollectionView` cell produces the phantom
  vertical gap.
- Fix (chosen approach — "scrollable inline"): size columns to their content with a
  per-column max width so long cells wrap at a readable measure, and wrap the grid
  in a horizontal `ScrollView` so a table wider than the screen pans instead of
  clipping. A table that fits renders inline with no panning. The content-derived
  stable size also cures the self-sizing gap.

## Context (from discovery)
- Files/components involved:
  - `HermesMobile/Sources/Features/Chat/MarkdownText.swift` — `tableView(headers:rows:)`
    at ~line 97 is the broken renderer; `inline(_:)` supplies per-cell AttributedStrings.
  - `HermesMobile/Sources/Features/Chat/Transcript/CollectionTranscriptView.swift` —
    hosts rows in self-sizing `UIHostingConfiguration` cells (where the gap manifests);
    not expected to change.
  - `HermesKit/Sources/HermesKit/Models/MarkdownSegment.swift` — `.table` parsing is
    correct and well-tested (`MarkdownSegmentTests`); untouched.
  - `HermesMobileTests/` — snapshot suite; no existing table snapshot coverage.
- Related patterns found: block rendering is structured per-segment in `MarkdownText`;
  selection comes from the parent `.textSelection(.enabled)`; snapshot tests are the
  required regression net for view changes (reducer tests can't catch layout).
- Dependencies identified: none new. Deployment target iOS 18, so
  `.scrollBounceBehavior(.basedOnSize)` and other modern scroll APIs are directly
  available.

## Development Approach
- **testing approach**: Regular (code first, then tests) — per user choice.
- complete each task fully before moving to the next
- make small, focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
  - tests are not optional - they are a required part of the checklist
  - snapshot tests are the unit-test equivalent for this view-only change (project
    convention: they catch view regressions reducer tests can't)
  - tests cover both the overflow (wide table) and the fits-inline (small table) cases
- **CRITICAL: all tests must pass before starting next task** - no exceptions
- **CRITICAL: update this plan file when scope changes during implementation**
- run tests after each change
- maintain backward compatibility (small tables should look essentially unchanged)

## Testing Strategy
- **unit tests**: parsing already covered in HermesKit (`MarkdownSegmentTests`); no
  parser change, so no new HermesKit tests expected.
- **snapshot tests**: the primary net for this change (`HermesMobileTests`). New
  snapshots for a wide/long-content table (the issue's repro) and a small table.
  Convention for adding new snapshots without a global re-record: run `make snapshot`
  **twice** — first run records the missing baselines and fails by design, second run
  asserts clean. Never use `make snapshot-record` (it wipes and re-records every
  baseline).
- **e2e tests**: none in this project; manual verification on simulator/device is a
  post-completion item.

## Progress Tracking
- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- update plan if implementation deviates from original scope
- keep plan in sync with actual work done

## Solution Overview
- Extract table rendering into a dedicated `MarkdownTableView` (view-layer, thin —
  no reducer/HermesKit change) used by `MarkdownText` for the `.table` segment.
- Column sizing: each cell keeps left alignment and inline Markdown, but instead of
  `.frame(maxWidth: .infinity)` it gets a **content-derived width capped at a
  per-column max** (~260pt): `.frame(maxWidth: tableColumnMaxWidth, alignment: .leading)`
  combined with `.fixedSize(horizontal: false, vertical: true)` so short cells take
  their natural width, and long cells wrap at the cap instead of being squeezed into
  equal flexible columns.
- Overflow: the `Grid` sits inside `ScrollView(.horizontal)` with
  `.scrollBounceBehavior(.basedOnSize)` — a fitting table neither pans nor bounces;
  a wide one pans horizontally instead of clipping. A horizontal `ScrollView` sizes
  its height to the content, giving the hosting cell a stable measured height (the
  gap fix).
- Selection: cells keep working with the parent `.textSelection(.enabled)` (verify;
  if the `ScrollView` breaks inheritance, re-apply `.textSelection(.enabled)` inside
  `MarkdownTableView`).
  **DEFERRED — device check required (still open at review iteration 4).** Neither branch of
  this conditional was actually executed: the "verify" branch needs a device gesture no test
  here can drive, and the "inheritance is broken" precondition was never established. What
  *was* done is unconditional and, by construction, a **no-op**: `MarkdownTableView` re-applies
  `.textSelection(.enabled)` on its own `Grid`, but `.textSelection` is an **Environment** value
  that `MarkdownText` already applies at the root of the same hierarchy, and `ScrollView` does
  not reset the environment — which is exactly why it measured size-neutral with all six
  baselines byte-identical. Keep the modifier (it costs nothing and removes any doubt about
  inheritance), but it addresses only the inheritance half. The half that matters — whether the
  selection gesture beats the collection view's and the table's own pan recognisers — is
  **untested**, and stays the on-device check below (a blocker for closing #59).

## Technical Details
- `MarkdownTableView(headers: [String], rows: [[String]])` renders:
  - header `GridRow` (semibold) + `Divider()` + body `GridRow`s, exactly today's
    structure, `alignment: .leadingFirstTextBaseline`, spacing 12/6 preserved;
  - per-cell: `Text(inline(...)).frame(maxWidth: 260, alignment: .leading)`
    `.fixedSize(horizontal: false, vertical: true)`;
  - the inline-Markdown helper either moves to a shared internal helper or is passed
    in — prefer duplicating the 3-line `inline(_:)` into the new view over widening
    `MarkdownText`'s API (it's a trivial, stable snippet).
  - the cap lives in a named constant (e.g. `tableColumnMaxWidth: CGFloat = 260`)
    with a comment explaining the readable-measure rationale.
- `MarkdownText.tableView` body is replaced by `MarkdownTableView(headers:rows:)`.
- Missing cells (ragged rows) keep today's behavior: pad with empty strings up to
  `max(headers.count, widest row)`.
- New source file ⇒ **`tuist generate` required** before any `xcodebuild`-based run
  (sources are globbed at generation time); `scripts/snapshot.sh` — verify it
  regenerates, run `make generate` first if not.

## What Goes Where
- **Implementation Steps** (`[ ]` checkboxes): view extraction + sizing fix + snapshot
  coverage + docs, all in this repo.
- **Post-Completion** (no checkboxes): manual on-device verification of the
  intermittent-gap symptom and the issue's exact repro prompt; closing issue #59.

## Implementation Steps

### Task 1: Extract MarkdownTableView with capped columns + horizontal scrolling

**Files:**
- Create: `HermesMobile/Sources/Features/Chat/MarkdownTableView.swift`
- Modify: `HermesMobile/Sources/Features/Chat/MarkdownText.swift`

- [x] create `MarkdownTableView` rendering the existing `Grid` structure with
      per-cell content-derived width capped at `MarkdownTableView.columnMaxWidth`
      instead of `.frame(maxWidth: .infinity)`
- [x] wrap the grid in `ScrollView(.horizontal)` with
      `.scrollBounceBehavior(.basedOnSize)`; confirm the view's height hugs the
      content (no vertical stretch)
- [x] replace `MarkdownText.tableView`'s body with `MarkdownTableView(headers:rows:)`
      and delete the old grid code
- [x] run `tuist generate` so the new file joins the app target
- [x] build the app target + run `make snapshot` — no NEW failures introduced (see ⚠️
      below: the baselines are already stale repo-wide on the only installed runtime)

⚠️ **Deviation (measured, not stylistic): `.frame(maxWidth:)` cannot cap a cell inside a
horizontal `ScrollView`.** A scroll view proposes `nil` width along its scroll axis
(verified with a probe `Layout` that printed the proposals), and a flexible frame answering
a `nil` proposal passes `nil` straight to its child — so the `Text` reports its full
single-line width and is merely *clipped* to the clamped frame: measured 260×16pt for a
3-line-worth sentence, i.e. exactly the truncation issue #59 is about. Replaced with a tiny
`CappedWidthLayout` (in the same file) that proposes the cap explicitly and reports the size
the `Text` actually wanted: long cell → 253×48 (wraps), short cell → 13×16 (natural width,
so a small table stays inline and pan-free). Constant renamed
`tableColumnMaxWidth` → `MarkdownTableView.columnMaxWidth` (it is already namespaced by the
type). Measured table sizes: wide 4-column table → 457pt content in a 390pt viewport (pans),
2×2 table → 31pt (no pan); heights hug content in all cases.

⚠️ **Pre-existing snapshot drift, unrelated to this change.** `make snapshot` fails 92 of
127 tests **on a clean checkout too** (verified by stashing the change and re-running):
`scripts/snapshot.sh` pins iOS 26 and the only installed `iPhone 17 Pro` runtime is now
26.5, while the baselines were recorded on an earlier 26.x. The failing-test set is
**byte-identical before and after this change** (35 passed / 92 failed both ways), so the
change introduces no regression. A global re-record (`make snapshot-record`) is a separate,
deliberate decision — out of scope here — but it blocks the "record only the new PNGs"
convention Task 2 relies on; Task 2 must decide how to record its new baselines given a
suite that cannot go green on this machine.

### Task 2: Snapshot coverage for wide and small tables

**Files:**
- Create: `HermesMobileTests/MarkdownTableSnapshotTests.swift`
- Create: `HermesMobileTests/__Snapshots__/MarkdownTableSnapshotTests/` (recorded PNGs)

- [x] add a snapshot test rendering `MarkdownText` with the issue's repro shape: a
      4-column table whose "long content" column holds multi-sentence text (must show
      wrapped-at-cap cells, no clipping at the trailing edge, no ellipsis truncation)
      — `testMarkdownTable_wideLongContent` (pinned to the device width, i.e. what the
      transcript cell measures) plus ➕ `testMarkdownTable_wideContentUnclipped`
- [x] add a snapshot test with a small table (e.g. 2×2) verifying it renders inline,
      natural column widths, no visual regression vs today's layout intent
- [x] add a snapshot test for a ragged table (row with fewer cells than headers) to
      lock in the empty-cell padding behavior (short row pads, long row widens)
- [x] record baselines via the run-`make snapshot`-twice convention (first run
      records + fails, second asserts clean); commit only the new PNGs
- [x] run `make snapshot` — [x] the 4 NEW table tests pass; the suite as a whole cannot
      go green on this machine (see ⚠️ below). Measured: 92 failed / 35 passed **before**
      this task, 92 failed / 39 passed **after** — the failing test set is byte-identical
      (`diff` of the two failing-name lists is empty), so no new failure was introduced.

➕ **Added a 4th case, `testMarkdownTable_wideContentUnclipped`.** The device-width shot can
only ever capture the first screenful of a table that pans, so on its own it cannot
distinguish "panned" from "truncated" — it is the case the issue is about, but not proof.
The extra case renders `MarkdownTableView` in a viewport wider than its content, showing the
whole grid: every cell complete, no ellipsis, the long column wrapped at `columnMaxWidth`
while `Type`/`Required` keep their natural widths.

⚠️ **`.sizeThatFits` collapses a horizontal `ScrollView` to zero width** (first recording of
the unclipped case came out an empty 60×645 sliver). The compressed-fit render proposes a
zero-width fit, and the scroll view is flexible along its scroll axis, so it takes it —
hence every case here pins an explicit width (`device.size.width` for the in-transcript
cases, 700pt for the unclipped one). Not a regression in the view; a property of the
snapshot layout mode.

⚠️ **`make snapshot` was NOT run in `RECORD=1` mode** (that wipes and re-records all 127
baselines — out of scope, and it would bury this fix in an unrelated global re-render).
Baselines came from the documented run-twice convention: the missing PNGs record on the
first run and fail by design, the second run asserts them clean. Only the 4 new PNGs are
committed; no pre-existing baseline was touched.

### Task 3: Verify acceptance criteria

**Files:**
- Create: `HermesMobileTests/MarkdownTableLayoutTests.swift` (measured layout assertions)
- Modify: `HermesMobileTests/MarkdownTableSnapshotTests.swift` (+ 2 edge-case cases)
- Create: 2 new baselines under `HermesMobileTests/__Snapshots__/MarkdownTableSnapshotTests/`

- [x] verify all requirements from Overview are implemented: no horizontal clipping,
      no cell truncation, wide tables pan horizontally, fitting tables don't pan
      — **measured**, not asserted from reading code (see ➕ below): new
      `MarkdownTableLayoutTests` hosts the real view, forces layout, and reads the
      resulting `UIScrollView`
- [x] verify edge cases: ragged rows, single-column table, table mid-prose
      (surrounded by other segments), dark mode snapshot appearance
      — ragged already covered by Task 2; added `testMarkdownTable_singleColumn` and
      `testMarkdownTable_midProse` (+ the measured
      `testSingleColumnTableWrapsAndDoesNotPan`). **Dark mode needed no new case**:
      `SnapshotTestCase.componentImage()` pins `UITraitCollection(userInterfaceStyle: .dark)`,
      so all six table baselines already *are* dark-mode renders (verified by inspecting the
      PNGs — black ground, white text, the `Divider` visible); `MarkdownTableView` sets no
      colour of its own, so nothing can diverge per appearance.
- [x] run full HermesKit suite: `script -q /dev/null swift test --package-path HermesKit`
      — **1016 tests in 57 suites, 0 failures**
- [x] run full snapshot suite: `make snapshot` — **all 12 table tests pass and the
      pre-existing failure set is unchanged**; the suite as a whole still cannot go green
      on this machine (the ⚠️ under Task 1). Measured: 139 executed / 92 failed after this
      task vs 92 failed before it, and a `diff` of the two failing-name lists is **empty**
      — every added test passes, no NEW failure. `make snapshot-record` was deliberately
      NOT run (it would re-record all 127 baselines — out of scope).
- [x] ~~build and launch in the simulator with the issue's repro prompt~~ **(skipped —
      requires a live Hermes agent to prompt; there is none reachable from this
      environment).** Covered instead by the automated equivalents: the repro-shaped table
      is rendered end-to-end through `MarkdownText` at device width
      (`testMarkdownTable_wideLongContent`), at full content width
      (`testMarkdownTable_wideContentUnclipped`), and measured for pan + height-hug
      (`testWideTablePansHorizontallyInsteadOfClipping`, `testTableHeightHugsItsContent`).
      The intermittent-gap symptom under **live streaming** specifically remains a
      Post-Completion manual item (it is a self-sizing artefact of streaming + hydration).

➕ **Added `MarkdownTableLayoutTests` — snapshots alone cannot prove "no clipping".** A
device-width shot of a panning table and a shot of a *truncated* one are the same first
screenful, so the snapshot can only ever be corroborating evidence. These six tests host
`MarkdownTableView` in a real `UIWindow`, force a layout pass and read the numbers off the
`UIScrollView` it produces: the wide table has `contentSize.width > bounds.width` (the
off-screen columns still exist → it pans), the 2×2 and the single-column tables have
`contentSize.width <= bounds.width` (nothing to pan), and the hosted height equals
`contentSize.height` within 2pt (the phantom gap #59 reported). Two more pin
`CappedWidthLayout`'s contract directly under the unbounded proposal a horizontal
`ScrollView` gives its content: a long cell comes back capped in width and **taller** than
its unconstrained single line (it wrapped — it was not truncated), while a short cell keeps
its natural width (< 80pt), which is what keeps a small table inline.

### Task 4: [Final] Update documentation

- [x] update `CLAUDE.md`'s chat-Markdown bullet (#27) to note tables render via
      `MarkdownTableView` (capped columns, horizontal scroll) — extended in the file's
      house style: the pan-vs-clip contract, `CappedWidthLayout` and the measured reason
      `.frame(maxWidth:)` cannot replace it (260×16pt clip under a `nil` proposal), the
      stable-size cure for the self-sizing gap, and the measured
      `MarkdownTableLayoutTests` net (a device-width snapshot cannot distinguish a
      panning table from a truncated one)
- [x] move this plan to `docs/plans/completed/` *(performed by the exec orchestrator after
      the review phases — the remaining review phases reference the plan at this path)*

➕ **Review follow-ups (phase 1).** Three reviewers flagged the `min(size.width, limit)` clamp
in `CappedWidthLayout.sizeThatFits` and proposed three different fixes. All three rest on
premises that **measurement refutes** (probe run in the simulator, then deleted):
`Text` does *not* ellipsise an unbreakable run at the cap — it character-wraps (an 80-char
token → 259.7×64pt, three lines), so the clamp never fires; and `subview.sizeThatFits(.zero)`
returns `(0, 0)` for a `Text`, not "the longest unbreakable run", so measuring a minimum
width from it is a no-op. What *is* real is the zero-proposal hazard: `Text` answers a
zero-width proposal with 0pt × ~1780pt, and the old code forwarded that verbatim. Resolved by
deleting the proposal from the calculation entirely — the layout always proposes the cap and
returns the child's own (unclamped) answer, which fixes the dishonest minimum, keeps the
unbreakable-token case wrapping, and makes the reported size provably width-invariant (the
mechanism behind the phantom-gap half of the fix, now asserted directly). Also from review:
the cap became `@ScaledMetric` (Dynamic Type; measured 260pt at `.large` → no baseline drift,
567pt at `.accessibility3`); a trailing fade now marks a table that still has content to the
right (the only visual difference between "pans" and "clipped"); the dead
`.frame(maxWidth: .infinity)` was removed after measuring it to be a no-op; and
`MarkdownTableLayoutTests` was rebuilt so it actually guards the cap — verified by reverting
`cell(_:isHeader:)` to the `.frame(maxWidth: 260)` recipe, which now turns **three** tests red
(it previously turned none red).

➕ **Review follow-ups (phase 1, iteration 2).** The two critical reviewers **directly
contradicted each other** on the `@ScaledMetric` cap — one called it a major accessibility
regression, the other a deliberate trade-off. Settled by measurement in the simulator
(throwaway XCTest, deleted), not by argument:

| | `.large` | `.accessibility1` | `.accessibility3` | `.accessibility5` |
|---|---|---|---|---|
| scaled cap (unclamped) | 260.0 | 401.7 | 567.3 | 732.7 |
| 1-column prose table content width | 260.0 | 391.7 | 554.0 | 728.0 |
| pans on a 358pt transcript? | no | **yes** | **yes** | **yes** |

The usable transcript width really is 358pt (390pt device − the collection view's 16pt
section insets), so the regression is real: from AX1 up, a **single-column** table — the one
shape that cannot overflow by construction — forced horizontal panning to read one line of
prose. But the reverse trade-off is real too: at a fixed 260pt cap the same sentence measures
336pt tall at AX3 and 683pt at AX5, versus 240pt/435pt when the cap is allowed to grow to the
screen. **Clamping wins on both axes** — it reads without panning *and* is shorter than the
fixed cap — so `columnMaxWidthCeiling` (343pt = narrowest iOS-18 iPhone, 375pt, minus the
32pt of insets) now caps the scaled value. It is a **constant**, not the offered width, so the
proposal-independence the phantom-gap fix rests on is untouched. `.large` is unaffected
(`min(260, 343) == 260`) → zero baseline drift. `testColumnCapScalesWithDynamicType`, which
*asserted the overflow itself*, was replaced by
`testColumnCapGrowsWithDynamicTypeButNeverPastTheCeiling` +
`testSingleColumnTableNeverPansAtAccessibilitySizes`; both go red if the clamp is removed
(verified).

Also from iteration 2: the **gap half of #59 is now measured on the real host path** —
`testTableRowMeasuresTheSameHeightOnEveryHostingConfigurationPass` builds the exact
`UIHostingConfiguration` the transcript's cell registration builds and asks it the same
`systemLayoutSizeFitting` question the collection view does, over repeated passes and at
320/358/390pt. Verified red against the pre-fix renderer: it measured **743.7pt at 320pt and
589.7pt at 358pt** for identical content — a 154pt swing, which *is* the blank band. The
trailing-fade rule moved to `ScrollGeometry.visibleRect.maxX` (inset-correct; measured with a
20pt inset the old `contentOffset + containerSize` pair reports 298 where the content is
really visible to 338, i.e. a permanent fade on a table that fits). The mask's leading half
is now explicitly `.fill(Color.black)`: the reviewer's "an unfilled `Rectangle()` inherits the
ambient `foregroundStyle` and would dim the whole table" is a **false positive** — measured,
an unfilled shape in a `.mask` renders at full alpha under a half-alpha ambient style
(255/255) while an explicit half-alpha *fill* masks to 128/255 — but the explicit fill costs
nothing and puts both halves of the mask on the same footing.

### Review iteration 3 — the ceiling was derived from the wrong narrowest device

Both reviewers independently found `columnMaxWidthCeiling = 343` wrong: 375pt is the narrowest
*default* iPhone width, but **Display Zoom** renders every iOS-18 iPhone at **320pt logical**
(SE 2/3 320×568, X-class and later 320×693), i.e. a **288pt** transcript row. Measured on a
288pt viewport with the 343pt ceiling, a single-column table's content width is 260.0 (`.large`)
/ 278.3 (`.xLarge`) / **307.3** (`.xxLarge`) / **337.3** (`.xxxLarge`) / **343** (AX1+) — it pans
from `.xxLarge` up, which is exactly the regression the ceiling exists to prevent. Fixed with the
simple option: `columnMaxWidthCeiling = 288`. The container-width-via-`EnvironmentKey` option was
declined deliberately — it touches `ChatView`/`MessageBubbleView` and puts the branch's core
width-invariance invariant at risk for a readable-measure gain, and a correct constant beats an
elegant regression. `.large` is still untouched (`min(260, 288) == 260`) → zero baseline drift.
`testSingleColumnTableNeverPansAtAccessibilitySizes` now measures at **both** 288pt and 358pt
across seven text sizes; verified red at 288pt if the ceiling goes back to 343.

The host-path test was settled by measurement too. Its "same width, four repeated passes" block
was **measured unfailable**: four `systemLayoutSizeFitting` calls on one unchanged content view
return the identical height even for deliberately width-*dependent* prose content (264.0 ×4 at
358pt, while a fresh instance at 320pt gives 308.0) — so it was removed. In its place the test
now drives the real thing: `TranscriptCellHarness` builds a `UICollectionView` with the
transcript's `.estimated(60)` self-sizing compositional layout and its
`UIHostingConfiguration`-cell registration, in a window, and reads the laid-out row frame at a
390pt collection (358pt row), at 320pt (288pt row), and after `reconfigureItems`. It is
self-validating: a prose control through the same harness reports 264pt vs 352pt, so the table's
equal-height verdict is a measurement, not a tautology. Verified red against the pre-fix renderer
(no `ScrollView`, equal-flexible columns): **831.7pt at 288pt vs 589.7pt at 358pt**, a 242pt
swing — the blank band. The `hostedCellContentView` doc overclaim ("the exact
`UIHostingConfiguration` the collection view's cell registration builds" — `ChatView.rowView` adds
a `VStack` + `MessageActionBar`) went away with the helper.

Two doc comments were also narrowed to what was actually measured: `hasTrailingOverflow`'s
content-inset rationale (insets are zero here; the inset case was never measured, and Apple's
`visibleRect` definition may make the old note backwards) and the `.mask` note (the unfilled-shape
observation was one measured configuration, not a general SwiftUI rule).

## Post-Completion
*Items requiring manual intervention or external systems - no checkboxes, informational only*

**Manual verification:**
- On-device check of the intermittent top/bottom gap. The automated guard
  (`testTableRowKeepsOneHeightAcrossRelayouts`, a real `UICollectionView` +
  `UIHostingConfiguration` cell) asserts **width-invariance of the measured height** — a
  **proxy**, not a reproduction: the reported symptom is measured height ≠ displayed height at
  ONE width, and the harness's prose control proves the two are different properties (ordinary
  prose rows *are* width-dependent and never showed a gap). So it is a solid revert-guard on the
  renderer shape, and **the symptom itself is still only verified by eye — live streaming and
  hydration need a device**: stream a table response live (not just hydrated), scroll away and back so
  the cell is recycled, and background/foreground the app, confirming the cell height stays
  tight and no blank band appears above or below the table.
- **Interactive pop-back near the leading edge**: the table's horizontal `UIScrollView`
  starts ~16pt from the screen edge, a classic conflict with the `NavigationStack` swipe-back
  gesture. Swipe back from the left edge while a wide table is on screen and confirm the pop
  still wins.
- **Cell reuse and the trailing fade**: scroll a wide (fading) table off screen and a fitting
  table into the same recycled cell; the fade must not persist on the fitting table beyond
  the first frame (`trailingOverflow` is `@State` inside a `UIHostingConfiguration` cell).
- ⚠️ **BLOCKER FOR CLOSING #59 — text selection inside table cells is UNVERIFIED.** A
  documented product contract ("the assistant Markdown is fully selectable", CLAUDE.md #27)
  has **never been checked for table cells**, on this branch or before it. It needs a device
  gesture, which no automated test in this repo can drive, so it cannot be discharged here.
  What *was* done (iteration 3): `MarkdownTableView` now re-applies `.textSelection(.enabled)`
  on its own `Grid`. That is belt-and-braces, **not** a fix — `.textSelection` is an Environment
  value already applied by `MarkdownText` at the root of the same hierarchy and `ScrollView`
  does not reset the environment, so the re-application is a no-op (hence: measured
  size-neutral, layout tests and all six baselines unchanged). It rules inheritance out as a
  suspect; it does not touch the gesture. What remains unproven is the gesture itself:
  long-press-drag a table cell in the transcript and confirm a selection starts. Cells are
  plain `Text`, and `SelectableText`'s doc comment records that `.textSelection(.enabled)` is
  unreliable inside the `UICollectionView` transcript; the table adds one more competing pan
  recogniser. Routing cells through `SelectableText` (as prose does) is **not** a drop-in fix:
  its `sizeThatFits` returns the *proposed* width verbatim, so every cell would claim the full
  cap and small tables would stop rendering inline — the contract this fix exists to establish.
  If the gesture does fail on device, the fix is to widen `SelectableText` with a natural-width
  mode. Until this check happens, `MarkdownText.swift` and CLAUDE.md are worded to claim only
  prose selection as guaranteed — keep them that way.
- Close GitHub issue #59 with a before/after screenshot once verified.

**Known caveats travelling with the PR:**
- **The 6 table baselines were recorded on iOS 26.5**, while the other 121 in
  `__Snapshots__/` came from an earlier 26.x. `scripts/snapshot.sh` only guards the *major*
  version (`SIM_OS=26`), so nothing catches the mismatch. On this machine that is why
  `make snapshot` reports 92 pre-existing failures on a **clean checkout too** (verified by
  stashing); the table baselines are the ones that pass here and would be the ones to fail
  on a machine where the other 121 pass. They cannot be re-recorded correctly from this
  environment (the older runtime is not installed) and must **not** be deleted — fold them
  into the pending global `make snapshot-record` whenever that deliberate re-record happens.
- `testMarkdownTable_wideLongContent.1.png` was re-recorded once during review to pick up
  the new trailing fade. The other five baselines are byte-identical to their first
  recording, which is also the evidence that the fade mask is a genuine no-op for a table
  that fits.

**Deferred (out of scope, by approach decision):**
- "Tap to open" full-screen table viewer (issue's Option B) — can be layered on later
  if very large tables still feel cramped when panning; would need presentation state
  plumbed to `ChatView` (sheets can't present cleanly from a
  `UIHostingConfiguration` cell).
