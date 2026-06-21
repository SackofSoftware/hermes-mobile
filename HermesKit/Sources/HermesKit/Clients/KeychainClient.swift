import ComposableArchitecture
import DependenciesMacros
import Foundation
import Security

/// Stores the Hermes auth session (a bare token in `.token` mode, or the cookie payload +
/// username in `.cookie` mode). Live implementation backs onto the iOS Keychain; an
/// in-memory variant is used for previews and feature tests.
///
/// The session is persisted as a JSON-encoded `AuthSession` under a single Keychain item.
/// `loadSession`/`saveSession`/`deleteSession` are the full-session API; the `…Token`
/// closures are thin token-mode shims (kept as first-class dependency endpoints so the
/// existing token-mode call sites and their test overrides stay unchanged).
@DependencyClient
public struct KeychainClient: Sendable {
  /// Load the full persisted session. For a `.cookie` session this also rehydrates the
  /// captured cookies into the supplied `HTTPCookieStorage` so the REST/WS transports pick
  /// them up on a fresh launch.
  public var loadSession: @Sendable (_ storage: HTTPCookieStorage) -> AuthSession? = { _ in nil }
  /// Persist the full session (token payload, or cookie jar + username).
  public var saveSession: @Sendable (_ session: AuthSession) throws -> Void
  /// Clear the persisted session.
  public var deleteSession: @Sendable () throws -> Void

  // Token-mode shims — retained as dependency endpoints for byte-identical token behaviour.
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
    @Sendable func load(_ storage: HTTPCookieStorage) -> AuthSession? {
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
      guard let session = decodeSession(data) else { return nil }
      rehydrate(session, into: storage)
      return session
    }
    @Sendable func save(_ session: AuthSession) throws {
      let data = try JSONEncoder().encode(session)
      let identity: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
      ]
      SecItemDelete(identity as CFDictionary) // upsert: clear any existing item first
      var add = identity
      add[kSecValueData as String] = data
      add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
      let status = SecItemAdd(add as CFDictionary, nil)
      guard status == errSecSuccess else { throw KeychainError.unhandled(status) }
    }
    @Sendable func delete() throws {
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
    return KeychainClient(
      loadSession: { load($0) },
      saveSession: { try save($0) },
      deleteSession: { try delete() },
      loadToken: { load(.shared)?.token },
      saveToken: { try save(.token($0)) },
      deleteToken: { try delete() }
    )
  }

  /// Deterministic in-memory store for previews and tests.
  static func inMemory() -> KeychainClient {
    let box = SessionBox()
    @Sendable func load(_ storage: HTTPCookieStorage) -> AuthSession? {
      guard let session = box.get() else { return nil }
      rehydrate(session, into: storage)
      return session
    }
    return KeychainClient(
      loadSession: { load($0) },
      saveSession: { box.set($0) },
      deleteSession: { box.set(nil) },
      loadToken: { box.get()?.token },
      saveToken: { box.set(.token($0)) },
      deleteToken: { box.set(nil) }
    )
  }
}

/// Decode a persisted `AuthSession`. Falls back to treating a legacy raw-string payload
/// (a bare token written by older builds) as `.token` so existing installs keep working.
private func decodeSession(_ data: Data) -> AuthSession? {
  if let session = try? JSONDecoder().decode(AuthSession.self, from: data) {
    return session
  }
  if let token = String(data: data, encoding: .utf8), !token.isEmpty {
    return .token(token)
  }
  return nil
}

/// Rehydrate a `.cookie` session's cookies into the cookie storage so the transports
/// authenticate on a fresh launch. `.token` sessions need no cookie work.
private func rehydrate(_ session: AuthSession, into storage: HTTPCookieStorage) {
  guard case let .cookie(cookieSession) = session else { return }
  for cookie in cookieSession.cookies.compactMap(\.httpCookie) {
    storage.setCookie(cookie)
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
private final class SessionBox: @unchecked Sendable {
  private let lock = NSLock()
  private var value: AuthSession?
  func get() -> AuthSession? { lock.withLock { value } }
  func set(_ newValue: AuthSession?) { lock.withLock { value = newValue } }
}
