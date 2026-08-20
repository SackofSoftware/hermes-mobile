import Foundation
import Testing

@testable import HermesKit

struct ModelOptionsTests {
  @Test func decodesProvidersModelsAndCapabilities() throws {
    let json = #"""
    {
      "model": "claude-opus-4-8",
      "provider": "anthropic",
      "providers": [
        {
          "name": "Anthropic", "slug": "anthropic", "authenticated": true,
          "models": ["claude-opus-4-8", "claude-haiku-4-5"],
          "capabilities": {
            "claude-opus-4-8": {"fast": false, "reasoning": true},
            "claude-haiku-4-5": {"fast": true, "reasoning": false}
          }
        },
        { "name": "OpenAI", "slug": "openai", "models": [], "authenticated": false, "warning": "paste OPENAI_API_KEY to activate" }
      ]
    }
    """#
    let options = try JSONDecoder().decode(ModelOptions.self, from: Data(json.utf8))

    #expect(options.currentModel == "claude-opus-4-8")
    #expect(options.providers.count == 2)
    // Only CONFIGURED providers are offered: the picker lists what you can actually
    // pick, not a catalog of things to go set up. The unconfigured provider is still
    // decoded (below) — it is simply not shown.
    #expect(options.orderedProviders.map(\.name) == ["Anthropic"])
    #expect(options.orderedProviders.map(\.isConfigured) == [true])
    #expect(options.providers.first(where: { $0.name == "OpenAI" })?.warning == "paste OPENAI_API_KEY to activate")
  }

  @Test func orderedProvidersKeepsOnlyConfigured() {
    let options = ModelOptions(providers: [
      // Dropped: authenticated but with no models is not usable...
      .init(name: "Unconfigured", slug: "u", models: [], authenticated: false, warning: "configure me"),
      .init(name: "Configured", slug: "c", models: ["m"], authenticated: true),
      // ...and neither is one with no models and no hint.
      .init(name: "Empty", slug: "e", models: [], authenticated: false),
      // Authenticated but model-less: still unusable, so still dropped.
      .init(name: "NoModels", slug: "n", models: [], authenticated: true),
    ])
    #expect(options.orderedProviders.map(\.name) == ["Configured"])
  }

  @Test func supportsReasoningReflectsPerModelCapability() {
    let options = ModelOptions(
      providers: [.init(
        name: "Anthropic", slug: "anthropic",
        models: ["opus", "haiku"], authenticated: true,
        capabilities: ["opus": .init(reasoning: true), "haiku": .init(reasoning: false)]
      )],
      currentModel: "opus"
    )
    #expect(options.supportsReasoning("opus") == true)
    #expect(options.supportsReasoning("haiku") == false)
    // Unknown model / nil → default true (don't hide the control on unknowns).
    #expect(options.supportsReasoning("mystery") == true)
    #expect(options.supportsReasoning(nil) == true)
  }
}
