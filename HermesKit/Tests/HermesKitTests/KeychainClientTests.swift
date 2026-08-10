import ComposableArchitecture
import Foundation
import Security
import Testing

@testable import HermesKit

// Serialized: several cases touch the process-global `HTTPCookieStorage.shared`, and
// `deleteSession` now flushes it — running them concurrently would let one test wipe
// another's cookies.
@Suite(.serialized) struct KeychainClientTests {
  // MARK: Token-mode (byte-identical to before)

  @Test func inMemoryTokenRoundTrip() throws {
    let kc = KeychainClient.inMemory()
    #expect(kc.loadToken() == nil)
    try kc.saveToken("abc")
    #expect(kc.loadToken() == "abc")
    try kc.saveToken("def") // overwrite
    #expect(kc.loadToken() == "def")
    try kc.deleteToken()
    #expect(kc.loadToken() == nil)
  }

  @Test func tokenSessionRoundTripsAsAuthSession() throws {
    let kc = KeychainClient.inMemory()
    try kc.saveSession(.token("xyz"))
    #expect(kc.loadSession(HTTPCookieStorage()) == .token("xyz"))
    #expect(kc.loadToken() == "xyz")
  }

  // MARK: Cookie-mode

  @Test func cookieSessionSerializeStoreLoad() throws {
    let kc = KeychainClient.inMemory()
    let cookieSession = CookieSession(
      cookies: [
        SerializedCookie(name: "hermes_session_at", value: "ACCESS", domain: "test.local", path: "/"),
        SerializedCookie(name: "hermes_session_rt", value: "REFRESH", domain: "test.local", path: "/"),
      ],
      username: "alice",
      provider: "basic"
    )
    try kc.saveSession(.cookie(cookieSession))

    let loaded = kc.loadSession(HTTPCookieStorage())
    #expect(loaded == .cookie(cookieSession))
    // The token shim is nil for a cookie session.
    #expect(loaded?.token == nil)
  }

  @Test func loadRehydratesCookiesIntoStorage() throws {
    // Apple's `HTTPCookieStorage()` (freshly allocated) silently drops `setCookie`; only
    // `.shared` (and named group containers) actually persist. Use `.shared` and clean up.
    let kc = KeychainClient.inMemory()
    let storage = HTTPCookieStorage.shared
    let unique = "hermes_session_at_\(UUID().uuidString)"
    defer {
      storage.cookies?.filter { $0.name == unique }.forEach(storage.deleteCookie)
    }
    let cookieSession = CookieSession(
      cookies: [
        SerializedCookie(name: unique, value: "ACCESS", domain: "test.local", path: "/"),
      ],
      username: "alice",
      provider: "basic"
    )
    try kc.saveSession(.cookie(cookieSession))

    _ = kc.loadSession(storage)

    let names = (storage.cookies ?? []).map(\.name)
    #expect(names.contains(unique))
    let value = storage.cookies?.first { $0.name == unique }?.value
    #expect(value == "ACCESS")
  }

  @Test func deleteClearsCookieSession() throws {
    let kc = KeychainClient.inMemory()
    try kc.saveSession(.cookie(CookieSession(cookies: [], username: "a", provider: "basic")))
    #expect(kc.loadSession(HTTPCookieStorage()) != nil)
    try kc.deleteSession()
    #expect(kc.loadSession(HTTPCookieStorage()) == nil)
  }

  /// Logout must flush gated cookies out of the shared jar the live transports read — not
  /// just clear the Keychain item. `clearSharedCookies()` is what the live `deleteSession`
  /// runs (review finding #6). Without this, stale gated-session cookies linger after logout.
  @Test func clearSharedCookiesFlushesTheSharedJar() throws {
    let storage = HTTPCookieStorage.shared
    let unique = "hermes_session_at_\(UUID().uuidString)"
    defer { storage.cookies?.filter { $0.name == unique }.forEach(storage.deleteCookie) }
    if let cookie = SerializedCookie(name: unique, value: "ACCESS", domain: "test.local", path: "/").httpCookie {
      storage.setCookie(cookie)
    }
    #expect((storage.cookies ?? []).contains { $0.name == unique })

    clearSharedCookies()
    #expect(!(storage.cookies ?? []).contains { $0.name == unique })
  }

  /// …and the flush must happen even when the Keychain removal FAILS. `deleteSession` used to
  /// throw first and clear the jar after, so an `OSStatus` failure left a user who had just
  /// logged out with live gated-session cookies signing every subsequent request (review
  /// finding). The error is still surfaced — the flush is what must not be conditional on it.
  @Test func deleteFlushesSharedCookiesEvenWhenTheKeychainRemovalFails() throws {
    let storage = HTTPCookieStorage.shared
    let unique = "hermes_session_at_\(UUID().uuidString)"
    defer { storage.cookies?.filter { $0.name == unique }.forEach(storage.deleteCookie) }
    if let cookie = SerializedCookie(name: unique, value: "ACCESS", domain: "test.local", path: "/").httpCookie {
      storage.setCookie(cookie)
    }
    #expect((storage.cookies ?? []).contains { $0.name == unique })

    #expect(throws: KeychainError.unhandled(errSecInteractionNotAllowed)) {
      try deleteStoredSession { errSecInteractionNotAllowed }
    }
    #expect(!(storage.cookies ?? []).contains { $0.name == unique })
  }

  /// The live save is an **upsert**, and the upsert is what makes `fullLogout`'s "overwrite the
  /// session I could not delete" compensation real: when an item is already there it is
  /// overwritten IN PLACE, and the add is never reached.
  @Test func saveOverwritesAnExistingItemInPlace() throws {
    let added = LockIsolated(0)
    let updated = LockIsolated(0)
    try writeStoredSession(
      update: {
        updated.withValue { $0 += 1 }
        return errSecSuccess
      },
      add: {
        added.withValue { $0 += 1 }
        return errSecSuccess
      }
    )
    #expect(updated.value == 1)
    #expect(added.value == 0)
  }

  /// The ordering is the whole point, and this is the test that pins it — with a write that
  /// actually FAILS (the earlier version of this test let the update succeed, so the failing
  /// branch it claimed to cover was unreachable and it merely restated the happy path above).
  ///
  /// The Keychain here holds a credential it will not let anyone write (locked / unavailable —
  /// `errSecInteractionNotAllowed`). A delete-then-add "upsert" is destructive before it is
  /// constructive: it would already have removed `OLD` before discovering the write cannot land,
  /// leaving the device with no session at all. Update-first meets the same failure with the
  /// stored credential untouched, and must NOT fall through to the add — the only step in this
  /// fake that can still mutate the store — which is why the add is wired to clobber it.
  @Test func saveNeverDestroysTheOldItemWhenTheWriteFails() throws {
    let store = LockIsolated<String?>("OLD")
    let addAttempts = LockIsolated(0)

    #expect(throws: KeychainError.unhandled(errSecInteractionNotAllowed)) {
      try writeStoredSession(
        update: {
          guard store.value != nil else { return errSecItemNotFound }
          return errSecInteractionNotAllowed
        },
        add: {
          addAttempts.withValue { $0 += 1 }
          store.setValue("NEW") // a fallthrough here is exactly what would lose the old value
          return errSecNotAvailable
        }
      )
    }

    #expect(store.value == "OLD") // the credential survived a failed write
    #expect(addAttempts.value == 0)
  }

  /// …and when the in-place overwrite fails for a real reason, that is NOT swallowed (the caller
  /// has to tell "neutralized" from "still on the device") and it does NOT fall through to an
  /// add that would race the item it could not write.
  @Test func saveThrowsWhenTheOverwriteFailsAndDoesNotFallThroughToAdd() throws {
    let added = LockIsolated(0)
    #expect(throws: KeychainError.unhandled(errSecInteractionNotAllowed)) {
      try writeStoredSession(
        update: { errSecInteractionNotAllowed },
        add: {
          added.withValue { $0 += 1 }
          return errSecSuccess
        }
      )
    }
    #expect(added.value == 0)
  }

  /// The first-ever write: nothing to update, so it adds — and a failing add is still an error.
  @Test func saveAddsWhenThereIsNoExistingItem() throws {
    let added = LockIsolated(0)
    try writeStoredSession(
      update: { errSecItemNotFound },
      add: {
        added.withValue { $0 += 1 }
        return errSecSuccess
      }
    )
    #expect(added.value == 1)
    #expect(throws: KeychainError.unhandled(errSecNotAvailable)) {
      try writeStoredSession(update: { errSecItemNotFound }, add: { errSecNotAvailable })
    }
  }

  /// The live jar — not the Keychain's login-time vintage — is what the transports authenticate
  /// with, so it has to be readable: a transparently-rotated cookie exists nowhere else.
  @Test func captureSharedCookiesSnapshotsTheLiveJar() throws {
    let storage = HTTPCookieStorage.shared
    let unique = "hermes_session_at_\(UUID().uuidString)"
    defer { storage.cookies?.filter { $0.name == unique }.forEach(storage.deleteCookie) }
    if let cookie = SerializedCookie(name: unique, value: "ROTATED", domain: "test.local", path: "/").httpCookie {
      storage.setCookie(cookie)
    }

    let snapshot = sharedCookieSnapshot()
    #expect(snapshot.first { $0.name == unique }?.value == "ROTATED")
  }

  /// The success/not-found statuses stay silent (a logout with nothing stored is not an error).
  @Test func deleteTreatsItemNotFoundAsSuccess() throws {
    try deleteStoredSession { errSecItemNotFound }
    try deleteStoredSession { errSecSuccess }
  }

  /// A fresh in-app login must push its captured cookies into the shared jar immediately
  /// (not just on next launch) so the live REST/WS transports authenticate — and must flush
  /// any prior cookies first so a user-switch can't mix jars (review recheck finding). This
  /// is the standalone op the live keychain's `activateCookieSession` runs.
  @Test func activateCookieSessionRehydratesAndFlushesSharedJar() throws {
    let storage = HTTPCookieStorage.shared
    let staleName = "hermes_stale_\(UUID().uuidString)"
    let freshName = "hermes_session_at_\(UUID().uuidString)"
    defer {
      storage.cookies?
        .filter { $0.name == staleName || $0.name == freshName }
        .forEach(storage.deleteCookie)
    }
    // Seed a stale cookie as if a prior session left it behind.
    if let stale = SerializedCookie(name: staleName, value: "OLD", domain: "test.local", path: "/").httpCookie {
      storage.setCookie(stale)
    }
    #expect((storage.cookies ?? []).contains { $0.name == staleName })

    activateSharedCookieSession(CookieSession(
      cookies: [SerializedCookie(name: freshName, value: "NEW", domain: "test.local", path: "/")],
      username: "alice", provider: "basic"
    ))

    let names = (storage.cookies ?? []).map(\.name)
    #expect(names.contains(freshName))      // fresh cookie is now live
    #expect(!names.contains(staleName))     // prior cookies flushed
  }

  @Test func savingTokenThenCookieReplacesSession() throws {
    let kc = KeychainClient.inMemory()
    try kc.saveToken("tok")
    #expect(kc.loadSession(HTTPCookieStorage()) == .token("tok"))
    let cookieSession = CookieSession(cookies: [], username: "bob", provider: "basic")
    try kc.saveSession(.cookie(cookieSession))
    #expect(kc.loadSession(HTTPCookieStorage()) == .cookie(cookieSession))
    #expect(kc.loadToken() == nil)
  }
}
