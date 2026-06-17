import Foundation

/// A Hermes profile (an independent environment: separate config, skills, SOUL.md, and
/// its own sessions). Decoded from `ProfileInfo` in `GET /api/profiles`
/// (`{ profiles: [...] }`). The default profile (`isDefault`) can't be renamed/deleted.
///
/// Decodes leniently — missing optional fields (`model`/`provider`) and absent
/// `skill_count`/`has_env` never crash. `Identifiable` by `name`.
public struct Profile: Equatable, Sendable, Identifiable, Decodable {
  /// Profile name — the identifier used in `?profile=` scoping. Also the `id`.
  public var name: String
  /// Whether this is the default/primary profile (can't be renamed/deleted).
  public var isDefault: Bool
  public var model: String?
  public var provider: String?
  /// Number of skills configured for this profile.
  public var skillCount: Int
  /// Whether the profile has an `.env` (env overrides) configured.
  public var hasEnv: Bool

  public var id: String { name }

  enum CodingKeys: String, CodingKey {
    case name
    case isDefault = "is_default"
    case model
    case provider
    case skillCount = "skill_count"
    case hasEnv = "has_env"
  }

  public init(
    name: String,
    isDefault: Bool = false,
    model: String? = nil,
    provider: String? = nil,
    skillCount: Int = 0,
    hasEnv: Bool = false
  ) {
    self.name = name
    self.isDefault = isDefault
    self.model = model
    self.provider = provider
    self.skillCount = skillCount
    self.hasEnv = hasEnv
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    name = (try? c.decode(String.self, forKey: .name)) ?? ""
    isDefault = (try? c.decodeIfPresent(Bool.self, forKey: .isDefault)) ?? false
    model = try? c.decodeIfPresent(String.self, forKey: .model)
    provider = try? c.decodeIfPresent(String.self, forKey: .provider)
    skillCount = (try? c.decodeIfPresent(Int.self, forKey: .skillCount)) ?? 0
    hasEnv = (try? c.decodeIfPresent(Bool.self, forKey: .hasEnv)) ?? false
  }
}
