import Foundation

/// How the app authenticates against a Hermes server. The server has two distinct auth
/// **regimes**, modeled here so downstream clients adapt transport without scattering
/// regime checks:
///
/// - `.token` — loopback/`--insecure`, `auth_required=false`. REST uses the
///   `X-Hermes-Session-Token` header; WS uses `…/api/ws?token=<token>`; never expires.
/// - `.cookie` — gated (password/OAuth), `auth_required=true`. REST uses session cookies
///   (HttpOnly, rotating); WS requires a single-use `?ticket=` minted per connect.
public enum AuthSession: Equatable, Sendable, Codable {
  case token(String)
  case cookie(CookieSession)

  /// The bearer token for `.token` sessions; `nil` for `.cookie` (which authenticates via
  /// the cookie jar). A convenience so existing token-mode call sites stay byte-identical.
  public var token: String? {
    switch self {
    case let .token(value): value
    case .cookie: nil
    }
  }

  /// The session's cookies (empty in `.token` mode). Normally the transports read the shared
  /// jar instead — this is for the one call that must authenticate **after** the jar has been
  /// flushed (`unregisterPush` on logout).
  public var cookies: [SerializedCookie] {
    switch self {
    case .token: []
    case let .cookie(session): session.cookies
    }
  }

  /// The same session with its cookies replaced — used to refresh a stored (login-vintage)
  /// cookie session from a snapshot of the live jar. `.token` sessions are returned unchanged.
  public func replacingCookies(_ cookies: [SerializedCookie]) -> AuthSession {
    guard case var .cookie(session) = self else { return self }
    session.cookies = cookies
    return .cookie(session)
  }
}

/// A captured cookie-based session for the gated auth regime. Carries enough to rehydrate
/// the cookie jar (`HTTPCookieStorage`) on a fresh launch plus the identity for re-auth
/// routing.
public struct CookieSession: Equatable, Sendable, Codable {
  public var cookies: [SerializedCookie]
  public var username: String
  public var provider: String

  public init(cookies: [SerializedCookie], username: String, provider: String) {
    self.cookies = cookies
    self.username = username
    self.provider = provider
  }
}

/// A `Codable` snapshot of an `HTTPCookie`. Carries the fields needed to round-trip the
/// cookie back into `HTTPCookieStorage` (`HttpOnly` only blocks JS, not native clients).
public struct SerializedCookie: Equatable, Sendable, Codable {
  public var name: String
  public var value: String
  public var domain: String
  public var path: String
  /// Absolute expiry (seconds since 1970), `nil` for a session cookie.
  public var expiresAt: Double?
  public var isSecure: Bool
  public var isHTTPOnly: Bool

  public init(
    name: String,
    value: String,
    domain: String,
    path: String,
    expiresAt: Double? = nil,
    isSecure: Bool = false,
    isHTTPOnly: Bool = false
  ) {
    self.name = name
    self.value = value
    self.domain = domain
    self.path = path
    self.expiresAt = expiresAt
    self.isSecure = isSecure
    self.isHTTPOnly = isHTTPOnly
  }
}

public extension SerializedCookie {
  /// Snapshot an `HTTPCookie` for persistence.
  init(_ cookie: HTTPCookie) {
    self.init(
      name: cookie.name,
      value: cookie.value,
      domain: cookie.domain,
      path: cookie.path,
      expiresAt: cookie.expiresDate?.timeIntervalSince1970,
      isSecure: cookie.isSecure,
      isHTTPOnly: cookie.isHTTPOnly
    )
  }

  /// Rehydrate into an `HTTPCookie` for `HTTPCookieStorage`.
  var httpCookie: HTTPCookie? {
    var properties: [HTTPCookiePropertyKey: Any] = [
      .name: name,
      .value: value,
      .domain: domain,
      .path: path,
    ]
    if let expiresAt { properties[.expires] = Date(timeIntervalSince1970: expiresAt) }
    if isSecure { properties[.secure] = "TRUE" }
    // `HTTPOnly` has no public property key; native clients ignore it anyway.
    return HTTPCookie(properties: properties)
  }

  /// Would `URLSession` have attached this cookie to a request for `url`?
  ///
  /// This exists for the ONE call that authenticates from an explicit `Cookie` header instead of
  /// the shared jar (`HermesRESTClient`'s push unregister — the jar is flushed by the logout that
  /// triggers it). An explicit header bypasses every check `HTTPCookieStorage` would have made,
  /// and the snapshot it is built from is the WHOLE jar, so without this predicate a foreign or
  /// out-of-scope cookie would be disclosed to that endpoint. The rules are RFC 6265's, matching
  /// how Foundation normalises what it stores: a cookie with an explicit `Domain` is kept with a
  /// leading dot (and matches subdomains), one without is host-only (exact match); path is a
  /// prefix match on a `/` boundary; `Secure` requires https; an expired cookie is never sent.
  internal func applies(to url: URL, now: Date) -> Bool {
    guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
    guard Self.domainMatches(domain, host: host) else { return false }
    guard Self.pathMatches(path, requestPath: url.path.isEmpty ? "/" : url.path) else {
      return false
    }
    if isSecure, url.scheme?.lowercased() != "https" { return false }
    if let expiresAt, expiresAt <= now.timeIntervalSince1970 { return false }
    return true
  }

  /// Host-only (no leading dot) → exact match. Domain cookie (leading dot) → the host must be
  /// the domain itself or a subdomain of it, so `evilexample.com` never matches `.example.com`.
  internal static func domainMatches(_ domain: String, host: String) -> Bool {
    let domain = domain.lowercased()
    guard domain.hasPrefix(".") else { return !domain.isEmpty && domain == host }
    let bare = String(domain.dropFirst())
    guard !bare.isEmpty else { return false }
    return host == bare || host.hasSuffix(".\(bare)")
  }

  /// RFC 6265 path-match: equal, or a prefix ending at a `/` boundary. An empty cookie path is
  /// treated as `/` (what Foundation stores when `Path` is absent).
  internal static func pathMatches(_ cookiePath: String, requestPath: String) -> Bool {
    let cookiePath = cookiePath.isEmpty ? "/" : cookiePath
    if cookiePath == requestPath { return true }
    guard requestPath.hasPrefix(cookiePath) else { return false }
    if cookiePath.hasSuffix("/") { return true }
    return requestPath.dropFirst(cookiePath.count).hasPrefix("/")
  }
}
