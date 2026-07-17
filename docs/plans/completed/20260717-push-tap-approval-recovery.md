# Push-Tap Approval Recovery

## Overview

Client-side workaround for hermes-agent issue #30 ("Re-surface pending approvals to
clients that connect after they fire"): when the socket was down at the moment an
`approval.request` fired (backgrounded app, disconnection), the event is gone — the
server does not re-send it on `session.resume`. But the **approval push notification**
still reaches the user, and its tap tells us a specific session has (or recently had) a
pending approval.

On an approval-typed push tap, after the normal hydrate: if the turn is still
`running` and no blocking interaction arrived over the socket, **synthesize a generic
approval card** (command unavailable — the push deliberately carries no content per the
generic-body privacy rule) so the user can still approve/deny. This is functional
because approvals have **no `request_id`** — `approval.respond` resolves a per-session
FIFO with just `session_id` + `choice` + `all`, and a blind respond against an empty
queue is a verified no-op on the server (`resolve_gateway_approval` returns `0`,
resolving nothing). The `{"resolved": n}` RPC result gives positive feedback: `0` means
"already handled elsewhere" and the UI says so instead of a false "Approved".

Composes with #30 rather than fighting it: when the agent learns to re-surface pending
approvals on resume, the real event simply overwrites the synthetic card; the tap
plumbing stays useful.

## Context (from discovery)

- `HermesKit/Sources/HermesKit/AppFeature.swift` — `pushTapped` routing (#32:
  on-screen match / detached-slot match / replace), `pendingApprovalSessionIDs`
  badge set (inserted on approval tap at line ~263, cleared on `openSession` at
  line ~298), `tap.isApproval`.
- `HermesKit/Sources/HermesKit/Features/ChatFeature.swift` —
  `State.pendingInteraction` (`PendingInteraction.approval(ApprovalRequest)`),
  `.approvalRequest` event handling (~line 1305, overwrites unconditionally),
  `.respondToApproval` (~line 790: optimistic "Approved"/"Denied" status row +
  fire-and-forget `try? gateway.send("approval.respond", …)`), `applyHydration`
  (~line 1545: authoritative `running` flag from `session.resume`).
- `HermesKit/Sources/HermesKit/Models/ApprovalRequest.swift` — every field already
  optional, decoded leniently; **no model change needed** (a synthetic request is
  just `command: nil` + explanatory `detail`).
- `HermesKit/Sources/HermesKit/Clients/HermesGatewayClient.swift` — `send` returns
  `JSONValue`, so the `{"resolved": n}` result is parseable.
- `HermesMobile/Sources/Features/Chat/ApprovalCardView.swift` — already renders
  gracefully with `command == nil` (detail-only card); no view change needed.
- Server behavior verified in the hermes-agent clone (`tools/approval.py`):
  `resolve_gateway_approval` FIFO, returns count resolved, `0` when queue empty —
  a blind respond cannot pre-approve a future approval. `session.resume` exposes
  no pending-approval state (that's exactly #30).

## Development Approach

- **Testing approach: Regular** (implementation, then tests within the same task).
- Complete each task fully before moving to the next; small focused changes.
- **CRITICAL: every task MUST include new/updated tests** for code changes in that
  task — success and error scenarios, as separate checklist items.
- **CRITICAL: all tests must pass before starting the next task.**
- **CRITICAL: update this plan file when scope changes during implementation.**
- Run `script -q /dev/null swift test --package-path HermesKit` (or `make test`)
  after each change; snapshot suite via `make snapshot`.
- Backward compatible: no wire changes, no push-payload changes (privacy rule holds),
  behavior identical for sessions never touched by an approval push.

## Testing Strategy

- **Unit tests** (HermesKit `swift test`): TCA `TestStore` event-reduction tests are
  the core deliverable — hint threading in `AppFeatureTests`, synthesis +
  resolved-count handling in `ChatInteractionTests` / `ChatReductionTests`.
- **Snapshot tests** (`HermesMobileTests/ChatSnapshotTests.swift`, `make snapshot`):
  one new case for the recovered (command-less) approval card.

## Progress Tracking

- Mark completed items `[x]` immediately when done.
- Add newly discovered tasks with ➕ prefix; blockers with ⚠️ prefix.
- Keep the plan in sync with actual work.

## Solution Overview

Three pieces, all in HermesKit (views untouched):

1. **Hint threading (`AppFeature`)** — an approval push tap marks the session in
   `pendingApprovalSessionIDs` (existing). New: routes that put that session's chat
   on screen also set a one-shot `expectsPendingApproval` flag on the
   `ChatFeature.State` that will hydrate — covering all three #32 routes plus the
   badged-then-opened-later-from-the-list route (cold launch on onboarding).
2. **Synthesis on hydrate (`ChatFeature.applyHydration`)** — consume the hint once:
   if the authoritative `running == true` and no `pendingInteraction` arrived via
   the socket, set `pendingInteraction = .approval(ApprovalRequest(command: nil,
   detail: <recovery copy>))`. Not running → the approval already resolved/timed
   out → drop silently. A real `approval.request` still overwrites unconditionally.
3. **Result-aware respond (`ChatFeature.respondToApproval`)** — keep the optimistic
   "Approved"/"Denied" status row but capture its id; the effect parses the
   `{"resolved": n}` result and feeds back `.approvalRespondResult`: `resolved == 0`
   → patch the row to "Already handled elsewhere"; RPC failure → `errorBanner`
   (no more silently-swallowed `try?`). Uniform for real and synthetic cards — the
   desktop-race benefit applies to real cards too, and no `isSynthesized` marker is
   needed anywhere.

### Key design decisions

- **No push-payload change**: the generic-body privacy rule stands; the tap's
  existing `type == "approval"` + `session_id` is all we use.
- **No `ApprovalRequest` model change**: the synthetic card is distinguished only by
  its content (`command: nil`, recovery `detail` copy). The card view already
  renders that shape.
- **The hint lives in `ChatFeature.State`, set by `AppFeature`** — mirrors how the
  parent already owns push-tap policy (#32); the chat stays ignorant of pushes.
- **`running` is the gate**: an agent blocked on approval keeps `running == true`,
  so a stale tap on a finished turn synthesizes nothing (no phantom card).
- **Honest copy**: the card's detail says the command details couldn't be recovered
  and to approve only if the user knows what the agent is doing; Deny stays the
  safe prominent-adjacent option (existing layout).

## Technical Details

- **`ChatFeature.State.expectsPendingApproval: Bool`** — transient, default `false`,
  not persisted in `ChatSnapshotClient` (a snapshot repaint must never resurrect a
  card), consumed (set `false`) on the first `applyHydration` and cleared by a real
  `.approvalRequest`.
- **Synthesis point**: inside `applyHydration` right after the authoritative
  `running` is computed — all open/foreground/cold-launch/reattach paths funnel
  through it, so one hook covers every route.
- **Recovery copy** (reducer-built, like the existing "Approved"/"Denied" rows):
  `ApprovalRequest(command: nil, detail: "The agent is waiting for approval of a
  command, but the details couldn't be recovered after reconnecting. Approve only
  if you know what it's doing.")`.
- **`.approvalRespondResult(rowID: ChatRow.ID, approve: Bool, resolved: Int?)`**:
  `resolved` parsed from the `JSONValue` result's `"resolved"` number; `nil` when
  the RPC threw (the effect catches and also sets a user-facing `errorBanner` via
  the action). `resolved == 0` → mutate the captured status row's text in place to
  "Already handled elsewhere" (the row id is a live `uuid()` row; the next hydrate
  replaces it wholesale with deterministic ids, which is fine — server wins).
- **`AppFeature` threading points** (`pushTapped` / `openSession`):
  - On-screen match (`currentViewingSessionID == tap.sessionID`): set
    `state.liveChat?.expectsPendingApproval = true` when `tap.isApproval` (the
    tap's app activation fires the existing `.foreground` re-hydrate).
  - `openSession`: read `pendingApprovalSessionIDs.contains(session.id)` **before**
    the existing `remove` — if true, set the flag on the re-attached slot state or
    on the fresh `ChatFeature.State`. This transparently covers the tap→open
    route, the slot-replacement route, and a badged session opened later from the
    list (cold-launch-on-onboarding case).
- **Badge behavior unchanged**: `pendingApprovalSessionIDs` insert/clear and
  `setBadge` stay exactly as they are.

### Edge cases

- Hint + `running == false` → no card, hint consumed (approval resolved/denied/
  timed out while detached).
- Hint + `pendingInteraction != nil` → socket already delivered a real request →
  hint consumed, nothing synthesized.
- Real `approval.request` after a synthetic card is up → overwrites (already the
  behavior at `.approvalRequest`); also clears the hint so a later hydrate can't
  re-synthesize.
- Respond hitting an empty queue (handled on desktop meanwhile) → server returns
  `resolved: 0` → row says "Already handled elsewhere"; nothing was mutated
  server-side (verified no-op).
- Respond RPC failure → `errorBanner`, card already dismissed (parity with how the
  turn continues server-side is unknowable offline; the banner is honest).
- Double hydrate of the same running turn → hint already consumed on the first →
  no duplicate synthesis.
- Non-approval push taps (`complete`/`error`/`clarify`) → no hint, zero behavior
  change. Clarify recovery is out of scope (it needs `request_id`, which only the
  real event carries — genuinely blocked on #30).

## What Goes Where

- **Implementation Steps**: HermesKit reducer/state changes + tests, snapshot test.
- **Post-Completion**: manual on-device verification with a real push; upstream #30
  note.

## Implementation Steps

### Task 1: Synthesize the recovered approval card on hydrate

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/ChatReductionTests.swift`

- [x] add `expectsPendingApproval: Bool` to `ChatFeature.State` (default `false`,
      documented as the push-tap approval-recovery hint, #30 workaround)
- [x] add a `static func recoveredApprovalRequest() -> ApprovalRequest` (or a
      constant) carrying the `command: nil` + recovery-copy `detail`
- [x] in `applyHydration`, after `running` is computed: consume the hint
      (`expectsPendingApproval = false`); when it was set AND `running` AND
      `pendingInteraction == nil`, set `pendingInteraction = .approval(recovered…)`
      (the hydrate-apply function is named `applyActivate` in the codebase)
- [x] in `.approvalRequest`, also clear `expectsPendingApproval` (real event wins,
      no later re-synthesis)
- [x] write TestStore tests: hint + running + no interaction → synthetic card set,
      hint consumed
- [x] write TestStore tests (negative): hint + not-running → no card; hint +
      interaction already present → untouched; no hint → no card; real
      `.approvalRequest` after synthesis overwrites and clears the hint
      (plus: double hydrate after respond → no re-synthesis)
- [x] run `swift test --package-path HermesKit` — must pass before task 2 (707 pass)

### Task 2: Parse the `approval.respond` resolved count and surface the outcome

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/ChatInteractionTests.swift`

- [x] add action `.approvalRespondResult(rowID: ChatRow.ID, approve: Bool,
      resolved: Int?)`
- [x] in `.respondToApproval`: capture the optimistic status row's id; replace the
      fire-and-forget effect with one that awaits
      `gateway.send("approval.respond", …)`, parses `result["resolved"]`, and sends
      `.approvalRespondResult` (`resolved: nil` on throw; the effect sends only
      actionable outcomes — resolved == 0 or throw — so a resolved ≥ 1 / missing-key
      success stays action-free and existing tests pass unchanged)
- [x] handle `.approvalRespondResult`: `resolved == 0` → patch the captured row's
      status text to "Already handled elsewhere"; `resolved: nil` → set
      `errorBanner` ("Failed to send the approval response."); `resolved >= 1` →
      no-op (optimistic row already correct)
- [x] write TestStore tests: resolved ≥ 1 keeps "Approved"/"Denied"; resolved == 0
      patches the row; RPC failure sets `errorBanner`
- [x] verify the choice vocabulary and no-`request_id` payload are byte-identical
      to today (existing tests keep passing unchanged)
- [x] run `swift test --package-path HermesKit` — must pass before task 3 (710 pass)

### Task 3: Thread the approval hint from AppFeature push-tap/open routing

**Files:**
- Modify: `HermesKit/Sources/HermesKit/AppFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/AppFeatureTests.swift`

- [x] `pushTapped` on-screen match: when `tap.isApproval`, set
      `state.liveChat?.expectsPendingApproval = true` before the badge bookkeeping
      (nil slot guarded)
- [x] `openSession`: read `pendingApprovalSessionIDs.contains(session.id)` before
      the existing `remove(session.id)`; when true, set the flag on the matched
      slot state (re-attach route) or on the fresh `ChatFeature.State` (fill /
      replace routes)
- [x] write TestStore tests: approval tap for the on-screen session sets the slot
      hint; approval tap from the list threads the hint through `openSession` into
      the re-attached slot (asserted end-to-end: reattach hydrate synthesizes the
      recovered card); approval tap for a different session threads it into the
      replacement slot state (plus: badged-then-opened-later cold-launch route)
- [x] write TestStore tests (negative): non-approval tap sets no hint; opening an
      un-badged session sets no hint; badge insert/clear + `setBadge` behavior
      unchanged
- [x] run `swift test --package-path HermesKit` — must pass before task 4 (714 pass)

### Task 4: Snapshot the recovered approval card

**Files:**
- Modify: `HermesMobileTests/ChatSnapshotTests.swift`
- Modify: `HermesMobile/Sources/Features/Chat/ApprovalCardView.swift` (➕ discovered)

- [x] add a snapshot case rendering `ApprovalCardView` (or the chat screen) with
      the synthetic `ApprovalRequest` (nil command, recovery detail) — verifies the
      command-less card lays out correctly (`testApprovalCard_recovered`, rendered
      from the real `ChatFeature.recoveredApprovalRequest()`)
- ➕ [x] fix `ApprovalCardView` detail truncation: the multi-line recovery copy
      collapsed to one ellipsized line under an ideal-height proposal —
      `.fixedSize(horizontal: false, vertical: true)` on the detail `Text` (the
      "no view change needed" prediction didn't survive the snapshot; the existing
      single-line `testApprovalCard` baseline is pixel-unchanged)
- [x] record via `make snapshot-record`, then assert via `make snapshot`
      (deviation: recorded via SnapshotTesting's missing-baseline auto-record on a
      targeted run instead of `make snapshot-record`, which wipes and re-records ALL
      baselines)
- [x] run `make snapshot` — must pass before task 5 (all ChatSnapshotTests pass incl.
      the new case; ⚠️ 4 PRE-EXISTING baseline-drift failures unrelated to this work —
      `testSecureConnectionInfo_passwordAvailable`, `testChatView_sentImageAttachment`,
      `testComposer_attachmentChips`, `testComposer_attachmentUploadingAndFailed` —
      verified to fail identically on a clean main checkout (baselines recorded
      2026-07-01, simulator runtime now iOS 26.2); re-recording them was left to the
      user, out of this task's scope)

### Task 5: Verify acceptance criteria

- [x] verify the Overview flow end-to-end in tests: approval push tap on a
      disconnected running session → hydrate → synthetic card → approve →
      `approval.respond` with session-scoped payload → resolved feedback
      (`approvalTapForDetachedSlotThreadsRecoveryHint` extended through the respond
      tail: captured payload asserted session-scoped with NO `request_id`,
      `resolved: 1` keeps the optimistic "Approved" row, no banner)
- [x] verify all edge cases in the Edge cases list have a covering test (audited —
      all seven covered: stopped-turn / real-interaction-present / real-event-
      overwrite in `ChatReductionTests`; resolved-0 approve+deny + RPC-failure
      banner in `ChatInteractionTests`; double-hydrate inside
      `hydrateWithHintOnRunningTurnSynthesizesRecoveredCard`; non-approval-tap /
      un-badged-open / no-hint negatives in `AppFeatureTests` +
      `hydrateWithoutHintSynthesizesNothing`; no new gaps found)
- [x] run the full suite: `script -q /dev/null swift test --package-path HermesKit`
      (714 tests in 49 suites, all pass)
- [x] run snapshots: `make snapshot` (all approval-card cases pass; only the 4
      known pre-existing iOS-26.2 baseline-drift failures noted in Task 4 remain —
      verified identical on clean main, out of scope)
- [x] confirm zero behavior change for non-approval pushes and sessions without the
      hint (existing tests unmodified except where new state is asserted — diff vs
      main shows the only touched existing test is
      `pushTapForOnScreenSessionDoesNotNavigate`, which now additionally asserts
      the hint; all approval payload/vocabulary tests byte-unchanged)

### Task 6: Update documentation

- [x] add a CLAUDE.md conventions bullet: push-tap approval recovery (hint →
      hydrate-gated synthesis → resolved-count feedback; privacy rule untouched;
      composes with hermes-agent #30)
- [x] move this plan to `docs/plans/completed/` (deferred — orchestrator moves it
      at run completion)

### ➕ Review hardening (post-Task-6 code review)

- [x] a synthesized (or real) approval card must never outlive its turn: turn-end events
      (`message.complete` / `error`) and a `running == false` hydrate now clear a standing
      `.approval` `pendingInteraction` + the hint (`clearStaleApproval`); tests
      `hydrateOfStoppedTurnClearsStaleApprovalCard`, `turnCompleteClearsStaleApprovalCardAndHint`,
      `turnErrorClearsStaleApprovalCardAndHint`
- [x] the on-screen push-tap arm now drives its own consuming `.liveChat(.foreground)` hydrate
      (no reliance on the tap's scene activation racing the store); `.respondToApproval` also
      clears the hint; tests `approvalTapForOnScreenSessionHydratesRecoveredCard`,
      `hydrateFailureKeepsHintArmedForTheRetry`
- [x] "Approve all in this session" is hidden on the recovered card via the content-derived
      `ApprovalRequest.offersSessionApproval` (a blind approve must not whitelist an unseen
      pattern session-wide); recovered-card snapshot baseline re-recorded (targeted)
- [x] dropped the dead `approve` payload from `.approvalRespondResult`; `recoveredApprovalRequest`
      is now a `static let`; fixed the doc comment that had attached to the wrong declaration;
      added the absent-row resolved-0 no-op test; README "Approve from anywhere" bullet extended

## Post-Completion

**Manual verification:**
- On-device: background the app mid-turn until the socket drops, trigger a
  dangerous command, tap the approval push → recovered card appears; approve and
  confirm the agent unblocks. Repeat with the approval answered on desktop first →
  "Already handled elsewhere".
- Stale-tap check: let an approval time out / turn finish, then tap the old push →
  no card.

**External systems:**
- No plugin/gateway changes (deliberate — generic-body privacy rule).
- Comment on hermes-agent issue #30 that the mobile client now has a tap-driven
  fallback; the proper fix (re-surfacing pending approvals on `session.resume`,
  e.g. exposing `has_blocking_approval` + the `_pending` payload) would let the
  client replace the generic card with full command details.
