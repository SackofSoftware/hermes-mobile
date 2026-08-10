import HermesKit
import SwiftUI
import UIKit
import XCTest

@testable import HermesMobile

/// Measured (not eyeballed) acceptance checks for the approval card's command block (#65).
///
/// A snapshot of a command that *scrolls* and a snapshot of one that was *truncated* are the
/// same first screenful — what tells them apart is whether the rest of the command still
/// exists in the hierarchy and can be reached. So these tests host the real card in a window,
/// force a layout pass, and read the numbers straight off the `UIScrollView` the block
/// renders into:
///
/// - a command past the cap has `contentSize.height > bounds.height`, holds *all* of its
///   lines, and can be scrolled to its last one (nothing is thrown away);
/// - the card's own height is bounded by the cap rather than by the command's length, so
///   Deny/Approve stay inside a tight vertical budget however long the command is — the
///   half `.fixedSize` alone would have broken;
/// - a command that fits keeps its natural height exactly as before this change (no dead
///   space, no scrolling);
/// - the command-less recovered card (#30 workaround) grows no scroll view at all.
///
/// Dynamic Type is pinned to `.large`: the cap is `@ScaledMetric`, so every numeric
/// threshold below would otherwise follow the simulator's text-size setting.
final class ApprovalCardLayoutTests: XCTestCase {
  /// iPhone 13 Pro width — the same viewport the snapshot suite pins.
  private static let viewportWidth: CGFloat = 390

  /// A deliberately tight vertical budget for the card. `ChatView` gives it the
  /// non-scrolling region between the transcript and the composer, and #65 happens when
  /// that region runs short (long command, keyboard up). The contract under test is not
  /// that the card fits some particular device, but that its height is decided by the cap
  /// and therefore *does not grow with the command* — measured at 458pt here, against the
  /// ~1500pt the same card would want if the command sized itself freely
  /// (`testUncappedCommandBlockWouldBlowTheBudget`).
  private static let heightBudget: CGFloat = 480

  /// Kept alive for the duration of a test: a hosted view only lays out for real while its
  /// window exists, and SwiftUI won't materialise the `UIScrollView` otherwise.
  private var windows: [UIWindow] = []

  override func tearDown() {
    for window in windows {
      window.isHidden = true
      window.rootViewController = nil
    }
    windows = []
    super.tearDown()
  }

  // MARK: - Overflow (the #65 fix)

  func testLongCommandScrollsInsteadOfBeingTruncated() throws {
    let scroll = try commandBlock(for: Self.longCommand)

    XCTAssertEqual(
      scroll.bounds.height, ApprovalCardView.commandMaxHeightBase, accuracy: 1,
      "Past the cap the block must stop growing at exactly the cap"
    )
    XCTAssertGreaterThan(
      scroll.contentSize.height, scroll.bounds.height,
      "A command taller than the cap must have scrollable content, not clipped-away lines"
    )
    // Not merely a line or two past the cap: all 20 lines are still in the hierarchy.
    XCTAssertGreaterThan(
      scroll.contentSize.height, scroll.bounds.height * 4,
      "Every line of the command must survive the cap, not just the first screenful plus slack"
    )
    // And the last of them is reachable — the whole point of the issue.
    let end = scroll.contentSize.height - scroll.bounds.height
    scroll.setContentOffset(CGPoint(x: 0, y: end), animated: false)
    XCTAssertEqual(
      scroll.contentOffset.y, end, accuracy: 1,
      "The hidden tail of the command must be scrollable into view"
    )
  }

  /// The other half of #65: `.fixedSize` alone would have made the command readable by
  /// pushing Approve/Deny off screen. The card's height must be decided by the cap, so a
  /// 200-line command costs exactly as much room as a 20-line one.
  func testCardHeightIsBoundedByTheCapNotTheCommandLength() {
    let twenty = cardHeight(for: Self.longCommand)
    let twoHundred = cardHeight(for: Self.veryLongCommand)

    XCTAssertEqual(
      twenty, twoHundred, accuracy: 1,
      "A ten-times longer command must not make the card any taller — the cap decides"
    )
    XCTAssertLessThanOrEqual(
      twoHundred, Self.heightBudget,
      "The card (buttons included) must stay inside the fixed region's budget at any command length"
    )
    XCTAssertGreaterThan(twenty, ApprovalCardView.commandMaxHeightBase, "Sanity: the block is at its cap")
  }

  /// The control that makes the assertions above a measurement rather than a property of the
  /// harness: rendered the pre-fix way — a bare `.fixedSize`d `Text`, free to take its ideal
  /// height — the very same command overruns the budget several times over. Measured at the
  /// block's real width, read off the live card so it cannot drift from the padding.
  func testUncappedCommandBlockWouldBlowTheBudget() throws {
    let blockWidth = try commandBlock(for: Self.longCommand).bounds.width
    XCTAssertGreaterThan(blockWidth, 0)

    let uncapped = hostedSize(
      of: Text(Self.longCommand).font(.callout.monospaced()).fixedSize(horizontal: false, vertical: true),
      width: blockWidth
    )
    XCTAssertGreaterThan(
      uncapped.height, Self.heightBudget,
      "Fixture sanity: the sample command must genuinely need capping, otherwise the budget test proves nothing"
    )
    XCTAssertGreaterThan(
      uncapped.height, ApprovalCardView.commandMaxHeightBase * 4,
      "Fixture sanity: the command must overrun the cap by a wide margin"
    )
  }

  // MARK: - Below the cap (the common case, unchanged)

  func testShortCommandHugsItsContentWithoutScrolling() throws {
    let scroll = try commandBlock(for: "rm -rf build/ && git clean -fdx")

    XCTAssertGreaterThan(scroll.contentSize.height, 0, "The command must actually be laid out, not collapsed")
    XCTAssertLessThan(
      scroll.bounds.height, ApprovalCardView.commandMaxHeightBase,
      "A one-line command must hug its content, not pad out to the cap"
    )
    XCTAssertEqual(
      scroll.bounds.height, scroll.contentSize.height, accuracy: 1,
      "Below the cap the block's height must equal its content's — no dead space, nothing to scroll"
    )
    XCTAssertFalse(
      ApprovalCardView.overflows(
        contentHeight: scroll.contentSize.height, cap: ApprovalCardView.commandMaxHeightBase
      ),
      "A fitting command must not be reported as overflowing, i.e. must not be faded"
    )
  }

  /// A command that fits *exactly* to the cap is the boundary between the two shapes, and it
  /// must land on the non-scrolling side rather than fading a block with nothing hidden.
  func testCommandAtTheCapDoesNotScroll() throws {
    let scroll = try commandBlock(for: Self.commandFillingTheCap)
    XCTAssertLessThanOrEqual(scroll.bounds.height, ApprovalCardView.commandMaxHeightBase + 1)
    XCTAssertLessThanOrEqual(
      scroll.contentSize.height, scroll.bounds.height + 1,
      "A command that just fits the cap has nothing to scroll to"
    )
  }

  // MARK: - The command-less card (#30 recovery path)

  /// The recovered approval (`command == nil`) and a request whose command decoded empty both
  /// skip the block entirely: no scroll view is created, and the card measures exactly what it
  /// did before this work.
  func testRecoveredCardRendersNoCommandBlock() throws {
    for (name, request) in [
      ("recovered", ChatFeature.recoveredApprovalRequest),
      ("empty command", ApprovalRequest(command: "", detail: "Delete the build directory")),
    ] {
      let host = hostedCard(request)
      XCTAssertTrue(
        Self.scrollViews(in: host.view).isEmpty,
        "\(name): a card with no command must not host a command block at all"
      )
      XCTAssertGreaterThan(fittedHeight(of: host), 0, "\(name): the card must still lay out")
      XCTAssertLessThan(
        fittedHeight(of: host), cardHeight(for: "rm -rf build/"),
        "\(name): a command-less card must be shorter than one carrying a command"
      )
    }
  }

  // MARK: - The overflow rule

  /// The fade's trigger, as a pure rule — the view's own measurement is private `@State`.
  func testOverflowRule() {
    let cap = ApprovalCardView.commandMaxHeightBase
    // Nothing measured yet: bounded by the cap, but nothing is *known* to be hidden.
    XCTAssertFalse(ApprovalCardView.overflows(contentHeight: nil, cap: cap))
    XCTAssertFalse(ApprovalCardView.overflows(contentHeight: 20, cap: cap))
    XCTAssertFalse(ApprovalCardView.overflows(contentHeight: cap, cap: cap))
    // Fractional layout slack must not switch the fade on.
    XCTAssertFalse(ApprovalCardView.overflows(contentHeight: cap + 0.4, cap: cap))
    XCTAssertTrue(ApprovalCardView.overflows(contentHeight: cap + 40, cap: cap))
    XCTAssertTrue(ApprovalCardView.overflows(contentHeight: 1258, cap: cap))
    // A zero-height (or degenerate) measurement never fades either.
    XCTAssertFalse(ApprovalCardView.overflows(contentHeight: 0, cap: cap))
  }

  /// The fade must sit at the **bottom** edge — the direction the hidden lines are in — and be
  /// a no-op when nothing overflows. Asserted on alpha sampled from the rendered mask, because
  /// a ramp at the wrong edge still snapshots as "a card with a soft edge".
  @MainActor
  func testBottomFadeMaskRampsAtTheBottomEdgeOnly() throws {
    let faded = try Self.maskAlphas(isFaded: true)
    XCTAssertGreaterThan(faded[2], 240, "The top of the block is never faded")
    XCTAssertGreaterThan(faded[50], 240, "The middle of the block is never faded")
    XCTAssertLessThan(faded[98], 40, "The bottom edge must fade out to hint at the hidden lines")

    let plain = try Self.maskAlphas(isFaded: false)
    for y in [2, 50, 88, 98] {
      XCTAssertGreaterThan(plain[y], 240, "An unfaded mask must be opaque at y=\(y)")
    }
  }

  // MARK: - Fixtures

  /// ~20 lines — comfortably past the 220pt cap at the default content size (the same shape
  /// the snapshot suite uses).
  private static let longCommand = (1...20)
    .map { "step \($0): xcodebuild -workspace HermesMobile.xcworkspace -scheme Target\($0) test" }
    .joined(separator: "\n")

  /// Ten times longer again: the card must not notice.
  private static let veryLongCommand = (1...200)
    .map { "step \($0): xcodebuild -workspace HermesMobile.xcworkspace -scheme Target\($0) test" }
    .joined(separator: "\n")

  /// Short, single-token lines: at `.callout` (~18.3pt per line, measured) ten of them come to
  /// ~183pt — under the 220pt cap, but close enough to it to be the boundary case.
  private static let commandFillingTheCap = (1...10).map { "line \($0)" }.joined(separator: "\n")

  // MARK: - Helpers

  /// Hosts the card in a real window at ``viewportWidth`` and forces a layout pass. The window
  /// is only as tall as the budget the card has to live inside, so the measurements below are
  /// taken under #65's own condition rather than in unlimited space.
  private func hostedCard(
    _ request: ApprovalRequest, dynamicType: DynamicTypeSize = .large
  ) -> UIHostingController<AnyView> {
    let host = UIHostingController(
      rootView: AnyView(
        ApprovalCardView(request: request, onApprove: { _ in }, onDeny: {})
          .dynamicTypeSize(dynamicType)
      )
    )
    let window = UIWindow(
      frame: CGRect(x: 0, y: 0, width: Self.viewportWidth, height: Self.heightBudget)
    )
    window.rootViewController = host
    window.isHidden = false
    windows.append(window)
    host.view.frame = window.bounds
    host.view.setNeedsLayout()
    host.view.layoutIfNeeded()
    return host
  }

  /// The command block's scroll view, found by the identifier the view publishes for exactly
  /// this purpose. SwiftUI only stamps `.accessibilityIdentifier` onto the backing
  /// `UIScrollView` once the accessibility tree is materialised, so the lookup walks the
  /// *accessibility* children rather than plain `subviews` — which also keeps it specific
  /// instead of "whatever scroll view happens to be in there".
  private func commandBlock(
    for command: String, file: StaticString = #filePath, line: UInt = #line
  ) throws -> UIScrollView {
    let host = hostedCard(ApprovalRequest(command: command, detail: "Run the build"))
    return try XCTUnwrap(
      Self.identifiedScrollView(in: host.view),
      "The card must host the command block's scroll view", file: file, line: line
    )
  }

  /// The height the card asks for at ``viewportWidth`` — what `ChatView`'s `VStack` has to
  /// find room for, buttons included.
  private func cardHeight(for command: String) -> CGFloat {
    fittedHeight(of: hostedCard(ApprovalRequest(command: command, detail: "Run the build")))
  }

  private func fittedHeight(of host: UIHostingController<AnyView>) -> CGFloat {
    host.sizeThatFits(
      in: CGSize(width: Self.viewportWidth, height: CGFloat.greatestFiniteMagnitude)
    ).height
  }

  private func hostedSize(of view: some View, width: CGFloat) -> CGSize {
    UIHostingController(rootView: view.dynamicTypeSize(.large))
      .sizeThatFits(in: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
  }

  private static func identifiedScrollView(in element: Any, depth: Int = 0) -> UIScrollView? {
    let object = element as AnyObject
    if let scroll = object as? UIScrollView,
      (object.accessibilityIdentifier as String?) == ApprovalCardView.commandBlockAccessibilityID
    {
      return scroll
    }
    guard depth < 12 else { return nil }
    for index in 0..<(object.accessibilityElementCount?() ?? 0) {
      if let child = object.accessibilityElement?(at: index),
        let found = identifiedScrollView(in: child, depth: depth + 1)
      {
        return found
      }
    }
    return nil
  }

  /// Every scroll view in the plain view hierarchy — used to assert the *absence* of a
  /// command block, which the identifier lookup alone could not prove.
  private static func scrollViews(in view: UIView) -> [UIScrollView] {
    var found: [UIScrollView] = []
    if let scroll = view as? UIScrollView { found.append(scroll) }
    for sub in view.subviews { found += scrollViews(in: sub) }
    return found
  }

  /// Alpha (0–255) per y of the fade mask, rendered 20×100 at scale 1 over an opaque fill.
  @MainActor
  private static func maskAlphas(isFaded: Bool) throws -> [Int] {
    let renderer = ImageRenderer(
      content: Color.black
        .frame(width: 20, height: 100)
        .mask { ApprovalCardView.bottomFadeMask(isFaded: isFaded) }
    )
    renderer.scale = 1
    let image = try XCTUnwrap(renderer.uiImage, "the mask must render")
    let cg = try XCTUnwrap(image.cgImage)
    var pixels = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
    let context = try XCTUnwrap(
      CGContext(
        data: &pixels, width: cg.width, height: cg.height, bitsPerComponent: 8,
        bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    )
    context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
    // Sample the middle column; row 0 of a bitmap context's buffer is the image's top edge.
    let x = cg.width / 2
    return (0..<cg.height).map { y in Int(pixels[(y * cg.width + x) * 4 + 3]) }
  }
}
