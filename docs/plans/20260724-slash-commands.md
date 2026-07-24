# Slash-Command Support in the Chat Composer

GitHub issue: #36

## Overview

Support the agent's slash commands from the mobile chat composer, mirroring desktop:
typing `/` surfaces a filtering autocomplete panel of available commands (built-ins +
dynamic skill routes), selection inserts the command, and sending executes it through
the gateway's dedicated slash pipeline (`slash.exec` → `command.dispatch` →
`prompt.submit` for skill/send directives) — **not** as plain prompt text. Command
output renders as a new bubble-less transcript row. The whole affordance is
capability-gated: old agents without `commands.catalog` behave byte-identically to
today.

Key benefit: mid-conversation session control from the phone (`/compress`, `/undo`,
`/retry`, `/steer`, `/queue`, `/status`, …) plus invoking installed skills (`/plan`,
…) — none of which have native mobile UI.

## Context (from discovery)

Protocol facts verified in the Hermes source clone
(`/Users/eugene/Documents/Development/Personal/hermes-agent`):

- **Discovery is WS JSON-RPC only** (no REST endpoint): `commands.catalog`
  (`tui_gateway/server.py:13871`) returns
  `{pairs: [[name, desc]], sub: {"/cmd": [subs]}, canon: {alias: canonical}, categories: [{name, pairs}], skill_count, warning}`.
  Dynamic skill routes are appended to `pairs` only (never in `categories`).
- **Execution**: `slash.exec {command, session_id}` → `{output, warning?}`
  (`server.py:15746`); on error fall back to `command.dispatch {name, arg, session_id}`
  → typed directive `{type:'exec'|'plugin', output}` / `{type:'alias', target}` /
  `{type:'skill'|'send', message}` — skill/send messages then go through the normal
  `prompt.submit` (`server.py:14060`). Reference pipeline: `web/src/lib/slashExec.ts`
  (explicitly written for future SwiftUI clients to copy).
- The catalog is TUI-flavored: excludes messaging-only commands but **includes
  terminal-only ones**; no surface flags on the wire. Desktop filters client-side
  (`apps/desktop/src/lib/desktop-slash-commands.ts`) — mobile does the same.
- **Verified: `slash.exec` output is ephemeral** — never written to persisted history;
  `session.resume` never returns it; desktop and web both accept output loss on
  reload.

Mobile codebase anchors:

- `HermesKit/Sources/HermesKit/Features/ChatFeature.swift` — `composerText` (~38),
  `BindingReducer` (~428), `composerSubmitted` handler (~679–768, `prompt.submit`
  ~764), attach capability pattern (`isUnknownMethod` catch ~731–734 →
  `attachmentsUnsupportedDetected` ~1099–1109), `model.options` fetch convention
  (~1120–1136).
- `HermesKit/Sources/HermesKit/Clients/HermesGatewayClient.swift` — `send` (~25),
  `GatewayError.isUnknownMethod` (~53–61).
- `HermesMobile/Sources/Features/Chat/ChatView.swift` — stack: connectionBanner →
  transcript → footer → pendingCard → `Divider()` → `ComposerView` (~18–40).
- `HermesMobile/Sources/Features/Chat/ComposerView.swift` — `attachmentChips` above
  the TextField (~72–81) prove the "strip above composer" slot.

## Development Approach

- **Testing approach**: Regular (code first, then tests, within each task)
- Complete each task fully before moving to the next; small focused changes
- **Commit at each task completion** (per project memory) — capitalized verb, no
  conventional-commit prefixes, concise
- **CRITICAL: every task MUST include new/updated tests** — success and error paths,
  listed as separate checklist items; not optional
- **CRITICAL: all tests must pass before starting the next task**
- **CRITICAL: update this plan file when scope changes during implementation**
- Backward compatibility is a hard guard: agents without `commands.catalog` must see
  byte-identical behavior to today

## Testing Strategy

- **Unit tests (HermesKit, `swift test`)**: pure decode + filter logic, and
  `TestStore` reducer tests for every new action path (highest-value suite per
  project conventions). Use
  `script -q /dev/null swift test --package-path HermesKit` (or `make test`) for
  live output.
- **Snapshot tests (`HermesMobileTests`)**: the suggestion panel and the
  command-output row. `make snapshot` to assert, `make snapshot-record` to record
  new baselines. Row timestamps pinned for determinism.
- No e2e suite in this project.

## Progress Tracking

- Mark completed items `[x]` immediately when done
- Add newly discovered tasks with ➕ prefix
- Document issues/blockers with ⚠️ prefix
- Keep the plan in sync with actual work

## Solution Overview

Locked design decisions (from the 2026-07-24 brainstorm):

1. **Curation — mirror desktop**: show the full catalog minus a static client-side
   `mobileHiddenCommands` hide-list of terminal-only commands. Redundant-with-native-UI
   commands (`/model`, `/stop`, `/new`, `/title`, `/sessions`, `/resume`, `/usage`,
   `/reasoning`) ARE shown for muscle-memory parity.
2. **Filtering — client-side only** over the cached catalog. NO `complete.slash` in
   v1 (server arg-completion is a possible follow-up).
3. **UI — inline suggestion panel** between transcript and composer, ~5 visible rows
   with internal scroll, monospaced name + secondary description, skill rows marked
   with an icon, reduce-motion-respecting transition, tap inserts and keeps the
   keyboard up.
4. **No new dependency client** — catalog fetch is a one-shot
   `gateway.send("commands.catalog", …)` effect in `ChatFeature` (the `model.options`
   convention). Capability gate = the attach pattern verbatim.
5. **No stored suggestion state** — a computed property derives suggestions from
   `composerText` + `commandCatalog` via a pure filter. Nothing to keep in sync.
6. **Ephemerality (desktop parity)** — command rows are local-only and vanish on the
   next wholesale hydrate; NO #26-style preservation for them (skill/send invocations
   persist naturally as real `prompt.submit` messages). NO full hydrate after exec
   (it would wipe the output row) — instead a **runtime-only refresh**
   (`session.resume` → `applyRuntimeInfo` only, transcript untouched).

## Technical Details

### CommandCatalog model (HermesKit)

```swift
public struct SlashCommand: Equatable, Sendable {
    public let name: String        // "/compress" (canonical, leading slash)
    public let description: String
    public let category: String?   // "Session" … nil for skills
    public let isSkill: Bool
}
public struct CommandCatalog: Equatable, Sendable {
    public let commands: [SlashCommand]        // hide-list already applied, category order, skills last
    public let subcommands: [String: [String]] // "/reasoning" → ["none", "low", …]
    public let canonical: [String: String]     // "/reset" → "/new"
}
```

- Decoded leniently from the `commands.catalog` JSON — unknown/missing fields never
  throw (same rule as events).
- `categories` gives categorized built-ins; entries in `pairs` appearing in **no**
  category are the appended skill routes → `isSkill = true`.
- `mobileHiddenCommands: Set<String>` (static, unit-tested) applied at decode:
  `/clear /redraw /history /prompt /snapshot /config /statusbar /timestamps /skin
  /indicator /busy /copy /paste /image /quit /handoff /tools /toolsets /pet /hatch
  /reload /reload-mcp /reload-skills /browser /plugins /billing /platforms /journey`.

### SlashSuggestionFilter (pure)

`SlashSuggestionFilter.suggestions(for: composerText, catalog:) -> [SlashSuggestion]`:

- Text must **begin with `/`** and contain no newline — else `[]` (mid-sentence
  slashes never trigger).
- Bare `/` → full filtered catalog in category order, skills last.
- First token, no space yet (`/qu`) → case-insensitive **prefix** match on canonical
  names AND aliases (via `canonical`; matched aliases display their canonical row).
  Prefix-only, no fuzzy.
- Known command + space + partial (`/reasoning l`) → subcommand suggestions from the
  `sub` map. Any other post-space text → `[]` (args are freeform).

### ChatFeature changes

- State: `commandCatalog: CommandCatalog?`, `commandsUnsupported: Bool`, computed
  `slashSuggestions`.
- Catalog fetch: one-shot effect after hydrate reaches ready;
  `isUnknownMethod` → `commandsUnsupported = true` (attach pattern); transient
  failure → catalog stays `nil`, silent, retried on next hydrate.
- `.slashSuggestionTapped` → sets `composerText = "/name "` (trailing space) or
  `"/cmd sub"`; suggestions update/clear automatically via the computed property.
- `composerSubmitted` command branch — only when trimmed text starts with `/` AND
  catalog is loaded AND no staged attachments (attachments always take the plain
  prompt path): append the typed command as a normal **user row**, clear composer,
  set `isSending`. Effect chain:
  1. `slash.exec {command (no leading slash), session_id}` → `{output, warning?}` →
     append a `commandOutput` row, clear `isSending`, then **runtime-only refresh**.
  2. `slash.exec` error → `command.dispatch {name, arg, session_id}`:
     `exec`/`plugin` → output row (as above); `alias` → re-enter the pipeline once
     with the target (**single hop**, no loop); `skill`/`send` → hand `message` to
     the existing `prompt.submit` flow **suppressing the duplicate optimistic user
     row** (the `/cmd` row is already in the transcript) — streaming/thinking takes
     over and `isSending` follows the normal turn lifecycle.
  3. Both fail → `errorBanner` + clear `isSending` (never a swallowed `try?`). The
     session-not-found self-heal wraps these RPCs like any other outbound call.
- Runtime-only refresh: `session.resume(sessionID)` applying `applyRuntimeInfo`
  (model/reasoning/usage/title) **without** `reconstructTranscript`/inflight seeding;
  failure is silent (cosmetic refresh only).

### commandOutput row

New `ChatRow.Kind.commandOutput(String)`: bubble-less, dimmed system styling,
monospaced, selectable. Own stable kind-discriminator token feeding the FNV-1a
deterministic row ID (never random, never derived from mutable text).

## What Goes Where

- **Implementation Steps** (checkboxes): all code, tests, and doc updates in this
  repo.
- **Post-Completion** (no checkboxes): manual on-device verification against a live
  agent; nothing in external repos (no agent/plugin/gateway changes).

## Implementation Steps

### Task 1: CommandCatalog model with lenient decode and mobile hide-list

**Files:**
- Create: `HermesKit/Sources/HermesKit/Models/CommandCatalog.swift`
- Create: `HermesKit/Tests/HermesKitTests/CommandCatalogTests.swift`

- [x] add `SlashCommand` + `CommandCatalog` structs (public, `Equatable`, `Sendable`)
- [x] implement lenient decode from the `commands.catalog` JSON response
      (`pairs`/`sub`/`canon`/`categories`): categorized pairs keep their category,
      uncategorized pairs → `isSkill = true` appended last; malformed/missing fields
      degrade, never throw
- [x] add static `mobileHiddenCommands: Set<String>` (list in Technical Details) and
      apply it at decode (also drop hidden names from `subcommands`/`canonical`)
- [x] write tests: full fixture decode (categories, skills marked, hide-list
      applied, aliases mapped, subcommands mapped)
- [x] write tests: malformed/empty/partial payloads decode leniently without throwing
- [x] run `swift test --package-path HermesKit` — must pass before task 2

### Task 2: SlashSuggestionFilter pure filtering logic

**Files:**
- Create: `HermesKit/Sources/HermesKit/Models/SlashSuggestionFilter.swift`
- Create: `HermesKit/Tests/HermesKitTests/SlashSuggestionFilterTests.swift`

- [x] add `SlashSuggestion` (id/name/description/isSkill or subcommand variant —
      whatever the panel needs, `Equatable`) and
      `SlashSuggestionFilter.suggestions(for:catalog:)` implementing the rules in
      Technical Details (leading-`/` + no-newline guard, bare `/` full list, prefix
      match on names + aliases, subcommand mode after `/cmd `, `[]` otherwise)
- [x] write tests: bare `/` → full list in category order with skills last; `/qu`
      prefix filtering; alias lookup (`/fork` → `/branch` row); case-insensitivity
- [x] write tests: subcommand mode (`/reasoning l` → `low`); freeform args → `[]`;
      mid-sentence `/` and multiline text → `[]`; nil catalog → `[]`
- [x] run `swift test --package-path HermesKit` — must pass before task 3

### Task 3: Catalog fetch and capability gate in ChatFeature

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/ChatFeatureTests.swift`

- [ ] add `commandCatalog: CommandCatalog?` + `commandsUnsupported: Bool` to State
      and actions `.commandCatalogLoaded(CommandCatalog)` /
      `.commandsUnsupportedDetected`
- [ ] fire a one-shot `gateway.send("commands.catalog", …)` effect once hydrate
      reaches ready (mirror the `model.options` convention; `[gateway]` capture per
      `@Sendable` gotcha); decode via Task 1
- [ ] on `GatewayError.isUnknownMethod` → `.commandsUnsupportedDetected` (attach
      pattern verbatim); any other failure → silent no-op (catalog stays `nil`,
      naturally retried on next hydrate); skip the fetch when `commandsUnsupported`
- [ ] write TestStore tests: successful fetch populates the catalog; unknown-method
      flips `commandsUnsupported` and suppresses future fetches
- [ ] write TestStore tests: transient failure leaves catalog `nil` and a later
      hydrate refetches
- [ ] run `swift test --package-path HermesKit` — must pass before task 4

### Task 4: Computed suggestions and selection action

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/ChatFeatureTests.swift`

- [ ] add computed `State.slashSuggestions` delegating to `SlashSuggestionFilter`
      (empty when catalog is `nil` or `commandsUnsupported`)
- [ ] add `.slashSuggestionTapped(SlashSuggestion)` → set `composerText` to
      `"/name "` (trailing space) or `"/cmd sub"`; no other state changes
- [ ] write TestStore tests (the issue's required four): typing `/` yields
      suggestions; typing filters; tap inserts the command; non-`/` input never
      produces suggestions
- [ ] write test: suggestions stay empty when `commandsUnsupported`
- [ ] run `swift test --package-path HermesKit` — must pass before task 5

### Task 5: commandOutput transcript row kind

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Models/ChatRow.swift` (or wherever
  `ChatRow.Kind` + the FNV-1a discriminator live)
- Modify: `HermesKit/Tests/HermesKitTests/` (the existing row-ID test file)

- [ ] add `ChatRow.Kind.commandOutput(String)` with its own stable
      kind-discriminator token for the deterministic ID (extend every exhaustive
      `switch` the compiler flags)
- [ ] write tests: commandOutput row IDs are deterministic across rebuilds and
      distinct from other kinds at the same ordinal
- [ ] write test: `reconstructTranscript` output is unaffected (server history never
      contains commandOutput; wholesale replace drops local ones — desktop parity)
- [ ] run `swift test --package-path HermesKit` — must pass before task 6

### Task 6: slash.exec pipeline in composerSubmitted

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/ChatFeatureTests.swift`

- [ ] branch `composerSubmitted`: trimmed text starts with `/` AND catalog loaded
      AND attachments empty → command branch (append user row, clear composer, set
      `isSending`); otherwise today's path byte-identical
- [ ] add the `slash.exec` effect (`{command w/o slash, session_id}`) + response
      action appending the `commandOutput` row (include `warning` when present) and
      clearing `isSending`; wrap with the existing session-not-found self-heal
- [ ] add the runtime-only refresh after successful exec: `session.resume` →
      `applyRuntimeInfo` only (no transcript touch); silent on failure
- [ ] write TestStore tests: `/status` submit → user row + exec RPC + output row +
      `isSending` cycle + runtime refresh applies model/usage without transcript
      change
- [ ] write TestStore tests: unsupported/`nil`-catalog agent → `/text` goes through
      plain `prompt.submit` untouched (backward-compat guard); staged attachments
      force the plain path
- [ ] run `swift test --package-path HermesKit` — must pass before task 7

### Task 7: command.dispatch fallback (alias, exec, skill/send directives)

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/ChatFeatureTests.swift`

- [ ] on `slash.exec` failure (non-unknown-method) → `command.dispatch
      {name, arg, session_id}`; decode the typed directive leniently
- [ ] handle directives: `exec`/`plugin` → output row (as Task 6); `alias` →
      re-enter the pipeline once with the target (single hop — a second alias fails
      to the error path); `skill`/`send` → route `message` into the existing
      `prompt.submit` flow suppressing the duplicate optimistic user row;
      `isSending` then follows the normal turn lifecycle
- [ ] both-fail path → `errorBanner` + clear `isSending` (no swallowed `try?`)
- [ ] write TestStore tests: dispatch `exec` output row; alias single hop resolves;
      double-alias hits the error path
- [ ] write TestStore tests: `skill` directive submits the message with exactly one
      user row (the typed `/cmd`); both-RPCs-fail → `errorBanner` and composer
      unlocked
- [ ] run `swift test --package-path HermesKit` — must pass before task 8

### Task 8: SlashSuggestionPanel view, ChatView wiring, row rendering

**Files:**
- Create: `HermesMobile/Sources/Features/Chat/SlashSuggestionPanel.swift`
- Modify: `HermesMobile/Sources/Features/Chat/ChatView.swift`
- Modify: the chat row view rendering (`rowView` site) for `.commandOutput`
- Modify: `HermesMobileTests/` (snapshot tests)

- [ ] build `SlashSuggestionPanel(suggestions:onTap:)` — thin view: rows of
      monospaced name + secondary description, skill icon for `isSkill`, ~5 visible
      rows max with internal scroll, reduce-motion-respecting transition
- [ ] slot it in `ChatView` between the transcript and `Divider()`/`ComposerView`,
      rendered only when `store.slashSuggestions` is non-empty; taps send
      `.slashSuggestionTapped`; keyboard stays up
- [ ] render `.commandOutput` rows bubble-less, dimmed, monospaced, selectable
- [ ] run `tuist generate` so the new source file joins the app target
- [ ] write snapshot tests: panel with built-ins + a skill row; a commandOutput row;
      record via `make snapshot-record`
- [ ] run `make snapshot` — must pass before task 9

### Task 9: Verify acceptance criteria

- [ ] verify the issue's expected behavior end-to-end in tests: `/` opens the list,
      filtering works, selection inserts, commands submit through the slash
      pipeline, non-`/` input unaffected
- [ ] verify backward compat: `commandsUnsupported` path leaves every existing test
      untouched (no snapshot or reducer diffs outside the new feature)
- [ ] run the full HermesKit suite:
      `script -q /dev/null swift test --package-path HermesKit`
- [ ] run `make snapshot`
- [ ] build the app: `tuist generate` + simulator build succeeds

### Task 10: [Final] Update documentation

- [ ] add a slash-command convention bullet to `CLAUDE.md` (catalog fetch + gate,
      client-side filter, exec pipeline, ephemerality rule)
- [ ] update `README.md` feature list if it enumerates chat features
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion

**Manual verification** (on-device against a live agent):
- Type `/` in a real session: panel appears with built-ins + installed skills;
  `/status` returns output; `/reasoning low` subcommand completion works
- `/compress` on a long session: output row appears, context pill drops after the
  runtime refresh
- A skill route (e.g. `/plan …`): streams as a normal turn, single user row
- Old-agent regression check (or simulated `-32601`): no panel, plain sends
  unchanged
- Confirm command output visibly disappearing after backgrounding/re-hydrate feels
  acceptable (known desktop-parity behavior, documented above)

**Possible follow-ups** (out of scope):
- `complete.slash` server-driven argument completion (checkpoint ids, personality
  names)
- Command palette entry point (a `/` button in the composer toolbar) if
  discoverability turns out poor
