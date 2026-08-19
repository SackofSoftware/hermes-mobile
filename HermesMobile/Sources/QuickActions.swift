import Foundation
import UIKit

/// Home-screen quick actions (long-press the app icon). Today there's exactly one:
/// **New Chat**.
///
/// The tricky part isn't the shortcut, it's the timing. A quick action can fire while the
/// app is cold-launching, long before there's a session list to start a chat in — and if
/// you're signed out it may never become valid at all. So this type never acts directly:
/// it only *records* the pending action, and `AppView` drains it once the home screen is
/// actually on screen. A pending action that's never drained is simply dropped on the
/// next launch, which is the right behaviour for a stale tap.
enum QuickAction: String {
  case newChat = "me.hawes.hermes.newchat"

  init?(shortcutItem: UIApplicationShortcutItem) {
    self.init(rawValue: shortcutItem.type)
  }
}

/// Holds the action a quick action requested until the UI is ready to honour it.
///
/// Main-actor isolated: it's written from `UIApplicationDelegate` callbacks and read from
/// SwiftUI, both on the main actor, so no locking is needed.
@MainActor
final class QuickActionBox {
  static let shared = QuickActionBox()

  /// Set by the app delegate; cleared by whoever performs it.
  private(set) var pending: QuickAction?

  private init() {}

  func record(_ action: QuickAction?) {
    guard let action else { return }
    pending = action
  }

  /// Hand back the pending action exactly once. Returns nil if there's nothing to do.
  func take() -> QuickAction? {
    defer { pending = nil }
    return pending
  }
}
