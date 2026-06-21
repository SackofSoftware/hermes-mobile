import Foundation

/// One auth provider advertised by `GET /api/auth/providers`
/// (`[{name, display_name, supports_password}]`). `name` is the wire identifier passed to
/// `POST /auth/password-login` (usually `"basic"`); `displayName` is for the UI.
public struct AuthProvider: Equatable, Sendable, Decodable {
  public var name: String
  public var displayName: String
  public var supportsPassword: Bool

  public init(name: String, displayName: String, supportsPassword: Bool) {
    self.name = name
    self.displayName = displayName
    self.supportsPassword = supportsPassword
  }

  enum CodingKeys: String, CodingKey {
    case name
    case displayName = "display_name"
    case supportsPassword = "supports_password"
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    name = try c.decode(String.self, forKey: .name)
    // Lenient: fall back to the wire name when the server omits a display name.
    displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? name
    supportsPassword = try c.decodeIfPresent(Bool.self, forKey: .supportsPassword) ?? false
  }
}

/// What auth UI the onboarding screen should offer for a given server. Derived purely from
/// the capability probe (`/api/status` + `/api/auth/providers`) so it stays unit-testable
/// and free of regime checks scattered across the reducer.
///
/// - `.tokenOnly` — old/loopback servers (`auth_required` absent/`false`) or no
///   password-capable provider: only the static-token path is offered.
/// - `.passwordAvailable` — gated server with a password-capable provider: offer the
///   password form (preferred when both password and OAuth exist).
/// - `.oauthOnly` — gated server whose providers are all OAuth (none support password).
///   OAuth itself is out of scope (#19); modeled here so the UI can disable password
///   honestly rather than guess.
public enum ServerAuthCapability: Equatable, Sendable {
  case tokenOnly
  case passwordAvailable(provider: String, displayName: String)
  case oauthOnly(providers: [AuthProvider])

  /// Pure mapper. `providers` is the decoded `/api/auth/providers` payload, or `nil` when
  /// that endpoint 404s / is unreachable (older servers) — treated as no providers.
  public init(from status: ServerStatus, providers: [AuthProvider]?) {
    // Absent/false `auth_required` → today's token-only behaviour (loopback/`--insecure`).
    guard status.authRequired == true else {
      self = .tokenOnly
      return
    }
    let providers = providers ?? []
    // Mixed → password preferred: pick the first password-capable provider.
    if let password = providers.first(where: \.supportsPassword) {
      self = .passwordAvailable(provider: password.name, displayName: password.displayName)
    } else if !providers.isEmpty {
      // Gated but no password-capable provider → OAuth-only (parked, #19).
      self = .oauthOnly(providers: providers)
    } else {
      // Gated yet no providers advertised (older server / providers 404): fall back to
      // the token path so the user still has a way in.
      self = .tokenOnly
    }
  }
}
