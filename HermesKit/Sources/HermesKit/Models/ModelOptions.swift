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
    /// Hint for unconfigured providers, e.g. "paste ANTHROPIC_API_KEY to activate".
    public var warning: String?
    /// Per-model capabilities (`{model: {fast, reasoning}}`). Used to gate the reasoning
    /// control — a model that doesn't support reasoning hides the effort picker.
    public var capabilities: [String: Capability]

    public var id: String { slug ?? name }

    /// Configured + usable: authenticated with at least one model. Unconfigured providers
    /// come back authenticated=false with an empty model list and a `warning`.
    public var isConfigured: Bool { (authenticated ?? false) && !models.isEmpty }

    enum CodingKeys: String, CodingKey {
      case name, slug, models, authenticated, warning, capabilities
    }

    public init(
      name: String, slug: String? = nil, models: [String] = [],
      authenticated: Bool? = nil, warning: String? = nil, capabilities: [String: Capability] = [:]
    ) {
      self.name = name
      self.slug = slug
      self.models = models
      self.authenticated = authenticated
      self.warning = warning
      self.capabilities = capabilities
    }

    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      name = (try? c.decode(String.self, forKey: .name)) ?? ""
      slug = try c.decodeIfPresent(String.self, forKey: .slug)
      models = (try? c.decode([String].self, forKey: .models)) ?? []
      authenticated = try c.decodeIfPresent(Bool.self, forKey: .authenticated)
      warning = try c.decodeIfPresent(String.self, forKey: .warning)
      capabilities = (try? c.decode([String: Capability].self, forKey: .capabilities)) ?? [:]
    }
  }

  public struct Capability: Equatable, Sendable, Decodable {
    public var reasoning: Bool?
    public var fast: Bool?

    public init(reasoning: Bool? = nil, fast: Bool? = nil) {
      self.reasoning = reasoning
      self.fast = fast
    }
  }

  /// Providers ordered for the picker: configured (selectable) first in server order,
  /// then unconfigured ones (shown disabled, with a configure hint). Providers that are
  /// neither configured nor offer a hint are dropped.
  public var orderedProviders: [Provider] {
    let configured = providers.filter(\.isConfigured)
    let unconfigured = providers.filter { !$0.isConfigured && ($0.warning?.isEmpty == false) }
    return configured + unconfigured
  }

  /// Whether `model` supports reasoning, per the provider capabilities map. Defaults to
  /// `true` when the model isn't found or has no capability entry (matches the desktop's
  /// `caps?.reasoning ?? true`), so the effort control isn't hidden on unknown models.
  public func supportsReasoning(_ model: String?) -> Bool {
    guard let model else { return true }
    for provider in providers {
      if let capability = provider.capabilities[model] {
        return capability.reasoning ?? true
      }
    }
    return true
  }

  /// Valid reasoning-effort levels (verified: `hermes_constants.VALID_REASONING_EFFORTS`
  /// plus "none"). Sent via `config.set {key:"reasoning", value}`. The server accepts any
  /// level regardless of model; they only take effect on reasoning-capable models.
  public static let reasoningEfforts = ["none", "minimal", "low", "medium", "high", "xhigh"]
}
