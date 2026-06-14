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
AppFeature                 // root nav + launch auto-connect; onboarding until connected
├─ ConnectionFeature       // auto-validating URL + token
├─ SessionListFeature      // workspace-grouped list (last-active order, collapsible) /
│  │                       //   search / create; pin (client-side) + archive (server) +
│  │                       //   working-glow auto-poll; presents Settings
│  └─ SettingsFeature      // token mgmt, manual reconnect, debug log
└─ ChatFeature             // owns the WS lifecycle + streaming reduction; also folds in
                           //   approvals, clarify/sudo/secret, the tool-detail sheet,
                           //   and the model/reasoning picker, reconnect
```

## Dependency clients

All side effects go through `@DependencyClient` structs (each with a `liveValue` and
a `testValue`/`.inMemory()` variant):

- **`HermesRESTClient`** — status, sessions, search, messages.
- **`HermesGatewayClient`** — WebSocket JSON-RPC connect/send. The socket is one
  long-running cancellable effect; reconnect/backoff lives in the reducer (testable
  with `TestClock`).
- **`KeychainClient`** — the auth token (the only secret).
- **`PreferencesClient`** — non-secret prefs: server URL (for auto-login), per-session
  seen counts, and client-side pinned session ids. All cleared on logout.
- **`PasteboardClient`** — copy.
- **`DebugLogClient`** — an event ring buffer for the in-app debug log.

## Wire protocol

The app authenticates REST via the `X-Hermes-Session-Token` header and the WebSocket
via `…/api/ws?token=<token>`. `/api/status` is public (used to validate a server URL
before login).

A few protocol facts that shape the reducer (verified against the real Hermes source,
not assumed):

- **Streaming has no message id.** The fold tracks a single in-flight assistant row,
  created lazily on the first delta — a `message.start` with no text would otherwise
  render as an empty bubble. The `session_id` lives on the event *frame*.
- **Decode leniently.** Unknown event `type`s decode to `.unknown` and never crash.
- **Pins are device-local** (Hermes has no pin API) — an ordered `[String]` of session
  ids in `PreferencesClient`. **Archive is server-side**
  (`PATCH /api/sessions/{id}` `{"archived": …}`), done optimistically.
