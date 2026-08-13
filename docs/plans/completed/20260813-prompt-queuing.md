# Prompt Queuing While a Turn Is Running (#66)

## Overview

- Today the composer hard-blocks mid-turn: the send button becomes Interrupt while
  `isSending`, and `canSend` gates on `!isSending && !slashExecInFlight`, so a user who
  thinks of the next prompt while the agent works has nowhere to put it.
- Add a **client-side prompt queue**: mid-turn, the send arrow returns whenever the
  composer has content; tapping it freezes the draft (text + staged attachments) into an
  ordered `queuedPrompts` list — no wire traffic. When the turn ends, the head entry
  auto-fires as the next turn through the existing submit pipeline.
- Queued entries are visible in a compact panel pinned above the composer, with a
  per-entry context menu: **Edit** (lift back into an empty composer), **Delete**, and
  **Send now** (interrupt-then-send while running).
- Client-side deliberately (brainstorm decision): the server's `queued_prompt` slot is a
  single merge-only slot with **no edit/delete API** (`session.interrupt` silently clears
  it), so server-side queuing can't support the required interactions. Mobile never
  submits against a running turn, so the server's `busy_input_mode` policy never engages
  from mobile — mid-turn send always means "queue". Old agents (which 4009 a busy
  `prompt.submit`) work identically since nothing is sent mid-turn.

## Context (from discovery)

- `HermesKit/Sources/HermesKit/Features/ChatFeature.swift` — `canSend` ~452–489
  (gates: content, `liveSessionID != nil`, `pendingInteraction == nil`, `!isSending`,
  `!slashExecInFlight`, `!isBranching`, `pendingPasteCount == 0`); `.composerSubmitted`
  reduction ~1060–1258 (attachment path → degenerate slash → compress → slash pipeline →
  plain prompt; composer cleared only in the reducer); `.interruptTapped` ~1296–1309
  (optimistic: `isSending = false`, freeze thinking, cancel timer, fire-and-forget
  `session.interrupt`); `.messageComplete` ~2095; `.error` ~2160; `finalizeInFlight`
  ~2284 (`.gatewayClosed` — no `messageComplete` ever arrives on a socket drop);
  `applyActivate` ~2586 re-derives `isSending = running || slashExecInFlight`.
- `HermesKit/Sources/HermesKit/Models/ComposerAttachment.swift` — staged attachment
  model; `ChatFeature.State.attachments: [ComposerAttachment]` (line ~130).
- `HermesMobile/Sources/Features/Chat/ComposerView.swift` ~182–196 — `sendButton`
  swaps on `isSending` alone (stop vs arrow); wired in `ChatView.swift` ~46–63.
- `HermesMobile/Sources/Features/Chat/ChatView.swift` ~270–290 — `SlashSuggestionPanel`
  renders between transcript and composer when `slashSuggestions` non-empty, with an
  emptiness-keyed animation; the queue panel takes the same slot (above suggestions).
- `HermesKit/Sources/HermesKit/AppFeature.swift` ~645–658 — turn-end-while-detached:
  `.runningChanged(_, false)` with empty path runs `teardownSlot()`.
- Server reference (hermes-agent sibling clone, `tui_gateway/server.py`): busy
  `prompt.submit` queues/steers/redirects per `display.busy_input_mode` (9983,
  `_handle_busy_submit` 6022, merge-only `_enqueue_prompt` 5967); `session.interrupt`
  clears `queued_prompt` (9657). No queue management RPC exists — the reason this
  feature is client-side. Desktop precedent: client-side composer-queue store +
  queue-panel with park-on-explicit-stop and settle-edge drain.
- Patterns: TCA `TestStore` reducer tests in `HermesKit/Tests/HermesKitTests/`,
  snapshot tests in `HermesMobileTests/`.

## Development Approach

- **Testing approach**: Regular (code first, then tests, per task)
- Complete each task fully before moving to the next
- Make small, focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
  - tests are not optional — they are a required part of the checklist
  - cover both success and error scenarios
- **CRITICAL: all tests must pass before starting next task** — no exceptions
- **CRITICAL: update this plan file when scope changes during implementation**
- Run `script -q /dev/null swift test --package-path HermesKit` after each HermesKit
  change; `make snapshot` for view changes
- Backward compatibility: the idle-time submit path stays byte-identical (same gates,
  same wire behavior); old agents see no new traffic at all

## Testing Strategy

- **Unit tests (HermesKit, `swift test`)**: `TestStore` + dependency overrides +
  `TestClock` carry the weight — enqueue gating, drain state machine, parking,
  failure re-park, Send-now, Edit gate, `AppFeature` detached-slot policy.
- **Snapshot tests (`HermesMobileTests`, `make snapshot`)**: the queue panel in queued
  and held states. New baselines via the run-twice recipe (first run records + fails,
  second asserts) — do NOT use `make snapshot-record`. Judge pre-existing broad
  snapshot drift by size mismatch first (known simulator-runtime drift).
- No e2e suite in this project.

## Progress Tracking

- Mark completed items with `[x]` immediately when done
- Add newly discovered tasks with ➕ prefix
- Document issues/blockers with ⚠️ prefix
- Keep plan in sync with actual work done

## Solution Overview

- **State**: `ChatFeature.State.queuedPrompts: [QueuedPrompt]` (ordered) where
  `QueuedPrompt` = `id` (from `@Dependency(\.uuid)`) + `text` + `attachments:
  [ComposerAttachment]` — a frozen composer draft. Queue-level `isQueueParked: Bool`
  (parking is a queue property, not per-entry). `drainingEntry: QueuedPrompt?` tracks
  the in-flight drained entry so a failure can restore it losslessly.
- **Enqueue**: `.composerSubmitted` while `isSending || slashExecInFlight` (and the
  other gates pass) appends an entry and clears the composer. No RPC, no transcript row.
- **Drain**: one `maybeDrainQueue` decision point, evaluated on `.messageComplete` and
  on a hydrate whose authoritative `running == false` (covers `.gatewayClosed`
  finalization + reconnect — no `messageComplete` arrives on a socket drop). Head-only,
  one turn per entry; the drained entry goes through the **existing** submit pipeline
  (attachment uploads, slash routing for command-shaped text, #17 session-not-found
  heal) via a shared submit helper extracted from `.composerSubmitted`.
- **Parking**: manual Stop (`.interruptTapped`) and turn `.error` set `isQueueParked`
  (mirrors desktop park-on-explicit-stop; avoids burning the queue against a failing
  server). A failed drain re-inserts `drainingEntry` at the **head** + parks + error
  banner — a queued message is never silently lost. Idle composer sends always work
  and jump ahead of parked entries.
- **Send now**: idle → remove entry, submit immediately (ahead of the queue). Running →
  move entry to head, arm `sendNowArmed: Bool`, fire the interrupt effect; the
  interrupted turn's terminal signal drains it (settle-edge, desktop semantics —
  avoids racing a submit against a still-running server turn). `sendNowArmed`
  suppresses the interrupt/error park for that one turn-end and clears `isQueueParked`.
- **UI**: `QueuedPromptsPanel` pinned above the composer (above `SlashSuggestionPanel`
  in the same non-scrolling slot), compact 2-line rows, height-capped with internal
  scrolling beyond ~3 entries (#65 non-scrolling-region lessons). Not in the
  transcript — no row-id/hydrate involvement at all.
- **Persistence: in-memory v1** — survives navigation/backgrounding via the live-chat
  slot; lost on process kill (same lifetime as an unsent draft). Snapshot persistence
  of text-only entries is an explicit non-goal (follow-up); attachment bytes never go
  to GRDB.

## Technical Details

- **Gates for enqueue** (computed `canQueue`): content present AND
  (`isSending || slashExecInFlight`) AND `liveSessionID != nil` AND
  `pendingInteraction == nil` AND `!isBranching` AND `pendingPasteCount == 0`. An
  approval/clarify card still locks all submission — decide the card first.
- **Drain preconditions**: queue non-empty, `!isQueueParked` (unless `sendNowArmed`),
  `!isSending`, `!slashExecInFlight`, `pendingInteraction == nil`,
  `drainingEntry == nil`, `liveSessionID != nil`.
- **Drain lifecycle**: pop head → `drainingEntry = entry` → shared submit helper.
  Success is implied by the turn starting (`.messageStart` clears `drainingEntry`);
  `promptSubmitFailed` / `.attachmentUploadFailed` with a standing `drainingEntry`
  re-insert it at head, park, clear `drainingEntry`. A stray 4009 from an old agent in
  the completion race rides the same failure path.
- **Park does NOT fire on Send-now's own interrupt**: `.queuedPromptSendNow` runs its
  own interrupt effect (freeze thinking, cancel timer, `session.interrupt`) without
  routing through `.interruptTapped`'s park, and `sendNowArmed` makes the interrupted
  turn's terminal `.error`/`.messageComplete` drain instead of park.
- **Edit**: `.queuedPromptEditTapped(id)` guards `composerText` trimmed-empty AND
  `attachments.isEmpty`, then removes the entry and restores `composerText` +
  `attachments` from it (`/undo`-prefill style). The panel disables the menu item when
  the composer has content (reducer guard is the source of truth; the view mirrors it).
- **Hydrate**: `applyActivate` never touches `queuedPrompts`/`isQueueParked` (they are
  client-local, not server state); it only feeds the `running == false` drain trigger.
- **Detached slot** (`AppFeature`): the `.runningChanged(_, false)` teardown guard
  additionally requires the slot's queue to be empty. Non-empty queue → keep the slot;
  the drain fires inside the slot and the next turn streams into it (glow continues).
  A **parked** queue on a detached slot keeps the slot alive indefinitely (held entries
  wait for the user) — accepted for v1; noted as a follow-up if the idle socket bothers.
- **Composer button**: while `isSending`, empty composer keeps the red Stop; content
  present swaps to the send arrow driven by `canSend || canQueue` (new
  `canSubmitOrQueue` passed to `ComposerView`). Accessibility label switches to
  "Queue message" in the queue case.

## What Goes Where

- **Implementation Steps** (`[ ]` checkboxes): HermesKit model/reducer changes, app
  target views, tests, docs.
- **Post-Completion** (no checkboxes): manual device checks, follow-ups.

## Implementation Steps

### Task 1: QueuedPrompt model, state, and the enqueue branch

**Files:**
- Create: `HermesKit/Sources/HermesKit/Models/QueuedPrompt.swift`
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/ChatFeatureTests.swift` (or a new
  `ChatQueueTests.swift` if the file is unwieldy)

- [x] create `QueuedPrompt` (`Identifiable`, `Equatable`, `Sendable`): `id: UUID`,
      `text: String`, `attachments: [ComposerAttachment]`
- [x] add `queuedPrompts: [QueuedPrompt]`, `isQueueParked: Bool`,
      `drainingEntry: QueuedPrompt?`, `drainingRowID`, `sendNowArmed: Bool` to
      `ChatFeature.State`; add computed `canQueue` + `hasQueuedWork`
- [x] branch `.composerSubmitted`: when `isSending || slashExecInFlight` and `canQueue`,
      append `QueuedPrompt` (id from `@Dependency(\.uuid)`), clear `composerText` +
      `attachments`, return `.none`; idle path stays byte-identical (degenerate-slash
      local failure mirrored, composer kept)
- [x] write tests: enqueue mid-turn appends + clears composer; enqueue during slash
      exec; blocked by pending approval card / branching / pending paste; idle submit
      unaffected; two enqueues stay separate ordered entries (`ChatQueueTests`, 9 tests;
      ➕ updated `submitWhileSendingIsNoOp` → `submitWhileSendingQueuesInsteadOfSubmitting`
      and `canSendBlockedWhileSlashExecInFlight` — both encoded the old no-op contract)
- [x] run `script -q /dev/null swift test --package-path HermesKit` — 1106 tests pass

### Task 2: Shared submit helper + drain state machine

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/ChatQueueTests.swift`

- [x] extract the idle body of `.composerSubmitted` into `submitDraft(text:attachments:
      fromQueue:sessionID:state:)` (attachment path, degenerate-slash guard, compress,
      slash pipeline, plain prompt — all preserved; existing submit tests stayed green);
      `.attachmentsSubmitted` gained a `fromQueue` flag so a drained upload never clears
      the live composer
- [x] add `drainQueueIfReady` (named per its callers, not `maybeDrainQueue`):
      preconditions per Technical Details; pop head, set `drainingEntry` +
      `drainingRowID`, submit via the helper; evaluated on `.messageComplete` and in
      `applyActivate` when authoritative `running == false` (covers `.gatewayClosed` +
      the post-slash refresh)
- [x] park on `.interruptTapped` and `.error` (skip when `sendNowArmed`); clear
      `drainingEntry` on `.messageStart` / turn terminals / `.attachmentsSubmitted` /
      `finishSlashExec` / `.slashCommandHandedOff`; `reparkDrainingEntry` (head + park +
      echo-row removal) on `promptSubmitFailed` / `.attachmentUploadFailed` /
      `.attachmentsUnsupportedDetected` / `.slashCommandFailed`
- [x] write tests: drain fires on `messageComplete` (head only, second waits); drain on
      idle hydrate; still-running hydrate leaves queue untouched; park on Stop (complete
      does not drain); park on error; failed drain re-parks at head with banner + echo
      row removed; `message.start` consumes the entry; idle composer send jumps ahead of
      a parked queue
- [x] run `script -q /dev/null swift test --package-path HermesKit` — 1114 tests pass
      (twice, for flake stability)

### Task 3: Queue interactions — delete, edit, send now

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/ChatQueueTests.swift`

- [x] add `.queuedPromptDeleted(id:)`: remove entry (no confirmation dialog)
- [x] add `.queuedPromptEditTapped(id:)`: guard composer trimmed-empty and no staged
      attachments → remove entry, restore `composerText` + `attachments` from it
- [x] add `.queuedPromptSendNow(id:)`: idle → promote to head + drain immediately;
      running → promote, set `sendNowArmed`, clear `isQueueParked`, run the interrupt
      effect WITHOUT the park (➕ the effect also sends `.maybeDrainQueue` after the
      interrupt RPC resolves — a deterministic re-check for a turn whose terminal never
      arrives; ➕ during a slash exec there is no interrupt, the exec's terminal drains
      the armed head)
- [x] write tests: delete; edit lifts into empty composer (text + attachments); edit
      no-ops when composer has a draft; send-now idle submits ahead of parked entries;
      send-now running = interrupt → `.maybeDrainQueue` → single submit; ➕ the armed
      drain also fires from the interrupted turn's `.error` terminal with the late
      RPC re-check a no-op (one submit, not two)
- [x] run `script -q /dev/null swift test --package-path HermesKit` — 1120 tests pass

### Task 4: Composer button swap

**Files:**
- Modify: `HermesMobile/Sources/Features/Chat/ComposerView.swift`
- Modify: `HermesMobile/Sources/Features/Chat/ChatView.swift`

- [x] `ComposerView`: replace the `isSending`-only swap — ➕ simpler than the planned
      `canSubmitOrQueue` param: pass `canQueue` itself (defaulted `false` so snapshot
      call sites and all existing baselines stay byte-identical); Stop shows only while
      `isSending && !canQueue` — which also keeps Stop reachable when a blocking card
      suppresses queuing — else the arrow, `.disabled(!(canSend || canQueue))`,
      accessibility label "Queue message" when queuing
- [x] `ChatView`: pass `canQueue: store.canQueue`
- [x] Stop stays reachable mid-turn by clearing the composer (`canQueue` loses content)
- [x] added `testComposer_midTurnQueueable` snapshot (run-twice recipe; asserts green);
      existing mid-turn baselines unchanged (all use an empty composer → Stop, as before)
- [x] `swift test` green; snapshot failures triaged — every other failing composer test
      is the documented runtime drift (incl. tests that never render the send button:
      recording bar, transcribing, ModelPickerSheet)

### Task 5: QueuedPromptsPanel view + ChatView integration

**Files:**
- Create: `HermesMobile/Sources/Features/Chat/QueuedPromptsPanel.swift`
- Modify: `HermesMobile/Sources/Features/Chat/ChatView.swift`
- Modify: `HermesMobileTests/ChatSnapshotTests.swift` (or a new
  `QueuedPromptsPanelSnapshotTests.swift`)

- [x] build `QueuedPromptsPanel`: compact rows — `lineLimit(2)` text (➕ needs
      `.fixedSize(horizontal: false, vertical: true)`, or the HStack's ideal-height
      pass truncates at ONE line — caught by the first recorded baseline), status icon
      (clock vs pause) + "Held — not sent automatically" header when parked,
      paperclip-count badge; hugs ≤3 rows, fixed `@ScaledMetric` height + internal
      scroll beyond (fixed, not `min(content, cap)` — a `ScrollView` swallows concrete
      height proposals, per the repo gotcha)
- [x] per-row context menu: Send Now, Edit (disabled while the composer has content —
      mirrors the reducer guard), Delete (destructive role)
- [x] integrated in `ChatView` above the `SlashSuggestionPanel` slot; emptiness-keyed
      animation matching the suggestion panel (nil under reduce-motion)
- [x] snapshot tests: clamp+badge, parked header/icons, >3-entry fixed-height scroll
      (run-twice recipe; all three assert green after the fixedSize re-record)
- [x] `make snapshot` triaged: only the documented drift fails; ➕ dropped three stray
      SettingsSnapshotTests baselines the full run auto-recorded (never committed,
      belong to the pending global re-record) and reverted `Package.resolved` churn

### Task 6: AppFeature detached-slot policy

**Files:**
- Modify: `HermesKit/Sources/HermesKit/AppFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/AppFeatureTests.swift`

- [x] extend the `.runningChanged(_, false)` detached-teardown guard with
      `!chat.hasQueuedWork` (queued entries OR a mid-drain `drainingEntry`); ➕ the
      idle-pop `chatViewDisappeared` guard gets the same check — an idle pop with a
      parked queue must not destroy the in-memory entries either
- [x] confirm the eventual teardown still runs when the queue empties and the last
      drained turn ends while detached (asserted in the drain test's second half)
- [x] write tests: detached turn-end with queued entries keeps the slot and drains
      (then tears down once empty); parked queue on a detached slot keeps the slot
      without draining (zero submits); idle pop with queued work keeps the slot
- [x] run `script -q /dev/null swift test --package-path HermesKit` — 1123 tests pass

### Task 7: Verify acceptance criteria

- [x] simulator UI smoke (AXe-driven, `HERMES_DEMO=work` scenario temporarily seeded
      `isSending` + a live id — scaffolding reverted): mid-turn Stop → typing swaps to
      the send arrow (the "Queue message" a11y label resolves) → tap queues (panel row
      with clock icon, composer clears, Stop returns) → long-press shows Send Now /
      Edit / Delete → Edit lifts the text back into the composer → Delete removes the
      row. Auto-drain/park/server flows are TestStore-verified (no live agent was
      running); real-agent end-to-end stays the Post-Completion device check
- [x] edge cases covered by reducer tests: queue during slash exec; blocked by
      approval card; drain via idle hydrate after `.gatewayClosed`; two entries drain
      strictly one turn each; parked-not-drained; failed-drain re-park
- [x] full suite: 1123 tests pass after the scaffolding revert
- [x] snapshot suites: new baselines assert green; the rest is the documented drift
- [x] `tuist generate` + app build succeed with the new source files (smoke build)

### Task 8: [Final] Update documentation

- [x] add a prompt-queuing convention bullet to `CLAUDE.md` (client-side queue
      rationale — no server management API; park rules; send-now semantics;
      detached-slot policy; the fixed-height ScrollView cap rationale)
- [x] update `README.md` feature list ("Queue the next prompt while it works")
- [x] move this plan to `docs/plans/completed/`

## Post-Completion

**Manual verification:**
- Real-device pass: queue 2–3 prompts against a long-running turn, background the app
  mid-queue (grace persistence), reconnect after a socket drop, and confirm the panel's
  context menu (selection-vs-scroll precedence in the capped panel is a manual-check
  item, same caveat family as #59/#65).
- Against an OLD agent build: confirm mid-turn queuing works and drains normally
  (nothing is sent mid-turn, so no 4009s should ever surface outside the drain race).

**Follow-ups (explicit non-goals for v1):**
- Persist text-only queued entries in `ChatSnapshotClient` so a process kill doesn't
  drop them (attachment bytes stay out of GRDB regardless).
- Reconsider the parked-queue-on-detached-slot socket lifetime if the idle socket
  proves wasteful.
