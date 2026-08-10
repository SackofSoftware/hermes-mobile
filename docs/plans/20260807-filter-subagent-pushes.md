# Filter Subagent Pushes in the hermes-push Plugin (#64)

## Overview

- TestFlight feedback (issue #64): when a delegated subagent finishes, the user gets a
  "Turn complete" push even though the parent turn is still running — misleading noise.
- Root cause (verified in hermes-agent): `delegate_task` builds each subagent as a full
  `AIAgent` with `platform="subagent"` and its **own `session_id`**
  (`tools/delegate_tool.py:1367-1385`). The child runs the same conversation loop, so
  its turns fire the same `post_llm_call` / `on_session_end` hooks the plugin maps to
  `complete` / `error` pushes — with the *child's* session id. The policy's
  client-present gate can't suppress it (no client is bound to the child session) and
  the >10s duration gate passes because subagent tasks are long.
- Fix: filter internal-fork events in the **plugin** (`hermes-mobile-push-plugin`
  repo). `pre_llm_call`, `post_llm_call`, and `on_session_end` all forward
  `platform=getattr(agent, "platform", ...)`, so the plugin can skip a platform in
  `INTERNAL_PLATFORMS` (`"subagent"`, plus `"curator"` — see Solution Overview).
  Older agents that don't pass `platform` see `""` →
  today's behavior (fail-open, backward compatible).
- Bonus fix: `pre_tool_call` (which carries **no** `platform`) feeds the plugin's
  turn-session tracker used to correlate **approval** pushes. A subagent's tool calls
  can overwrite the tracker with the child session id, mis-routing an approval push to
  a chat with no approval card. An internal-session registry lets the plugin skip that
  recording, so the *parent's* tracker can never hold a fork's id (a hypothetical reused
  pool worker's own thread-local still could — see the ➕ refinement below) — but note this does NOT buy a
  parent-id guarantee for approvals raised *inside* a child; see the ⚠️ correction
  below for what it actually delivers.
- Deliberately kept: **approval** pushes for subagent commands (they block and need
  the user). Deliberately suppressed: subagent **complete** AND **error**
  (a child failure is handled by the parent, whose own turn is still running).
- ⚠️ [correction, review] The approval half of the bonus fix does **not** deliver a
  parent-id guarantee, and the docs no longer claim one. hermes-agent runs every
  delegated child's `run_conversation` on a `DaemonThreadPoolExecutor` worker —
  `_run_single_child` builds a FRESH one-worker executor per child (for the child
  timeout) and submits exactly one `run_conversation` into it, including from the
  batch path, whose reusable outer pool only ever runs `_run_single_child` itself
  and never a hook — and the plugin's turn tracker is a ContextVar +
  `threading.local`. So a child physically cannot corrupt the parent's tracker —
  the tracker guard and the `_on_session_end` teardown skip are defence-in-depth
  for an inline host — and an approval raised *inside* a child reads an EMPTY
  tracker, falling back to `session_key` (in practice such an approval fires with
  `surface="cli"` from the worker's non-interactive callback and is skipped
  entirely). ➕ [review 2, corrected by review 5] the *documented* guarantee is
  deliberately weaker than what the current agent produces: were two children ever
  to share one worker, the teardown skip would leave the first child's thread-local
  set and the second would read a stale **sibling** child's id rather than an empty
  tracker. Never the parent's — both are forks the app has no row for, so the
  user-visible outcome is unchanged. That reuse does NOT happen upstream today
  (fresh executor per child, above); it is a defensive characterization the plugin
  keeps because it does not control the agent's threading, modelled — explicitly as
  a shape the current agent does not produce — by
  `test_reused_pool_worker_may_hold_a_stale_sibling_id_never_the_parent`.
  The registry, being process-global, DOES work across that boundary,
  which is what makes the `platform`-less `pre_tool_call` filterable at all.
- ⚠️ [known gap, review] `agent/background_review.py` forks a review agent that
  **inherits the parent's `platform` and pins its `session_id` to the parent's**,
  then runs a full `run_conversation` on a daemon thread every few turns. It is
  indistinguishable from a real turn at the hook boundary, so this filter cannot
  suppress it: it still fires a spurious extra "Turn complete" for the user's own
  session ~30s-2min after the real one and resets/clears the parent's duration
  anchor. Documented in the plugin README / `triggers.py` / this repo's
  `CLAUDE.md` + `docs/architecture.md` as a second root cause needing a
  hermes-agent change — verify on the live agent before closing #64. ⚠️ that change
  must NOT be "just a distinct `platform`": because the fork shares the parent's
  `session_id`, deny-listing that platform would register the PARENT and suppress
  the user's own pushes (see the widening precondition under Development Approach).
- Out of scope (agreed): iOS fine-grained notification settings — once the subagent
  noise is gone, the complaint is fixed; per-trigger toggles are YAGNI. No iOS,
  gateway, or hermes-agent changes.

## Context (from discovery)

- All code changes land in the **plugin repo**:
  `/Users/eugene/Documents/Development/Personal/hermes-mobile-push-plugin` (public,
  `goncharik/hermes-mobile-push-plugin`; clone present, clean, on `2f1b1ea`). This
  plan lives in hermes-mobile (the tracker repo), like the original push plan.
- `triggers.py` — pure mapping layer: `map_complete` / `map_session_end` /
  `map_clarify` mappers, `TriggerDispatcher` hook callbacks, and the current-turn
  session tracker (`record_turn_session` / `current_turn_session`, contextvar +
  thread-local) that `map_approval` reads (commit `2f1b1ea` history).
- `__init__.py` — hook registration (`pre_approval_request`, `pre_tool_call`,
  `pre_llm_call`, `post_llm_call`, `on_session_end`); `_on_pre_llm_call` records the
  turn tracker + the policy's turn-start anchor (`note_turn_start`).
- `policy.py` — untouched by this plan (gates stay as they are; filtering happens
  before the policy ever sees a subagent payload).
- hermes-agent hook kwargs (reference clone `../hermes-agent`): `pre_llm_call`
  (`agent/turn_context.py:1027`), `post_llm_call` (`agent/turn_finalizer.py:515`),
  `on_session_end` (`agent/turn_finalizer.py:674`) all pass `platform`;
  `pre_tool_call` (`model_tools.py` `resolve_pre_tool_block`) does NOT.
- Tests: pytest in `tests/` (`test_triggers.py`, `test_wiring.py`, …), run via
  `make test` from the plugin repo root.

## Development Approach

- **Testing approach**: Regular (code first, then tests, per task)
- Complete each task fully before moving to the next; small focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that
  task — success and error scenarios both
- **CRITICAL: all tests must pass before starting next task** (`make test` in the
  plugin repo) — no exceptions
- **CRITICAL: update this plan file when scope changes during implementation**
- Backward compatibility is a hard requirement: events with no `platform` kwarg (old
  agents) and every platform value outside the deny-list must behave byte-identically
  to today. Only an EXACT match against `INTERNAL_PLATFORMS` is filtered —
  `{"subagent", "curator"}` as shipped (the plan originally scoped this to
  `"subagent"` alone; `"curator"` was added during review, see Solution Overview for
  why it is safe). Missing / empty / non-`str` / any other `platform` fails open.
  Adding a value to that set is the ONLY sanctioned way to widen the filter, and
  only for a platform no user-facing client can ever carry — **and only for a fork
  that carries its OWN `session_id`, never the parent's.** ⚠️ [precondition, review]
  `_on_pre_llm_call` files an internal-platform event's session id in the fork
  registry and all three pushing mappers suppress any event bearing a registered
  id, so deny-listing a fork that shares the parent's id (which is exactly what
  `agent/background_review.py` does — it pins `review_agent.session_id =
  agent.session_id`) would register the PARENT and silence the user's OWN
  complete/error pushes for the whole fork run — and until FIFO eviction if that
  fork's `on_session_end` never fires. One spurious extra push would become no
  pushes at all. The precondition lives on `INTERNAL_PLATFORMS` /
  `record_internal_session` in `triggers.py`, in the plugin README, and is
  characterized by `test_a_fork_sharing_the_parent_session_id_would_suppress_the_parent`
  (which monkeypatches the widening in, so it stays green if the platform is really
  added); the assertion that actually FAILS on a widening is
  `test_internal_platforms_is_the_single_deny_list`, whose message points back at the
  precondition.
- Commits in the plugin repo follow the same convention: capitalized verb, no
  conventional-commit prefixes, concise.

## Testing Strategy

- **Unit tests (pytest, plugin repo)**: mapper-level filtering (`test_triggers.py`),
  wiring-level behavior (`test_wiring.py`) — the registry lifecycle, the tracker
  guard, and the fail-open old-agent path.
- No iOS or gateway tests — those artifacts are unchanged.

## Progress Tracking

- Mark completed items with `[x]` immediately when done
- Add newly discovered tasks with ➕ prefix; blockers with ⚠️ prefix
- Keep plan in sync with actual work done

## Solution Overview

- **Platform filter at the mapping layer**: `map_complete` and `map_session_end`
  return `None` when `kwargs["platform"]` is an internal-fork platform. The mappers
  are the single choke point both dispatcher and tests exercise; the policy/sender
  never see the payload. ➕ [review] the deny-list is `INTERNAL_PLATFORMS =
  {"subagent", "curator"}`, not `"subagent"` alone: `agent/curator.py` forks the same
  way with `platform="curator"` and its own `session_id`, and that push lands on a
  session the app has no list row for (tapping it strands the user in a spurious
  empty chat). Every user-facing platform (`gateway` / `cli` / `api_server` /
  `telegram` / `discord` / `tui`) and every unknown value still fails open.
- **Internal-session registry** (module-level in `triggers.py`, mirroring the turn
  tracker's style): a lock-guarded, insertion-ordered set of session ids known to
  belong to a fork. ⚠️ [correction, review] populated by `pre_llm_call` and
  `post_llm_call` only — the two platform-carrying hooks that fire BEFORE a fork's
  session ends (`pre_llm_call` precedes the fork's first tool call, so the registry
  is warm in time); `on_session_end` **only ever prunes, never records** (its
  record call was dead and was deleted). Entries are discarded at that fork's
  `on_session_end` (in a `finally`, after the mapping decision). ⚠️ [correction, review] the prune path
  does **not** bound it — `on_session_end` is not guaranteed to fire (early returns
  that never reach `finalize_turn`; `delegate_task` abandons a timed-out child's
  worker thread) — so the registry is **hard-capped with FIFO eviction**
  (`_INTERNAL_SESSIONS_MAX`). Eviction is safe: session ids are `timestamp_uuid` and
  never reused.
- ➕ [review] All three *pushing* mappers (`map_complete` / `map_session_end` /
  `map_clarify`) consult the registry; the first two read `platform` as well (they
  are the only mappers whose hooks carry one), while `map_clarify` has **no
  `platform` to read** — `pre_tool_call` carries none, so the registry is its ONLY
  signal. `map_approval` is the deliberate exception and never filters. Verdict on the "is the registry arm
  reachable?" question: against today's hermes-agent it is **not** (all three
  platform-carrying hooks read the same `getattr(agent, "platform", None) or ""`),
  but it is kept — it costs one dict lookup, `pre_tool_call` proves hook-kwarg drift
  is a real shape, and it is what keeps the mappers' verdict in lockstep with
  `__init__._on_session_end`'s. Removing one arm without the other is what produced
  the task-3 bug. Recorded in `triggers.py`'s module docstring, where the code is.
- **Tracker guard**: `TriggerDispatcher.on_pre_tool_call` skips
  `record_turn_session` — and `map_clarify` skips mapping — when the incoming
  session id is in the registry (`pre_tool_call` has no `platform` of its own).
  Subagents are built with `clarify_callback=None`, so a subagent clarify should be
  impossible; the skip is belt-and-braces.
- **Turn-start anchor hygiene**: `_on_pre_llm_call` skips `note_turn_start` (and the
  turn tracker) for subagent calls — a child session must never own a policy anchor.

## Technical Details

- New in `triggers.py` (names as shipped after the review pass):
  - `PLATFORM_SUBAGENT` / `PLATFORM_CURATOR` constants + the `INTERNAL_PLATFORMS`
    frozenset; ONE predicate body `_is_internal_platform(kwargs) -> bool` (exact
    match against `INTERNAL_PLATFORMS` on a `str` only — no `str()` coercion, so
    a non-`str` fails open, `triggers.py:287-304`), with the public
    `is_internal_platform(**kwargs)` delegating to it (no duplicated body).
  - Registry API: `record_internal_session(session_id)`,
    `is_internal_session(session_id) -> bool`, `discard_internal_session(session_id)`
    — module functions over a `threading.Lock()`-guarded `OrderedDict[str, None]`
    (FIFO-capped), no-ops on empty ids (matches `record_turn_session` conventions).
  - `map_complete`: platform check first (cheapest), then the existing logic, then
    the registry check. `map_session_end` gates the same two signals but AFTER the
    completed/interrupted skip — otherwise every fork end logs a bogus "suppressed
    error" line for an event that was never going to push anyway; both orders
    return `None` for exactly the same events (`triggers.py:614-621`).
    `map_clarify` has no `platform` kwarg
    to check at all (`pre_tool_call` carries none) — it filters on the registry
    alone, after the `tool_name` filter. ⚠️ [deviation]
    the mappers are **no longer pure** — `map_clarify` already read the registry, and
    hoisting the check to the dispatcher would let a direct mapper call (which the
    wiring tests make) bypass it.
  - `TriggerDispatcher.on_post_llm_call`: records the session id into the registry
    when the event is internal-platform (so even a fork whose `pre_llm_call` was
    missed still self-identifies in time to keep the turn-tracker clean).
    `TriggerDispatcher.on_session_end` does **not** record — ⚠️ [correction, review]
    that call was dead (the id is discarded in the same invocation) and was deleted;
    it only discards the id, in a `finally` around the dispatch, on EITHER signal
    (platform kwarg or registry).
  - `TriggerDispatcher.on_pre_tool_call`: guard `record_turn_session` and the clarify
    mapping behind `not is_internal_session(session_id)`, resolving the id with the
    same `_hook_session_id` helper `map_clarify` uses so guard and mapper cannot
    disagree about which session an event belongs to.
- `__init__.py` `_on_pre_llm_call`: when internal-platform → `record_internal_session`
  and return early (no `record_turn_session`, no `note_turn_start`).
- Docstrings: update the module docstring's "How the events surface" section and
  `__init__.py`'s hook comments to document the subagent story (they are the
  plugin's living spec).
- `__init__.py` `_on_session_end`: an internal fork's end still dispatches (no push,
  registry pruned) but SKIPS the parent's anchor/tracker teardown. Defence-in-depth
  given the thread boundary; also what keeps this verdict in lockstep with
  `map_session_end`'s.
- Payloads, gateway contract, iOS app: unchanged. Version bump `0.1.0` → `0.2.0` in
  `pyproject.toml`, `plugin.yaml` **and `dashboard/manifest.json`** (all three carry
  a version field), plus a README *Update* section with the one-line changelog.

## What Goes Where

- **Implementation Steps** (`[ ]` checkboxes): plugin-repo code + tests, this repo's
  issue/docs bookkeeping.
- **Post-Completion** (no checkboxes): deploying the updated plugin to the agent
  host, live verification.

## Implementation Steps

### Task 1: Platform filter + subagent-session registry in `triggers.py`

**Files (plugin repo `../hermes-mobile-push-plugin`):**
- Modify: `triggers.py`
- Modify: `tests/test_triggers.py`

> ℹ️ The checkboxes in Tasks 1–2 name the PRE-RENAME API (`is_subagent_platform` /
> `record_subagent_session` / …) and the pre-review gate order (they say
> `map_session_end` filters *before* the completed/interrupted logic; it now
> filters after it). Review renamed the whole family to `is_internal_platform` /
> `record_internal_session` / … when the deny-list grew past `"subagent"`, and
> inverted that one gate order. Left verbatim as the historical record;
> **Technical Details above carries the shipped names and gate order.**

- [x] add `PLATFORM_SUBAGENT`, `_is_subagent_platform`, and the lock-guarded
      subagent-session registry (`record_subagent_session` / `is_subagent_session` /
      `discard_subagent_session`, empty-id no-ops)
      ➕ also added the public kwargs-taking `is_subagent_platform(**kwargs)` (used by
      `__init__.py` in task 2 / tests) and `clear_subagent_sessions()` (test hygiene,
      wired into the autouse `conftest.py` fixture next to `clear_turn_session`)
- [x] `map_complete`: return `None` on subagent platform (before session-id logic)
- [x] `map_session_end`: return `None` on subagent platform (before the
      completed/interrupted logic)
- [x] `map_clarify`: return `None` when `is_subagent_session(session_id)`
- [x] `TriggerDispatcher.on_post_llm_call` / `on_session_end`: record subagent ids
      into the registry; `on_session_end` discards after dispatch;
      `on_pre_tool_call`: skip `record_turn_session` for registered subagent ids
- [x] update module docstring (subagent story)
- [x] write tests: subagent `post_llm_call` maps to no payload; subagent
      `on_session_end` (failure shape) maps to no payload; missing `platform` and
      `platform="gateway"`/`"cli"` still map (old-agent fail-open); registry
      record/lookup/discard incl. empty-id no-ops; subagent `pre_tool_call` neither
      records the turn tracker nor emits clarify; parent approval after a subagent
      tool call still correlates to the parent session id; `on_session_end` prunes
      the registry entry
- [x] run `make test` in the plugin repo — must pass before task 2 (151 passed)

### Task 2: Hook wiring guard in `__init__.py`

**Files (plugin repo `../hermes-mobile-push-plugin`):**
- Modify: `__init__.py`
- Modify: `tests/test_wiring.py`

- [x] `_on_pre_llm_call`: subagent platform → `record_subagent_session` + early
      return (no turn tracker write, no `note_turn_start`)
      ➕ also guarded `_on_session_end`: a subagent's session end (platform kwarg
      OR a registered child id, read BEFORE dispatch since the dispatcher prunes
      the registry) still dispatches (mapping → no push, registry pruned) but
      SKIPS the parent teardown — the unconditional `clear_turn_session()` would
      otherwise wipe the parent's approval turn-tracker mid-parent-turn, exactly
      the mis-routing this plan set out to fix
- [x] update the hook-registration comments to document subagent filtering
      (plus a "Subagents (delegated tasks) never push" section in the module
      docstring — the plugin's living spec)
- [x] bump version `0.1.0` → `0.2.0` in `pyproject.toml` (and `plugin.yaml` if it
      carries a version) — both carried one
- [x] write wiring tests: subagent `pre_llm_call` sets no policy turn anchor and
      leaves the turn tracker untouched; full flow — parent turn start → subagent
      turn start/complete → parent complete — emits exactly ONE `complete` push
      (the parent's, with the parent session id); subagent error emits nothing;
      parent error still emits
      ➕ plus: child end preserves the parent tracker AND a following parent
      approval still correlates to the parent id; old-agent path (no `platform`
      kwarg anywhere) unchanged end to end
- [x] run `make test` — must pass before task 3 (157 passed; verified
      non-vacuous — neutering both guards turns 2 of the new tests red)

### Task 3: Verify acceptance criteria

- [x] subagent `complete` and `error` pushes are suppressed at the mapper AND never
      reach the sender in the wiring flow test
      — mapper: `test_subagent_post_llm_call_maps_to_nothing` /
      `test_subagent_session_end_failure_maps_to_nothing`; sink-level:
      `test_subagent_turn_emits_exactly_one_parent_complete` /
      `test_subagent_error_emits_nothing` (the `_CountingSink` IS
      `hermes_push._sender`, so `send` is provably never called). ➕ added
      `test_subagent_pushes_never_reach_the_real_gateway_sender` — drives the REAL
      `GatewaySender` + recording HTTP client, drained via `shutdown(wait=True)`,
      asserting the recorded gateway request bodies are exactly one `complete` for
      `parent` (non-vacuous in both directions: the parent's push IS recorded)
      ⚠️ [deviation] criterion did NOT hold as shipped — a session id already
      identified as a child still pushed `complete`/`error` when a later hook
      omitted `platform`, while `__init__._on_session_end` simultaneously
      classified that same event as a subagent (skipping the parent teardown),
      and the registry entry leaked forever. FIXED: `map_complete` /
      `map_session_end` now consult `is_subagent_session` too (mirroring
      `map_clarify`), and the dispatcher's `on_session_end` prunes on EITHER
      signal. Regression test:
      `test_registered_child_is_filtered_even_without_a_platform_kwarg`
- [x] parent pushes (complete/error/approval/clarify) are byte-identical to before —
      no payload or policy change for non-subagent events
      — verified by a differential harness that loads `git show 2f1b1ea:triggers.py`
      as a standalone module beside the current one and compares outputs field by
      field over 400 mapper cases (8 non-subagent `platform` variants × 5
      session-id shapes × every `completed`/`interrupted` combo × 4 `tool_name`s ×
      4 approval `surface`s, both empty and populated turn-tracker) plus 8 full
      dispatcher flows (`pre_tool_call` ×2 → `pre_approval_request` →
      `post_llm_call` → `on_session_end`), asserting both the emitted payload list
      and the resulting `current_turn_session()`: zero mismatches. Also
      `test_non_subagent_platforms_still_map`, plus new
      `test_parent_clarify_still_maps_while_a_child_is_registered` /
      `test_parent_complete_and_error_still_map_while_a_child_is_registered`
      (the registry must only ever suppress the ids actually in it)
- [x] old-agent path (no `platform` kwarg anywhere) byte-identical to before
      — the `{}` (no-`platform`) row of the differential harness above is exactly
      this path; plus `test_old_agent_pre_llm_call_without_platform_unchanged`
      (anchor + tracker + complete + teardown) and new
      `test_old_agent_clarify_and_approval_path_unchanged` (the other two
      triggers: clarify still pushes and still suppresses the trailing complete,
      approval still correlates via the tracker not the `session_key` fallback)
- [x] approval correlation: tracker never holds a subagent session id
      — new `test_turn_tracker_never_holds_a_child_id_at_any_point` walks the
      realistic hook order for a parent delegating two nested children and asserts
      the invariant after EVERY hook (not just at the end — an approval can fire
      at any of those moments); plus
      `test_subagent_pre_llm_call_sets_no_anchor_and_no_tracker`,
      `test_subagent_pre_tool_call_does_not_record_turn_tracker`,
      `test_parent_approval_after_subagent_tool_call_keeps_parent_session`,
      `test_subagent_end_keeps_parent_turn_tracker_for_approval`, and new
      `test_subagent_end_without_platform_kwarg_still_spares_the_parent`
      (covers the previously-untested registry half of `_on_session_end`'s `or`)
- [x] full suite green: `make test` in the plugin repo — 164 passed (was 157;
      +7 tests). Every guard proven non-vacuous: all 10 subagent guards across
      `triggers.py` + `__init__.py` were neutered one at a time and each turned
      the suite red, restoring cleanly (harness output in the progress log)

### Task 4: [Final] Documentation + issue bookkeeping

- [x] update the plugin repo `README.md` (triggers section: subagent events are
      filtered; which hooks carry `platform`)
      — new "Subagents (delegated tasks) never push" subsection under *Triggers*:
      per-hook table (which of the five carry `platform`, what each does for a
      child, why `pre_approval_request` deliberately still pushes), the registry's
      role for the two `platform`-less hooks, and the fail-open backward-compat
      rule; *Status* now links it
- [x] update this repo's `CLAUDE.md` push-notifications bullet with one line: the
      plugin filters `platform == "subagent"` events (complete/error) and guards the
      approval turn-tracker against subagent session ids
- [x] commit + push the plugin repo changes; comment on hermes-mobile issue #64 with
      the fix summary (close after live verification)
      (committed; push + issue #64 comment deferred to post-review — outward-facing,
      needs human go-ahead)
- [x] move this plan to `docs/plans/completed/`
      (handled by the exec runner at completion)

## Post-Completion

**Deployment (manual — plugin is a directory install):**
- On the agent host: `git -C ~/.hermes/plugins/hermes-push pull`, then restart the
  agent (pip is NOT used — hermes-agent only mounts directory plugins).

**Live verification:**
- Start a turn that spawns a subagent (e.g. a delegated research task) with the app
  backgrounded: no push when the subagent finishes; exactly one "Turn complete" push
  when the parent turn actually ends (if >10s).
- Do it **twice — once with a single delegated task and once with a batch of ≥2**
  (only the batch path fans out across worker threads; the in-thread suite models
  the inline shape).
- Trigger an approval inside a subagent-spawning turn: the PARENT's own approval push
  arrives and tapping it opens the parent chat with the card. An approval raised
  *inside* the child is expected to either not push at all (`surface="cli"` from the
  worker's non-interactive callback) or to carry the child's `session_key` — NOT the
  parent's id. That is the documented limit, not a regression.
- **Watch for a second, later "Turn complete" ~30s-2min after the real one** — that is
  the unfixed `background_review` fork (see Overview). If it appears, #64 is only
  partly resolved and the remaining half needs a hermes-agent change.
- ⚠️ **Do NOT close #64 on this change alone.** The delegate-subagent half is fixed and
  test-pinned; the `background_review` half is reachable by DEFAULT (nudge intervals
  default to 10 turns and are gated only on the `skill_manage` / `memory` toolsets
  being present, and the policy's 5s dedup window cannot absorb a fork that lands
  ~30s-2min later). A second-order effect: the review fork's `on_session_end` clears
  the PARENT's turn-start anchor, so a genuinely new parent turn can lose its anchor
  and fail the >10s duration gate **open** — an extra push, not a lost one.
  Keep #64 open until the live check above passes, and file an upstream
  hermes-agent ask — there is no plugin-side fix. ⚠️ [correction, review] the ask is
  a fork signal the internal-session registry never consumes: a `fork=True` /
  `is_fork` hook kwarg, or its OWN `session_id` for the review fork. **Do not ask
  for a distinct `platform` alone**: the fork pins `review_agent.session_id =
  agent.session_id`, so adding that platform to `INTERNAL_PLATFORMS` would file the
  PARENT's id in the registry and silence the user's own complete/error pushes for
  the whole review run (worse than the extra push it fixes). See the widening
  precondition under Development Approach; characterized by
  `test_a_fork_sharing_the_parent_session_id_would_suppress_the_parent`, with the
  actual widening tripwire in `test_internal_platforms_is_the_single_deny_list`.
- Close #64 only if the live check shows no second push; otherwise re-scope it to
  the `background_review` half and file the upstream ask.

**External systems:**
- Gateway and iOS app unchanged — no deploys there.
