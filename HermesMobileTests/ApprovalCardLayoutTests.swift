import ComposableArchitecture
import HermesKit
import SwiftUI
import UIKit
import XCTest

@testable import HermesMobile

/// Measured (not eyeballed) acceptance checks for the approval card's scrollable content
/// region (#65).
///
/// A snapshot of content that *scrolls* and a snapshot of content that was *truncated* are the
/// same first screenful — what tells them apart is whether the rest still exists in the
/// hierarchy and can be reached. So these tests host the real views in a window, force a
/// layout pass, and read the numbers straight off the `UIScrollView` the region renders into.
///
/// Two harnesses, because the two halves of #65 fail in different places:
///
/// - **the card alone** (`hostedCard`) — the cap, the floor, the hug-below-the-cap behaviour,
///   the unmeasured `sizeThatFits` shape a snapshot render takes;
/// - **the real `ChatView`** (`hostedChat`) — the *composition*. The card is one child of a
///   `VStack` that also holds a greedy transcript and the composer, and a stack offers each
///   child `remaining / remainingCount` in flexibility order, so the card's own arithmetic
///   being right does not mean it is *given* room. That is exactly how the first take on this
///   fix shipped a region collapsed onto its floor in the very condition the issue reports.
///
/// Dynamic Type is pinned to `.large` except where a test varies it: the cap is
/// `@ScaledMetric`, so every numeric threshold below would otherwise follow the simulator's
/// text-size setting.
///
/// **Line-count floors are measured on the command's own painted band**
/// (``readableCommandHeight(_:file:line:)``), never on the viewport's height. The viewport also
/// holds the detail and the session toggle, so a floor stated on it is satisfied by chrome — and
/// was: a region painting *zero* lines of command passed a "three lines" assertion, on exactly the
/// device the issue was filed about.
final class ApprovalCardLayoutTests: XCTestCase {
  /// iPhone 13 Pro width — the same viewport the snapshot suite pins.
  private static let viewportWidth: CGFloat = 390

  /// Roomy host: tall enough that nothing in the card is compressed, so a measurement here
  /// reads the height the card *asks for*.
  private static let roomyHeight: CGFloat = 900

  /// #65's own condition for the card-alone harness: the non-scrolling region `ChatView` has
  /// between the transcript and the composer with the keyboard up on a small phone.
  private static let tightRegionHeight: CGFloat = 290

  /// One line of `.callout`, measured at `.large`. Line-count thresholds are expressed in
  /// terms of it so they read as "N lines" rather than as magic point values.
  private static let calloutLineHeight: CGFloat = 20.9

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

  // MARK: - The composition (what #65 actually reports)

  /// The card in the **real `ChatView`**, in the fixed region a phone has left with the
  /// keyboard up — the exact shape of the report.
  ///
  /// This is the assertion the previous take on the fix could not satisfy: the card's region
  /// is *less* flexible than the greedy transcript, so a plain `VStack` offers it roughly half
  /// of what is left and it lands on its floor. Measured at 88pt here without `ChatView`'s
  /// `.layoutPriority` and 149pt with it (227 before the region started handing a quarter of
  /// the offer back to the transcript) — from about one line of command to about six.
  ///
  /// The assertion is on the **command's own painted geometry**, not on the viewport's height:
  /// the viewport also holds the detail and the session toggle, so a line-count floor on the
  /// viewport alone is satisfied by chrome — it was, and that is how a region showing zero
  /// lines of command passed.
  @MainActor
  func testChatViewGivesTheCardTheFixedRegionWithTheKeyboardUp() throws {
    let chat = try hostedChat(width: 393, height: 516)

    XCTAssertGreaterThanOrEqual(
      try readableCommandLines(chat), 4,
      """
      With the keyboard up the card must get the fixed region, not half of it: anything less \
      and a long command is read a line or two at a time, which is the report.
      """
    )
    XCTAssertGreaterThan(
      chat.region.contentSize.height, chat.region.bounds.height * 4,
      "…and the rest of the command must still be there, behind the viewport"
    )
    assertNothingIsPushedOffScreen(chat)
  }

  /// The smallest supported phone (320×568 under Display Zoom) with the keyboard up: the
  /// region is genuinely too small for the whole card, so the floor is what is left. The
  /// floor exists to buy **command** lines, so that is what is measured — with the title and
  /// the detail above it inside the scroll, this same region painted about half a line of
  /// command and the old viewport-height assertion passed anyway.
  @MainActor
  func testChatViewOnTheShortestScreenKeepsSeveralLinesOfTheCommand() throws {
    let chat = try hostedChat(width: 320, height: 352)

    XCTAssertEqual(
      chat.region.bounds.height, ApprovalCardView.contentMinHeight, accuracy: 1,
      "Sanity: this is the configuration where the region lands exactly on its floor"
    )
    XCTAssertGreaterThanOrEqual(
      try readableCommandLines(chat), 3,
      """
      Even squeezed onto its floor the region must paint several lines of the COMMAND above \
      the fade ramp — not several lines of header and detail with the command below the fold.
      """
    )
    XCTAssertGreaterThan(chat.region.contentSize.height, chat.region.bounds.height, "…and scroll")
    assertNothingIsPushedOffScreen(chat)
  }

  /// The safety half, at accessibility text sizes. The card's session toggle and detail grow
  /// with Dynamic Type; while they were rigid their sum alone outgrew the fixed region and
  /// pushed Deny/Approve (and the composer) off the bottom. Only the (clamped, one-line) title
  /// and the button row are rigid now, so the region absorbs the whole difference — and the
  /// command, being first in the scroll, is still the thing on screen.
  @MainActor
  func testChatViewKeepsTheAnswerOnScreenAtAccessibilitySizes() throws {
    for size in [DynamicTypeSize.accessibility3, .accessibility5] {
      // The shortest screen and a mainstream one, both with the keyboard up.
      for (width, height) in [(CGFloat(320), CGFloat(352)), (393, 516)] {
        let chat = try hostedChat(width: width, height: height, dynamicType: size)
        assertNothingIsPushedOffScreen(chat)
        XCTAssertGreaterThan(
          chat.region.bounds.height, 0, "\(chat.label): the region must still be laid out"
        )
      }
    }
  }

  /// …and at those sizes the command is still what the viewport opens on. A line at AX5 is
  /// ~3.3× a `.large` one, so "several lines" is not physically available on a phone — what is
  /// asserted is that the region's first screenful is *command*, not chrome.
  ///
  /// Only the mainstream window: on the 320×352 one the card over-subscribes its container at
  /// AX3+, and in that state this harness renders the region's content blank (it reports a
  /// viewport taller than the card is actually painted). Measured identically **before** this
  /// branch, so it is a limitation of the offscreen harness rather than a property of the card;
  /// the composition assertions above still cover that window.
  @MainActor
  func testTheCommandIsWhatTheViewportOpensOnAtAccessibilitySizes() throws {
    for size in [DynamicTypeSize.accessibility3, .accessibility5] {
      let chat = try hostedChat(width: 393, height: 516, dynamicType: size)
      XCTAssertGreaterThan(
        try readableCommandHeight(chat), 0,
        "\(chat.label): the command must be the first thing the region paints, at any text size"
      )
    }
  }

  /// `detail` is the server's `description` and has no length limit, so it is the other way
  /// the card can outgrow its region — and, before the command was moved to the top of the
  /// scroll, the way it pushed the command **entirely** below the fold: measured at 393×516
  /// with a 1000-character detail, the viewport painted no command pixels at all while the
  /// old line-count assertion passed on detail lines.
  @MainActor
  func testAnUnboundedDetailCannotDisplaceTheCommand() throws {
    let long = try hostedChat(width: 393, height: 516, detail: Self.longDetail)
    assertNothingIsPushedOffScreen(long)
    XCTAssertGreaterThanOrEqual(
      try readableCommandLines(long), 4,
      "A long detail must be absorbed by the scroll BELOW the command, not in front of it"
    )

    // Isolated to the detail: the same window, the same command, 26 vs 1000 characters of
    // server-controlled copy — the command's painted geometry must not notice.
    let short = try hostedChat(width: 393, height: 516, detail: "Delete the build directory")
    XCTAssertEqual(
      try readableCommandHeight(long), try readableCommandHeight(short), accuracy: 1,
      "The detail's length must not change how much of the command is on screen at first paint"
    )
  }

  /// The transcript is the *context* for an approve/deny decision, and `.layoutPriority(1)`
  /// hands the card everything the other children do not strictly need — the greedy
  /// transcript's minimum is zero, so it was measured at **0pt** on every phone. The region
  /// gives a quarter of its offer back (`BoundedHeightLayout.claim`).
  @MainActor
  func testTheTranscriptKeepsAUsableHeightBehindTheCard() throws {
    let chat = try hostedChat(width: 393, height: 516)
    XCTAssertGreaterThanOrEqual(
      chat.transcript.bounds.height, 40,
      """
      A standing approval must not starve the transcript to nothing — the conversation the \
      command belongs to is what the decision is made against.
      """
    )
    // …but not at the command's expense: the card still gets the lion's share.
    XCTAssertGreaterThan(
      chat.region.bounds.height, chat.transcript.bounds.height,
      "The blocking card still outranks the transcript for the fixed region"
    )
  }

  /// The clarify/secret card was never made compressible, so it gets **no** layout priority:
  /// priority would only take the transcript's room without buying the card anything it can
  /// use (measured with a long question at 393×516: transcript 160pt → 13pt).
  @MainActor
  func testTheClarifyCardDoesNotTakeTheTranscriptsRoom() throws {
    let chat = try hostedChat(
      width: 393, height: 516,
      interaction: .clarify(
        ClarifyRequest(
          requestID: "r",
          question: String(
            repeating: "Which target should I rebuild before running the suite? ", count: 20)
        )
      )
    )
    XCTAssertGreaterThanOrEqual(
      chat.transcript.bounds.height, 100,
      """
      The approval card's layout priority must be scoped to approvals: a rigid clarify card \
      cannot use the extra room, so granting it would only blank the transcript.
      """
    )
    let composer = chat.composer.convert(chat.composer.bounds, to: nil)
    XCTAssertLessThanOrEqual(
      composer.maxY, chat.windowHeight, "…and the clarify card must not push the composer out")
  }

  // MARK: - Overflow (the #65 fix), card alone

  func testLongCommandScrollsInsteadOfBeingTruncated() throws {
    let scroll = try contentRegion(for: Self.longCommand)

    XCTAssertEqual(
      scroll.bounds.height, ApprovalCardView.contentMaxHeightBase, accuracy: 1,
      "Past the cap the region must stop growing at exactly the cap"
    )
    XCTAssertGreaterThan(
      scroll.contentSize.height, scroll.bounds.height,
      "Content taller than the cap must be scrollable, not clipped away"
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
    // Reached the end, so the fade must be off — a permanently-faded bottom edge would leave
    // the command's last line unreadable, which is the very thing #65 is about.
    XCTAssertFalse(
      ApprovalCardView.hasBottomOverflow(
        visibleRect: CGRect(origin: scroll.contentOffset, size: scroll.bounds.size),
        contentHeight: scroll.contentSize.height
      ),
      "At the scroll end nothing is hidden below, so the bottom must not be faded"
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
    XCTAssertGreaterThan(twenty, ApprovalCardView.contentMaxHeightBase, "Sanity: at the cap")
  }

  /// The card alone in a tight region, with a greedy sibling above it.
  ///
  /// `sizeThatFits` at the tight height is the load-bearing assertion — it is exactly the
  /// answer `ChatView`'s `VStack` gets, so a card that fits it cannot push its own buttons,
  /// or the composer, off the bottom. The line-count floor is the other half: absorbing the
  /// squeeze must not degenerate into a one-line peephole, which an upper bound alone would
  /// happily accept.
  @MainActor
  func testCardFitsATightRegionByCompressingTheContentNotByLosingIt() throws {
    let host = hostedCard(
      ApprovalRequest(command: Self.longCommand, detail: "Run the build"),
      windowHeight: Self.tightRegionHeight,
      // A stand-in for the greedy transcript above the card: the card gets what's left.
      squeezedByGreedySibling: true
    )
    let fitted = host.sizeThatFits(
      in: CGSize(width: Self.viewportWidth, height: Self.tightRegionHeight)
    ).height
    XCTAssertLessThanOrEqual(
      fitted, Self.tightRegionHeight,
      "The card must fit the fixed region it is given — anything more pushes Deny/Approve out"
    )

    let scroll = try XCTUnwrap(Self.onlyScrollView(in: host.view), "the region must be hosted")
    XCTAssertLessThan(
      scroll.bounds.height, ApprovalCardView.contentMaxHeightBase,
      "The region must be the thing that yields when the space runs short"
    )
    XCTAssertGreaterThanOrEqual(
      try readableCommandHeight(window: XCTUnwrap(windows.last), region: scroll),
      3 * Self.calloutLineHeight,
      """
      …but the squeeze must stop well above a peephole: several lines OF THE COMMAND have to \
      stay legible outside the bottom ramp, or the user is reading a dangerous command a line \
      at a time.
      """
    )
    XCTAssertGreaterThan(
      scroll.contentSize.height, scroll.bounds.height * 4,
      "Compressing the viewport must not drop a single line of the command"
    )
    XCTAssertLessThanOrEqual(
      scroll.convert(scroll.bounds, to: nil).maxY, Self.tightRegionHeight,
      "The region must be laid out inside the window, not spilling past it"
    )
  }

  /// The card's **compressed fitting size** — what it asks for when its container has nothing
  /// to spare — pinned so the rigid half cannot drift upward one row at a time.
  ///
  /// It is the number that decides whether a short container can hold the card *and* the
  /// composer. A portrait phone with the keyboard up can (measured on the shortest, 320×352:
  /// the whole card plus the composer fit). A **landscape** phone with the keyboard up leaves
  /// roughly 100pt of fixed region and cannot — on this branch or before it. What happens
  /// there is at least the right order of precedence: the region lands on its floor, the
  /// Deny/Approve row stays inside the window, and the composer — which is *disabled* while a
  /// card is up — is what goes under the keyboard.
  func testTheCardsCompressedFittingSizeIsPinned() throws {
    let host = hostedCard(
      ApprovalRequest(command: Self.longCommand, detail: Self.longDetail),
      windowHeight: 200,
      squeezedByGreedySibling: true
    )
    let compressed = host.sizeThatFits(in: CGSize(width: Self.viewportWidth, height: 1)).height
    XCTAssertLessThanOrEqual(
      compressed, 260,
      """
      Compressed, the card must stay inside the fixed region a portrait phone has with the \
      keyboard up — every rigid point added here comes out of that budget.
      """
    )
    XCTAssertGreaterThan(
      compressed, ApprovalCardView.contentMinHeight,
      "Sanity: the floor is part of it — the card never compresses past its region's floor"
    )
  }

  // MARK: - The session toggle's state at the moment Approve is tapped

  /// "Approve all in this session" whitelists the danger pattern for the whole session, and it
  /// lives inside the scroll (it has to — a rigid toggle at accessibility sizes is what pushed
  /// the buttons off screen), so with a long command it is below the fold. The state therefore
  /// has to be legible on the rigid row where the decision is committed.
  func testTheApproveButtonReflectsTheSessionToggle() {
    XCTAssertEqual(ApprovalCardView.approveTitle(all: false), "Approve")
    XCTAssertEqual(
      ApprovalCardView.approveTitle(all: true), "Approve all",
      """
      With the session toggle on, the primary button must say so: the toggle can be flipped, \
      scrolled away from, and committed blind otherwise.
      """
    )
  }

  /// The card must account for the whole region **before** any layout pass — i.e. its height
  /// must come from what the content asks for, not from a measurement that has not happened
  /// yet.
  ///
  /// A `ScrollView` handed a concrete height proposal swallows it whole, so an earlier take on
  /// this view sized the region to its padding alone on any pass that ran before its
  /// `onGeometryChange` fired, and the card under-reported by a whole command: measured as a
  /// 1170×553 render against a 1170×611 baseline, i.e. clipped at both ends. A `sizeThatFits`
  /// snapshot render is exactly one such pass; the windowed tests above cannot see it, because
  /// their harness forces a layout pass first.
  func testUnmeasuredCardAccountsForTheWholeContentRegion() {
    let long = unmeasuredCardHeight(for: Self.longCommand)
    let oneLine = unmeasuredCardHeight(for: "rm -rf build/")

    // Measured against the *same card minus a long command*, so it cannot be satisfied by a
    // hosting-environment constant: the region must have grown by essentially the whole
    // remaining cap with no layout pass behind it.
    XCTAssertGreaterThan(
      long - oneLine, ApprovalCardView.contentMaxHeightBase * 0.5,
      "With no layout pass the region must still ask for its capped height, not its padding"
    )
    XCTAssertEqual(
      long, unmeasuredCardHeight(for: Self.veryLongCommand), accuracy: 1,
      "…and the cap must decide that height unmeasured too"
    )
  }

  /// The scaled cap must be clamped, or at accessibility sizes the region alone claims
  /// ~1050pt — taller than any iPhone screen.
  func testTheScaledCapIsClampedAtAccessibilitySizes() throws {
    let scroll = try contentRegion(
      for: Self.longCommand, dynamicType: .accessibility5, windowHeight: 1400
    )
    XCTAssertEqual(
      scroll.bounds.height, ApprovalCardView.contentMaxHeightCeiling, accuracy: 1,
      "At AX5 the scaled cap overshoots and must land on the ceiling"
    )
    XCTAssertGreaterThan(
      scroll.contentSize.height, scroll.bounds.height,
      "Clamping bounds what the region asks for, never what it holds — it still scrolls"
    )
    XCTAssertLessThan(
      ApprovalCardView.contentMaxHeightCeiling, TranscriptLayout.shortestLayoutHeight,
      "The ceiling must leave room for the button row on the shortest screen"
    )
  }

  // MARK: - Below the cap (the common case, unchanged)

  func testShortCommandHugsItsContentWithoutScrolling() throws {
    let scroll = try contentRegion(for: "rm -rf build/ && git clean -fdx")

    XCTAssertGreaterThan(scroll.contentSize.height, 0, "The content must actually be laid out")
    XCTAssertLessThan(
      scroll.bounds.height, ApprovalCardView.contentMaxHeightBase,
      "A one-line command must hug its content, not pad out to the cap"
    )
    XCTAssertEqual(
      scroll.bounds.height, scroll.contentSize.height, accuracy: 1,
      "Below the cap the region's height must equal its content's — no dead space, no scroll"
    )
    XCTAssertFalse(
      ApprovalCardView.hasBottomOverflow(
        visibleRect: CGRect(origin: .zero, size: scroll.bounds.size),
        contentHeight: scroll.contentSize.height
      ),
      "Content that fits must not be reported as overflowing, i.e. must not be faded"
    )
  }

  /// The cap is a boundary, so it is asserted from both sides: content just under it hugs
  /// itself and does not scroll, content just over it lands exactly on the cap and does.
  /// Both sides assert non-zero geometry — an upper bound alone is satisfied by a collapsed
  /// 0×0 region, which is a real failure mode here (the `ScrollView`'s own ideal height *is*
  /// zero).
  func testTheCapBoundaryFromBothSides() throws {
    let under = try contentRegion(for: Self.commandJustUnderTheCap)
    XCTAssertGreaterThan(
      under.bounds.height, ApprovalCardView.contentMaxHeightBase * 0.6, "Sanity: near the cap")
    XCTAssertLessThanOrEqual(under.bounds.height, ApprovalCardView.contentMaxHeightBase + 1)
    XCTAssertEqual(
      under.contentSize.height, under.bounds.height, accuracy: 1,
      "Content that still fits the cap has nothing to scroll to"
    )

    let over = try contentRegion(for: Self.commandJustOverTheCap)
    XCTAssertEqual(
      over.bounds.height, ApprovalCardView.contentMaxHeightBase, accuracy: 1,
      "One line past the cap the region must sit exactly on the cap, not a line above it"
    )
    XCTAssertGreaterThan(
      over.contentSize.height, over.bounds.height + 1,
      "…with the overrunning lines present and scrollable"
    )
  }

  // MARK: - The command-less card (#30 recovery path)

  /// The recovered approval (`command == nil`) and a request whose command decoded empty
  /// render no command at all: the region hugs the recovery copy, has nothing to scroll, and
  /// the card is shorter than the same request carrying a command.
  func testRecoveredCardRendersNoCommand() throws {
    for (name, request) in [
      ("recovered", ChatFeature.recoveredApprovalRequest),
      ("empty command", ApprovalRequest(command: "", detail: "Delete the build directory")),
    ] {
      let host = hostedCard(request)
      let scroll = try XCTUnwrap(Self.onlyScrollView(in: host.view), "\(name): region hosted")
      XCTAssertEqual(
        scroll.bounds.height, scroll.contentSize.height, accuracy: 1,
        "\(name): with no command the region hugs the recovery copy — nothing to scroll"
      )
      XCTAssertGreaterThan(fittedHeight(of: host), 0, "\(name): the card must still lay out")
    }

    // Isolated to the command: same request shape (detail + toggle), command present or not.
    let bare = ApprovalRequest(command: nil, detail: "Delete the build directory", patternKey: "rm")
    let carrying = ApprovalRequest(
      command: "rm -rf build/", detail: "Delete the build directory", patternKey: "rm")
    XCTAssertEqual(
      bare.offersSessionApproval, carrying.offersSessionApproval,
      "Sanity: only the command differs")
    XCTAssertLessThan(
      fittedHeight(of: hostedCard(bare)), fittedHeight(of: hostedCard(carrying)),
      "Dropping the command must be the only height difference, and it must shorten the card"
    )
  }

  // MARK: - The overflow rule and the ramp

  /// The fade's trigger, as a pure rule — the view's own flag is private `@State`. Driven by
  /// live scroll geometry, so it must go **false at the end** of the scroll: a fade keyed on
  /// the content height alone would ramp the command's last line to transparent forever.
  func testBottomOverflowRule() {
    let viewport = CGSize(width: 300, height: 220)
    func rect(_ offsetY: CGFloat) -> CGRect {
      CGRect(origin: CGPoint(x: 0, y: offsetY), size: viewport)
    }

    // Nothing to scroll: content exactly fills the viewport.
    XCTAssertFalse(ApprovalCardView.hasBottomOverflow(visibleRect: rect(0), contentHeight: 220))
    XCTAssertFalse(ApprovalCardView.hasBottomOverflow(visibleRect: rect(0), contentHeight: 100))
    // Fractional layout slack must not switch the fade on.
    XCTAssertFalse(ApprovalCardView.hasBottomOverflow(visibleRect: rect(0), contentHeight: 220.4))
    // Long content, parked at the top and mid-scroll: more below, so fade.
    XCTAssertTrue(ApprovalCardView.hasBottomOverflow(visibleRect: rect(0), contentHeight: 1258))
    XCTAssertTrue(ApprovalCardView.hasBottomOverflow(visibleRect: rect(500), contentHeight: 1258))
    // …and scrolled to the very end: nothing below, so the last line reads clean.
    XCTAssertFalse(
      ApprovalCardView.hasBottomOverflow(visibleRect: rect(1258 - 220), contentHeight: 1258))
  }

  /// The ramp is a hint, so it may never be most of what is left to read. A constant 24pt is
  /// fine against a full-height viewport and ruinous against a squeezed one — this region
  /// compresses, `MarkdownTableView`'s trailing edge does not, which is why the two differ.
  func testTheFadeRampNeverEatsMoreThanAQuarterOfTheViewport() {
    // Roomy: the constant is the binding limit.
    XCTAssertEqual(
      ApprovalCardView.fadeRampHeight(viewportHeight: 320), ApprovalCardView.bottomFadeHeight)
    XCTAssertEqual(
      ApprovalCardView.fadeRampHeight(viewportHeight: 96), ApprovalCardView.bottomFadeHeight)
    // Squeezed: the fraction takes over, so three quarters always stay fully opaque.
    XCTAssertEqual(ApprovalCardView.fadeRampHeight(viewportHeight: 60), 15)
    XCTAssertEqual(ApprovalCardView.fadeRampHeight(viewportHeight: 40), 10)
    // Degenerate geometry must not produce a negative ramp.
    XCTAssertEqual(ApprovalCardView.fadeRampHeight(viewportHeight: 0), 0)
    XCTAssertEqual(ApprovalCardView.fadeRampHeight(viewportHeight: -10), 0)
    // The invariant the two constants have to keep, stated once so they cannot drift back
    // into "the hint covers half the content".
    for viewport in stride(from: CGFloat(20), through: 400, by: 10) {
      XCTAssertLessThanOrEqual(
        ApprovalCardView.fadeRampHeight(viewportHeight: viewport), viewport / 4,
        "At \(viewport)pt the ramp must leave three quarters legible"
      )
    }
  }

  /// The fade must sit at the **bottom** edge — the direction the hidden lines are in — and be
  /// a no-op when nothing overflows. Asserted on alpha sampled from the rendered mask, because
  /// a ramp at the wrong edge still snapshots as "a card with a soft edge".
  @MainActor
  func testBottomFadeMaskRampsAtTheBottomEdgeOnly() throws {
    let faded = try Self.maskAlphas(.init(isFaded: true, rampHeight: 24))
    XCTAssertEqual(faded.count, 100, "the sampled column must be the full rendered height")
    XCTAssertGreaterThan(faded[2], 240, "The top of the region is never faded")
    XCTAssertGreaterThan(faded[50], 240, "The middle of the region is never faded")
    XCTAssertGreaterThan(faded[70], 240, "…and everything above the ramp stays opaque")
    XCTAssertLessThan(faded[98], 40, "The bottom edge must fade out to hint at the hidden lines")

    let plain = try Self.maskAlphas(.init(isFaded: false, rampHeight: 24))
    XCTAssertEqual(plain.count, 100)
    for y in [2, 50, 88, 98] {
      XCTAssertGreaterThan(plain[y], 240, "An unfaded mask must be opaque at y=\(y)")
    }
  }

  // MARK: - The bounding layout, without a view

  /// ``BoundedHeightLayout``'s arithmetic, asserted directly: `min(natural, cap)` when there
  /// is room, the offered height when the container is short, and never below the floor —
  /// nor above the content when the content is smaller than the floor.
  func testBoundedHeightLayoutArithmetic() {
    let layout = BoundedHeightLayout(cap: 320, minHeight: 88)
    // Roomy: bounded by the cap, never by the proposal.
    XCTAssertEqual(layout.height(natural: 1258, offered: 900), 320)
    XCTAssertEqual(layout.height(natural: 100, offered: 900), 100, "…and hugs content under the cap")
    XCTAssertEqual(
      layout.height(natural: 1258, offered: nil), 320, "an unspecified proposal is roomy")
    // Squeezed: yields to the container, down to the floor.
    XCTAssertEqual(layout.height(natural: 1258, offered: 120), 120)
    XCTAssertEqual(layout.height(natural: 1258, offered: 10), 88, "never below the floor")
    XCTAssertEqual(layout.height(natural: 20, offered: 0), 20, "…and never taller than the content")
  }

  /// The share the region hands back so the transcript is not starved to 0pt by the card's
  /// layout priority — and the two things that outrank it: the cap above, the floor below.
  func testBoundedHeightLayoutYieldsAShareOfTheOfferedHeight() {
    let layout = BoundedHeightLayout(cap: 320, minHeight: 88, claim: 0.75)
    XCTAssertEqual(
      layout.height(natural: 1258, offered: 200), 150, "a quarter of the offer goes back")
    XCTAssertEqual(
      layout.height(natural: 1258, offered: 900), 320, "…but the cap still decides when roomy")
    XCTAssertEqual(
      layout.height(natural: 1258, offered: 100), 88,
      "…and the floor outranks the share: yielding must never squeeze the card past its floor")
    XCTAssertEqual(
      layout.height(natural: 60, offered: 200), 60, "…nor pad short content out to the share")
    XCTAssertEqual(
      BoundedHeightLayout(cap: 320, minHeight: 88).height(natural: 1258, offered: 200), 200,
      "Sanity: `claim` defaults to taking the whole offer, so it is opt-in")
  }

  // MARK: - Fixtures

  /// ~20 lines — comfortably past the cap at the default content size.
  static let longCommand = (1...20)
    .map { "step \($0): xcodebuild -workspace HermesMobile.xcworkspace -scheme Target\($0) test" }
    .joined(separator: "\n")

  /// The server's `description` has no length limit — this is the shape that used to push the
  /// command out of the viewport entirely.
  private static let longDetail = String(
    repeating: "This deletes everything under the build directory. ", count: 20)

  /// Ten times longer again: the card must not notice.
  private static let veryLongCommand = (1...200)
    .map { "step \($0): xcodebuild -workspace HermesMobile.xcworkspace -scheme Target\($0) test" }
    .joined(separator: "\n")

  /// Short, single-token lines at `.callout` (~20.9pt each, measured). With the header,
  /// detail and toggle around them these land just under the cap…
  private static let commandJustUnderTheCap = (1...10).map { "line \($0)" }.joined(separator: "\n")

  /// …and these just over it. (Both are asserted against the cap rather than against these
  /// estimates, so a font-metric change fails loudly instead of silently turning the boundary
  /// test into a second short-command test.)
  private static let commandJustOverTheCap = (1...14).map { "line \($0)" }.joined(separator: "\n")

  // MARK: - Helpers (card alone)

  /// Hosts the card in a real window and forces a layout pass. The window is roomy by
  /// default, so a measurement reads the height the card *asks for*;
  /// `squeezedByGreedySibling` reproduces `ChatView`'s shape instead.
  private func hostedCard(
    _ request: ApprovalRequest,
    dynamicType: DynamicTypeSize = .large,
    windowHeight: CGFloat = ApprovalCardLayoutTests.roomyHeight,
    squeezedByGreedySibling: Bool = false
  ) -> UIHostingController<AnyView> {
    let card = ApprovalCardView(request: request, onApprove: { _ in }, onDeny: {})
    let root: AnyView =
      squeezedByGreedySibling
      ? AnyView(
        VStack(spacing: 0) {
          Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
          card
        }
        .dynamicTypeSize(dynamicType)
      )
      : AnyView(card.dynamicTypeSize(dynamicType))

    return host(root, width: Self.viewportWidth, height: windowHeight)
  }

  /// The content region's scroll view. The card hosts exactly one, so a plain `subviews` walk
  /// is sufficient — no test-only hook on the production view (the `MarkdownTableLayoutTests`
  /// convention).
  private func contentRegion(
    for command: String,
    dynamicType: DynamicTypeSize = .large,
    windowHeight: CGFloat = ApprovalCardLayoutTests.roomyHeight,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws -> UIScrollView {
    let host = hostedCard(
      ApprovalRequest(command: command, detail: "Run the build"),
      dynamicType: dynamicType,
      windowHeight: windowHeight
    )
    return try XCTUnwrap(
      Self.onlyScrollView(in: host.view),
      "The card must host exactly one scroll view — the content region", file: file, line: line
    )
  }

  /// The height the card asks for at ``viewportWidth`` — what `ChatView`'s `VStack` has to
  /// find room for, buttons included.
  private func cardHeight(for command: String) -> CGFloat {
    fittedHeight(of: hostedCard(ApprovalRequest(command: command, detail: "Run the build")))
  }

  /// The height the card asks for with **no window and no layout pass** — the shape that
  /// exposed the collapsed-ideal regression (a `sizeThatFits` snapshot render is exactly this).
  private func unmeasuredCardHeight(for command: String) -> CGFloat {
    UIHostingController(
      rootView: ApprovalCardView(
        request: ApprovalRequest(command: command, detail: "Run the build"),
        onApprove: { _ in }, onDeny: {}
      )
      .dynamicTypeSize(.large)
    )
    .sizeThatFits(in: CGSize(width: Self.viewportWidth, height: CGFloat.greatestFiniteMagnitude))
    .height
  }

  private func fittedHeight(of host: UIHostingController<AnyView>) -> CGFloat {
    host.sizeThatFits(
      in: CGSize(width: Self.viewportWidth, height: CGFloat.greatestFiniteMagnitude)
    ).height
  }

  // MARK: - Helpers (the real ChatView)

  /// What a hosted `ChatView` gives back: the card's content region, the transcript and the
  /// composer, all live views, plus the window they were laid out in.
  private struct HostedChat {
    /// The card's bounded content region — `nil` when the standing card is a clarify/secret
    /// one, which is plain stacked content and hosts no scroll view of its own.
    var regionIfAny: UIScrollView?
    var transcript: UIScrollView
    var composer: UIScrollView
    var window: UIWindow
    var windowHeight: CGFloat
    var label: String

    /// The approval card's region. Force-unwrapped on purpose: every caller has an approval
    /// standing, and `hostedChat` already fails the test with a message when it is missing.
    var region: UIScrollView { regionIfAny! }
  }

  /// Hosts the **real** `ChatView` with an approval standing, in a window the size of the
  /// screen area left when the keyboard is up (that is exactly what the keyboard does to the
  /// view's frame), and forces a layout pass.
  @MainActor
  private func hostedChat(
    width: CGFloat,
    height: CGFloat,
    dynamicType: DynamicTypeSize = .large,
    detail: String = "Delete the build directory and all untracked files",
    interaction: ChatFeature.State.PendingInteraction? = nil,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws -> HostedChat {
    var state = ChatFeature.State(
      connection: ServerConnection(
        baseURL: URL(string: "http://127.0.0.1:8787")!, auth: .token("t")
      ),
      resumeStoredID: "layout-session",
      title: "Layout",
      transcript: IdentifiedArray(
        uniqueElements: (1...30).map { i in
          ChatRow(id: UUID(), kind: .message(role: .assistant, text: "row \(i)", isComplete: true))
        }
      ),
      status: .ready
    )
    // Through `present(_:)`, like the reducer: a bare assignment leaves the token behind, and
    // the token is the card's view identity.
    state.present(interaction ?? .approval(ApprovalRequest(command: Self.longCommand, detail: detail)))
    let root = AnyView(
      NavigationStack {
        ChatView(
          store: Store(initialState: state) { ChatFeature() } withDependencies: {
            // Don't open a real socket during layout.
            $0.hermesGateway.connect = { _, _ in AsyncStream { _ in } }
            $0.continuousClock = ImmediateClock()
          }
        )
      }
      .dynamicTypeSize(dynamicType)
    )
    let hosted = host(root, width: width, height: height)
    // The transcript is a `UIViewRepresentable`; let its first collection-view layout settle
    // before reading how the stack distributed the fixed region.
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    hosted.view.setNeedsLayout()
    hosted.view.layoutIfNeeded()

    let scrolls = Self.scrollViews(in: hosted.view)
    // The chat screen hosts several scroll views: the transcript's collection view, a
    // `SelectableText` per rendered assistant row, the composer's input, and the card's
    // region. The card's is the only plain one; the composer is matched by its own type
    // rather than by "the first `UITextView`", which a transcript row would win.
    let region = scrolls.first { !($0 is UICollectionView) && !($0 is UITextView) }
    if case .approval = state.pendingInteraction {
      XCTAssertNotNil(
        region, "the approval card's content region must be hosted", file: file, line: line)
    }
    let transcript = try XCTUnwrap(
      scrolls.compactMap { $0 as? UICollectionView }.first,
      "the transcript must be hosted", file: file, line: line
    )
    let composer = try XCTUnwrap(
      scrolls.compactMap { $0 as? ComposerInputTextView }.first,
      "the composer's input view must be hosted", file: file, line: line
    )
    return HostedChat(
      regionIfAny: region, transcript: transcript, composer: composer,
      window: try XCTUnwrap(windows.last, file: file, line: line), windowHeight: height,
      label: "\(Int(width))×\(Int(height)) @\(dynamicType)"
    )
  }

  /// The card's answer must stay reachable. The Deny/Approve row is laid out *between* the
  /// content region and the composer, so a composer that is still fully inside the window is
  /// proof that neither it nor the buttons were pushed out — and it needs no assumption about
  /// how tall a button row is at a given Dynamic Type size.
  private func assertNothingIsPushedOffScreen(
    _ chat: HostedChat, file: StaticString = #filePath, line: UInt = #line
  ) {
    let composer = chat.composer.convert(chat.composer.bounds, to: nil)
    let region = chat.region.convert(chat.region.bounds, to: nil)
    XCTAssertLessThanOrEqual(
      composer.maxY, chat.windowHeight,
      "\(chat.label): the card must not push the composer (and the buttons above it) off screen",
      file: file, line: line
    )
    XCTAssertLessThan(
      region.maxY, composer.minY,
      "\(chat.label): the button row must still fit between the region and the composer",
      file: file, line: line
    )
  }

  // MARK: - Measuring the COMMAND (not the viewport it happens to sit in)

  /// How many `.callout` lines **of the command itself** are painted inside the region's
  /// readable (un-ramped) area at first paint.
  ///
  /// The suite's earlier floors were expressed on the viewport's height, which since the
  /// header/detail/toggle moved into the same scroll was satisfied entirely by chrome: at the
  /// floor on the shortest screen the viewport showed three lines *and none of them were the
  /// command*. There is no `UIView` to interrogate — SwiftUI draws `Text` into a shared layer
  /// — so this measures the pixels: the command sits in a `secondarySystemBackground` block on
  /// a `tertiarySystemBackground` card, which is a run of rows the renderer can find. The
  /// block's own padding is discounted, so the number really is lines of text.
  @MainActor
  private func readableCommandLines(
    _ chat: HostedChat, file: StaticString = #filePath, line: UInt = #line
  ) throws -> CGFloat {
    try readableCommandHeight(chat, file: file, line: line) / Self.calloutLineHeight
  }

  @MainActor
  private func readableCommandHeight(
    _ chat: HostedChat, file: StaticString = #filePath, line: UInt = #line
  ) throws -> CGFloat {
    try readableCommandHeight(
      window: chat.window, region: chat.region, file: file, line: line)
  }

  @MainActor
  private func readableCommandHeight(
    window: UIWindow, region: UIScrollView, file: StaticString = #filePath, line: UInt = #line
  ) throws -> CGFloat {
    // Rendered from the REGION's own layer, in the region's own coordinate space. Converting
    // the region's frame into window coordinates and sampling the window is *wrong* in exactly
    // the configurations that matter: when the card over-subscribes its container (a landscape
    // window, or the shortest screen at AX3+) SwiftUI places the stack partly outside, and the
    // converted origin no longer matches where the card is painted (measured: the region
    // reported y=0 while the card's border was drawn 36pt lower).
    let rendered = try Self.render(region, file: file, line: line)
    let readableMaxY =
      region.bounds.height - ApprovalCardView.fadeRampHeight(viewportHeight: region.bounds.height)
    let block = Self.rgb(.secondarySystemBackground, window.traitCollection)
    let card = Self.rgb(.tertiarySystemBackground, window.traitCollection)

    // Measured as the **contiguous** band starting at the top of the viewport, not as
    // first-match-to-last-match: the command is the first thing in the scroll, so "the viewport
    // opens on the command" is the invariant, and a span between two far-apart matches would
    // report a command that is actually below the fold as visible.
    let step = 1 / rendered.scale
    var bottom: CGFloat = 0
    var gap: CGFloat = 0
    var y: CGFloat = 0
    while y < min(readableMaxY, rendered.height) {
      // Sample across the width: the command's own glyphs are neither colour, and a single
      // column would land on one at any indentation.
      let isBlock = stride(from: 0.04, through: 0.98, by: 0.02).contains { fraction in
        let pixel = rendered.color(x: region.bounds.width * fraction, y: y)
        return Self.distance(pixel, block) < 8 && Self.distance(pixel, block)
          < Self.distance(pixel, card)
      }
      if isBlock {
        bottom = y + step
        gap = 0
      } else {
        gap += step
        // A couple of points of fully-covered row (a glyph row, an anti-aliased edge) is not
        // the end of the block; anything more is.
        if gap > 3 { break }
      }
      y += step
    }
    // Discount the block's own top padding: what is asserted is legible command *text*.
    return max(0, bottom - ApprovalCardView.commandPadding)
  }

  /// A rendered view as a flat RGBA buffer. `layer.render(in:)` rather than
  /// `drawHierarchy(in:afterScreenUpdates:)`, which returns black for an off-screen window in
  /// this host.
  private struct RenderedWindow {
    var pixels: [UInt8]
    var pixelWidth: Int
    var pixelHeight: Int
    var scale: CGFloat
    var height: CGFloat { CGFloat(pixelHeight) / scale }

    func color(x: CGFloat, y: CGFloat) -> (Int, Int, Int) {
      let px = min(max(Int(x * scale), 0), pixelWidth - 1)
      let py = min(max(Int(y * scale), 0), pixelHeight - 1)
      let i = (py * pixelWidth + px) * 4
      return (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))
    }
  }

  @MainActor
  private static func render(
    _ view: UIView, file: StaticString = #filePath, line: UInt = #line
  ) throws -> RenderedWindow {
    let image = UIGraphicsImageRenderer(bounds: CGRect(origin: .zero, size: view.bounds.size))
      .image { context in
        // The layer's own bounds origin (a scroll view's `contentOffset`) is the context's
        // origin, so the render starts at what the viewport currently shows.
        context.cgContext.translateBy(x: -view.bounds.minX, y: -view.bounds.minY)
        view.layer.render(in: context.cgContext)
      }
    let cg = try XCTUnwrap(image.cgImage, "the view must render", file: file, line: line)
    var pixels = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
    let context = try XCTUnwrap(
      CGContext(
        data: &pixels, width: cg.width, height: cg.height, bitsPerComponent: 8,
        bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ), file: file, line: line)
    context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
    return RenderedWindow(
      pixels: pixels, pixelWidth: cg.width, pixelHeight: cg.height,
      scale: CGFloat(cg.height) / view.bounds.height
    )
  }

  private static func rgb(_ color: UIColor, _ traits: UITraitCollection) -> (Int, Int, Int) {
    var r: CGFloat = 0
    var g: CGFloat = 0
    var b: CGFloat = 0
    var a: CGFloat = 0
    color.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
    return (Int(r * 255), Int(g * 255), Int(b * 255))
  }

  private static func distance(_ lhs: (Int, Int, Int), _ rhs: (Int, Int, Int)) -> Int {
    abs(lhs.0 - rhs.0) + abs(lhs.1 - rhs.1) + abs(lhs.2 - rhs.2)
  }

  // MARK: - Hosting

  private func host<V: View>(_ view: V, width: CGFloat, height: CGFloat) -> UIHostingController<V> {
    let controller = UIHostingController(rootView: view)
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: height))
    window.rootViewController = controller
    window.isHidden = false
    windows.append(window)
    controller.view.frame = window.bounds
    controller.view.setNeedsLayout()
    controller.view.layoutIfNeeded()
    return controller
  }

  private static func onlyScrollView(in view: UIView) -> UIScrollView? {
    let found = scrollViews(in: view)
    return found.count == 1 ? found[0] : nil
  }

  /// Every scroll view in the view hierarchy.
  private static func scrollViews(in view: UIView) -> [UIScrollView] {
    var found: [UIScrollView] = []
    if let scroll = view as? UIScrollView { found.append(scroll) }
    for sub in view.subviews { found += scrollViews(in: sub) }
    return found
  }

  /// Alpha (0–255) per y of the fade mask, rendered 20×100 at scale 1 over an opaque fill.
  @MainActor
  private static func maskAlphas(_ fade: ApprovalCardView.FadeState) throws -> [Int] {
    let renderer = ImageRenderer(
      content: Color.black
        .frame(width: 20, height: 100)
        .mask { ApprovalCardView.bottomFadeMask(fade) }
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
