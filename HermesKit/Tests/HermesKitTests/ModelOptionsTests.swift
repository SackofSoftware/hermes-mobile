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

  @Test func reasoningLadderIsTheFullUpstreamScale() {
    #expect(ModelOptions.reasoningEfforts == [
      "none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra",
    ])
    #expect(ModelOptions.reasoningEfforts.first == "none")
    #expect(ModelOptions.reasoningEfforts.last == "ultra")
  }

  @Test func offeredEffortsReturnsFullLadderWhenExtendedSupported() {
    #expect(ModelOptions.offeredEfforts(extendedSupported: true) == ModelOptions.reasoningEfforts)
  }

  @Test func offeredEffortsDropsExactlyMaxAndUltraWhenLatched() {
    let offered = ModelOptions.offeredEfforts(extendedSupported: false)
    #expect(offered == ["none", "minimal", "low", "medium", "high", "xhigh"])
    // Only the extended levels are removed; the rest keeps ladder order.
    #expect(Set(ModelOptions.reasoningEfforts).subtracting(offered) == ModelOptions.extendedReasoningEfforts)
    #expect(offered == ModelOptions.reasoningEfforts.filter { offered.contains($0) })
  }

  @Test func extendedEffortsAreASubsetOfTheLadder() {
    #expect(ModelOptions.extendedReasoningEfforts.isSubset(of: Set(ModelOptions.reasoningEfforts)))
    #expect(ModelOptions.extendedReasoningEfforts == ["max", "ultra"])
  }

  // MARK: filteredProviders(matching:)

  private let searchableOptions = ModelOptions(providers: [
    .init(name: "Anthropic", slug: "anthropic", models: ["claude-opus-4-8", "claude-haiku-4-5"], authenticated: true),
    .init(name: "DeepSeek", slug: "deepseek", models: ["deepseek-v4-flash", "deepseek-reasoner"], authenticated: true),
    .init(name: "OpenAI", slug: "openai", models: ["gpt-5.6", "gpt-5.6-mini"], authenticated: true),
    .init(name: "Groq", slug: "groq", models: [], authenticated: false, warning: "paste GROQ_API_KEY to activate"),
  ])

  @Test func emptyQueryReturnsTheFullOrderedList() {
    #expect(searchableOptions.filteredProviders(matching: "").map(\.name) ==
      searchableOptions.orderedProviders.map(\.name))
    #expect(searchableOptions.filteredProviders(matching: "   ").map(\.name) ==
      searchableOptions.orderedProviders.map(\.name))
  }

  @Test func modelNameSubstringMatchKeepsOnlyMatchingModelsWithinTheirProvider() {
    // "dee" matches both DeepSeek models but no other provider's models.
    let result = searchableOptions.filteredProviders(matching: "dee")
    #expect(result.map(\.name) == ["DeepSeek"])
    #expect(result.first?.models == ["deepseek-v4-flash", "deepseek-reasoner"])
  }

  @Test func modelNameMatchDropsNonMatchingModelsButKeepsTheProviderSection() {
    let result = searchableOptions.filteredProviders(matching: "reasoner")
    #expect(result.map(\.name) == ["DeepSeek"])
    #expect(result.first?.models == ["deepseek-reasoner"])
  }

  @Test func providerNameMatchKeepsAllOfThatProvidersModels() {
    // "openai" matches the provider name, so every OpenAI model survives even though
    // none of them contain the substring.
    let result = searchableOptions.filteredProviders(matching: "openai")
    #expect(result.map(\.name) == ["OpenAI"])
    #expect(result.first?.models == ["gpt-5.6", "gpt-5.6-mini"])
  }

  @Test func unconfiguredProviderNeverSurfacesEvenByName() {
    // This fork lists configured providers only (set new ones up in Settings › Providers),
    // so an unconfigured provider stays out of the picker even on a provider-name match.
    let result = searchableOptions.filteredProviders(matching: "groq")
    #expect(result.isEmpty)
  }

  @Test func matchingIsCaseAndDiacriticInsensitive() {
    #expect(searchableOptions.filteredProviders(matching: "DEEP").map(\.name) == ["DeepSeek"])
    #expect(searchableOptions.filteredProviders(matching: "claude").map(\.name) == ["Anthropic"])
  }

  @Test func noMatchReturnsAnEmptyList() {
    #expect(searchableOptions.filteredProviders(matching: "zzz").isEmpty)
  }

  @Test func filteringPreservesProviderOrdering() {
    // "a" matches Anthropic and OpenAI by provider name and DeepSeek by model name; all
    // three configured providers survive in their original (configured-first) order.
    let result = searchableOptions.filteredProviders(matching: "a")
    #expect(result.map(\.name) == ["Anthropic", "DeepSeek", "OpenAI"])
  }
}
