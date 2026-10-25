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
  /// it kept cutting a region that had room to fit (see `PromptCardMetrics.transcriptReserve`).
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
/// under a squeeze — with the live-geometry bottom fade that says "more below". Its numbers and
/// fade rules are ``PromptCardMetrics``.
struct BoundedScrollRegion<Content: View>: View {
  /// Spacing of the content's `VStack`.
  var spacing: CGFloat = 10
  /// Points handed back to the transcript (``BoundedHeightLayout/reserve``) — only for a card
  /// `ChatView` gives layout priority; without priority there is nothing to hand back.
  var reserve: CGFloat = 0
  @ViewBuilder var content: Content

  /// Bottom-fade state from live scroll geometry — see ``PromptCardMetrics/FadeState``.
  @State private var fade = PromptCardMetrics.FadeState()

  /// The cap's Dynamic Type input, clamped by ``contentMaxHeight``.
  @ScaledMetric(relativeTo: .callout)
  private var scaledContentMaxHeight: CGFloat = PromptCardMetrics.contentMaxHeightBase

  private var contentMaxHeight: CGFloat {
    min(scaledContentMaxHeight, PromptCardMetrics.contentMaxHeightCeiling)
  }

  var body: some View {
    BoundedHeightLayout(
      cap: contentMaxHeight, minHeight: PromptCardMetrics.contentMinHeight, reserve: reserve
    ) {
      ScrollView(.vertical) {
        VStack(alignment: .leading, spacing: spacing) {
          content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .scrollBounceBehavior(.basedOnSize)
      .onScrollGeometryChange(for: PromptCardMetrics.FadeState.self) { geometry in
        PromptCardMetrics.FadeState(
          isFaded: PromptCardMetrics.hasBottomOverflow(
            visibleRect: geometry.visibleRect, contentHeight: geometry.contentSize.height
          ),
          rampHeight: PromptCardMetrics.fadeRampHeight(viewportHeight: geometry.containerSize.height)
        )
      } action: { _, newFade in
        fade = newFade
      }
    }
    .mask { PromptCardMetrics.bottomFadeMask(fade) }
  }
}

/// The numbers and fade rules of ``BoundedScrollRegion``, shared by every prompt card. Every
/// card's rigid chrome around the region (one clamped title line, one button row) is the same
/// size, so one set of derivations holds for all of them. The derivations are made against the
/// approval card — the one whose content (the command being approved) the user must be able to
/// read before answering — and the other cards inherit them.
enum PromptCardMetrics {
  /// Unscaled base for the region's cap (``BoundedScrollRegion`` scales it with Dynamic Type,
  /// `@ScaledMetric(relativeTo: .callout)`, so a larger text size keeps roughly the same *line
  /// count* visible, then clamps it to ``contentMaxHeightCeiling``): on the approval card about
  /// a dozen monospaced `.callout` command lines plus the detail and the session toggle under
  /// them — enough for the shell commands agents actually ask about.
  static let contentMaxHeightBase: CGFloat = 320

  /// Hard ceiling on the scaled cap. `@ScaledMetric(relativeTo: .callout)` runs to roughly
  /// 3.3× at `.accessibility5`, i.e. a ~1050pt region — taller than any iPhone screen, let
  /// alone the fixed region one has left with the keyboard up.
  ///
  /// **Derived, not typed** (the `MarkdownTableView.columnMaxWidthCeiling` convention): three
  /// fifths of ``TranscriptLayout/shortestLayoutHeight``, so on the shortest screen this app
  /// can render at the remaining two fifths are always left for the pinned button row, the
  /// composer and a slice of transcript. Effective cap: 320pt through roughly `.accessibility1`,
  /// then flat at 340pt.
  ///
  /// It only binds in a *roomy* container. In a tight one ``BoundedHeightLayout`` yields to
  /// whatever the region offers regardless, so the ceiling is a guard against a runaway
  /// `@ScaledMetric`, never the thing that keeps the buttons on screen.
  static let contentMaxHeightCeiling: CGFloat = TranscriptLayout.shortestLayoutHeight * 0.6

  /// The region never compresses below this under a `VStack` squeeze (or below its own
  /// content, whichever is smaller — a one-line recovered card is never padded out to it).
  ///
  /// **Derived from what the user must be able to read, not chosen by taste**: on the shortest
  /// screen with the keyboard up the region lands exactly here, and there the approval card's
  /// *command* has to show three full `.callout` lines **at `.large`** outside the bottom ramp
  /// — `ApprovalCardView.commandPadding` (8) + 3 × 20.9 + ``bottomFadeHeight`` (24) ≈ 95,
  /// rounded to 96. That arithmetic only works because the command is the FIRST thing in the
  /// scroll: with the title and the detail above it, the same region showed about half a line
  /// of command (measured — no command pixels above the ramp at all with a long detail).
  ///
  /// Deliberately *not* scaled, so **the three-line contract is a `.large` one and degrades
  /// with Dynamic Type**: the readable band is a constant 64pt (96 − a 24pt ramp − 8pt of block
  /// padding), which is ~3.1 `.callout` lines at `.large`, ~1.3 at AX3 and under one at AX5
  /// (`ApprovalCardLayoutTests.testTheFloorsReadableBandDegradesWithDynamicType` pins those
  /// numbers off the real font metrics). Scaling it is not an option and not merely a taste
  /// call: three AX5 lines are ~210pt, and reserving that on a 320×352 keyboard-up region is
  /// measurably what pushes Deny/Approve — the safety-critical half — off the screen. A floor
  /// small enough to keep the answer reachable everywhere is the trade, and one the *cap* (not
  /// the floor) undoes as soon as there is any room: this binds only in the tightest
  /// configuration there is.
  static let contentMinHeight: CGFloat = 96

  /// Tallest the bottom ramp that signals "there is more below" is allowed to be.
  static let bottomFadeHeight: CGFloat = 24

  /// Points of the fixed region the content region hands back, so the transcript — the context
  /// for the decision — is not starved to nothing.
  ///
  /// `ChatView` gives a compressible card `.layoutPriority(1)` (without it the region collapses
  /// onto its floor with the keyboard up), and a priority-1 child is offered *everything* the
  /// other children do not strictly need: the greedy transcript's minimum is zero, so the card
  /// took the whole region and the transcript was measured at **0pt** on every phone.
  ///
  /// **Absolute, not a fraction.** A proportional reserve (this was `0.75` of the offer) cuts
  /// the region even when the content had room to fit: at an offer of 320 with 320pt of content
  /// it handed back 80pt — about four command lines — that nothing else had asked for, on the
  /// one surface whose rule is "the user must be able to read what they are approving". An
  /// absolute reserve can only ever spend room the card does not want: the content hugs itself
  /// whenever it fits under `offer − reserve`, and past that it gives back this much and no
  /// more. One 44pt tap target's worth, the HIG minimum — enough that the conversation behind
  /// the card is a row rather than a sliver, small enough to be invisible when the card is
  /// short. The floor still outranks it, so the shortest screen gives the card what it needs.
  static let transcriptReserve: CGFloat = 44

  /// What the bottom ramp looks like right now. Both halves come from **live scroll
  /// geometry** — whether anything is still hidden below the viewport, and how tall the ramp
  /// may be at the viewport's current height — rather than from the content's measured
  /// height: a measurement-derived flag would be true for the region's whole lifetime, so its
  /// last line would sit permanently inside the ramp and never be readable — the opposite of
  /// what #65 asks for. Mirrors `MarkdownTableView`'s trailing fade (#59).
  struct FadeState: Equatable {
    /// Is there still content below what the viewport shows?
    var isFaded: Bool = false
    /// How tall the ramp may be — see ``fadeRampHeight(viewportHeight:)``.
    var rampHeight: CGFloat = 0
  }

  /// Pure scroll-geometry rule behind the bottom fade: is there content below what the
  /// viewport shows? (Kept out of the view so it is unit-testable — the flag itself is
  /// private `@State`.) The 1pt slack absorbs fractional layout.
  ///
  /// Takes the whole `visibleRect` — the framework's own answer to "which part of the content
  /// is on screen" — rather than `contentOffset.y + containerSize.height`, mirroring
  /// `MarkdownTableView.hasTrailingOverflow`. Going false at the scroll end is the point: the
  /// last line of the content must be readable, not permanently ramped to transparent.
  static func hasBottomOverflow(visibleRect: CGRect, contentHeight: CGFloat) -> Bool {
    visibleRect.maxY < contentHeight - 1
  }

  /// The ramp is a **fraction** of the viewport, capped at ``bottomFadeHeight``.
  ///
  /// A constant 24pt ramp is fine against `MarkdownTableView`'s trailing edge, whose viewport
  /// is always at least a screen wide — but this region compresses, and against a squeezed
  /// one a fixed ramp would tint most of what is left toward transparent: a hint would have
  /// eaten the content it was hinting about, on the one surface where the user must be able
  /// to read what they are answering. A quarter leaves three quarters of any viewport, at any
  /// size, fully opaque.
  static func fadeRampHeight(viewportHeight: CGFloat) -> CGFloat {
    max(0, min(bottomFadeHeight, viewportHeight / 4))
  }

  /// The overflow hint, as `.mask` content: opaque everywhere except a `rampHeight` ramp at
  /// the bottom, and opaque there too when nothing is hidden below.
  ///
  /// Same rationale as `MarkdownTableView`'s trailing fade (#59): iOS only flashes the
  /// scroll indicator while a drag is in flight, so without the ramp a scrollable card
  /// looks exactly like the clipped one #65 reported. Applied unconditionally (an `if`
  /// would rebuild the `ScrollView` and throw away the user's scroll offset the moment the
  /// state flipped — which, driven by scroll geometry, is every time they reach the end);
  /// when nothing overflows the mask is fully opaque, i.e. a no-op. Vertical, so unlike
  /// #59's horizontal fade there is no layout-direction mirroring to handle.
  @ViewBuilder
  static func bottomFadeMask(_ fade: FadeState) -> some View {
    VStack(spacing: 0) {
      Rectangle().fill(Color.black)
      LinearGradient(
        colors: [.black, .black.opacity(fade.isFaded ? 0 : 1)],
        startPoint: .top,
        endPoint: .bottom
      )
      .frame(height: fade.rampHeight)
    }
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
