# Reasoning-effort levels `max`/`ultra` + `config.set` failure handling (issue #81)

## Overview

Two TestFlight testers asked for "max reasoning" / "ultra thinking" and a `/reasoning`
command. The app **already has** a per-session reasoning picker (composer `model · effort`
chip → `ModelPickerSheet` → effort rows under the selected model → `config.set
{key:"reasoning"}`), but its level list is a hardcoded six-entry constant that stops at
`xhigh`. Upstream Hermes added `max` and `ultra` on 2026-07-12 (#62650), so the mobile cap
is the only reason the testers could not pick them.

This plan:

- Extends the picker's scale to the full upstream ladder: `none, minimal, low, medium,
  high, xhigh, max, ultra`.
- Fixes a latent rule violation in the same code path: `configSet` swallows every RPC
  failure with `try?`, so a rejected `model` **or** `reasoning` change leaves the
  optimistic chip lying. Failures now roll back the optimistic value and surface an
  `errorBanner` (desktop parity: `model-menu-panel.tsx` `patchReasoning` rolls back +
  toasts).
- Capability-gates the two new levels reactively: an older gateway (pre-2026-07-12)
  rejects them with server error `4002 "unknown reasoning value: <v>"`. One such verdict
  latches a per-chat-slot `extendedReasoningSupported = false` that hides `max`/`ultra`
  from the sheet for the rest of that slot's life.

Out of scope (decided in the brainstorm, YAGNI): a typed `/reasoning` command (it is on the
slash hide-list **on purpose** — the gateway's worker doesn't mirror it onto the live
session, see `docs/features/slash-commands.md`), discoverability work, the desktop's
separate Thinking on/off switch, `can_disable_reasoning`, and short labels
(`XHigh`/`Ultra`) — raw level ids stay as the labels in both chip and sheet.

## Context (from discovery)

Verified against upstream Hermes `upstream/main` @ `02c7ae956e` (2026-08-25).

- **Existing picker path**: `ChatFeature.Action.modelChipTapped` → `model.options` RPC →
  `State.ModelPicker` → `ModelPickerSheet`
  (`HermesMobile/Sources/Features/Chat/ModelPickerSheet.swift`) → `.reasoningSelected` /
  `.modelSelected` (`ChatFeature.swift:~1918–1935`) → private `configSet(key:value:…)`
  (`ChatFeature.swift:3402–3419`) → `config.set {session_id, key, value}` wrapped in the
  #17 `withSessionHeal` (re-resume + single replay on "session not found").
- **Level list**: `ModelOptions.reasoningEfforts = ["none","minimal","low","medium","high",
  "xhigh"]` at `HermesKit/Sources/HermesKit/Models/ModelOptions.swift:104`; the sheet
  iterates it directly (`ModelPickerSheet.swift:61`).
- **Upstream ladder**: `hermes_constants.VALID_REASONING_EFFORTS = ("minimal","low",
  "medium","high","xhigh","max","ultra")`; `parse_reasoning_effort` also accepts `none`.
  Desktop `apps/desktop/src/lib/reasoning-effort.ts` shows all seven. Transports clamp per
  provider **on the wire** (gpt-5.6 `ultra→max`, xAI tops at `high`, OpenAI-compat tops
  at `max`), and `hermes_cli/inventory.py::_apply_capabilities` deliberately does NOT
  forward per-model `supported_efforts` (it under-reports). ⇒ the client must offer the
  full scale and never filter by model. This also answers the "why can't I choose ultra
  for OpenAI" tester: the server clamps, the client just needs to offer it.
- **Older-gateway rejection**: `tui_gateway/server.py` `config.set`, key `reasoning` →
  `parse_reasoning_effort(arg)` → `None` → `_err(rid, 4002, f"unknown reasoning value:
  {value}")`. NOT `-32601`, so the usual method-probe gate doesn't apply; the gate must be
  reactive per selection. `InboundFrame` keeps only the error *message*, not the code —
  so matching is by the stable server text, the `GatewayError.isUnknownMethod` idiom
  (`HermesGatewayClient.swift:79`).
- **Swallowed failure**: `configSet` does `_ = try? await withSessionHeal(...)` — violates
  the "surface RPC failures" rule; the optimistic `state.model` / `state.reasoningEffort`
  written before the RPC is never rolled back.
- **Sibling capability flags** (`commandsUnsupported`, `attachmentsUnsupported`) live in
  `ChatFeature.State`, per chat slot, initialised in `init` (~line 449–451), reset on a
  fresh slot, never persisted in `ChatSnapshotClient`.
- **Existing tests on this path** (must keep passing):
  `HermesKit/Tests/HermesKitTests/ChatInteractionTests.swift`
  (`selectingReasoningSendsConfigSet`, `selectionIsBlockedWhileSending`, ~line 262) and
  `SelfHealTests.swift` (`reasoningSelectionSelfHealsOnSessionNotFoundThenSucceeds`,
  ~line 40). Snapshot: `HermesMobileTests/ComposerSnapshotTests.swift`
  `testModelPickerSheet` (renders the effort rows — its baseline changes deliberately)
  and `testModelPickerSheet_nonReasoningModelHidesEffort`.
- **Sheet call sites**: `ChatView.swift:110` (live) and the two snapshot tests. The
  `ComposerView` idiom for new inputs is a defaulted `var` so snapshot call sites stay
  unchanged.

## Development Approach

- **testing approach**: Regular (code first, then tests) — consistent with every prior plan.
- complete each task fully before moving to the next
- make small, focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
  - tests cover both success and error scenarios
- **CRITICAL: all tests must pass before starting next task** — no exceptions
- **CRITICAL: update this plan file when scope changes during implementation**
- commit at each task completion (capitalized verb, no prefixes, concise)
- HermesKit tests: `script -q /dev/null swift test --package-path HermesKit` (or `make test`)
- maintain backward compatibility: the success path of `config.set` is byte-identical;
  old agents only differ in that a rejection is now *visible*.

## Testing Strategy

- **unit tests** (HermesKit, `TestStore` + `@Dependency` overrides): required for every
  task — the pure `offeredEfforts` filter, the `GatewayError` text match, and the
  `configSetFailed` reduction (rollback / latch / banner) for both keys and both error
  classes.
- **snapshot tests** (`HermesMobileTests`): the existing `testModelPickerSheet` baseline
  must be re-recorded (it now shows two more rows) and one new latched-state snapshot is
  added. NEVER run `make snapshot-record` (it wipes the whole `__Snapshots__` dir):
  delete the single stale PNG and run `make snapshot` twice (first records + fails by
  design, second asserts clean). The suite has known broad baseline drift — judge by
  render-size mismatch, not pixel residual.
- no e2e suite in this project.

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- update plan if implementation deviates from original scope

## Solution Overview

Option A from the brainstorm — **static list + per-slot latch**:

- The ladder stays a static constant mirroring `VALID_REASONING_EFFORTS` verbatim (with
  `none` first, as today). No server-derived list (the server refuses to publish one).
- A pure `ModelOptions.offeredEfforts(extendedSupported:)` is the single filter the sheet
  iterates — unit-tested in HermesKit, view stays thin.
- `configSet` stops swallowing: the final failure (after the #17 heal has had its single
  replay) becomes `.configSetFailed(key:previousValue:error:)`. ONE result path serves both
  `model` and `reasoning`; the reducer rolls back the matching field, sets `errorBanner`,
  and latches `extendedReasoningSupported = false` only for `key == "reasoning"` with the
  `unknown reasoning value` verdict. Transport failures and other server errors (mid-turn
  4009) roll back + banner but never latch — a transport failure is not a capability
  verdict (#62 logic).
- The latch is per chat slot and unpersisted (same lifetime as `commandsUnsupported`):
  a fresh slot re-offers the levels, so an agent upgrade is picked up on the next chat with
  no extra logic. Bounded staleness while a latched slot outlives an upgrade — accepted.
- Success stays fire-and-forget: the server emits `session.info` after a successful
  `config.set`, and `.sessionInfo` already reconciles `model` / `reasoningEffort`.

## Technical Details

**`ModelOptions` (HermesKit)**
```swift
public static let reasoningEfforts = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
public static let extendedReasoningEfforts: Set<String> = ["max", "ultra"]
public static func offeredEfforts(extendedSupported: Bool) -> [String]  // order preserved
```

**`GatewayError`**
```swift
/// `config.set {key:"reasoning"}` on a gateway older than 2026-07-12 (#62650) answers
/// error 4002 "unknown reasoning value: <v>" for `max`/`ultra`. The frame drops the code,
/// so match the stable server text (same contract as `isUnknownMethod`).
public var isUnknownReasoningValue: Bool
```

**`ChatFeature.State`**: `public var extendedReasoningSupported: Bool` — `true` in `init`.

**`ChatFeature.Action`**: `case configSetFailed(key: String, value: String, previousValue: String?, error: GatewayError)` — `value` is the rejected pick, for the banner.

**Reducer flow**
1. `.modelSelected(m)` / `.reasoningSelected(e)`: capture `previous` = the last server-confirmed
   value (`state.pendingConfigRollback[key] ?? state.model` / `state.reasoningEffort`, stored back
   under `key` so a superseding pick reuses it), write optimistic, call
   `configSet(key:value:previousValue:sessionID:storedSessionID:branchSeed:profile:)`.
2. `configSet`: `do { _ = try await withSessionHeal(...) } catch let e as GatewayError {
   await send(.configSetFailed(key:, value:, previousValue:, error: e)) } catch {
   await send(.configSetFailed(..., error: .disconnected)) }` — same non-`GatewayError`
   fallback as the `model.options` fetch.
3. `.configSetFailed(key, value, previous, error)`:
   - rollback unconditionally: `"model"` → `state.model = previous`; `"reasoning"` →
     `state.reasoningEffort = previous` (server wins again on the next `session.info`).
   - latch: `key == "reasoning" && error.isUnknownReasoningValue` →
     `state.extendedReasoningSupported = false`.
   - banner: latch case → `This agent doesn't support "<value>" reasoning.` (the rejected
     value is the action's `value`); otherwise → `Couldn't change <key>: <error.message>`.
   - no `isSending` / `activity` changes (a config change is not a turn). Guards
     `!isSending` + `liveSessionID != nil` on the selection actions are unchanged.
   - the sheet stays open (the row deselects behind the banner — desktop parity).

**View**: `ModelPickerSheet` gains `var extendedReasoningSupported: Bool = true`
(defaulted, `ComposerView` idiom); the effort `ForEach` iterates
`ModelOptions.offeredEfforts(extendedSupported: extendedReasoningSupported)`. `ChatView`
passes `store.extendedReasoningSupported`.

## What Goes Where

- **Implementation Steps** (`[ ]`): all code, tests, docs — everything is in this repo.
- **Post-Completion**: manual verification on a real (old and new) agent.

## Implementation Steps

### Task 1: Extend the reasoning ladder and add the `offeredEfforts` filter

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Models/ModelOptions.swift`
- Modify (or create if no model-level test file exists): `HermesKit/Tests/HermesKitTests/ModelOptionsTests.swift`

- [x] replace `reasoningEfforts` with the eight-entry ladder (`none` first, then
      `VALID_REASONING_EFFORTS` verbatim); rewrite the doc comment: cite upstream #62650
      (2026-07-12), state that transports clamp per provider on the wire and that the
      server deliberately does not publish per-model `supported_efforts`, so the client
      never filters by model
- [x] add `extendedReasoningEfforts: Set<String> = ["max", "ultra"]` with a comment that
      these are the levels a pre-#62650 gateway rejects with 4002
- [x] add pure `offeredEfforts(extendedSupported: Bool) -> [String]` (full ladder, or the
      ladder minus the extended set, order preserved)
- [x] write tests: full ladder when supported (exact array, `none` first, `ultra` last);
      latched list excludes exactly `max`/`ultra` and keeps order; `extendedReasoningEfforts`
      is a subset of `reasoningEfforts`
- [x] run `swift test --package-path HermesKit` — must pass before task 2

### Task 2: Add `GatewayError.isUnknownReasoningValue`

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Clients/HermesGatewayClient.swift`
- Modify: the existing `GatewayError` / gateway client test file (locate with
  `grep -rl isUnknownMethod HermesKit/Tests`)

- [x] add `isUnknownReasoningValue` next to `isUnknownMethod`: `.server(message)` whose
      lowercased text `hasPrefix("unknown reasoning value")`; doc comment mirrors the
      `isUnknownMethod` justification (frame drops the code) and cites
      `tui_gateway/server.py` `config.set` → `_err(rid, 4002, "unknown reasoning value: …")`
- [x] write tests: matches `"unknown reasoning value: max"` (and mixed case); does not
      match `"unknown method: config.set"`, `"session not found"`, `.timedOut`,
      `.disconnected`
- [x] run `swift test --package-path HermesKit` — must pass before task 3

### Task 3: Surface `config.set` failures — `configSetFailed`, rollback, latch, banner

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/ChatInteractionTests.swift`
- Modify: `HermesKit/Tests/HermesKitTests/SelfHealTests.swift` (verify only)

- [x] add `public var extendedReasoningSupported: Bool` to `State`, initialised `true`
      beside `commandsUnsupported`; doc comment: per-slot, unpersisted, flipped only by the
      4002 verdict, reset on a fresh slot
- [x] add `case configSetFailed(key: String, value: String, previousValue: String?, error: GatewayError)`
      to `Action` (carry the rejected `value` so the latch banner can name it)
- [x] change `configSet` to take `value` + `previousValue`, drop the `try?`, and
      `do/catch` around `withSessionHeal`: `GatewayError` → `.configSetFailed`, any other
      error → `.configSetFailed(…, error: .disconnected)`; keep the #17 heal untouched
- [x] in `.modelSelected` / `.reasoningSelected`, capture the previous value BEFORE the
      optimistic write and pass it through
- [x] reduce `.configSetFailed`: unconditional rollback by key; latch when
      `key == "reasoning" && error.isUnknownReasoningValue`; set `errorBanner`
      (`This agent doesn't support "<value>" reasoning.` for the latch case,
      `Couldn't change <key>: <message>` otherwise); no `isSending`/`activity` changes
      — banners use the codebase's typographic apostrophe (`doesn’t` / `Couldn’t`)
- [x] write tests (TestStore, `readyState()` with `reasoningEffort = "medium"`,
      `model = "gpt-5"`):
      - `reasoningSelected("max")` with a stub throwing `.server("unknown reasoning value: max")`
        → optimistic `"max"`, then receives `.configSetFailed` → `reasoningEffort == "medium"`,
        `extendedReasoningSupported == false`, banner names `"max"`
      - `reasoningSelected("max")` with `.timedOut(method: "config.set")` → rollback +
        banner, `extendedReasoningSupported` stays `true`
      - `reasoningSelected("high")` with `.server("some other error")` → rollback + banner,
        no latch
      - `modelSelected("gpt-5-mini")` with `.server("cannot switch mid-turn")` →
        `model == "gpt-5"`, banner, `extendedReasoningSupported` stays `true`
      - non-`GatewayError` thrown by the stub → `.configSetFailed(error: .disconnected)`
      - success path: `selectingReasoningSendsConfigSet` unchanged — no failure action
        received
- [x] confirm `reasoningSelectionSelfHealsOnSessionNotFoundThenSucceeds` still passes
      (heal + replay succeed → no `.configSetFailed`); add a variant where the REPLAY also
      fails → exactly one `.configSetFailed`, no second retry
- [x] run `swift test --package-path HermesKit` — must pass before task 4

### Task 4: Thread the latch into `ModelPickerSheet` and re-record its snapshot

**Files:**
- Modify: `HermesMobile/Sources/Features/Chat/ModelPickerSheet.swift`
- Modify: `HermesMobile/Sources/Features/Chat/ChatView.swift`
- Modify: `HermesMobileTests/ComposerSnapshotTests.swift`
- Delete + re-record: the `testModelPickerSheet` PNG under `HermesMobileTests/__Snapshots__/ComposerSnapshotTests/`

- [x] add `var extendedReasoningSupported: Bool = true` to `ModelPickerSheet` (defaulted so
      snapshot call sites stay unchanged) and iterate
      `ModelOptions.offeredEfforts(extendedSupported: extendedReasoningSupported)` in the
      effort `ForEach`; update the type doc comment (full scale; latch hides `max`/`ultra`)
- [x] pass `extendedReasoningSupported: store.extendedReasoningSupported` from `ChatView`
- [x] check `HermesMobile/Sources/DemoMode.swift` for any effort-list assumptions
      (it references `reasoning`) — adjust only if it enumerates the ladder — its only
      `reasoning` reference is a demo reasoning *string*, no ladder; left untouched
- [x] delete the stale `testModelPickerSheet` baseline PNG (single file — NOT
      `make snapshot-record`), run `make snapshot` twice; verify the new baseline shows
      eight effort rows — verified: `none … xhigh, max, ultra` all render unclipped
- [x] add `testModelPickerSheet_latchedHidesExtendedEfforts` (same fixture as
      `testModelPickerSheet`, `extendedReasoningSupported: false`) — record via
      `make snapshot` twice; verify `max`/`ultra` absent — verified: six rows, ends at `xhigh`
- [x] run `make snapshot` — the picker tests assert clean (other suites' known drift is
      pre-existing; judge by render size) — all three picker tests pass; 36/198 pre-existing
      baseline-drift failures elsewhere (documented runtime drift, untouched by this task)

### Task 5: Verify acceptance criteria
- [x] the sheet offers `none … xhigh, max, ultra` on a current agent; selecting `max`
      updates the chip and survives a hydrate (server `session.info` echoes it) — verified by
      `ModelOptionsTests.reasoningLadderIsTheFullUpstreamScale` /
      `offeredEffortsReturnsFullLadderWhenExtendedSupported`, the re-recorded
      `ComposerSnapshotTests.testModelPickerSheet` baseline (eight rows), and the new
      `ChatInteractionTests.selectingMaxSendsItAndSurvivesTheEchoingSessionInfo`
- [x] on a pre-#62650 agent (or a stub answering the 4002 text): first `max` pick rolls
      back, banner shows, `max`/`ultra` disappear from the sheet; a fresh chat re-offers them
      — verified by `ChatInteractionTests.rejectedExtendedReasoningRollsBackAndLatches`,
      `GatewayErrorTests.unknownReasoningValue*`,
      `ModelOptionsTests.offeredEffortsDropsExactlyMaxAndUltraWhenLatched`,
      `ComposerSnapshotTests.testModelPickerSheet_latchedHidesExtendedEfforts`, and the new
      `ChatInteractionTests.freshSlotReOffersTheExtendedLevels`; a real old agent is not
      automatable — covered by Post-Completion manual verification
- [x] a rejected model switch rolls back the chip and banners — verified by
      `ChatInteractionTests.rejectedModelSwitchRollsBackAndBanners` (plus the no-latch
      siblings `timedOutReasoningSelectionRollsBackWithoutLatching`,
      `otherServerErrorOnReasoningDoesNotLatch`, `nonGatewayErrorMapsToDisconnected`, and
      `SelfHealTests.reasoningSelectionSurfacesFailureWhenReplayAlsoFails`)
- [x] `/reasoning` typed in the composer still falls through to `prompt.submit` (no
      catalog change — verify `mobileHiddenCommands` untouched) — `CommandCatalog` is
      untouched on this branch (`git diff main...HEAD` lists no catalog file);
      `CommandCatalogTests.hideListContainsOnlySlashPrefixedLowercaseNames` still asserts
      `/reasoning` is hidden, and `/reasoning max` was added to
      `SlashCommandChatTests.typedHiddenOrUnknownCommandFallsThroughToPlainPrompt`
- [x] run full suite: `make test` and `make snapshot` — `swift test`: 1196 tests / 60
      suites, all green; `make snapshot`: the three `ModelPickerSheet` tests pass, 36
      pre-existing baseline-drift failures in untouched suites (same 36 as Task 4;
      documented runtime drift, not re-recorded)

### Task 6: [Final] Update documentation
- [x] create `docs/features/model-picker.md`: picker path + RPCs; full-scale-always with
      the per-provider clamp rationale; the 4002 text-match latch and why not `-32601`;
      per-slot unpersisted latch reset; one rollback path for both keys; `/reasoning`
      stays hidden and why; reference #81 and upstream #62650
- [x] add one compressed bullet to `CLAUDE.md` under "Composer & input" (after the
      slash-commands bullet) pointing at the new doc — placed after the prompt-queue
      bullet (last in that section), same bold-lead style as its neighbours
- [x] README feature overview: mention the full reasoning scale only if the README lists
      the picker today (check; do not add a section otherwise) — checked: the overview
      never mentions the model/reasoning picker (its only "reasoning" hit is the Thinking
      disclosure), so README is left untouched
- [x] move this plan to `docs/plans/completed/` (deferred to the orchestrator's
      completion step)

## Post-Completion

**Manual verification**
- Real device against a current Hermes build: pick `ultra` on an OpenAI model and
  confirm the turn runs (server clamps `ultra→max` for gpt-5.6 — the chip still reads
  `ultra`, which is the desktop behaviour too).
- Against an older Hermes build (git checkout before `7550c594ce`): confirm the latch and
  banner, then a new chat re-offers the levels.
- Close issue #81 with a note that `/reasoning` is intentionally not a command on mobile
  (the chip is the affordance) and why.
