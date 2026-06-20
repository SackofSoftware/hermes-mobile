# Auth: Password Login + Token-Mode Disclaimer

## Overview

Today the iOS app authenticates **only** with a long-lived static session token. This adds
**username/password login** like the desktop, presented as a capability-aware **segmented
toggle (Password | Token)** on the auth screen (server URL shared above), plus a
vibetunnel-style **security disclaimer + "How to connect securely" details screen** for the
token method (tailnet guidance, Tailscale link). Release blocker.

**Approach (locked):** Option A — *native two-regime auth*. The server actually has two
distinct auth **regimes**, not just two input fields:

- **Token mode** (today): loopback/`--insecure`, `auth_required=false`. REST = the
  `X-Hermes-Session-Token` header; WS = `…/api/ws?token=<token>`; token never expires.
- **Gated mode** (password/OAuth): public bind, `auth_required=true`. REST = session
  **cookies** (`hermes_session_at` ~12h, `hermes_session_rt` 30d, rotating, HttpOnly); WS
  `?token=` is **rejected** → must `POST /api/auth/ws-ticket` (cookie-authed, single-use,
  30s TTL) then connect `…/api/ws?ticket=<ticket>`.

We model an `AuthSession` (`.token` | `.cookie`) behind the existing client seams so every
downstream feature is unchanged. **OAuth is out of scope** — parked as backlog **issue #19**.
**Token-mode must stay byte-identical** to today (loopback regression guard).

## Context (from discovery)

**Backend reality** (verified against `/Users/eugene/Documents/Development/Personal/hermes-agent`):
- Password login: `POST /auth/password-login` JSON `{provider, username, password, next?}`
  → `200 {ok, next}` **+ Set-Cookie** (tokens are in cookies, not the body). Errors: `401`
  invalid creds (no user-enumeration), `429` rate-limited (10/min/IP), `503` provider
  unreachable, `404` unknown/unsupported provider. Provider name usually `"basic"`.
- **Refresh is transparent**: BasicAuth tokens are self-signed; server middleware re-mints
  the access token whenever a valid refresh cookie is presented. **No client refresh
  endpoint to build** — persist + resend the cookie jar, capture refreshed `Set-Cookie`.
- Capability probe: `GET /api/status` (public) → `auth_required` + `auth_providers`;
  `GET /api/auth/providers` → `[{name, display_name, supports_password}]`.
- `URLSession` handles cookies natively (HttpOnly only blocks JS, not native clients).

**Key files** (verified):
- `HermesKit/Sources/HermesKit/Features/ConnectionFeature.swift` (171 lines): staged
  onboarding — `checkServer`/`serverStatusResponse`; `connectTapped` → `rest.sessions` probe
  → `keychain.saveToken` + `preferences.saveServerURL` → `delegate(.connected)`;
  `State.Status` enum; `canConnect`; `parseServerURL` helper. **Main screen to extend.**
- `HermesKit/Sources/HermesKit/Clients/HermesRESTClient.swift`: `ServerConnection` (carries
  `token: String?` — **change to `AuthSession`**), `ServerStatus` (add `auth_required`/
  `auth_providers`), `RESTError` (has `.unauthorized`/`.server(status,detail)`/etc.). Add
  `passwordLogin` + a providers endpoint + a dedicated cookie `URLSession`.
- `HermesKit/Sources/HermesKit/Clients/HermesGatewayClient.swift`: `connect` — branch
  token vs ws-ticket.
- `HermesKit/Sources/HermesKit/Clients/KeychainClient.swift`: store the `AuthSession`
  (cookie payload + username), not just a bare token; has `.inMemory()`.
- `HermesKit/Sources/HermesKit/Clients/PreferencesClient.swift`: server URL; identity-scoped
  prefs to clear on user-switch (pins, seen counts, selected profile).
- `HermesKit/Sources/HermesKit/Features/AppFeature.swift`: launch auto-connect (rehydrate
  `AuthSession`); present `ReauthFeature` sheet; route `sessionExpired`; pop-to-list on
  user-switch.
- App views: `HermesMobile/Sources/Features/*` (auth screen — segmented control, password
  fields, disclaimer + details screen; `ReauthFeature` sheet); `HermesMobileTests/*`
  snapshots.

**Related patterns:** `@DependencyClient` + `liveValue`/`testValue`/`.inMemory()`; capability
gating (attach/profiles hide on 404); "logout clears everything"; reconnect/backoff lives in
the reducer (`TestClock`); `RESTError` surfaces server `detail` verbatim.

**Dependencies:** none new (uses `URLSession`/`HTTPCookieStorage`).

## Development Approach

- **Testing approach: Regular** (implementation, then tests within the same task). Per
  project convention every task includes new/updated tests.
- Reducer tests via `TestStore` + `@Dependency` + `TestClock` are the highest-value suite;
  pure logic (capability mapper, identity-compare, error→copy) extracted and unit-tested.
- Complete each task fully (tests passing) before the next. Per-task commits. Skip the codex
  external-review phase.
- `swift test` buffers when piped — use `make test`.
- **New Swift files need `tuist generate`** before an `xcodebuild` app build sees them.
- iOS 17 target — gate newer APIs with `#available`.
- **Backward compatibility is a hard requirement:** old token-only servers must behave
  exactly as today; the `.token` REST/WS paths stay byte-identical.

## Testing Strategy

- **Unit (required every task):** pure mappers (`ServerAuthCapability`, identity-compare,
  error→status copy); reducer flows (capability gating, password login success + each error,
  ws-ticket auth-failure vs transient, re-auth routing); client tests with an injected
  `URLSession` (cookie capture, token-mode WS URL byte-identical); Keychain persistence
  round-trip.
- **Snapshot** (`make snapshot` / `make snapshot-record`): auth screen per segment
  (Password / Token); token disclaimer + details screen; capability-disabled segment;
  re-auth sheet (password vs token variant). Timestamps pinned; re-record on intended UI
  change.
- No Playwright/Cypress-style e2e; on-device manual verification in Post-Completion.

## Progress Tracking

- Mark completed items `[x]` immediately. New tasks `➕`; blockers `⚠️`. Keep this file in
  sync; update if scope changes.

## Solution Overview

An `AuthSession` value (`.token(String)` | `.cookie(payload)`) flows through
`ServerConnection`, so the REST and Gateway clients adapt transport (header + `?token=` vs
cookie jar + ws-ticket) without scattering regime checks. Onboarding probes server
capability and drives a capability-aware segmented toggle. Password login captures cookies
via a dedicated `URLSession`, persists the session (incl. refresh cookie + username) to
Keychain, and relies on the server's transparent refresh. A `ws-ticket` handshake covers the
gated WebSocket. A `sessionExpired` signal pauses reconnect and raises a polished re-auth
modal with identity-aware routing. The token segment carries an honest security disclaimer +
details screen.

**Build order:** model + capability probe → password client + persistence → UI toggle/gating
→ ws-ticket handshake → re-auth modal → disclaimer → snapshots/verify. Token-mode stays
byte-identical throughout.

## Technical Details

- **`AuthSession`** (`Equatable, Sendable, Codable`): `.token(String)` |
  `.cookie(CookieSession)` where `CookieSession = { cookies: [SerializedCookie], username:
  String, provider: String }`. `SerializedCookie` carries name/value/domain/path/expiry so it
  rehydrates into `HTTPCookieStorage`.
- **`ServerConnection`**: `token: String?` → `auth: AuthSession`.
- **`ServerStatus`**: add `authRequired: Bool?` (`auth_required`), `authProviders: [String]?`
  (`auth_providers`).
- **`ServerAuthCapability`** (pure, from status + providers): `.tokenOnly` |
  `.passwordAvailable(provider: String, displayName: String)` |
  `.oauthOnly(providers: [...])` (hidden → #19). Mixed → password preferred.
- **Identity compare** (pure): normalized-username equality decides same-user vs user-switch.

## What Goes Where

- **Implementation Steps** (`[ ]`): all code, tests, copy, snapshots in this repo.
- **Post-Completion** (no checkboxes): on-device manual verification against real token-only
  and gated servers; copy/legal review of the disclaimer wording.

---

## Implementation Steps

### Task 1: `AuthSession` model + `ServerConnection`/`ServerStatus` changes

**Files:**
- Create: `HermesKit/Sources/HermesKit/Models/AuthSession.swift`
- Modify: `HermesKit/Sources/HermesKit/Clients/HermesRESTClient.swift` (ServerConnection, ServerStatus)
- Create: `HermesKit/Tests/HermesKitTests/AuthSessionTests.swift`

- [ ] add `AuthSession` enum (`.token` | `.cookie(CookieSession)`) + `CookieSession`/`SerializedCookie` (Codable)
- [ ] change `ServerConnection.token: String?` → `auth: AuthSession`; keep a convenience for the unauth probe
- [ ] add `authRequired`/`authProviders` to `ServerStatus` (coding keys `auth_required`/`auth_providers`)
- [ ] update all current construction sites to `.token(...)` so token mode compiles unchanged
- [ ] write tests: `AuthSession`/`CookieSession` Codable round-trip; `ServerStatus` decodes new fields (present + absent)
- [ ] run tests — must pass before next task

### Task 2: Capability probe + `ServerAuthCapability` mapper

**Files:**
- Create: `HermesKit/Sources/HermesKit/Models/ServerAuthCapability.swift`
- Modify: `HermesKit/Sources/HermesKit/Clients/HermesRESTClient.swift` (add `authProviders(url)` endpoint)
- Create: `HermesKit/Tests/HermesKitTests/ServerAuthCapabilityTests.swift`

- [ ] add `AuthProvider` model `{name, displayName, supportsPassword}` + `rest.authProviders(url)` (`GET /api/auth/providers`)
- [ ] implement pure `ServerAuthCapability(from status:providers:)` → tokenOnly / passwordAvailable(provider,display) / oauthOnly
- [ ] handle providers 404 / older servers gracefully (treat as token-only)
- [ ] write table-driven tests for the mapper (auth_required false; gated+basic; gated+oauth-only; mixed → password)
- [ ] write a client test for `authProviders` decoding (injected URLSession)
- [ ] run tests — must pass before next task

### Task 3: `passwordLogin` client + cookie capture + persistence round-trip

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Clients/HermesRESTClient.swift` (passwordLogin + dedicated cookie URLSession)
- Modify: `HermesKit/Sources/HermesKit/Clients/KeychainClient.swift` (store/load `AuthSession`)
- Create: `HermesKit/Tests/HermesKitTests/PasswordLoginClientTests.swift`
- Modify: `HermesKit/Tests/HermesKitTests/KeychainClientTests.swift`

- [ ] add `rest.passwordLogin(url, provider, username, password)` → `POST /auth/password-login`, using a dedicated `URLSession` with its own `HTTPCookieStorage`; return the captured `CookieSession`
- [ ] map errors → `RESTError` so the UI can show copy: 401 invalid creds, 429 rate-limited, 503 unreachable, 404 unsupported
- [ ] extend `KeychainClient` to persist/load the full `AuthSession` (cookie payload + username), replacing bare-token storage; rehydrate cookies into the client's storage on load
- [ ] write client tests (injected URLSession): 200 + Set-Cookie captured into the jar; each error code maps correctly
- [ ] write Keychain tests: `.cookie` session serialize → store → load → cookies rehydrated; token session still works
- [ ] run tests — must pass before next task

### Task 4: Auth screen — segmented toggle, password fields, capability gating

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/ConnectionFeature.swift`
- Modify: `HermesMobile/Sources/Features/*` (ConnectionView/auth screen)
- Modify: `HermesKit/Tests/HermesKitTests/ConnectionFeatureTests.swift`

- [ ] add `method: AuthMethod (.password/.token)` + `username`/`password` to state; fold the capability into `serverStatusResponse` (probe providers when gated)
- [ ] capability-aware toggle: both segments by default; token-only → preselect+disable Password (hint); gated → de-emphasize Token
- [ ] `connectTapped` branches: password → `rest.passwordLogin` → validate (`sessions?limit=1`) → persist `.cookie` AuthSession → `delegate(.connected)`; token → today's path unchanged
- [ ] surface error copy from Task 3's `RESTError` mapping in `State.Status`
- [ ] write reducer tests: capability drives enable/preselect; password success → connected with `.cookie`; each error → status copy; token path regression (unchanged)
- [ ] run `tuist generate` (new view files) and the suite — must pass before next task

### Task 5: Gateway `ws-ticket` handshake + auth-failure vs transient

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Clients/HermesGatewayClient.swift`
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift` (reconnect: distinguish sessionExpired)
- Modify: `HermesKit/Tests/HermesKitTests/HermesGatewayClientTests.swift`
- Modify: `HermesKit/Tests/HermesKitTests/ChatReductionTests.swift` (or reconnect tests)

- [ ] `connect` branches on `AuthSession`: `.token` → `?token=` (byte-identical); `.cookie` → `POST /api/auth/ws-ticket` then `?ticket=`, minted fresh per connect (never cached)
- [ ] classify ws-ticket `401` (session fully dead) as a non-retryable auth failure → `delegate(.sessionExpired)`; transient failures → existing backoff
- [ ] ensure reconnect/backoff stays in the reducer and just re-calls `connect` (re-mints ticket)
- [ ] write client tests: token-mode WS URL byte-identical (regression); cookie-mode mints ticket then connects `?ticket=`
- [ ] write reducer tests (TestClock): ws-ticket 401 → sessionExpired (no backoff); transient → backoff continues
- [ ] run tests — must pass before next task

### Task 6: `ReauthFeature` modal + AppFeature routing

**Files:**
- Create: `HermesKit/Sources/HermesKit/Features/ReauthFeature.swift`
- Modify: `HermesKit/Sources/HermesKit/Features/AppFeature.swift` (present sheet, route sessionExpired, user-switch)
- Modify: `HermesKit/Sources/HermesKit/Clients/PreferencesClient.swift` (clear identity-scoped prefs helper, if absent)
- Create: `HermesMobile/Sources/Features/ReauthView.swift`
- Create: `HermesKit/Tests/HermesKitTests/ReauthFeatureTests.swift`
- Modify: `HermesKit/Tests/HermesKitTests/AppFeatureTests.swift`

- [ ] `ReauthFeature`: fixed server URL, prefilled username, password (or token) field, Sign in + "Quit to start"; reuse the Task 3 login effect
- [ ] AppFeature presents it on `delegate(.sessionExpired)` and **pauses** reconnect while shown
- [ ] outcome routing via identity-compare: same user → dismiss + reconnect (stay put); different user → pop to session list + force reload + clear identity-scoped prefs
- [ ] Quit → full logout (clear Keychain session + all prefs) → onboarding
- [ ] token-mode parity: same modal with a token field (identity-compare skipped)
- [ ] write tests: sessionExpired presents + pauses reconnect; same-user dismiss+reconnect; different-user pop+reload+clear; Quit → logout→onboarding; pure identity-compare helper
- [ ] run tests — must pass before next task

### Task 7: Token-mode disclaimer + "How to connect securely" screen

**Files:**
- Modify: `HermesMobile/Sources/Features/*` (auth screen — inline disclaimer on Token segment)
- Create: `HermesMobile/Sources/Features/SecureConnectionInfoView.swift`
- Modify: `HermesKit/Sources/HermesKit/Features/ConnectionFeature.swift` (only if a nav/route flag is needed)

- [ ] add the always-visible inline disclaimer under the token field (never expires / private network only / full access / "Learn how to connect securely →")
- [ ] build the pushed details screen: WHY, HOW (Model-A snippet `--host 0.0.0.0 --insecure` + `HERMES_DASHBOARD_SESSION_TOKEN`, trust boundary = tailnet), real Tailscale link (`https://tailscale.com`, open in Safari), nudge back to Password when supported
- [ ] capability tie-in: gated → token segment disabled hint ("This server uses password login"); token-only → disclaimer primary
- [ ] SCOPE GUARD: static copy + one external link only (no Tailscale SDK / network detection)
- [ ] write any reducer test for the disclaimer/route flag if logic was added (else covered by snapshots in Task 8)
- [ ] run `tuist generate` + suite — must pass before next task

### Task 8: Snapshot tests

**Files:**
- Modify: `HermesMobileTests/*` (snapshot host + baselines)

- [ ] auth screen — Password segment and Token segment
- [ ] token disclaimer + the "How to connect securely" details screen
- [ ] capability-disabled segment state (gated → token disabled; token-only → password disabled)
- [ ] re-auth sheet — password variant and token variant
- [ ] record baselines with `make snapshot-record` (pinned timestamps); run `make snapshot` — must pass before next task

### Task 9: Verify acceptance criteria

- [ ] token-only server: behavior byte-identical to today (header + `?token=`), disclaimer shown
- [ ] gated server: password login → cookies persisted → REST + ws-ticket work end-to-end; survives app restart
- [ ] expired session mid-chat: re-auth modal appears, same-user returns to the exact chat, different-user pops to list + reload, Quit → onboarding
- [ ] capability gating hides/disables the unsupported segment correctly
- [ ] run full HermesKit suite: `make test`
- [ ] run snapshots: `make snapshot`

### Task 10: [Final] Update documentation

**Files:**
- Modify: `docs/architecture.md`, `CLAUDE.md`, `README.md` (if user-facing)

- [ ] document the two auth regimes + `AuthSession`/ws-ticket in `docs/architecture.md` (update the wire-protocol section)
- [ ] note new conventions in `CLAUDE.md` (capability-aware toggle; cookie session in Keychain; ws-ticket per connect; sessionExpired→re-auth routing; token-mode byte-identical)
- [ ] cross-reference backlog #19 (OAuth) and #18 (state-sync foreground reconnect shares `connect`)
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion

*Items requiring a real server/device — informational only.*

**Manual verification:**
- Real **token-only** server (loopback/`--insecure`): confirm unchanged login + the disclaimer/details screen + Tailscale link.
- Real **gated** server with BasicAuth: password login, then exercise REST + WS over time so the ~12h access token refreshes transparently (confirm the refreshed `Set-Cookie` is captured and persists); kill/relaunch to confirm the cookie session survives.
- Force expiry (revoke/rotate the server session) mid-chat to exercise the re-auth modal: same-user resume, different-user switch, Quit → onboarding.
- Rate-limit (`429`) and provider-down (`503`) copy paths against a real server.

**Review:**
- Copy/legal review of the disclaimer wording (security claims, Tailscale mention).

**External:**
- None — no backend changes. OAuth sign-in tracked separately in **#19**; foreground-reconnect interplay tracked in **#18**.
