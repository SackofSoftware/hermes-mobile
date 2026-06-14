# Hermes Mobile

A native SwiftUI / [TCA](https://github.com/pointfreeco/swift-composable-architecture)
iOS companion app for a self-hosted [Hermes Agent](https://github.com/) — a thin
remote client to chat with sessions, stream responses, and approve/clarify the
agent's actions from an iPhone while the real runtime stays on your Mac/server.

> **Status: MVP feature-complete.** The full loop is built and tested — connect, list/
> search/resume/create sessions, stream responses, see tool/status activity, and
> approve/clarify the agent's requests. Covered by 101 unit tests (`swift test`) + 13
> SwiftUI snapshot tests, and shipping to TestFlight. Remaining: final on-device
> verification against a live server. Full history:
> [`docs/plans/completed/2026-06-09-hermes-ios-mvp.md`](docs/plans/completed/2026-06-09-hermes-ios-mvp.md).

## Features

- **Connect** — type a server URL (validated automatically as you type / on paste / on
  return) + token; token in the iOS Keychain, server URL persisted so the app
  **auto-logs-in on launch** and skips onboarding when credentials are stored.
- **Sessions** — list **grouped by workspace** (like the desktop app), ordered by
  last-active within each group, with **collapsible groups** ("Show N more" / "Show
  less"); full-text search (flat results), resume an existing session, or start a new
  one. **Pin** sessions into a top "Pinned" section (client-side, shown only when
  non-empty; via swipe or a long-press menu), **archive** them server-side (PATCH, behind
  a confirmation dialog), and watch a subtle **working glow** on active sessions —
  driven by `is_active` and a ~10s auto-poll while the list is on screen.
- **Live chat** — streaming assistant responses as native Markdown (code blocks + lists),
  **tool/skill activity rows** (human title + a detail sheet with args/result/diff), a
  collapsible thinking row, and a Liquid-Glass **scroll-to-bottom** button.
- **Composer** — a **model · reasoning-effort chip** (tap to switch via an interactive
  picker; reasoning is gated per-model; unconfigured providers shown disabled), a voice
  button (placeholder), and a brand-coloured send button.
- **Approvals & clarify** — the mobile-native payoff: respond to `approval.request`,
  `clarify.request`, and `sudo`/`secret` prompts via pinned cards; the composer blocks
  until you answer.
- **Resilience** — automatic reconnect with backoff and a visible connection banner.
- **Settings** — re-paste / clear the token (logout), manual reconnect, and a live debug
  log of decoded gateway events.

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

### Feature tree (TCA reducers, in `HermesKit`)

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

Dependency clients (`@DependencyClient`): `HermesRESTClient` (status/sessions/search/
messages), `HermesGatewayClient` (WebSocket JSON-RPC connect/send), `KeychainClient`
(token), `PreferencesClient` (server URL for auto-login, per-session seen counts, and
client-side pinned session ids — all cleared on logout), `PasteboardClient` (copy),
`DebugLogClient` (event ring buffer). The socket is one long-running cancellable effect;
reconnect/backoff lives in the reducer (testable with `TestClock`).

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

To bake a default server URL into Debug builds (kept out of git), set it at generate
time. Tuist only forwards `TUIST_`-prefixed env vars to the manifest:

```sh
TUIST_SERVER_URL=http://<tailnet-host>:9119 tuist generate     # or: HERMES_DEFAULT_SERVER_URL=… make run
```

Likewise a device build needs the team: `DEVELOPMENT_TEAM=<team id> make run-device`
(the script translates it to `TUIST_DEVELOPMENT_TEAM`).

Build/run the `HermesMobile` scheme from Xcode, or use the scripts below.

## Scripts

Common tasks are wrapped in `scripts/` (and a `Makefile`):

```sh
make setup            # tuist install + generate
make test             # run the HermesKit suite (streamed output)
make run              # build + install + launch on a simulator
make run-device       # build + install + launch on a connected device
make snapshot         # run SwiftUI snapshot tests against baselines
make snapshot-record  # re-record SwiftUI snapshot baselines
```

- **Simulator** (`scripts/run-sim.sh`) needs no signing. Override the device with
  `SIM_NAME="iPhone 16" make run` or `scripts/run-sim.sh "iPhone 16"`.
- **Device** (`scripts/run-device.sh`) needs automatic signing —
  `DEVELOPMENT_TEAM=<your 10-char team id> make run-device`. The team is baked in at
  generate time.
- **Tests** (`scripts/test.sh`) wrap `swift test` in a pseudo-TTY so output streams
  live (a bare pipe buffers until exit).
- **Snapshots** (`scripts/snapshot.sh`) render the SwiftUI views via SnapshotTesting
  (iOS XCTest target `HermesMobileTests`, separate from the SPM suite). Baselines live
  in `HermesMobileTests/__Snapshots__/`. Row timestamps are pinned to a fixed reference
  date so the images are deterministic.

## TestFlight distribution

Distribution runs through the [`asc`](https://github.com/) CLI (the `hermes` profile).
Bump `CURRENT_PROJECT_VERSION` in `Project.swift`, then archive → export with **manual**
signing → upload:

```sh
# 1. archive (Release, generic iOS) with automatic signing
xcodebuild archive -workspace HermesMobile.xcworkspace -scheme HermesMobile \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath build/testflight/HermesMobile.xcarchive \
  -allowProvisioningUpdates -authenticationKeyPath <AuthKey.p8> \
  -authenticationKeyID <KEY_ID> -authenticationKeyIssuerID <ISSUER_ID> \
  CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=<team id>

# 2. export — MUST use manual signing (cloud/API-key signing fails on export)
xcodebuild -exportArchive -archivePath build/testflight/HermesMobile.xcarchive \
  -exportPath build/testflight/export \
  -exportOptionsPlist build/testflight/ExportOptions.plist   # method app-store-connect, signingStyle manual

# 3. upload
asc --profile hermes builds upload --app <app id> --ipa build/testflight/export/HermesMobile.ipa
```

The provisioning profile must be installed locally first
(`asc --profile hermes profiles download --id <profile id>`). `build/` is gitignored.

## Verifying the protocol (M0 probe)

To sanity-check connectivity and event shapes against your server:

```sh
SERVER_URL=http://<tailnet-host>:9119 HERMES_TOKEN=<token> swift Probe/main.swift
```

Expect `✅ streaming loop confirmed`. See [`Probe/README.md`](Probe/README.md) for details.
