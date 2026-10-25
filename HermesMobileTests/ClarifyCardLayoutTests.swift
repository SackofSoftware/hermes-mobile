import ComposableArchitecture
import HermesKit
import SwiftUI
import UIKit
import XCTest

@testable import HermesMobile

/// Measured acceptance checks for the clarify card's bounded region — the layout facts a
/// snapshot cannot prove (the `ApprovalCardLayoutTests` pattern, `docs/features/approvals.md`).
///
/// A five-question batch is the clarify card's #65: up to five sections of server-controlled
/// text, four choices and an Other row each, in the non-scrolling region between the transcript
/// and the composer. What must hold is that the pinned Skip / Confirm row stays inside the
/// window and the questions scroll instead of pushing it out — asserted on the buttons' own
/// **accessibility frames** (the one place UIKit publishes where a SwiftUI control landed) and
/// on the region's live `UIScrollView`. Dynamic Type is pinned to `.large`: the region's cap is
/// `@ScaledMetric`.
final class ClarifyCardLayoutTests: XCTestCase {
  /// Kept alive for the duration of a test: a hosted view only lays out for real while its
  /// window exists.
  private var windows: [UIWindow] = []

  override func tearDown() {
    for window in windows {
      window.isHidden = true
      window.rootViewController = nil
    }
    windows = []
    super.tearDown()
  }

  // MARK: - Five questions on the shortest keyboard-up window

  /// The smallest supported phone (320×568 under Display Zoom) with the keyboard up — the
  /// window where the approval card's region lands on its floor. A five-question batch is far
  /// taller than that, so the region must scroll while Skip / Confirm (and the composer) stay
  /// inside the window.
  @MainActor
  func testFiveQuestionsKeepSkipAndConfirmInsideTheShortestKeyboardUpWindow() throws {
    let chat = try hostedChat(width: 320, height: 352, request: Self.fiveQuestions)

    let region = try XCTUnwrap(chat.region, "the clarify card's bounded region must be hosted")
    XCTAssertGreaterThan(
      region.contentSize.height, region.bounds.height,
      "five questions must scroll inside the region, not be cut or push the card out"
    )
    XCTAssertGreaterThanOrEqual(
      region.bounds.height, ApprovalCardView.contentMinHeight - 1,
      "…and the region must keep its floor's worth of readable questions"
    )

    for title in ["Skip", "Confirm"] {
      let frame = try buttonFrame(title, in: chat)
      XCTAssertGreaterThanOrEqual(frame.minY, 0, "\(title) must not be clipped off the top")
      XCTAssertLessThanOrEqual(
        frame.maxY, chat.windowHeight, "\(title) must stay inside the window — it is pinned")
    }

    let composer = chat.composer.convert(chat.composer.bounds, to: nil)
    XCTAssertLessThanOrEqual(
      composer.maxY, chat.windowHeight, "the card must not push the composer off screen")
    let regionFrame = region.convert(region.bounds, to: nil)
    XCTAssertLessThan(
      regionFrame.maxY, composer.minY, "the pinned row must fit between the region and the composer")
  }

  /// The multi-question card gets `ChatView`'s layout priority (`isCompressibleCardPending`) —
  /// and with it the region's transcript reserve, so the conversation behind the questions is
  /// not starved to nothing on a mainstream keyboard-up window.
  @MainActor
  func testFiveQuestionsTakeTheFixedRegionButLeaveTheTranscriptARow() throws {
    let chat = try hostedChat(width: 393, height: 516, request: Self.fiveQuestions)
    let region = try XCTUnwrap(chat.region)
    XCTAssertGreaterThan(
      region.bounds.height, chat.transcript.bounds.height,
      "with priority, the questions outrank the transcript for the fixed region"
    )
    XCTAssertGreaterThanOrEqual(
      chat.transcript.bounds.height, 40, "…but the reserve keeps the transcript a usable row")
  }

  // MARK: - One question hugs its content

  /// A short single-question card asks for exactly its content: the region does not pad out to
  /// the cap and does not scroll.
  @MainActor
  func testASingleQuestionCardHugsItsContent() throws {
    let request = ClarifyRequest(
      requestID: nil,
      questions: [ClarifyQuestion(qid: "q0", question: "Proceed?", choices: ["Yes (Recommended)", "No"])],
      answerShape: .answers
    )
    let host = host(
      ClarifyCardView(request: request, onSubmit: { _ in }, onSkip: {})
        .dynamicTypeSize(.large),
      width: 390, height: 900
    )
    let region = try XCTUnwrap(
      Self.plainScrollViews(in: host.view).first, "the card hosts one bounded region")

    XCTAssertGreaterThan(region.contentSize.height, 100, "sanity: the form is laid out")
    XCTAssertEqual(
      region.bounds.height, region.contentSize.height, accuracy: 1,
      "a short form hugs its content — no blank band, nothing hidden"
    )
    XCTAssertLessThan(
      region.bounds.height, ApprovalCardView.contentMaxHeightBase,
      "sanity: the content is under the cap, so hugging is what is being measured"
    )
  }

  // MARK: - Fixtures

  /// Five questions (upstream's maximum), four choices each where they have choices
  /// (upstream's maximum), long enough to wrap on a 320pt phone.
  static let fiveQuestions = ClarifyRequest(
    requestID: nil,
    questions: (0..<5).map { index in
      ClarifyQuestion(
        qid: "q\(index)",
        question: "Question \(index + 1): which option should the agent use for this part of the change?",
        choices: index == 4 ? [] : ["Option A (Recommended)", "Option B", "Option C", "Option D"],
        multiSelect: index == 2
      )
    },
    answerShape: .answers
  )

  // MARK: - Hosting the real ChatView

  private struct HostedChat {
    var region: UIScrollView?
    var transcript: UIScrollView
    var composer: ComposerInputTextView
    var window: UIWindow
    var windowHeight: CGFloat
  }

  /// Hosts the **real** `ChatView` with `request` standing, in a window the size of the screen
  /// area left when the keyboard is up, and forces a layout pass.
  @MainActor
  private func hostedChat(width: CGFloat, height: CGFloat, request: ClarifyRequest) throws -> HostedChat {
    var state = ChatFeature.State(
      connection: ServerConnection(baseURL: URL(string: "http://127.0.0.1:8787")!, auth: .token("t")),
      resumeStoredID: "layout-session",
      title: "Layout",
      transcript: IdentifiedArray(
        uniqueElements: (1...30).map { i in
          ChatRow(id: UUID(), kind: .message(role: .assistant, text: "row \(i)", isComplete: true))
        }
      ),
      status: .ready
    )
    // Through `present(_:)`, like the reducer: the token is the card's view identity.
    state.present(.clarify(request))
    let store = Store(initialState: state) { ChatFeature() } withDependencies: {
      $0.hermesGateway.connect = { _, _ in AsyncStream { _ in } }
      $0.continuousClock = ImmediateClock()
    }
    let hosted = host(
      NavigationStack { ChatView(store: store) }.dynamicTypeSize(.large),
      width: width, height: height
    )
    // Let the transcript's first collection-view layout settle before reading the stack.
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    hosted.view.setNeedsLayout()
    hosted.view.layoutIfNeeded()

    let scrolls = Self.scrollViews(in: hosted.view)
    return HostedChat(
      region: Self.plainScrollViews(in: hosted.view).first,
      transcript: try XCTUnwrap(
        scrolls.compactMap { $0 as? UICollectionView }.first, "the transcript must be hosted"),
      composer: try XCTUnwrap(
        scrolls.compactMap { $0 as? ComposerInputTextView }.first, "the composer must be hosted"),
      window: try XCTUnwrap(windows.last),
      windowHeight: height
    )
  }

  /// A pinned button's frame, read off the accessibility tree by its exact title (so a
  /// section's "Skip this question" cannot stand in for the card's Skip).
  private func buttonFrame(_ title: String, in chat: HostedChat) throws -> CGRect {
    try XCTUnwrap(
      Self.accessibilityElements(in: chat.window).first { $0.label == title }?.frame,
      "\(title) must be in the accessibility tree"
    )
  }

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

  /// Every labelled accessibility element, flattened, with where it actually ended up (screen
  /// coordinates — every window here is at the origin, so window coordinates too).
  private static func accessibilityElements(in object: NSObject) -> [(label: String, frame: CGRect)] {
    var found: [(String, CGRect)] = []
    let count = object.accessibilityElementCount()
    if count != NSNotFound, count > 0 {
      for index in 0..<count {
        guard let child = object.accessibilityElement(at: index) as? NSObject else { continue }
        if let label = child.accessibilityLabel { found.append((label, child.accessibilityFrame)) }
        found += accessibilityElements(in: child)
      }
    } else if let view = object as? UIView {
      for sub in view.subviews { found += accessibilityElements(in: sub) }
    }
    return found
  }

  /// The scroll views `ChatView` renders itself: the transcript is a `UICollectionView`, and
  /// the composer, a `SelectableText` row and a vertical `TextField` are `UITextView`s.
  private static func plainScrollViews(in view: UIView) -> [UIScrollView] {
    scrollViews(in: view).filter { !($0 is UICollectionView) && !($0 is UITextView) }
  }

  private static func scrollViews(in view: UIView) -> [UIScrollView] {
    var found: [UIScrollView] = []
    if let scroll = view as? UIScrollView { found.append(scroll) }
    for sub in view.subviews { found += scrollViews(in: sub) }
    return found
  }
}
