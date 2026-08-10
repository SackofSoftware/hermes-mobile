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
  /// Clear the persisted session. The live implementation also flushes any gated-session
  /// cookies rehydrated into `HTTPCookieStorage.shared` (used by the REST/WS transports) so
  /// no stale cookie outlives logout — call this, not `deleteToken`, on logout.
  public var deleteSession: @Sendable () throws -> Void
  /// Activate a freshly-captured `.cookie` session by rehydrating its cookies into
  /// `HTTPCookieStorage.shared` — the jar the live REST/WS transports read. Call this right
  /// after `passwordLogin` (BEFORE the first authenticated REST call): the login cookies are
  /// otherwise captured only in an isolated jar, so `.shared` stays empty and authenticated
  /// REST calls 401 until the next launch (when `loadSession` rehydrates). Flushes any prior
  /// shared cookies first so a user-switch / re-auth can't mix old and new jars.
  public var activateCookieSession: @Sendable (_ session: CookieSession) -> Void = { _ in }
  /// Snapshot the cookies **currently live** in `HTTPCookieStorage.shared` — the jar the REST/WS
  /// transports actually authenticate with. The persisted `CookieSession` is only the
  /// *login-time* vintage: the gated server rotates cookies transparently on any response and
  /// nothing writes those back to the Keychain, so the jar can hold newer cookies than the
  /// stored session does. Callers that need to re-install (`activateCookieSession`) or re-send
  /// (`unregisterPush` after logout has flushed the jar) a cookie session must read it from
  /// here first, or they downgrade a refreshed session to its stale copy.
  public var captureSharedCookies: @Sendable () -> [SerializedCookie] = { [] }
  /// Flush every cookie out of `HTTPCookieStorage.shared` — the same jar-clearing half
  /// `deleteSession` performs, exposed on its own so logout can run it a SECOND time once the
  /// in-flight work it is racing has been cancelled. `deleteSession` clears the jar while REST
  /// effects may still be in flight, and `URLSession` writes a reply's `Set-Cookie` into the
  /// shared jar itself — so a response landing after that first flush would repopulate live
  /// credentials behind a user who has just logged out. Idempotent, and cheap: an already-empty
  /// jar is a no-op.
  public var flushSharedCookies: @Sendable () -> Void = {}

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
      var add = identity
      add[kSecValueData as String] = data
      add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
      try writeStoredSession(
        update: {
          SecItemUpdate(
            identity as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
          )
        },
        add: { SecItemAdd(add as CFDictionary, nil) }
      )
    }
    @Sendable func delete() throws {
      let identity: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
      ]
      try deleteStoredSession { SecItemDelete(identity as CFDictionary) }
    }
    return KeychainClient(
      loadSession: { load($0) },
      saveSession: { try save($0) },
      deleteSession: { try delete() },
      activateCookieSession: { activateSharedCookieSession($0) },
      captureSharedCookies: { sharedCookieSnapshot() },
      flushSharedCookies: { clearSharedCookies() },
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
      // No-op for the in-memory variant: feature tests don't drive the live `.shared` jar, and
      // mutating the process-global jar here would race across parallel suites. Tests that
      // need to assert activation override this endpoint with a spy.
      activateCookieSession: { _ in },
      // Likewise a no-op: the in-memory variant never drives the process-global jar, so it has
      // nothing live to snapshot. An empty snapshot is the "nothing fresher than the stored
      // session" answer every caller already handles. Spy on it to assert a capture.
      captureSharedCookies: { [] },
      // Same reasoning: the in-memory variant owns no process-global jar to flush. Spy on it to
      // assert logout's post-cancellation re-flush.
      flushSharedCookies: {},
      loadToken: { box.get()?.token },
      saveToken: { box.set(.token($0)) },
      deleteToken: { box.set(nil) }
    )
  }
}

/// The live `deleteSession`: remove the Keychain item, then flush the gated-session cookies
/// rehydrated into `HTTPCookieStorage.shared` (where the live REST/WS transports read them) so
/// logout leaves nothing behind for the next user.
///
/// The flush is **unconditional, and that is the whole point of this function existing**: the
/// Keychain removal can fail (`errSecInteractionNotAllowed`, any other `OSStatus`), and
/// throwing before the flush left a user who had just "logged out" with live authentication
/// cookies in the jar every subsequent request is signed with. The item removal is injected so
/// that guarantee is testable without a Keychain that can be made to fail.
func deleteStoredSession(_ removeKeychainItem: () -> OSStatus) throws {
  let status = removeKeychainItem()
  clearSharedCookies()
  guard status == errSecSuccess || status == errSecItemNotFound else {
    throw KeychainError.unhandled(status)
  }
}

/// The live `saveSession`: a real **upsert** — update first, add only when there is nothing to
/// update. Never "delete then add and hope".
///
/// Order matters, and it is the opposite of the obvious one. Deleting first makes the write
/// *destructive before it is constructive*: if the following `SecItemAdd` fails for any reason
/// that is not `errSecDuplicateItem` (`errSecNotAvailable`, `errSecInteractionNotAllowed`, a
/// full-disk `errSecIO`…), the previous credential is already gone and the new one never landed
/// — the device is left with no session at all. `SecItemUpdate` first is atomic in the case that
/// matters: it either overwrites in place or answers `errSecItemNotFound`, which is the only
/// status that means "nothing there yet" and the only one that falls through to `SecItemAdd`.
///
/// That in-place overwrite is also what makes `fullLogout`'s "overwrite the credential I could
/// not delete" compensation real, and a failure of either step propagates rather than being
/// swallowed, so the caller can say out loud that the credential is still on the device.
/// Injected ops so every branch is testable without a Keychain that can be made to fail.
func writeStoredSession(
  update: () -> OSStatus,
  add: () -> OSStatus
) throws {
  let updateStatus = update()
  if updateStatus == errSecSuccess { return }
  // Anything other than "no such item" is a real failure — do NOT fall through to an add that
  // would race the item we could not write.
  guard updateStatus == errSecItemNotFound else { throw KeychainError.unhandled(updateStatus) }
  let addStatus = add()
  guard addStatus == errSecSuccess else { throw KeychainError.unhandled(addStatus) }
}

/// Snapshot every cookie currently in `HTTPCookieStorage.shared` (see
/// `KeychainClient.captureSharedCookies`) — deliberately unfiltered: domain-matching guesswork
/// here would be the thing that silently drops the rotated cookie a refresh depends on.
///
/// **"Every cookie" is NOT the same as "the live session's cookies".** The jar is process-global
/// and persisted, so it can also hold a previous server's cookies (nothing flushes it until the
/// next logout / cookie-session activation) or anything else a response set. Consumers must
/// therefore treat this as a raw jar snapshot and re-apply scoping themselves — which is exactly
/// what `cookieHeader(_:for:)` does before serialising any of it into an explicit `Cookie`
/// header, since setting that header switches off every rule `URLSession` would have enforced.
func sharedCookieSnapshot() -> [SerializedCookie] {
  (HTTPCookieStorage.shared.cookies ?? []).map(SerializedCookie.init)
}

/// Rehydrate a freshly-captured `.cookie` session into `HTTPCookieStorage.shared` (flushing
/// any prior cookies first) so the live REST/WS transports authenticate immediately after an
/// in-app login — not just on the next launch.
func activateSharedCookieSession(_ session: CookieSession) {
  clearSharedCookies()
  rehydrate(.cookie(session), into: .shared)
}

/// Remove every cookie from `HTTPCookieStorage.shared` — the jar the live REST/WS transports
/// read (and into which a `.cookie` session is rehydrated). Called on session deletion so a
/// gated logout leaves no cookie behind. (Clearing the WHOLE jar is the conservative direction:
/// the app talks to one agent at a time and stores nothing else in it, so an over-broad flush
/// costs nothing, while domain-matching guesswork could leave a session cookie behind.)
func clearSharedCookies() {
  let storage = HTTPCookieStorage.shared
  for cookie in storage.cookies ?? [] { storage.deleteCookie(cookie) }
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
