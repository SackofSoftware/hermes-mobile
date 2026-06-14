import Foundation

/// Result of the `model.options` gateway call — the available providers/models plus the
/// currently-selected model. Decoded leniently (the live payload carries far more).
public struct ModelOptions: Equatable, Sendable, Decodable {
  public var providers: [Provider]
  /// Currently-selected model id.
  public var currentModel: String?

  enum CodingKeys: String, CodingKey {
    case providers
    case currentModel = "model"
  }

  public init(providers: [Provider] = [], currentModel: String? = nil) {
    self.providers = providers
    self.currentModel = currentModel
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    providers = (try? c.decode([Provider].self, forKey: .providers)) ?? []
    currentModel = try c.decodeIfPresent(String.self, forKey: .currentModel)
  }

  public struct Provider: Equatable, Sendable, Decodable, Identifiable {
    public var name: String
    public var slug: String?
    public var models: [String]
    public var authenticated: Bool?

    public var id: String { slug ?? name }

    enum CodingKeys: String, CodingKey { case name, slug, models, authenticated }

    public init(name: String, slug: String? = nil, models: [String] = [], authenticated: Bool? = nil) {
      self.name = name
      self.slug = slug
      self.models = models
      self.authenticated = authenticated
    }

    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      name = (try? c.decode(String.self, forKey: .name)) ?? ""
      slug = try c.decodeIfPresent(String.self, forKey: .slug)
      models = (try? c.decode([String].self, forKey: .models)) ?? []
      authenticated = try c.decodeIfPresent(Bool.self, forKey: .authenticated)
    }
  }

  /// Providers that have at least one model and are usable (authenticated, or unknown).
  public var usableProviders: [Provider] {
    providers.filter { !$0.models.isEmpty && ($0.authenticated ?? true) }
  }

  /// Valid reasoning-effort levels (verified: `hermes_constants.VALID_REASONING_EFFORTS`
  /// plus "none"). Sent via `config.set {key:"reasoning", value}`.
  public static let reasoningEfforts = ["none", "minimal", "low", "medium", "high", "xhigh"]
}
