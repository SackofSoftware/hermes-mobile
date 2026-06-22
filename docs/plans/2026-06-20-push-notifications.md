# Push Notifications for Hermes Mobile

## Overview

Notify the iOS app when the self-hosted Hermes Agent needs the user, even while the
app is backgrounded (its WebSocket dropped). Four trigger events: **approval
requests**, **clarify / input-needed**, **turn complete**, and **errors/failures**.

Target is a *publishable, multi-user* App Store app used by many self-hosters, and the
user will **not** run a VPS. The hard constraint: APNs auth uses the *publisher's* APNs
key (`.p8`, tied to Team ID + bundle id) — it cannot be safely distributed to users'
machines. So the design splits the work:

- the **trigger** runs on the user's agent (a pip-installable Hermes plugin, holds no
  Apple secret),
- the **sender** is a tiny **stateless serverless function** the publisher operates
  (the only place the `.p8` lives — an edge function, not a VPS),
- the **iOS app** registers its device token with the user's own agent (over Tailscale)
  and handles incoming pushes.

This is the Home Assistant push model. Privacy: only a generic title/body + `session_id`
transit the gateway; real message content is fetched in-app over Tailscale.

## Context (from discovery)

Spans **three artifacts across two repos**:

- **This repo (`hermes-mobile`)** — iOS app. Logic in `HermesKit/` (SwiftUI + TCA),
  thin views in `HermesMobile/`. Clients are `@DependencyClient` structs in
  `HermesKit/Sources/HermesKit/Clients/` (see `AudioRecorderClient.swift` for the
  iOS-only `#if canImport(UIKit)` guard pattern; `HermesRESTClient.swift` for REST).
  Features in `HermesKit/Sources/HermesKit/Features/`. `Project.swift` (Tuist) is the
  source of truth for entitlements/Info.plist; bundle `me.honcharenko.HermesMobile`,
  team `7V99GYC5W7`, iOS 17 deployment target.
- **Sibling repo (`hermes-agent`, `/Users/eugene/Documents/Development/Personal/hermes-agent`)** —
  the `hermes-push` plugin. Real plugin system: pip entry point `hermes_agent.plugins`
  with `register(ctx)`. Relevant source: hooks `pre_approval_request`
  (`tools/approval.py` ~1155, exposes `surface`) and `pre_gateway_dispatch`
  (`gateway/run.py` ~7428); event emit `_emit` (`tui_gateway/server.py` ~512); gateway
  method dispatch `_methods`/`@method` (~564-600); plugin REST mounting
  `_mount_plugin_api_routes` (`hermes_cli/web_server.py` ~9166, mounts a plugin's
  `dashboard/manifest.json` `api` router at `/api/plugins/<name>/`); plugin storage
  convention (`plugins/disk-cleanup/` uses `get_hermes_home()/<name>/*.json`).
- **Gateway function (new, standalone)** — a stateless serverless fn (Cloudflare Workers
  / Deno Deploy / Lambda free tier). Lives in its own small repo/dir; tracked here for
  completeness.

Related patterns to mirror: capability-gating (attach/profiles hide when the server
404s); "logout clears everything"; cancellable effects; `TestStore` + `@Dependency` +
`TestClock` reducer tests; snapshot tests for view states.

## Development Approach

- **Testing approach**: Regular (implementation, then tests **within the same task**).
  Per project convention, every task includes new/updated tests — not optional.
- Complete each task fully (including passing tests) before the next.
- Per-task commits during execution. Skip the codex external-review phase.
- Small, focused changes; maintain backward compatibility (old agents without the
  plugin must degrade gracefully via capability-gating).
- iOS 17 deployment target — gate any newer APIs with `#available`.
- **New Swift source files need `tuist generate`** before an `xcodebuild` app build
  sees them.

## Testing Strategy

- **Unit tests (required every task):**
  - HermesKit (`script -q /dev/null swift test --package-path HermesKit` / `make test`):
    `PushClient` flows; reducer registration-on-connect, unregister-on-logout,
    capability-gated-hide — `TestStore` + `@Dependency` overrides + `TestClock`.
  - Plugin (Python): hook→payload mapping, suppression policy, dedup window, token
    pruning — mock the gateway POST.
  - Gateway fn: JWT minting (ES256 header/claims), `apns_env`→host selection, HMAC
    verify, 410→prune signaling — mock APNs.
- **Snapshot tests** (`make snapshot` / `make snapshot-record`): Settings notifications
  toggle states (enabled / unavailable / test-sent). Re-record when UI changes
  intentionally.
- **Manual E2E** (Post-Completion): in-app "send test notification" with a real `.p8`
  to a real device, in **both** sandbox and production.

## Progress Tracking

- Mark completed items `[x]` immediately when done.
- New tasks prefixed `➕`; blockers prefixed `⚠️`.
- Keep this file in sync; update if scope changes.

## Solution Overview

End-to-end flow:

```
┌─ User's machine ────────────┐      ┌─ Publisher ────┐      ┌─ Apple ─┐     ┌ Phone ┐
│  Hermes Agent               │      │ Push gateway   │      │  APNs   │     │  App  │
│   └─ hermes-push (plugin)   │ ───► │ (serverless fn)│ ───► │         │ ──► │       │
│      hooks + REST route     │ POST │ holds .p8/JWT  │ HTTP │         │     │       │
└─────────────────────────────┘      └────────────────┘      └─────────┘     └───────┘
        ▲ device token + apns_env registered by app over Tailscale ─────────────┘
```

**Build order** (minimizes blocked work):

1. **Gateway fn first** — independently testable against APNs, gives the plugin a real
   endpoint and the app a way to verify "send test notification" early.
2. **`hermes-push` plugin** — trigger hooks + REST registration route + outbound POST to
   the gateway.
3. **iOS app** — `PushClient`, registration reducer wiring, receive/deep-link, Settings
   toggle + test button, entitlements. Can begin against a stub registration endpoint in
   parallel with (2).

Key design decisions: APNs token-auth (`.p8`/ES256 JWT, never expires) over certs;
generic notification body (privacy); "push only when no live client + duration gate"
suppression; capability-gating for old agents; compile-time `apns_env`.

## Technical Details

**Gateway request (plugin → fn):**
```
POST /push  { device_token, apns_env: "sandbox"|"production", type, session_id,
              title, body, thread_id, hmac? }
```
**Gateway → APNs:** `POST https://{api|api.sandbox}.push.apple.com/3/device/{token}`
headers `authorization: bearer <ES256 JWT {kid}/{iss=TEAM_ID}>`, `apns-topic: <bundle>`,
`apns-push-type: alert`, `apns-priority: 10`, `apns-collapse-id: <session_id>`; body
`{ aps: { alert:{title,body}, sound:"default", "thread-id":<session_id>,
"interruption-level": type=="approval" ? "time-sensitive" : "active" }, session_id }`.
On APNs `410 Unregistered` → relay a prune signal.

**Registration (app → plugin REST):** `POST /api/plugins/hermes-push/register`
`{ device_token, apns_env, app_version }`, auth `X-Hermes-Session-Token`. Plus
`/unregister`. Storage: `~/.hermes/hermes-push/tokens.json`.

**Suppression:** push only when no live client is bound to the session; turn-complete /
error additionally require turn duration > ~10s; dedup rapid repeats per session within
a short window (collapse-id reinforces on the APNs side).

## What Goes Where

- **Implementation Steps** (`[ ]`): all code, tests, and config achievable in the repos.
- **Post-Completion** (no checkboxes): Apple Developer portal setup (App ID push capability,
  `.p8` key), gateway secret provisioning + deploy, manual on-device E2E, App Store
  submission notes.

---

## Implementation Steps

### Part A — Push gateway (serverless fn)

> Standalone small repo/dir. Language per platform (TS for Workers/Deno). Tests mock APNs.

### Task A1: Scaffold gateway fn + config/secrets loading

**Files:**
- Create: `gateway/src/index.ts` (handler entry)
- Create: `gateway/src/config.ts` (reads `.p8`, KEY_ID, TEAM_ID, BUNDLE_ID, HMAC_SECRET from env/secrets)
- Create: `gateway/src/config.test.ts`
- Create: `gateway/README.md`, `gateway/package.json`, deploy config (e.g. `wrangler.toml`)

- [x] scaffold the chosen platform (Cloudflare Workers / Deno Deploy / Lambda) with a single `POST /push` route
- [x] implement config loader pulling APNs creds + HMAC secret from platform secrets
- [x] reject startup/handler if required secrets are missing (clear error)
- [x] write tests for config loading (present / missing-secret cases)
- [x] run tests — must pass before next task

### Task A2: ES256 JWT minting (with cache)

**Files:**
- Create: `gateway/src/apnsJwt.ts`
- Create: `gateway/src/apnsJwt.test.ts`

- [x] implement ES256 JWT: header `{alg:"ES256", kid:KEY_ID}`, claims `{iss:TEAM_ID, iat}`
- [x] cache the minted token ~50 min and reuse; re-mint when stale
- [x] write tests for header/claims correctness and cache reuse/expiry (inject clock)
- [x] write tests for malformed/missing key handling
- [x] run tests — must pass before next task

### Task A3: Request validation, HMAC verify, rate-limiting

**Files:**
- Create: `gateway/src/validate.ts`
- Create: `gateway/src/validate.test.ts`

- [x] validate payload shape; cap body size; reject malformed → 400
- [x] verify optional `hmac` over the payload using the per-device secret when present
- [x] rate-limit per `device_token` and per source IP
- [x] write tests for valid/invalid shapes, HMAC pass/fail, rate-limit trip
- [x] run tests — must pass before next task

### Task A4: APNs forwarding + env→host selection + 410 handling

**Files:**
- Modify: `gateway/src/index.ts`
- Create: `gateway/src/apnsSend.ts`
- Create: `gateway/src/apnsSend.test.ts`

- [x] select host from `apns_env` (`api.push.apple.com` vs `api.sandbox.push.apple.com`)
- [x] build APNs request (topic, push-type, priority, collapse-id, thread-id, interruption-level)
- [x] forward and relay APNs status; on 410 return a prune signal to caller
- [x] ensure no message content is logged (metadata-only or no logging)
- [x] write tests (mock APNs): env→host, header/payload assembly, 200 + 410 paths
- [x] run tests — must pass before next task

### Part B — `hermes-push` Hermes plugin (sibling repo)

> In `/Users/eugene/Documents/Development/Personal/hermes-agent`. Python. `pytest`.

### Task B1: Plugin scaffold + manifest + entry point

**Files:**
- Create: `hermes-push/pyproject.toml` (entry point `hermes_agent.plugins`)
- Create: `hermes-push/hermes_push/__init__.py` (`register(ctx)`)
- Create: `hermes-push/plugin.yaml`
- Create: `hermes-push/dashboard/manifest.json` (declares `api` router path)
- Create: `hermes-push/tests/test_register.py`

- [x] scaffold pip package with `register(ctx)` and `plugin.yaml`
- [x] declare `dashboard/manifest.json` with `api` field pointing to the REST router module
- [x] confirm plugin loads (entry-point discovery) and `register` runs without error
- [x] write tests for `register` wiring (hooks + route registered)
- [x] run tests — must pass before next task

### Task B2: Device-token registration REST route + storage

**Files:**
- Create: `hermes-push/hermes_push/api.py` (FastAPI `router`: `/register`, `/unregister`)
- Create: `hermes-push/hermes_push/store.py` (`~/.hermes/hermes-push/tokens.json`)
- Create: `hermes-push/tests/test_api.py`
- Create: `hermes-push/tests/test_store.py`

- [x] implement `POST /register` `{device_token, apns_env, app_version}` and `/unregister`
- [x] ⚠️ CONFIRM `X-Hermes-Session-Token` auth middleware covers `/api/plugins/*`; if not, enforce auth in the router — **CONFIRMED YES**: `auth_middleware` (hermes_cli/web_server.py:327) gates all `/api/` routes except the small read-only allowlist in `dashboard_auth/public_paths.py` (`/api/status`, `/api/dashboard/plugins`, …); `/api/plugins/hermes-push/register` + `/unregister` are NOT in it, so the dashboard session-token (or OAuth cookie) is required. No redundant in-router auth added.
- [x] implement JSON-file token store (upsert by token, list, remove, prune-invalid)
- [x] mint + return a per-device HMAC secret on register (store alongside token) — reused (not rotated) on re-register so the app's stored secret stays valid
- [x] write tests for register/unregister + store upsert/remove/prune
- [x] run tests — must pass before next task

### Task B3: Trigger hooks → event mapping

**Files:**
- Create: `hermes-push/hermes_push/triggers.py`
- Create: `hermes-push/tests/test_triggers.py`

- [x] register `pre_approval_request` (approval; honor `surface`, ignore CLI-only) — bound to `TriggerDispatcher.on_pre_approval_request`; gateway surface → payload, cli/empty → skipped
- [x] register `pre_gateway_dispatch` for `message.complete` (turn complete) + `error` — **N/A via this hook**: `pre_gateway_dispatch` fires only for *incoming* user `MessageEvent`s (gateway/run.py:7418), never outbound events. complete/error/clarify are `_emit`-ed straight to the WS transport (tui_gateway/server.py:512) with no hook, so they are mapped via the loopback `/api/ws` client instead (see next item). The hook stays registered as a strict no-op observer.
- [x] ⚠️ VERIFY `clarify.request` surfaces through a hook; if not, add the thin loopback `/api/ws` client fallback (subscribe read-only) — **VERIFIED: NO hook path.** `clarify.request` (tui_gateway/server.py:2158), `message.complete` (:4699) and `error` (:4826) are all emitted via `_emit(...)` direct to the WS transport — none pass through a registerable hook. **Path: loopback WS fallback** — the pure event→payload mapper `triggers.map_ws_event` / `TriggerDispatcher.handle_ws_event` (exact event `type` strings `"clarify.request"`, `"message.complete"`, `"error"`) is implemented + unit-tested here in B3; the guarded, off-thread connector to `/api/ws` is wired in B5 (it needs the sender lifecycle). Only `type` + `session_id` are read — never the content `payload`.
- [x] map each event → `{type, session_id, title, generic body}` (no message content) — `make_payload` builds `{type, session_id, title, body, thread_id=session_id}`; titles/bodies are centralized constants (`TITLES`/`BODIES`), no event content interpolated
- [x] write tests for hook→payload mapping for all four event types — `tests/test_triggers.py`: all 4 types, approval surface-gating (gateway→mapped, cli/empty→skipped), WS mapper for complete/error/clarify + ignored events, dispatcher sink wiring + non-raising, content-leak guard (28 tests)
- [x] run tests — must pass before next task — `54 passed` (26 prior + 28 B3)

### Task B4: Suppression policy + dedup

**Files:**
- Create: `hermes-push/hermes_push/policy.py`
- Create: `hermes-push/tests/test_policy.py`

- [x] suppress unless **no live client** is bound to the session (read transport state) — injectable `client_present(session_id)` gate; real source (wired B5): `_sessions[sid]["transport"] is not _stdio_transport` (tui_gateway/server.py; detached → stdio on disconnect, re-bound on prompt.submit)
- [x] additionally gate turn-complete/error on turn duration > ~10s — `note_turn_start`/`clear_turn_start` + injected clock; complete/error only (approval/clarify never gated); fail-open on unknown turn start; threshold configurable (default 10s)
- [x] dedup rapid repeats per session within a short window — per `(session_id, type)` last-sent map + injected clock; default 5s; only *sent* payloads recorded (suppressed ones don't poison the window)
- [x] no-devices fast path (skip all work cheaply) — `device_count()` checked first, short-circuits before the client-present check (asserted via spy)
- [x] write tests for each gate (client-present, short-turn, dedup window, no-devices) — `tests/test_policy.py`, 18 tests incl. spy proving fast-path short-circuit
- [x] run tests — must pass before next task — `72 passed` (54 prior + 18 B4)

### Task B5: Outbound POST to gateway (fire-and-forget)

**Files:**
- Create: `hermes-push/hermes_push/sender.py`
- Modify: `hermes-push/hermes_push/__init__.py` (wire triggers→policy→sender)
- Create: `hermes-push/tests/test_sender.py`

- [x] POST `{device_token, apns_env, type, session_id, title, body, thread_id, hmac}` to gateway URL (baked-in const) — `sender.py::GatewaySender`; baked-in `GATEWAY_URL` const (`https://hermes-push.example.workers.dev/push`, publisher replaces post-deploy) with `HERMES_PUSH_GATEWAY_URL` env override; per-device `hmac` = lowercase-hex HMAC-SHA256 over the canonical string, byte-identical to `gateway/src/validate.ts::canonicalSignedString` (verified `json.dumps(signed, separators=(",",":"), ensure_ascii=False)` == JS `JSON.stringify`; fixed key order, `thread_id` omitted when absent, `hmac` excluded from signed material)
- [x] best-effort: short timeout + few retries, off the hook thread; **never block the turn** — 5s timeout, 3 bounded attempts with exponential backoff, fan-out runs on a daemon `ThreadPoolExecutor`; `send()` returns immediately (tested: dispatched to executor, not run inline; slow gateway doesn't block the caller)
- [x] on gateway prune signal (APNs 410) → remove token from store — `_is_prune` accepts HTTP 410 OR a `{"prune":true,…}` body → `store.prune_invalid(device_token)`; no retry after a prune
- [x] write tests (mock gateway): payload shape, HMAC included, timeout/retry, prune→remove — `tests/test_sender.py` (canonical-string key-order/compact-separators/non-ASCII, HMAC recompute, payload shape, multi-device fan-out with per-device secrets, transient-then-success retry, give-up after N, 5xx-retry/4xx-give-up, 410+prune-body prune, off-thread non-blocking) + `tests/test_wiring.py` (pipeline policy→sender, register stands up store/policy/sender + survives pipeline failure, loopback WS connector maps complete/turn-lifecycle/ignores-noise/degrades-without-websockets/swallows-connection-error, `build_ws_url`)
- [x] run tests — must pass before next task — `103 passed` (72 prior + 31 new)

> **WS loopback (deferred from B3, wired here):** built `wsclient.py::LoopbackWsConnector` — guarded, off-thread (daemon thread + own asyncio loop), optional (`websockets` extra), never blocks/raises into `register()`, degrades to a logged no-op when `websockets` is missing or the WS is unreachable. Connects to `ws://{host}:{port}/api/ws?token=<HERMES_DASHBOARD_SESSION_TOKEN>` (loopback/`--insecure` auth path per `hermes_cli/web_server.py::_ws_auth_reason`), URL from `HERMES_PUSH_WS_URL` / `HERMES_DASHBOARD_URL` / `HERMES_DASHBOARD_HOST`+`PORT` (default `127.0.0.1:8080`). **Architectural limitation (documented in `wsclient.py`):** complete/error/clarify are `_emit`-ed via `write_json` → `current_transport()` (transport-scoped, no global broadcast, no hook), so a separate loopback connection does NOT observe other sessions' events with hermes-agent as it stands. Approval pushes work via the hook; complete/error/clarify need hermes-agent to grow a global `_emit` fan-out (e.g. `/api/events`-style broadcast). The connector is built/wired so it lights up the moment such a channel exists; `client_present` falls back to a conservative always-notify default since the live session map isn't exposed on `PluginContext` (duration/dedup/no-devices gates remain fully active).

### Part C — iOS app (this repo)

> HermesKit logic + thin app target. `make test` / `make snapshot`.

### Task C1: `PushClient` dependency client

**Files:**
- Create: `HermesKit/Sources/HermesKit/Clients/PushClient.swift`
- Create: `HermesKit/Tests/HermesKitTests/PushClientTests.swift`

- [x] define `@DependencyClient` with: `requestAuthorization`, `authorizationStatus`, `register()` (device token via `AsyncStream`), `incomingTaps()` stream — `PushClient` exposes all four; tokens surfaced as lowercase-hex `String`, taps as a `PushTap` value type carrying `session_id`
- [x] `liveValue` guarded `#if canImport(UIKit)` (UNUserNotificationCenter + `registerForRemoteNotifications`); non-iOS fallback `liveValue = testValue` — live value wires `UNUserNotificationCenter.requestAuthorization`/`notificationSettings` + `UIApplication.registerForRemoteNotifications`, fed by a process-wide `PushBridge` (the C2 app-delegate bridge calls `tokenReceived`/`tapReceived`); `#else` falls back to `testValue`
- [x] provide `testValue` / `.inMemory()` variants (mirror `AudioRecorderClient`) — explicit no-op `testValue` (avoids macro-unimplemented leak) + `.inMemory(granted:status:)` returning a controllable `InMemory` handle (inject token/tap, set authorized) backed by a thread-safe `PushBox`
- [x] keep pure logic (token hex-encoding, env constant) outside the iOS guard — `hexToken(from:)`, compile-time `apnsEnv` (`#if DEBUG` → "sandbox" else "production"), `sessionID(fromPayload:)` are plain statics outside the guard
- [x] write tests for in-memory register/authorize flows + token encoding — `PushClientTests`: hex encoding (known bytes + empty), apns_env constant, payload→session_id (present/missing/empty/wrong-type), testValue no-op streams, in-memory authorize result, register stream yields injected token (retained), incomingTaps delivers injected tap
- [x] run tests — must pass before next task — `script -q /dev/null swift test --package-path HermesKit`: 467 tests, all passing

### Task C2: App-delegate bridge (token + tap forwarding)

**Files:**
- Create: `HermesMobile/Sources/PushAppDelegate.swift`
- Modify: `HermesMobile/Sources/HermesMobileApp.swift` (`UIApplicationDelegateAdaptor`)

- [x] add delegate handling `didRegisterForRemoteNotificationsWithDeviceToken` + `didFailToRegister` — `PushAppDelegate` forwards the token via `PushBridge.shared.tokenReceived`; failure is logged via `os.Logger` (no business logic — failures surface no actionable state on the bridge)
- [x] implement `UNUserNotificationCenterDelegate`: `didReceive` (tap) and `willPresent` (foreground) — `didReceive` → `PushBridge.shared.tapReceived(userInfo)` + completion; `willPresent` presents `[.banner, .sound]` (C2 minimal; nav-aware suppression deferred to C5)
- [x] forward token + taps into `PushClient` streams; **no logic in the delegate** — delegate only converts callbacks to `PushBridge` calls (which feed `PushClient` streams from C1); zero decisions in the delegate
- [x] wire `UIApplicationDelegateAdaptor` in the App struct — `@UIApplicationDelegateAdaptor(PushAppDelegate.self) var pushDelegate` in `HermesMobileApp`; delegate sets `UNUserNotificationCenter.current().delegate = self` at `didFinishLaunchingWithOptions`
- [x] write tests for any pure bridging helper extracted into HermesKit (token→hex, payload→`session_id` parse) — covered by C1's `PushClientTests` (`hexToken*`, `sessionID*`); the delegate calls only those pure helpers, so no new helper/test was needed
- [x] run tests — must pass before next task — `swift test --package-path HermesKit`: 467 tests passing; `tuist generate` + `xcodebuild` app build SUCCEEDED with the new delegate file

### Task C3: Add `register`/`unregister` to `HermesRESTClient` + capability detection

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Clients/HermesRESTClient.swift`
- Modify: `HermesKit/Tests/HermesKitTests/HermesRESTClientTests.swift`

- [ ] add `registerPush(deviceToken, apnsEnv, appVersion)` → `POST /api/plugins/hermes-push/register`
- [ ] add `unregisterPush(deviceToken)` → `/unregister`
- [ ] surface 404 distinctly so the reducer can capability-gate (mirror attach/profiles)
- [ ] write tests (injected `URLSession`/transport): success, 404-not-available, error
- [ ] run tests — must pass before next task

### Task C4: Registration reducer wiring (connect / token-change / logout)

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/SessionListFeature.swift` (or AppFeature — wherever connect/logout lives)
- Modify: corresponding `*FeatureTests.swift`

- [ ] on connect/launch, if authorized: get token, call `registerPush` with compile-time `apns_env` (`#if DEBUG` sandbox else production)
- [ ] re-register on device-token change (observe `PushClient.register()` stream)
- [ ] on logout call `unregisterPush` and clear any push prefs (fits "logout clears everything")
- [ ] store `pushAvailable` capability flag from the 404 result
- [ ] write reducer tests: registration-on-connect, token-change re-register, unregister-on-logout, 404→capability-hidden (`TestStore` + `@Dependency` + `TestClock`)
- [ ] run tests — must pass before next task

### Task C5: Deep-link on tap + foreground suppression + badge

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/SessionListFeature.swift` / `AppFeature.swift`
- Modify: corresponding `*FeatureTests.swift`

- [ ] handle incoming tap action → open `session_id` via existing `openSession` delegate path
- [ ] `willPresent`: suppress banner if already viewing that session (check nav state)
- [ ] badge for pending approvals; clear on viewing the session
- [ ] write reducer tests for tap→openSession, suppress-when-foregrounded, badge set/clear
- [ ] run tests — must pass before next task

### Task C6: Settings — notifications toggle + "send test notification"

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/SettingsFeature.swift`
- Modify: `HermesMobile/Sources/Features/*` (Settings view)
- Modify: `HermesKit/Tests/HermesKitTests/SettingsFeatureTests.swift`
- Modify: `HermesMobileTests/*` (snapshot)

- [ ] add "Notify me about approvals" toggle that triggers the **contextual** permission prompt (not first-launch)
- [ ] hide toggle + show "not available on this server" when `pushAvailable == false`
- [ ] add "Send test notification" button (registers if needed, asks gateway to deliver a test push)
- [ ] write reducer tests for toggle→authorize, unavailable state, test-send action
- [ ] add/record snapshot tests for the three toggle states (enabled / unavailable / test-sent)
- [ ] run tests — must pass before next task

### Task C7: Entitlements + Info.plist (Tuist)

**Files:**
- Modify: `Project.swift`
- Create: `HermesMobile/HermesMobile.entitlements` (if not using inline)

- [ ] add Push Notifications entitlement (`aps-environment`)
- [ ] add `UIBackgroundModes: [remote-notification]` to Info.plist
- [ ] run `tuist generate` and confirm the app target builds with the new capability
- [ ] write/adjust any affected snapshot/build smoke as needed
- [ ] run tests — must pass before next task

### Task C8: Verify acceptance criteria

- [ ] verify all four trigger types deliver (mock plugin/gateway where needed)
- [ ] verify suppression (no buzz while viewing session; >10s gate) and dedup
- [ ] verify capability-gating hides the toggle on an agent without the plugin
- [ ] run full HermesKit suite: `make test`
- [ ] run snapshots: `make snapshot`

### Task C9: [Final] Update documentation + close out

**Files:**
- Modify: `README.md`, `docs/architecture.md`, `CLAUDE.md`

- [ ] document the push feature + the 3-part architecture (app / plugin / gateway)
- [ ] add a `PushClient` entry to the dependency-clients list in `docs/architecture.md`
- [ ] note new conventions in `CLAUDE.md` (push capability-gating, apns_env compile-time, generic-body privacy rule)
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion

*Items requiring manual intervention or external systems — informational only.*

**Apple Developer portal (one-time):**
- Enable the **Push Notifications** capability for App ID `me.honcharenko.HermesMobile` (team `7V99GYC5W7`).
- Create an **APNs Auth Key** (`.p8`), record Key ID + Team ID. This key is the publisher secret — store **only** in the gateway fn's secrets.
- Refresh provisioning profiles; TestFlight export uses **manual signing**.

**Gateway deployment:**
- Provision the fn's secrets: `.p8` content, `KEY_ID`, `TEAM_ID`, `BUNDLE_ID` (`me.honcharenko.HermesMobile`), `HMAC_SECRET`.
- Deploy to the chosen free-tier platform; record the public URL and bake it into the plugin's `sender.py` constant.
- Confirm rate-limits + body-size caps are active; verify no content is logged.

**Plugin distribution:**
- Publish `hermes-push` (PyPI or install-from-source instructions) so self-hosters can `pip install` + restart the agent.

**Manual on-device E2E:**
- "Send test notification" through a **real** `.p8` to a **real** device, in **both** sandbox (Debug build) and production (TestFlight/App Store build) — APNs env mismatch is the classic footgun and only surfaces on-device.
- Verify tap→deep-link, foreground suppression, badge, token-rotation re-register, and 410-prune (uninstall app → confirm token pruned).

**App Store submission:**
- Push notifications require an accurate privacy nutrition label; note that only generic metadata transits the gateway, message content stays on the user's agent.
