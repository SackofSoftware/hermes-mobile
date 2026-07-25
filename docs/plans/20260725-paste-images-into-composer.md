# Paste images from the clipboard into the chat composer (#54)

## Overview

GitHub issue #54 — *"Allow to paste images from clipboard into chat"*. Today the only way to
get an image into a message is the paperclip menu (Photo Library / Camera / Files). The
natural gesture — copy a screenshot, long-press the message field, tap **Paste** — does
nothing: the composer is a SwiftUI `TextField(axis: .vertical)`, whose paste configuration
accepts text only, so for an image-only clipboard iOS does not even offer the **Paste** item.

This plan makes an image paste land **in the field the user is already typing in**. A pasted
image is staged exactly like a picked one: it becomes a `ComposerAttachment` chip above the
input and uploads via `image.attach_bytes` on submit. Nothing downstream of `PickedItem`
changes.

Product decisions taken during planning:

- **Native gesture only.** No extra "Paste" entry in the paperclip menu — it was considered
  and explicitly skipped. The edit-menu paste is an implicit pasteboard grant (no *"Allow
  Paste"* banner); a menu-driven programmatic read is not, so skipping it also avoids the
  only path that would prompt.
- **Images only.** Mixed clipboards still paste their text normally; non-image providers are
  forwarded to `UITextView`'s stock handling untouched.
- **Regular testing approach** — implementation first, tests before the task closes.

The cost of the natural UX is that the composer's SwiftUI `TextField` has to be replaced with
a `UITextView`-backed representable, since only UIKit exposes the paste hooks. That component
must reproduce today's behaviour exactly: placeholder, 1–6 line growth, `@FocusState`
binding, and Return-key submit.

## Context (from discovery)

Files/components involved:

- `HermesMobile/Sources/Features/Chat/ComposerView.swift:53` — the `TextField(axis: .vertical)`
  being replaced; `:83` the paperclip `Menu` (unchanged); `:217` `AttachmentChip`, which
  already renders an image thumbnail from `attachment.data`.
- `HermesMobile/Sources/Features/Chat/ChatView.swift:9` `@FocusState private var composerFocused`
  (the transcript uses it to dismiss the keyboard), `:25-47` the `ComposerView` call site.
- `HermesKit/Sources/HermesKit/Clients/AttachmentPickerClient.swift` — `PickedItem` (the shared
  hand-off type) and `PhotoPickerPresenter.loadImage(from:)` (`:120-134`), whose
  "pick the best image type identifier from an `NSItemProvider`" logic paste needs verbatim.
- `HermesKit/Sources/HermesKit/Models/ComposerAttachment.swift` — `Kind.infer`, `dataURL`,
  `base64`; already handles any `image/*`.
- `HermesKit/Sources/HermesKit/Features/ChatFeature.swift:579-586` (attachment actions),
  `:1573-1600` (their reducer cases), `:98`/`:1627` the `attachmentsUnsupported` capability gate.

Related patterns found:

- Attachment sources are uniform: an action → an `AttachmentPickerClient` closure → `[PickedItem]`
  → `.attachmentAdded(item.attachment(id: uuid()))` per item. Paste becomes a fourth source
  entering at the same point.
- UIKit lives behind `#if canImport(UIKit)` with pure logic hoisted out so `swift test` covers
  it on macOS (`AudioRecorderClient`, `AttachmentPickerClient`).
- Reducer tests: `ChatReductionTests.swift:1605` overrides `$0.attachmentPicker` +
  `$0.uuid = .incrementing`. Model tests: `ComposerAttachmentTests.swift` (swift-testing).
- Snapshots: 8 `ComposerView` call sites across `ComposerSnapshotTests.swift` and
  `ContextUsageSnapshotTests.swift:65`, plus `ChatSnapshotTests` renders the composer inside
  the full screen.

Dependencies identified:

- `NSItemProvider` / `UniformTypeIdentifiers` — Foundation-level, available on macOS 14
  (HermesKit's test platform), so the provider→`PickedItem` loader can live outside the UIKit
  guard and be unit-tested.
- `UIPasteConfiguration` / `UIResponder.paste(itemProviders:)` / `canPaste(_:)` — iOS 18 target,
  no availability gate needed.
- No server, protocol, or gateway change. No new dependency client.

## Development Approach

- **testing approach**: Regular (code first, then tests) — chosen during planning
- complete each task fully before moving to the next
- make small, focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
  - tests are not optional - they are a required part of the checklist
  - write unit tests for new functions/methods
  - write unit tests for modified functions/methods
  - add new test cases for new code paths
  - update existing test cases if behavior changes
  - tests cover both success and error scenarios
- **CRITICAL: all tests must pass before starting next task** - no exceptions
- **CRITICAL: update this plan file when scope changes during implementation**
- run tests after each change
- maintain backward compatibility

## Testing Strategy

- **unit tests (HermesKit, `swift test`)**: the pure provider→`PickedItem` loader (type-identifier
  selection, filename generation, non-image filtering, byte fidelity) and the new reducer case
  (`TestStore` + `$0.uuid = .incrementing`, capability gate).
- **iOS unit tests (`HermesMobileTests`)**: the `UITextView` subclass's paste routing —
  `canPaste` for an image provider, non-image providers forwarded to `super`, images diverted
  to the callback instead of the text buffer. UIKit is available in this target.
- **snapshot tests (`make snapshot`)**: the composer is being re-implemented, so its baselines
  are the regression net for placeholder, line growth, chip row, and toolbar layout. Re-record
  only the baselines that actually change (see Task 7 for the surgical recipe — **not**
  `make snapshot-record`, which wipes and re-records everything).
- **simulator verification (Task 8)**: the paste gesture itself cannot be unit-tested. Seed the
  simulator pasteboard with `xcrun simctl pbcopy`, drive the UI with AXe, confirm the **Paste**
  item appears for an image-only clipboard and produces a chip.
- no e2e/Playwright suite in this project.

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- update plan if implementation deviates from original scope
- keep plan in sync with actual work done

## Solution Overview

Four layers, each independently testable:

1. **`PastedImageLoader` (HermesKit, no UIKit)** — pure/async conversion of `[NSItemProvider]`
   into `[PickedItem]`: filter to providers carrying an image UTType, pick the best registered
   type identifier, load its original bytes (no re-encode, so a pasted JPEG stays a JPEG),
   derive `filename`/`mimeType`. `PhotoPickerPresenter.loadImage` is refactored onto the same
   helper so the two sources cannot drift and the existing path gains coverage.
2. **`ComposerTextView` (HermesMobile, UIKit)** — a `UIViewRepresentable` over a
   `PasteInterceptingTextView: UITextView`. The subclass widens `pasteConfiguration` to accept
   `UTType.image` (this is what makes iOS *offer* **Paste** for an image-only clipboard) and
   overrides `paste(itemProviders:)`: image providers go to an `onPasteImages` callback,
   everything else to `super`. Plain-text paste never enters the override and stays stock.
3. **`ChatFeature.attachmentsPasted([PickedItem])`** — appends staged attachments with injected
   ids, no-op when `attachmentsUnsupported`.
4. **Wiring** — `ComposerView` swaps `TextField` → `ComposerTextView` and gains an
   `onPasteImages` closure; `ChatView` forwards it to the store.

**Key design decisions and rationale**

- *Why replace the `TextField` at all* — SwiftUI exposes no hook for a non-text paste into a
  text field, and `.onPasteCommand` does not fire when a focused `UITextField` consumes the
  paste command. Intercepting requires being the text responder.
- *Why `pasteConfiguration` + `paste(itemProviders:)` rather than overriding `paste(_:)` and
  reading `UIPasteboard.general`* — the paste configuration is what drives whether UIKit
  enables the **Paste** menu item at all. Reading the general pasteboard from a `paste(_:)`
  override would work for ⌘V but the long-press menu would still not offer Paste for an
  image-only clipboard, which is the whole point of the issue.
- *Why the async provider load happens in the view's coordinator, not a reducer effect* — the
  implicit pasteboard grant is scoped to the paste command; hopping through the store first and
  reading the pasteboard from an effect risks losing it (and would need a `Sendable`/`Equatable`
  action carrying `NSItemProvider`, which it is not). The coordinator awaits the HermesKit
  loader and sends the finished `[PickedItem]`, so the only view-resident logic is one `await`.
- *Why one `attachmentsPasted([PickedItem])` action instead of N `attachmentAdded`* — a paste is
  one user act; a single action keeps the capability gate and ordering assertions in one place.
- *Why no size/count cap* — the picker path has none today; adding one only for paste would be
  an inconsistency. Noted under Post-Completion instead.

## Technical Details

**`PastedImageLoader` API (HermesKit)**

```
imageTypeIdentifier(in registeredTypeIdentifiers: [String]) -> String?   // pure
filename(suggestedName: String?, typeIdentifier: String, index: Int) -> String  // pure
pickedItem(from: NSItemProvider, fallbackName: String, index: Int) async -> PickedItem?
pickedItems(from: [NSItemProvider], fallbackName: String) async -> [PickedItem]
containsImage(_ providers: [NSItemProvider]) -> Bool                     // pure
```

- type-identifier choice: first registered identifier conforming to `UTType.image`, else nil
  (→ provider skipped). Mirrors `PhotoPickerPresenter.loadImage`.
- filename: `<suggestedName ?? fallbackName>.<ext>`, and for index > 0 a `-<n>` suffix
  (`pasted-image.png`, `pasted-image-2.png`) so a multi-image paste yields distinct chip labels.
  Picker path keeps `fallbackName: "photo"`; paste uses `"pasted-image"`.
- mime: `UTType(id)?.preferredMIMEType ?? "image/png"`; `kind` is always `.image`.
- ordering preserved; providers that fail to load are dropped (same as the picker).

**`PasteInterceptingTextView` behaviour**

| clipboard | UIKit route | result |
| --- | --- | --- |
| text only | stock `paste(_:)` | text inserted, unchanged from today |
| image only | `paste(itemProviders:)` | providers → `onPasteImages`, text buffer untouched |
| image + text | `paste(itemProviders:)` | images → callback, remainder → `super` |
| image, `attachmentsUnsupported` | `paste(itemProviders:)` | reducer drops the images (no chip, no banner) |

`canPaste(_ itemProviders:)` returns true when any provider carries an image, so the menu item
is enabled.

**`ComposerTextView` parity checklist** (what the SwiftUI `TextField` gives us today)

- `text: Binding<String>`, updated in `textViewDidChange` (drives `slashSuggestions`).
- placeholder `"Message"` — a `UILabel` shown while empty, `.secondaryLabel`.
- growth `1...6` lines: `intrinsicContentSize` from `sizeThatFits`, clamped between one and six
  line heights; `isScrollEnabled` flips on at the ceiling.
- Return submits: `shouldChangeTextIn` intercepts a lone `"\n"` → `onSubmit()`, returns `false`
  (matching `TextField(axis: .vertical) { }.onSubmit`).
- focus: `FocusState<Bool>.Binding` — `updateUIView` calls `becomeFirstResponder()` /
  `resignFirstResponder()`; `textViewDidBeginEditing`/`DidEndEditing` write back.
- style: `.preferredFont(forTextStyle: .body)`, `adjustsFontForContentSizeCategory = true`,
  clear background, `textContainerInset = .zero`, `lineFragmentPadding = 0`, default tint.
- input traits left at the values the `TextField` used (autocorrect/capitalisation/smart
  punctuation defaults) — parity now, not a behaviour change smuggled into this PR.

**Reducer**

```
case attachmentsPasted([PickedItem])
```

- `guard !state.attachmentsUnsupported else { return .none }`
- append `item.attachment(id: uuid())` per item, in order; `.none`.

## What Goes Where

- **Implementation Steps** (`[ ]`): all code, unit tests, snapshot baselines, simulator
  verification, docs.
- **Post-Completion** (no checkboxes): physical-device checks, hardware-keyboard ⌘V on iPad,
  and follow-ups deliberately out of scope.

## Implementation Steps

### Task 1: Add `PastedImageLoader` in HermesKit

**Files:**
- Create: `HermesKit/Sources/HermesKit/Models/PastedImageLoader.swift`
- Create: `HermesKit/Tests/HermesKitTests/PastedImageLoaderTests.swift`

- [ ] create `PastedImageLoader` with the pure helpers `imageTypeIdentifier(in:)`,
      `filename(suggestedName:typeIdentifier:index:)`, `containsImage(_:)` — no UIKit import,
      outside any `#if` guard so `swift test` covers them on macOS
- [ ] add the async `pickedItem(from:fallbackName:index:)` / `pickedItems(from:fallbackName:)`
      loading original bytes via `loadDataRepresentation(forTypeIdentifier:)`, always `kind: .image`
- [ ] write tests for `imageTypeIdentifier` (picks the image-conforming id; nil for a
      text-only provider; prefers an image id when mixed identifiers are registered)
- [ ] write tests for `filename` (extension from UTType, `-2` suffix on the second item,
      `suggestedName` honoured, fallback used when nil)
- [ ] write tests for `pickedItems` with synthetic `NSItemProvider`s: PNG + JPEG load in order
      with exact byte fidelity and correct mime; a plain-text provider is filtered out; an
      empty array returns `[]`
- [ ] run `script -q /dev/null swift test --package-path HermesKit` — must pass before Task 2

### Task 2: Route the photo picker through the shared loader

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Clients/AttachmentPickerClient.swift`

- [ ] replace `PhotoPickerPresenter.loadImage(from:)`'s inline type/name/mime logic with
      `PastedImageLoader.pickedItem(from:fallbackName: "photo", index:)`, preserving today's
      `suggestedName ?? "photo"` naming
- [ ] keep the change inside the existing `#if canImport(UIKit)` guard; no API change to
      `AttachmentPickerClient`
- [ ] write a test asserting the picker's naming contract still holds via the shared helper
      (`suggestedName: nil` → `photo.png`), so the refactor cannot silently rename picked files
- [ ] run `script -q /dev/null swift test --package-path HermesKit` — must pass before Task 3

### Task 3: Add the `attachmentsPasted` reducer case

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/ChatReductionTests.swift`

- [ ] add `case attachmentsPasted([PickedItem])` to `ChatFeature.Action` beside the other
      attachment actions (`:579-586`) with a doc comment explaining the paste source
- [ ] implement the reducer case near `.attachmentAdded` (`:1594`): no-op when
      `attachmentsUnsupported`, otherwise append `item.attachment(id: uuid())` in order
- [ ] write a `TestStore` test (`$0.uuid = .incrementing`): pasting two `PickedItem`s stages two
      attachments in order with incrementing ids
- [ ] write a `TestStore` test for the error/edge cases: an empty array changes nothing, and a
      paste while `attachmentsUnsupported == true` stages nothing
- [ ] run `script -q /dev/null swift test --package-path HermesKit` — must pass before Task 4

### Task 4: Build `ComposerTextView` (UITextView-backed input)

**Files:**
- Create: `HermesMobile/Sources/Features/Chat/ComposerTextView.swift`

- [ ] add `PasteInterceptingTextView: UITextView` — widen `pasteConfiguration` with
      `UTType.image`, override `canPaste(_:)` (true when any provider carries an image) and
      `paste(itemProviders:)` (images → `onPasteImages`, remainder → `super`)
- [ ] add the `ComposerTextView: UIViewRepresentable` + `Coordinator` implementing the parity
      checklist: text binding, `"Message"` placeholder label, 1–6 line growth via
      `intrinsicContentSize`/`sizeThatFits` with `isScrollEnabled` at the ceiling
- [ ] wire `FocusState<Bool>.Binding` (become/resign in `updateUIView`, write back from
      `textViewDidBeginEditing`/`textViewDidEndEditing`) and Return-key submit via
      `shouldChangeTextIn`
- [ ] have the coordinator `await PastedImageLoader.pickedItems(from:fallbackName: "pasted-image")`
      and hand the result to `onPasteImages: ([PickedItem]) -> Void`
- [ ] run `tuist generate` so the new source file is picked up by the app/test targets
- [ ] file is not yet referenced by any view — it is wired in Task 5; tests land in Task 6

### Task 5: Swap the composer input and forward pasted images

**Files:**
- Modify: `HermesMobile/Sources/Features/Chat/ComposerView.swift`
- Modify: `HermesMobile/Sources/Features/Chat/ChatView.swift`

- [ ] replace the `TextField` in `ComposerView.textComposer` (`:53`) with `ComposerTextView`,
      keeping the surrounding `VStack`/chips/toolbar layout untouched
- [ ] add `var onPasteImages: ([PickedItem]) -> Void = { _ in }` to `ComposerView` (defaulted,
      so the 8 snapshot call sites keep compiling unchanged)
- [ ] forward it from `ChatView` as `onPasteImages: { store.send(.attachmentsPasted($0)) }`
- [ ] verify the transcript's keyboard-dismiss path still resigns focus through the new
      representable (`composerFocused = false`)
- [ ] build the app target (`xcodebuild` / `make build`) — must compile before Task 6

### Task 6: Unit-test the paste interception

**Files:**
- Create: `HermesMobileTests/ComposerPasteTests.swift`

- [ ] write a test that `canPaste([imageProvider])` is `true` and `canPaste([textProvider])`
      is `false`
- [ ] write a test that `paste(itemProviders:)` with an image provider invokes `onPasteImages`
      with that provider and leaves `textView.text` unchanged
- [ ] write a test for the mixed clipboard: images go to the callback and non-image providers
      are forwarded to `super` (assert via a spy subclass / recorded forward)
- [ ] write a test for the error case: a provider registering no image type never reaches the
      callback
- [ ] run the iOS test target — must pass before Task 7

### Task 7: Re-record the affected snapshot baselines

**Files:**
- Modify: `HermesMobileTests/__Snapshots__/ComposerSnapshotTests/*.png` (as needed)
- Modify: `HermesMobileTests/__Snapshots__/ChatSnapshotTests/*.png` (as needed)
- Modify: `HermesMobileTests/__Snapshots__/ContextUsageSnapshotTests/*.png` (as needed)

- [ ] run `make snapshot` and list exactly which baselines fail (expected: composer-bearing ones)
- [ ] inspect each failure diff and confirm the delta is only the input-field re-implementation
      (placeholder position, line metrics) — investigate anything else before re-recording
- [ ] delete **only** the failing PNGs and run `make snapshot` twice (record, then assert) —
      do **not** run `make snapshot-record`, which wipes every baseline
- [ ] verify the idle/typing/recording/attachment-chip composer states still read correctly
- [ ] run `make snapshot` — must be clean before Task 8

### Task 8: Verify the paste gesture in the simulator

**Files:**
- Modify: `docs/plans/20260725-paste-images-into-composer.md` (record findings)

- [ ] boot the simulator, seed the pasteboard with a PNG via `xcrun simctl pbcopy`, open a chat
- [ ] long-press the message field and confirm **Paste** is offered for an image-only clipboard
      (this is the load-bearing assumption of the whole approach — if it fails, fall back to
      overriding `paste(_:)` + `canPerformAction(_:withSender:)` and record the change here)
- [ ] confirm the paste produces an attachment chip with a thumbnail, the text stays empty, and
      no *"Allow Paste"* banner appears
- [ ] confirm pasting text still inserts text, and send a pasted image end-to-end (chip →
      `image.attach_bytes` → user row with thumbnail)
- [ ] confirm keyboard focus, Return-key submit, 6-line growth, and the slash-suggestion panel
      still behave as before
- [ ] record the outcome (and any deviation) in this plan under Progress Tracking

### Task 9: Verify acceptance criteria

- [ ] verify all requirements from Overview are implemented (native field paste, image-only
      scope, no paperclip menu entry)
- [ ] verify edge cases: multi-image paste, mixed image+text clipboard, paste while
      `attachmentsUnsupported`, paste with a non-image clipboard, paste into an empty vs
      non-empty composer
- [ ] run full test suite: `script -q /dev/null swift test --package-path HermesKit`
- [ ] run snapshot suite: `make snapshot`
- [ ] verify no regression in the existing attachment flows (photos / camera / files)

### Task 10: [Final] Update documentation

- [ ] update `CLAUDE.md` — the composer input is now `UITextView`-backed
      (`ComposerTextView`); paste routing (`pasteConfiguration` + `paste(itemProviders:)`,
      images diverted to `.attachmentsPasted`, everything else stock) and the shared
      `PastedImageLoader` used by both the picker and paste
- [ ] update `README.md` if the attachment feature is described there
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion

*Items requiring manual intervention or external systems - no checkboxes, informational only*

**Manual verification**:
- physical-device paste from Safari (HEIC/JPEG providers) and from the Photos app.
- iPad with a hardware keyboard: ⌘V should route through the same `paste(itemProviders:)`.
- VoiceOver pass over the re-implemented input: the placeholder must still be announced and
  the field reachable, matching the old `TextField`.
- Dynamic Type at accessibility sizes: confirm the 1–6 line clamp scales with the body font.
- a very large pasted image (multi-MB screenshot) — today neither picker nor paste caps size;
  watch upload time and memory, and open a separate issue if it needs a cap.

**Deliberately out of scope** (candidates for follow-up issues):
- pasting PDFs / arbitrary files into the field (`Kind.infer` already supports it; only the
  paste configuration and loader filter would need widening).
- a size or count cap on staged attachments, applied uniformly across picker and paste.
- drag-and-drop of an image onto the composer (iPad) — a different UIKit interaction.
