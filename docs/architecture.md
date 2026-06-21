# Architecture

Hermes Mobile is a **remote-control surface only** — no agent logic runs on the
phone. It talks to a self-hosted
[Hermes Agent](https://github.com/NousResearch/hermes-agent) over REST (session lists
and history)
and a WebSocket JSON-RPC gateway (the live turn: streaming, tool/status events,
approval/clarify requests).

## Repository layout

- **`HermesMobile/`** — the app target: a thin SwiftUI shell (views only). The
  project is defined by Tuist; the `.xcodeproj`/`.xcworkspace` are generated and
  gitignored.
- **`HermesKit/`** — a local Swift package holding the engine: models, dependency
  clients, and TCA reducers. This is where the logic lives. Built and tested
  independently with `swift test` (no simulator needed), which keeps the
  reducer/event-reduction test loop fast.
- **`HermesMobileTests/`** — an iOS XCTest target for SwiftUI snapshot tests
  (separate from the SPM suite).
- **`Probe/`** — a throwaway Swift script that verifies the Hermes wire protocol
  against a real server. See [`../Probe/README.md`](../Probe/README.md).

## Feature tree (TCA reducers, in `HermesKit`)

```
AppFeature                 // root nav + launch auto-connect; onboarding until connected;
│                          //   presents ReauthFeature on .sessionExpired (identity-aware routing)
├─ ConnectionFeature       // auto-validating URL + capability-aware auth toggle (Password | Token)
├─ ReauthFeature           // re-auth modal: fixed URL, prefilled identity, password/token field;
│                          //   same-user resume vs different-user switch vs Quit→onboarding
├─ SessionListFeature      // flat list, grouped by workspace OR chronological (persisted) /
│  │                       //   search / create; pin (client-side) + archive/rename (server) +
│  │                       //   working-glow auto-poll; profile pill/switcher (per-call scoped) +
│  │                       //   presents Settings + Archived + AddProfile sheets
│  ├─ SettingsFeature      // token mgmt, manual reconnect, debug log
│  ├─ ArchivedSessionsFeature // archived list (?archived=only); restore + open delegate
│  └─ AddProfileFeature    // create-then-PUT-soul; inline name validation + server-400 banner
└─ ChatFeature             // owns the WS lifecycle + streaming reduction; also folds in
                           //   approvals, clarify/sudo/secret, the tool-detail sheet,
                           //   and the model/reasoning picker, reconnect
```

## Dependency clients

All side effects go through `@DependencyClient` structs (each with a `liveValue` and
a `testValue`/`.inMemory()` variant):

- **`HermesRESTClient`** — status, sessions, archived sessions (`?archived=only`), search,
  messages, archive/rename (`PATCH /api/sessions/{id}`). Session-scoped reads/mutations take
  an optional `profile` (omitted for default).
- **`HermesProfileClient`** — profile CRUD + SOUL.md (`PUT /api/profiles/{name}/soul`) +
  profile-scoped session lists (`GET /api/profiles/sessions?profile=`). Capability-gated: a
  404 from `GET /api/profiles` hides the selector.
- **`HermesGatewayClient`** — WebSocket JSON-RPC connect/send. The socket is one
  long-running cancellable effect; reconnect/backoff lives in the reducer (testable
  with `TestClock`). Each `send` enforces a per-request timeout (default 30s) so a
  stuck/never-acking RPC throws `GatewayError.timedOut` instead of hanging forever.
  `connect` branches on the `AuthSession`: `.token` → `?token=` (byte-identical to the
  legacy path); `.cookie` → mint a fresh single-use `?ticket=` via `POST /api/auth/ws-ticket`
  per connect (never cached). A `401` from the mint surfaces as `GatewayEvent.authExpired`
  (non-retryable → `.sessionExpired`); other mint failures are `.ticketUnavailable`
  (transient → reducer backoff).
- **`KeychainClient`** — the persisted `AuthSession` (the only secret): either a static
  `.token`, or a `.cookie(CookieSession)` carrying the rotating session cookies + username +
  provider. `saveSession`/`loadSession` round-trip the whole session (cookies rehydrate into
  `HTTPCookieStorage` on launch); the legacy `…Token` helpers remain for token-mode.
- **`PreferencesClient`** — non-secret prefs: server URL (for auto-login), per-session
  seen counts, client-side pinned session ids, the session-list grouping mode
  (`SessionGroupingMode`), and the selected profile name (`hermes.selected-profile-id`). All
  cleared/reset on logout.
- **`PasteboardClient`** — copy.
- **`DebugLogClient`** — an event ring buffer for the in-app debug log.

## Wire protocol

### Auth regimes

The server has **two distinct auth regimes**, modeled by `AuthSession`
(`.token` | `.cookie(CookieSession)`) so downstream clients adapt transport without
scattering regime checks. `/api/status` is public (used to validate a server URL and to
probe capability before login).

- **Token mode** (`.token`) — loopback/`--insecure` servers (`auth_required` absent/false).
  REST authenticates via the `X-Hermes-Session-Token` header; WS via `…/api/ws?token=<token>`.
  The token never expires. **This path is byte-identical to the legacy single-token client**
  (a hard backward-compat requirement) — the `profile`-style omissions and request shapes are
  unchanged so old servers behave exactly as before.
- **Gated mode** (`.cookie`) — public-bind servers with `auth_required=true` and a
  password-capable provider. Login is `POST /auth/password-login` `{provider, username,
  password}`; the server returns rotating session cookies via `Set-Cookie` (`hermes_session_at`
  ~12h, `hermes_session_rt` 30d, HttpOnly). REST then authenticates via the cookie jar; the
  WebSocket rejects `?token=`, so each connect mints a fresh single-use `?ticket=` via
  `POST /api/auth/ws-ticket` (cookie-authed, 30s TTL) — **never cached**. Token refresh is
  **transparent**: the server middleware re-mints the access cookie whenever a valid refresh
  cookie is presented, so there is no client refresh endpoint — we persist + resend the jar and
  capture refreshed `Set-Cookie`.

**Capability probe.** `ServerAuthCapability(from: status, providers:)` is a pure mapper over
`/api/status` (`auth_required`/`auth_providers`) + `GET /api/auth/providers` →
`.tokenOnly` | `.passwordAvailable(provider, displayName)` | `.oauthOnly(providers:)`. It
drives the onboarding screen's capability-aware **Password | Token** segmented toggle. A
providers 404 / unreachable endpoint (older servers) falls back to `.tokenOnly`. **OAuth is
out of scope** (`.oauthOnly` exists only so the UI can honestly disable Password) — tracked in
backlog **#19**.

**Persistence + re-auth.** The `AuthSession` (cookies + username + provider, or the bare
token) is stored in `KeychainClient` and rehydrated on launch. When the gated WS ticket mint
returns `401` the session is fully dead → `ChatFeature` raises `.sessionExpired`; `AppFeature`
pauses reconnect and presents `ReauthFeature`. Outcome routing uses a pure normalized-username
identity compare: **same user** → dismiss + reconnect in place; **different user** → pop to the
session list, force a reload, and clear identity-scoped prefs; **Quit** → full logout →
onboarding. Token mode reuses the same modal with a token field (identity compare skipped).
The gated foreground-reconnect flow shares the same `connect` (which re-mints the ticket) — see
backlog **#18** (session state-sync).

A few protocol facts that shape the reducer (verified against the real Hermes source,
not assumed):

- **Streaming has no message id.** The fold tracks a single in-flight assistant row,
  created lazily on the first delta — a `message.start` with no text would otherwise
  render as an empty bubble. The `session_id` lives on the event *frame*.
- **Decode leniently.** Unknown event `type`s decode to `.unknown` and never crash.
- **Pins are device-local** (Hermes has no pin API) — an ordered `[String]` of session
  ids in `PreferencesClient`. **Archive is server-side**
  (`PATCH /api/sessions/{id}` `{"archived": …}`), done optimistically.
- **Rename is server-side**, optimistic with rollback (mirrors archive): the session
  list uses `PATCH /api/sessions/{id}` `{"title": …}` over REST; the chat screen uses
  the `session.title` gateway method.
- **Profiles are device-local with per-call scoping** — the selected profile *name* lives
  in `PreferencesClient`; we never call `POST /api/profiles/active`. Instead the scoped list
  comes from `GET /api/profiles/sessions?profile=`, and an optional `profile` param threads
  into `session.create`/`session.resume` (gateway) and session-scoped messages/archive/rename
  (REST) — omitted for `"default"` so single-profile agents are byte-identical to today.
  **Search is not profile-scoped** (mirrors the desktop). The desktop's per-profile color is
  intentionally omitted.
