# Keep Running Session Alive Across Navigation and Backgrounding

## Overview

Today the gateway socket's lifetime equals the pushed `ChatFeature`'s lifetime: popping
chat → sessions list destroys the state (`path: StackState<ChatFeature.State>` element
removal) and cancels the socket, discarding live thinking/tool/streaming rows; and
backgrounding suspends the process with no grace period, killing the socket mid-turn.
Reasoning/tool events streamed while disconnected are unrecoverable client-side (the
server's `inflight` carries only user/assistant text; there is no replay buffer).

This plan makes a **running turn keep its socket**:

1. **Nav-pop** — lift the open chat's state into an `AppFeature`-owned "live chat slot"
   (`liveChat: ChatFeature.State?`); the navigation path holds only thin session-id
   markers. Popping to the list no longer cancels anything — the turn keeps streaming,
   rows accumulate, and re-opening re-attaches live.
2. **Backgrounding** — a new `BackgroundTaskClient` (`beginBackgroundTask`) keeps the
   socket alive ~30s after `.background`; then flush + clean disconnect, falling back to
   the existing push + reconnect + hydrate catch-up.
3. **Push-tap dedup** (closes #32) — tap routing compares the pushed `session_id`
   against the slot + path, so tapping a push for the already-open session no longer
   stacks a duplicate chat screen.

Resolves the issue #33 spike (decision: client-only, no background modes, no
`BGTaskScheduler`) and closes #32.

## Context (from discovery)

- `HermesKit/Sources/HermesKit/AppFeature.swift` — `path: StackState<ChatFeature.State>`
  (:11), `currentViewingSessionID` (:43-45), `scenePhaseChanged` (:141-158, top-of-path
  hunting), `pushTapped` (:160-179, always appends via `openSession`), `openSession`
  (:185-202), `createSession` (:204-215), disconnect/logout (:217-223, :246-257),
  `sessionExpired` reads `path.last` (:225-231), reauth resume targets `path.ids.last`
  (:233-244), `runningChanged` routing (:259-264), `.forEach(\.path)` (:276-278),
  `.onChange(of: \.currentViewingSessionID)` (:283-287).
- `HermesKit/Sources/HermesKit/Features/ChatFeature.swift` — `.task` → `connect` (:357-363),
  `.onDisappear` kill-everything (:365-379, also releases the mic), `.gatewayClosed`
  backoff (:406-424), `.reconnectTick` (:426-427), `.resumeAfterReauth` (:429-440),
  `.persistNow` (:493-502), `.foreground` (:504-516, resets `hasRequestedSession` +
  reconnects unconditionally), `connect` (~:1302, `CancelID.socket`, `cancelInFlight: true`),
  `hydrate` (~:1346), `applyActivate` + #26 live-row preservation (~:1373-1494),
  `status` (`.ready`/`.reconnecting`) is the connection-alive signal.
- `HermesMobile/Sources/AppView.swift` — `NavigationStack(path: $store.scope(...))`
  destination builds `ChatView(store: chatStore)` from the path element (:28-32);
  scenePhase observer (:20-22).
- `HermesMobile/Sources/Features/Chat/` — `ChatView.onDisappear` sends `.onDisappear`.
- Pattern references: `AudioRecorderClient.swift` (UIKit-guarded client),
  `PushClient.swift`, `PreferencesClient.swift`.
- Related history: state-sync plan (#18) made hydrate server-authoritative; #26 preserves
  live thinking/tool rows on foreground re-hydrate but only while the ChatFeature is
  still alive — the slot makes that always true.

## Locked decisions (from brainstorm — do not re-open)

- Client-only; **no hermes-agent changes**.
- Background bar: **~30s grace then catch-up**. No audio/VoIP/processing background
  modes, no `BGTaskScheduler` reconnect.
- Approach: **live chat slot in `AppFeature`** (one live session at a time; opening a
  different session replaces the slot, same as today — no regression).
- Slot policy: a running turn keeps its socket; an idle chat doesn't need one.
- Reauth surfaces at root even while detached; slot sits paused until resolved.

## Development Approach

- **Testing approach: Regular** (implementation, then tests within the same task).
- Complete each task fully before moving to the next; small focused changes.
- **CRITICAL: every task MUST include new/updated tests** for its code changes —
  success and error scenarios; `TestStore` + `@Dependency` overrides + `TestClock`.
- **CRITICAL: all tests must pass before starting the next task.**
- **CRITICAL: update this plan file when scope changes during implementation.**
- Per-task commits (capitalized verb, no conventional-commit prefixes). Skip the codex
  external-review phase.
- `script -q /dev/null swift test --package-path HermesKit` for live test output.
- New app-target source files need `tuist generate` before an `xcodebuild` build.

## Testing Strategy

- **Unit tests** (HermesKit `swift test`): AppFeature slot-policy suite is the core new
  coverage; ChatFeature's existing suite stays green with minimal churn (actions renamed
  where noted).
- **Snapshot tests** (`make snapshot`): no visual changes expected; run to confirm. If a
  snapshot host constructs `AppFeature.State.path` with `ChatFeature.State`, update it to
  the marker + slot shape.

## Progress Tracking

- Mark completed items with `[x]` immediately when done.
- Add newly discovered tasks with ➕ prefix; blockers with ⚠️ prefix.
- Keep the plan in sync with actual work.

## Solution Overview

```swift
// AppFeature.State — after
public var path: StackState<ChatScreen.State>   // thin marker: session key only
public var liveChat: ChatFeature.State?          // the real chat state, slot-owned
```

- `liveChat` composed with `.ifLet(\.liveChat, action: \.liveChat)` — the socket,
  reconnect backoff, thinking ticker, and debounced persist become slot-rooted and
  survive navigation.
- The navigation destination scopes into `store.liveChat` (defensive `EmptyView` if nil).
- Teardown becomes an explicit `AppFeature` policy (new `ChatFeature` action
  `.teardown` = today's kill-everything `.onDisappear`); the view's disappear action
  shrinks to mic/voice cleanup only.

### Lifecycle rules

| Event | Policy |
| --- | --- |
| Open session (slot empty) | Fill slot + push marker; connect + hydrate as today |
| Open different session (slot occupied) | `persistNow` + `.teardown` old → replace slot + set path |
| Re-open the slot's session | Push marker only; `.reattached` (hydrate; connect only if socket dead) |
| Pop, turn running | Keep slot untouched (socket streams, list glow via `runningChanged`) |
| Pop, idle | `persistNow` + `.teardown` → `liveChat = nil` |
| Turn completes/errors while detached | Flush persist → tear down immediately |
| Archive the slot's session from the list | Tear slot down first, then today's optimistic archive |
| Logout / identity switch | Clear slot unconditionally (with existing wipes) |
| `.sessionExpired` (attached or detached) | Raise `ReauthFeature` at root; slot paused; same-user resume re-attaches |

### Backgrounding

- `.background` with `liveChat` running: `persistNow` + `backgroundTask.begin` — the
  socket just keeps running (no `ChatFeature` changes).
- Expiry (~30s, still backgrounded): final `persistNow`, cancel the socket cleanly
  (`.teardownSocketOnly` — state stays in memory), end the task. Catch-up is then the
  existing push + `.foreground` reconnect/hydrate with #26 preservation (now always
  applicable since the state survived).
- `.active` before expiry: end the task; existing `.foreground` path runs harmlessly.
- `.background` with no running turn: `persistNow` only — no task, no battery burn.

### Re-attach connect guard (key subtlety)

Re-opening a live slot must **not** cancel-and-redial a healthy socket (the gap drops
events). New `ChatFeature.Action.reattached`: always re-hydrate (server authority, the
existing #26-safe `applyActivate` path), but `connect` only when the socket isn't alive
(`status != .ready` — else just reset `hasRequestedSession` and invoke the hydrate
effect directly against the live socket).

### Push-tap routing (closes #32)

Decided in `AppFeature.pushTapped` by comparing `tap.sessionID` to the slot + path:

- matches slot **and** its marker is on top of the path → **no navigation**; in-place
  hydrate covers the update (badge bookkeeping still runs).
- matches slot, user on the list (no marker) → push the marker (live re-attach, no dup).
- different session → replace the slot and **set** the path to the single new marker
  (no stacking on cold launch either).

## Technical Details

- `ChatScreen` — a minimal `@Reducer` (or plain identified state) whose `State` holds the
  session key (`storedSessionID ?? liveSessionID` at push time; a new chat uses a stable
  placeholder id until resolved). No behavior of its own.
- `currentViewingSessionID` becomes: top marker present → `liveChat`'s session key,
  else `nil` (semantics preserved: detached-on-list means pushes for that session are
  not suppressed).
- Pop detection: handle `.path(.popFrom)` / observe path emptiness via `.onChange(of: \.path)`
  in `AppFeature` — whichever proves reliable with the marker stack; the policy branch
  (`liveChat.isRunning`?) is what's tested.
- `ChatFeature` gains a lightweight `isRunning`-style accessor if one doesn't exist
  (drive off the same state that powers `runningChanged`).
- `BackgroundTaskClient`:

```swift
@DependencyClient
struct BackgroundTaskClient {
  /// Starts a finite background task; the stream yields once if iOS expires it early.
  var begin: @Sendable (_ name: String) async -> AsyncStream<Void> = { _ in .finished }
  var end: @Sendable () async -> Void
}
```

  `#if canImport(UIKit)` `liveValue` wrapping `UIApplication.beginBackgroundTask`/
  `endBackgroundTask` (the client owns the mandatory end-on-expiry bookkeeping);
  non-iOS `liveValue = testValue`; in-memory `testValue` with test-drivable expiry
  (mirrors `AudioRecorderClient`). Lives in `HermesMobile/Sources/Features` alongside the
  other clients? — **No**: clients live in `HermesKit/Sources/HermesKit/Clients/`
  (`PushClient.swift` pattern); put it there so `AppFeature` can depend on it and tests run
  under `swift test`.

## Implementation Steps

### Task 1: Introduce the live chat slot and marker navigation path

**Files:**
- Modify: `HermesKit/Sources/HermesKit/AppFeature.swift`
- Create: `HermesKit/Sources/HermesKit/Features/ChatScreen.swift`
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift`
- Modify: `HermesMobile/Sources/AppView.swift`
- Modify: `HermesMobile/Sources/Features/Chat/ChatView.swift`
- Modify: `HermesKit/Tests/HermesKitTests/AppFeatureTests.swift` (+ any test/snapshot host constructing `path`)

- [x] add `ChatScreen.State` (session-key marker) and switch `AppFeature.State.path` to `StackState<ChatScreen.State>`; add `liveChat: ChatFeature.State?` + `.ifLet(\.liveChat, action: \.liveChat)`; update `currentViewingSessionID`
- [x] rewire `openSession`/`createSession` to fill the slot and push a marker; rewire `sessionExpired`/`resumeAfterReauth`/`runningChanged`/logout paths from `path.last`/`path.ids.last` to `liveChat`
- [x] split `ChatFeature.onDisappear` into `.viewDisappeared` (mic/voice cleanup only) and `.teardown` (full cancel of socket/reconnect/thinking/persist effects; the snapshot flush is `AppFeature`'s `.persistNow`-before-`.teardown` sequence on pop, matching the lifecycle table); `ChatView` sends the former
- [x] update `AppView` destination to scope `store.liveChat` into `ChatView` (defensive empty view when nil); keep behavior byte-identical for the plain open→pop-idle flow (pop while idle tears down via the Task 2 policy — for this task, wire pop→teardown unconditionally so no socket leaks between tasks)
- [x] write/adjust AppFeature tests: open fills slot + pushes marker; logout clears slot; reauth resume targets `liveChat`; existing suites green
- [x] run tests — must pass before task 2
- ➕ [x] open-different-session while the slot is occupied already tears the old slot down in Task 1 (concatenated `.teardown` → `.fillLiveChat`): slot cancel IDs are position-scoped, so a leaked old socket would feed events into the replacement state. Task 2 adds `persistNow` to that sequence.
- ➕ [x] one slot ↔ one marker: `fillLiveChat` resets the path (removeAll + append) instead of appending, so duplicate markers can never stack; Task 6 still adds the same-session routing compare.

### Task 2: Slot lifecycle policy (keep-while-running, teardown rules)

**Files:**
- Modify: `HermesKit/Sources/HermesKit/AppFeature.swift`
- Modify: `HermesKit/Sources/HermesKit/Features/SessionListFeature.swift` (archived delegate)
- Modify: `HermesKit/Tests/HermesKitTests/AppFeatureTests.swift`

- [x] on pop (`.path(.popFrom)` / path-emptied): keep the slot untouched when `liveChat.isRunning`; otherwise `persistNow` + `.teardown` + `liveChat = nil`
- [x] on `runningChanged(running: false)` (and error/interrupt completions) while no marker is in the path: flush persist then tear the slot down
- [x] on open-different-session while the slot is occupied: `persistNow` + `.teardown` the old slot before filling the new one
- [x] surface a `sessionArchived(id)` delegate from `SessionListFeature` and tear the slot down first when it matches the slot's session
- [x] write tests: pop-while-running keeps effects alive (streaming event after pop still mutates `liveChat`); idle pop tears down; complete-while-detached tears down; slot replacement persists + cancels the old chat; archive-the-slot-session tears down
- [x] run tests — must pass before task 3

### Task 3: Re-attach flow with the connect guard

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift`
- Modify: `HermesKit/Sources/HermesKit/AppFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/ChatFeatureTests.swift`
- Modify: `HermesKit/Tests/HermesKitTests/AppFeatureTests.swift`

- [x] add `ChatFeature.Action.reattached`: socket alive (`status == .ready` with a live session) → re-run the hydrate effect directly (no reconnect); socket dead → behave like `.foreground` (reset `hasRequestedSession`, `connect`)
- [x] `AppFeature`: re-opening the slot's session pushes the marker only and sends `.liveChat(.reattached)` (no new `ChatFeature.State`, no re-init losing live rows)
- [x] make `ChatView.task` re-attach-safe: appearance of an already-connected slot must not fire the unconditional `connect` (gated `.task` on slot freshness via a new internal `hasStarted` flag — first appearance connects, later appearances no-op and `.reattached` owns re-opens; `ChatView` unchanged)
- [x] write tests: reattach with a live socket does NOT cancel/redial (no `.gatewayClosed`, streaming continues) but does hydrate; reattach with a dead socket reconnects; re-open keeps accumulated detached rows
- [x] run tests — must pass before task 4

### Task 4: BackgroundTaskClient

**Files:**
- Create: `HermesKit/Sources/HermesKit/Clients/BackgroundTaskClient.swift`
- Create: `HermesKit/Tests/HermesKitTests/BackgroundTaskClientTests.swift`

- [x] implement the `@DependencyClient` (`begin(name) -> AsyncStream<Void>` yielding once on early expiry; `end()`), `DependencyValues` registration
- [x] `#if canImport(UIKit)` liveValue wrapping `beginBackgroundTask`/`endBackgroundTask` with internal end-on-expiry bookkeeping; non-iOS `liveValue = testValue`
- [x] in-memory `testValue` with a test-drivable expiry trigger (continuation captured for tests), `AudioRecorderClient` pattern
- [x] write tests: begin/end bookkeeping; expiry yields exactly once; double-begin replaces the prior task
- [x] run tests — must pass before task 5

### Task 5: Background grace policy in scenePhaseChanged

**Files:**
- Modify: `HermesKit/Sources/HermesKit/AppFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/AppFeatureTests.swift`

- [x] `.background` with `liveChat` running: `persistNow` + start the background task effect (cancellable `CancelID.backgroundGrace`), listening for expiry
- [x] on expiry while still backgrounded: final `persistNow`, cancel the socket only (`.teardownSocketOnly` — keep `liveChat` state in memory for #26 preservation), `end()` the task
- [x] `.active`: cancel the grace effect + `end()` the task; existing `.foreground` fan-out (now to `liveChat` directly, no top-of-path hunting) unchanged
- [x] `.background` with idle/no slot: `persistNow` only, no task
- [x] write tests (TestClock + fake BackgroundTaskClient): running → task begun + socket alive through the window; expiry → persist + socket cancelled + state retained; active-before-expiry → task ended, no socket cancel; idle → no task
- [x] run tests — must pass before task 6

### Task 6: Push-tap routing dedup (closes #32)

**Files:**
- Modify: `HermesKit/Sources/HermesKit/AppFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/AppFeatureTests.swift`

- [x] route `pushTapped` by slot/path comparison: matches slot + marker on top → no path change (badge bookkeeping only); matches slot + on list → push marker + `.reattached`; different → replace slot + SET path to the single new marker
- [x] keep cold-launch behavior correct (no home yet → badge only, as today)
- [x] write tests: matching id with chat open → no path change; matching id from list → re-attach push, no duplicate; different id → slot replaced, path set (not appended); approval badge bookkeeping preserved
- [x] run tests — must pass before task 7

### Task 7: Verify acceptance criteria

- [ ] pop during a streaming turn → return: no lost thinking/tool rows, timer continuous, no reconnect flash (manual sim run + reducer assertions)
- [ ] all lifecycle rules from Solution Overview covered by a passing test each
- [ ] run full suite: `script -q /dev/null swift test --package-path HermesKit`
- [ ] `tuist generate` + app build; run `make snapshot` — update hosts if the path shape broke them, confirm no visual diffs
- [ ] verify no socket leak: teardown paths cancel `CancelID.socket` exactly once (instrument via test gateway client)

### Task 8: Update documentation and close out

- [ ] update `CLAUDE.md` conventions: the live-chat-slot ownership rule, BackgroundTaskClient, push-tap dedup routing
- [ ] update `README.md` if the feature list mentions lifecycle behavior
- [ ] post the #33 write-up comment (decision: 30s grace + slot; no background modes) and reference this plan; note #32 is fixed
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion

**Manual verification:**
- Device test: background mid-turn < 30s → return: streaming never dropped (watch for the reconnect status flash — there should be none).
- Device test: background > 30s → push arrives on completion; foreground → hydrate with preserved thinking/tool rows.
- Device test: pop to list mid-turn, watch the row glow, re-open → live re-attach.
- Battery sanity: idle backgrounding starts no background task (Xcode Energy gauge).

**External follow-ups:**
- Close #32 and #33 on GitHub after merge (#33 gets the decision write-up comment).
- Server-side replay buffer for reasoning/tool events missed while disconnected remains
  an upstream gap (related: #30 re-surfacing pending approvals) — out of scope here.
