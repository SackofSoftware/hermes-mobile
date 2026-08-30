import Testing
@testable import HermesMobile

@Suite struct ProviderIconMappingTests {
  private func asset(_ provider: String, _ model: String? = nil) -> String? {
    ProviderIconView.assetName(provider: provider, model: model)
  }

  @Test func mapsTheFourFormerlyMissingBrands() {
    #expect(asset("anthropic", "claude-haiku-4-5") == "claude")
    #expect(asset("anthropic") == "anthropic")
    #expect(asset("xai", "grok-4") == "grok")
    #expect(asset("moonshot", "kimi-k2") == "kimi")
  }

  @Test func codexAndOpenAIResolveToOpenAI() {
    #expect(asset("openai-codex", "gpt-5.5") == "openai")
    #expect(asset("openai", "o3-mini") == "openai")
  }

  @Test func aggregatorShowsTheUnderLYINGModelNotOpenRouter() {
    // The whole point: openrouter/<vendor>/<model> should show the VENDOR's mark.
    #expect(asset("openrouter", "google/gemini-2.5-flash-lite") == "gemini")
    #expect(asset("openrouter", "deepseek/deepseek-r1") == "deepseek")
    #expect(asset("openrouter", "meta-llama/llama-3.3-70b") == "llama")
    #expect(asset("openrouter", "anthropic/claude-sonnet-4") == "claude")
  }

  @Test func openRouterOwnMarkOnlyWhenNothingElseMatches() {
    #expect(asset("openrouter", "some-unknown-model") == "openrouter")
  }

  @Test func monochromeMarksAreTemplatesSoTheySurviveDarkMode() {
    #expect(ProviderIconView.templateAssets.contains("anthropic"))
    #expect(ProviderIconView.templateAssets.contains("grok"))
    // Brand-coloured marks must NOT be tinted.
    #expect(!ProviderIconView.templateAssets.contains("claude"))
    #expect(!ProviderIconView.templateAssets.contains("openrouter"))
  }

  @Test func gemmaIsNotSwallowedByGemini() {
    #expect(asset("openrouter", "google/gemma-3-27b") == "gemma")
  }
}
