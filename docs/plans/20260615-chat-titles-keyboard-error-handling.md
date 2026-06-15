# Chat titles, keyboard dismissal & prompt error handling

Covers GitHub issues **#2, #3, #5, #6**.

## Overview

Four related polish fixes to the chat experience:

- **#3 — Chat title bugs.** (a) New sessions created from mobile are hardcoded as
  "Mobile chat", which suppresses the server's auto-naming from the first message.
  (b) Search results render the raw stored session id as a "weird title".
- **#2 — Edit chat title.** Let the user rename a session from both the session list
  and the chat screen.
- **#5 — Keyboard won't dismiss** on the chat screen until a message is sent. It
  should dismiss on tap or scroll outside the input.
- **#6 — Stuck "compacting" with no progress.** A failed/hung `prompt.submit` shows no
  error on mobile (desktop shows "Prompt failed — request timed out: prompt.submit"),
  and the activity/compacting message is truncated to one line.

## Context (from discovery)

Files/components involved:

- `HermesKit/Sources/HermesKit/Features/ChatFeature.swift` — `bootstrapSession`
  hardcodes `title: "Mobile chat"` (line ~525); `composerSubmitted` swallows
  `prompt.submit` errors with `try?` (line ~215) and never clears `isSending`.
- `HermesKit/Sources/HermesKit/Clients/HermesGatewayClient.swift` — `GatewayConnection.send`
  has **no request timeout**; a hung RPC awaits forever.
- `HermesKit/Sources/HermesKit/Clients/HermesRESTClient.swift` — has `archive` via
  `PATCH /api/sessions/{id}`; rename uses the **same endpoint** with `{"title":…}`.
- `HermesKit/Sources/HermesKit/Features/SessionListFeature.swift` — list state, swipe/
  context-menu actions, optimistic archive + rollback (the pattern rename mirrors).
- `HermesMobile/Sources/Features/Chat/ChatView.swift` — activity footer is
  `.lineLimit(1)`; transcript `ScrollView` has no keyboard dismissal.
- `HermesMobile/Sources/Features/Chat/ComposerView.swift` — the `TextField` (no shared
  `@FocusState`).
- `HermesMobile/Sources/Features/SessionRowView.swift` — renders `session.title ?? session.id`.

Verified against the Hermes source (`/Users/eugene/Documents/Development/Personal/hermes-agent`):

- **Auto-title:** `session.create` stores `pending_title = title or None` (server.py:3025).
  `agent/title_generator.maybe_auto_title` only generates **when no title is set**, so
  passing "Mobile chat" disables it. Title is written to the DB and surfaced by the
  REST session list — **no live title event is emitted** (the callback isn't wired), so
  the open chat header won't update live (deferred by decision; the list self-heals on
  its 10s poll).
- **Rename:** `PATCH /api/sessions/{id}` `{"title":…}` (web_server.py:5301) — empty/null
  clears; may return **400** (too long / invalid / duplicate). Gateway `session.title`
  method (server.py:3526) sets the title over the socket and returns `{pending,title}`.
- **Search:** `/api/sessions/search` results contain only `session_id` (a compression-
  **lineage tip**, possibly a different id), `snippet`, `session_started` — **no title**.
- **prompt.submit acks fast:** returns `_ok(rid, {"status":"streaming"})` immediately
  and streams asynchronously — so a client-side request timeout is **safe** (it won't
  trip on long turns) and is exactly what catches a stuck server.
- **Desktop error handling:** `requestTimeoutMs` per RPC → `request timed out: <method>`
  (json-rpc-gateway.ts:238); `use-prompt-actions.ts` catches and shows "Prompt failed".

Decisions (from planning):

- Rename transport: **chat → gateway `session.title`**, **list → REST PATCH**.
- **Defer** the live chat-header auto-title update (list-only fix for #3a).
- **Regular** testing (implement, then tests in the same task).

## Development Approach

- **Testing approach: Regular.** Complete each task fully (code + tests) before the next.
- Logic lives in `HermesKit`; views stay thin (see `CLAUDE.md`).
- **Every task includes new/updated tests** (TCA `TestStore` reducer tests are the
  highest-value suite; gateway/REST clients use injected transports; views use snapshots).
- **All tests pass before starting the next task.** Run `make test` (HermesKit) and
  `make snapshot` (views) as relevant.
- Maintain backward compatibility; keep decode lenient; never crash on unknown events.

## Testing Strategy

- **Unit (required each task):** `swift test` via `make test` — `TestStore` + `@Dependency`
  overrides + `TestClock`; gateway-client tests with a fake `WebSocketTransport`; REST
  tests with a `URLProtocol` mock.
- **Snapshot:** `make snapshot` (assert) / `make snapshot-record` (re-record) for view
  changes (search row, multi-line footer). Re-record only when the change is intentional.
- **Manual verification:** keyboard dismissal (#5) and the rename alert flows are
  UI-interaction-only — verify on simulator/device (see Post-Completion).

## Solution Overview

Seven focused tasks: two title-display fixes (#3), two rename surfaces (#2), keyboard
dismissal (#5), and the two-part prompt-error fix (#6 = gateway timeout + reducer
surfacing/footer). Rename reuses the optimistic-update-with-rollback pattern already
proven by archive.

## What Goes Where

- **Implementation Steps** (`[ ]`): all code, tests, and snapshots in this repo.
- **Post-Completion** (no checkboxes): on-device manual verification of keyboard and
  rename flows; `tuist generate` is needed for any new source file before an app build.

## Implementation Steps

### Task 1: Auto-name new mobile sessions (#3a)

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/ChatInteractionTests.swift` (and any
  gateway/JSONRPC test fixture referencing `"Mobile chat"`)

- [x] In `bootstrapSession`, change the new-session branch from
  `?? .object(["title": .string("Mobile chat")])` to `?? .object([:])` so
  `session.create` sends no title and the server auto-names from the first message.
- [x] Verify the resume branch (`session.resume` with `session_id`) is unchanged.
- [x] Update/replace the bootstrap test to assert `session.create` is sent with **no
  `title`** param (and no regression to resume).
- [x] Grep for and update any test fixture still asserting `"Mobile chat"` (none existed outside the source line).
- [x] Run `make test` — must pass before next task.

### Task 2: Show snippet (not raw id) for search results (#3b)

**Files:**
- Modify: `HermesMobile/Sources/Features/SessionRowView.swift`
- Modify: `HermesMobileTests/PreviewSnapshotTests.swift`

- [x] When the row has no `title` and `showsPreview` is true (search result), render the
  `preview`/snippet as the primary (headline) label instead of `session.id`; keep the
  relative date. Avoid ever showing the raw stored id as a title.
- [x] Keep the grouped-list behaviour unchanged (titled rows still show the title; an
  untitled non-search row still falls back to id, which only happens transiently).
- [x] Add a snapshot case for a search-result row with `title == nil` + a snippet.
- [x] Run `make snapshot` (record the new baseline intentionally) — must pass before next.

### Task 3: Rename from the session list via REST PATCH (#2)

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Clients/HermesRESTClient.swift`
- Modify: `HermesKit/Sources/HermesKit/Features/SessionListFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/HermesRESTClientTests.swift`
- Modify: `HermesKit/Tests/HermesKitTests/SessionListFeatureTests.swift`
- Modify: `HermesMobile/Sources/Features/SessionListView.swift` (swipe/context menu + alert)

- [x] Add `rename: @Sendable (_ connection:, _ id:, _ title: String) async throws -> Void`
  to `HermesRESTClient`; `live` does `PATCH /api/sessions/{id}` with `{"title": title}`
  (reuse the raw-id interpolation + `send` helper used by `archive`).
- [x] Add rename state to `SessionListFeature.State` (e.g. `renamingID: Session.ID?` +
  bound `renameDraft: String`) and actions: `renameButtonTapped(id)`,
  `renameDraftChanged`/binding, `confirmRename`, `renameSucceeded(id)`,
  `renameFailed(id, previousTitle:)`.
- [x] `confirmRename`: optimistically set the row's `title` to the trimmed draft, clear
  the alert, fire `rest.rename`; on failure restore `previousTitle` and set `loadError`
  (server may 400 on invalid/duplicate). Empty draft clears the title (allowed).
- [x] Wire the view: a "Rename" entry in both `.swipeActions` and the row `.contextMenu`,
  presenting an `.alert` with a `TextField` bound to `renameDraft` + Save/Cancel.
- [x] Write `HermesRESTClient` test: `rename` issues a `PATCH` with the correct path +
  JSON body (URLProtocol mock); maps 400 → `RESTError.server`.
- [x] Write `SessionListFeature` tests: rename success (optimistic title update + RPC)
  and failure (rollback to previous title + error surfaced).
- [x] Run `make test` — must pass before next task.

### Task 4: Rename from the chat screen via gateway `session.title` (#2)

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/ChatInteractionTests.swift`
- Modify: `HermesMobile/Sources/Features/Chat/ChatView.swift` (toolbar + alert)

- [x] Add rename state to `ChatFeature.State` (e.g. `renameDraft: String?`) and actions:
  `renameButtonTapped`, `confirmRename`, `renameFailed(previousTitle:)`.
- [x] `confirmRename`: optimistically set `state.title` to the trimmed draft, then send
  `session.title` with `{"session_id": liveSessionID, "title": draft}` over the gateway;
  on failure restore the previous title and set `errorBanner`. Guard on `liveSessionID`.
- [x] Wire the view: a nav-bar toolbar control (e.g. an ellipsis `Menu` with "Rename")
  that presents an `.alert` with a `TextField` bound to the draft + Save/Cancel,
  pre-filled with the current title.
- [x] Write `ChatFeature` tests: rename success (optimistic `state.title` + the
  `session.title` RPC is sent) and failure (rollback + `errorBanner`).
- [x] Run `make test` — must pass before next task.

### Task 5: Dismiss the keyboard on tap / scroll (#5)

**Files:**
- Modify: `HermesMobile/Sources/Features/Chat/ChatView.swift`
- Modify: `HermesMobile/Sources/Features/Chat/ComposerView.swift`

- [x] Hoist a `@FocusState private var composerFocused: Bool` in `ChatView`; pass a
  `FocusState<Bool>.Binding` into `ComposerView` and apply `.focused($composerFocused)`
  to its `TextField`.
- [x] Add `.scrollDismissesKeyboard(.interactively)` to the transcript `ScrollView`
  (iOS 17-safe) so dragging the transcript dismisses the keyboard.
- [x] Add a tap affordance on the transcript area that sets `composerFocused = false`
  (`.simultaneousGesture(TapGesture())` on the ScrollView — preserves row buttons,
  context menus, and markdown links).
- [x] No reducer logic changes → no unit test; verified existing snapshots still pass
  via `make snapshot` (23 tests, 0 failures — no baseline diffs). Updated the three
  `ComposerView` snapshot call sites with a `ComposerHost` `@FocusState` wrapper.
  Keyboard behaviour is covered by manual verification (Post-Completion).
- [x] Confirmed the app/test target still builds — `make snapshot` ran a full
  xcodebuild + test pass (`** TEST SUCCEEDED **`); no new files, so `tuist generate`
  was not needed.

### Task 6: Add a per-request timeout to the gateway client (#6, mechanism)

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Clients/HermesGatewayClient.swift`
- Modify: `HermesKit/Tests/HermesKitTests/HermesGatewayClientTests.swift`

- [x] Add `GatewayError.timedOut` with a message mirroring desktop
  (`"request timed out: <method>"`).
- [x] Give `GatewayConnection` a `requestTimeout: Duration` (default e.g. `.seconds(30)`),
  threaded through `make(requestTimeout:)` and `live`. `send` schedules a per-id timeout
  task; on fire it removes the pending continuation and resumes it throwing `.timedOut`.
- [x] Cancel/clear the timeout task when the response, failure, or `finish` resolves the
  id (no leaks, no double-resume — track tasks per id alongside `pending`).
- [x] Write a gateway-client test: a fake `WebSocketTransport` that **never responds** to
  a request, with a short injected `requestTimeout`, makes `send` throw `.timedOut`;
  confirm a normal response still resolves and cancels its timer (no spurious throw).
- [x] Run `make test` — must pass before next task.

### Task 7: Surface prompt errors + multi-line activity footer (#6)

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift`
- Modify: `HermesMobile/Sources/Features/Chat/ChatView.swift`
- Modify: `HermesKit/Tests/HermesKitTests/ChatInteractionTests.swift`

- [x] In `composerSubmitted`, stop swallowing the error: await `gateway.send("prompt.submit",…)`
  and on throw send a new `promptSubmitFailed(message)` action.
- [x] Handle `promptSubmitFailed`: set `errorBanner` (e.g. `"Prompt failed: \(message)"`,
  mirroring desktop), set `isSending = false`, clear `activity` so the stuck
  "compacting…" footer goes away.
- [x] In `ChatView.footer`, remove `.lineLimit(1)` from the activity label (allow
  wrapping) so the compacting/activity message is fully visible.
- [x] Write `ChatFeature` tests: a failing `prompt.submit` (gateway throws, incl.
  `.timedOut`) sets `errorBanner`, clears `isSending`, and clears `activity`.
- [x] (skipped — optional) No new snapshot added; the footer change is a pure
  `.lineLimit(1)` removal. Ran `make snapshot` to confirm existing 23 baselines still
  pass (`** TEST SUCCEEDED **`, no diffs).
- [x] Run `make test` (and `make snapshot` if a baseline changed) — must pass. (157
  HermesKit tests pass; snapshot suite passes.)

### Task 8: Verify acceptance criteria

- [ ] #3a: a new session sends `session.create` with no title; after a first message the
  list shows the auto-generated name (manual, against a live server).
- [ ] #3b: search results show the snippet, never the raw stored id.
- [ ] #2: rename works from both the list (REST) and the chat screen (gateway), with
  optimistic update and rollback-on-error.
- [ ] #5: keyboard dismisses on tap and on scroll, before any message is sent.
- [ ] #6: a hung/failed prompt surfaces "Prompt failed", clears the spinner, and the
  activity/compacting message wraps to multiple lines.
- [ ] Run the full suite: `make test` and `make snapshot`.

### Task 9: [Final] Update documentation

- [ ] Update `docs/architecture.md` if the gateway timeout / rename paths warrant a note.
- [ ] Update `CLAUDE.md` if a new convention emerged (e.g. the request-timeout behaviour).
- [ ] Move this plan to `docs/plans/completed/`.

## Post-Completion
*Manual / external — no checkboxes.*

**Manual verification (on simulator/device against a live Hermes server):**
- Keyboard dismissal (#5) — tap-outside and scroll-to-dismiss, with the composer empty.
- Rename alert flows (#2) from both the list and the chat screen, including a server
  rejection (e.g. an over-long or duplicate title → error surfaced, optimistic value
  rolled back).
- New-session auto-naming (#3a) end-to-end after the first message.
- A genuinely stuck `prompt.submit` (#6) → "Prompt failed" appears and the spinner clears.

**Build note:**
- Any newly added source file requires `tuist generate` before an `xcodebuild` app build
  picks it up. (This plan modifies existing files only, but re-generate if you add one.)
