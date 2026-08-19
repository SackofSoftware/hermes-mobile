import HermesKit
import SwiftUI
import UIKit
import XCTest

@testable import HermesMobile

/// Measured (not eyeballed) checks for the session row's minimum-height floor (#73).
///
/// The floor exists for the sake of a view the row does not own: iOS collapses trailing
/// swipe-action buttons into cramped text-only capsules when the row is short, and renders
/// the full icon-over-label style once it is tall enough (verified in the iOS 26.5
/// simulator at the current floor). A snapshot of the row alone cannot prove any of that —
/// what it can miss is the floor silently becoming a cap, or being lost entirely — so the
/// row is hosted for real and its fitted height is read back.
///
/// Dynamic Type is pinned to `.large` except where a test varies it: the floor is a plain
/// constant, so the thresholds below would otherwise follow the simulator's text setting.
final class SessionRowLayoutTests: XCTestCase {
  /// The width every row snapshot pins — one line of title fits comfortably.
  private static let rowWidth: CGFloat = 390

  /// Kept alive for the duration of a test: a hosted view only lays out for real while
  /// its window exists.
  private var windows: [UIWindow] = []

  override func tearDown() {
    for window in windows {
      window.isHidden = true
      window.rootViewController = nil
    }
    windows = []
    super.tearDown()
  }

  /// A one-line row (title only, no preview) — the shape that used to land the list row
  /// around 46pt and collapse the swipe buttons. Its content must sit exactly on the floor.
  @MainActor
  func testOneLineRowContentLandsOnTheFloor() {
    let height = fittedHeight(of: oneLineRow(), dynamicType: .large)
    XCTAssertEqual(
      height, SessionRowView.contentMinHeight, accuracy: 0.5,
      """
      A one-line row's content must be lifted exactly to the floor — the floor is what \
      keeps trailing swipe buttons in the icon-over-label style.
      """
    )
  }

  /// The floor is a floor, not a cap: a search-result row carrying a two-line preview must
  /// keep its natural (taller) height.
  @MainActor
  func testTallerContentGrowsPastTheFloor() {
    let twoLine = SessionRowView(
      session: Session(
        id: "s1",
        title: "Refactor the streaming parser",
        updatedAt: Date(timeIntervalSince1970: 1_749_556_800),
        preview: "Can you help me refactor the WebSocket JSON-RPC parser to handle "
          + "interleaved deltas without dropping the tail?"
      ),
      now: Date(timeIntervalSince1970: 1_749_600_000),
      showsPreview: true
    )
    XCTAssertGreaterThan(
      fittedHeight(of: twoLine, dynamicType: .large),
      SessionRowView.contentMinHeight + 10,
      "Content taller than the floor must grow freely — `minHeight` must never clip"
    )
  }

  /// Dynamic Type outranks the floor: at accessibility sizes even a one-line row's text
  /// outgrows the constant, and the row must follow the text, not the floor.
  @MainActor
  func testDynamicTypeGrowsPastTheFloor() {
    let height = fittedHeight(of: oneLineRow(), dynamicType: .accessibility3)
    XCTAssertGreaterThan(
      height, SessionRowView.contentMinHeight,
      "An AX3 headline is taller than the floor — the floor must not compress it"
    )
  }

  // MARK: - Helpers

  private func oneLineRow() -> SessionRowView {
    SessionRowView(
      session: Session(
        id: "s0",
        title: "Plan the iOS MVP",
        updatedAt: Date(timeIntervalSince1970: 1_749_556_800)
      ),
      now: Date(timeIntervalSince1970: 1_749_600_000)
    )
  }

  /// Hosts the row in a real window (the `ApprovalCardLayoutTests` convention) and reads
  /// the height it asks for at the pinned width.
  @MainActor
  private func fittedHeight(of row: SessionRowView, dynamicType: DynamicTypeSize) -> CGFloat {
    let controller = UIHostingController(rootView: row.dynamicTypeSize(dynamicType))
    // The window's safe areas (status bar / home indicator) are chrome, not row content —
    // without this the fitted height reads floor + insets and every threshold shifts.
    controller.safeAreaRegions = []
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: Self.rowWidth, height: 400))
    window.rootViewController = controller
    window.isHidden = false
    windows.append(window)
    controller.view.setNeedsLayout()
    controller.view.layoutIfNeeded()
    return controller.sizeThatFits(
      in: CGSize(width: Self.rowWidth, height: CGFloat.greatestFiniteMagnitude)
    ).height
  }
}
