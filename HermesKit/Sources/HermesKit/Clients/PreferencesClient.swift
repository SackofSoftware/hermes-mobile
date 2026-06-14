import ComposableArchitecture
import DependenciesMacros
import Foundation

/// Non-secret, persisted app preferences. Currently just the last server URL, kept so
/// the app can auto-reconnect on launch without re-running onboarding (the token lives
/// in `KeychainClient`). Live implementation backs onto `UserDefaults`; an in-memory
/// variant is used for previews and tests.
@DependencyClient
public struct PreferencesClient: Sendable {
  public var loadServerURL: @Sendable () -> String? = { nil }
  public var saveServerURL: @Sendable (_ url: String) -> Void
  public var clearServerURL: @Sendable () -> Void
  /// Last-seen message count per session id — used to flag unread activity.
  public var loadSeenCounts: @Sendable () -> [String: Int] = { [:] }
  public var saveSeenCounts: @Sendable (_ counts: [String: Int]) -> Void
}

public extension PreferencesClient {
  /// `UserDefaults`-backed implementation.
  static func live(defaults: UserDefaults = .standard) -> PreferencesClient {
    let key = "hermes.server-url"
    let seenKey = "hermes.seen-message-counts"
    // UserDefaults is documented thread-safe but not Sendable.
    nonisolated(unsafe) let store = defaults
    return PreferencesClient(
      loadServerURL: { store.string(forKey: key) },
      saveServerURL: { store.set($0, forKey: key) },
      clearServerURL: { store.removeObject(forKey: key) },
      loadSeenCounts: { (store.dictionary(forKey: seenKey) as? [String: Int]) ?? [:] },
      saveSeenCounts: { store.set($0, forKey: seenKey) }
    )
  }

  /// Deterministic in-memory store for previews and tests.
  static func inMemory() -> PreferencesClient {
    let box = LockIsolated<String?>(nil)
    let seen = LockIsolated<[String: Int]>([:])
    return PreferencesClient(
      loadServerURL: { box.value },
      saveServerURL: { url in box.setValue(url) },
      clearServerURL: { box.setValue(nil) },
      loadSeenCounts: { seen.value },
      saveSeenCounts: { seen.setValue($0) }
    )
  }
}

extension PreferencesClient: DependencyKey {
  public static var liveValue: PreferencesClient { .live() }
  public static var testValue: PreferencesClient { .inMemory() }
}

public extension DependencyValues {
  var preferences: PreferencesClient {
    get { self[PreferencesClient.self] }
    set { self[PreferencesClient.self] = newValue }
  }
}
