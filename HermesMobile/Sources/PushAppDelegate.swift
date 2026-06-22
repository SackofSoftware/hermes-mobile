import HermesKit
import os
import UIKit
import UserNotifications

/// App-delegate bridge for push notifications (#push C2). Converts UIKit /
/// `UNUserNotificationCenter` callbacks into `PushBridge` calls and nothing more —
/// **no business logic lives here**. All decisions (registration, deep-link, suppression,
/// badging) belong to reducers/clients downstream of the streams `PushBridge` feeds.
final class PushAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
  private static let log = Logger(subsystem: "me.honcharenko.HermesMobile", category: "push")

  func application(
    _: UIApplication,
    didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    return true
  }

  // MARK: - Remote-notification registration

  func application(
    _: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    PushBridge.shared.tokenReceived(deviceToken)
  }

  func application(
    _: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    Self.log.error("APNs registration failed: \(error.localizedDescription, privacy: .public)")
  }

  // MARK: - UNUserNotificationCenterDelegate

  /// User tapped a notification → forward the `session_id` for deep-linking.
  func userNotificationCenter(
    _: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    PushBridge.shared.tapReceived(response.notification.request.content.userInfo)
    completionHandler()
  }

  /// A notification arrived while the app is foregrounded. C2 keeps this minimal: present a
  /// sensible default banner + sound. Nav-aware suppression is C5.
  func userNotificationCenter(
    _: UNUserNotificationCenter,
    willPresent _: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .sound])
  }
}
