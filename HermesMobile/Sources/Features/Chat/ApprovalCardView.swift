import HermesKit
import SwiftUI

/// Pinned card shown when the agent requests approval for an action. Approve/Deny,
/// with an "approve all" toggle for the rest of the session.
///
/// The card lives in `ChatView`'s outer `VStack`, i.e. the **non-scrolling** region between
/// the greedy transcript and the composer. That is the whole reason the command is rendered
/// by ``commandBlock(_:)`` — a measured, capped, scrollable region — instead of a bare
/// `Text`: when the fixed region runs short (long command, keyboard up, suggestion panel
/// showing) the `VStack` compresses whatever it can, and a plain `Text` answers that
/// squeeze by truncating with no way to reach the rest (issue #65 — users had to leave and
/// re-enter the chat, where the keyboard was down, to read what they were approving).
/// `.fixedSize` alone would invert the problem and push Approve/Deny off screen.
struct ApprovalCardView: View {
  let request: ApprovalRequest
  let onApprove: (_ all: Bool) -> Void
  let onDeny: () -> Void

  @State private var approveAll = false

  /// Natural (unclipped) height of the command text, once the first geometry callback has
  /// landed — `nil` before that.
  @State private var commandContentHeight: CGFloat?

  /// Tallest the command block grows before it scrolls in place. Scaled with Dynamic Type
  /// so a larger text size keeps roughly the same *line count* visible rather than fewer
  /// and fewer lines.
  @ScaledMetric(relativeTo: .callout)
  private var commandMaxHeight: CGFloat = ApprovalCardView.commandMaxHeightBase

  /// Unscaled base for ``commandMaxHeight``: about ten monospaced `.callout` lines — enough
  /// for the shell commands agents actually ask about, while leaving the toggle and the
  /// Deny/Approve row on screen on the smallest supported device with the keyboard up.
  static let commandMaxHeightBase: CGFloat = 220

  /// Height of the bottom ramp that signals "there is more command below".
  static let bottomFadeHeight: CGFloat = 24

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("Approval requested", systemImage: "lock.shield")
        .font(.subheadline.weight(.semibold))

      if let detail = request.detail, !detail.isEmpty {
        Text(detail)
          .font(.footnote)
          .foregroundStyle(.secondary)
          // Wrap instead of truncating — the recovered-approval card (#30 workaround)
          // carries a multi-line detail and no command, so the copy must stay readable.
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      if let command = request.command, !command.isEmpty {
        commandBlock(command)
      }

      // Hidden on the push-tap-recovered card (#30 workaround): with no command and no
      // pattern to show, "Approve all" would whitelist an unseen danger pattern for the
      // whole session — a blind single approve is the most the recovery copy covers.
      if request.offersSessionApproval {
        Toggle("Approve all in this session", isOn: $approveAll)
          .font(.footnote)
      }

      HStack(spacing: 12) {
        Button(role: .destructive, action: onDeny) {
          Text("Deny").frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        Button { onApprove(approveAll) } label: {
          Text("Approve").frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
      }
    }
    .padding()
    .background(Color(uiColor: .tertiarySystemBackground), in: .rect(cornerRadius: 14))
    .overlay(RoundedRectangle(cornerRadius: 14).stroke(.orange.opacity(0.5)))
    .padding(.horizontal)
  }

  /// The command, in a vertical `ScrollView` pinned to an **explicitly measured** height:
  /// its natural height while that fits under ``commandMaxHeight``, the cap past it.
  ///
  /// - `.fixedSize(horizontal: false, vertical: true)` lets the `Text` size to its ideal
  ///   inside the scroll content, so every byte of the command exists in the hierarchy and
  ///   is reachable by scrolling — never truncated.
  /// - The explicit `.frame(height:)` is what the enclosing `VStack` can no longer squeeze:
  ///   a fixed height is not compressible, so the region the card gets is deterministic and
  ///   Deny/Approve always stay laid out. A short command still hugs its content exactly as
  ///   before this change — no dead space, no scrolling.
  /// - Deliberately **not** `ViewThatFits(in: .vertical)`: that picks per the *incoming
  ///   proposal*, which in this compressed `VStack` is precisely the squeezed size that
  ///   caused #65, so it would reintroduce the ambiguity instead of removing it. A measured
  ///   frame also makes the height assertable (`ApprovalCardLayoutTests`).
  /// - Before the first measurement lands the cap is proposed as a *maximum* rather than a
  ///   hard height, and ``commandSizer(_:)`` supplies the ideal underneath it, so the block
  ///   never reports a collapsed first frame.
  private func commandBlock(_ command: String) -> some View {
    let overflows = Self.overflows(contentHeight: commandContentHeight, cap: commandMaxHeight)
    return ZStack(alignment: .topLeading) {
      commandSizer(command)

      ScrollView(.vertical) {
        commandText(command)
          .textSelection(.enabled)
          .onGeometryChange(for: CGFloat.self, of: \.size.height) { height in
            commandContentHeight = height
          }
      }
      .scrollBounceBehavior(.basedOnSize)
    }
    .frame(height: commandContentHeight.map { min($0, commandMaxHeight) })
    .frame(maxHeight: commandContentHeight == nil ? commandMaxHeight : nil)
    // Masked before the padded background so the *text* fades out and the block's own
    // rounded rect stays solid.
    .mask { Self.bottomFadeMask(isFaded: overflows) }
    .padding(8)
    .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 8))
    .accessibilityIdentifier(Self.commandBlockAccessibilityID)
  }

  /// Invisible twin of the command text, present only to give the block an **ideal height**.
  ///
  /// A `ScrollView` is fully flexible along its scroll axis, so its own ideal height is
  /// *zero*: `.frame(maxHeight:)` can cap that but cannot conjure one. Without this twin the
  /// unmeasured first pass therefore sizes the block to its padding alone, and every layout
  /// that asks the card how tall it wants to be **before** `onGeometryChange` has fired gets
  /// an answer one command too short — measured: the short-command card came back 19.3pt
  /// short and rendered clipped at both ends (`ChatSnapshotTests.testApprovalCard`, which is
  /// exactly a single unmeasured `sizeThatFits` pass, and would be a one-frame squeeze of the
  /// very content #65 is about). Sized by the same builder as the real text, so the two can
  /// never disagree; `.hidden()` keeps it out of the render and the accessibility tree while
  /// it still participates in layout.
  ///
  /// The twin carries **its own** `maxHeight` clamp, and that is load-bearing rather than a
  /// duplicate of the block's: the text inside is `.fixedSize`, so it answers any proposal
  /// with its full natural height. Unclamped, a 20-line command therefore reports ~1258pt as
  /// the `ZStack`'s size — the sibling `ScrollView` is handed all of it and the outer frame
  /// merely clips the result, i.e. the cap is defeated and nothing scrolls (measured: the
  /// block came back 1258pt tall). Clamped, the twin reports `min(natural, cap)`, which is
  /// exactly the ideal the block should have.
  private func commandSizer(_ command: String) -> some View {
    commandText(command)
      .hidden()
      .frame(maxHeight: commandMaxHeight)
      .accessibilityHidden(true)
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

  /// Identifies the command block for the measured layout tests (the scroll view itself is
  /// private `body` structure).
  static let commandBlockAccessibilityID = "approval-command-block"

  /// Does the command overrun the cap — i.e. is the block scrolling rather than hugging?
  /// Pure so the fade's trigger is assertable without rendering. Unmeasured content
  /// (`nil`) never fades: the block is bounded by the cap but nothing is known to be
  /// hidden yet.
  static func overflows(contentHeight: CGFloat?, cap: CGFloat) -> Bool {
    guard let contentHeight else { return false }
    return contentHeight > cap + 1  // 1pt slack absorbs fractional layout.
  }

  /// The overflow hint, as `.mask` content: opaque everywhere except a
  /// ``bottomFadeHeight`` ramp at the bottom, and opaque there too when `isFaded` is false.
  ///
  /// Same rationale as `MarkdownTableView`'s trailing fade (#59): iOS only flashes the
  /// scroll indicator while a drag is in flight, so without the ramp a scrollable command
  /// looks exactly like the clipped one #65 reported. Applied unconditionally (an `if`
  /// would rebuild the `ScrollView` and throw away the user's scroll offset the moment the
  /// state flipped); when nothing overflows the mask is fully opaque, i.e. a no-op. Vertical,
  /// so unlike #59's horizontal fade there is no layout-direction mirroring to handle.
  @ViewBuilder
  static func bottomFadeMask(isFaded: Bool) -> some View {
    VStack(spacing: 0) {
      Rectangle().fill(Color.black)
      LinearGradient(
        colors: [.black, .black.opacity(isFaded ? 0 : 1)],
        startPoint: .top,
        endPoint: .bottom
      )
      .frame(height: bottomFadeHeight)
    }
  }
}
