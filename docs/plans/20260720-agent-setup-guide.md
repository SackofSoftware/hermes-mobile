# Agent Setup Guide (login-screen onboarding for the public beta)

## Overview

Public-beta TestFlight users typically have a Hermes Agent running locally but have
never exposed it for remote access — the login screen assumes they already know how.
Add a native, discoverable **"Set Up Your Agent" guide sheet** on the connection
screen teaching the blessed path per current Hermes guidance: **password ("basic")
auth over Tailscale/LAN**, with `--insecure` + token demoted to a last-resort
advanced section. This *replaces* the existing `SecureConnectionInfoView`, whose
token-first instructions now point users the wrong way, and reconciles the README
quick-start to the same recipe.

Key facts baked into the copy (verified against the Hermes Agent source/docs):

- There is **no `auth_required` knob** — the auth gate engages automatically on a
  non-loopback bind without `--insecure`; a gated dashboard with no provider
  configured refuses to start (fail-closed).
- Credentials are env vars in `~/.hermes/.env`:
  `HERMES_DASHBOARD_BASIC_AUTH_USERNAME`, `..._PASSWORD` (plaintext variant for
  onboarding simplicity; hash variant stays in web docs), and `..._SECRET`
  (random 32 bytes — without it sessions die on every agent restart).
- Launch command: `hermes dashboard --host 0.0.0.0 --port 9119 --no-open`.
- The basic provider is for **trusted networks / VPN only** — Tailscale remains part
  of the recommended recipe, not an optional hardening step. Never port-forward the
  dashboard to the open internet.
- **No minimum-version requirement** in the copy — basic auth works on 0.16.0
  (user-verified); an older agent surfaces naturally at the verify step.
- Full docs link: <https://hermes-agent.nousresearch.com/docs/user-guide/features/web-dashboard>

## Context (from discovery)

- `HermesMobile/Sources/Features/ConnectionView.swift` — login form. Two sections
  (Server / Sign in); `statusFooter` (lines ~107-138) switches on
  `ConnectionFeature.State.status`; `tokenDisclaimer` (lines ~70-89) holds the
  `NavigationLink` to `SecureConnectionInfoView`. No toolbar of its own (nav title
  set in `AppView`).
- `HermesMobile/Sources/Features/SecureConnectionInfoView.swift` — **to be
  deleted**; its building blocks (`card`, `calloutCard`, `cardHeader`, `stepRow`,
  `CommandCard` with copy affordance) are the visual language the new guide reuses.
- `HermesMobile/Sources/Features/Settings/PushSetupGuideView.swift` — sheet
  precedent: `NavigationStack` + inline title + Close toolbar button.
- `HermesKit/.../ConnectionFeature.swift` — `Status` enum (read-only reference;
  `.unreachable` / `.notHermes` gate the contextual help link). **No reducer
  changes** — sheet presentation is display-only local `@State` (matches the
  context-pill precedent of keeping presentation state out of reducers).
- Snapshot tests: `HermesMobileTests/ConnectionSnapshotTests.swift`
  (idle / reachable / invalidToken variants),
  `HermesMobileTests/AuthSnapshotTests.swift:96-110`
  (two `SecureConnectionInfoView` tests — to be replaced),
  `SettingsSnapshotTests.swift:81-88` (PushSetupGuideView pattern).
- `README.md` Quick start (lines ~71-98) — step 1 still teaches
  `hermes ... --host 0.0.0.0 --insecure` + session token.

## Development Approach

- **Testing approach**: Regular (code first, then tests). No reducer changes → no
  new HermesKit tests; the required coverage is the snapshot suite (this is exactly
  what it exists for — view regressions reducer tests can't catch).
- Complete each task fully before moving to the next; small focused changes.
- **CRITICAL: every task MUST include new/updated tests** for code changes in that
  task (here: snapshot tests — added for new views/variants, removed with deleted
  views, re-recorded where UI intentionally changed).
- **CRITICAL: all tests must pass before starting the next task** — no exceptions.
- **CRITICAL: update this plan file when scope changes during implementation.**
- New/removed app-target source files need `tuist generate` before `xcodebuild`
  picks them up (sources are globbed at generation time).
- Commit at each task completion (per project workflow), message style: capitalized
  verb, no conventional-commit prefixes.

## Testing Strategy

- **HermesKit unit tests**: none needed (no reducer/model changes); run
  `make test` in the final verification anyway to prove nothing regressed.
- **Snapshot tests** (`make snapshot` / `make snapshot-record`): new tests for the
  guide sheet and the failure-footer variant; delete the two
  `SecureConnectionInfoView` tests; re-record `ConnectionView` variants (new
  top help row changes every existing snapshot of that screen). Row content is
  static — no timestamp pinning concerns.
- No e2e suite in this project.

## Progress Tracking

- Mark completed items with `[x]` immediately when done.
- Add newly discovered tasks with ➕ prefix.
- Document issues/blockers with ⚠️ prefix.
- Keep plan in sync with actual work done.

## Solution Overview

One new static SwiftUI view, three entry points toggling one local `@State` flag,
one deletion, one README rewrite. No HermesKit changes.

**`AgentSetupGuideView`** — presented as a `.sheet` from `ConnectionView`
(a reference card you consult and dismiss, not a navigation destination; identical
behavior from all three entry points). `NavigationStack` + inline title
"Set Up Your Agent" + Close toolbar button (PushSetupGuideView pattern), body is a
`ScrollView` card stack on `Color(.systemGroupedBackground)` reusing the
`SecureConnectionInfoView` building blocks (which move into this file — the old
file is deleted, so this is a move, not duplication).

Content (in order):

1. **Hero/intro** — "Hermes Mobile connects to a Hermes Agent running on your
   computer. Three things to set up: your login, the dashboard, and network
   access." (No version requirement.)
2. **Create your login** — numbered step + copyable card for `~/.hermes/.env`:
   `HERMES_DASHBOARD_BASIC_AUTH_USERNAME=you`,
   `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=…`,
   `HERMES_DASHBOARD_BASIC_AUTH_SECRET=$(openssl rand -base64 32)`;
   footnote: the secret keeps you signed in across agent restarts.
3. **Start the dashboard** — copyable card
   `hermes dashboard --host 0.0.0.0 --port 9119 --no-open`; note that password
   login switches on automatically when the dashboard is reachable beyond the
   machine itself.
4. **Reach it from your phone** — Tailscale callout card (recommended; external
   link to <https://tailscale.com>, reuse the existing branded link row);
   "on the same Wi-Fi, your Mac's local IP works for a quick try"; warning
   callout (orange): never port-forward the dashboard to the open internet.
5. **Check it works** — copyable card `curl http://<host>:9119/api/status`,
   "you should see `auth_required: true`"; then: enter the URL and your username
   and password back on the sign-in screen.
6. **Advanced: token mode** — collapsed `DisclosureGroup` absorbing the old
   `SecureConnectionInfoView` copy (never-expiring master-key warning, trust
   boundary, `hermes dashboard --host 0.0.0.0 --insecure` +
   `export HERMES_DASHBOARD_SESSION_TOKEN=…` command cards), reframed as a
   last-resort for fully trusted networks. Fixes the old `hermes serve` wording.
7. **Footer link** — "Full setup guide" →
   `https://hermes-agent.nousresearch.com/docs/user-guide/features/web-dashboard`.

**Entry points** (all set the same `@State private var showsSetupGuide` in
`ConnectionView`; **no toolbar button** — deliberate, decided in brainstorm):

- (a) A labeled full-width `Button` row — `Label("How to prepare your Hermes
  agent", systemImage: "info.circle")` — as its own `Section` at the **top** of the
  form, above Server. Unmissable for first-timers; this screen's beta job is half
  "log in", half "teach setup".
- (b) A contextual "Need help setting up your agent?" link-styled `Button`
  appended inside `statusFooter` **only** for `.unreachable` and `.notHermes`
  (the stuck moment). Not shown for auth failures — those users are past setup.
- (c) The token-disclaimer's "Learn how to connect securely" `NavigationLink`
  becomes a `Button` opening the same sheet. No scroll-to-anchor (YAGNI — the
  guide is short).

## Technical Details

- Sheet presentation is pure view state; nothing observable by
  `ConnectionFeature` changes, so `TestStore` coverage is unaffected.
- `AgentSetupGuideView` takes no parameters (the old `passwordAvailable` nudge is
  obsolete — the whole guide is password-first).
- Snapshotting the sheet: render `AgentSetupGuideView()` directly (as
  `SettingsSnapshotTests` does for `PushSetupGuideView`); one variant with the
  advanced `DisclosureGroup` expanded if a simple `@State`-seeded init flag makes
  that reachable — otherwise snapshot collapsed only (don't add API just for the
  snapshot).
- Failure-footer variant: `ConnectionSnapshotTests` already constructs
  `ConnectionFeature.State` with a preset status (see `invalidToken` test); add an
  `.unreachable` variant showing the help link.

## What Goes Where

- **Implementation Steps** (`[ ]` checkboxes): code, snapshot tests, README.
- **Post-Completion** (no checkboxes): manual device pass, TestFlight build.

## Implementation Steps

### Task 1: Create `AgentSetupGuideView`

**Files:**
- Create: `HermesMobile/Sources/Features/AgentSetupGuideView.swift`
- Modify: `HermesMobileTests/AuthSnapshotTests.swift`

- [ ] Create `AgentSetupGuideView.swift`: `NavigationStack` + `ScrollView` card
      stack, inline title "Set Up Your Agent", Close toolbar button; move the
      building blocks (`card`, `calloutCard`, `cardHeader`, `stepRow`,
      `CommandCard`) over from `SecureConnectionInfoView` (file-private in the new
      file; the old file is deleted in Task 2)
- [ ] Implement content sections 1–5 (hero, login env-vars card, dashboard
      command card, Tailscale/LAN/no-port-forward cards, verify-with-curl card)
      exactly per Solution Overview copy
- [ ] Implement section 6 (collapsed `DisclosureGroup` "Advanced: token mode"
      with the reframed last-resort copy + two command cards) and section 7
      (external "Full setup guide" `Link`)
- [ ] Add `#Preview`; run `tuist generate` so the app target picks up the file;
      build the app target to confirm it compiles
- [ ] Write snapshot test(s) for `AgentSetupGuideView` in
      `AuthSnapshotTests.swift` (collapsed; expanded variant only if reachable
      without adding API); record via `make snapshot-record`
- [ ] Run `make snapshot` — must pass before Task 2

### Task 2: Wire entry points in `ConnectionView`, delete `SecureConnectionInfoView`

**Files:**
- Modify: `HermesMobile/Sources/Features/ConnectionView.swift`
- Delete: `HermesMobile/Sources/Features/SecureConnectionInfoView.swift`
- Modify: `HermesMobileTests/AuthSnapshotTests.swift`
- Modify: `HermesMobileTests/ConnectionSnapshotTests.swift`

- [ ] Add `@State private var showsSetupGuide = false` +
      `.sheet(isPresented:)` presenting `AgentSetupGuideView()` to `ConnectionView`
- [ ] Add entry point (a): top form `Section` with the full-width
      `Label("How to prepare your Hermes agent", systemImage: "info.circle")`
      button row, above the Server section
- [ ] Add entry point (b): help `Button` ("Need help setting up your agent?")
      appended in `statusFooter` for `.unreachable` and `.notHermes` only
- [ ] Convert entry point (c): token-disclaimer `NavigationLink` →
      `Button("Learn how to connect securely")` toggling the same sheet; delete
      `SecureConnectionInfoView.swift`; run `tuist generate`; build
- [ ] Update tests: delete the two `testSecureConnectionInfo_*` snapshot tests
      (+ their `__Snapshots__` PNGs); add an `.unreachable` failure-footer
      variant to `ConnectionSnapshotTests`; re-record changed `ConnectionView`
      snapshots (`make snapshot-record`)
- [ ] Run `make snapshot` and `make test` — must pass before Task 3

### Task 3: Reconcile README quick-start to password-first

**Files:**
- Modify: `README.md`

- [ ] Rewrite Quick start step 1 to the password-first recipe: env vars in
      `~/.hermes/.env` (`USERNAME` / `PASSWORD` / `SECRET`), then
      `hermes dashboard --host 0.0.0.0 --port 9119 --no-open`, noting the auth
      gate engages automatically on a non-loopback bind
- [ ] Rewrite step 3 (Connect) to lead with **Password**; demote
      `--insecure` + `HERMES_DASHBOARD_SESSION_TOKEN` to a clearly-labeled
      last-resort aside for fully trusted networks (fixing the old
      `hermes ...` wording); keep the Tailscale trust-boundary warning
- [ ] Add the full web-dashboard docs link
      (`https://hermes-agent.nousresearch.com/docs/user-guide/features/web-dashboard`)
- [ ] Proofread that README and in-app guide copy agree on commands verbatim
      (docs change only — no code/tests; suite already green from Task 2)

### Task 4: Verify acceptance criteria

- [ ] Verify all Overview requirements: guide sheet with all 7 sections; three
      entry points (top row, failure footer, token link) all opening it; no
      toolbar button; `SecureConnectionInfoView` gone; README password-first
- [ ] Verify edge cases: footer link absent for `.idle` / auth-failure statuses;
      copy buttons copy the exact commands; external links resolve
- [ ] Run full suites: `make test` (HermesKit) and `make snapshot` — all green
- [ ] Build the app (`make run` or equivalent) to confirm the generated project
      compiles clean after the file add/delete

### Task 5: [Final] Update documentation

- [ ] Update `CLAUDE.md` conventions if warranted (e.g. note the setup-guide
      sheet as the single connection-help surface, replacing
      `SecureConnectionInfoView`)
- [ ] Move this plan to `docs/plans/completed/`

## Post-Completion

**Manual verification:**
- On-device pass: open guide from all three entry points, copy each command,
  follow the recipe against a real agent (password login end-to-end), confirm
  the failure-footer link appears with Wi-Fi off / bad URL.
- Dynamic Type / dark mode eyeball of the guide sheet on device.

**External:**
- TestFlight build + "What to Test" notes referencing the new setup guide for
  beta testers.
- Hermes web docs remain the canonical deep-dive; if upstream commands change,
  the in-app copy needs an app release to follow (accepted trade-off).
