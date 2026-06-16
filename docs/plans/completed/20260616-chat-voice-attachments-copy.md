# Chat: Voice Input, Attachments, and Granular Copy (Issues #7, #8, #9)

## Overview

Three chat-composer/transcript features for Hermes Mobile, all shippable against
a current Hermes agent with **no server changes**:

- **#7 Voice input** — record audio in the composer, transcribe via the agent's
  `POST /api/audio/transcribe` REST endpoint (accepts a base64 data URL), and
  insert the returned transcript into the composer text.
- **#8 Photo/file attachments** — attach images (photo library + camera), PDFs,
  and arbitrary files to a message. iOS is **always remote** relative to the
  agent (no shared filesystem), so we upload **bytes**, mirroring the desktop's
  remote branch: images → `image.attach_bytes`, PDFs → `pdf.attach`, other files
  → `file.attach`. `prompt.submit` is unchanged (it picks up `attached_images` /
  the agent reads the returned `@file:` ref).
- **#9 Granular copy** — copy individual parts of an assistant message, with a
  dedicated **copy button per code block** and transient feedback (icon → green
  checkmark / small toast). Today only whole-message copy exists (context menu).

### Why / benefits
Brings the mobile composer to parity with the desktop's remote workflow and
fixes a real friction point (#9: "not friendly to be able to copy only the whole
message").

### Integration
All logic lands in `HermesKit` reducers/clients; `HermesMobile` views stay thin.
Outbound RPCs are discrete one-shot effects through `HermesGatewayClient`;
transcription is a REST call through `HermesRESTClient`. New native capabilities
(mic, photo/file pickers) go behind `@DependencyClient` structs.

## Context (from discovery)

**Verified against the deployed Hermes (`origin/main` of `hermes-agent`).** Note:
a local clone was 442 commits stale and lacked the byte-upload methods — always
verify against current `origin/main`.

Agent-side (server) contract — `hermes-agent/tui_gateway/server.py`:
- `image.attach_bytes` (≈5456): params `{ session_id, content_base64 | data, filename?, ext? }`;
  accepts a `data:image/…;base64,…` prefix; 25 MB cap; writes `upload_*` into the
  gateway images dir and queues into `session["attached_images"]`. Response mirrors
  `image.attach` (`{ attached, path, count, … }`).
- `pdf.attach` (≈5517): params `{ session_id, path | content_base64, name? }`;
  renders each page to PNG via `pdftoppm` (50 MB / 25 pages cap); queues pages as
  images. May return `5028` if `pdftoppm` is missing on the agent host.
- `file.attach` (≈5779): params `{ session_id, data_url, name?, path? }`; materializes
  the file on the gateway and returns `{ ref_path, ref_text: "@file:…" }` for the agent's
  file tools. (Non-image files are NOT vision tiles — they become readable artifacts.)
- Unknown methods → JSON-RPC error **`-32601` "unknown method: …"**. There is **no**
  capability list for methods (`model.options` `capabilities` is about model features,
  not RPC methods). Gate by attempting the call and handling `-32601`.
- `POST /api/audio/transcribe` — `hermes-agent/hermes_cli/web_server.py` (≈1339):
  body `{ data_url: "data:audio/…;base64,…", mime_type? }` → `{ ok, transcript, provider? }`;
  25 MB cap; provider is the agent's configured backend (local/groq/openai/…).
- Desktop reference flow (current `main`): `apps/desktop/src/app/session/hooks/use-prompt-actions.ts`
  picks path-vs-bytes by gateway locality and emits `['file.attach'|'image.attach_bytes', 'prompt.submit']`
  (see its `use-prompt-actions.test.tsx`).

iOS-side (this repo):
- Composer view: `HermesMobile/Sources/Features/Chat/ComposerView.swift` — `TextField`,
  `onSubmit(onSend)`, and a **disabled `voiceButton` placeholder** (≈58–64) ready to wire.
- Chat reducer/state: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift` —
  `composerText`, `isSending`, `canSend`, `errorBanner`; `.composerSubmitted` sends
  `prompt.submit` via `gateway.send` (≈221–241).
- Transcript view: `HermesMobile/Sources/Features/Chat/ChatView.swift` (context-menu copy
  → `.copyRow(id:)`); rows `HermesKit/.../Models/ChatRow.swift`.
- Markdown rendering: `HermesMobile/Sources/Features/Chat/MarkdownText.swift` +
  `HermesKit/Sources/HermesKit/Models/MarkdownSegment.swift` (splits ``` fences; code
  segments render in a monospaced box).
- Clients: `HermesKit/Sources/HermesKit/Clients/` — `HermesGatewayClient` (`send`),
  `HermesRESTClient` (REST w/ `ServerConnection`), `PasteboardClient.copy`, plus
  Keychain/Preferences/DebugLog. New mic + picker clients land here.
- Tests: reducer tests `HermesKit/Tests/HermesKitTests/ChatReductionTests.swift`
  (`TestStore` + `@Dependency` overrides + `TestClock`); snapshots
  `HermesMobileTests/PreviewSnapshotTests.swift`.

### Dependencies identified
- AVFoundation (`AVAudioSession`, `AVAudioRecorder`) for mic capture.
- PhotosUI (`PhotosPicker`) for the photo library; `UIImagePickerController`/camera for
  capture; `UIDocumentPicker` for files — all behind clients (no UIKit in reducers).
- `pdftoppm` (poppler-utils) must exist on the agent host for `pdf.attach` (graceful error).

## Development Approach

- **Testing approach: Regular** (implement, then write/update tests in the same task).
- Complete each task fully (impl + tests green) before the next.
- **Logic in `HermesKit`, views thin.** Never call UIKit/AVFoundation/Security/URLSession
  from a reducer — go through a `@DependencyClient` with `liveValue` + `testValue`.
- **Surface failures** — set `errorBanner`, clear `isSending`/recording/upload state on
  RPC/REST failure; never `try?`-swallow (matches the gateway convention).
- `@Sendable` effect closures capture deps explicitly (`[gateway]`, `[dismiss]`, `[recorder]`).
- Deployment target **iOS 17** — gate newer APIs (`#available`), prefer 17-safe SwiftUI.
- **New source files need `tuist generate`** before an `xcodebuild`/snapshot build sees them.
- A `public struct` nested in feature State needs an explicit `public init` to build from
  the app/snapshot target.
- CRITICAL: every task includes new/updated tests (success + error/edge); all tests pass
  before moving on. Update this plan when scope shifts.

## Testing Strategy

- **Unit/reducer tests (required per task)**: `TestStore` with `@Dependency` overrides;
  `TestClock`/`ImmediateClock` for timing; `LockIsolated` to capture outbound RPC params;
  assert exact `gateway.send`/REST payloads and state transitions (including error paths
  and `-32601` capability gating).
- **Snapshot tests**: re-render composer (recording state, attachment chips, transcribing)
  and transcript (code block with copy button + checkmark). `make snapshot` to assert,
  `make snapshot-record` when UI changes intentionally. Pinned row timestamps.
- Run `swift test` via `script -q /dev/null swift test --package-path HermesKit` (or `make test`)
  for live output.

## Progress Tracking
- Mark `[x]` immediately when done; `➕` for newly discovered tasks; `⚠️` for blockers.
- Keep this file in sync with actual work.

## Solution Overview

- **Voice (#7)**: `AudioRecorderClient` (record → `Data` + mime) + a `transcribe`
  method on `HermesRESTClient`. Reducer owns a `recording` state machine and a
  transcribe effect; on success it appends the transcript to `composerText`.
- **Attachments (#8)**: a `ComposerAttachment` value type + `attachments` array in
  `ChatFeature.State`; an `AttachmentPickerClient` for native pickers (library/camera/files).
  Upload effects call `image.attach_bytes` / `pdf.attach` / `file.attach` (base64),
  collect `@file:` refs, then `prompt.submit`. Capability gating caches an
  `attachmentsUnsupported` flag on `-32601`.
- **Copy (#9)**: extend `MarkdownSegment`/`MarkdownText` so each code block renders a
  copy button → `PasteboardClient.copy`, with a transient per-button checkmark and an
  optional lightweight toast; keep whole-message copy. Reducer tracks `recentlyCopiedID`
  for feedback, cleared by `TestClock`-driven effect.

### Key design decisions
- **Always upload bytes on iOS** (never send a device path) — the device shares no FS with
  the agent. This mirrors the desktop's remote branch exactly.
- **Reuse, don't reshape `prompt.submit`** — attachments are pre-staged via their own RPCs,
  consistent with desktop and the existing reducer.
- **Transcription via the agent endpoint** (not on-device `Speech`) — respects the user's
  configured provider and matches desktop behavior.
- **Capability gate via `-32601`** — no method-capability list exists server-side.

## What Goes Where
- **Implementation Steps** (`[ ]`): all iOS code + tests in this repo.
- **Post-Completion** (no checkboxes): manual device testing (mic permission, camera,
  large files), agent-host `pdftoppm` availability, `tuist generate` before app/snapshot builds.

## Implementation Steps

> Order: #9 first (pure client, lowest risk, fast win), then #7 (one new client +
> one REST method), then #8 (largest; depends on new pickers + multi-RPC upload).

---

### Task 1: Per-code-block copy data in the markdown model (#9)

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Models/MarkdownSegment.swift`
- Modify: `HermesKit/Tests/HermesKitTests/` (add `MarkdownSegmentTests.swift` if absent)

- [x] Ensure `MarkdownSegment.parse` exposes, for each code segment, the **raw code text**
      (fence-stripped, whitespace preserved) and an optional language hint, as a stable
      public shape usable by the view. (`case code(text:language:)`)
- [x] Add a stable identity for each segment (e.g. index-based id) so the view can track
      which block's copy was tapped. (view uses `enumerated()` offset — sufficient per render)
- [x] Write tests: code-only, mixed prose+code, multiple code blocks, unterminated fence,
      language-tagged fence, whitespace fidelity — assert raw code text round-trips exactly.
- [x] Run tests — 7/7 pass; package builds clean.

### Task 2: Code-block copy button + feedback in the view (#9)

**Files:**
- Modify: `HermesMobile/Sources/Features/Chat/MarkdownText.swift`
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift` (copy action + feedback state)
- Modify: `HermesKit/Tests/HermesKitTests/ChatReductionTests.swift`

- [x] Add a `.copyCode(text:token:)` action + `.copyFeedbackExpired(token:)` and a
      `recentlyCopiedToken` in `ChatFeature.State` for transient feedback.
- [x] Add an effect that clears the feedback after 1.5s using the injected `continuousClock`
      (cancellable `copyFeedback`, `cancelInFlight` so a new copy restarts it).
- [x] In `MarkdownText`, overlay a small copy button on each code block (top-trailing) via
      new `CodeBlockView`; icon flips to a green checkmark while `recentlyCopiedToken`
      matches the block's token. Reduce-motion gates the transition. Code text still selectable.
- [x] Keep existing whole-message context-menu copy intact (`.copyRow` unchanged).
- [x] Write reducer tests: copy sets pasteboard + shows/clears feedback with `TestClock`;
      second copy moves checkmark + restarts timer; empty no-op; stale-expiry guard. 20/20 pass.
- [x] Run tests — ChatReductionTests 20/20 pass. (App-target view build verified in Task 3.)

### Task 3: Copy-feedback toast + whole-message snapshot (#9)

**Files:**
- Modify: `HermesMobile/Sources/Features/Chat/ChatView.swift` (optional lightweight toast)
- Modify: `HermesMobileTests/PreviewSnapshotTests.swift`
- Create: snapshot baselines under `HermesMobileTests/__Snapshots__/…`

- [x] Toast: **skipped by decision** — the per-block green checkmark already satisfies the
      issue's "green checkmark" feedback ask; a second toast would double up. Revisit if
      whole-message copy needs its own cue.
- [x] Added two component snapshots (`testCodeBlock_copyButtonIdle`, `testCodeBlock_copiedCheckmark`)
      and re-recorded `testChatView_codeBlockAndReconnecting` (copy button now in context).
- [x] `tuist generate` ran; surgically re-recorded only the affected baseline; assert pass clean.
- [x] Run reducer + snapshot tests — full `PreviewSnapshotTests` suite green; isolation verified
      (only the 3 code-block snapshots changed, all others unchanged).

---

### Task 4: `AudioRecorderClient` dependency (#7)

**Files:**
- Create: `HermesKit/Sources/HermesKit/Clients/AudioRecorderClient.swift`
- Create: `HermesKit/Tests/HermesKitTests/AudioRecorderClientTests.swift`

- [x] Defined `@DependencyClient struct AudioRecorderClient` with `requestPermission`,
      `startRecording`, `stopRecording -> RecordedAudio` (`{ data, mimeType }`), `cancel`, and
      **`levels() -> AsyncStream<Float>`** (normalized 0...1 mic amplitude for the waveform).
      `liveValue` (iOS-only, `#if canImport(UIKit)`): AVAudioSession + AVAudioRecorder w/
      metering, an `AudioRecorderEngine` actor sampling `averagePower` at ~15 Hz; mime
      `audio/m4a`. macOS falls back to the no-op double so `swift test` compiles.
- [x] Registered the `DependencyValues.audioRecorder` accessor; explicit `testValue` (canned
      audio + finite `[0.2, 0.6, 0.4]` levels).
- [x] Added `NSMicrophoneUsageDescription` via `Project.swift`; `tuist generate` clean.
- [x] Tests: dB→0...1 normalization (floor/full-scale/mid), test-double permission + audio,
      levels stream emits-then-finishes. 5/5 pass.
- [x] Run tests — 5/5 pass; package builds on macOS.

### Task 5: Transcription over REST (#7)

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Clients/HermesRESTClient.swift`
- Modify: `HermesKit/Tests/HermesKitTests/` (REST client test, mock `URLSession`/transport)

- [x] Added `transcribe(connection:dataURL:mimeType:) -> String` POSTing to `/api/audio/transcribe`
      with `{ data_url, mime_type? }`, decoding `{ ok, transcript, provider? }` via a new `postJSON`
      helper; throws `RESTError.transcriptionFailed(reason)` on `ok:false`, maps HTTP errors as usual.
- [x] Added `RecordedAudio.dataURL` (`data:<mime>;base64,<…>`) builder.
- [x] Tests: success returns transcript + asserts POST/path/token/Content-Type; `ok:false` throws
      server reason; 401 → `.unauthorized`; `dataURL` base64 round-trip. (`MockURLProtocol`.)
- [x] Run tests — full HermesKit suite 193/193 pass.

### Task 6: Wire voice recording into the composer reducer + view (#7)

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift`
- Modify: `HermesMobile/Sources/Features/Chat/ComposerView.swift`
- Modify: `HermesKit/Tests/HermesKitTests/ChatReductionTests.swift`
- Modify: `HermesMobileTests/PreviewSnapshotTests.swift`

- [x] Added `recording: RecordingState` (`.idle`/`.requestingPermission`/`.recording`/`.transcribing`)
      + `waveformLevels`/`recordingSeconds` to State, and actions `.voiceButtonTapped`,
      `.recordingPermission`, `.recordingStarted`, `.recordingLevel`, `.recordingTick`,
      `.recordingStopped`, `.transcriptionSucceeded`, `.voiceInputFailed`, `.recordingCancelled`.
- [x] Stop → transcribe effect; success **appends** transcript to `composerText` (with a
      separating space); failure sets `errorBanner` and returns to `.idle`. `onDisappear`
      tears down voice effects + cancels the recorder mid-recording.
- [x] Replaced the disabled `voiceButton` with a live mic button; recording/transcribing
      swap the text field for the recorder bar.
- [x] `.recording` shows an **animated waveform** (`RecordingWaveform`) driven by
      `AudioRecorderClient.levels()`, an `m:ss` elapsed readout, and cancel (×) / stop controls;
      reduce-motion disables the bar animation.
- [x] Reducer tests: permission-denied banner; full record→stop→transcribe→append; transcribe
      failure surfaces server reason; timer advances `recordingSeconds` (`TestClock`). 24/24 pass.
- [x] Added `testComposer_recordingWaveform` + `testComposer_transcribing`; re-recorded the 4
      composer-bearing baselines (mic restyle). Full snapshot suite green; change isolated.

---

### Task 7: `ComposerAttachment` model + state (#8)

**Files:**
- Create: `HermesKit/Sources/HermesKit/Models/ComposerAttachment.swift`
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/ChatReductionTests.swift`

- [x] Defined `public struct ComposerAttachment` (explicit `public init`): `id`, `kind`
      (`.image`/`.pdf`/`.file`), `filename`, `mimeType`, `data`, `uploadState`
      (`.pending`/`.uploading`/`.uploaded(ref:)`/`.failed`), plus `dataURL`/`base64` helpers.
- [x] Added `attachments: [ComposerAttachment]` + `attachmentsUnsupported: Bool` to State;
      `canSend` now allows an attachments-only message (text OR attachments present).
- [x] Added actions `.attachmentAdded`, `.removeAttachment(id:)` with reducer cases.
- [x] Tests: add/remove mutates state; attachments-only `canSend`. Full suite 199/199 pass.

### Task 8: `AttachmentPickerClient` (library / camera / files) (#8)

**Files:**
- Create: `HermesKit/Sources/HermesKit/Clients/AttachmentPickerClient.swift`
- Modify: `HermesMobile/Sources/Features/Chat/ComposerView.swift` (present native pickers)
- Create/Modify: tests for the test client + a thin view wiring

- [x] Defined `@DependencyClient struct AttachmentPickerClient` returning `[PickedItem]`
      (`{ data, filename, mimeType, kind }`) for `pickPhotos`/`capturePhoto`/`pickFiles`.
      `liveValue` (iOS-only) bridges `PHPickerViewController` / `UIImagePickerController` /
      `UIDocumentPickerViewController` via top-VC presenters + continuations; `testValue` empty.
      Pure `ComposerAttachment.Kind.infer(mimeType:filename:)` routes files to image/pdf/file.
- [x] Added an attach "+" Menu (Photo Library / Camera / Files) in the composer, hidden when
      `attachmentsUnsupported`; reducer `.attach{Photos,Camera,Files}Tapped` run the picker and
      dispatch `.attachmentAdded` (fresh `uuid` per item).
- [x] Added `NSCameraUsageDescription` via `Project.swift` (PHPicker needs no photo-library
      string — it's out-of-process); regenerated the project.
- [x] Tests: picker → `attachmentAdded` per item with fresh ids; cancelled picker no-ops;
      `Kind.infer` by mime + extension fallback; `dataURL`/`base64` helpers. 204/204 pass.
- [x] iOS build compiles the live picker code; re-recorded the 4 idle-composer baselines (attach
      button). Snapshot suite green; change isolated.

### Task 9: Attachment upload effects + submit integration (#8)

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/ChatReductionTests.swift`

- [x] `base64`/`dataURL` helpers live on `ComposerAttachment` (Task 7); a private free
      `uploadAttachment(_:sessionID:gateway:)` dispatches by kind.
- [x] `.composerSubmitted` with attachments uploads **before** `prompt.submit` (image →
      `image.attach_bytes` `{content_base64, filename}`; pdf → `pdf.attach` `{content_base64, name}`;
      file → `file.attach` `{data_url, name}`), collects `ref_text` (`@file:…`), prepends them on
      their own lines, then submits. Empty text → the bubble shows filenames.
- [x] Upload failure (`.attachmentUploadFailed`) sets `errorBanner`, marks attachments `.failed`,
      clears `isSending`, and keeps the composer text + attachments for retry — never submits partial.
- [x] `.attachmentsSubmitted` echoes the user row, clears composer + attachments on success.
- [x] Tests (RPC order via `LockIsolated`): image → `['image.attach_bytes','prompt.submit']`;
      pdf → `['pdf.attach','prompt.submit']`; file → `['file.attach','prompt.submit']` with the
      `@file:` ref woven into the prompt text; mixed batch; failure aborts + preserves input. 209/209.
- [x] Note: `-32601` is detected via the gateway error message prefix (`"unknown method"`) — the
      JSON-RPC code isn't preserved by `InboundFrame`. Wired in Task 10.

### Task 10: Capability gating for old agents (`-32601`) (#8)

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/ChatReductionTests.swift`

- [x] Added `GatewayError.isUnknownMethod` (matches the server's `"unknown method"` text). The
      upload catch branches to `.attachmentsUnsupportedDetected`, which sets `attachmentsUnsupported`,
      a clear "agent too old, update it" banner, marks attachments failed, clears `isSending`, and
      aborts before `prompt.submit`.
- [x] Attach "+" affordance hides for the session when `attachmentsUnsupported` (wired in Task 8 via
      `attachmentsSupported: !store.attachmentsUnsupported`).
- [x] Tests: `isUnknownMethod` detection (case-insensitive, negatives); gating flow flips the flag +
      message and never calls `prompt.submit`, preserving input. 211/211 pass.

### Task 11: Attachment chips UI + snapshots (#8)

**Files:**
- Modify: `HermesMobile/Sources/Features/Chat/ComposerView.swift`
- Modify: `HermesMobileTests/PreviewSnapshotTests.swift`
- Create: snapshot baselines

- [x] `AttachmentChip` renders above the input: image thumbnail (`UIImage(data:)`) or pdf/file
      glyph + filename, with a remove (×) button; upload state shows a spinner (uploading) or an
      orange warning + remove (failed). Chips sit in a horizontal scroll row.
- [x] Added `testComposer_attachmentChips` (image + pdf + file) and
      `testComposer_attachmentUploadingAndFailed`; recorded baselines. Snapshot suite green;
      isolated (existing snapshots unchanged — chips only show with attachments).

---

### Task 12: Verify acceptance criteria

- [x] #7: record → transcript appended; permission-denied + transcribe-failure handled (reducer tests).
- [x] #8: photos/camera/files attach + upload-by-kind then submit on a remote agent; old-agent
      `-32601` gating; failures surfaced with input preserved, no partial sends (reducer tests).
- [x] #9: per-code-block copy with checkmark feedback; whole-message copy intact (reducer + snapshots).
- [x] Ran full suites: `make test` → 211/211; `make snapshot` → suite green.
- [x] No UIKit/AVFoundation/URLSession in reducers — all behind `@DependencyClient`s.

### Task 13: [Final] Docs + plan move

- [x] Updated `README.md` feature list (voice + waveform, attachments, granular copy).
- [x] Updated `CLAUDE.md`: voice/attachment conventions, upload-bytes-not-paths, `-32601`
      gating, and the iOS-only-client `#if canImport(UIKit)` + macOS-fallback rule.
- [x] Moved this plan to `docs/plans/completed/`.

## Post-Completion
*Manual / external — no checkboxes.*

**Manual verification (device):**
- Mic permission prompt + denial recovery; real transcription quality across the agent's
  configured provider.
- Camera capture + photo-library + Files picker on a physical device.
- Large media near the 25 MB image / 50 MB PDF caps; slow-network upload UX.
- Reduce-motion behavior for copy feedback.

**External / environment:**
- Agent host must have `pdftoppm` (poppler-utils) for `pdf.attach`; otherwise it returns `5028`
  — confirm the UI surfaces this gracefully.
- Validate against an agent old enough to lack `image.attach_bytes`/`file.attach` to confirm
  the `-32601` gating path (or simulate in tests).
- `tuist generate` before any `xcodebuild`/snapshot build that includes new source files.
- Issue references: GitHub #7 (voice), #8 (attachments), #9 (granular copy).
