import ComposableArchitecture
import HermesKit
import SwiftUI

/// The chat screen: a scrolling transcript, a transient error footer, and
/// the composer. Streams over the gateway via `ChatFeature`.
struct ChatView: View {
  @Bindable var store: StoreOf<ChatFeature>
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(spacing: 0) {
      connectionBanner
      // The toast overlays the transcript (not the whole screen) so it floats just above
      // the composer instead of covering it.
      transcript
        .overlay(alignment: .bottom) {
          CopiedToastView(token: store.copiedIDToastToken)
        }
      footer
      // A standing *approval* outranks the greedy transcript for the fixed region's height.
      // Without it a `VStack` offers each child `remaining / remainingCount` in flexibility
      // order, so the card — less flexible than the transcript — is offered roughly *half*
      // of what is left and its scrollable region collapses onto its floor with the keyboard
      // up: measured at the floor on every iPhone, i.e. the two-line window #65 was filed
      // about. With the priority the card is offered the whole remainder first; it hands a
      // tap target's worth back (`BoundedHeightLayout.reserve`) so the transcript — the
      // context for the decision — is not starved to 0pt. Applied here rather than inside
      // `pendingCard`'s `switch`: a trait written inside a `@ViewBuilder` branch does not
      // reach the enclosing stack (measured — the region stayed on its floor).
      //
      // Scoped to `.approval` because only that card is compressible: `ClarifyCardView` is
      // plain stacked content with rigid choice buttons, so priority would only take room
      // from the transcript (measured: 160pt → 13pt with a long question) without giving the
      // card anything it can use. Every card gets a fresh identity per presentation — a
      // replacement that does not pass through `nil` (a queued approval, a second secret
      // prompt) must not inherit the previous one's `@State`: its scroll offset, its
      // "Approve all" toggle, or — worst — a typed sudo password.
      pendingCard
        .id(store.pendingInteractionToken)
        .layoutPriority(store.isApprovalPending ? 1 : 0)
      suggestionPanel
      Divider()
      ComposerView(
        text: $store.composerText,
        isSending: store.isSending,
        canSend: store.canSend,
        model: store.model,
        reasoningEffort: store.reasoningEffort,
        usage: store.usage,
        recording: store.recording,
        waveformLevels: store.waveformLevels,
        recordingSeconds: store.recordingSeconds,
        attachmentsSupported: !store.attachmentsUnsupported,
        attachments: store.attachments,
        // Raising a blocking card hands the keyboard back (`ComposerTextView.blockingCardToken`):
        // the card can't be answered from the composer — `canSend` is false while one stands —
        // and the keyboard shrinks the very fixed region the card lives in, which is #65's own
        // root cause. Not a disable: the field stays live for a draft.
        blockingCardToken: store.pendingInteraction != nil ? store.pendingInteractionToken : nil,
        onModelTap: { store.send(.modelChipTapped) },
        onSend: { store.send(.composerSubmitted) },
        onInterrupt: { store.send(.interruptTapped) },
        onVoiceTap: { store.send(.voiceButtonTapped) },
        onCancelRecording: { store.send(.recordingCancelled) },
        onAttachPhotos: { store.send(.attachPhotosTapped) },
        onAttachCamera: { store.send(.attachCameraTapped) },
        onAttachFiles: { store.send(.attachFilesTapped) },
        onRemoveAttachment: { store.send(.removeAttachment(id: $0)) },
        onPasteBegan: { store.send(.attachmentsPasting) },
        onPasteImages: { store.send(.attachmentsPasted($0)) }
      )
    }
    // Animates the suggestion panel in/out (and the layout shift it causes). Keyed to
    // emptiness so mere filtering while typing never animates; nil under reduce-motion,
    // so the panel then appears/disappears instantly.
    .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: store.slashSuggestions.isEmpty)
    .navigationTitle(store.title ?? "Chat")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Menu {
          // Icons on every item — a `Menu` reserves the glyph gutter as soon as one item
          // has an image, so a bare "Rename" would sit in a blank column.
          Button("Rename", systemImage: "pencil") { store.send(.renameButtonTapped) }
            .disabled(!store.canRename)
          // `sessionKey` is `storedSessionID ?? liveSessionID` — nil only before a session
          // exists at all (a brand-new chat that hasn't been created yet).
          Button("Copy ID", systemImage: "doc.on.doc") { store.send(.copySessionIDTapped) }
            .disabled(store.sessionKey == nil)
        } label: {
          Image(systemName: "ellipsis.circle")
        }
      }
    }
    .alert("Rename session", isPresented: renameBinding) {
      TextField("Title", text: renameDraftBinding)
      Button("Save") { store.send(.confirmRename) }
      Button("Cancel", role: .cancel) { store.send(.cancelRename) }
    }
    .task { store.send(.task) }
    // NOTE: no `.onDisappear` here — disappearance is observed by the DESTINATION in
    // `AppView` (`AppFeature.chatViewDisappeared`), which guards a nil slot and forwards
    // the mic/voice cleanup (`.viewDisappeared`). Slot teardown is an `AppFeature` policy,
    // not a view event.
    .sheet(item: toolDetailBinding) { row in
      if case let .tool(name, title, _, detail, durationS) = row.kind {
        ToolDetailSheet(name: name, title: title, detail: detail ?? ToolDetail(), durationS: durationS)
      }
    }
    .sheet(isPresented: modelPickerBinding) {
      if let picker = store.modelPicker {
        ModelPickerSheet(
          picker: picker,
          currentModel: store.model,
          currentEffort: store.reasoningEffort,
          isBusy: store.isSending,
          onSelectModel: { store.send(.modelSelected($0)) },
          onSelectEffort: { store.send(.reasoningSelected($0)) },
          onDone: { store.send(.modelPickerDismissed) }
        )
      }
    }
  }

  /// Drives the rename alert's presentation; dismissing routes through `.cancelRename`.
  private var renameBinding: Binding<Bool> {
    Binding(
      get: { store.renameDraft != nil },
      set: { if !$0 { store.send(.cancelRename) } }
    )
  }

  /// A non-optional proxy over the optional draft so the `TextField` stays authoritative
  /// in the reducer (writes go through the binding action).
  private var renameDraftBinding: Binding<String> {
    Binding(
      get: { store.renameDraft ?? "" },
      set: { store.renameDraft = $0 }
    )
  }

  private var modelPickerBinding: Binding<Bool> {
    Binding(
      get: { store.modelPicker != nil },
      set: { if !$0 { store.send(.modelPickerDismissed) } }
    )
  }

  /// Drives the tool-detail sheet; dismissing routes through the reducer.
  private var toolDetailBinding: Binding<ChatRow?> {
    Binding(
      get: { store.presentedTool },
      set: { if $0 == nil { store.send(.toolDetailDismissed) } }
    )
  }

  /// The transcript, rendered behind the shared renderer boundary (`SwiftUITranscriptView`).
  /// The reducer owns no scroll state — stick-to-bottom / pin behaviour is renderer-local.
  /// `canLoadOlder` (= `hasMoreAbove`) gates the top sentinel so it can't page past the start
  /// and can't get stuck mid-load when already at the true top of history.
  @ViewBuilder
  private var transcript: some View {
    let rows = Array(store.visibleRows)
    let turnState: TurnState = store.isSending ? .streaming : .idle
    let canLoadOlder = store.hasMoreAbove
    let onLoadOlder = { _ = store.send(.loadOlderRequested) }

    // The transcript is rendered by the `UICollectionView`-backed engine (the only engine):
    // a diffable data source keyed on the deterministic row id gives stable diffing, scroll
    // restoration, and prepend-preservation that the pure-SwiftUI `ScrollView` couldn't.
    CollectionTranscriptView(
      rows: rows,
      turnState: turnState,
      canLoadOlder: canLoadOlder,
      onLoadOlder: onLoadOlder,
      cell: transcriptCell
    )
    // Keyboard dismissal is drag-driven (`.interactively`). We intentionally do NOT add a
    // `.simultaneousGesture(TapGesture())` here: it would swallow the hosted
    // `ScrollToBottomButton`'s tap.
    .scrollDismissesKeyboard(.interactively)
  }

  @ViewBuilder
  private func transcriptCell(_ row: ChatRow) -> some View {
    // Only user messages get the long-press "Copy whole message" menu (mirrors their bubble).
    // Assistant/tool/thinking rows render bubble-less plain text — no context menu, so a
    // long-press starts native text selection (select any range → system Copy/Share) instead
    // of grabbing the entire row. The menu's long-press gesture would otherwise pre-empt
    // `.textSelection`.
    if row.kind.role == .user {
      rowView(row)
        .contextMenu {
          Button {
            store.send(.copyRow(id: row.id))
          } label: {
            Label("Copy", systemImage: "doc.on.doc")
          }
        }
    } else {
      rowView(row)
    }
  }

  // Internal (not `private`) so snapshot tests can render a single transcript cell
  // deterministically — a full-device capture of a *streaming* row is flaky (the
  // spinner keeps animations alive while the collection view re-pins to bottom).
  @ViewBuilder
  func rowView(_ row: ChatRow) -> some View {
    switch row.kind {
    case let .message(role, text, isComplete):
      VStack(alignment: .leading, spacing: 8) {
        MessageBubbleView(
          role: role, text: text, isComplete: isComplete,
          copiedToken: store.recentlyCopiedToken,
          tokenPrefix: "\(row.id)",
          onCopyCode: { text, token in store.send(.copyCode(text: text, token: token)) },
          attachmentImages: row.attachmentImages
        )
        // The visible action row (#34): only under COMPLETED assistant messages with
        // real text — hidden while streaming (the reducer re-guards all of this).
        if role == .assistant, isComplete,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          MessageActionBar(
            isCopied: store.recentlyCopiedToken == ChatFeature.rowCopyToken(row.id),
            isBranchDisabled: !store.canBranch,
            onCopy: { store.send(.copyRow(id: row.id)) },
            onBranch: { store.send(.branchFromMessage(id: row.id)) }
          )
        }
      }
    case let .tool(name, title, state, detail, durationS):
      ToolStatusView(
        name: name, title: title, state: state, durationS: durationS,
        hasDetail: detail?.isEmpty == false,
        onTap: { store.send(.toolTapped(id: row.id)) }
      )
    case let .thinking(reasoning, status, elapsedSeconds, isComplete):
      ThinkingIndicatorView(
        liveSeconds: store.thinkingSeconds,
        reasoning: reasoning,
        status: status,
        elapsedSeconds: elapsedSeconds,
        isComplete: isComplete
      )
    case let .status(kind, text):
      // Review summaries (#47) are multi-sentence system lines — render them a step
      // larger (`.footnote`) and selectable so they stay readable/copyable. Other
      // status kinds ("approval", "clarify", …) keep the terse caption styling.
      if kind == ChatRow.Kind.reviewStatusKind {
        Text(text)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      } else {
        Text(text).font(.caption).foregroundStyle(.secondary)
      }
    case let .commandOutput(text):
      // Ephemeral slash-command output (#36): bubble-less, dimmed, monospaced, selectable.
      Text(text)
        .font(.system(.callout, design: .monospaced))
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  /// The slash-command autocomplete panel (#36), anchored just above the composer.
  /// Rendered only while the reducer's computed `slashSuggestions` is non-empty (catalog
  /// loaded, composer text is a slash query); a tap inserts via `.slashSuggestionTapped`
  /// and leaves focus untouched, so the keyboard stays up.
  @ViewBuilder
  private var suggestionPanel: some View {
    let suggestions = store.slashSuggestions
    if !suggestions.isEmpty {
      SlashSuggestionPanel(suggestions: suggestions) { store.send(.slashSuggestionTapped($0)) }
        .transition(.opacity)
    }
  }

  @ViewBuilder
  private var pendingCard: some View {
    switch store.pendingInteraction {
    case let .approval(request):
      // The per-presentation identity that keeps this card's `@State` (scroll offset,
      // "Approve all") from leaking into the next one is applied to `pendingCard` at the
      // `VStack` call site, so it covers the clarify/secret branches too — see there.
      ApprovalCardView(
        request: request,
        onApprove: { all in store.send(.respondToApproval(approve: true, all: all)) },
        onDeny: { store.send(.respondToApproval(approve: false, all: false)) }
      )
    case let .clarify(request):
      ClarifyCardView(mode: .clarify(request)) { answer in
        store.send(.respondToClarify(answer: answer))
      }
    case let .secret(kind, prompt):
      ClarifyCardView(mode: .secret(kind, prompt)) { value in
        store.send(.respondToSecret(value: value))
      }
    case .none:
      EmptyView()
    }
  }

  @ViewBuilder
  private var connectionBanner: some View {
    switch store.status {
    case .connecting:
      banner("Connecting…", systemImage: "wifi", tint: .secondary)
    case .reconnecting:
      banner("Reconnecting…", systemImage: "wifi.exclamationmark", tint: .orange)
    case .ready:
      EmptyView()
    }
  }

  private func banner(_ text: String, systemImage: String, tint: Color) -> some View {
    HStack(spacing: 6) {
      Image(systemName: systemImage)
      Text(text)
      Spacer()
    }
    .font(.caption.weight(.medium))
    .foregroundStyle(tint)
    .padding(.horizontal)
    .padding(.vertical, 6)
    .background(tint.opacity(0.12))
  }

  @ViewBuilder
  private var footer: some View {
    if let error = store.errorBanner {
      Label(error, systemImage: "exclamationmark.triangle")
        .font(.caption).foregroundStyle(.red)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
    }
  }
}
