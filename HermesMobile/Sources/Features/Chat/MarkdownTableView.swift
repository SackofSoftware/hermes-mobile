import SwiftUI

/// A pipe table from chat Markdown (#27), rendered as a `Grid` inside a horizontal
/// `ScrollView`.
///
/// The previous inline renderer gave every cell `.frame(maxWidth: .infinity)`, so all
/// columns claimed equal flexible width: nothing bounded the grid to the screen, a wide
/// table clipped at the trailing edge with its cells truncated, and the grid's unstable
/// measured size inside the `UIHostingConfiguration`-hosted collection-view cell produced
/// an intermittent blank gap above/below the table (issue #59).
///
/// Now each cell takes its *content's* natural width capped at ``columnMaxWidth`` (see
/// ``CappedWidthLayout``), and the grid pans horizontally when the columns total more
/// than the screen. `.scrollBounceBehavior(.basedOnSize)` keeps a table that already fits
/// from bouncing. The hosting cell gets a stable height from both halves of that: a
/// horizontal `ScrollView` hugs its content vertically, *and* the content's height no
/// longer varies with the width it is offered (``CappedWidthLayout`` sizes from the cap,
/// not from the proposal — its doc comment has the measurements).
///
/// A panned table would otherwise look exactly like the clipped one #59 reported (the
/// trailing column is cut mid-word and iOS only flashes the scroll indicator while a drag
/// is in flight), so the trailing edge fades out whenever there is content still to the
/// right — see ``hasTrailingOverflow(visibleRect:contentWidth:layoutDirection:)``.
struct MarkdownTableView: View {
  let headers: [String]
  let rows: [[String]]

  /// Per-column ceiling at the default content size. Wide enough for a readable measure
  /// (~35–40 characters at body size) yet narrow enough that a multi-column table still
  /// shows more than one column on an iPhone. Cells shorter than this take their natural
  /// width; longer ones wrap.
  ///
  /// This is the *unscaled base*, and only the base: the effective cap is this value scaled by
  /// Dynamic Type and then clamped to ``columnMaxWidthCeiling``, where the measured scale and
  /// the reason for the clamp are recorded.
  static let columnMaxWidth: CGFloat = 260

  /// Hard ceiling on the scaled cap: the width a transcript row gets on the narrowest layout
  /// this app can be rendered at — ``TranscriptLayout/narrowestRowWidth``, i.e. 288pt.
  ///
  /// **Derived from the layout, not copied from it**: widening the transcript's section insets
  /// (or re-deriving its narrowest width) without moving this ceiling would silently re-open
  /// the panning regression below with every test still green.
  ///
  /// Scaling the cap at all exists so the "~35–40 characters" rationale survives a raised text
  /// size instead of squeezing every cell down to two words per line. The clamp exists because
  /// unclamped the scale overshoots the screen, and then a **single-column** table — the one
  /// shape that physically cannot overflow at `.large` — has to be panned to read each line of
  /// ordinary prose. Measured *unclamped* scale, the input to the clamp and **not** the
  /// effective cap: 260pt at `.large`, 283.7pt at `.xLarge`, 307.3pt at `.xxLarge`, 342.7pt at
  /// `.xxxLarge`, 401.7pt at `.accessibility1`, 567.3pt at `.accessibility3`, 732.7pt at
  /// `.accessibility5`. Only the first two come in under the ceiling, so the **effective** cap
  /// is 260 / 283.7pt at `.large` / `.xLarge` and then flat at 288pt from `.xxLarge` upwards —
  /// every accessibility size included. (A 343pt ceiling — the same derivation off the 375pt
  /// narrowest *default* iPhone — still panned a single-column table from `.xxLarge` up on a
  /// 288pt row: measured content widths 307.3 / 337.3 / 343pt.)
  ///
  /// Clamping is strictly better than *both* alternatives, which is why it wins over "keep the
  /// unclamped scale" and over "go back to a fixed 260pt": measured cell height for the same
  /// sentence at `.accessibility3` is 336pt at a fixed 260pt cap versus 240pt clamped, and at
  /// `.accessibility5` 683pt versus 435pt. So the clamp reads without panning *and* is shorter
  /// than the fixed cap. `.large` is untouched either way (`min(260, 288) == 260`).
  ///
  /// It is deliberately a **constant**, not the width the view is offered: the measured size
  /// must stay independent of the proposal (see ``CappedWidthLayout``), and a screen-derived
  /// constant keeps that invariant while a `GeometryReader` would destroy it.
  static let columnMaxWidthCeiling: CGFloat = TranscriptLayout.narrowestRowWidth

  /// Gap between columns. Also the width an all-empty column contributes to the grid.
  static let columnSpacing: CGFloat = 12

  /// Gap between rows.
  private static let rowSpacing: CGFloat = 6

  /// Width of the trailing fade that signals "there is more table to the right".
  private static let trailingFadeWidth: CGFloat = 24

  @ScaledMetric(relativeTo: .body) private var scaledColumnMaxWidth: CGFloat = MarkdownTableView.columnMaxWidth

  /// Which physical edge the *logical* trailing edge is on — see
  /// ``hasTrailingOverflow(visibleRect:contentWidth:layoutDirection:)``.
  @Environment(\.layoutDirection) private var layoutDirection

  /// The cap actually handed to each cell: scaled with Dynamic Type, clamped to the screen.
  private var columnCap: CGFloat { min(scaledColumnMaxWidth, Self.columnMaxWidthCeiling) }

  /// True while the scroll view has content past its trailing edge (drives the fade).
  ///
  /// `@State` inside a `UIHostingConfiguration` cell can survive recycling when the view
  /// structure matches, so a cell reused from a wide table onto a fitting one can carry a
  /// stale `true` — but only until the geometry event that the changed content size emits
  /// in the same layout pass, so the worst case is one frame of a 24pt fade. Resetting it
  /// on the data would trade that for the mirror-image flicker on every wide table.
  ///
  /// The *pan offset* is a separate question, and it does **not** need scoping to the row: a
  /// recycled cell always re-opens its table at the leading edge (measured in a real
  /// `UICollectionView` — `testRecycledRowShowsItsTableFromTheLeadingEdge`, which also measures
  /// that a pan does survive when the cell is *not* recycled, so the reset is the platform's
  /// behaviour and not an artifact of the harness). An `.id()` keyed to the row would be a
  /// no-op here.
  @State private var trailingOverflow = false

  var body: some View {
    // Ragged rows pad with empty cells up to the widest row (or the header count).
    let columnCount = max(headers.count, rows.map(\.count).max() ?? 0)
    ScrollView(.horizontal) {
      Grid(
        alignment: .leadingFirstTextBaseline,
        horizontalSpacing: Self.columnSpacing,
        verticalSpacing: Self.rowSpacing
      ) {
        GridRow {
          ForEach(0..<columnCount, id: \.self) { col in
            cell(col < headers.count ? headers[col] : "", isHeader: true)
          }
        }
        Divider()
        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
          GridRow {
            ForEach(0..<columnCount, id: \.self) { col in
              cell(col < row.count ? row[col] : "", isHeader: false)
            }
          }
        }
      }
      // Re-applied rather than inherited from `MarkdownText`, so cell selection never depends
      // on inheritance through this `ScrollView` (idempotent and measured size-neutral). It
      // does not *guarantee* selection inside the collection view — `SelectableText`'s doc
      // comment records why, and #59 tracks the device check. Cells cannot use
      // `SelectableText` itself: its `sizeThatFits` returns the proposed width verbatim, so
      // every cell would claim the full cap and small tables would stop rendering inline.
      .textSelection(.enabled)
    }
    .scrollBounceBehavior(.basedOnSize)
    .onScrollGeometryChange(for: Bool.self) { [layoutDirection] geometry in
      Self.hasTrailingOverflow(
        visibleRect: geometry.visibleRect,
        contentWidth: geometry.contentSize.width,
        layoutDirection: layoutDirection
      )
    } action: { _, hasOverflow in
      trailingOverflow = hasOverflow
    }
    // Applied unconditionally (an `if` here would rebuild the `ScrollView` and throw away the
    // user's pan offset the moment they reached the end); when nothing overflows the mask is
    // fully opaque, i.e. a no-op.
    .mask { Self.trailingFadeMask(isFaded: trailingOverflow, layoutDirection: layoutDirection) }
  }

  /// The fade, as `.mask` content: opaque everywhere except a 24pt ramp at the **logical**
  /// trailing edge, and opaque there too when `isFaded` is false.
  ///
  /// Only *half* of this mirrors by itself, which is why the direction has to be passed in
  /// (measured, 100pt wide, alpha sampled off the rendered mask):
  ///
  /// - the `HStack` **does** mirror, so under `.rightToLeft` the ramp's 24pt slot correctly
  ///   moves to the physical left — the logical trailing edge;
  /// - `LinearGradient`'s `.leading`/`.trailing` unit points **do not**, so inside that slot the
  ///   ramp still ran left→right: opaque at the outer edge and transparent 24pt *inside* it,
  ///   i.e. a hard cut at the table's edge plus a transparent band across its columns (alpha
  ///   228 at x=1 where the fade belongs, 255 everywhere it does not).
  ///
  /// Reversing the stops in RTL puts the opaque end back against the content. Extracted from
  /// `body` so `testFadeMaskSitsAtTheLogicalTrailingEdge` can render exactly this. Both halves
  /// fill explicitly so neither half's alpha can depend on an ambient `foregroundStyle`.
  @ViewBuilder
  static func trailingFadeMask(isFaded: Bool, layoutDirection: LayoutDirection) -> some View {
    let stops: [Color] = [.black, .black.opacity(isFaded ? 0 : 1)]
    HStack(spacing: 0) {
      Rectangle().fill(Color.black)
      LinearGradient(
        colors: layoutDirection == .rightToLeft ? stops.reversed() : stops,
        startPoint: .leading,
        endPoint: .trailing
      )
      .frame(width: trailingFadeWidth)
    }
  }

  /// Pure scroll-geometry rule behind the trailing fade: is there still content past the
  /// **logical** trailing edge of what the viewport shows? (Kept out of the view so it is
  /// unit-testable — the fade itself is private `@State`.) The 1pt slack absorbs fractional
  /// layout.
  ///
  /// Layout-direction-aware because SwiftUI *mirrors* a horizontal `ScrollView` under
  /// `.rightToLeft`: measured on a 390pt viewport over 516.7pt of content, an RTL table opens
  /// already at `contentOffset.x == 126.7` — parked against the right, with every hidden column
  /// to the **left**. A "trailing means larger x" rule therefore answers backwards there: no
  /// fade while the whole rest of the table is waiting off-screen, then a fade once the user has
  /// panned to the end. The `.mask` mirrors only halfway by itself and needs the direction too
  /// — see ``trailingFadeMask(isFaded:layoutDirection:)``.
  ///
  /// Takes the whole `visibleRect` — the framework's own answer to "which part of the content is
  /// on screen" — rather than `contentOffset.x + containerSize.width`, so the rule keeps asking
  /// the right question if a horizontal content inset is ever introduced. This view's insets are
  /// zero, where the two are equal.
  static func hasTrailingOverflow(
    visibleRect: CGRect,
    contentWidth: CGFloat,
    layoutDirection: LayoutDirection
  ) -> Bool {
    switch layoutDirection {
    case .rightToLeft: return visibleRect.minX > 1
    default: return visibleRect.maxX < contentWidth - 1
    }
  }

  /// One table cell: left-aligned inline Markdown that wraps at the column cap rather
  /// than being squeezed into an equal-width flexible column or truncated.
  private func cell(_ value: String, isHeader: Bool) -> some View {
    CappedWidthLayout(maxWidth: columnCap) {
      Text(MarkdownText.inline(value))
        .fontWeight(isHeader ? .semibold : nil)
        .multilineTextAlignment(.leading)
    }
  }
}

/// Sizes its single subview to the subview's natural width, capped at `maxWidth` — text
/// longer than the cap wraps instead of running off.
///
/// A plain `.frame(maxWidth:)` cannot do this **inside a horizontal `ScrollView`**: the
/// scroll view proposes `nil` width in its scroll axis (measured), and a flexible frame
/// answering a `nil` proposal passes `nil` straight through to its child, so the `Text`
/// reports its full single-line width and is merely clipped to the frame's clamped
/// `maxWidth` — the exact truncation issue #59 is about (measured: a three-lines-worth
/// sentence comes back 260×20pt, one clipped line, versus 260×64pt / three lines here).
///
/// The cap is proposed **regardless of the incoming proposal**, so the reported size is
/// derived only from the content. Two measured reasons, both load-bearing:
///
/// - `Text` answers a *zero* width proposal with zero width and ~1780pt of
///   character-wrapped height, so honouring a `.zero` probe (SwiftUI's standard
///   minimum-size question) would advertise a cell that is 0pt wide and absurdly tall —
///   the same family as the blank 60×645 sliver a compressed-fit render produced while
///   this view was being written.
/// - A size that cannot vary with the proposal is what makes the hosting
///   `UIHostingConfiguration` cell's height stable (#59's phantom vertical gap): the
///   table measures the same at 200pt, 390pt and 700pt of offered width (measured).
///
/// The child's own answer is returned **unclamped**. For `Text` it never exceeds the cap
/// (an 80-character unbreakable run character-wraps to 259.7×64pt rather than truncating
/// — measured), but a child that genuinely cannot compress must be allowed to say so:
/// reporting less than it needs would place it in a too-small box and truncate it, which
/// is the bug this view exists to fix. Overflowing the cap merely costs a little panning.
struct CappedWidthLayout: Layout {
  let maxWidth: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard let subview = subviews.first else { return .zero }
    return subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    subviews.first?.place(
      at: CGPoint(x: bounds.minX, y: bounds.minY),
      anchor: .topLeading,
      proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
    )
  }
}
