import ComposableArchitecture
import SwiftUI
import UIKit
import XCTest

@testable import HermesMobile

/// The bottom action sheet's load-bearing wiring: a dialog button carrying an action must
/// send it through the store — this view replaced the system `.confirmationDialog` for
/// every `SessionListView` dialog (archive, delete, profile delete), so a routing
/// regression would break all of them at once. The action-less Cancel path dismisses via
/// the SwiftUI environment (exercised by the on-device flows); the snapshot test pins the
/// rendering.
final class BottomActionSheetInteractionTests: XCTestCase {
  private enum DialogAction: Equatable { case confirm }

  private var window: UIWindow?

  override func tearDown() {
    window?.isHidden = true
    window?.rootViewController = nil
    window = nil
    super.tearDown()
  }

  @MainActor
  func testDestructiveButtonSendsItsActionThroughTheStore() throws {
    let received = LockIsolated<[DialogAction]>([])
    let dialog = ConfirmationDialogState<DialogAction> {
      TextState("Delete session?")
    } actions: {
      ButtonState(role: .destructive, action: .confirm) { TextState("Delete") }
      ButtonState(role: .cancel) { TextState("Cancel") }
    } message: {
      TextState("This permanently deletes the session and its history.")
    }
    let store = Store<ConfirmationDialogState<DialogAction>, DialogAction>(
      initialState: dialog
    ) {
      Reduce { _, action in
        received.withValue { $0.append(action) }
        return .none
      }
    }

    let controller = UIHostingController(rootView: BottomActionSheetView(store: store))
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 400))
    window.rootViewController = controller
    window.makeKeyAndVisible()
    self.window = window
    controller.view.layoutIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))

    let delete = try XCTUnwrap(
      accessibilityElement(labeled: "Delete", under: controller.view),
      "The destructive dialog button must be reachable as an accessibility element"
    )
    XCTAssertTrue(
      delete.accessibilityActivate(),
      "Activating the button must run its SwiftUI action"
    )
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    XCTAssertEqual(received.value, [.confirm], "The button's dialog action must reach the store")
  }

  /// Depth-first search across the UIKit view tree AND each node's accessibility
  /// elements — SwiftUI vends its controls as `UIAccessibilityElement`s, not subviews.
  private func accessibilityElement(labeled label: String, under root: NSObject) -> NSObject? {
    if root.accessibilityLabel == label { return root }
    var children: [NSObject] = (root.accessibilityElements as? [NSObject]) ?? []
    if let view = root as? UIView {
      children.append(contentsOf: view.subviews)
    }
    for child in children {
      if let match = accessibilityElement(labeled: label, under: child) { return match }
    }
    return nil
  }
}
