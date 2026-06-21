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
}
