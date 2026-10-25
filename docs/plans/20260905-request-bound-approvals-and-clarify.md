# Request-bound prompts over server→client requests (#97)

## Overview

Move every blocking prompt the app renders (approval, clarify, sudo, secret) onto Hermes'
server→client JSON-RPC requests ("protocol v7"). Bind each card to the server's exact request,
restore open prompts on reconnect from `open_requests`, tear cards down on `request.cancel`, add
the multi-select, batch and "Other" clarify forms, and keep agents that predate v7 working as
they do today.

- **Problem.** The original version of this plan (2026-09-05) was verified against upstream
  `63279301bc` (2026-09-03). Ten days later upstream replaced the `*.request` events and
  `*.respond` methods with server→client requests (`ebe8cda8ea`/`9f7f2f28c0`, tag v2026.9.14).
  Since `f9d178f78e` (v2026.9.21) the server refuses to send a prompt at all when no attached
  client advertised `client.capabilities {server_requests: true}`. The app on `main` never
  advertises. So on any current agent where the phone is the only client: approvals are
  withdrawn ("update the Hermes app"), clarify returns `undelivered`, and sudo/secret come back
  skipped — instantly, with no card. On v2026.9.14 itself the frames arrive, the app drops them,
  and the agent waits out the deadline. Today's `clarify.respond` / `sudo.respond` /
  `secret.respond` calls hit `-32601` on v7 and are swallowed by `try?`.
- **Base: PR #116, merged as `e8fb410` ("Support server-request approval prompts").** A
  contributor PR carried the v7 wire layer and approval presentation; it is on `main` (see
  "Base" below for what landed) and is the foundation of this plan. Queueing, cancel, replay
  and every other kind are built here, generalized from the start.
- **Benefit.** Prompts work again on current agents. The card the user answers is the request
  the server resolves, and an answer that arrives too late says so ("Already handled
  elsewhere"). A reconnect or push-tap restores the real card (command, question, locked batch
  answers) instead of a generic one. Every clarify form the desktop renders works on the phone.
  The phone never widens the server's choice set and never steals a prompt meant for a desktop
  sharing the session.
- **Integration.** Everything rides the existing `pendingInteraction` / `present(_:)` /
  `pendingInteractionToken` contract and the single `hydrate` → `applyActivate` funnel. The
  base's `InboundFrame.serverRequest` routing is generalized from approval to every prompt kind.
  No `AppFeature` routing changes.

Sibling issues split out of #96: #98 (event replay) and #99 (native Projects). Out of scope
here. Multi-slot fan-out stays #90.

**Release gate.** The base makes the phone advertise, so the server starts routing every prompt
to it. Until Tasks 3–6 land, the phone stays silent on clarify/sudo/secret (see the decline
rule), and a phone-only agent waits out those deadlines (clarify up to 3600 s). `main` has
carried the base since `e8fb410`: do not ship a TestFlight build from `main` without Tasks 3–6.

## Context (from discovery)

Re-verified 2026-10-12 against upstream `main` `82ef40ab29`/`3f2abce7f4` (the files below are
byte-identical to release `v0.21.7`) via `git show upstream/main:<path>` in the sibling clone
`/Users/eugene/Documents/Development/Personal/hermes-agent` (the checked-out tree is stale).

**Release timeline.** Upstream switched tag schemes after `v2026.9.24` (next: `v0.21.6`
2026-10-08, `v0.21.7` 2026-10-12; `main` reports version `0.0.0`). Never gate on a version
string; detect features.

| Releases | Prompt wire |
|---|---|
| ≤ v2026.9.11 | Legacy: `approval.request` / `clarify.request` / `sudo.request` / `secret.request` events, `*.respond` RPCs, `clarify.expire`, `pending_clarify`. `desktop_contract` = 6. |
| v2026.9.14 | v7 server requests. No `client.capabilities` (`-32601`); frames go to every client. Intermediate clarify shapes. |
| v2026.9.21, v2026.9.24 | Adds `client.capabilities`; non-advertising clients are refused. |
| v0.21.6+ | Adds the 4404 decline (`declines_not_shown`) and the single clarify shape (always `questions`, `null` = skipped). |

**Wire-generation signal.** `info.desktop_contract` (in `session.create` / `session.resume` /
`session.activate` `info` and in `session.info` events; `contracts/common.py:88`, typed
`int | str | None`): `>= 7` = v7, 6 on v2026.9.11. Receiving needs no gate (the two wires never
coexist on one server); the signal is for proactive choices only (push-tap recovery, legacy
clearing). `-32601` on `client.capabilities` does NOT mean legacy: v2026.9.14 is v7 without it.

**`client.capabilities`** (`methods_voice.py:442-450`, `contracts/liveness.py:29-48`).
`{"server_requests": true}` → `{"server_requests": [methods…], "declines_not_shown": true}`
(the last key only on v0.21.6+). Send once per connection after `gateway.ready`; the
advertisement is per transport and dies with the socket. A session counts as answerable when
any attached WS client advertised (or none is attached — the request then waits for the
reconnect replay; `session_transports.py:38-47`). A request raised before the advertisement is
processed is refused while the phone is the only client, so the app advertises before its
first `session.resume` / `session.create` on every connect.

**Server request frame** (`server_requests.py:67,82-84`):
`{"jsonrpc":"2.0","id":"srq-<12 hex>","method":"<kind>","params":{"session_id":"<live sid>",…}}`.
Request frames carry no `seq` and are not in the replay ring. A response frame
`{"jsonrpc":"2.0","id":"srq-…","result":{…}}` gets no reply. Any error response except 4404
settles the request as unanswered (`result=None`, no `request.cancel`); for a batch clarify that
discards its locked answers (`outcome: "undelivered"`); for an approval it withdraws instead of
denying. A response for an id no longer open is silently dropped.

**`request.answer {id, result}` → `{status: "ok"|"expired"}`** (`methods_prompt.py:1222-1235`,
since v2026.9.14). Runs the same `resolve_response` as a response frame, plus the compute-host
relay, and reports whether the request was still open. Upstream calls it the proxy for clients
that did not receive the frame; it is fully equivalent and acknowledged.

| Method | Params (plus `session_id`) | Answer `result` | Skip / deny | Default timeout |
|---|---|---|---|---|
| `approval` | `request_id` (queue id), `command` (redacted), `description`, `pattern_key(s)`, `allow_session`, `allow_permanent`, `choices`, `smart_denied?` | `{choice}` (`all` is ignored with a `request_id`) | `{choice:"deny"}` | `approvals.timeout`, 300 s |
| `clarify` v0.21.6+ | `questions: [{qid, question, choices\|null, multi_select}]`, `answers?` (locks, on replay) | `{answers: {qid: text\|null}}` | `{}` = cancel all; `null` = skip one | `agent.clarify_timeout`, **3600 s**; `<= 0` = unlimited |
| `clarify` v2026.9.14–.24 | single: `question, choices, multi_select?`; batch: `questions` | single `{answer}`; batch `{answers}` (`dict[str,str]`) | `{answer:""}` | same |
| `sudo` | `command` (from v2026.9.21; empty params on .14) | `{value}` | `{value:""}` | 120 s |
| `secret` | `env_var`, `prompt`, `metadata?` | `{value}` | `{value:""}` | 300 s |

Answer in the shape the request arrived in. Clarify details: qids `q0..q4` (max 5 questions,
max 4 choices); the first of ≥ 2 choices arrives suffixed `" (Recommended)"` (presentation
only; the server strips it; send the bare text, as desktop does); multi-select answer is a
JSON-array string (`"[\"A\",\"B\"]"`); the tool schema tells the model the UI adds an "Other"
free-text row to every question with choices (`clarify_tool.py:8,146`; desktop renders it), and
a typed answer is a plain string (`_clean_answer`). Sources: `contracts/server_requests.py`,
`server.py:765-778,1398-1427`, `tools/clarify_tool.py`, `agent_callbacks.py:231-279`.

**Methods the app does not render.**
- Window-owned bridges `terminal.read` / `preview.read` / `window.read` / `preview.act` / `tour`.
  The 4404 (`NOT_SHOWN_CODE`) decline is scoped to these: it does not settle until every
  answering client attached to the session declined (`server_requests.py:233-262`). Desktop
  sends 4404 only when the backend counts declines, and nothing otherwise
  (`apps/shared/src/json-rpc-channel.ts:376-380`).
- Prompts: `setup_choose`, `vault.unlock_prompt` / `vault.save_login` / `vault.code`, sessionless
  `display.install.sudo`. Never 4404 these: when every client declines, the request settles with
  `{"value": "{\"success\": false, …}"}` (`server_requests.py:257`), and `_ask` returns that
  string verbatim — it would reach the password manager as a master password or 2FA code
  (`agent_callbacks.py:265-279`). An error response (`-32601`) settles at once and kills a
  desktop user's card on a shared session.

**`request.cancel`** — a normal event (`seq`-stamped, replayable):
`{"type":"request.cancel","payload":{"id":"srq-…","method":"approval","reason":"timeout"}}`;
reasons `timeout | interrupted | shutdown | resolved | session_closed` (approval callers may pass
their own wording). It is **not** emitted when another client answered by response frame, so a
card on the phone only learns that when its own answer comes back `expired`, or at turn end
(`message.complete`, error), as desktop does (`message-stream.ts:355-365`).

**Reconnect: `open_requests`** (`server_requests.py:86-92,349-353`; `contracts/sessions.py`) —
`[{id, method, params}]`, oldest first; `params.answers` carries batch-clarify locks so far.
Present on `session.resume` (live reattach) and `session.activate` when non-empty, always on
`session.events.since`. A cold resume of a stored session has none. It does not depend on
`running`: a reconnect can return a `running=false` snapshot while a bridge is still parked on an
open request (`secret_cb` can fire from background workers). Desktop re-delivers each entry
through the live handlers, treats absence as authoritative, and keeps a live request's card on a
`running=false` snapshot (#83319, `session-info.ts:320-327`).

**Still live, now fallbacks** — `pending_approval` in resume (oldest queue entry; its
`request_id` is the queue id, also `params.request_id` in the `approval` open-request entry — not
the `srq-` id). `approval.pending {session_id}` → `{approvals: […]}`. `approval.respond
{session_id, choice, request_id}` → `{resolved: n}` (legacy answer path; on v7 it also resolves
and emits `request.cancel{reason:"resolved"}`). `approval.received` is a server-side no-op now —
dropped from this plan.

**Concurrency** — a session can hold several open requests (parallel tool calls / subagents each
queue an approval). Desktop queues approvals per session and shows the head; clarify, sudo and
secret are one slot per session.

**Push** — upstream hook order is unchanged (`pre_approval_request` fires before the request
frame). With no client attached (the backgrounded-socket case the push targets) the request
waits in `open_requests`, so the resume after a tap restores the exact card. Plugin-side
behaviour unverified.

**Base: PR #116, merged as squash commit `e8fb410` (2026-10-25).** Verified in Task 1 against
the code. It delivers:
- `InboundFrame.serverRequest(id:method:params:)` (string `id` + `method`, classified before
  int-id responses).
- `GatewayConnection` (`HermesGatewayClient.swift`): `handle(frame:)` presents a decodable
  `approval` synchronously (`presentApproval` sets `ApprovalRequest.serverRequestID` and yields
  `GatewayEvent.approvalServerRequest`); anything else goes to `handleServerRequest` in a `Task`
  (never awaited inside the receive loop). Decline rule: 4404 (`"Not shown on this client"`,
  encoded by `wireEncoder`) only for the five window-owned methods and only once the
  advertisement returned `declines_not_shown: true`; every other method gets nothing; a
  malformed approval (params `null`, non-object, wrong types, missing) is denied through
  `send("request.answer", {id, result:{choice:"deny"}})`. There is no raw-response
  `respond(id:result:)` API.
- Advertisement: `startAdvertisement()` on the `gateway.ready` frame launches a `Task`
  (`retryAdvertisement`) and `.ready` is yielded at once, NOT after the advertisement. Success
  stores `declinesNotShown`; `-32601` stops silently (`advertisementUnsupported`); any other
  failure retries with 2 s → 30 s backoff for the connection's life and yields one
  `GatewayEvent.serverRequestFailed` banner per connection ("Couldn’t enable approval
  requests: …").
- `GatewayEvent.serverRequestFailed(message:)` — a local, non-turn-ending failure (advertisement,
  decline send, automatic deny): sets `errorBanner`, leaves `isSending` alone.
- `ApprovalRequest.requestID` (`request_id`, the queue id), `serverRequestID` (set by the
  client, never decoded), `choices`, `allowsSessionChoice` / `allowsOnce` (empty `choices` =
  permissive). `offersSessionApproval` now also requires `allowsOnce && allowsSessionChoice`.
  `ApprovalCardView` hides Approve when `!allowsOnce`.
- `ChatFeature`: `.approvalServerRequest` → `present(.approval)` + clear the push-tap hint.
  `respondToApproval` ignores Approve when `!allowsOnce`, narrows `session` → `once` when
  `!allowsSessionChoice`, and with a `serverRequestID` sends `request.answer {id,
  result:{choice}}`: `ok` → nothing, `expired` → `approvalRespondResult(resolved: 0)` ("Already
  handled elsewhere"), anything else or a throw → banner. The card is cleared and the
  "Approved"/"Denied" row appended optimistically before the RPC. Legacy `approval.respond`:
  unchanged without `request_id`; with one (and no srq id) it sends `{session_id, request_id,
  choice, all:false}`.
- Tests: `ServerRequestTests` (decline matrix, malformed deny, retry, wire order, failures),
  `ChatInteractionTests` (answer per status, deny/session choice, `request_id` legacy params),
  `JSONRPCTests`, `GatewayEventDecodingTests`, `HermesGatewayClientTests`. No snapshot.
- Docs: server-request paragraphs in `docs/features/approvals.md` and `docs/architecture.md`
  (`CLAUDE.md` untouched).

Every fix the plan asked of #116 landed (`wireEncoder` on every outbound frame, no `try?` on the
advertisement or sends, the three-way decline rule, `request.answer` + `expired`, deny on a
malformed approval, reducer tests). The gaps against this plan's design are the ➕ items in
Tasks 2, 3, 7, 9 and 10; interim risks are the ⚠️ notes in Tasks 2, 3 and 8.

**App today (`main`, including the base)**
- `HermesKit/Sources/HermesKit/Models/ApprovalRequest.swift` — `ApprovalRequest` (with the
  base's `requestID` / `serverRequestID` / `choices`), `ClarifyRequest` (`requestID`,
  `question`, `choices`).
- `HermesKit/Sources/HermesKit/Models/GatewayEvent.swift` — `.approvalRequest` /
  `.approvalServerRequest` / `.serverRequestFailed` / `.clarifyRequest` /
  `.sudoRequest(SecretPrompt)` / `.secretRequest(SecretPrompt)`;
  `SecretPrompt` requires `request_id` (v7 sudo/secret params carry none); `SessionInfo`
  (synthesized `Decodable`, `:253-286`).
- `HermesKit/Sources/HermesKit/Models/GatewayLogEntry.swift` — exhaustive name/summary switches.
- `HermesKit/Sources/HermesKit/Models/JSONRPC.swift` — `InboundFrame`, `JSONRPCRequest.wireEncoder`.
- `HermesKit/Sources/HermesKit/Clients/HermesGatewayClient.swift` — connection actor
  (`GatewayConnection`); frames are handled on the actor's receive loop; the base's
  `handleServerRequest` / `presentApproval` / advertisement retry live here.
- `HermesKit/Sources/HermesKit/Models/Session.swift` — `ActivateResponse` (`messages`, `info`,
  `running`, `inflight`; `try? decodeIfPresent(SessionInfo…)` at `:185` drops the whole `info`
  if any field throws).
- `HermesKit/Sources/HermesKit/Features/ChatFeature.swift` — `PendingInteraction`
  (`.approval` / `.clarify` / `.secret(SecretKind, SecretPrompt)`), `present(_:)`,
  `expectsPendingApproval`, `recoveredApprovalRequest`, `applyActivate`, `respondToApproval`,
  `respondToClarify` and `respondToSecret` (both `try?`-swallowed), `clearStaleApproval`,
  `canSend` / `canQueue` gated on `pendingInteraction == nil`, the exhaustive non-transcript
  event list (~`:3504`).
- `HermesMobile/Sources/Features/Chat/ApprovalCardView.swift` (`BoundedHeightLayout`),
  `ClarifyCardView.swift` (clarify card — single-select list or free-text field, rigid — and the
  secret card), wired in `ChatView.pendingCard`.
- Tests: `GatewayEventDecodingTests`, `SessionDecodingTests`, `JSONRPCTests`,
  `HermesGatewayClientTests`, `ServerRequestTests` (base), `ChatInteractionTests`,
  `ClarifyFeatureTests`, `HydrateTests`,
  `AppFeatureTests` (push-tap recovery); `ChatSnapshotTests` and `ApprovalCardLayoutTests` in
  `HermesMobileTests`.

## Development Approach

- **testing approach**: Regular (code first, then tests) — user preference for this plan.
- complete each task fully before moving to the next
- make small, focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
  - tests are not optional - they are a required part of the checklist
  - write unit tests for new functions/methods
  - write unit tests for modified functions/methods
  - add new test cases for new code paths
  - update existing test cases if behavior changes
  - tests cover both success and error scenarios
- **CRITICAL: all tests must pass before starting next task** - no exceptions; "all" means the
  full `swift test --package-path HermesKit` run, never a filtered selection
- **CRITICAL: update this plan file when scope changes during implementation**
- run tests after each change
- maintain backward compatibility: a legacy agent (`desktop_contract < 7`, ≤ v2026.9.11) must
  behave as today on the wire — the legacy event/respond paths stay, including the generic
  recovered approval card
- commit per task, capitalized verb, no conventional-commit prefix

## Testing Strategy

- **unit tests** (HermesKit, `swift test`): decoding tests for every v7 params shape (approval,
  both clarify generations, sudo with and without `command`, secret, `open_requests`,
  `request.cancel`, `desktop_contract` as int and as string); `TestStore` reduction tests for
  every reducer path (queueing, presenting the head, in-place refresh, answering per kind and per
  clarify generation, `expired`, cancel, turn-end clearing, replay with absence-is-authoritative
  on `running` true and false, legacy paths unchanged). Event-reduction tests are the
  highest-value suite here.
- **wire tests** (`HermesGatewayClientTests`): declines encoded through `wireEncoder` (assert
  no `\/` in a payload containing `/`); the advertisement precedes the first session RPC; a hung
  advertisement still reaches ready; the decline matrix (window-owned × `declines_not_shown`,
  unrendered prompt, malformed rendered kind).
- **snapshot tests** (`HermesMobileTests`, `make snapshot` twice per new test): new clarify forms
  (multi-select, batch, recommended badge, locked answers, Other row), approval card without the
  session toggle. Judge by render size first (baselines predate the current runtime; small
  pixel residual is drift).
- **hosted layout test** for the clarify card's bounded region: a 5-question batch at the
  shortest keyboard-up window keeps the Confirm/Skip row inside the window and the region
  scrollable (same pattern as `ApprovalCardLayoutTests`, assert on accessibility frames).
- no e2e suite in this project.
- run HermesKit tests with `script -q /dev/null swift test --package-path HermesKit` (or
  `make test`) — piped output buffers.

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- update plan if implementation deviates from original scope
- keep plan in sync with actual work done

## Solution Overview

1. **One queue of open server requests per slot.** `serverRequests` is an ordered list (oldest
   first, the `open_requests` order) of `PendingServerRequest { id, kind }`, and the head is the
   presented card, raised through `present(_:)` so the token contract holds. A new arrival
   appends. A replayed arrival with a known id updates in place through one sanctioned helper,
   `State.refreshPresented(_:)` (same srq id only, no token bump) — the single documented
   exception to "never assign `pendingInteraction`". Answering, `expired`, or a matching
   `request.cancel` removes the entry and presents the next one.
2. **Answers go through `request.answer`, in the request's own shape.** `request.answer {id,
   result}` is an ordinary RPC (`gateway.send`): `wireEncoder`, the 30 s timeout and a surfaced
   error come for free, and `status: "expired"` tells the phone another surface answered first.
   Result shapes: approval `{choice}`; clarify `{answers}` (v0.21.6+) or `{answer}` / `{answers}`
   (v2026.9.14–.24 single / batch); cancel-all `{}`; sudo/secret `{value}`, skip `{value:""}`.
   `ok` → remove; `expired` → remove + "Already handled elsewhere" status row; RPC failure →
   `errorBanner`, card stays. Never an error response for a rendered kind.
3. **The phone never steals or poisons a prompt it does not render.** Window-owned bridges: 4404
   when the backend advertised `declines_not_shown`, otherwise nothing. Unrendered prompts
   (`vault.*`, `setup_choose`, `display.install.sudo`): nothing — a desktop sharing the session
   answers; a phone-only agent waits out that prompt's deadline (120–300 s). A rendered kind whose
   params fail to decode: that kind's own skip (`{choice:"deny"}`, `{}`, `{value:""}`), so the
   agent is never left hanging.
4. **Cards end when the request ends.** `request.cancel` removes the matching entry (a `timeout`
   on the presented card appends a "Timed out" status row). Turn end (`message.complete`,
   `.error`) clears the queue — the generalization of `clearStaleApproval`. A hydrate never
   clears on `running == false` alone on v7; it reconciles with `open_requests`.
5. **Reconnect restores the exact prompts.** `ActivateResponse` decodes `openRequests`. On v7,
   `applyActivate` always reconciles `serverRequests` with it, whatever `running` says: listed
   ids are kept (params refreshed), unlisted ones dropped, new ones appended. Batch-clarify
   `params.answers` show as locked.
6. **Push-tap recovery reads the real card.** On v7 an armed `expectsPendingApproval` hint is
   satisfied by the replay; if the replay holds no approval, the hint is dropped silently. The
   generic `recoveredApprovalRequest` card survives only on legacy servers, exactly as today.
7. **Clarify grows the desktop's forms.** One `ClarifyRequest` model with a `questions` list
   covers every shape; layout comes from the question count, the wire shape from `answerShape`.
   Single question: tap-to-submit rows (single-select), checkmark rows + Submit (multi-select),
   or a text field; every question with choices also gets an "Other" text row. Several
   questions: sections over one `BoundedHeightLayout` region with a pinned Confirm/Skip row.
   Recommended shows a badge, never a preselection; Skip on every form. On legacy servers the
   single-select and free-text forms work as today; the new forms are v7-only.
8. **Sudo and secret move to the new channel.** `SecretPrompt` stops requiring `request_id`
   (the srq id identifies a v7 prompt) and gains the sudo `command` and secret `env_var`. The
   legacy `sudo.respond` / `secret.respond` path stays for legacy servers, with its `try?`
   replaced by a surfaced failure.

Key decisions:
- **`request.answer` instead of the raw response frame** (deliberate deviation from desktop,
  which uses response frames and falls back to `approval.respond`). It is the same server code
  path plus an acknowledgement, and it keeps the app's existing "Already handled elsewhere"
  contract for every kind, not just approvals. Raw frames remain only for declines.
- **One answer for a batch clarify, no `clarify.lock`.** Locks only matter for saving answers
  incrementally; the phone submits the form at once. Replayed locks are shown and re-sent with
  the final set (the server merges them anyway).
- **Silence for unrendered prompts.** The cost — a phone-only agent waits up to 300 s on a vault
  or setup prompt — beats killing a desktop user's card or feeding a refusal string to the
  password manager.
- **Legacy stays as it is today.** No new legacy features (no `pending_clarify` hydration, no
  `clarify.expire`, no `approval.pending` probe): those only serve agents from before 2026-09-14.
- **`approval.received` is dropped** — a server-side no-op on current agents.
- **`always` is never offered**: the phone narrows the server's choice set and never widens it.
- **No composer send during a pending clarify.** The composer stays locked behind every card as
  today; Skip is the way out. (Desktop cancels the clarify and sends; doing that here would mean
  submitting against a running turn, which #66 forbids.)
- **No queue counter on the card** — the queue is presented one card at a time without a
  "1 of N" hint.

## Technical Details

### Models

```swift
/// Moved out of `ChatFeature.State.PendingInteraction` so models don't depend on the feature.
public enum SecretKind: Equatable, Sendable { case sudo, secret }

/// One open v7 prompt. `id` is the `srq-…` request id — the only place it is stored.
public struct PendingServerRequest: Equatable, Sendable, Identifiable {
  public var id: String
  public var kind: Kind
  public enum Kind: Equatable, Sendable {
    case approval(ApprovalRequest)
    case clarify(ClarifyRequest)
    case secret(SecretKind, SecretPrompt)
  }
}

public struct ClarifyQuestion: Equatable, Sendable {
  public var qid: String?            // nil only for the intermediate/legacy single form
  public var question: String
  public var choices: [String]       // raw, may carry the "(Recommended)" suffix
  public var multiSelect: Bool
  public var isFreeText: Bool { choices.isEmpty }
}

public struct ClarifyRequest: Equatable, Sendable, Decodable {
  public var requestID: String?                // legacy event id; nil on v7
  public var questions: [ClarifyQuestion]      // >= 1 after decoding
  public var lockedAnswers: [String: String?]  // replayed `answers`, keyed by qid; nil = skipped
  public var answerShape: AnswerShape
  public enum AnswerShape: Equatable, Sendable { case answers, singleAnswer, legacyRespond }
  public var isMultiQuestion: Bool { questions.count > 1 }   // layout only
  // convenience for the single form (keeps existing call sites/tests)
  public init(requestID: String?, question: String, choices: [String] = [], multiSelect: Bool = false)
}

public enum ClarifyChoice {
  /// ("Use SwiftUI", isRecommended: true) for "Use SwiftUI (Recommended)"; case-insensitive
  /// suffix match, mirrors upstream `strip_recommended`.
  public static func split(_ raw: String) -> (label: String, isRecommended: Bool)
}

public struct SecretPrompt: Equatable, Sendable, Decodable {
  public var requestID: String?      // legacy event id; nil on v7
  public var prompt: String?
  public var command: String?        // sudo, v2026.9.21+ (redacted server-side)
  public var envVar: String?         // secret ("env_var")
}

public struct RequestCancel: Equatable, Sendable, Decodable {
  public var id: String              // srq id
  public var method: String?
  public var reason: String?         // free text: timeout | interrupted | resolved | …
}

public struct OpenRequest: Equatable, Sendable, Decodable {
  public var id: String
  public var method: String
  public var params: JSONValue
}
```

The base's `ApprovalRequest.serverRequestID` (set in `GatewayConnection.presentApproval`) is
removed once the queue exists (the id lives on `PendingServerRequest` only). `requestID`,
`choices`, `allowsOnce` and `allowsSessionChoice` stay as merged.

Decoding rules: `ApprovalRequest` stays fully lenient. `ClarifyRequest` picks its shape from the
payload: `questions` (each entry needs `qid` + `question`) → `.answers`; a top-level `question`
from a server request → `.singleAnswer`; the legacy event (with `request_id`) → `.legacyRespond`.
No usable question → decode failure. `multi_select` defaults `false`; `choices: null` → `[]`.
Unknown keys are ignored.

`ActivateResponse` adds `openRequests: [OpenRequest]` (`"open_requests"`, default `[]`).
`SessionInfo` adds `desktopContract: Int?` (`"desktop_contract"`), decoded by hand: an Int, or a
String that parses as an Int, else nil — it must never throw, because a throw drops the whole
`info`. `GatewayEvent` gains `.serverRequest(PendingServerRequest)` (replacing the base's
`.approvalServerRequest`) and `.requestCancel(RequestCancel)` (`"request.cancel"`), each with a
`GatewayLogEntry` name and a summary that never includes a secret value. The base's
`.serverRequestFailed(message:)` stays as the local, non-turn-ending failure event for
advertisement, decline and automatic-skip sends.

### Client (`HermesGatewayClient`)

- Inbound `.serverRequest`: `approval` / `clarify` / `sudo` / `secret` decode into
  `GatewayEvent.serverRequest`, yielded synchronously from `handle(frame:)` as the base does for
  approval (a following turn terminal must not overtake the card). A rendered method whose
  params fail to decode gets that kind's skip through `request.answer` from a `Task` (the
  base's malformed-approval path; a failure → `.serverRequestFailed`). Window-owned methods get
  a 4404 error frame when `declinesNotShown`, else nothing. Every other method gets nothing.
- Advertisement: when the `gateway.ready` frame arrives, the actor starts a `Task` that sends
  `client.capabilities {server_requests: true}` and awaits the result with a 5 s cap, stores
  `declinesNotShown`, and only then yields `.ready` (awaiting inside the receive loop would
  deadlock — the response arrives through that loop). `-32601` means "no advertisement on this
  backend"; a timeout or other failure is logged through the gateway log; every outcome still
  yields `.ready`. Events arriving during the window are yielded as usual. The base already
  starts the `Task` on `gateway.ready` but yields `.ready` immediately and retries failures in
  the background (see "Base"); Task 2 reconciles the two.
  **As built (Task 2):** one attempt per connection, no background retry (the next connect
  re-advertises). The `.ready` gate (`readyGateOpen`, `advertisementReadyCap` = 5 s) opens on
  the attempt settling or the cap, whichever is first; a capped attempt keeps running under the
  30 s request budget and its late outcome still counts. A failure other than `-32601` yields
  `GatewayEvent.serverRequestsUnavailable(message:)` ("Couldn’t enable approvals and other
  prompts: …") strictly AFTER `.ready`; the reducer stores it in
  `State.serverRequestsUnavailable`, which `.ready` resets and `applyActivate`'s stale-banner
  clear restores (`errorBanner = serverRequestsUnavailable`), so the banner outlives the
  hydrate that follows. Like every stream event it is mirrored into the gateway log.
- Every outbound frame — declines and skip responses included — is encoded by
  `JSONRPCRequest.wireEncoder`. Answers go through `send("request.answer", …)`.

### Reducer (`ChatFeature`)

State additions (per slot, unpersisted, reset in `init`):
- `serverRequests: IdentifiedArrayOf<PendingServerRequest>`
- `desktopContract: Int?` (from `applyActivate` / `session.info`)

Helpers:
- `present(_:)` — unchanged; raises the head.
- `refreshPresented(_:)` — replaces the presented interaction's payload for the same srq id
  without touching `pendingInteractionToken`. Doc comment names it as the one exception to the
  `present(_:)` rule; CLAUDE.md's approval bullet mentions it.

Actions:
- `.gatewayEvent(.serverRequest(r))` — append, or `refreshPresented` / update in place when the
  id is known; present when it became the head.
- `.gatewayEvent(.requestCancel(c))` — remove the matching entry; if it was presented, present
  the next or clear; `reason == "timeout"` on the presented card appends a "Timed out" row.
- `respondToApproval(approve:all:)` — builds `{choice}` (the base's narrowing kept); legacy
  `approval.respond` path as merged. The v7 outcome moves from the base's
  `approvalRespondResult(resolved: 0)` overload to `serverRequestAnswered`.
- `submitClarify(answers: [String: String?])` — keyed by qid (a single legacy/intermediate
  question uses the key `""`); the reducer builds the wire shape from `answerShape`.
- `skipClarify` — v7 `.answers`: `{}`; `.singleAnswer`: `{answer:""}`; legacy: today's empty
  `clarify.respond`.
- `respondToSecret(value:)` — v7 `{value}`; legacy `sudo.respond` / `secret.respond`.
- `serverRequestAnswered(id:, Result<AnswerStatus, GatewayError>)` — `.ok` → remove + next;
  `.expired` → remove + "Already handled elsewhere" row + next; failure → `errorBanner`, card
  stays. Legacy clarify/secret failures surface the same way instead of `try?`.
  **As built (Task 3):** `serverRequestAnswered(id:echo:_:)` — `AnswerEcho {kind, text,
  failureBanner}` carries the `ok` row and the failure banner, so each kind sets its own copy;
  no optimistic row on v7. `answeringServerRequestID` ignores a second answer while one is in
  flight. `State.presentedServerRequest` (= the queue head while a card stands) is how answers
  find their srq id; `presentNextServerRequest()` raises the next head or dismisses.

Answer building per kind (all v7 answers are `request.answer {id, result: …}`):
```
approval               → {choice: "once"|"session"|"deny"}
clarify .answers       → {answers: {q0: "A", q1: "[\"B\",\"C\"]", q2: "typed other", q3: null}}
                          cancel → {}
clarify .singleAnswer  → {answer: "A"}                  skip → {answer: ""}
clarify .legacyRespond → clarify.respond {session_id, request_id, answer}   (today's wire)
sudo / secret v7       → {value: "…"}                   skip → {value: ""}
sudo / secret legacy   → sudo.respond / secret.respond   (today's wire)
```
Choices send the bare text (`ClarifyChoice.split(...).label`); an Other answer is the typed string
(also for a multi-select question); replayed locks are included in the final set.

`applyActivate` ordering (replacing today's hint block):
1. `running := response.running ?? false`; record `desktopContract` from `info`.
2. If v7: reconcile `serverRequests` with `openRequests` — keep listed ids (refresh params),
   drop unlisted ones, append new ones in order; present the head unless the same id is already
   presented. An armed hint is consumed (the replay is the answer). This step runs whether or
   not `running` is true.
3. If legacy and `!running`: today's `clearStaleApproval` + clear the hint.
4. If legacy and `running`: today's behaviour, including the generic recovered card for an
   armed hint.

Everything else in `applyActivate` (the #26 live-row preservation, wholesale rebuild, inflight
seeding) is untouched. The `session.events.since` path (#98) feeds its `open_requests` through
the same reconcile when it lands.

### Views (`HermesMobile`)

- `ApprovalCardView`: toggle on `offersSessionApproval` (the base folded `allowsOnce &&
  allowsSessionChoice` into it), Approve hidden when `!allowsOnce` (from the base).
- `ClarifyCardView` rebuilt around one `BoundedHeightLayout` region (moved to its own
  `BoundedHeightLayout.swift`; pure move) with a pinned action row. Single question:
  single-select rows (tap submits), multi-select checkmark rows + Submit, free-text field +
  Send. Several questions: one section per question, Confirm enabled when every question has an
  answer or a skip. Every question with choices has an "Other" text row. Skip on every form,
  recommended badge, no preselection. `.layoutPriority(1)` scope extends to multi-question
  clarify (`State.isCompressibleCardPending`).
- Locked answers are read from the store (`lockedAnswers` of the presented request), shown ✓;
  view `@State` holds only the user's edits to unlocked questions, keyed on
  `pendingInteractionToken` through the existing `.id`, so a refreshed replay shows new locks
  and a replacement card never inherits selections.
- Secret card (in `ClarifyCardView.swift`): shows the sudo `command` / secret `env_var` when
  present.

### Wire examples (test fixtures)

```json
// server request: approval (v7)
{"jsonrpc":"2.0","id":"srq-1a2b3c4d5e6f","method":"approval","params":{"session_id":"live","request_id":"ab12","command":"rm -rf build","description":"…","pattern_key":"rm_rf","choices":["once","session","always","deny"]}}
// answer
{"jsonrpc":"2.0","id":7,"method":"request.answer","params":{"id":"srq-1a2b3c4d5e6f","result":{"choice":"once"}}}
// → {"jsonrpc":"2.0","id":7,"result":{"status":"ok"}}   or {"status":"expired"}
// server request: clarify v0.21.6+, two questions with a replayed lock
{"jsonrpc":"2.0","id":"srq-0f0e0d0c0b0a","method":"clarify","params":{"session_id":"live","questions":[{"qid":"q0","question":"Framework?","choices":["SwiftUI (Recommended)","UIKit"],"multi_select":false},{"qid":"q1","question":"Targets?","choices":["iOS","macOS"],"multi_select":true}],"answers":{"q0":"SwiftUI"}}}
// answer result
{"answers":{"q0":"SwiftUI","q1":"[\"iOS\",\"macOS\"]"}}
// server request: clarify v2026.9.14–.24 single
{"jsonrpc":"2.0","id":"srq-aaaaaaaaaaaa","method":"clarify","params":{"session_id":"live","question":"Proceed?","choices":["Yes","No"]}}
// server request: sudo (v2026.9.21+)
{"jsonrpc":"2.0","id":"srq-bbbbbbbbbbbb","method":"sudo","params":{"session_id":"live","command":"apt install …"}}
// decline, window-owned method, backend with declines_not_shown
{"jsonrpc":"2.0","id":"srq-cccccccccccc","error":{"code":4404,"message":"Not shown on this client"}}
// request.cancel
{"jsonrpc":"2.0","method":"event","params":{"type":"request.cancel","session_id":"live","seq":123,"payload":{"id":"srq-1a2b3c4d5e6f","method":"approval","reason":"timeout"}}}
// session.resume extras (live reattach)
{"running":false,"open_requests":[{"id":"srq-1a2b3c4d5e6f","method":"approval","params":{…}}],"info":{"desktop_contract":"8",…}}
```

## Implementation Steps

### Task 1: Reconcile with the merged base

**Files:**
- Read: the merged PR #116 squash commit `e8fb410`
- Modify: this plan (names, anything the base delivered differently)

- [x] confirm the base delivered the items listed under "Base" — in particular `wireEncoder`
      for every frame, no `try?`, the three-way decline rule (no 4404 outside the window-owned
      set, nothing on backends without `declines_not_shown`), `request.answer` with `expired`
      handling, deny on a malformed approval, reducer tests (all present; see "Base")
- [x] list every gap as a ➕ item in the matching task below; rename types in this plan to the
      merged names
- [x] if #116 was not revised by 2026-10-26: take over `702f983` on a branch and close those gaps
      here, with tests (n/a — #116 revised and merged as `e8fb410`)
- [x] run the full suite on `main` — must be green before Task 2 (run on this branch = `main`
      + plan edits: 1509 tests in 68 suites passed, 1 known issue)

### Task 2: Wire-generation signal and advertisement ordering

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Models/GatewayEvent.swift` (`SessionInfo.desktopContract`)
- Modify: `HermesKit/Sources/HermesKit/Models/Session.swift` (`ActivateResponse.openRequests`)
- Modify: `HermesKit/Sources/HermesKit/Clients/HermesGatewayClient.swift`
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/HermesGatewayClientTests.swift`, `SessionDecodingTests.swift`, `GatewayEventDecodingTests.swift`, `ServerRequestTests.swift`

- [x] decode `desktop_contract` leniently (Int, numeric String, else nil — never throws) and
      `open_requests` (default `[]`) (`SessionInfo` got a hand-written decoder that keeps the
      other fields' synthesized semantics; `open_requests` decodes per entry — a malformed entry
      is dropped, a non-array is `[]`; `OpenRequest` lives next to `ActivateResponse` in
      `Session.swift`, so Task 3 no longer adds it)
- [x] advertisement in a `Task` started on the `gateway.ready` frame, 5 s cap, store
      `declinesNotShown`, then yield `.ready`; `-32601`, timeout and other failures still reach
      ready, the latter two logged (the base already starts the `Task` and stores
      `declinesNotShown`; what changes is holding `.ready` until it settles or the cap fires)
      (a capped attempt keeps running; its late failure — the 30 s request timeout included —
      surfaces through `.serverRequestsUnavailable`, which the gateway log mirrors; the cap
      itself logs nothing)
- [x] record `desktopContract` per slot from `applyActivate` and `session.info` (a hydrate's
      `info` is a full snapshot and overwrites; a partial `session.info` writes only when present)
- [x] write tests: `desktop_contract` as `7`, `"8"`, `"x"`, absent — and a string value leaves the
      model/usage fields of `info` intact; `open_requests` present/absent/malformed; the
      advertisement precedes `session.resume` on the wire; a hung advertisement still reaches
      ready after the cap; events in the window are not lost; `declinesNotShown` stored
- [x] ➕ rewrite #116's `unknownAdvertisementMethodIsSilentAndNotRetried` (`ServerRequestTests`):
      it calls `advertiseServerRequestsIfNeeded()` directly, so the retry loop (started only on
      `ready`) never runs, the clock advance is a no-op, and `events` is never read — it passes
      on the pre-fix `e6736df`. Drive it through an injected `ready` frame and assert one
      `client.capabilities` frame and no `.serverRequestFailed`
- [x] ➕ if #116's retry loop survives this task: test that a non-`-32601` failure (`busy`)
      keeps retrying but surfaces once per connection (`advertisementFailureReported` is
      uncovered) (n/a — the retry loop is gone; `advertisementFailureSurfacesAfterReadyAndIsNotRetried`
      covers the single attempt instead)
- [x] ➕ drop the redundant `advertisementUnsupported` flag in `GatewayConnection` — the same
      branch sets `advertisedServerRequests = true`, which already stops the retry (gone, along
      with `advertisedServerRequests` / `advertisingServerRequests` /
      `advertisementFailureReported`; one `advertisementStarted` flag remains)
- [x] ➕ decide whether #116's background retry (`startAdvertisement` → `retryAdvertisement`,
      2 s → 30 s for the connection's life) survives behind the awaited first attempt. The
      Technical Details design has none (the next connect is the retry); if it stays, describe it
      there and keep the item above about `advertisementFailureReported` (dropped: one attempt per
      connection, matching Technical Details and the no-automatic-retries preference)
- [x] ➕ make the advertisement failure visible: the base's `.serverRequestFailed` banner lands
      just after `.ready` and is wiped by `applyActivate`'s `errorBanner = nil` when the hydrate
      answers later; once `.ready` waits on the advertisement, the `.ready` handler's own clear
      wipes it too. Pick banner (CLAUDE.md "surface RPC failures") or gateway log (Technical
      Details), make it survive the ready/hydrate clears, and test that (banner, and the gateway
      log via the stream mirror: new `GatewayEvent.serverRequestsUnavailable` yielded after
      `.ready`, kept in `State.serverRequestsUnavailable`, restored by the hydrate clear, reset by
      the next `.ready`)
- [x] ➕ reword the failure copy "Couldn’t enable approval requests" to cover every prompt kind
      (clarify/sudo/secret ride the same advertisement after Tasks 5–6) ("Couldn’t enable
      approvals and other prompts: …")
- ⚠️ (resolved in Task 2) until this task lands, `.ready` (and so `session.resume`) does not
      wait for the advertisement: a prompt raised before the server processed it is refused
      while the phone is the only client
- [x] run tests - must pass before next task (1519 tests in 68 suites passed, 1 known issue)

### Task 3: One queue for every rendered server request

**Files:**
- Create: `HermesKit/Sources/HermesKit/Models/PendingServerRequest.swift` (incl. `SecretKind`)
- Modify: `HermesKit/Sources/HermesKit/Models/GatewayEvent.swift` (`.serverRequest`, `.requestCancel`)
- Modify: `HermesKit/Sources/HermesKit/Models/GatewayLogEntry.swift`
- Modify: `HermesKit/Sources/HermesKit/Clients/HermesGatewayClient.swift`
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift` (queue, `refreshPresented`,
  the exhaustive event list)
- Modify: `HermesKit/Tests/HermesKitTests/ChatInteractionTests.swift`, `HermesGatewayClientTests.swift`, `ServerRequestTests.swift`

- [x] add `PendingServerRequest`, `SecretKind` (moved), `RequestCancel` (`OpenRequest` already
      landed in Task 2, in `Session.swift`); replace
      `GatewayEvent.approvalServerRequest` (the case, its `GatewayLogEntry` name/summary, the
      reducer case, the non-transcript list entry) with `.serverRequest`; drop
      `ApprovalRequest.serverRequestID` (set in `GatewayConnection.presentApproval`)
      (`PendingServerRequest.init?(id:method:params:)` is the one rendered-method decoder and
      `malformedSkip(for:)` the per-kind skip — Tasks 5/6 extend both; `windowOwnedMethods` lives
      there too; `ClarifyCardView.Mode` now names the top-level `SecretKind`)
- [x] `serverRequests` queue with `present(_:)` for a new head and `refreshPresented(_:)` for a
      known id; approval answers through `request.answer` → `serverRequestAnswered`
      (invariant: while the queue is non-empty its head IS the presented card —
      `State.presentedServerRequest`; `presentNextServerRequest()` raises the next head;
      `answeringServerRequestID` guards a second tap while an answer is in flight; the outcome
      action carries an `AnswerEcho` — row kind/text on `ok`, banner on failure)
- [x] `request.cancel`: remove the entry, present the next, "Timed out" row for a presented
      `timeout`
- [x] turn end (`message.complete`, `.error`) clears the queue — generalize `clearStaleApproval`
      (now `clearStalePrompts`; still also called by `applyActivate` on `running == false`
      until Task 8 — see the ⚠️ there)
- [x] decline matrix in the client (window-owned × `declinesNotShown`; unrendered prompts silent;
      malformed rendered kind → its skip) (`handleServerRequest` is now private and synchronous
      on the receive loop; only the sends run in a `Task`)
- [x] write tests: two approvals queue and present in order; answering the head presents the next
      with a new token; `expired` removes with "Already handled elsewhere"; an RPC failure keeps
      the card with a banner; a replayed id refreshes without a token bump; cancel of the head /
      of a queued entry / of an unknown id; turn end clears; the decline matrix including
      `vault.code` getting nothing on every backend
- [x] ➕ keep the card on a failed answer: the base clears `pendingInteraction` and appends the
      "Approved"/"Denied" row BEFORE `request.answer`, so a throw or malformed status leaves a
      banner, no card, and a request still open server-side. Remove only on `ok`/`expired`; on
      failure keep the card and drop or patch the optimistic row. Rewrite the base's
      `serverApprovalAnswer` test (it asserts the card is gone on failure) (no optimistic row on
      v7: the row is appended on the acknowledgement; the legacy `approval.respond` path keeps
      its optimistic row)
- [x] ➕ test the base's `!approve || request.allowsOnce` guard in `respondToApproval`: Approve
      on a card whose `choices` lack `once` sends nothing and keeps the card (uncovered)
- [x] ➕ drive the decline-matrix tests through injected frames: the base's
      `declinesOnlyWindowBridges` / `automaticSendFailureDoesNotEndTurn` call
      `handleServerRequest` directly, so `handle(frame:)`'s routing of non-approval methods is
      untested (only approval frames are injected end to end)
- ⚠️ (resolved in Task 3) approval params that decode but carry no `command`/`description`
      (`{}`, `session_id` only) present a content-less card that looks like the push-tap
      recovered card instead of being denied as malformed — now malformed
      (`ApprovalRequest.hasContent`: command, description or a danger pattern) and denied
- ⚠️ a `choices` list with `session` but no `once` renders Deny only (Approve hidden, the toggle
      needs `allowsOnce`); upstream always offers `once` alongside `session`, so accepted
- ⚠️ the base ignores `params.session_id` (as the client already drops events' `session_id`);
      fine while one socket serves one session (multi-slot is #90)
- ⚠️ (resolved in Task 3) until this task lands, a second server approval overwrites the
      presented one and the first stays open server-side until its deadline
- ⚠️ clarify/sudo/secret server requests stay silent (unrendered, no skip) until Tasks 5–6
      add them to `PendingServerRequest`; the decline-matrix test lists them as silent
- [x] run tests - must pass before next task (1531 tests in 68 suites passed, 1 known issue;
      app target builds; `make snapshot` 40 failures, all at identical render size = known drift)

### Task 4: `ClarifyRequest` questions model and all three shapes

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Models/ApprovalRequest.swift` (move `ClarifyRequest` out)
- Create: `HermesKit/Sources/HermesKit/Models/ClarifyRequest.swift`
- Modify: `HermesKit/Tests/HermesKitTests/GatewayEventDecodingTests.swift`
- Create: `HermesKit/Tests/HermesKitTests/ClarifyChoiceTests.swift`

- [x] create `ClarifyRequest.swift` with `ClarifyQuestion`, `ClarifyRequest` (`questions`,
      `lockedAnswers`, `answerShape`, `isMultiQuestion`, the single-form convenience init) and the
      shape-detecting decoder (detection order: usable `questions` → `.answers`; `request_id` →
      `.legacyRespond`, decoded as before; top-level non-blank `question` → `.singleAnswer`. An
      unusable `questions` entry is dropped, the rest render; a non-string lock is ignored;
      `multiSelect` is forced `false` on a free-text question, as upstream normalizes. The
      `clarify.request` event only accepts the `.legacyRespond` shape. `question` / `choices`
      stay as first-question accessors so the single card and the log summary are untouched
      until Task 7)
- [x] add `ClarifyChoice.split(_:)` (case-insensitive `(recommended)` suffix, trimmed) (a choice
      that is only the marker keeps it as its label — never an empty row)
- [x] write decoding tests: v0.21.6 single-select and free-text single questions (one-entry
      `questions`, `isMultiQuestion == false`), three mixed questions, replayed `answers`
      including a `null`, intermediate single with and without `multi_select`, intermediate
      batch, legacy event (unchanged), no usable question → failure
- [x] write `ClarifyChoice.split` tests: suffix present / absent / mixed case / lone choice
- [x] run tests - must pass before next task (1554 tests in 69 suites passed, 1 known issue;
      app target builds; `make snapshot` 40 failures, all at identical render size = known drift)

### Task 5: Clarify over server requests

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Clients/HermesGatewayClient.swift`
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/ClarifyFeatureTests.swift`

- [ ] route `clarify` server requests into the queue; a malformed one gets `{}`
- [ ] `submitClarify(answers:)` / `skipClarify` build the result per `answerShape` (table in
      Technical Details); bare choice text; Other answers as typed; replayed locks included
- [ ] legacy `respondToClarify`: replace `try?` with surfaced failure (banner, echo row patched
      to "Failed to send")
- [ ] write tests: each shape's exact `request.answer` params; multi-select JSON-array string;
      an Other answer on a single-select and on a multi-select question; a skipped question sends
      `null`; cancel-all `{}`; intermediate skip `{answer:""}`; `expired`; a failed answer keeps
      the card and banners; legacy wire byte-identical to today's fixture; legacy failure
      surfaces
- [ ] run tests - must pass before next task

### Task 6: Sudo and secret over server requests

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Models/GatewayEvent.swift` (`SecretPrompt`)
- Modify: `HermesKit/Sources/HermesKit/Models/GatewayLogEntry.swift`
- Modify: `HermesKit/Sources/HermesKit/Clients/HermesGatewayClient.swift`
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift`
- Modify: `HermesMobile/Sources/Features/Chat/ClarifyCardView.swift` (secret card: command / env var line)
- Modify: `HermesKit/Tests/HermesKitTests/ChatInteractionTests.swift`, `GatewayEventDecodingTests.swift`

- [ ] `SecretPrompt.requestID` optional; add `command`, `envVar`
- [ ] route `sudo` / `secret` server requests into the queue; answer `{value}`, skip
      `{value:""}`; a malformed one gets `{value:""}`
- [ ] legacy `sudo.respond` / `secret.respond` unchanged on the wire; `try?` replaced by
      surfaced failure
- [ ] the value never reaches the transcript, the gateway log, or a push (privacy rule)
- [ ] write tests: v7 sudo with and without `command`, secret with `env_var`; answer and skip
      params; the gateway log entry omits the value; legacy wire unchanged; legacy failure
      surfaces
- [ ] run tests - must pass before next task

### Task 7: `ClarifyCardView` forms over a bounded region

**Files:**
- Create: `HermesMobile/Sources/Features/Chat/BoundedHeightLayout.swift` (moved from
  `ApprovalCardView.swift`, no behaviour change)
- Modify: `HermesMobile/Sources/Features/Chat/ApprovalCardView.swift`
- Modify: `HermesMobile/Sources/Features/Chat/ClarifyCardView.swift`
- Modify: `HermesMobile/Sources/Features/Chat/ChatView.swift`
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift` (`isCompressibleCardPending`)
- Modify: `HermesMobileTests/ChatSnapshotTests.swift`
- Create: `HermesMobileTests/ClarifyCardLayoutTests.swift`

- [ ] move `BoundedHeightLayout` to its own file; keep its doc comments and measured
      derivations; `tuist generate` so the new file is picked up
- [ ] rebuild `ClarifyCardView` per Technical Details (layout by question count, Other row,
      Skip everywhere, recommended badge, store-driven locks, Confirm gating, no preselection)
- [ ] `ChatView.pendingCard`: wire `submitClarify` / `skipClarify`; extend `.layoutPriority(1)`
      to `store.isCompressibleCardPending` with the rationale updated
- [ ] add snapshots: `testClarifyCard_multiSelect`, `testClarifyCard_multiQuestion`,
      `testClarifyCard_recommendedBadge`, `testClarifyCard_lockedAnswers`,
      `testClarifyCard_otherRow`, `testApprovalCard_noSessionChoice` (the base added no
      snapshot) (`make snapshot` twice each; pinned width + height since the region scrolls)
- [ ] ➕ add `testApprovalCard_denyOnly` (`choices: ["deny"]`): the base hides Approve when
      `!allowsOnce`, and no snapshot covers the one-button row
- [ ] add `ClarifyCardLayoutTests`: hosted `ChatView` at the shortest keyboard-up window with
      five questions — Confirm/Skip frames inside the window, region
      `contentSize.height > bounds.height`; a single-question card still hugs its content
- [ ] run HermesKit tests and `make snapshot` — no new failures; any failure with a different
      render size from its baseline is a regression (equal size with a small residual is the
      known drift)

### Task 8: Reconnect replay and push-tap recovery

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift` (`applyActivate`)
- Modify: `HermesKit/Tests/HermesKitTests/HydrateTests.swift`
- Modify: `HermesKit/Tests/HermesKitTests/AppFeatureTests.swift` (existing recovery tests)

- [ ] implement the `applyActivate` ordering in Technical Details: on v7 always reconcile with
      `openRequests` (absence is authoritative, same-id refresh, locks shown); legacy clears on
      `!running` as today
- [ ] v7 push-tap: an armed hint is consumed by the replay; no approval in the replay → no card;
      legacy keeps the generic recovered card exactly as today
- [ ] write tests: `open_requests` with an approval and a clarify presents the approval then the
      clarify; re-hydrate with the same ids keeps the token; an unlisted presented card is
      cleared; `running == false` with a non-empty `open_requests` keeps the card;
      `running == false` with none clears; v7 hint + approval in the replay → the real card, no
      generic card; v7 hint + empty replay → nothing; legacy hint → generic card (existing
      `AppFeatureTests` cases still pass)
- ⚠️ until this task lands, the base's `applyActivate` still runs `clearStaleApproval` on
      `running == false`, which also drops a live server-request approval card (#83319) and
      leaves the request open server-side
- [ ] run tests - must pass before next task

### Task 9: Verify acceptance criteria

- [ ] verify all requirements from Overview: every rendered kind works on v7 (approval, clarify
      in all three shapes, sudo, secret), queueing, `expired`, cancel, turn-end clearing,
      replay, push-tap, the decline matrix, choice narrowing
- [ ] verify legacy wire byte-identity: the pre-change `clarify.respond` / `sudo.respond` /
      `secret.respond` / `approval.respond` fixtures still pass for legacy payloads
- [ ] ➕ settle the base's `request_id` branch in `respondToApproval`: a legacy-event approval
      carrying `request_id` (no srq id) now sends `{session_id, request_id, choice, all:false}`
      instead of today's `{session_id, choice, all}`. Check upstream (`git show
      <tag>:tui_gateway/…`) for any `approval.request` event that carries `request_id` and
      whether its `approval.respond` accepts it; if none does, the branch is dead — drop it (and
      `requestBoundApproval*` tests) or document it in `docs/features/approvals.md`. (Task 1
      could not check: the worktree rules forbid touching the sibling clone)
- [ ] verify edge cases: a cancel for a queued (not presented) request; a replay that reorders;
      every question skipped; a `running == false` snapshot with an open request; a window-owned
      request on a backend without `declines_not_shown`
- [ ] run full test suite: `script -q /dev/null swift test --package-path HermesKit`
- [ ] run `make snapshot`; judge failures by render size (baseline drift is known)
- [ ] manual pass against a live v0.21.7+ agent: approve after a socket drop; two parallel
      approvals; a clarify with several questions incl. multi-select and Other; skip; sudo; kill
      the socket mid-clarify and re-open — the card returns with locks; desktop and phone on one
      session — a clarify answered on desktop shows "Already handled elsewhere" when answered on
      the phone, and the phone never takes a desktop preview/terminal read or vault prompt
- [ ] manual pass against a v2026.9.24 agent (intermediate clarify shape, no 4404) and a
      v2026.9.11 agent (legacy) if one is available

### Task 10: [Final] Update documentation

- [ ] `docs/features/approvals.md`: rewrite around server requests (queue, `request.answer` and
      `expired`, cancel, turn-end clearing, replay, the decline matrix, answer shapes) and
      push-tap recovery on v7 vs legacy; replace the "ClarifyCardView is rigid" sentence
- [ ] ➕ rewrite, don't append to, #116's doc text: `docs/features/approvals.md` (~:24-47, the
      "unsupported prompt kinds are left alone" point is stated twice; "phone-only agent waits"
      becomes false for clarify/sudo/secret) and `docs/architecture.md` (~:92-100, "advertises
      when the gateway receives `ready`" — update for the Task 2 ordering)
- [ ] `docs/features/push-notifications.md`: point the tap-recovery paragraph at the replay
- [ ] `docs/architecture.md`: the server→client request flow, `client.capabilities` ordering,
      `open_requests` in "Session re-hydration", `desktop_contract` as the wire signal
- [ ] `CLAUDE.md` approval/clarify bullet: server requests, one queue, `refreshPresented` as the
      one exception to `present(_:)`, the decline matrix, narrow-never-widen, legacy kept
- [ ] `README.md` feature list: multi-select, multi-question and Other in clarify; compatibility
      note (both the v7 and the legacy wire are supported)
- [ ] comment on #97 with what shipped, the v7 floor, and what legacy agents still get
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion

**Manual verification**
- Real-device check of the multi-question clarify card at AX3 with the keyboard up (the layout
  test pins `.large`); selection-vs-scroll precedence inside the region is a manual item, as
  for the approval card.
- Reconnect mid-clarify with two answers locked on the desktop, then open the phone: the two
  show ✓, the rest are editable, Confirm sends all.

**External**
- `session.info` with `running` true→false as an extra clearing trigger (desktop #86577, for a
  lost `message.complete`), minding desktop's #83319 rule that a live request keeps its card.
- The resume `status: "waiting"` could drive a "needs input" indicator in the session list —
  separate issue.
- #98 (event replay) feeds `session.events.since`'s `open_requests` through the Task 8
  reconcile.
- Push plugin behaviour under v7 is unverified; check the plugin repo when touching push.
