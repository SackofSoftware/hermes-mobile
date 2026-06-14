# Hermes Mobile — iOS Companion MVP

## Overview

A native SwiftUI/TCA iOS companion app ("Hermes Mobile") that connects to a
running [Hermes Agent](https://github.com/) instance over Tailscale and lets the
user work with chat sessions from iPhone: list/resume/create sessions, stream
assistant responses, see tool/status activity, and — the mobile-native payoff —
approve/deny tool actions and answer clarification prompts while the agent keeps
working on the Mac/server.

The app is a **thin remote-control surface**. The runtime, tools, secrets, files,
cron, and integrations all stay on the trusted Hermes machine. The MVP question
this answers: *"Can I use Hermes comfortably from my phone without Telegram,
while keeping the real runtime on my Mac?"*

This plan is the output of a completed brainstorm. The wire protocol below was
**verified against the real Hermes source** (not assumed) — endpoints, JSON-RPC
methods, event names, and the auth model are all confirmed against
`hermes_cli/web_server.py`, `tui_gateway/server.py`, `apps/desktop/src/hermes.ts`,
`apps/shared/src/json-rpc-gateway.ts`, and `web/src/lib/gatewayClient.ts`.

## Context (from discovery)

This is a fresh repo (`hermes-mobile`) — only `.git` and `.claude` exist. No
Swift code yet. Reference desktop/gateway source lives in a sibling clone at
`/Users/eugene/Documents/Development/Personal/hermes-agent`.

### Verified connection model (LOCKED = "Model A")

- iOS app talks to Hermes over **Tailscale**. Hermes is launched with
  `--host 0.0.0.0 --insecure` and env `HERMES_DASHBOARD_SESSION_TOKEN=<stable secret>`.
- The `HERMES_DASHBOARD_SESSION_TOKEN` env var already exists
  (`hermes_cli/web_server.py:139`) — **no backend code change required**. Setting it
  yields a stable token that survives server restarts.
- Trust boundary = the tailnet. The `--insecure` flag disables the OAuth gate; the
  simple token path then works from any host (verified via the `should_require_auth`
  truth table and WS gating, `web_server.py:221-234`, `:7603-7717`).
- **Default loopback bind rejects non-loopback Host headers with HTTP 400** — that's
  why a phone cannot reach a default Hermes over Tailscale, and why `--insecure` +
  `0.0.0.0` bind is required.
- Real device pairing / QR / token revocation **does NOT exist in Hermes today** and
  is **deferred out of the MVP entirely** (old plan's "Phase 3" is dropped).
- "Model B" (OAuth-gated `dashboard_auth` flow for a non-loopback *secure* bind) is a
  **future-only** path — a real OAuth client with cookies/refresh tokens. Not MVP.

### Verified auth

- REST: header `X-Hermes-Session-Token: <token>` (legacy `Authorization: Bearer <token>`
  also accepted, `web_server.py:184-201`).
- `GET /api/status` is **public/unauthenticated** — use for the reachability probe.
- WebSocket: `…/api/ws?token=<stable>` query param (legacy mode, valid when the OAuth
  gate is off — i.e. under `--insecure`).
- Token stored in iOS Keychain.

### Verified REST endpoints

- `GET /api/status` — health/reachability (public)
- `GET /api/sessions` — params `limit`, `offset`, `order=recent`, `archived`
- `GET /api/sessions/search?q=<query>` — full-text search
- `GET /api/sessions/{id}/messages` — session history
- `PATCH /api/sessions/{id}` — rename/archive · `DELETE /api/sessions/{id}` — delete

### Verified WebSocket protocol (`/api/ws`)

- Newline-delimited **JSON-RPC 2.0**.
- Request: `{"jsonrpc":"2.0","id":<n>,"method":<m>,"params":{…}}` →
  `{"jsonrpc":"2.0","id":<n>,"result":{…}}` (or `"error"`).
- Server events: `{"method":"event","params":{"type":<t>,"session_id":<id>,"payload":{…}}}`.
- **Methods (client→server):** `session.create`, `session.resume`, `session.list`,
  `session.interrupt`, `session.close`, `session.delete`, `session.title`,
  `session.history`, `prompt.submit`, `approval.respond` (params include `all?:bool`),
  `clarify.respond`, `sudo.respond`, `secret.respond`.
- **Events (server→client) handled in MVP:** `gateway.ready`, `session.info`,
  `message.start`, `message.delta` (carries `text` + pre-`rendered` HTML),
  `message.complete`, `thinking.delta`, `reasoning.delta`, `status.update`,
  `tool.start`, `tool.complete`, `approval.request`, `clarify.request`,
  `sudo.request`, `secret.request`, `error`.
- **Events decoded-and-ignored for now (forward-compat):** `tool.progress`,
  `tool.generating`, `background.complete`, `skin.changed`. Unknown event types must
  also be tolerated — **never crash on an unknown `type`**.

### M0 findings — corrections from the live probe (2026-06-10)

The M0 probe ran successfully against a real server over Tailscale
(`Probe/main.swift`, fixture at `Probe/fixtures/session-events.jsonl`). Model A is
confirmed. These details **differ from the assumptions above** and override them:

- **`session_id` is on the event frame, not the payload.** Events are
  `{method:"event", params:{type, session_id, payload}}` — read `session_id` from
  `params`. `message.start` carries **no `payload` key at all**.
- **No per-message id in streaming events.** `message.start` = `{}` payload (absent);
  `message.delta` = `{text}`; `message.complete` = `{text, usage, status}`. There is
  **nothing to key an assistant row by** → reduction tracks a single *in-flight
  assistant row* (open on `message.start`, append on `message.delta`, finalize on
  `message.complete`). This overrides the "keyed by id" fold rule below.
- **Two session IDs from `session.create`/`session.resume`.** Result shape:
  `{session_id, stored_session_id, message_count, messages[], info{model,cwd,profile_name,…}}`.
  - `session_id` (e.g. `8680ce37`) = short **live/runtime handle**; used in all WS
    calls and event routing.
  - `stored_session_id` (e.g. `20260610_120231_afcca6`) = **persisted id**; almost
    certainly what REST `/api/sessions` lists and `/api/sessions/{id}/messages` uses.
  - ⚠️ **Open question for M1:** does `session.resume` take the `session_id` or the
    `stored_session_id`? And the inline `messages[]` means **WS resume may hydrate
    history directly** — possibly making the separate REST history call optional.
- **`prompt.submit` result is `{status:"streaming"}`** (not `{ok:true}`).
- **`message.delta` carries only `text`** (no `rendered` HTML in this run) → native
  `AttributedString` markdown is required, not just preferred.
- **`status.update.kind` is an open string** — saw `"lifecycle"` (plus expected
  `process`/`warn`/`error`). Render generically off `text`.
- **`thinking.delta`** can be empty/decorative (`"(◔_◔) synthesizing..."`); also saw
  **`reasoning.available`** `{text}` (full transcript) near turn end. Both fold into
  the collapsible thinking row (or ignore for MVP); tolerate empty text.
- **`session.info`** event is large (model, usage/context/cost, version, tools, skills,
  running, yolo, …). Decode **leniently** — model only the few fields the UI needs.
- `message.complete.usage` carries token/context/cost — a possible later usage
  indicator; not MVP.

### Reference files (hermes-agent repo)

- `apps/desktop/src/hermes.ts` — REST client wrapper (endpoint shapes)
- `apps/shared/src/json-rpc-gateway.ts` — JSON-RPC client + `GatewayEventName` union
- `web/src/lib/gatewayClient.ts` — browser WS client (token/ticket auth modes)
- `tui_gateway/server.py` — `@method(...)` dispatch + event emission points
- `tui_gateway/ws.py` — WS transport
- `hermes_cli/web_server.py` — auth middleware (~`139-341`), WS gating (~`7603-7717`)
- `hermes_cli/dashboard_auth/` — Model B OAuth gate (future reference)

## Development Approach

- **Testing approach:** Regular (code first, then tests) — TCA reducers and clients
  are written, then exercised with `TestStore`/`TestClock` and mocked dependency
  clients. Event-reduction tests are the highest-value suite.
- Complete each task fully before moving to the next; small, focused changes.
- **Every task MUST include new/updated tests** for code changes in that task. Tests
  are a required deliverable, listed as separate checklist items.
- **All tests must pass before starting the next task.**
- **Update this plan file when scope changes during implementation.**
- Maintain a clean `HermesKit` package boundary so the app shell stays thin.

## Testing Strategy

- **Unit tests (TCA):** required for every task. Use `TestStore`, `TestClock`,
  `@Dependency` overrides, and mock clients. Priority order:
  1. **Event-reduction tests** — feed recorded `GatewayEvent` sequences, assert the
     transcript folds correctly (deltas append, tool rows fill, approval pins). Highest value.
  2. Reconnect/backoff with `TestClock`.
  3. Approval/clarify request→respond round-trips with a mock gateway.
  4. Session-list load/search via mock REST.
- **No UI/snapshot/e2e tests until the core loop works.** Snapshot tests
  (swift-snapshot-testing) may be added in M3+ if the UI stabilizes; not before.

## Progress Tracking

- Mark completed items with `[x]` immediately when done.
- Add newly discovered tasks with ➕ prefix; document blockers with ⚠️ prefix.
- Update the plan if implementation deviates from scope.

## Solution Overview

Full Point-Free stack from day one (locked decision):

- **TCA** (`swift-composable-architecture`) for state/effects/navigation/testability.
- **swift-dependencies** (`@DependencyClient`) for REST/WS/Keychain clients.
- **swift-navigation** / TCA navigation for onboarding → list → chat → settings.
- **Tuist** for project generation; **SPM** for dependencies.
- `URLSession` for REST, `URLSessionWebSocketTask` for the JSON-RPC WebSocket.

**Project layout:** one Tuist app target `HermesMobile` + one local SPM package
`HermesKit` (models, dependency clients, reducers) + a test target. Generated
`.xcodeproj` is gitignored; `Project.swift` is committed. Debug config ships a
Tailscale server preset for fast iteration.

**Feature tree:**

```
AppFeature                       // connection state + root navigation
├─ ConnectionFeature             // server URL + token, staged /api/status validation
├─ SessionListFeature            // list / search / create
└─ ChatFeature                   // owns WS lifecycle + streaming reduction
   ├─ ApprovalFeature            // approval.request → approval.respond
   └─ ClarifyFeature             // clarify.request → clarify.respond (+ sudo/secret)
SettingsFeature                  // token mgmt, manual reconnect, raw event debug log
```

**Dependency clients:**

```
HermesRESTClient     // URLSession; status / sessions / search / messages
HermesGatewayClient  // URLSessionWebSocketTask; connect(url:token:)->AsyncStream<GatewayEvent>
                     //   + send(method:params:) async throws; owns id counter + pending map
KeychainClient       // token persistence
```

(The old plan's separate `ServerStatusClient` / `HermesAuthClient` are collapsed
into REST + Keychain — status is one REST call, and "auth" in Model A is just
attaching the token header.)

### Key design decisions & rationale

- **REST hydrates, socket goes live.** Lists come over REST; everything during a turn
  comes over the WebSocket. "New chat" opens ChatFeature, connects the socket, and
  calls `session.create`. Resume: the M0 probe showed `session.create`/`session.resume`
  return an inline `messages[]` array, so **resume may hydrate history straight from the
  WS result** — preferred if it carries full history; fall back to
  `GET /api/sessions/{id}/messages` otherwise (resolve in M1, Task 8).
- **One inbound stream, discrete outbound effects.** The WS connection is a single
  long-running cancellable TCA effect that funnels every event through one
  `.gatewayEvent` action. Outbound JSON-RPC calls (`prompt.submit`,
  `approval.respond`, …) are separate one-shot effects awaiting `gateway.send`.
- **Reconnect/backoff lives in the reducer**, not the client. The client stays dumb
  (connect + yield events); the reducer drives reconnect, making backoff visible in
  state and testable with `TestClock`.
- **Native markdown.** Render assistant text from the `text` field via
  `AttributedString`; ignore the server-provided `rendered` HTML (no web view).
- **Explicit pending-interaction state.** `chat.pendingInteraction` (not just a
  transcript row) blocks the composer while the agent waits on an approval/clarify.
- **sudo/secret fold into clarify.** `sudo.request`/`secret.request` reuse the
  clarify text-input card with `isSecureEntry: true`; responses go via their own RPC
  methods. No separate features.

## Technical Details

### `GatewayEvent` model

One Swift enum decoded from `{type, payload}` frames, with an `unknown(type:, raw:)`
case for forward-compatibility:

Each event also carries a frame-level `sessionID` (from `params.session_id`). The
streaming message events carry **no message id** (confirmed by M0):

```
ready | sessionInfo(SessionInfo) | messageStart | messageDelta(text)
| messageComplete(text, usage) | thinkingDelta(text) | reasoningAvailable(text)
| statusUpdate(kind, text) | toolStart(toolID, name, args) | toolComplete(toolID, result, durationS)
| approvalRequest(ApprovalRequest) | clarifyRequest(ClarifyRequest)
| sudoRequest(SecretPrompt) | secretRequest(SecretPrompt) | error(message)
| unknown(type, raw)
```

### Chat transcript reduction

State holds `IdentifiedArrayOf<ChatRow>` where a row is `.message` / `.tool` /
`.thinking` / `.status`. Fold rules:

- `message.start` → open a single **in-flight assistant row** (track its index in
  state; there is no message id to key by).
- `message.delta` → append `text` to the in-flight row (the streaming effect).
- `message.complete` → finalize the in-flight row (store text, stop the cursor
  animation, clear the in-flight pointer; optionally stash `usage`).
- `tool.start` → append a collapsed tool row; `tool.complete` → fill result + duration.
- `thinking.delta` / `reasoning.delta` → append to a collapsible "thinking" row, hidden by default.
- `status.update` → transient line that clears on the next message.
- Composer submit → optimistic `.message` user row + `prompt.submit` effect (result is
  `{status:"streaming"}`; the response arrives via events). Interrupt button →
  `session.interrupt`.

### Approval / clarify flow

- `approval.request` `{request_id, command, …}` → set `pendingInteraction`, surface a
  pinned high-emphasis Approve/Deny card with an "approve all" toggle → tap →
  `approval.respond({session_id, request_id, choice, all})` → collapse to settled state
  on `{resolved}`.
- `clarify.request` `{request_id, question, choices[]}` → if `choices` non-empty render
  selectable options, else inline text input → `clarify.respond({session_id, request_id, answer})`.
- `sudo.request` / `secret.request` → clarify card with `isSecureEntry: true` →
  `sudo.respond` / `secret.respond`.
- ⚠️ Phase-2 protocol check: verify the server **re-emits pending requests on
  resume/reconnect** so an in-flight approval isn't lost if the socket drops.

## What Goes Where

- **Implementation Steps** (`[ ]`): all code, tests, and in-repo docs.
- **Post-Completion** (no checkboxes): the Hermes server launch-flag setup
  (`--insecure` + stable token), on-device manual verification against the real
  server, TestFlight, and fast-follow features requiring backend work.

## Implementation Steps

### Milestone M0 — Protocol probe (~half a day)

Goal: confirm Model A and the event shapes against the *actual* running Hermes server
before investing in the app. (Protocol archaeology is already done — this is a live
sanity check, not a week of research.)

#### Task 1: Swift protocol probe against the live server

**Files:**
- Create: `Probe/main.swift` (throwaway Swift executable or a single XCTest)
- Create: `Probe/README.md`

- [x] write a minimal `URLSessionWebSocketTask` client that connects to
  `<server>/api/ws?token=<stable>` and reads newline-delimited JSON-RPC frames
- [x] call `session.create`, then `prompt.submit`, and log every inbound
  `{method:"event", params:{type,…}}` frame (raw)
- [x] verify against the live server: `gateway.ready`, `message.start/delta/complete`,
  `status.update` arrive (tool events not exercised by the simple prompt — fine)
- [x] record one real event sequence to a JSON fixture file for later reduction tests
  (`Probe/fixtures/session-events.jsonl`)
- [x] note payload-shape surprises and update the plan's "Verified WebSocket protocol"
  section (see **M0 findings** above — 5 corrections captured)
- [x] run the probe — streamed a full prompt/response (`✅ streaming loop confirmed`)
- ➕ ⚠️ follow-up for M1: resolve the two-session-id resume question (Task 8) and
  whether tool events need a separate probe with a tool-invoking prompt

### Milestone M1 — Vertical slice (send a prompt, watch it stream)

#### Task 2: Tuist + HermesKit scaffold

**Files:**
- Create: `Project.swift`, `Tuist/`, `.gitignore`
- Create: `Package.swift` (HermesKit local SPM package)
- Create: `HermesKit/Sources/HermesKit/` (module entry), `HermesKit/Tests/HermesKitTests/`
- Create: `HermesMobile/Sources/HermesMobileApp.swift`

- [x] define `Project.swift`: app target `HermesMobile` (`.iPhone`, iOS 17), Debug/Release
  configs, Debug server preset via `HERMES_DEFAULT_SERVER_URL` env at generate time
  (leak-free — empty unless set); depends on local `HermesKit` package via `.local`
- [x] add SPM deps in `HermesKit/Package.swift`: `swift-composable-architecture` +
  `swift-dependencies` (for `DependenciesMacros`/`@DependencyClient`). `swift-navigation`
  is **available transitively via TCA** — add explicitly only if a non-TCA usage appears.
- [x] gitignore generated `*.xcodeproj`/`*.xcworkspace`/`Derived/`; commit `Project.swift`
- [x] add a placeholder `AppFeature` reducer + root `App`/`AppView` so generation builds
- [x] write a smoke test (`AppFeatureTests`) asserting initial state + lifecycle no-op
- [x] verified: `swift test` (1 passed), `tuist generate`, and `xcodebuild` for iOS
  Simulator → **BUILD SUCCEEDED**

#### Task 3: Models + `GatewayEvent` decoding

**Files:**
- Create: `HermesKit/Sources/HermesKit/Models/{Session,ChatRow,GatewayEvent,JSONRPC,ApprovalRequest,ClarifyRequest}.swift`
- Create: `HermesKit/Tests/HermesKitTests/GatewayEventDecodingTests.swift`

- [x] define `Session` (domain) + `SessionHandle` (verified create/resume result with
  both ids), `ChatRow` (`.message/.tool/.thinking/.status`), `ApprovalRequest`/
  `ClarifyRequest`/`SecretPrompt` request models
- [x] define `GatewayEvent` enum incl. `unknown(type:, raw:)`; map from `{type, payload}`
  with `session_id` read at the **frame** level (per M0); `reasoning.delta` folds into
  `.thinkingDelta`
- [x] define JSON-RPC envelope types: `JSONRPCRequest` (outbound) + `InboundFrame`
  classifier (`.event`/`.response`/`.failure`/`.ignored`) + a `JSONValue` for
  loosely-typed surfaces (tool args, unknown payloads, raw results)
- [x] decoding tests for every handled event type, using trimmed inlined M0 frame
  shapes (fixture is gitignored, so frames are inlined to keep the suite hermetic)
- [x] test: unknown event type → `.unknown` and never throws (+ unknown without payload)
- [x] direct tests for the outbound `JSONRPCRequest` wire shape and `JSONValue`
  Codable (bool-vs-number disambiguation, round-trips, accessors, malformed-throws)
- [x] run tests — **29 passed** (`swift test`)

#### Task 4: `KeychainClient` + `HermesRESTClient`

**Files:**
- Create: `HermesKit/Sources/HermesKit/Clients/{KeychainClient,HermesRESTClient}.swift`
- Create: `HermesKit/Tests/HermesKitTests/HermesRESTClientTests.swift`

- [x] verified REST JSON shapes against the real source (`web_server.py` + `hermes_state.py`)
  before writing DTOs — status, sessions list (`s.*` + computed `preview`/`last_active`),
  search (`{results}` with `snippet`, **no title**), messages (`messages` table columns)
- [x] `@DependencyClient KeychainClient` (load/save/delete) — live (Security/Keychain)
  + `inMemory()` for previews/tests; `testValue` = in-memory
- [x] `@DependencyClient HermesRESTClient`: `status(baseURL:)` (unauthenticated probe),
  `sessions`, `search`, `messages`; attaches `X-Hermes-Session-Token`; injectable
  `URLSession` for tests; `testValue` = unimplemented (calls must be stubbed)
- [x] typed `RESTError`: 401→`.unauthorized`, 404→`.notFound`, other→`.server`,
  transport→`.unreachable`, bad body→`.decoding`
- [x] tests with a `URLProtocol` mock: status decode, sessions/search mapping, messages,
  header+query attachment, no-token-on-probe, 401, transport-fail, malformed body;
  + keychain in-memory round-trip
- [x] run tests — **39 passed** (`swift test`)

#### Task 5: `HermesGatewayClient` (WebSocket JSON-RPC)

**Files:**
- Create: `HermesKit/Sources/HermesKit/Clients/HermesGatewayClient.swift`
- Create: `HermesKit/Tests/HermesKitTests/HermesGatewayClientTests.swift`

- [x] `@DependencyClient HermesGatewayClient` with `connect`/`send`/`disconnect`;
  transport abstracted behind `WebSocketTransport` so tests inject a fake socket
- [x] `GatewayConnection` actor over `URLSessionWebSocketTask`: id counter,
  pending-request map (`id → continuation`), routes `InboundFrame` to event stream
  vs. waiting `send`; **`send` fails fast (`.disconnected`) on a finished connection
  so a torn-down socket can never hang the caller**
- [x] newline-delimited framing (one WS message → many frames) + socket close finishes
  the stream and fails all outstanding requests
- [x] fake-transport tests: send↔result correlation, concurrent-send id routing, events
  on stream, multi-frame split, error response, not-connected, socket-close-fails-pending
- [x] run tests — **46 passed** (`swift test`). ⚠️ note: pipe `swift test` through
  `script -q /dev/null …` for live (unbuffered) output; bare pipes buffer until exit

#### Task 6: `ConnectionFeature` (staged validation)

**Files:**
- Create: `HermesKit/Sources/HermesKit/Features/ConnectionFeature.swift`
- Create: `HermesMobile/Sources/Features/ConnectionView.swift`
- Create: `HermesKit/Tests/HermesKitTests/ConnectionFeatureTests.swift`

- [x] staged flow with a `Status` enum (idle/checking/invalidURL/unreachable/notHermes/
  reachable/validating/invalidToken/failed): `GET /api/status` distinguishes unreachable
  (`.unreachable`) vs. not-Hermes (`.decoding`); token validated via authed
  `GET /api/sessions?limit=1`; on success persist to Keychain + `.delegate(.connected)`
- [x] lenient URL parsing (defaults `http://`); editing the URL resets status to idle
- [x] SwiftUI `ConnectionView`: URL + secure token fields, gated buttons (`canCheck`/
  `canConnect`), per-status footer messaging
- [x] reducer tests: happy path (stores token), unreachable, not-Hermes, invalid-token
  (no store), empty-URL, edit-resets-status
- [x] run tests — **52 passed**; `xcodebuild` app target → **BUILD SUCCEEDED**

#### Task 7: `SessionListFeature` (list / search / create)

**Files:**
- Create: `HermesKit/Sources/HermesKit/Features/SessionListFeature.swift`
- Create: `HermesMobile/Sources/Features/SessionList{View,RowView}.swift`
- Create: `HermesKit/Tests/HermesKitTests/SessionListFeatureTests.swift`

- [x] load `GET /api/sessions?order=recent` on appear + pull-to-refresh; `.searchable`
  field → debounced (300ms via `clock.sleep` + `.cancellable(cancelInFlight:)`) →
  `/api/sessions/search?q=` (empty query reloads the full list)
- [x] `SessionRowView`: title (or id), relative timestamp, preview; row tap →
  `.delegate(.openSession)`, "+" → `.delegate(.createSession)` — `ChatFeature`/`AppFeature`
  wiring deferred to Task 8 (same delegate seam as `ConnectionFeature`)
- [x] reducer tests: load success, load failure (typed error message), debounced search
  via `TestClock`, open/create delegate emission
- [x] run tests — **57 passed**; `xcodebuild` app target → **BUILD SUCCEEDED**
- ➕ note: modern TCA has no `Effect.debounce(clock:)`; use `clock.sleep` +
  `.cancellable(id:, cancelInFlight: true)` instead

#### Task 8: `ChatFeature` streaming core

**Files:**
- Create: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift`
- Create: `HermesMobile/Sources/Features/Chat/{ChatView,MessageBubbleView,ToolStatusView,ComposerView}.swift`
- Create: `HermesKit/Tests/HermesKitTests/ChatReductionTests.swift`

- [x] long-running cancellable connect effect (`CancelID.socket`) funnels every event
  through `.gatewayEvent`; stream end → `.gatewayClosed`; reconnect/backoff
  (`2^(attempt-1)`, cap 30s, via `clock.sleep`) driven in the reducer; `.onDisappear`
  cancels socket + reconnect
- [x] **two-session-id model (unified):** first ready with no stored id → `session.create`;
  any ready with a stored id (resume entry / reconnect) → `session.resume` by stored id
  (which `create` also returns). History hydrates via REST `messages(storedID)`.
  ⚠️ **still needs live verification** (server wasn't up to probe `session.resume`) — if
  resume actually wants the live `session_id`, it's a one-line change in `bootstrapSession`
- [x] resume path: REST history hydrate (`.task`) + connect socket; new path:
  connect → `session.create` on `.ready`
- [x] fold rules verified by tests: single in-flight assistant row for `message.*`
  (no id), tool rows keyed by `tool_id`, `thinking.delta`/`reasoning.available` → one
  collapsible row, `status.update` → transient `activity` footer, `error` → banner
- [x] composer submit → optimistic user row + `prompt.submit`; interrupt →
  `session.interrupt`; both capture deps in the effect
- [x] native `AttributedString` markdown (inline-only, whitespace-preserving) for
  assistant text in `MessageBubbleView`
- [x] event-reduction tests (streaming/thinking/tool/status/error) with `.incrementing`
  UUIDs; create-bootstrap integration test; reconnect/backoff test with `TestClock`
- [x] run tests — **64 passed**; app `BUILD SUCCEEDED`; `ChatView` snapshot recorded
- [x] **`AppFeature` integration**: onboarding (`ConnectionFeature`) until connected,
  then `SessionListFeature` as the stack root pushing `ChatFeature` screens; wired via
  child delegates (`connected` / `openSession` / `createSession`). 66 tests pass; runs
  on simulator. (`AppView` renders the `NavigationStack` over `StackState`.)
- ➕ **M1 demo (send a prompt from iPhone, watch it stream) — ready for on-device run**:
  needs the iPhone connected + Hermes running (Model A) + `DEVELOPMENT_TEAM=7V99GYC5W7
  make run-device`. This is also where the `session.resume` contract gets live-verified.

### Milestone M2 — Approvals & clarify (the mobile-native payoff)

#### Task 9: Approvals (folded into `ChatFeature`)

**Decision:** implemented inside `ChatFeature` (not a separate child reducer) — responding
needs ChatFeature's gateway connection + sessionID, so a child would just reach back into
all of it. State: `pendingInteraction: PendingInteraction?` (enum covering approval +
clarify/secret for Task 10).

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift`
- Create: `HermesMobile/Sources/Features/Chat/ApprovalCardView.swift`
- Create: `HermesKit/Tests/HermesKitTests/ChatInteractionTests.swift`

- [x] `approval.request` → `state.pendingInteraction = .approval(req)`; `canSend` now also
  requires `pendingInteraction == nil`, so the composer is blocked; `ApprovalCardView` pinned
- [x] Approve/Deny + "approve all" toggle → `respondToApproval(approve:all:)` →
  `approval.respond({session_id, request_id, choice, all})`; clears pending + appends a
  settled `.status` row ("Approved"/"Denied")
- [x] tests: request pins card + blocks composer; approve/approve-all/deny round-trips
  assert the exact RPC params (via recorded `gateway.send`)
- [x] run tests — **70 passed**; app `BUILD SUCCEEDED`

#### Task 10: `ClarifyFeature` (+ sudo/secret)

**Files:**
- Create: `HermesKit/Sources/HermesKit/Features/ClarifyFeature.swift`
- Create: `HermesMobile/Sources/Features/Chat/ClarifyCardView.swift`
- Create: `HermesKit/Tests/HermesKitTests/ClarifyFeatureTests.swift`

**Decision:** like Task 9, folded into `ChatFeature` (not a separate child reducer) —
responding needs the gateway connection + sessionID. `PendingInteraction` already had
`.clarify`/`.secret` cases; this task wired the events, responses, and a shared
`ClarifyCardView`.

- [x] `clarify.request`: choices[] non-empty → selectable options; empty → inline text
  input → `clarify.respond({request_id, answer})`. `ClarifyCardView` covers both shapes.
- [x] `sudo.request`/`secret.request` → same card with secure entry → `sudo.respond`/
  `secret.respond`. **Verified value keys differ** (`tui_gateway/server.py:5224-5236`):
  `clarify`→`answer`, `sudo`→`password`, `secret`→`value`. `secret.request` carries a
  `prompt`; `sudo.request` payload is `{}` (no prompt). Secret value is **never echoed**
  into the transcript (settled row shows "Password/Secret submitted").
- [x] composer disabled while `pendingInteraction` set (`canSend` already gates on it);
  clears on response
- [x] ⚠️ **investigated — server does NOT re-emit pending prompts on reconnect.**
  `_block` registers the request in `_pending`/`_pending_prompt_payloads` and the thread
  blocks up to a timeout (clarify 300s, sudo 120s), but only `_session_pending_kind`
  reads the stored payload — just to report a "waiting" status on `session.info`, not to
  re-`_emit` the `*.request`. So a socket drop mid-prompt loses the card client-side
  while the server stays blocked until timeout. **MVP limitation, accepted** (matches the
  deferred reconnect-resilience scope); a future fix could re-surface from `session.info`
  `live_status == "waiting"`. Revisit in Task 11 (reconnect resilience).
- [x] write tests: choices path, free-text path, secure-entry path (sudo + secret),
  request-pins-card, no-secret-echo, guard when nothing pending — 7 new tests
- [x] run tests — **77 passed**; app `BUILD SUCCEEDED`

### Milestone M3 — Polish

#### Task 11: Chat polish (markdown, copy, tool rows, resilience)

**Files:**
- Create: `HermesKit/Sources/HermesKit/Models/MarkdownSegment.swift`,
  `HermesKit/Sources/HermesKit/Clients/PasteboardClient.swift`,
  `HermesMobile/Sources/Features/Chat/MarkdownText.swift`
- Modify: `HermesMobile/Sources/Features/Chat/*.swift`, `HermesKit/.../ChatFeature.swift`,
  `HermesKit/.../Models/ChatRow.swift`
- Create: `HermesKit/Tests/HermesKitTests/MarkdownSegmentTests.swift`;
  Modify: `HermesKit/Tests/HermesKitTests/ChatReductionTests.swift`

- [x] markdown rendering: `MarkdownSegment.parse` (pure, in HermesKit) splits ``` fences;
  `MarkdownText` renders code blocks in a monospaced box. **Lesson (caught by snapshot):**
  SwiftUI `Text` does *not* lay out block-level Markdown — `.full` collapsed lists onto
  one line with no bullets/newlines. Fix: render prose **line-by-line**, drawing explicit
  bullets/numbers and keeping inline-only Markdown (bold/code/links) per line. Tolerates
  an unterminated fence mid-stream.
- [x] copy-message action: `PasteboardClient` dependency + `ChatRow.copyText` +
  `.copyRow(id:)` reducer action; `ChatView` exposes it via a per-row context menu
- [x] collapsible tool rows (result + duration) and thinking row — already present from
  Task 8 (`ToolStatusView` / `DisclosureGroup`); kept as-is
- [x] reconnect resilience: **transcript persists across reconnect** (TCA state), and
  `gatewayClosed` now calls `finalizeInFlight` to close out a half-streamed row so it
  doesn't spin forever; **visible connection state** via a `connecting…/reconnecting…`
  banner in `ChatView` driven by `state.status`.
  - ⚠️ **Not done (deferred):** true re-hydration of messages the agent emitted *while
    the socket was down* — would need a diff against `session.resume`'s inline
    `messages[]` to avoid duplicating the persisted transcript. Out of MVP scope; pairs
    with the Task 10 "pending prompts not re-emitted on reconnect" limitation. Revisit
    if on-device testing shows dropped turns.
- [x] tests: `MarkdownSegmentTests` (5 — plain, fenced, lang-hint, unterminated, blank
  trimming); `ChatReductionTests` (+3 — finalize-in-flight-on-close, copy round-trip,
  copy-unknown-row no-op)
- [x] **snapshot tests** (`HermesMobileTests/PreviewSnapshotTests`, +5): approval card,
  clarify-choices, clarify-free-text, secret card, chat with code-block + reconnecting
  banner; updated the existing `testChatView` baseline (now real bullets + `.ready`
  status). 11 snapshot tests pass via `make snapshot`. **These caught the list-collapse
  bug above** — exactly the M3 stabilization payoff the plan anticipated.
- [x] run tests — **85 HermesKit + 11 snapshot pass**; app `BUILD SUCCEEDED`

#### Task 12: `SettingsFeature` + connection debug log

**Decisions (resolved interactively):** Settings is a **sheet from the session list**
(gear in the toolbar) since token + log are app-global. The debug log is fed by an
app-wide **`DebugLogClient`** ring buffer (not feature state, so `ChatFeature`'s
high-frequency event fold and its tests stay untouched). "Manual reconnect" = **reload
the session list** over REST (the live socket is per-chat; a global socket reconnect was
rejected as awkward).

**Files:**
- Create: `HermesKit/Sources/HermesKit/Features/SettingsFeature.swift`,
  `HermesKit/Sources/HermesKit/Clients/DebugLogClient.swift`,
  `HermesKit/Sources/HermesKit/Models/GatewayLogEntry.swift`
- Create: `HermesMobile/Sources/Features/Settings/{SettingsView,ConnectionDebugView}.swift`
- Modify: `SessionListFeature` (presents settings, handles its delegates), `AppFeature`
  (`disconnect` → reset to onboarding), `ChatFeature` (connect loop mirrors events into
  the buffer), `SessionListView` (gear + `.sheet`)
- Create: `HermesKit/Tests/HermesKitTests/{SettingsFeatureTests,DebugLogClientTests}.swift`;
  Modify: `SessionListFeatureTests`, `PreviewSnapshotTests`

- [x] **token**: `SettingsView` shows server URL + a secure token field; "Save token"
  persists to Keychain + `delegate(.tokenSaved)` (re-paste); "Clear token & disconnect"
  deletes from Keychain + `delegate(.disconnect)` → `AppFeature` tears down to onboarding.
- [x] **manual reconnect**: "Reconnect" → `delegate(.reconnect)` → `SessionListFeature`
  re-fetches the list; the sheet auto-dismisses via `@Dependency(\.dismiss)`.
- [x] **debug log**: `DebugLogClient` (capped 200, lock-guarded ring buffer + live
  fan-out `AsyncStream`); `GatewayLogEntry` maps each event to type + truncated summary;
  `ChatFeature.connect` appends; `SettingsFeature.task` subscribes; `ConnectionDebugView`
  renders the live feed.
- [x] tests: `SettingsFeatureTests` (5 — clear→delete+disconnect, reconnect delegate,
  save→persist+tokenSaved, no-op-when-unchanged, log stream); `DebugLogClientTests`
  (4 — sequential ids/summaries, capacity cap, stream prime+broadcast, newline collapse);
  `SessionListFeatureTests` (+4 — present, disconnect-bubbles, reconnect-reloads,
  token-saved-updates-connection)
- [x] **snapshot tests** (+2): `SettingsView`, `ConnectionDebugView`
- [x] run tests — **98 HermesKit + 13 snapshot pass**; app `BUILD SUCCEEDED`

### Task 13: Verify acceptance criteria

- [ ] verify all Overview requirements: connect, list, resume, create, stream,
  tool/status visibility, approve/deny, clarify
- [ ] verify edge cases: unknown events ignored, 401 token, socket drop/reconnect,
  pending-interaction blocking
- [ ] run full test suite (`tuist test` / `swift test`)
- [ ] verify event-reduction coverage against the M0 fixture

### Task 14: [Final] Documentation

- [ ] write `README.md`: architecture, the Model A server setup (`--insecure` + stable
  token), Tailscale connection, build instructions
- [ ] update `CLAUDE.md` with project conventions (TCA/Tuist/HermesKit layout) if useful
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion

*Items requiring manual intervention or external systems — informational only.*

**Hermes server setup (operator action, not iOS code):**
- Launch Hermes with `--host 0.0.0.0 --insecure` and set
  `HERMES_DASHBOARD_SESSION_TOKEN=<stable secret>` in its environment.
- Ensure the Mac/server and iPhone are on the same tailnet; confirm
  `GET http://<tailscale-host>:<port>/api/status` is reachable from the phone.

**Manual verification:**
- On-device run against the real server: create + resume sessions, stream a real
  prompt, exercise a real approval and a real clarify request.
- Confirm pending approval/clarify survive a socket drop (the ⚠️ Task 10 finding).
- TestFlight build only after the streaming + approval loop works on-device.

**Fast-follows (post-MVP, NOT in this plan's scope):**
- **Push notifications for approvals** — #1 priority; the app is half-blind without it.
  Requires backend work (APNs + a notify hook in Hermes).
- Stable-token / QR onboarding UX (scan a QR encoding URL + token).
- Model B: OAuth-gated remote access (`dashboard_auth`) for use without Tailscale.

**Explicitly out of scope:**
- On-device Hermes runtime, desktop feature parity, terminal/file browser, full
  config/model/profile editor, multi-user/team, public internet exposure beyond
  Tailscale, real device pairing/revocation backend.
