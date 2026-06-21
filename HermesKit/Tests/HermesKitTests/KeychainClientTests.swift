import Foundation
import Testing

@testable import HermesKit

@Suite struct KeychainClientTests {
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
