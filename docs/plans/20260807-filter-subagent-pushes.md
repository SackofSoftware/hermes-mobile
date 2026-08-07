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
- Fix: filter subagent-originated events in the **plugin** (`hermes-mobile-push-plugin`
  repo). `pre_llm_call`, `post_llm_call`, and `on_session_end` all forward
  `platform=getattr(agent, "platform", ...)`, so the plugin can skip
  `platform == "subagent"`. Older agents that don't pass `platform` see `""` →
  today's behavior (fail-open, backward compatible).
- Bonus fix: `pre_tool_call` (which carries **no** `platform`) feeds the plugin's
  turn-session tracker used to correlate **approval** pushes. A subagent's tool calls
  can overwrite the tracker with the child session id, mis-routing an approval push to
  a chat with no approval card. A subagent-session registry lets the plugin skip that
  recording, so approval pushes always correlate to the parent/UI session.
- Deliberately kept: **approval** pushes for subagent commands (they block and need
  the user; with the tracker fix they carry the parent chat's id, where the card
  actually appears). Deliberately suppressed: subagent **complete** AND **error**
  (a child failure is handled by the parent, whose own turn is still running).
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
  agents) and every non-`"subagent"` platform value must behave byte-identically to
  today. Only exact `platform == "subagent"` is filtered.
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
  return `None` when `kwargs["platform"] == "subagent"`. The mappers are the single
  choke point both dispatcher and tests exercise; the policy/sender never see the
  payload.
- **Subagent-session registry** (module-level in `triggers.py`, mirroring the turn
  tracker's style): a lock-guarded set of session ids known to belong to subagents.
  Populated from any hook that carries `platform == "subagent"` + a session id
  (`pre_llm_call` fires before a child's first tool call, so the registry is warm in
  time); entries discarded at that child's `on_session_end` (after the mapping
  decision), keeping the set bounded by concurrently-running children.
- **Tracker guard**: `TriggerDispatcher.on_pre_tool_call` skips
  `record_turn_session` — and `map_clarify` skips mapping — when the incoming
  session id is in the registry (`pre_tool_call` has no `platform` of its own).
  Subagents are built with `clarify_callback=None`, so a subagent clarify should be
  impossible; the skip is belt-and-braces.
- **Turn-start anchor hygiene**: `_on_pre_llm_call` skips `note_turn_start` (and the
  turn tracker) for subagent calls — a child session must never own a policy anchor.

## Technical Details

- New in `triggers.py`:
  - `PLATFORM_SUBAGENT = "subagent"` constant; helper
    `_is_subagent_platform(kwargs) -> bool` (exact match on
    `str(kwargs.get("platform") or "")`).
  - Registry API: `record_subagent_session(session_id)`,
    `is_subagent_session(session_id) -> bool`, `discard_subagent_session(session_id)`
    — module functions over a `threading.Lock()`-guarded `set[str]`, no-ops on empty
    ids (matches `record_turn_session` conventions).
  - `map_complete` / `map_session_end`: platform check first (cheapest), then the
    existing logic. `map_session_end` additionally calls
    `record_subagent_session`/`discard` bookkeeping from the dispatcher, not inside
    the pure mapper (mappers stay pure).
  - `TriggerDispatcher.on_post_llm_call` / `on_session_end`: record the session id
    into the registry when the event is subagent-platform (so even if `pre_llm_call`
    was missed, later events self-identify); `on_session_end` discards the id after
    dispatch.
  - `TriggerDispatcher.on_pre_tool_call`: guard `record_turn_session` and the clarify
    mapping behind `not is_subagent_session(session_id)`.
- `__init__.py` `_on_pre_llm_call`: when subagent-platform → `record_subagent_session`
  and return early (no `record_turn_session`, no `note_turn_start`).
- Docstrings: update the module docstring's "How the events surface" section and
  `__init__.py`'s hook comments to document the subagent story (they are the
  plugin's living spec).
- Payloads, gateway contract, iOS app: unchanged. Version bump `0.1.0` → `0.2.0` in
  `pyproject.toml` (behavioral change worth a marker; check `plugin.yaml` for a
  version field too).

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

- [ ] add `PLATFORM_SUBAGENT`, `_is_subagent_platform`, and the lock-guarded
      subagent-session registry (`record_subagent_session` / `is_subagent_session` /
      `discard_subagent_session`, empty-id no-ops)
- [ ] `map_complete`: return `None` on subagent platform (before session-id logic)
- [ ] `map_session_end`: return `None` on subagent platform (before the
      completed/interrupted logic)
- [ ] `map_clarify`: return `None` when `is_subagent_session(session_id)`
- [ ] `TriggerDispatcher.on_post_llm_call` / `on_session_end`: record subagent ids
      into the registry; `on_session_end` discards after dispatch;
      `on_pre_tool_call`: skip `record_turn_session` for registered subagent ids
- [ ] update module docstring (subagent story)
- [ ] write tests: subagent `post_llm_call` maps to no payload; subagent
      `on_session_end` (failure shape) maps to no payload; missing `platform` and
      `platform="gateway"`/`"cli"` still map (old-agent fail-open); registry
      record/lookup/discard incl. empty-id no-ops; subagent `pre_tool_call` neither
      records the turn tracker nor emits clarify; parent approval after a subagent
      tool call still correlates to the parent session id; `on_session_end` prunes
      the registry entry
- [ ] run `make test` in the plugin repo — must pass before task 2

### Task 2: Hook wiring guard in `__init__.py`

**Files (plugin repo `../hermes-mobile-push-plugin`):**
- Modify: `__init__.py`
- Modify: `tests/test_wiring.py`

- [ ] `_on_pre_llm_call`: subagent platform → `record_subagent_session` + early
      return (no turn tracker write, no `note_turn_start`)
- [ ] update the hook-registration comments to document subagent filtering
- [ ] bump version `0.1.0` → `0.2.0` in `pyproject.toml` (and `plugin.yaml` if it
      carries a version)
- [ ] write wiring tests: subagent `pre_llm_call` sets no policy turn anchor and
      leaves the turn tracker untouched; full flow — parent turn start → subagent
      turn start/complete → parent complete — emits exactly ONE `complete` push
      (the parent's, with the parent session id); subagent error emits nothing;
      parent error still emits
- [ ] run `make test` — must pass before task 3

### Task 3: Verify acceptance criteria

- [ ] subagent `complete` and `error` pushes are suppressed at the mapper AND never
      reach the sender in the wiring flow test
- [ ] parent pushes (complete/error/approval/clarify) are byte-identical to before —
      no payload or policy change for non-subagent events
- [ ] old-agent path (no `platform` kwarg anywhere) byte-identical to before
- [ ] approval correlation: tracker never holds a subagent session id
- [ ] full suite green: `make test` in the plugin repo

### Task 4: [Final] Documentation + issue bookkeeping

- [ ] update the plugin repo `README.md` (triggers section: subagent events are
      filtered; which hooks carry `platform`)
- [ ] update this repo's `CLAUDE.md` push-notifications bullet with one line: the
      plugin filters `platform == "subagent"` events (complete/error) and guards the
      approval turn-tracker against subagent session ids
- [ ] commit + push the plugin repo changes; comment on hermes-mobile issue #64 with
      the fix summary (close after live verification)
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion

**Deployment (manual — plugin is a directory install):**
- On the agent host: `git -C ~/.hermes/plugins/hermes-push pull`, then restart the
  agent (pip is NOT used — hermes-agent only mounts directory plugins).

**Live verification:**
- Start a turn that spawns a subagent (e.g. a delegated research task) with the app
  backgrounded: no push when the subagent finishes; exactly one "Turn complete" push
  when the parent turn actually ends (if >10s).
- Trigger an approval inside a subagent-spawning turn: push arrives and tapping it
  opens the parent chat showing the approval card.
- Then close issue #64.

**External systems:**
- Gateway and iOS app unchanged — no deploys there.
