import ComposableArchitecture
import DependenciesMacros
import Foundation

/// Authorization state for push notifications. A small Sendable mirror of
/// `UNAuthorizationStatus` so HermesKit doesn't leak `UserNotifications` types to the
/// non-iOS test host (the package is also built/tested on macOS via `swift test`).
public enum PushAuthorizationStatus: Equatable, Sendable {
  case notDetermined
  case denied
  case authorized
  /// Provisional / ephemeral authorizations (treated as "may deliver" by callers).
  case provisional
}

/// A tapped push notification, carrying just enough to deep-link (#push). Only generic
/// metadata transits the gateway — real message content is fetched in-app — so a tap
/// surfaces the `session_id` and nothing sensitive.
public struct PushTap: Equatable, Sendable {
  public let sessionID: String

  public init(sessionID: String) {
    self.sessionID = sessionID
  }
}

/// Bridges APNs registration + notification handling behind a dependency so reducers stay
/// testable and never touch `UserNotifications`/`UIKit` directly. The app-delegate bridge
/// (C2) feeds device tokens and taps into the streams this client exposes.
@DependencyClient
public struct PushClient: Sendable {
  /// Prompt for (or read) notification permission. `true` ⇒ granted.
  public var requestAuthorization: @Sendable () async -> Bool = { false }
  /// Current authorization status (no prompt).
  public var authorizationStatus: @Sendable () async -> PushAuthorizationStatus = { .notDetermined }
  /// Trigger `registerForRemoteNotifications` and stream device tokens as lowercase hex
  /// strings. The app-delegate bridge yields a token here once APNs registration succeeds;
  /// the stream re-yields on token rotation. Finishes when the consumer is cancelled.
  public var register: @Sendable () -> AsyncStream<String> = { AsyncStream { $0.finish() } }
  /// A stream of incoming notification taps (carrying the `session_id`) for deep-linking.
  public var incomingTaps: @Sendable () -> AsyncStream<PushTap> = { AsyncStream { $0.finish() } }

  // MARK: - Pure logic (unit-tested on macOS, outside the iOS guard)

  /// Encode an APNs device-token `Data` blob as a lowercase hex string (the form the
  /// gateway/plugin expect). Pure so it's testable on any platform.
  public static func hexToken(from data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
  }

  /// The APNs environment baked in at compile time. A Debug build registers with the APNs
  /// *sandbox*; a Release build registers with *production*. The env→host mismatch is the
  /// classic push footgun, so it's a single compile-time constant threaded to registration.
  public static let apnsEnv: String = {
    #if DEBUG
      return "sandbox"
    #else
      return "production"
    #endif
  }()

  /// Parse the `session_id` out of an APNs userInfo payload (`{ "session_id": "…" }`).
  /// Returns `nil` when absent/empty so the bridge can drop a malformed tap. Pure.
  public static func sessionID(fromPayload payload: [AnyHashable: Any]) -> String? {
    guard let id = payload["session_id"] as? String, !id.isEmpty else { return nil }
    return id
  }
}

extension PushClient: DependencyKey {
  /// No-op double: never granted, empty streams. Override individual closures in tests.
  /// (Spelled out rather than the bare memberwise init so the `@DependencyClient` macro's
  /// unimplemented closures don't leak into the default test double.)
  public static var testValue: PushClient {
    PushClient(
      requestAuthorization: { false },
      authorizationStatus: { .notDetermined },
      register: { AsyncStream { $0.finish() } },
      incomingTaps: { AsyncStream { $0.finish() } }
    )
  }
}

public extension DependencyValues {
  var push: PushClient {
    get { self[PushClient.self] }
    set { self[PushClient.self] = newValue }
  }
}

// MARK: - In-memory (deterministic test variant)

/// Thread-safe mailbox driving the in-memory client's streams and authorize result, so
/// tests can inject a token / tap / granted-result and observe them through the public API.
private final class PushBox: @unchecked Sendable {
  private let lock = NSLock()
  private var _granted: Bool
  private var _status: PushAuthorizationStatus
  private var tokenContinuations: [AsyncStream<String>.Continuation] = []
  private var tapContinuations: [AsyncStream<PushTap>.Continuation] = []

  init(granted: Bool, status: PushAuthorizationStatus) {
    _granted = granted
    _status = status
  }

  var granted: Bool {
    lock.withLock { _granted }
  }

  var status: PushAuthorizationStatus {
    lock.withLock { _status }
  }

  func setAuthorized(_ granted: Bool) {
    lock.withLock {
      _granted = granted
      _status = granted ? .authorized : .denied
    }
  }

  func tokenStream() -> AsyncStream<String> {
    AsyncStream { continuation in
      lock.withLock { tokenContinuations.append(continuation) }
    }
  }

  func tapStream() -> AsyncStream<PushTap> {
    AsyncStream { continuation in
      lock.withLock { tapContinuations.append(continuation) }
    }
  }

  func emit(token: String) {
    let continuations = lock.withLock { tokenContinuations }
    for continuation in continuations { continuation.yield(token) }
  }

  func emit(tap: PushTap) {
    let continuations = lock.withLock { tapContinuations }
    for continuation in continuations { continuation.yield(tap) }
  }
}

public extension PushClient {
  /// A deterministic, controllable client for tests: `authorize()` returns the configured
  /// result and exposes hooks to push a token / tap into the live streams. Mirrors
  /// `AudioRecorderClient` / `KeychainClient` `.inMemory()` variants.
  struct InMemory: Sendable {
    public let client: PushClient
    private let box: PushBox

    public init(granted: Bool = true, status: PushAuthorizationStatus = .authorized) {
      let box = PushBox(granted: granted, status: status)
      self.box = box
      self.client = PushClient(
        requestAuthorization: {
          box.setAuthorized(box.granted)
          return box.granted
        },
        authorizationStatus: { box.status },
        register: { box.tokenStream() },
        incomingTaps: { box.tapStream() }
      )
    }

    /// Push a device token into the `register()` stream as if APNs delivered it.
    public func emit(token: String) { box.emit(token: token) }
    /// Push a tap into the `incomingTaps()` stream as if the user tapped a notification.
    public func emit(tap: PushTap) { box.emit(tap: tap) }
    /// Change the granted result the next `requestAuthorization()` returns.
    public func setAuthorized(_ granted: Bool) { box.setAuthorized(granted) }
  }

  /// Convenience: a controllable in-memory client + handle for driving its streams.
  static func inMemory(
    granted: Bool = true,
    status: PushAuthorizationStatus = .authorized
  ) -> InMemory {
    InMemory(granted: granted, status: status)
  }
}

// MARK: - Live (iOS only)

// `UNUserNotificationCenter`/`UIApplication.registerForRemoteNotifications` are iOS-only;
// the package is also built/tested on macOS via `swift test`, so the live client is
// compiled in only where UIKit exists. Elsewhere `liveValue` falls back to the no-op
// double (#push).
#if canImport(UIKit)
  import UIKit
  import UserNotifications

  /// Process-wide hub the app-delegate bridge (C2) feeds tokens/taps into, fanned out to
  /// every `register()` / `incomingTaps()` consumer. Lives here so the bridge has no logic
  /// of its own — it just calls `tokenReceived` / `tapReceived`.
  public final class PushBridge: @unchecked Sendable {
    public static let shared = PushBridge()

    private let lock = NSLock()
    private var tokenContinuations: [AsyncStream<String>.Continuation] = []
    private var tapContinuations: [AsyncStream<PushTap>.Continuation] = []
    private var lastToken: String?

    private init() {}

    func tokenStream() -> AsyncStream<String> {
      AsyncStream { continuation in
        let cached: String? = lock.withLock {
          tokenContinuations.append(continuation)
          return lastToken
        }
        // Re-deliver the most recent token so a late subscriber still registers.
        if let cached { continuation.yield(cached) }
      }
    }

    func tapStream() -> AsyncStream<PushTap> {
      AsyncStream { continuation in
        lock.withLock { tapContinuations.append(continuation) }
      }
    }

    /// Called by the app delegate on `didRegisterForRemoteNotificationsWithDeviceToken`.
    public func tokenReceived(_ data: Data) {
      let hex = PushClient.hexToken(from: data)
      let continuations: [AsyncStream<String>.Continuation] = lock.withLock {
        lastToken = hex
        return tokenContinuations
      }
      for continuation in continuations { continuation.yield(hex) }
    }

    /// Called by the app delegate on a notification tap (`didReceive`).
    public func tapReceived(_ payload: [AnyHashable: Any]) {
      guard let id = PushClient.sessionID(fromPayload: payload) else { return }
      let continuations = lock.withLock { tapContinuations }
      for continuation in continuations { continuation.yield(PushTap(sessionID: id)) }
    }
  }

  extension PushClient {
    public static var liveValue: PushClient {
      PushClient(
        requestAuthorization: {
          let center = UNUserNotificationCenter.current()
          let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
          if granted {
            await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
          }
          return granted
        },
        authorizationStatus: {
          let settings = await UNUserNotificationCenter.current().notificationSettings()
          switch settings.authorizationStatus {
          case .authorized: return .authorized
          case .provisional, .ephemeral: return .provisional
          case .denied: return .denied
          case .notDetermined: return .notDetermined
          @unknown default: return .notDetermined
          }
        },
        register: {
          Task { @MainActor in UIApplication.shared.registerForRemoteNotifications() }
          return PushBridge.shared.tokenStream()
        },
        incomingTaps: { PushBridge.shared.tapStream() }
      )
    }
  }
#else
  extension PushClient {
    /// No push off-device (macOS `swift test`): fall back to the no-op double.
    public static var liveValue: PushClient { testValue }
  }
#endif
