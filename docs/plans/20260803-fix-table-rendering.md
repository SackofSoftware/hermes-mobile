# Fix chat Markdown table rendering (issue #59)

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

- [ ] create `MarkdownTableView` rendering the existing `Grid` structure with
      per-cell `.frame(maxWidth: tableColumnMaxWidth, alignment: .leading)` +
      `.fixedSize(horizontal: false, vertical: true)` instead of
      `.frame(maxWidth: .infinity)`
- [ ] wrap the grid in `ScrollView(.horizontal)` with
      `.scrollBounceBehavior(.basedOnSize)`; confirm the view's height hugs the
      content (no vertical stretch)
- [ ] replace `MarkdownText.tableView`'s body with `MarkdownTableView(headers:rows:)`
      and delete the old grid code
- [ ] run `tuist generate` so the new file joins the app target
- [ ] build the app target + run `make snapshot` — existing baselines must still pass
      (any diff in existing chat snapshots must be inspected and justified before
      proceeding)

### Task 2: Snapshot coverage for wide and small tables

**Files:**
- Create: `HermesMobileTests/MarkdownTableSnapshotTests.swift`
- Create: `HermesMobileTests/__Snapshots__/MarkdownTableSnapshotTests/` (recorded PNGs)

- [ ] add a snapshot test rendering `MarkdownText` with the issue's repro shape: a
      4-column table whose "long content" column holds multi-sentence text (must show
      wrapped-at-cap cells, no clipping at the trailing edge, no ellipsis truncation)
- [ ] add a snapshot test with a small table (e.g. 2×2) verifying it renders inline,
      natural column widths, no visual regression vs today's layout intent
- [ ] add a snapshot test for a ragged table (row with fewer cells than headers) to
      lock in the empty-cell padding behavior
- [ ] record baselines via the run-`make snapshot`-twice convention (first run
      records + fails, second asserts clean); commit only the new PNGs
- [ ] run `make snapshot` — full suite must pass before task 3

### Task 3: Verify acceptance criteria

- [ ] verify all requirements from Overview are implemented: no horizontal clipping,
      no cell truncation, wide tables pan horizontally, fitting tables don't pan
- [ ] verify edge cases: ragged rows, single-column table, table mid-prose
      (surrounded by other segments), dark mode snapshot appearance
- [ ] run full HermesKit suite: `script -q /dev/null swift test --package-path HermesKit`
- [ ] run full snapshot suite: `make snapshot`
- [ ] build and launch in the simulator with the issue's repro prompt ("Render a
      table as an example with long content...") and confirm the gap and cutoff are
      gone (the gap was intermittent — exercise open/scroll/re-open)

### Task 4: [Final] Update documentation

- [ ] update `CLAUDE.md`'s chat-Markdown bullet (#27) to note tables render via
      `MarkdownTableView` (capped columns, horizontal scroll)
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion
*Items requiring manual intervention or external systems - no checkboxes, informational only*

**Manual verification:**
- On-device check of the intermittent top/bottom gap: it's a self-sizing artifact of
  live streaming + hydration, so also stream a table response live (not just
  hydrated) and background/foreground the app to confirm the cell height stays tight.
- Close GitHub issue #59 with a before/after screenshot once verified.

**Deferred (out of scope, by approach decision):**
- "Tap to open" full-screen table viewer (issue's Option B) — can be layered on later
  if very large tables still feel cramped when panning; would need presentation state
  plumbed to `ChatView` (sheets can't present cleanly from a
  `UIHostingConfiguration` cell).
