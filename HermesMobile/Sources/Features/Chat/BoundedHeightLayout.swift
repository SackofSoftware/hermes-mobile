import SwiftUI

/// Sizes its subview to `min(its natural height, cap)` when there is room — minus `reserve`,
/// which is held back for a greedy sibling — and yields to a shorter proposal down to
/// `minHeight`.
///
/// Two things a plain `.frame` cannot do together, both load-bearing for #65:
///
/// - **it asks for an ideal height a `ScrollView` will not volunteer.** A scroll view is
///   fully flexible along its scroll axis: hand it a concrete height proposal — which is what
///   every enclosing stack does — and it answers with the whole proposal, so short content
///   pads out to the cap and long content never scrolls, while a `ZStack`'d hidden twin plus a
///   `.frame(maxHeight:)` only clips the result. Probed with the height **unspecified**
///   (`ProposedViewSize(width:height: nil)`, below) the very same scroll view instead reports
///   its *content's* ideal height, which is exactly the number the card needs. That probe is
///   therefore the whole mechanism: propose a concrete height there and the region silently
///   goes back to "always the cap" (measured, and covered by
///   `ApprovalCardLayoutTests.testShortCommandHugsItsContentWithoutScrolling` /
///   `testUnmeasuredCardAccountsForTheWholeContentRegion` — the latter runs with no layout
///   pass at all, the shape a `sizeThatFits` snapshot render takes).
/// - **compressibility.** `.frame(height:)` fixes the region, which is deterministic but
///   incompressible: the card then demands ~400pt from a fixed region that is ~230–370pt with
///   the keyboard up, and the overflow pushes Deny/Approve out of reach. Shrinking a *scroll
///   viewport* costs nothing — every byte is still there and still reachable — so the region
///   is the right thing to squeeze, and taking the squeeze here is what keeps the buttons on
///   screen.
///
/// Used through ``BoundedScrollRegion``, the one region every prompt card's pinned row sits
/// over.
struct BoundedHeightLayout: Layout {
  /// Tallest the region will ask for, however long the content is.
  let cap: CGFloat
  /// Shortest it will compress to — never taller than the content itself.
  let minHeight: CGFloat
  /// Points of a *concrete* offer held back for a greedy sibling that is served after this one
  /// (the transcript), so it is not left with nothing.
  ///
  /// **Absolute on purpose**: it may only ever spend room the content did not want. Content
  /// that fits under `offer − reserve` still hugs itself exactly, and content that does not is
  /// cut by this much and no more — a *proportional* reserve instead scales with the offer, so
  /// it kept cutting a region that had room to fit (see `ApprovalCardView.transcriptReserve`).
  /// Applied above the floor only: under a real squeeze the floor still wins. `0` opts out.
  var reserve: CGFloat = 0

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard let content = subviews.first else { return .zero }
    // Height *unspecified* on purpose — see the type's doc comment: that is what makes a
    // scroll view report its content's ideal height instead of swallowing the proposal.
    let ideal = content.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
    return CGSize(
      width: proposal.width ?? ideal.width,
      height: height(natural: ideal.height, offered: proposal.height)
    )
  }

  /// The height rule, pure so it is assertable without rendering: the content's own height
  /// while it fits both the cap and `offered − reserve`, that bound past it — and never below
  /// `minHeight`, nor above the content when the content is shorter than `minHeight` (a
  /// one-line card is not padded out to a floor).
  func height(natural: CGFloat, offered: CGFloat?) -> CGFloat {
    let bounded = min(natural, cap)
    guard let offered else { return bounded }
    // The floor outranks the reserve: handing points back to a sibling is for the *comfortable*
    // case, and must never be the thing that squeezes the card below what it needs.
    let claimable = max(minHeight, offered - reserve)
    // One `min` covers both halves of the rule: `claimable` is at least `minHeight`, so the
    // result is at least `min(bounded, minHeight)` — i.e. the floor, or the content itself when
    // the content is shorter than the floor. No second clamp needed.
    return min(bounded, claimable)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    // Only the first subview, matching what `sizeThatFits` measures (and `CappedWidthLayout`).
    subviews.first?.place(
      at: CGPoint(x: bounds.minX, y: bounds.minY),
      anchor: .topLeading,
      proposal: ProposedViewSize(bounds.size)
    )
  }
}

/// The bounded, scrollable region of a prompt card (approval, clarify, sudo/secret): its
/// content stacked in a vertical `ScrollView` sized by ``BoundedHeightLayout`` — the natural
/// height while it fits under the Dynamic-Type-scaled cap, the cap past it, down to the floor
/// under a squeeze — with the live-geometry bottom fade that says "more below". The numbers
/// and their derivations are `ApprovalCardView`'s (`contentMaxHeightBase` / `Ceiling`,
/// `contentMinHeight`, `transcriptReserve`, the fade rules): every card's rigid chrome around
/// the region is the same size, so the same derivations hold.
struct BoundedScrollRegion<Content: View>: View {
  /// Spacing of the content's `VStack`.
  var spacing: CGFloat = 10
  /// Points handed back to the transcript (``BoundedHeightLayout/reserve``) — only for a card
  /// `ChatView` gives layout priority; without priority there is nothing to hand back.
  var reserve: CGFloat = 0
  @ViewBuilder var content: Content

  /// Bottom-fade state from live scroll geometry — see `ApprovalCardView.FadeState`.
  @State private var fade = ApprovalCardView.FadeState()

  /// The cap's Dynamic Type input, clamped by ``contentMaxHeight``.
  @ScaledMetric(relativeTo: .callout)
  private var scaledContentMaxHeight: CGFloat = ApprovalCardView.contentMaxHeightBase

  private var contentMaxHeight: CGFloat {
    min(scaledContentMaxHeight, ApprovalCardView.contentMaxHeightCeiling)
  }

  var body: some View {
    BoundedHeightLayout(
      cap: contentMaxHeight, minHeight: ApprovalCardView.contentMinHeight, reserve: reserve
    ) {
      ScrollView(.vertical) {
        VStack(alignment: .leading, spacing: spacing) {
          content
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
}

extension View {
  /// The prompt cards' shared chrome: padded, on a rounded tertiary background with a `tint`
  /// stroke, inset from the screen edges.
  func promptCardChrome(tint: Color) -> some View {
    padding()
      .background(Color(uiColor: .tertiarySystemBackground), in: .rect(cornerRadius: 14))
      .overlay(RoundedRectangle(cornerRadius: 14).stroke(tint.opacity(0.5)))
      .padding(.horizontal)
  }
}
