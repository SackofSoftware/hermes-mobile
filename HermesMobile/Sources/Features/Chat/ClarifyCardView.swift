import HermesKit
import SwiftUI

/// Pinned card shown when the agent asks the user a question mid-turn — every clarify form the
/// desktop renders, in the approval card's shape: a rigid one-line title and a **pinned action
/// row** over ONE bounded, scrollable region (``BoundedHeightLayout``), never plain stacked
/// content. The region holds everything unbounded — up to five questions of server-controlled
/// text, four choices each, an "Other" row per question — so a squeezed fixed region (keyboard
/// up, accessibility sizes) is absorbed by the viewport and Skip / Submit stay on screen (#65's
/// lesson, `docs/features/approvals.md`).
///
/// The form comes from the question count and kind:
/// - **one single-select question** — a tap on a choice submits it at once;
/// - **one multi-select question** — checkmark rows, submitted with Submit;
/// - **one free-text question** — a text field, sent with Send;
/// - **several questions** — one section per question (choices select instead of submitting,
///   each section can be skipped), confirmed with Confirm once every question has an answer or
///   a skip.
///
/// Every question with choices also gets an "Other" free-text row (the upstream tool schema
/// tells the model the UI adds one) — except on a legacy `clarify.request`, which keeps
/// today's form. The recommended choice shows a badge and is never preselected. Skip is on
/// every form. Questions the server already locked (a replayed batch) render read-only from
/// the store; the view's `@State` holds only the user's edits to the rest (``ClarifyDraft``,
/// whose rules are unit-tested in HermesKit), and the card is keyed on
/// `pendingInteractionToken` at the call site, so a replacement card never inherits them.
struct ClarifyCardView: View {
  let request: ClarifyRequest
  /// Called with the answers keyed by qid (`""` for a single legacy/intermediate question).
  let onSubmit: ([String: ClarifyAnswer]) -> Void
  /// Skips the whole card.
  let onSkip: () -> Void

  @State private var draft: ClarifyDraft
  /// Bottom-fade state from live scroll geometry — `ApprovalCardView`'s, for the same reason.
  @State private var fade = ApprovalCardView.FadeState()

  /// The cap's Dynamic Type input, clamped by ``contentMaxHeight`` — the approval card's
  /// numbers, since the rigid chrome around the region (a one-line title, one button row) is
  /// the same size, so the same derivations hold.
  @ScaledMetric(relativeTo: .callout)
  private var scaledContentMaxHeight: CGFloat = ApprovalCardView.contentMaxHeightBase

  private var contentMaxHeight: CGFloat {
    min(scaledContentMaxHeight, ApprovalCardView.contentMaxHeightCeiling)
  }

  /// `draft` seeds the edits (snapshots render a form mid-answer); the app passes none.
  init(
    request: ClarifyRequest,
    draft: ClarifyDraft = ClarifyDraft(),
    onSubmit: @escaping ([String: ClarifyAnswer]) -> Void,
    onSkip: @escaping () -> Void
  ) {
    self.request = request
    self.onSubmit = onSubmit
    self.onSkip = onSkip
    _draft = State(initialValue: draft)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      // Rigid and clamped, as on the approval card: every rigid point is one the region loses.
      Label("Clarification needed", systemImage: "questionmark.circle")
        .font(.subheadline.weight(.semibold))
        .lineLimit(1)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)

      scrollableContent

      // Outside the scroll on purpose: whatever the region is squeezed to, the way out (Skip)
      // and the way forward (Submit / Send / Confirm) stay on screen and tappable.
      HStack(spacing: 12) {
        Button(action: onSkip) {
          Text("Skip").frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        if let submitTitle {
          Button { onSubmit(draft.answers(for: request)) } label: {
            Text(submitTitle).frame(maxWidth: .infinity)
          }
          .buttonStyle(.borderedProminent)
          .disabled(!draft.isComplete(for: request))
        }
      }
    }
    .padding()
    .background(Color(uiColor: .tertiarySystemBackground), in: .rect(cornerRadius: 14))
    .overlay(RoundedRectangle(cornerRadius: 14).stroke(.blue.opacity(0.5)))
    .padding(.horizontal)
  }

  /// The questions, in a vertical `ScrollView` bounded by ``BoundedHeightLayout``: the natural
  /// height while it fits under the cap, the cap past it, down to the approval card's floor
  /// under a squeeze. The transcript reserve applies only to the multi-question card — the one
  /// `ChatView` gives layout priority (`isCompressibleCardPending`); without priority there is
  /// nothing to hand back.
  private var scrollableContent: some View {
    BoundedHeightLayout(
      cap: contentMaxHeight,
      minHeight: ApprovalCardView.contentMinHeight,
      reserve: request.isMultiQuestion ? ApprovalCardView.transcriptReserve : 0
    ) {
      ScrollView(.vertical) {
        VStack(alignment: .leading, spacing: request.isMultiQuestion ? 18 : 10) {
          ForEach(Array(request.questions.enumerated()), id: \.offset) { _, question in
            questionSection(question)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .scrollBounceBehavior(.basedOnSize)
      .onScrollGeometryChange(for: ApprovalCardView.FadeState.self) { geometry in
        ApprovalCardView.FadeState(
          isFaded: ApprovalCardView.hasBottomOverflow(
            visibleRect: geometry.visibleRect, contentHeight: geometry.contentSize.height
          ),
          rampHeight: ApprovalCardView.fadeRampHeight(viewportHeight: geometry.containerSize.height)
        )
      } action: { _, newFade in
        fade = newFade
      }
    }
    .mask { ApprovalCardView.bottomFadeMask(fade) }
  }

  @ViewBuilder
  private func questionSection(_ question: ClarifyQuestion) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(question.question)
        .font(request.isMultiQuestion ? .callout.weight(.medium) : .callout)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)

      if let locked = request.lockedDisplayText(for: question) {
        Label(locked, systemImage: "checkmark.circle.fill")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      } else if question.isFreeText {
        TextField("Type a reply", text: textBinding(question), axis: .vertical)
          .textFieldStyle(.roundedBorder)
      } else {
        ForEach(question.choices, id: \.self) { choice in
          choiceRow(choice, in: question)
        }
        if showsOtherRow {
          otherRow(question)
        }
      }

      if request.isMultiQuestion, !request.isLocked(question) {
        let skipped = draft.isSkipped(question)
        Button { draft.toggleSkip(question) } label: {
          Label("Skip this question", systemImage: skipped ? "checkmark.circle.fill" : "circle")
            .font(.footnote)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .accessibilityAddTraits(skipped ? .isSelected : [])
      }
    }
  }

  /// One choice. On the one-question single-select form a tap submits it (the bare label is
  /// derived in the reducer — the raw choice goes up); everywhere else it selects, shown by a
  /// radio (single) or checkbox (multi) mark.
  private func choiceRow(_ choice: String, in question: ClarifyQuestion) -> some View {
    let split = ClarifyChoice.split(choice)
    let selected = draft.isPicked(choice, in: question)
    return Button {
      if submitsOnTap {
        onSubmit([question.answerKey: .choices([choice])])
      } else {
        draft.toggle(choice, in: question)
      }
    } label: {
      HStack(spacing: 8) {
        if !submitsOnTap {
          Image(systemName: selectionIcon(selected: selected, multiSelect: question.multiSelect))
        }
        Text(split.label)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
        if split.isRecommended {
          Text("Recommended")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.blue.opacity(0.18), in: Capsule())
        }
      }
    }
    .buttonStyle(.bordered)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  /// The "Other" free-text row: typing makes the typed text the answer (clearing any pick).
  private func otherRow(_ question: ClarifyQuestion) -> some View {
    TextField("Other…", text: textBinding(question))
      .textFieldStyle(.roundedBorder)
      .submitLabel(.send)
      .onSubmit {
        // Return sends only where a single answer is all the card needs.
        if !request.isMultiQuestion, draft.isComplete(for: request) {
          onSubmit(draft.answers(for: request))
        }
      }
  }

  private func textBinding(_ question: ClarifyQuestion) -> Binding<String> {
    Binding(
      get: { draft.text(for: question) },
      set: { draft.setText($0, for: question) }
    )
  }

  private func selectionIcon(selected: Bool, multiSelect: Bool) -> String {
    switch (multiSelect, selected) {
    case (true, true): "checkmark.square.fill"
    case (true, false): "square"
    case (false, true): "checkmark.circle.fill"
    case (false, false): "circle"
    }
  }

  /// The one-question single-select form, where a tapped choice is the whole answer.
  private var submitsOnTap: Bool {
    guard !request.isMultiQuestion, let question = request.questions.first else { return false }
    return !question.isFreeText && !question.multiSelect
  }

  /// The "Other" row is a v7 form; a legacy `clarify.request` keeps today's choices-only card.
  private var showsOtherRow: Bool {
    request.answerShape != .legacyRespond
  }

  /// The pinned primary button's title, `nil` where a tap on a choice is the only way to answer
  /// (a legacy single-select card, which has no Other row).
  private var submitTitle: String? {
    if request.isMultiQuestion { return "Confirm" }
    guard let question = request.questions.first else { return nil }
    if question.isFreeText { return "Send" }
    if question.multiSelect { return "Submit" }
    return showsOtherRow ? "Send" : nil
  }
}

/// Pinned card for a sudo password or a secret value (legacy event or v7 server request): a
/// secure-entry field with Skip, plus the sudo `command` / secret `env_var` line when the
/// request carries one.
struct SecretCardView: View {
  let kind: SecretKind
  let prompt: SecretPrompt
  /// Called with the typed value.
  let onSubmit: (String) -> Void
  let onSkip: () -> Void

  @State private var text = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label(kind == .sudo ? "Password required" : "Secret required", systemImage: "key.fill")
        .font(.subheadline.weight(.semibold))

      if let promptText = prompt.prompt, !promptText.isEmpty {
        Text(promptText)
          .font(.callout)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      if let detail {
        // Clamped: this card is rigid (no bounded scroll region), so a long redacted sudo
        // command must not push the field and the composer off screen.
        Text(detail)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(3)
          .truncationMode(.middle)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      HStack(spacing: 12) {
        SecureField("Enter value", text: $text)
          .textFieldStyle(.roundedBorder)
          .submitLabel(.send)
          .onSubmit(submit)

        Button("Skip", action: onSkip)
          .buttonStyle(.bordered)

        Button(action: submit) {
          Image(systemName: "paperplane.fill")
        }
        .buttonStyle(.borderedProminent)
        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding()
    .background(Color(uiColor: .tertiarySystemBackground), in: .rect(cornerRadius: 14))
    .overlay(RoundedRectangle(cornerRadius: 14).stroke(.blue.opacity(0.5)))
    .padding(.horizontal)
  }

  private func submit() {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    onSubmit(trimmed)
    text = ""
  }

  /// The sudo `command` or the secret's `env_var`, when the request carries one.
  private var detail: String? {
    let value = (kind == .sudo ? prompt.command : prompt.envVar)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let value, !value.isEmpty else { return nil }
    return kind == .sudo ? "$ \(value)" : "Saved as \(value)"
  }
}
