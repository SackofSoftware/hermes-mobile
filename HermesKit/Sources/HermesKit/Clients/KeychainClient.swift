import ComposableArchitecture
import DependenciesMacros
import Foundation
import Security

/// Stores the Hermes session token. Live implementation backs onto the iOS Keychain;
/// an in-memory variant is used for previews and feature tests.
@DependencyClient
public struct KeychainClient: Sendable {
  public var loadToken: @Sendable () -> String? = { nil }
  public var saveToken: @Sendable (_ token: String) throws -> Void
  public var deleteToken: @Sendable () throws -> Void
}

public enum KeychainError: Error, Equatable, Sendable {
  case unhandled(OSStatus)
}

public extension KeychainClient {
  /// Keychain-backed implementation (generic password item).
  static func live(
    service: String = "dev.honcharenko.HermesMobile",
    account: String = "session-token"
  ) -> KeychainClient {
    // Capture only the Sendable strings; build the (non-Sendable) query dicts inside
    // each closure so nothing non-Sendable crosses the @Sendable boundary.
    return KeychainClient(
      loadToken: {
        let query: [String: Any] = [
          kSecClass as String: kSecClassGenericPassword,
          kSecAttrService as String: service,
          kSecAttrAccount as String: account,
          kSecReturnData as String: true,
          kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
      },
      saveToken: { token in
        let identity: [String: Any] = [
          kSecClass as String: kSecClassGenericPassword,
          kSecAttrService as String: service,
          kSecAttrAccount as String: account,
        ]
        SecItemDelete(identity as CFDictionary) // upsert: clear any existing item first
        var add = identity
        add[kSecValueData as String] = Data(token.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unhandled(status) }
      },
      deleteToken: {
        let identity: [String: Any] = [
          kSecClass as String: kSecClassGenericPassword,
          kSecAttrService as String: service,
          kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(identity as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
          throw KeychainError.unhandled(status)
        }
      }
    )
  }

  /// Deterministic in-memory store for previews and tests.
  static func inMemory() -> KeychainClient {
    let box = TokenBox()
    return KeychainClient(
      loadToken: { box.get() },
      saveToken: { box.set($0) },
      deleteToken: { box.set(nil) }
    )
  }
}

extension KeychainClient: DependencyKey {
  public static var liveValue: KeychainClient { .live() }
  // Feature tests get a working in-memory store by default (deterministic, isolated).
  public static var testValue: KeychainClient { .inMemory() }
}

public extension DependencyValues {
  var keychain: KeychainClient {
    get { self[KeychainClient.self] }
    set { self[KeychainClient.self] = newValue }
  }
}

/// Lock-guarded box backing the in-memory keychain.
private final class TokenBox: @unchecked Sendable {
  private let lock = NSLock()
  private var value: String?
  func get() -> String? { lock.withLock { value } }
  func set(_ newValue: String?) { lock.withLock { value = newValue } }
}
