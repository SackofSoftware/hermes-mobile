import HermesKit
import SwiftUI

/// Pinned card shown when the agent requests approval for an action. Approve/Deny,
/// with an "approve all" toggle for the rest of the session.
///
/// The card lives in `ChatView`'s outer `VStack`, i.e. the **non-scrolling** region between
/// the greedy transcript and the composer. That is the whole reason everything between the
/// title and the button row is rendered by ``scrollableContent`` — one bounded, scrollable
/// region — instead of plain stacked text: when the fixed region runs short (long command,
/// long detail, keyboard up, accessibility text size) the `VStack` compresses whatever it can,
/// and plain `Text` answers that squeeze by truncating with no way to reach the rest (issue
/// #65 — users had to leave and re-enter the chat, where the keyboard was down, to read what
/// they were approving). `.fixedSize` alone would invert the problem and push Approve/Deny off
/// screen.
///
/// **Three rules decide the shape, and each of them is a measured failure of an earlier take:**
///
/// 1. **Only the title and the Deny/Approve row are rigid, and the title is clamped.** A rigid
///    `detail` (the server's `description`, no length limit) or a rigid session toggle was
///    measured to push the buttons — and the composer — off screen at AX3/AX5 and on any phone
///    with a long detail: the rigid remainder outgrew the fixed region on its own. What is left
///    rigid is bounded by construction (one clamped line, one button row).
/// 2. **The command is the FIRST thing in the scroll**, so nothing server-controlled sits
///    between the top of the viewport and the thing being approved. With the title and the
///    detail above it, a 1000-char `detail` pushed the command *entirely* below the fold at
///    first paint (measured: no command pixels in the viewport at all on a 393×516 keyboard-up
///    window), and on the shortest screen the title + a two-line detail alone filled the whole
///    floor (88pt when that was measured; ``PromptCardMetrics/contentMinHeight`` is 96 now) — the user was asked
///    to approve a command they could not see.
/// 3. **The toggle's state is mirrored on the Approve button** (``approveTitle(all:)``). The
///    toggle itself has to live inside the scroll (rule 1), so with a long command it sits
///    below the fold — and a session-wide whitelist committed from a control the user cannot
///    see at the moment they tap Approve is a safety problem, not a discoverability one. The
///    button title is rigid, so the state is always legible where the decision is made.
struct ApprovalCardView: View {
  let request: ApprovalRequest
  let onApprove: (_ all: Bool) -> Void
  let onDeny: () -> Void

  @State private var approveAll = false

  /// Padding inside the command's tinted block — part of the derivation of
  /// ``PromptCardMetrics/contentMinHeight``. Internal rather than private so the measured
  /// "how many command lines are legible" tests can discount it.
  static let commandPadding: CGFloat = 8

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      // Rigid, and deliberately tiny. The card's identity has to survive every squeeze, but
      // every rigid point here is a point the command's viewport does not get — so it is one
      // line, and its Dynamic Type is clamped: at AX5 an unclamped two-word title wraps into
      // three lines of chrome and pushes the answer off screen. The content it labels is NOT
      // clamped — the command, the detail and the toggle all scale in full inside the scroll.
      Label("Approval requested", systemImage: "lock.shield")
        .font(.subheadline.weight(.semibold))
        .lineLimit(1)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)

      scrollableContent

      // The other rigid part. Outside the scroll on purpose: whatever the region is squeezed
      // to, the answer the user has to give stays on screen and tappable — and its title
      // carries the session-toggle's state, which is otherwise a scroll away.
      HStack(spacing: 12) {
        Button(role: .destructive, action: onDeny) {
          Text("Deny").frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        if request.allowsOnce {
          Button { onApprove(approveAll) } label: {
            Text(Self.approveTitle(all: approveAll)).frame(maxWidth: .infinity)
          }
          .buttonStyle(.borderedProminent)
        }
      }
    }
    .promptCardChrome(tint: .orange)
  }

  /// Everything the user has to read before answering, in a ``BoundedScrollRegion``: it asks
  /// for its natural height while that fits under the cap and for the cap past it, and yields
  /// to a shorter proposal down to ``PromptCardMetrics/contentMinHeight``.
  ///
  /// - **Order is load-bearing**: command, then detail, then toggle. The command is the thing
  ///   being approved, the viewport's first screenful is the only thing guaranteed to be read,
  ///   and `detail` is server-controlled and unbounded — putting it first let it push the
  ///   command out of the viewport entirely (measured).
  ///
  /// - Every `Text` inside is `.fixedSize(horizontal: false, vertical: true)`, so it sizes to
  ///   its ideal within the scroll content and every byte exists in the hierarchy and is
  ///   reachable by scrolling — never truncated, whatever height the region ends up at.
  /// - The layout answers the enclosing `VStack`'s squeeze by **shrinking the viewport**
  ///   rather than by dropping content, so the card fits the region it is given (Deny/Approve
  ///   stay on screen) *and* the text stays whole. A rigid `.frame(height:)` gets the first
  ///   half wrong: at the cap the card wants ~400pt while the fixed region with the keyboard
  ///   up on a small phone is ~230–370pt, so the card would over-subscribe its container and
  ///   push the buttons (and the composer) under the keyboard — the failure `.fixedSize`
  ///   would have caused, reached by another route.
  /// - Deliberately **not** `ViewThatFits(in: .vertical)`: that picks a *variant* per the
  ///   incoming proposal, so in this compressed `VStack` it would swap layouts as the
  ///   keyboard comes and goes; the layout instead keeps one variant and bounds it, which is
  ///   also what makes the height assertable (`ApprovalCardLayoutTests`).
  private var scrollableContent: some View {
    BoundedScrollRegion(reserve: PromptCardMetrics.transcriptReserve) {
      if let command = request.command, !command.isEmpty {
        commandText(command)
          .textSelection(.enabled)
          .padding(Self.commandPadding)
          .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 8))
      }

      if let detail = request.detail, !detail.isEmpty {
        Text(detail)
          .font(.footnote)
          .foregroundStyle(.secondary)
          // Wrap instead of truncating — the recovered-approval card (#30 workaround)
          // carries a multi-line detail and no command, so the copy must stay readable.
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      // Hidden on the push-tap-recovered card (#30 workaround): with no command and no
      // pattern to show, "Approve all" would whitelist an unseen danger pattern for the
      // whole session — a blind single approve is the most the recovery copy covers.
      // Its state is mirrored on the Approve button, which is rigid: with a long command
      // this control is below the fold, and a session-wide whitelist must never be
      // committed from a switch the user cannot see at the moment they approve.
      if request.offersSessionApproval {
        Toggle("Approve all in this session", isOn: $approveAll)
          .font(.footnote)
      }
    }
  }

  /// The command's text, laid out at its natural height — `.fixedSize` so it wraps to its
  /// ideal instead of truncating, which inside the scroll content is what keeps every byte
  /// reachable.
  private func commandText(_ command: String) -> some View {
    Text(command)
      .font(.callout.monospaced())
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// The primary button's title, which is where the session toggle's state is made visible at
  /// the moment the decision is committed (the toggle itself is a scroll away whenever the
  /// command is long). Pure so the mirroring is assertable without rendering the card.
  static func approveTitle(all: Bool) -> String {
    all ? "Approve all" : "Approve"
  }
}
