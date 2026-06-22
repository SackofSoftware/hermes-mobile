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
  archive/rename (`PATCH /api/sessions/{id}`). Session-scoped reads/mutations take
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
- **`ChatSnapshotClient`** — a **non-authoritative** instant-paint cache + turn-start anchor,
  backed by GRDB (the store uses a private `DatabaseQueue` directly,
  not a shared `defaultDatabase`) and kept entirely behind the client boundary (read
  once, no reactive `@FetchAll`). It persists each session's latest transcript tail, model, reasoning,
  usage, and a per-session turn-start timestamp so a cold open can paint immediately before the
  server responds. The cache can only make the UI appear *faster*, never *differ* from the
  server: on hydrate the server wins, cached rows are replaced wholesale (no merge/dedup), and
  the whole store is wiped on logout. `.inMemory()` test variant.
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
  into `session.create`/`session.resume` (gateway) and session-scoped archive/rename
  (REST) — omitted for `"default"` so single-profile agents are byte-identical to today.
  **Search is not profile-scoped** (mirrors the desktop). The desktop's per-profile color is
  intentionally omitted.

## Session re-hydration (`session.resume`)

In-flight turn state (model, context usage, running status, tool/thinking history, the
elapsed "Thinking" timer) is **server-authoritative** and is reconstructed every time a chat
appears — there is no durable client-side mirror of it. This is what keeps navigating
**chat → list → chat**, backgrounding, or a cold restart from blanking the model, zeroing the
context gauge, dropping tool/thinking rows, or stranding a phantom "working" glow.

**One unified `hydrate(sessionID)` effect** serves open, foreground, and cold launch. Opening a
session with a stored id, foregrounding it (`.foreground`), and a cold-launch socket connect all
funnel through the same `.ready` → `hydrate` path (`ChatFeature`), so there is one code path to
reason about. `hydrate` calls the gateway's **`session.resume`** RPC, which returns
`{messages, session_id, resumed, info, running, inflight}` and serves **both** a stored session
(rebuilt from the DB) and an already-live one (the transport is reattached, in-flight turn
included). We deliberately do **not** use `session.activate` — that is live-only and answers
"session not found" for any stored session opened from the list (every common case). On the
response (`applyActivate`), in order:

1. **Instant paint first.** `ChatFeature.init` reads `ChatSnapshotClient.loadSnapshot`
   synchronously and paints the cached transcript tail + model + usage, so the screen is never
   blank while the socket connects. On an offline `resume` failure the cached paint is kept
   with a subtle "reconnecting" status (never blanked).
2. **`applyRuntimeInfo(info)`** overwrites model / reasoning effort / usage directly from the
   response (partial info only overwrites present fields) — fixing the blank-model and
   context-0 regressions.
3. **`reconstructTranscript(messages)`** rebuilds the transcript wholesale from the
   authoritative history — reasoning rows, assistant text, and tool-call rows (with
   backward-matched `role:"tool"` results), keyed identically to the live fold's `toolRowIDs`.
   The cached tail is replaced, never merged.
4. **Working indicator + inflight seed.** `isSending` is set from the authoritative `running`
   flag; `inflight.user`/`inflight.assistant` rows are appended and, when `inflight.streaming`
   is set, an assistant streaming row is seeded eagerly with `streamingRowID` pointed at it so
   the next `message.delta` reuses it instead of lazily creating a duplicate.
5. **`reconcileTimer(running, anchor, now)`** restarts the elapsed "Thinking" timer from a
   client-persisted turn-start anchor. **`running` decides *whether* the timer runs; the anchor
   only supplies the *start instant*.** A running turn resumes ticking seeded at `now − anchor`;
   a stopped turn with a stale anchor **discards** the anchor (no phantom timer) and leaves a
   static `Thought · <elapsed>` disclosure. The anchor is written on `prompt.submit` /
   `message.start` and cleared on `message.complete` / error / interrupt.
6. **Write-back.** A fresh server-authoritative snapshot is persisted (debounced; flushed
   immediately on `.background`/`.inactive` via `persistNow`) so the next cold open paints from
   it.

App lifecycle (`scenePhase`, observed in the SwiftUI shell and dispatched as
`AppFeature.scenePhaseChanged`) routes `.active` into the open chat's `.foreground` (reconnect +
re-hydrate via `session.resume`) plus a session-list refresh, and `.background`/`.inactive` into an immediate
snapshot/anchor flush. The nav stack is **not** auto-restored on cold launch — opening a session
is enough.

The session-list **working glow** is driven event-driven by `ChatFeature.Delegate.runningChanged`
(emitted on `message.start`/`complete`/`error` and from the `session.resume` `running` flag),
routed by `AppFeature` to `SessionListFeature` so the row's glow clears/lights instantly. The
existing poll stays the backstop for not-open sessions; a cached `running-guess` **never** starts
a glow on its own — only one the server confirms.
