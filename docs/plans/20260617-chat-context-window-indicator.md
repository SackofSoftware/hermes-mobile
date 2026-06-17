# Chat context window indicator

Resolves GitHub issue #4 — "Show context window size/left at the chat screen".

## Overview

Surface the agent's context-window usage (used / max, percent, cost) on the chat
screen, mirroring the Hermes TUI status-bar gauge. A compact pill sits in the
composer toolbar row beside the existing model/reasoning chip; tapping it expands a
popover with the full breakdown (used vs max, input/output split, compaction count,
estimated cost) plus a near-full nudge.

**Why this is mostly wire-up, not protocol work:** the `Usage` payload already arrives
and is already decoded — it rides on both the `session.info` event (`SessionInfo.usage`)
and `message.complete` (`payload.usage`), and the `Usage` struct already decodes
`context_used` / `context_max` / `context_percent` / `total` / `input` / `output` /
`cost_usd`. The reducer simply **drops** it today. We capture it into state, derive a
display model, and render it.

## Context (from discovery)

- **Files/components involved:**
  - `HermesKit/Sources/HermesKit/Models/GatewayEvent.swift` — `Usage` struct
    (`:93-110`), `SessionInfo.usage` (`:121`), `messageComplete(text:usage:)` (`:42`).
    Usage already fully decoded; no decoder changes needed.
  - `HermesKit/Sources/HermesKit/Features/ChatFeature.swift` — `State` (model/effort at
    `:31-32`); `.messageComplete(text, _)` discards usage (`:742`); `.sessionInfo` reads
    only model/effort (`:831-836`).
  - `HermesMobile/Sources/Features/Chat/ComposerView.swift` — the model chip lives in the
    composer toolbar `HStack` (`:55-56`), `modelChip` at `:129`, `modelLabel` at `:172`.
  - `HermesMobile/Sources/Features/Chat/ChatView.swift` — wires `ComposerView` (`:19-40`);
    passes `model`/`reasoningEffort` from the store.
  - `HermesMobile/Sources/Features/Chat/Color+Hermes.swift` — Color extension home.
- **Related patterns found:**
  - Partial `session.info`: overwrite a field only when present (model/effort precedent at
    `ChatFeature.swift:834-835`). Apply the same to usage.
  - Model chip is a tappable `Button` → `Capsule` background (`ComposerView.swift:130-144`).
  - Reduce-motion convention (session-list glow) — animate bar transitions, hold flat under
    reduce-motion.
  - A `public struct` nested in feature State needs an explicit `public init` to be built
    from the app/snapshot target.
- **Dependencies identified:** none new. No new clients, no protocol/RPC changes. (The
  on-demand `session.usage` RPC is **out of scope** — `session.info`/`message.complete`
  already deliver usage; we are not adding a fetch.)
- **TUI reference behavior (from issue):**
  - Label: `125k/200k` wide, `125k tok` narrow, `total tok` when no max known.
  - 10-char bar `█`/`░` filled by `context_percent`.
  - Color thresholds: `<50%` green, `≥50%` yellow, `>80%` amber, `≥95%` red.

## Development Approach

- **Testing approach: Regular** (code first, then tests) — matches the repo flow.
- Complete each task fully before the next; small, focused changes.
- **Every task includes new/updated tests.** Pure logic (formatter, color thresholds,
  display model) lives in `HermesKit` and is unit-tested via `swift test`; reducer changes
  via `TestStore`; the view via snapshot tests.
- **All tests pass before starting the next task.**
- Keep logic in `HermesKit`, views thin (project convention).
- Run tests after each change; maintain backward compatibility (usage is optional —
  absence must render gracefully, never crash).

## Testing Strategy

- **Unit tests (HermesKit `swift test`):**
  - `Usage` display derivation: `k`/`M` token formatting, `125k/200k` vs `125k tok` vs
    `total tok` fallbacks, percent → severity bucket thresholds, fraction clamping.
  - Reducer: `session.info` and `message.complete` carrying `usage` populate `state.usage`;
    partial `session.info` without usage does **not** clobber an existing value.
- **Snapshot tests (`make snapshot`, `HermesMobileTests/`):** the pill at a few fill levels
  (e.g. 40% / 85% / 97%), the unknown-max state, and the expanded detail popover. Re-record
  with `make snapshot-record` since this is an intentional UI addition.
- Run command for unit: `script -q /dev/null swift test --package-path HermesKit`
  (or `make test`). Snapshots: `make snapshot`.

## Progress Tracking

- Mark completed items `[x]` immediately.
- New tasks get a ➕ prefix; blockers get ⚠️.
- Keep this plan in sync if scope shifts.

## Solution Overview

1. **Derive, don't re-decode.** `Usage` already decodes the raw fields. Add a pure,
   testable display layer (`ContextUsageDisplay` or extension computed props on `Usage`) in
   HermesKit: formatted label, `0...1` fraction, and a `severity` enum mapping percent to
   the TUI thresholds. This keeps the view dumb and the thresholds unit-tested.
2. **Capture usage in the reducer.** `state.usage: Usage?`; set from `session.info` (only
   when present) and from `message.complete`.
3. **Render a compact pill** beside the model chip in `ComposerView`, tappable to a popover
   with the breakdown. Color from `severity`, paired with the numeric label (no color-only
   meaning); reduce-motion respected.

## Technical Details

- **Display model (HermesKit, pure):**
  - `Usage.tokenLabel` → `"125k/200k"` when `contextMax` present; `"125k tok"` when only
    `contextUsed`/`total` known; `nil`/empty when nothing known.
  - `Usage.contextFraction: Double?` → `contextPercent/100` clamped `0...1`, else
    `contextUsed/contextMax` when percent absent but both known; `nil` when max unknown.
  - `Usage.severity: ContextSeverity` (`.normal` `<50`, `.moderate` `≥50`, `.high` `>80`,
    `.critical` `≥95`) computed from `contextPercent` (fallback to fraction*100).
  - `formatTokens(_:)` → `k`/`M` compaction (e.g. `1_250 → "1k"`, `125_000 → "125k"`,
    `1_500_000 → "1.5M"`), mirroring TUI compact formatting.
  - Keep `compressions` available for the detail popover. ⚠️ Verify `Usage` actually decodes
    a `compressions`/compaction count; the issue lists it in `_get_usage()` but the current
    `Usage` struct (GatewayEvent.swift:93-110) does **not** declare it — if missing, add the
    optional field + `CodingKey` in Task 1 (lenient decode, no crash).
- **Color mapping (HermesMobile view):** `ContextSeverity` → `Color` (green / yellow /
  orange / red), defined alongside `Color+Hermes` or in the pill view. Logic-free switch;
  the *thresholds* are tested in HermesKit, the *color choice* is visual (snapshot).
- **Unknown-max state:** show `125k tok` text only, no bar/percent (avoids a misleading
  empty bar).

## What Goes Where

- **Implementation Steps** (`[ ]`): HermesKit display model + reducer wiring + tests; the
  SwiftUI pill + popover + snapshot tests; docs.
- **Post-Completion** (no checkboxes): on-device visual check on a real session, Dynamic
  Type / VoiceOver pass, `tuist generate` for any new app-target source file before an
  `xcodebuild`/device run.

## Implementation Steps

### Task 1: Context-usage display model in HermesKit

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Models/GatewayEvent.swift`
- Create: `HermesKit/Tests/HermesKitTests/ContextUsageTests.swift`

- [x] Add a `ContextSeverity` enum (`normal`/`moderate`/`high`/`critical`) — public, `Sendable`.
- [x] Add `formatTokens(_ n: Int) -> String` (`k`/`M` compaction) as a pure func/static.
- [x] Add computed props on `Usage`: `tokenLabel: String?`, `contextFraction: Double?`,
      `severity: ContextSeverity` per the thresholds in Technical Details.
- [x] Verify whether the wire carries a compaction count; if so add an optional
      `compressions: Int?` field + `CodingKey` to `Usage` (lenient, optional). (Confirmed:
      gateway sends `compressions` Int — `tui_gateway/server.py` `_get_usage`. Added.)
- [x] Write tests: `formatTokens` boundaries (`<1k`, `k`, `M`, exact thresholds);
      `tokenLabel` for max-known / used-only / total-only / empty; `contextFraction`
      clamping and percent-vs-ratio fallback.
- [x] Write tests: `severity` at boundary percents (49/50/80/81/94/95/100) — success +
      edge cases.
- [x] Run tests — must pass before Task 2: `script -q /dev/null swift test --package-path HermesKit`

### Task 2: Capture usage in `ChatFeature`

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/ChatReductionTests.swift`

- [x] Add `public var usage: Usage?` to `ChatFeature.State` (near `model`/`reasoningEffort`,
      ~`:31`); update the `State` init / default if applicable.
- [x] In `.sessionInfo`, set `if let u = info.usage { state.usage = u }` (overwrite only
      when present — mirrors model/effort partial-update handling at `:834-835`).
- [x] In `.messageComplete`, bind the usage arg (replace `_` at `:742`) and set
      `if let u = usage { state.usage = u }`.
- [x] Write reducer test: a `session.info` carrying `usage` populates `state.usage`.
- [x] Write reducer test: a `message.complete` carrying `usage` populates `state.usage`.
- [x] Write reducer test: a later partial `session.info` **without** usage does not clobber
      an existing `state.usage`.
- [x] Run tests — must pass before Task 3.

### Task 3: Context pill in the composer (compact view)

**Files:**
- Create: `HermesMobile/Sources/Features/Chat/ContextUsagePill.swift`
- Modify: `HermesMobile/Sources/Features/Chat/ComposerView.swift`
- Modify: `HermesMobile/Sources/Features/Chat/ChatView.swift`
- Modify: `HermesMobile/Sources/Features/Chat/Color+Hermes.swift` (severity → color)

- [x] Create `ContextUsagePill` view: thin capsule progress bar + label (`62%` or
      `125k/200k`), color from `severity`, paired numeric label (no color-only meaning).
      (Label uses `usage.tokenLabel`; bar fraction `usage.contextFraction`.)
- [x] Unknown-max state: render `125k tok` text only, no bar.
- [x] Animate fraction/bar changes gently; hold flat under reduce-motion
      (`@Environment(\.accessibilityReduceMotion)`).
- [x] Add `usage: Usage?` param to `ComposerView`; place the pill in the toolbar `HStack`
      beside `modelChip` (`:55-56`). Hide the pill entirely when `usage == nil` / no label.
- [x] Pass `store.usage` from `ChatView` into `ComposerView`.
- [x] Run `tuist generate` so the new source file is picked up by the app/snapshot target.
      (`make generate`.)
- [x] Add snapshot tests (new `ContextUsageSnapshotTests.swift`) at 40% / 85% / 97% and
      unknown-max (plus an in-composer case); recorded with `make snapshot-record`, asserted
      with `make snapshot`. (Severity→color mapping lives local to the pill, so
      `Color+Hermes.swift` was left unchanged.)
- [x] Run tests — must pass before Task 4. (37 snapshot tests pass; 242 HermesKit unit tests pass.)

### Task 4: Expandable detail popover

**Files:**
- Modify: `HermesMobile/Sources/Features/Chat/ContextUsagePill.swift`
- Modify: `HermesMobile/Sources/Features/Chat/ComposerView.swift` (or `ChatView.swift`)
- Modify: snapshot test file from Task 3

- [x] Make the pill tappable → `.popover` (or sheet) with breakdown: used / max, input vs
      output, compaction count (`compacted Nx` when `> 0`), estimated cost (`cost_usd`) when
      present. (Popover via `.presentationCompactAdaptation(.popover)`; `ContextUsageDetail`
      view, absent rows omitted.)
- [x] Near-full nudge: at `severity == .critical` (≥95%) show a subtle "context almost full
      — Hermes may compact soon" hint in the popover.
- [x] Decide the tap mechanism: prefer local view `@State` for popover presentation (pure UI,
      no reducer state) to keep `ChatFeature` lean — note rationale in the file.
      (`@State private var showDetail`, rationale commented inline.)
- [x] Add a snapshot test for the expanded popover (with and without cost / compaction).
      (Factored `ContextUsageDetail` into its own view; snapshotted directly at full-data
      critical + minimal non-critical.)
- [x] Run tests — must pass before Task 5. (HermesKit 242 unit tests pass; snapshot suite
      TEST SUCCEEDED — record hit the known post-record diagnostics-timeout but PNGs written
      and `make snapshot` asserts them clean.)

### Task 5: Verify acceptance criteria

- [x] Verify the pill shows used/max + percent on the chat screen, color-coded per TUI
      thresholds, matching issue #4's intent. (Verified: `ContextUsagePill.swift:24-67` renders
      bar + `usage.tokenLabel`; tint from `ContextSeverity.tint` (`:131-143`, green/yellow/orange/red);
      thresholds in `GatewayEvent.swift:144-154` `<50`/`≥50`/`>80`/`≥95`; baselines at 40/85/97%
      in `testContextPill_fillLevels`.)
- [x] Verify unknown-max renders `tok`-only (no misleading empty bar). (Verified:
      `contextFraction == nil` when max absent (`GatewayEvent.swift:197-205`) so `bar()` is gated
      by `if let fraction` (`ContextUsagePill.swift:30`); `testContextPill_unknownMax` baseline
      shows text only.)
- [x] Verify `usage == nil` (fresh session, old agent) renders nothing — no crash, no empty
      pill. (Verified: `ComposerView.swift:60` gates `if let usage`; the pill itself wraps
      everything in `if let label = usage.tokenLabel` (`ContextUsagePill.swift:24`), so a usage
      with no usable label is EmptyView. No defect.)
- [x] Run full unit suite: `script -q /dev/null swift test --package-path HermesKit` (242 tests
      in 22 suites passed).
- [x] Run snapshots: `make snapshot`. (TEST SUCCEEDED — 39 tests passed, 0 failed.)

### Task 6: Documentation

- [ ] Update `README.md` feature overview if it enumerates chat-screen features.
- [ ] Add a one-line convention to `CLAUDE.md` if a new pattern emerged (e.g. "context pill
      derives display from `Usage`; thresholds tested in HermesKit").
- [ ] Move this plan to `docs/plans/completed/`.

## Post-Completion

*Items requiring manual intervention or external systems — informational only.*

**Manual verification:**
- On-device check against a live session: confirm the percent moves as the conversation
  grows and that a backend auto-compaction visibly drops the bar (and bumps the
  `compacted Nx` count if surfaced).
- Dynamic Type + VoiceOver pass: the numeric label must be reachable and the pill must not
  truncate the model chip at large text sizes.
- Light/dark appearance check (snapshots pin dark mode; eyeball light).

**External system updates:**
- None. No protocol, RPC, or consuming-project changes. The on-demand `session.usage` RPC
  remains unused (out of scope) unless a later need arises.
