# Paste images from the clipboard into the chat composer (#54)

## Overview

GitHub issue #54 — *"Allow to paste images from clipboard into chat"*. Today the only way to
get an image into a message is the paperclip menu (Photo Library / Camera / Files). The
natural gesture — copy a screenshot, long-press the message field, tap **Paste** — does
nothing: the composer is a SwiftUI `TextField(axis: .vertical)`, which never claims `paste(_:)`
for a non-text clipboard, so for an image-only clipboard iOS does not even offer the **Paste**
item.

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
must reproduce today's behaviour exactly: placeholder, 1–6 line growth, and Return-key
submit. (The `@FocusState` binding it also carried turned out to be dead in both directions and
was removed in the review pass — see the Task 8 notes and the `ComposerTextView` doc comment.)

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
- `UIResponder.canPerformAction(_:withSender:)` / `paste(_:)` / `UIPasteboard` — iOS 18 target,
  no availability gate needed. (The originally-planned `UIPasteConfiguration` / `canPaste(_:)` /
  `paste(itemProviders:)` trio turned out to be inert for a `UITextView`'s edit menu — see the
  Task 8 notes.)
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
- **iOS unit tests (`HermesMobileTests`)**: the `UITextView` subclass's paste routing, driven
  through an injected `UIPasteboard.withUniqueName()` — `canPerformAction(paste:)` for an image
  clipboard, image-free clipboards left to UIKit's verdict, images diverted to the callback
  instead of the text buffer, plus the coordinator's provider→`PickedItem` hop. UIKit is
  available in this target.
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

1. **`PickedImageLoader` (HermesKit, no UIKit)** — pure/async conversion of `[NSItemProvider]`
   into `[PickedItem]`: filter to providers carrying an image UTType, pick the best registered
   type identifier, load its original bytes (no re-encode, so a pasted JPEG stays a JPEG),
   derive `filename`/`mimeType`. `PhotoPickerPresenter.loadImage` is refactored onto the same
   helper so the two sources cannot drift and the existing path gains coverage.
2. **`ComposerTextView` (HermesMobile, UIKit)** — a `UIViewRepresentable` over a
   `ComposerInputTextView: UITextView`. The subclass overrides
   `canPerformAction(_:withSender:)` to claim `paste(_:)` whenever `UIPasteboard.hasImages`
   (this is what makes iOS *offer* **Paste** for an image-only clipboard) and overrides
   `paste(_:)`: the clipboard's image providers go to an `onPasteImages` callback, everything
   else to `super`. Plain-text paste keeps UIKit's own verdict and stock insertion.
   ⚠️ The originally-planned `pasteConfiguration` + `canPaste(_:)` + `paste(itemProviders:)`
   design was **disproved in Task 8** — `UITextView` never consults `canPaste(_:)` when
   building its edit menu, so **Paste** never appeared. See the Task 8 notes.
3. **`ChatFeature.attachmentsPasting` / `.attachmentsPasted(PickedBatch)`** — the pair brackets
   the async load: `attachmentsPasting` is sent synchronously from `paste(_:)` and holds
   `pendingPasteCount` (hence `canSend`) down, `attachmentsPasted` appends the batch's staged
   attachments with injected ids, reports `droppedCount`, and releases the gate. No-op when
   `attachmentsUnsupported`, and ignored outright by a chat that never sent the
   `attachmentsPasting` half (the batch belongs to a torn-down chat — see the **Reducer** block).
4. **Wiring** — `ComposerView` swaps `TextField` → `ComposerTextView` and gains an
   `onPasteImages` closure; `ChatView` forwards it to the store. `ComposerView`'s existing
   `attachmentsSupported` flag is threaded into the text view too, so the **Paste** claim is
   capability-gated exactly like the paperclip (Task 9).

**Key design decisions and rationale**

- *Why replace the `TextField` at all* — SwiftUI exposes no hook for a non-text paste into a
  text field, and `.onPasteCommand` does not fire when a focused `UITextField` consumes the
  paste command. Intercepting requires being the text responder.
- *Why `canPerformAction(_:withSender:)` + `paste(_:)` over `UIPasteboard`, not
  `pasteConfiguration` + `paste(itemProviders:)`* — `UITextView` builds its edit menu from
  `canPerformAction(_:withSender:)` and never consults `canPaste(_:)`, so only the
  `canPerformAction` route makes UIKit *enable* **Paste** for an image-only clipboard, which is
  the whole point of the issue. The plan originally assumed the opposite; Task 8 measured it in
  the simulator (`pasteConfiguration` route → no **Paste** item; `paste(_:)` route → one) and
  the implementation switched.
- *Why `canPerformAction` probes `hasImages` and never `itemProviders`* — `hasImages` is
  metadata and raises no *"Allow Paste"* banner, whereas reading providers while merely
  *building the menu* would. Providers are read only inside `paste(_:)`, under the implicit
  grant of the user tapping **Paste**.
- *Why the async provider load happens in the view's coordinator, not a reducer effect* — the
  implicit pasteboard grant is scoped to the paste command; hopping through the store first and
  reading the pasteboard from an effect risks losing it (and would need a `Sendable`/`Equatable`
  action carrying `NSItemProvider`, which it is not). The coordinator awaits the HermesKit
  loader and sends the finished `PickedBatch`, so the only view-resident logic is one `await`.
- *Why one `attachmentsPasted(PickedBatch)` action instead of N `attachmentAdded`* — a paste is
  one user act; a single action keeps the capability gate and ordering assertions in one place.
- *Why no size/count cap* — the picker path has none today; adding one only for paste would be
  an inconsistency. Noted under Post-Completion instead. **Superseded for images**: bytes past
  `maxAttachmentBytes` are re-encoded rather than staged into a certain failure, in the *shared*
  loader (and, since the fifth review pass, in `rescuedImageItem` for the camera and Files too),
  so every image source behaves identically. A cap on PDFs/files remains out of scope — see the
  Post-Completion follow-up, since the same frame limit applies to them.

## Technical Details

**`PickedImageLoader` API (HermesKit)**

*(As shipped after the third and fourth review passes — the loader was renamed from
`PastedImageLoader` and moved to `Clients/` in the smells pass, since the photo picker is its
other caller.)*

```
imageTypeIdentifier(in registeredTypeIdentifiers: [String]) -> String?               // pure, public
filename(suggestedName: String?, fallbackName: String, typeIdentifier: String, index: Int) -> String
mimeType(for typeIdentifier: String) -> String                                        // pure
transcodedImage(from: Data, pixelLimit: Int = …, byteLimit: Int = …) -> (Data, String)?
pickedItem(from: NSItemProvider, fallbackName: String, index: Int,
           timeout: Duration = clipboardLoadTimeout, byteLimit: Int = maxAttachmentBytes,
           pixelLimit: Int = maxSourcePixels) async -> PickedItem?
pickedItems(from: [NSItemProvider], fallbackName: String,
            timeout: Duration = clipboardLoadTimeout) async -> PickedBatch            // public
pickedBatch(from:fallbackName:timeout:byteLimit:pixelLimit:batchLimit:) async -> PickedBatch
rescuedImageItem(_ item: PickedItem, byteLimit: Int = …, pixelLimit: Int = …) async -> PickedItem?
declaredPixelCount(_ properties: [CFString: Any]) -> Int?                             // pure
isWithinPixelLimit(_ properties: [CFString: Any], pixelLimit: Int) -> Bool            // pure
declaresDecodableSize(_ data: Data, pixelLimit: Int = maxSourcePixels) -> Bool
```

(A `containsImage(_:)` predicate existed for the abandoned `canPaste(_:)` override and was
removed in Task 9 — the shipped `paste(_:)` filters with `imageTypeIdentifier(in:)` directly.
`pixelLimit`/`byteLimit` are test seams; production always takes the defaults.)

- type-identifier choice: a **three-pass scan, honouring the provider's own order within each
  tier** — (1) the first identifier that is both agent-supported and **compressed**
  (`compressedImageExtensions` = png/jpg/jpeg/gif/webp), (2) the first otherwise-supported one
  (`serverSupportedImageExtensions`, a mirror of `cli.py:_IMAGE_EXTENSIONS`: tiff/tif/bmp/svg/ico),
  (3) the first conforming to `UTType.image`, else nil (→ provider skipped). Every part is
  load-bearing. `registeredTypeIdentifiers` is fidelity order, so imposing a global preference
  list flattens an animated GIF into the `public.png` still registered beside it and re-encodes a
  JPEG into a several-times-larger PNG. Tier 1 before 2 keeps a Mac-copied image — whose
  pasteboard lists `public.tiff` first (`NSPasteboardTypeTIFF`, bridged verbatim by Universal
  Clipboard) — from staging as a ~36 MB uncompressed TIFF while a `public.png` sat registered
  beside it. Tier 2 before 3 exists because `image.attach_bytes` derives the stored extension
  from the `filename` we send (`_sniff_image_ext` returns `Path(filename).suffix` whenever there
  is one — the magic-byte table is unreachable for a named file) and rejects anything outside
  `_IMAGE_EXTENSIONS`, which has no `.heic`, the identifier iOS providers commonly register first.
- **re-encode of last resort**, on **two** triggers: nothing supported registered at all (a
  HEIC-only clipboard, which the identifier choice cannot rescue) **or** loaded bytes past
  `maxAttachmentBytes` (a sole-registered `public.tiff` is a real Universal Clipboard shape, and
  a big one base64s into 50-80 MB for a certain 4018). `pickedItem` then runs the bytes through
  `transcodedImage(from:)` — ImageIO on a detached task, thumbnail API so the source's EXIF
  orientation is applied, **opacity read from the source's `kCGImagePropertyHasAlpha`** (the
  decoded thumbnail lies for HEIC), JPEG for an opaque image / PNG when there is alpha, stepping
  4096 → 2048 → 1024 px until the encode fits the budget. The source's *declared* dimensions are
  checked before any decode (`maxSourcePixels`, 50 MP; an absent declaration is a refusal).
  Bytes ImageIO cannot decode are dropped, not staged: a `pasted-image.heic` chip can only end
  in a 4016 no retry can fix.
- each provider load is **deadline-bounded, per source**: `clipboardLoadTimeout` (15s) for the
  clipboard — nothing obliges `loadDataRepresentation` to ever call its completion handler, and
  an unbounded wait wedged the composer's paste chain for the lifetime of the process — and
  `pickerLoadTimeout` (120s) for `PHPickerResult` providers, which perform the iCloud download
  *inside* `loadDataRepresentation` and blew the clipboard's budget on a weak connection.
- what a picker **lost** is reported: `PickedBatch { items, droppedCount }` (all three picker
  closures) drives `.attachmentsDropped`; a cancel is the empty batch (no items *and* no drops)
  and stays silent.
- filename: `<suggestedName ?? fallbackName>.<ext>`, and for index > 0 a `-<n>` suffix
  (`pasted-image.png`, `pasted-image-2.png`) so a multi-image paste yields distinct chip labels.
  The suffix applies **only** when falling back — a provider-suggested name is used verbatim, so
  the picker never renames `IMG_0042.jpeg` (see Task 2 notes).
  Picker path keeps `fallbackName: "photo"`; paste uses `"pasted-image"`. A suggested name is
  sanitised first (last path component, no leading dot, no doubled *or stale* image extension —
  a re-encoded `photo.heic` becomes `photo.jpeg`, never `photo.heic.jpeg`) and finally clamped to
  `maxFilenameBaseCharacters` — any app on the clipboard chooses it and it reaches the agent
  verbatim, in the same frame as the base64 payload the byte budget is sized against.
- mime: `UTType(id)?.preferredMIMEType ?? "image/png"`; `kind` is always `.image`.
- ordering preserved; providers that fail to load are dropped (same as the picker), and the
  count of the drops rides back on `PickedBatch.droppedCount` for **every** source — the paste
  path used to report only the all-or-nothing case, so a three-image paste that yielded two
  looked exactly like a two-image paste.
- **the byte budget is the transport's, not the handler's** (external review, iteration 5):
  `image.attach_bytes` travels base64'd inside one WebSocket text frame, and
  `hermes_cli/web_server.py` builds its `uvicorn.Config` without `ws_max_size` — so uvicorn's
  16 MiB default kills the frame (close 1009) at ~12 MiB of decoded bytes, well before the
  agent's own 25 MiB `_ATTACH_BYTES_MAX_BYTES` is ever consulted. `maxAttachmentBytes` is
  therefore 11 MiB (verified against the sibling `hermes-agent` clone), not the 24 MiB aimed at
  the handler's cap; images between the two staged as valid and then took the socket down.
- **two pixel guards, deliberately different.** `isWithinPixelLimit` gates a decode we are about
  to perform, so an undeclared size is a refusal; `declaresDecodableSize` gates bytes we are
  passing through untouched, so an unreadable header (`.svg`) passes. The pass-through one runs
  on **every** image — the guard used to live only inside the re-encode, so a supported,
  under-budget PNG declaring 40000×40000 was staged and then decoded by `UIImage(data:)` for its
  chip. Both go through `declaredPixelCount`, which **saturates** rather than trapping: the
  operands come from an untrusted header and `width * height` crashed on overflow.
- **an aggregate batch budget** (`maxBatchBytes`, 128 MiB): `loadDataRepresentation` materialises
  a whole payload with no way to see its size first, so a 100-photo pick could accumulate
  hundreds of megabytes before the first upload. The budget is checked *before* the next load and
  the remainder is reported as dropped rather than silently missing.
- **the two provider-less sources take the same contract** via `rescuedImageItem`: Files hands
  over the on-disk original (routinely a HEIC → 4016, or a Mac iCloud Drive TIFF past the frame
  budget) and the camera's `jpegData(compressionQuality:)` bounds no byte count. Both used to
  bypass the loader entirely, so the same picture attached fine from Photos and never from Files.
- **`.attachmentsPasting` / `.attachmentsPasted` bracket the load** and hold `pendingPasteCount`
  (hence `canSend`) down. A paste is the only attachment source with no modal sheet over it, so
  Send stays reachable while the providers load; a submit that won the race shipped the message
  without its image, which then reappeared orphaned in the next draft. A counter, not a flag —
  two fast pastes chain in the coordinator and both are outstanding at once. The counter is also
  the **pairing token** that keeps a paste in the chat it was made in: the load is the one
  attachment source outside TCA's effect lifecycle (the pickers are `.run` effects `ifLet`
  cancels on teardown), so a batch delivered after the live-chat slot was replaced would stage
  into an unrelated conversation — `attachmentsPasted` therefore ignores a batch whose
  `attachmentsPasting` half this state never saw.

**`ComposerInputTextView` behaviour** (as shipped — see the Task 8 notes for why the
`paste(itemProviders:)` column below became `paste(_:)`)

| clipboard | UIKit route | result |
| --- | --- | --- |
| text only | `paste(_:)` → `super` | text inserted, unchanged from today |
| image only | `paste(_:)` | providers → `onPasteImages`, text buffer untouched, `super` never called |
| image + text in one item (Safari *Copy Image*) | `paste(_:)` | images → callback; **no** `super`, so the page URL never types itself into the message |
| image item **and** a separate text item | `paste(_:)` | images → callback, and `super` still pastes the text |
| image + a non-image, non-text item (e.g. a PDF) | `paste(_:)` → `super` | image → callback; the leftover provider goes to stock handling (which inserts nothing) |
| PDF / any other file | `paste(_:)` → `super` | stock; images-only scope (#54) |
| image, `attachmentsUnsupported` | — | **Paste** is not claimed at all; an image-free clipboard still pastes its text |

`canPerformAction(_:withSender:)` claims `paste(_:)` whenever `UIPasteboard.hasImages` **and**
`acceptsPastedImages`, so the menu item is enabled; every other action and every image-free
clipboard keeps UIKit's verdict. `hasImages` is a metadata probe (no *"Allow Paste"* banner);
the providers themselves are read only inside `paste(_:)`, under the implicit grant of the user
tapping **Paste**.

`acceptsPastedImages` mirrors `!attachmentsUnsupported`, threaded down from `ComposerView`'s
existing `attachmentsSupported` flag (Task 9). It is the same capability gate that hides the
paperclip: with no upload capability the field is byte-identical to a stock `UITextView`, so
iOS never offers a **Paste** whose only outcome would be the reducer's silent drop. The reducer
guard stays as the backstop.

**`ComposerTextView` parity checklist** (what the SwiftUI `TextField` gives us today)

- `text: Binding<String>`, updated in `textViewDidChange` (drives `slashSuggestions`).
- placeholder `"Message"` — a `UILabel` shown while empty, **`.placeholderText`** (Task 7
  caught `.secondaryLabel` as a visible parity regression).
- growth `1...6` lines: the representable's `sizeThatFits(_:uiView:context:)` →
  `clampedHeight(forWidth:)`, clamped between one and six line heights, where a line is
  `font.lineHeight + font.leading`. `clampedHeight` is **pure measurement**; the
  `isScrollEnabled` flip happens in `layoutSubviews`, never in SwiftUI's sizing pass.
- Return submits: `shouldChangeTextIn` intercepts a lone `"\n"` → `onSubmit()`, returns `false`
  (matching `TextField(axis: .vertical) { }.onSubmit`). Hardware **Shift+Return** is routed
  around that interception by a `keyCommands` entry which flags its own insertion (third review
  pass); dictation's "new line" is indistinguishable at this layer and still submits.
- focus: **none**. A representable gets no `.focused(_:)` — it *is* the focusable view — so a
  `@FocusState` binding here never latches, and reading it in `updateUIView` only ever resigns
  the keyboard (it did: the composer lost the keyboard after one keystroke). Dismissal is
  `CollectionTranscriptView`'s `keyboardDismissMode = .interactive`.
- style: `.preferredFont(forTextStyle: .body)`, `adjustsFontForContentSizeCategory = true`,
  clear background, `textContainerInset = .zero`, `lineFragmentPadding = 0`, default tint.
- input traits left at the values the `TextField` used (autocorrect/capitalisation/smart
  punctuation defaults) — parity now, not a behaviour change smuggled into this PR.

**Reducer**

```
case attachmentsPasting
case attachmentsPasted(PickedBatch)
case attachmentsDropped(count: Int)
```

- `.attachmentsPasting` (sent synchronously from `paste(_:)`, before the first suspension point)
  increments `pendingPasteCount`; `.attachmentsPasted` decrements it on **every** terminal
  branch, so the gate cannot leak.
- `guard state.pendingPasteCount > 0 else { return .none }` — the batch belongs to a chat that
  no longer occupies the live-chat slot (final review pass). The load runs in the view
  coordinator's own `Task`, outside the effect lifecycle `ifLet` cancels, so a slot replaced
  mid-load (idle pop + open, a #32 push tap, a branch creation) would otherwise stage the image
  into an unrelated conversation and upload it there on Send.
- `guard !state.attachmentsUnsupported else { return .none }` (silent: that flip banners its own
  explanation).
- an **empty** batch sets `errorBanner` — the menu promised the paste and the user tapped it, so
  it must not end in silence (second review pass).
- otherwise clear `errorBanner` and append `item.attachment(id: uuid())` per item, in order,
  then banner `batch.droppedCount` if a multi-image paste only partly survived; `.none`.
- `.attachmentsDropped(count:)` is the picker half of the same rule (third review pass).

## What Goes Where

- **Implementation Steps** (`[ ]`): all code, unit tests, snapshot baselines, simulator
  verification, docs.
- **Post-Completion** (no checkboxes): physical-device checks, hardware-keyboard ⌘V on iPad,
  and follow-ups deliberately out of scope.

## Implementation Steps

### Task 1: Add `PickedImageLoader` in HermesKit

**Files:**
- Create: `HermesKit/Sources/HermesKit/Clients/PickedImageLoader.swift`
- Create: `HermesKit/Tests/HermesKitTests/PickedImageLoaderTests.swift`

- [x] create `PickedImageLoader` with the pure helpers `imageTypeIdentifier(in:)`,
      `filename(suggestedName:fallbackName:typeIdentifier:index:)`, `containsImage(_:)`,
      `mimeType(for:)` — no UIKit import, outside any `#if` guard so `swift test` covers them
      on macOS
- [x] add the async `pickedItem(from:fallbackName:index:)` / `pickedItems(from:fallbackName:)`
      loading original bytes via `loadDataRepresentation(forTypeIdentifier:)`, always `kind: .image`
- [x] write tests for `imageTypeIdentifier` (picks the image-conforming id; nil for a
      text-only provider; prefers an image id when mixed identifiers are registered)
- [x] write tests for `filename` (extension from UTType, `-2` suffix on the second item,
      `suggestedName` honoured, fallback used when nil)
- [x] write tests for `pickedItems` with synthetic `NSItemProvider`s: PNG + JPEG load in order
      with exact byte fidelity and correct mime; a plain-text provider is filtered out; an
      empty array returns `[]`
- [x] run `script -q /dev/null swift test --package-path HermesKit` — must pass before Task 2
      (960 tests, all green)

**Task 1 notes**

- [decision] `filename` takes an explicit `fallbackName:` parameter — the plan's signature
  omitted it while its own rule (`<suggestedName ?? fallbackName>`) required it.
- [decision] the async `pickedItem` / `pickedItems` are `@MainActor`: `NSItemProvider` is not
  `Sendable` (no `NS_SWIFT_SENDABLE` in the SDK header), so a nonisolated `async` signature
  would be uncallable from the two main-actor call sites (photo-picker delegate, paste
  coordinator) under Swift 6 language mode. The pure helpers stay nonisolated.
- [decision] an empty / whitespace-only `suggestedName` is treated as absent (it would
  otherwise yield a bare `.png` filename); added `mimeType(for:)` as a named helper so the
  `"image/png"` default lives in one place.
- [deviation] the picker's old `?? UTType.image.identifier` fallback is dropped: loading an
  unregistered identifier always fails, so `imageTypeIdentifier` returning `nil` (provider
  skipped) is the same outcome without the wasted round-trip. Documented in the source.

### Task 2: Route the photo picker through the shared loader

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Clients/AttachmentPickerClient.swift`

- [x] replace `PhotoPickerPresenter.loadImage(from:)`'s inline type/name/mime logic with
      `PickedImageLoader.pickedItem(from:fallbackName: "photo", index:)`, preserving today's
      `suggestedName ?? "photo"` naming
- [x] keep the change inside the existing `#if canImport(UIKit)` guard; no API change to
      `AttachmentPickerClient`
- [x] write a test asserting the picker's naming contract still holds via the shared helper
      (`suggestedName: nil` → `photo.png`), so the refactor cannot silently rename picked files
- [x] run `script -q /dev/null swift test --package-path HermesKit` — must pass before Task 3
      (963 tests, all green)

**Task 2 notes**

- [decision] the delegate calls `PickedImageLoader.pickedItems(from: results.map(\.itemProvider),
  fallbackName: "photo")` rather than looping over `pickedItem(…index:)` by hand — `pickedItems`
  *is* that loop (same per-item call, same index), so this keeps one code path and drops the
  hand-rolled accumulation. `loadImage(from:)` is deleted.
- [deviation] **`PickedImageLoader.filename` changed (Task 1 helper)**: the `-<n>` suffix is now
  applied **only to the fallback name**, never to a provider-suggested one. As written in Task 1
  it suffixed by index unconditionally, which renamed the picker's files
  (`IMG_0042.jpeg` → `IMG_0042-2.jpeg`) on a multi-select — exactly the silent rename this task
  exists to prevent. Multi-image *paste* is unaffected (pasteboard providers carry no
  `suggestedName`, so `pasted-image.png` / `pasted-image-2.png` still holds). Covered by
  `filenameNeverSuffixesASuggestedName`.
- [deviation] one intentional picker behaviour change remains: two *unnamed* picks used to
  collide on `photo.png`; they are now `photo.png` / `photo-2.png`. Strictly an improvement
  (distinct chip labels), pinned by `photoPickerDisambiguatesRepeatedUnnamedPicks`.
- [decision] the refactor lives entirely inside `#if canImport(UIKit)`, which macOS `swift test`
  does not compile, so it was additionally verified with `tuist generate` + a full
  `xcodebuild` iOS-Simulator build (exit 0) on top of the package suite.

### Task 3: Add the `attachmentsPasted` reducer case

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/ChatReductionTests.swift`

- [x] add `case attachmentsPasted([PickedItem])` to `ChatFeature.Action` beside the other
      attachment actions (`:579-586`) with a doc comment explaining the paste source
- [x] implement the reducer case near `.attachmentAdded` (`:1594`): no-op when
      `attachmentsUnsupported`, otherwise append `item.attachment(id: uuid())` in order
- [x] write a `TestStore` test (`$0.uuid = .incrementing`): pasting two `PickedItem`s stages two
      attachments in order with incrementing ids
- [x] write a `TestStore` test for the error/edge cases: an empty array changes nothing, and a
      paste while `attachmentsUnsupported == true` stages nothing
- [x] run `script -q /dev/null swift test --package-path HermesKit` — must pass before Task 4
      (967 tests, all green)

**Task 3 notes**

- [decision] the action is placed directly after `.attachmentAdded` (not after
  `.attachmentsUnsupportedDetected`) so the four attachment *sources* stay adjacent, and the
  reducer case sits immediately after `.attachmentAdded` for the same reason.
- [decision] the `attachmentsUnsupported` drop is silent — no `errorBanner`. The paperclip
  affordance is hidden in that mode, but the system paste menu is not ours to hide, so a paste
  can still arrive; surfacing an error for a gesture the user may not have meant as an attach
  would be noise, and a staged chip that could never upload would be worse.
  ⚠️ **Premise partly revised in Task 9**: with the Task 8 `canPerformAction` mechanism the menu
  item *is* ours to withhold, so the view no longer claims **Paste** in that mode. The reducer
  guard stays exactly as written — it is now the backstop, not the only gate.
- [decision] added a third test beyond the plan's two (`pastingImagesAppendsAfterAlreadyStaged
  Attachments`) — the reducer *appends*, and only a non-empty starting `attachments` array
  pins that against a future `state.attachments = ` regression.

### Task 4: Build `ComposerTextView` (UITextView-backed input)

**Files:**
- Create: `HermesMobile/Sources/Features/Chat/ComposerTextView.swift`

- [x] ⚠️ (superseded — see Task 8) add `ComposerInputTextView: UITextView` — widen
      `pasteConfiguration` with `UTType.image`, override `canPaste(_:)` (true when any provider
      carries an image) and `paste(itemProviders:)` (images → `onPasteImages`, remainder →
      `super`)
- [x] add the `ComposerTextView: UIViewRepresentable` + `Coordinator` implementing the parity
      checklist: text binding, `"Message"` placeholder label, 1–6 line growth via
      `intrinsicContentSize`/`sizeThatFits` with `isScrollEnabled` at the ceiling
- [x] ⚠️ (superseded — see Task 8 and the review pass) wire `FocusState<Bool>.Binding`
      (become/resign in `updateUIView`, write back from
      `textViewDidBeginEditing`/`textViewDidEndEditing`) and Return-key submit via
      `shouldChangeTextIn` — the focus half was removed outright; Return-key submit shipped
- [x] have the coordinator `await PickedImageLoader.pickedItems(from:fallbackName: "pasted-image")`
      and hand the result to `onPasteImages: ([PickedItem]) -> Void`
- [x] run `tuist generate` so the new source file is picked up by the app/test targets
- [x] file is not yet referenced by any view — it is wired in Task 5; tests land in Task 6
      (verified by an `xcodebuild` iOS-Simulator build, exit 0, plus the 967-test HermesKit suite)

**Task 4 notes**

- [deviation] `canPaste(_:)` returns `containsImage(providers) || super.canPaste(providers)`,
  not a bare `containsImage`. UIKit consults `canPaste` to enable the **Paste** menu item once a
  `pasteConfiguration` exists, so returning `false` for a text-only clipboard risks greying out
  Paste for plain text — a regression in the common case, bought only to satisfy an assertion.
  **Task 6's first checkbox should be adjusted**: assert `canPaste([imageProvider]) == true`
  (the load-bearing half) and that a non-image provider's verdict is simply `super`'s, i.e.
  unchanged from stock, rather than a hard `false`.
- [decision] `pasteConfiguration` is widened by *adding* `UTType.image` to the text view's own
  configuration rather than assigning a fresh one — replacing it would drop the text types and
  break plain-text paste.
- [decision] growth is implemented through the representable's `sizeThatFits(_:uiView:context:)`
  (the `SelectableText` convention already used in this target) delegating to a
  `clampedSize(forWidth:)` helper on the text view, instead of overriding
  `intrinsicContentSize`: SwiftUI drives layout here, and one sizing hook keeps the
  `isScrollEnabled` flip in a single place (assigned only on a real change, since it
  invalidates layout).
- [decision] the placeholder `UILabel` is frame-positioned in `layoutSubviews` rather than with
  auto layout — a `UITextView` is a scroll view, and edge constraints on a subview feed its
  content-size inference.
- [decision] the text view carries `accessibilityLabel = placeholder` (and the label itself is
  `isAccessibilityElement = false`), matching how a `UITextField` announces its prompt — the
  old `TextField` got that for free.
- [decision] the coordinator drops an empty load result instead of sending `onPasteImages([])`,
  and `paste(itemProviders:)` calls `super` only when there are non-image providers.
- ⚠️ **Superseded by Task 8.** The `pasteConfiguration` + `canPaste(_:)` +
  `paste(itemProviders:)` design in the first, second and last bullets above **does not make
  iOS offer Paste** and was replaced by `canPerformAction(_:withSender:)` + `paste(_:)`. The
  sizing, placeholder, font and accessibility decisions are unaffected; the focus decision was
  additionally **fixed** in Task 8 (it resigned the keyboard after one keystroke).

### Task 5: Swap the composer input and forward pasted images

**Files:**
- Modify: `HermesMobile/Sources/Features/Chat/ComposerView.swift`
- Modify: `HermesMobile/Sources/Features/Chat/ChatView.swift`

- [x] replace the `TextField` in `ComposerView.textComposer` (`:53`) with `ComposerTextView`,
      keeping the surrounding `VStack`/chips/toolbar layout untouched
- [x] add `var onPasteImages: ([PickedItem]) -> Void = { _ in }` to `ComposerView` (defaulted,
      so the 8 snapshot call sites keep compiling unchanged)
- [x] forward it from `ChatView` as `onPasteImages: { store.send(.attachmentsPasted($0)) }`
- [x] verify the transcript's keyboard-dismiss path still resigns focus through the new
      representable (`composerFocused = false`)
- [x] build the app target (`xcodebuild` / `make build`) — must compile before Task 6
      (exit 0, plus `build-for-testing -only-testing:HermesMobileTests` exit 0 and the
      967-test HermesKit suite green)

**Task 5 notes**

- [decision] `onPasteImages` is declared **last** in `ComposerView`, after
  `onRemoveAttachment`. Swift's memberwise init follows declaration order, so appending is
  what keeps the 8 existing snapshot call sites compiling untouched.
- [decision] `placeholder:` / `lineLimit:` are passed **explicitly** at the call site even
  though `ComposerTextView` defaults them to `"Message"` / `1 ... 6`. The parity contract
  belongs where the old `TextField("Message", …).lineLimit(1 ... 6)` was readable, not hidden
  in the representable's defaults.
- [decision] keyboard-dismiss verification is by inspection, not a new test: `composerFocused`
  is **never written** by `ChatView` (grep confirms the only writes are the binding hand-off at
  `:37`). Dismissal is entirely `.scrollDismissesKeyboard(.interactively)` on the transcript,
  which resigns the `UITextView`'s first-responder status; `Coordinator.textViewDidEndEditing`
  mirrors that back as `focused.wrappedValue = false`, and `updateUIView`'s `view.window != nil`
  guard stops an off-screen view from re-claiming focus. Same one-way-then-write-back contract
  the `TextField`'s `.focused(_:)` had.
- [deviation] `HermesKit/Package.resolved` was churned by the resolve step (dropping the
  `swift-snapshot-testing` pin, which is declared in `Project.swift` not `Package.swift`) and
  was reverted — unrelated to this change, and the pin is needed by the snapshot target.

### Task 6: Unit-test the paste interception

**Files:**
- Create: `HermesMobileTests/ComposerTextViewTests.swift`
- Modify: `HermesMobile/Sources/Features/Chat/ComposerTextView.swift` (test seam — see notes)

- [x] ⚠️ (superseded — see Task 8) write a test that `canPaste([imageProvider])` is `true`, and
      that a non-image clipboard's verdict is `super`'s — unchanged from stock UIKit behaviour
      (see the Task 4 deviation: the override is `containsImage || super.canPaste`, never a hard
      `false`)
- [x] ⚠️ (superseded — see Task 8) write a test that `paste(itemProviders:)` with an image
      provider invokes `onPasteImages` with that provider and leaves `textView.text` unchanged
- [x] ⚠️ (superseded — see Task 8) write a test for the mixed clipboard: images go to the
      callback and non-image providers are forwarded to `super` (assert via a spy subclass /
      recorded forward)
- [x] write a test for the error case: a provider registering no image type never reaches the
      callback
- [x] run the iOS test target — must pass before Task 7
      (`-only-testing:HermesMobileTests/ComposerTextViewTests` → 6 tests, 0 failures; plus the
      967-test HermesKit suite green)

**Task 6 notes**

- [deviation] the first checkbox was **relaxed** from "`canPaste([textProvider])` is `false`".
  Task 4 deliberately implemented `canPaste(_:)` as `containsImage(providers) ||
  super.canPaste(providers)` — a hard `false` for a text-only clipboard risks greying out
  **Paste** for plain text. `testCanPasteLeavesANonImageClipboardToStockBehaviour` therefore
  asserts the verdict *equals* a stock `UITextView`'s (carrying the same `pasteConfiguration`,
  which stands in for `super`), while `testCanPasteIsTrueForAnImageProvider` pins the
  load-bearing half.
- [decision] `ComposerInputTextView` lost its `final` and the `super.paste(itemProviders:)`
  call moved behind an overridable `pasteToSuper(itemProviders:)` seam. A spy subclass cannot
  observe its *superclass's* own `super` call, and the alternatives — swizzling
  `UITextView.paste(itemProviders:)` (a process-global side effect) or awaiting UIKit's real
  async text insertion on a windowless view (flaky) — are both worse. Production behaviour is
  unchanged: the seam's body is exactly `super.paste(itemProviders:)`.
- [decision] tests operate on the text view's `([NSItemProvider]) -> Void` callback rather than
  the coordinator's `[PickedItem]` hand-off, so they stay synchronous and deterministic; the
  provider→`PickedItem` conversion is already covered by `PickedImageLoaderTests` in HermesKit.
- [decision] added two cases beyond the plan's four: a provider with **no** registered types at
  all (alongside the plain-text one) and an **empty** paste, which must reach neither the
  callback nor stock handling.
- ⚠️ **Rewritten in Task 8.** These tests passed against hooks UIKit never calls, so a green
  suite here was *not* evidence the feature worked — only the simulator pass caught that. The
  file now drives `canPerformAction(_:withSender:)` / `paste(_:)` over an injected
  `UIPasteboard.withUniqueName()`, and the `pasteToSuper` seam survives with a `(_ sender:)`
  signature. See the Task 8 notes.

### Task 7: Re-record the affected snapshot baselines

**Files:**
- Modify: `HermesMobileTests/__Snapshots__/ComposerSnapshotTests/*.png` (as needed)
- Modify: `HermesMobileTests/__Snapshots__/ChatSnapshotTests/*.png` (as needed)
- Modify: `HermesMobileTests/__Snapshots__/ContextUsageSnapshotTests/*.png` (as needed)

- [x] run `make snapshot` and list exactly which baselines fail (expected: composer-bearing ones)
      (15 failures, all composer-bearing — listed in the notes below)
- [x] inspect each failure diff and confirm the delta is only the input-field re-implementation
      (placeholder position, line metrics) — investigate anything else before re-recording
      (one **real regression** found and fixed first: the placeholder colour — see notes)
- [x] delete **only** the failing PNGs and run `make snapshot` twice (record, then assert) —
      do **not** run `make snapshot-record`, which wipes every baseline
- [x] verify the idle/typing/recording/attachment-chip composer states still read correctly
- [x] run `make snapshot` — must be clean before Task 8 (exit 0, `** TEST SUCCEEDED **`;
      plus the 967-test HermesKit suite green)

**Task 7 notes**

- [decision] **Fixed a real regression instead of re-recording it.** The first `make snapshot`
  diff showed the placeholder rendering *brighter* than before: `ComposerTextView` set
  `placeholderLabel.textColor = .secondaryLabel` (per the plan's parity checklist), but SwiftUI's
  `TextField` prompt renders in `.placeholderText`. Measured over the composer's
  `secondarySystemBackground` in dark mode: old brightest text pixel `(90, 90, 94)` ≈ white α0.3,
  new `(152, 152, 159)` ≈ α0.6 — a visibly louder placeholder, not a line-metric artefact.
  `ComposerTextView.swift` now uses `.placeholderText`, which restores the old pixel value
  exactly (`(90, 90, 94)` in both). The plan's checklist said `.secondaryLabel`; parity with the
  `TextField` it replaced wins.
- after that fix the remaining delta on **every** failing baseline was input-swap-only:
  - **composer-only renders** (`ComposerSnapshotTests`, `ContextUsageSnapshotTests`) — the field
    is **+1.67pt taller** (`UITextView` line metrics + the `ceil` in `clampedSize(forWidth:)`
    vs the `TextField`'s 20.333pt line box), so the whole composer grows and the toolbar row
    shifts down ~5px @3x. Heights: idle/context-ring `102.33 → 104`, attachment chips
    `152.33 → 154`, typing+sending (two stacked composers) `224.67 → 228`.
  - **full-screen renders** (`ChatSnapshotTests`, `HydrationSnapshotTests`) — image size is
    **unchanged** (`1170 × 2532`) and the diff bounding box is a single 190 × 44px region around
    the placeholder glyphs, max channel delta 19/255: a sub-pixel baseline offset of the
    `UILabel` vs SwiftUI `Text`. Transcript rows, model chip, paperclip/mic/send, chips, toolbar
    and toasts are pixel-identical.
- **15 baselines re-recorded** (deleted individually, then `make snapshot` twice — record pass
  reported exactly `15` auto-recorded and no other failure, assert pass exit 0):
  - `ChatSnapshotTests/` — `testChatView.1`, `testChatView_codeBlockAndReconnecting.1`,
    `testChatView_commandOutputRow.1`, `testChatView_copiedIDToast.1`,
    `testChatView_messageActionBar.1`, `testChatView_reviewSummaryStatusRow.1`,
    `testChatView_sentImageAttachment.1`
  - `ComposerSnapshotTests/` — `testComposer_idle.1`, `testComposer_typingAndSending.1`,
    `testComposer_attachmentChips.1`, `testComposer_attachmentUploadingAndFailed.1`
  - `ContextUsageSnapshotTests/` — `testComposer_withContextRing.1`
  - `HydrationSnapshotTests/` — `testInstantPaint_fromCache.1`,
    `testRehydrated_rendersStoredHistory.rehydrated`, `testRehydrated_toolCallsAndThinking.1`
- the composer's non-text states were **not** touched: `testComposer_recordingWaveform`,
  `testComposer_transcribing`, both `testModelPickerSheet*`, `testChatView_slashSuggestionPanel`,
  `testChatView_streamingAssistant_noActionBar` and every approval/tool/clarify baseline passed
  unchanged — the recording bar replaces the field entirely, so it never saw the swap. The
  re-recorded set was reviewed visually: placeholder, typed text, send vs interrupt button,
  image thumbnail / PDF / file chips, the uploading spinner + failed warning, and the context
  ring all render as before.
- [deviation] `HermesKit/Package.resolved` was churned by the resolve step again (dropping the
  `swift-snapshot-testing` pin, which is declared in `Project.swift` not `Package.swift`) and was
  reverted — same unrelated churn recorded under Task 5.

### Task 8: Verify the paste gesture in the simulator

**Files:**
- Modify: `docs/plans/20260725-paste-images-into-composer.md` (record findings)

- [x] boot the simulator, seed the pasteboard with a PNG via `xcrun simctl pbcopy`, open a chat
      (iPhone 17 Pro / iOS 26.2; `simctl pbsync host <udid>` — `pbcopy` reads stdin as text
      only and cannot stage a PNG. No agent is reachable from this environment, so the chat
      was reached through the DEBUG `HERMES_DEMO=chat` demo mode)
- [x] long-press the message field and confirm **Paste** is offered for an image-only clipboard
      (this is the load-bearing assumption of the whole approach — if it fails, fall back to
      overriding `paste(_:)` + `canPerformAction(_:withSender:)` and record the change here)
      — ⚠️ **IT FAILED.** The fallback was implemented and **Paste** now appears. Full verdict
      and evidence in the notes below.
- [x] confirm the paste produces an attachment chip with a thumbnail, the text stays empty, and
      no *"Allow Paste"* banner appears (chip `pasted-image.png` + thumbnail + remove button,
      `TextArea "Message"` value `''`, no banner and no alert in the accessibility tree)
- [x] confirm pasting text still inserts text (composer value became `pasted text works`), and
      send a pasted image end-to-end **(not verifiable here — `canSend` requires a non-nil
      `liveSessionID`, which only a live agent produces; demo mode never attaches, so the send
      path is inert by design. Still needs a human pass against a real agent.)**
- [x] confirm keyboard focus, Return-key submit, 6-line growth, and the slash-suggestion panel
      still behave as before — ⚠️ **focus was broken and is now fixed** (see notes); growth
      clamps at 6 lines and scrolls internally; Return inserts no newline, and its *submit*
      hand-off is now pinned by a unit test since the sim can't reach `canSend`; **the
      slash-suggestion panel is not verifiable here** — `slashSuggestions` needs a
      `commands.catalog` from a live agent, so the panel never renders in demo mode (typing
      `/mo` updates the composer binding correctly; the panel's rendering stays covered by the
      passing `testChatView_slashSuggestionPanel` baseline)
- [x] record the outcome (and any deviation) in this plan under Progress Tracking

**Task 8 notes**

**VERDICT: the plan's core assumption was wrong.** With a PNG-only clipboard, long-pressing the
composer offered only *AutoFill* — **no Paste**. The documented fallback was implemented, and
after it the same gesture offers **Paste | AutoFill** and stages a chip.

- **Evidence the clipboard really was image-only** (i.e. the harness, not the app, was not at
  fault): a throwaway diagnostic in `HermesMobileTests` read `UIPasteboard.general` inside the
  simulator and reported `numberOfItems=1 hasImages=true hasStrings=false
  types=["public.png"]`. The control case confirms the gesture harness too: with a *text*
  clipboard the identical long-press produced **Paste | AutoFill**.
- **Why it failed.** `UITextView` builds its edit menu from `canPerformAction(_:withSender:)`
  and never consults `canPaste(_:)`. The same diagnostic showed our view's
  `canPaste([imageProvider]) == true` (the override worked) while
  `canPerformAction(#selector(paste(_:))) == false` — the verdict UIKit actually asks for.
  `pasteConfiguration` is inert for this decision.
- ➕ **Second, latent bug found by the same diagnostic**: stock `UITextView.pasteConfiguration`
  is **`nil`**, not a configuration carrying the text types. Task 4's "add to (never replace)"
  code therefore fell into its `?? UIPasteConfiguration(acceptableTypeIdentifiers: [])` branch
  and produced a configuration accepting **only** `public.image` — it *dropped* text
  acceptance rather than widening it (visible as our `canPaste([textProvider]) == false` vs
  stock's `true`). Moot now: the `pasteConfiguration` mutation is gone entirely and the view is
  byte-identical to stock for any image-free clipboard.
- [deviation] **`ComposerTextView.swift` rewritten around the fallback.** Removed: the
  `pasteConfiguration` widening, `canPaste(_:)`, `paste(itemProviders:)` and
  `pasteToSuper(itemProviders:)`. Added: `canPerformAction(_:withSender:)` (claims `paste(_:)`
  only when `pasteboard.hasImages`), `paste(_:)` (image providers → `onPasteImages`; no image →
  plain `super`; mixed → callback **and** `super` for the text), and `pasteToSuper(_:)` as the
  spy seam. `PickedImageLoader.imageTypeIdentifier(in:)` still does the classifying, so the
  HermesKit loader and its tests are untouched.
- [decision] added an injectable `var pasteboard: UIPasteboard = .general` seam. Tests drive a
  `UIPasteboard.withUniqueName()` (removed in `tearDown`) instead of mutating the device's
  general pasteboard, so the suite stays hermetic — the paste hooks now *read* the clipboard,
  which the provider-argument design didn't.
- [decision] `canPerformAction` probes with `hasImages` and never touches `itemProviders`.
  `hasImages` is metadata and does not raise the *"Allow Paste"* banner, whereas reading
  providers while merely *building the menu* would — the banner-free property the plan set out
  to keep. Confirmed on screen: no banner after a paste.
- [deviation] **Task 6's tests were rewritten** (`ComposerTextViewTests.swift`) — the old ones
  drove `canPaste(_:)` / `paste(itemProviders:)`, which no longer exist. The same four
  scenarios are now asserted against the real hooks, plus: other edit actions keep UIKit's
  verdict, multi-image order, an empty clipboard, and the two new cases below. 11 tests, green.
- ⚠️ ➕ **Third bug, caught by this task's own "keyboard focus" checkbox — the composer was
  unusable.** Typing `Hello there` landed exactly **one** character. Nothing applies
  `.focused(_:)` to the representable (it *is* the focusable view), so `ChatView`'s
  `@FocusState composerFocused` never latches `true`; `updateUIView` read it level-triggered
  and so resigned the first responder on the very next state change — i.e. after the first
  keystroke, and again right after a paste staged its chip. Fixed by making focus
  **edge-triggered**: a new pure `ComposerTextView.focusCommand(requested:lastRequested:
  isFirstResponder:)` plus `Coordinator.lastFocusRequest`, so only an actual *change* in the
  binding moves first-responder status. Keyboard dismissal still works — the transcript's
  `.scrollDismissesKeyboard(.interactively)` resigns at the UIKit level, as it did with the
  `TextField`. Pinned by `testAFocusValueThatNeverLatchesNeverResignsTheKeyboard` and
  `testAChangedFocusBindingStillMovesFirstResponder`; re-verified on device by typing a
  140-character message in full.
- [decision] added `testReturnSubmitsInsteadOfInsertingANewline` (drives the coordinator's
  `shouldChangeTextIn` directly). The simulator can only show the *absence* of a newline —
  `canSend` needs a live `liveSessionID`, so neither Return **nor the send button** submits in
  demo mode — and an unverifiable checkbox is better converted into a real test than waved
  through.
- 6-line growth verified live: a long message clamped at six wrapped lines and scrolled
  internally instead of growing further; the composer stopped expanding.
- validation after the change: `make snapshot` **clean** (`** TEST SUCCEEDED **`, whole
  `HermesMobileTests` target, so the 11 paste tests ran with it — the composer's *rendering* is
  unchanged, so no baseline moved) and the HermesKit suite green at **967 tests**.
- [deviation] `HermesKit/Package.resolved` was churned by the resolve step again (dropping the
  `swift-snapshot-testing` pin) and was reverted — same unrelated churn recorded under Tasks 5
  and 7.
- **Still needs a human pass** (no agent reachable from this environment): the end-to-end send
  of a pasted image (chip → `image.attach_bytes` → user row with thumbnail) and the live
  slash-suggestion panel.

### Task 9: Verify acceptance criteria

- [x] verify all requirements from Overview are implemented (native field paste, image-only
      scope, no paperclip menu entry)
- [x] verify edge cases: multi-image paste, mixed image+text clipboard, paste while
      `attachmentsUnsupported`, paste with a non-image clipboard, paste into an empty vs
      non-empty composer (two gaps found and closed — see the notes)
- [x] run full test suite: `script -q /dev/null swift test --package-path HermesKit`
      (966 tests, green)
- [x] run snapshot suite: `make snapshot` (`** TEST SUCCEEDED **`, no baseline moved;
      the run covers the whole `HermesMobileTests` target, so the 18 `ComposerTextViewTests`
      ran with it)
- [x] verify no regression in the existing attachment flows (photos / camera / files)

**Task 9 notes**

Verified against the **shipped** mechanism (`canPerformAction(_:withSender:)` + `paste(_:)` over
`UIPasteboard`), not the plan's original `pasteConfiguration` prose — the Overview, Solution
Overview, Technical Details, Testing Strategy and Task 10 wording were rewritten in this task so
the plan documents reality.

*Overview requirements — all met.* Native field paste: `ComposerView.textComposer` renders
`ComposerTextView`, `ChatView` forwards `onPasteImages` → `.attachmentsPasted`. Image-only
scope: `paste(_:)` filters providers through `PickedImageLoader.imageTypeIdentifier(in:)`;
everything else (text, PDF, files) reaches `super` untouched. No paperclip entry: the `Menu` is
still exactly Photo Library / Camera / Files.

*Edge cases — coverage after this task.* multi-image (`testMultipleImagesReachTheCallbackIn
ClipboardOrder`, `pickedItemsLoadsImagesInOrderWithExactBytes`, `pastingImagesStagesThemIn
OrderWithFreshIDs`); mixed image+text (`testMixedClipboardStagesTheImageAndStillPastesTheText`);
non-image clipboard (text / empty / **new** PDF case); `attachmentsUnsupported` (reducer test
plus **three new** view-level tests); empty vs non-empty composer (the "draft" case existed, the
**new** empty-composer case pins that the placeholder survives a paste). *(Several of these test
names changed in the review pass — see "Review pass" below.)*

- ➕ ⚠️ **Bug found and fixed: the Paste item was offered when the agent can't accept uploads.**
  `canPerformAction` claimed `paste(_:)` on `hasImages` alone, so with `attachmentsUnsupported`
  iOS still offered **Paste** for an image-only clipboard and tapping it did nothing (the
  reducer drops it silently, by design). The Task 3 decision that "the system paste menu is not
  ours to hide" was written against the *old* `pasteConfiguration` mechanism; the Task 8
  rewrite invalidated its premise. Fixed with `ComposerInputTextView.acceptsPastedImages`
  (default `true`), fed from `ComposerTextView.attachmentsSupported` ← `ComposerView`'s existing
  `attachmentsSupported` flag — the same capability gate that hides the paperclip, per the
  project's "gate UI by server capability" convention. Both hooks honour it, so in that mode the
  view is byte-identical to a stock `UITextView` and text paste is untouched. The reducer guard
  stays as the backstop (a mixed clipboard can still deliver images through a stock text paste
  on some future path). Pinned by `testAnImageClipboardKeepsTheStockVerdictWhenAttachmentsAre
  Unsupported`, `testPastingAnImageStagesNothingWhenAttachmentsAreUnsupported`,
  `testAMixedClipboardStillPastesItsTextWhenAttachmentsAreUnsupported`.
- ➕ **Gap closed: the coordinator's provider→`PickedItem` hop had no test in the app target.**
  `PickedImageLoaderTests` covers the loader, but nothing pinned that the *composer* passes
  `fallbackName: "pasted-image"` or that an all-failed load is dropped instead of sending an
  empty `attachmentsPasted`. Added `testPastedProvidersBecomePickedItemsWithTheComposersNaming`
  (two providers → `pasted-image.png` / `pasted-image-2.png`, original bytes, `image/png`,
  `.image`) and `testProvidersThatFailToLoadNeverReachTheCallback`.
- ➕ **Gap closed: empty-composer paste and PDF scope.**
  `testPastingAnImageIntoAnEmptyComposerKeepsThePlaceholder` (text stays `""`, placeholder stays
  visible, nothing forwarded to `super`) and `testAPDFClipboardIsNotStagedAsAnAttachment`
  (**Paste** not claimed, stock handling) — the latter pins the "images only" product decision
  against a future widening.
- [decision] **removed `PickedImageLoader.containsImage(_:)`** and its test. It existed solely to
  drive the abandoned `canPaste(_:)` override and had no production caller left; its doc comment
  still advertised that dead mechanism, which would have misled the Task 10 `CLAUDE.md` write-up.
  The shipped `paste(_:)` filters with `imageTypeIdentifier(in:)` directly. HermesKit: 967 → 966
  tests.
- *No regression in the picker flows*: camera and files never touched the shared loader (only
  `PhotoPickerPresenter` was refactored, Task 2), and the photo path's naming contract stays
  pinned by `photoPickerNamingContractIsPreserved` /
  `photoPickerDisambiguatesRepeatedUnnamedPicks`; the three `attach*Tapped` reducer tests and
  all attachment-chip snapshot baselines pass unchanged.
- **Still needs a human pass** (unchanged from Task 8, no agent reachable here): the end-to-end
  send of a pasted image and the live slash-suggestion panel.
- [deviation] `HermesKit/Package.resolved` was churned by the resolve step again (dropping the
  `swift-snapshot-testing` pin) and was reverted — same unrelated churn recorded under Tasks 5,
  7 and 8.

### Task 10: [Final] Update documentation

- [x] update `CLAUDE.md` — the composer input is now `UITextView`-backed
      (`ComposerTextView`); paste routing (`canPerformAction(_:withSender:)` claims `paste(_:)`
      when `UIPasteboard.hasImages` **and** attachments are supported; `paste(_:)` diverts the
      image providers to `.attachmentsPasted` and leaves everything else to stock UIKit) and
      the shared `PickedImageLoader` used by both the picker and paste
- [x] update `README.md` if the attachment feature is described there
- [x] move this plan to `docs/plans/completed/` (handled by the exec orchestrator at run end)

**Task 10 notes**

- the new `CLAUDE.md` bullet documents the **shipped** mechanism only — the abandoned
  `pasteConfiguration` / `canPaste(_:)` / `paste(itemProviders:)` route appears solely as the
  trap it turned out to be (tests green, no **Paste** item), since that is the load-bearing
  lesson for anyone touching this code next.
- [decision] `README.md` gained one clause on the existing "Compose hands-free or with files"
  bullet ("or just paste a copied screenshot into the message field") rather than a bullet of
  its own — the README is a user-facing feature list and paste is one more way into the
  attachment flow already described there, not a separate feature.
- [decision] the `.placeholderText` colour trap (Task 7) is folded into the same bullet: it is
  a one-line parity rule that a future re-render of the composer would otherwise re-break.
- validation: HermesKit suite green at **966 tests**; no code changed, so no snapshot run was
  needed. `HermesKit/Package.resolved` churn from the resolve step was reverted again (same
  unrelated churn recorded under Tasks 5, 7, 8 and 9).

## Review pass

*Findings from the post-implementation code review, verified against the source and the sibling
`hermes-agent` clone, then fixed. Recorded here because several of them contradicted what the
tasks above claim shipped.*

- ⚠️ **HEIC would have failed at send time.** `imageTypeIdentifier` took the *first*
  image-conforming identifier; `image.attach_bytes` trusts the filename suffix over the magic
  bytes (`tui_gateway/server.py:_sniff_image_ext`) and rejects anything outside
  `cli.py:_IMAGE_EXTENSIONS`, which has no `.heic`. A HEIC-first provider (very common on iOS)
  produced a good-looking `pasted-image.heic` chip and then a hard 4016 with the attachment
  still staged — unretryable. Now a server-supported identifier wins.
  *(Second pass: the first fix over-corrected — see below.)*
- ⚠️ **The focus plumbing was dead and dangerous, and was deleted.** `ChatView.composerFocused`
  was never read or written by anything (already true on `main`), so the Task 8 edge-trigger
  machinery existed only to keep a no-op binding harmless — and it still had a hole: the
  coordinator's `lastFocusRequest` was seeded *after* `updateUIView`'s `window != nil` guard, so
  the first windowed update could see `(requested: false, lastRequested: nil,
  isFirstResponder: true)` and **resign** — the very bug Task 8 fixed. Deleted the binding from
  `ChatView` / `ComposerView` / `ComposerTextView` along with `FocusCommand`, `focusCommand`,
  `lastFocusRequest` and the two delegate write-backs (chosen over patching the nil seed:
  patching keeps a subsystem whose only job is to do nothing). Keyboard dismissal was never
  its doing — `CollectionTranscriptView` sets `keyboardDismissMode = .interactive`.
- ⚠️ **`clampedSize` mutated the view from SwiftUI's sizing pass.** It assigned `isScrollEnabled`
  (which invalidates layout) inside `sizeThatFits`. Split into a pure `clampedHeight(forWidth:)`
  plus an `isScrollEnabled` flip in `layoutSubviews`.
- ⚠️ **The 1–6 line clamp was really 1–5½.** The ceiling used `font.lineHeight` (20.29 for
  17pt body) where TextKit lays a line out at `lineHeight + leading` (22.0). Fixed; only
  multi-line rendering moves, so no existing baseline changed — and the new
  `testComposer_multilineGrowth` baseline pins six full lines.
- **`paste(_:)` now decides "everything else" per provider, not per pasteboard.** It forwarded to
  `super` on `pasteboard.hasStrings`, which both contradicted its own docs (an image + PDF was
  silently dropped) and made Safari's *Copy Image* — one item carrying the image **and** the page
  URL — type the URL into the message alongside the chip. `super` is now called exactly when a
  non-image provider is left over.
- **The `canPerformAction` tests were tautological or ambient-flaky.** Every "keeps the stock
  verdict" assertion fell through to `super`, which reads `UIPasteboard.general` — not the
  injected board — so it passed (or failed) on whatever the simulator's clipboard held; the PDF
  case's hard `XCTAssertFalse` could go red from unrelated state. Added a
  `superCanPerformAction(_:withSender:)` seam and switched those cases to assert **delegation**.
- **Tests added for what was untested**: the representable's `apply(to:)` wiring (nothing
  exercised the `attachmentsSupported` → `acceptsPastedImages` gate — the test helper's
  `attachmentsSupported:` parameter was never once passed `false`), hosting the representable end
  to end, the `textViewDidChange` binding write-back + placeholder, `clampedHeight`'s
  1/3/6-line clamp, the `layoutSubviews` scroll flip in both directions, and a
  pasted→`image.attach_bytes` reducer case. `testProvidersThatFailToLoad…` gained a positive
  control (a good provider alongside the failing one) so it can no longer pass on a dead load
  path, and `testPastingAnImageIntoAnEmptyComposerKeepsThePlaceholder` — which asserted a value
  the test itself had set — was replaced by a real placeholder test.
- **`suggestedName` is sanitised** before it travels to the agent as `filename` (last path
  component, no leading dot, no doubled extension — a pasteboard name routinely already carries
  one, giving `screenshot.png.png`). The current agent is safe (`Path(filename).suffix` only,
  server-generated path), but the string is third-party-controlled and this app targets agents
  of varying vintage.
- **A paste that loads nothing is no longer silent** — `PickedImageLoader` logs the discarded
  provider error and the coordinator logs the dead end.
- **Concurrent pastes are ordered**: the coordinator chains its load tasks, so two fast pastes
  stage in paste order rather than in load-completion order.
- **Simplifications**: `lineLimit: ClosedRange<Int>` → `maxLines: Int` (the floor is always one
  line and can never bind); the explicit `placeholder:`/`lineLimit:` arguments dropped at the one
  call site that passed the defaults; `filename`/`mimeType`/`pickedItem` made internal (only the
  same file and `@testable` tests call them); the vestigial "the system paste menu isn't ours to
  hide" rationale — false since Task 9 added `acceptsPastedImages` — rewritten in the reducer and
  its test; `pastingNothingChangesNothing` dropped (a loop over `[]`, already guarded in the
  coordinator); `Box`/`ItemBox` collapsed into one `Recorder<T>`; `ComposerHost` deleted with the
  focus binding.
- [decision] **kept the reducer's `attachmentsUnsupported` guard** even though the view now
  hides the offer: the providers load asynchronously, so an `attachmentsUnsupportedDetected` can
  land between the paste and the finished items. The comment now says that instead of the
  disproved "menu isn't ours to hide".
- [decision] **did not** disambiguate chip filenames *across* separate pastes (two single-image
  pastes both label `pasted-image.png`). Cosmetic only — the agent writes its own
  `upload_<ts>_<counter><ext>` path — and fixing it would put stateful naming in the reducer.

## Second review pass

*A second, independent critical review of the fixes above. Two reviewers converged on the first
four; all were confirmed against the source and the sibling `hermes-agent` clone.*

- ⚠️ **The HEIC fix over-corrected into a fidelity regression.** `imageTypeIdentifier` looped
  over *our* preference list on the outside, so `public.png` beat whatever the provider itself
  listed first — and `registeredTypeIdentifiers` is documented fidelity order. Safari's *Copy
  Image* on an animated GIF registers `com.compuserve.gif` **and** the rendered PNG still, so
  the animation was silently flattened; a JPEG registering PNG alongside was re-encoded several
  times larger and base64'd over the socket. It hit the photo picker too, and contradicted the
  module's own "no re-encode" contract. Now the **provider's** order decides and we only skip
  past types the agent rejects — which still turns `["public.heic", "public.jpeg"]` into a JPEG.
- ⚠️ **The "exotic type still attaches" fallback did not attach — it hard-failed 4016.** The
  justifying comment claimed the agent sniffs magic bytes for an unknown extension; it does not:
  `_sniff_image_ext` returns `Path(filename).suffix` whenever the name has *any* suffix and we
  always append one, so the magic-byte table is unreachable and `_allowed_image_extensions()`
  rejects the rest. A HEIC-only clipboard still produced a good-looking chip that died at send.
  Fixed for real with a **client-side re-encode** (`transcodedImage(from:)`, ImageIO — see
  Technical Details); undecodable bytes are dropped instead of staged. The false comments about
  magic-byte sniffing and about `loadDataRepresentation` "transcoding" are gone.
- ⚠️ **One hung provider blocked every later paste, permanently.** `loadData` was a bare
  `withCheckedContinuation` around `loadDataRepresentation` — which nothing obliges to call its
  completion handler (expired Universal Clipboard item) — and every paste awaited the previous
  task's value. Added a 15s deadline (one-shot `ContinuationBox`, `progress.cancel()`), so the
  chain is bounded; the coordinator also clears `pendingLoad` when the newest load finishes.
- ⚠️ **A paste that loaded nothing was a completely silent dead end** (one `os_log` line). iOS
  offered **Paste** *because we claimed it*, the user tapped it, and nothing happened. The
  coordinator now hands over the empty batch and the reducer sets `errorBanner` — except under
  `attachmentsUnsupported`, which banners its own explanation.
- ⚠️ **The pinned-ceiling scroll flip never fired** — found by writing the test for the
  verification gap the reviewers flagged. Once the field is at six lines the frame stops
  changing, so nothing requested another layout pass and `updateScrollEnabled` (which lives in
  `layoutSubviews`) never ran: the seventh line neither grew the field nor scrolled into view.
  Both entry points now `setNeedsLayout()` — the `text` observer for programmatic sets and
  `textViewDidChange` for typing — with a test per path.
- **The caret after a programmatic text set** (slash insert, `/undo` prefill) is now pinned to
  the end of the text; `UITextView.text` leaves it wherever UIKit decides. The text sync moved
  into `apply(to:)` so it is testable without a `Context`.
- **Housekeeping**: `paste(_:)` short-circuits on `pasteboard.hasImages` before touching
  `itemProviders`, so a plain-text paste is byte-identical to stock down to not reading the
  clipboard's contents.
- [decision] **did not** forward to `super` when an image item *also* carries a genuine text
  payload (one reviewer's suggestion). Telling genuine prose from Safari's URL noise means
  reading and classifying the text, and a wrong guess types a stray URL into the user's message
  — the exact failure the per-provider rule was written to stop. Documented as a known
  limitation in `paste(_:)` and CLAUDE.md instead.
- [decision] the re-encode lives in **`PickedImageLoader` (HermesKit)**, not the app-side
  coordinator as the review suggested: ImageIO is Foundation-level, so `swift test` covers it on
  macOS, and the photo picker gets the same protection for free.
- [decision] `serverSupportedImageExtensions` mirrors `cli.py:_IMAGE_EXTENSIONS` **verbatim**
  (it gained `.tif`, `.svg`, `.ico` over the first pass's UTType list) — an SVG the agent would
  have accepted was being pointlessly re-encoded, and ImageIO cannot rasterise one anyway.

## Third review pass

*All three findings are regressions from the second pass's own fixes — the shared loader is
shared with the **photo picker**, so every change to it lands on a shipped path too.*

- ⚠️ **The re-encode always chose PNG for a HEIC, blowing the 25 MB cap.** The opacity verdict
  was read from the *decoded thumbnail's* `alphaInfo`, and `CGImageSourceCreateThumbnailAtIndex`
  reports `.premultipliedLast` for a **HEIC** source even when the image is fully opaque
  (verified locally: opaque heic → `alphaInfo=1`, opaque png/jpeg → `6`). HEIC is the only format
  the transcode exists for, so the branch written to be avoided was the branch always taken:
  ~39 MB PNG for a 12 MP photo JPEG encodes in ~7 MB → `image.attach_bytes` 4018, i.e. 4016
  traded for 4018. Opacity now comes from the **source's** `kCGImagePropertyHasAlpha` (absent for
  opaque, `true` with an alpha channel, across heic/png/jpeg). Both old transcode tests fed PNG
  bytes — even the one that *declared* `.heic` — so none of them ever decoded a HEIC; the new
  tests encode real HEIC (skipped where ImageIO has no HEIC encoder).
- ⚠️ **The provider-order scan promoted an uncompressed TIFF/BMP over a co-registered PNG/JPEG.**
  The rule was purely "supported / not supported", and `serverSupportedImageExtensions` contains
  `tiff`/`tif`/`bmp`. macOS pasteboards list `public.tiff` **first** (`NSPasteboardTypeTIFF`) and
  Universal Clipboard bridges that to iOS verbatim, so a Mac-copied image staged as a ~36 MB
  uncompressed TIFF — over the cap — with a perfectly good PNG on offer. Now a **three-pass**
  scan (compressed-supported → any-supported → any-image), each pass honouring the provider's own
  order, so GIF-before-PNG and JPEG-before-PNG are unchanged and `["public.tiff","public.png"]`
  yields PNG.
- ⚠️ **The 15 s clipboard deadline silently governed the photo picker too.** A
  `PHPickerResult`'s provider performs the **iCloud download inside `loadDataRepresentation`**,
  so with "Optimize iPhone Storage" a non-resident original over a weak connection blew the
  budget, `progress.cancel()` killed the download, and the picker path — which had no
  empty-batch reporting — dismissed onto an unchanged composer with no banner at all. The
  deadline is now **per source** (`clipboardLoadTimeout` 15 s clipboard / `pickerLoadTimeout` 120 s
  picker), *and* every picker reports what it lost: `PickedBatch { items, droppedCount }` drives
  `.attachmentsDropped`, while a cancel (no items **and** no drops) stays silent.
- **Minors fixed in the same pass**: the re-encode reads the source's declared pixel dimensions
  before any decode (`maxSourcePixels`, a decompression-bomb bound on the only types that
  reach it) and steps the thumbnail down 4096→2048→1024 if the encode still clears
  `maxAttachmentBytes`; the scroll flip `scrollRangeToVisible`s **on the transition only**,
  so the seventh line is visible immediately instead of one keystroke later; hardware
  **Shift+Return** inserts a newline again via a `keyCommands` entry that flags its own insertion
  (`TextField(axis: .vertical)` parity — dictation's "new line" still submits, indistinguishable
  at the text-replacement layer); and a successful paste clears a stale `errorBanner`.
- [decision] `PickedBatch` replaces `[PickedItem]` on **all three** picker closures, not just
  `pickPhotos`: the camera's failed `jpegData` and an unreadable Files pick are the same silent
  dead end, and one shape keeps the client coherent.
- [decision] the picker budget is a generous **bound** (120 s) rather than unbounded — it
  restores the "waits and succeeds" behaviour in practice while still releasing a provider that
  never calls back at all.

## Post-Completion

*Items requiring manual intervention or external systems - no checkboxes, informational only*

**Manual verification**:
- physical-device paste from Safari and from the Photos app. Both commonly offer a **HEIC**
  representation, which the agent rejects (`_IMAGE_EXTENSIONS` has no `.heic`, error 4016).
  The loader skips past it when a supported representation is registered and re-encodes when it
  is not, but only a real device + live agent can confirm the end-to-end result — including
  that a re-encoded photo keeps its orientation and lands under the 25 MB cap.
- typing past the sixth line on a device: the field must start scrolling rather than swallowing
  the new line (unit-tested both ways after the second review pass, never seen on hardware).
- iPad with a hardware keyboard: ⌘V should route through the same `paste(_:)` override.
- the end-to-end send of a pasted image, and the live slash-suggestion panel — neither is
  reachable without a running agent (see the Task 8 notes).
- VoiceOver pass over the re-implemented input: the placeholder must still be announced and
  the field reachable, matching the old `TextField`.
- Dynamic Type at accessibility sizes: confirm the 1–6 line clamp scales with the body font.
- a very large pasted image (multi-MB screenshot). Images are now capped and re-encoded to fit
  the WebSocket frame (`maxAttachmentBytes`); watch upload time and memory, and confirm a
  rescued screenshot is still legible.

**Deliberately out of scope** (candidates for follow-up issues):
- pasting PDFs / arbitrary files into the field (`Kind.infer` already supports it; only the
  paste configuration and loader filter would need widening).
- a size or count cap on staged attachments, applied uniformly across picker and paste. (Every
  image path now re-encodes anything past `maxAttachmentBytes` rather than staging a doomed
  chip, and `maxBatchBytes` bounds one batch, but PDFs/files are still uncapped.)
- drag-and-drop of an image onto the composer (iPad) — a different UIKit interaction.
- **`attachmentsSubmitted` wipes `state.attachments` wholesale**, so anything staged *during*
  an in-flight upload is lost when the submit lands. Pre-existing on `main` for all three
  pickers (not a paste regression); the fix is to remove only the ids that were submitted.
  The `pendingPasteCount` gate added in the fifth review pass closes the *other* half of this
  race (a submit that beats a paste), but not this one — a paste that lands *during* an upload
  is still wiped.
- **`image.attach_bytes` uploads are not idempotent** (external review, iteration 5 — CONFIRMED
  against the agent clone; pre-existing for every attachment source, this branch neither caused
  nor worsened it). `ChatFeature.composerSubmitted` uploads the staged attachments one at a
  time and then submits; the agent's handler calls `_queue_attached_image`, which appends to
  `session["attached_images"]` **immediately** (`tui_gateway/server.py`). There is no upload id
  and no way to retract one. So: (a) if attachment 2 fails, attachment 1 is already queued
  server-side while `attachmentUploadFailed` keeps *all* the chips client-side — a retry
  re-uploads #1 and the message carries it twice; (b) removing the failed chip and sending only
  text still submits the orphaned #1, which the user believes they removed. A fix needs either a
  server-side retraction/idempotency key or client-side tracking of which attachments a given
  live session has already accepted (and a re-upload only of the rest). Redesigning the upload
  state machine was explicitly out of scope for #54.
- **the 16 MiB WebSocket frame limit binds `pdf.attach` and `file.attach` too**, and neither has
  any client-side cap (the agent's own caps are 50 MiB for a PDF, i.e. more than three frames'
  worth). A large PDF or file attach will kill the socket rather than return an error. Same
  root cause as the image byte budget; the images-only fix shipped with #54.
