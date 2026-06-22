import Foundation
import Testing

@testable import HermesKit

struct AuthSessionTests {
  // MARK: AuthSession Codable round-trip

  @Test func tokenSessionRoundTrips() throws {
    let session = AuthSession.token("abc123")
    let data = try JSONEncoder().encode(session)
    let decoded = try JSONDecoder().decode(AuthSession.self, from: data)
    #expect(decoded == session)
    #expect(decoded.token == "abc123")
  }

  @Test func cookieSessionRoundTrips() throws {
    let session = AuthSession.cookie(
      CookieSession(
        cookies: [
          SerializedCookie(
            name: "hermes_session_at",
            value: "at-value",
            domain: "mac.tailnet",
            path: "/",
            expiresAt: 1_800_000_000,
            isSecure: true,
            isHTTPOnly: true
          ),
          SerializedCookie(
            name: "hermes_session_rt",
            value: "rt-value",
            domain: "mac.tailnet",
            path: "/"
          ),
        ],
        username: "alice",
        provider: "basic"
      )
    )
    let data = try JSONEncoder().encode(session)
    let decoded = try JSONDecoder().decode(AuthSession.self, from: data)
    #expect(decoded == session)
    #expect(decoded.token == nil)
  }

  // MARK: SerializedCookie <-> HTTPCookie bridging

  @Test func serializedCookieRehydratesIntoHTTPCookie() throws {
    let serialized = SerializedCookie(
      name: "hermes_session_at",
      value: "at-value",
      domain: "mac.tailnet",
      path: "/api",
      expiresAt: 1_800_000_000,
      isSecure: true
    )
    let cookie = try #require(serialized.httpCookie)
    #expect(cookie.name == "hermes_session_at")
    #expect(cookie.value == "at-value")
    #expect(cookie.domain == "mac.tailnet")
    #expect(cookie.path == "/api")
    #expect(cookie.isSecure)
    #expect(cookie.expiresDate == Date(timeIntervalSince1970: 1_800_000_000))
  }

  @Test func httpCookieSnapshotRoundTrips() throws {
    let original = try #require(
      HTTPCookie(properties: [
        .name: "hermes_session_rt",
        .value: "rt-value",
        .domain: "mac.tailnet",
        .path: "/",
      ])
    )
    let serialized = SerializedCookie(original)
    #expect(serialized.name == "hermes_session_rt")
    #expect(serialized.value == "rt-value")
    #expect(serialized.domain == "mac.tailnet")
    #expect(serialized.path == "/")
    #expect(serialized.expiresAt == nil)
  }

  // MARK: ServerConnection convenience

  @Test func tokenConvenienceInitMatchesAuth() {
    let url = URL(string: "http://mac.tailnet:9119")!
    let convenience = ServerConnection(baseURL: url, token: "tok")
    let explicit = ServerConnection(baseURL: url, auth: .token("tok"))
    #expect(convenience == explicit)
    #expect(convenience.token == "tok")
  }

  @Test func cookieConnectionExposesNilToken() {
    let url = URL(string: "http://mac.tailnet:9119")!
    let conn = ServerConnection(
      baseURL: url,
      auth: .cookie(CookieSession(cookies: [], username: "alice", provider: "basic"))
    )
    #expect(conn.token == nil)
  }

  // MARK: ServerStatus new fields

  @Test func serverStatusDecodesAuthFieldsWhenPresent() throws {
    let json = """
    {
      "version": "1.2.3",
      "gateway_running": true,
      "auth_required": true,
      "auth_providers": ["basic", "google"]
    }
    """
    let status = try JSONDecoder().decode(ServerStatus.self, from: Data(json.utf8))
    #expect(status.authRequired == true)
    #expect(status.authProviders == ["basic", "google"])
  }

  @Test func serverStatusDecodesWhenAuthFieldsAbsent() throws {
    let json = """
    { "version": "1.2.3", "gateway_running": true }
    """
    let status = try JSONDecoder().decode(ServerStatus.self, from: Data(json.utf8))
    #expect(status.authRequired == nil)
    #expect(status.authProviders == nil)
    #expect(status.version == "1.2.3")
  }
}
