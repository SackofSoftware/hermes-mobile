# Hermes Mobile

A native SwiftUI / [TCA](https://github.com/pointfreeco/swift-composable-architecture)
iOS companion app for a self-hosted [Hermes Agent](https://github.com/) — a thin
remote client to chat with sessions, stream responses, and approve/clarify the
agent's actions from an iPhone while the real runtime stays on your Mac/server.

> **Status: early scaffold.** Project skeleton builds and the wire protocol is
> verified against a live server (see M0 below). The chat/approvals UI is not built
> yet. Full roadmap: [`docs/plans/2026-06-09-hermes-ios-mvp.md`](docs/plans/2026-06-09-hermes-ios-mvp.md).

## Architecture

- **`HermesMobile/`** — the app target (SwiftUI shell, views). Project defined by Tuist.
- **`HermesKit/`** — a local Swift package holding the engine: models, dependency
  clients, and TCA reducers. Built and tested independently with `swift test` (no
  simulator needed), which keeps the reducer/event-reduction test loop fast.
- **`Probe/`** — a throwaway Swift script that verifies the Hermes wire protocol
  against a real server. See [`Probe/README.md`](Probe/README.md).

The app is a remote-control surface only — no agent logic runs on the phone. It
talks to Hermes over REST (lists/history) and a WebSocket JSON-RPC gateway (the live
turn: streaming, tool/status events, approval/clarify requests).

## Requirements

- macOS with **Xcode 26+**
- **Tuist** (`brew install tuist`)
- A running **Hermes Agent** reachable from your Mac (e.g. over Tailscale)

## Connecting to Hermes ("Model A")

The MVP relies on Hermes' existing token auth over a trusted network (your tailnet).
On the Hermes machine, launch the dashboard so a non-loopback client is allowed and
the token survives restarts:

```sh
# bind to all interfaces + disable the OAuth gate (tailnet is the trust boundary)
hermes ... --host 0.0.0.0 --insecure
# and set a stable token in its environment:
export HERMES_DASHBOARD_SESSION_TOKEN=<your-stable-secret>
```

> ⚠️ `--insecure` exposes the dashboard on all interfaces with only token auth — only
> do this when the network boundary is a private VPN (Tailscale), never the open
> internet. Proper remote auth (OAuth-gated mode) is a future, out-of-MVP path.

The app stores the token in the iOS Keychain and authenticates REST via the
`X-Hermes-Session-Token` header and the WebSocket via `…/api/ws?token=<token>`.

## Build & run

Generate the Xcode workspace and open it:

```sh
tuist generate
```

To bake a default server URL into Debug builds (kept out of git), set it at generate time:

```sh
HERMES_DEFAULT_SERVER_URL=http://<tailnet-host>:9119 tuist generate
```

Build/run the `HermesMobile` scheme from Xcode, or:

```sh
xcodebuild build -workspace HermesMobile.xcworkspace -scheme HermesMobile \
  -destination 'generic/platform=iOS Simulator'
```

## Test

Engine tests run fast on the Mac, no simulator:

```sh
swift test --package-path HermesKit
```

## Verifying the protocol (M0 probe)

To sanity-check connectivity and event shapes against your server:

```sh
SERVER_URL=http://<tailnet-host>:9119 HERMES_TOKEN=<token> swift Probe/main.swift
```

Expect `✅ streaming loop confirmed`. See [`Probe/README.md`](Probe/README.md) for details.
