import Testing
@testable import HermesKit

@Suite struct ModelDisplayTests {
  @Test func prettifiesTheModelsThisAgentActuallyUses() {
    #expect(ModelDisplay.prettyName("gpt-5.6-terra") == "ChatGPT 5.6 Terra")
    #expect(ModelDisplay.prettyName("gpt-5.5") == "ChatGPT 5.5")
    // Alibaba brands it "Qwen3.8", but spacing the version keeps every family
    // consistent ("ChatGPT 5.6 Terra", "Gemini 2.5 Flash Lite") and stays readable.
    #expect(ModelDisplay.prettyName("qwen/qwen3.8-flash") == "Qwen 3.8 Flash")
    #expect(ModelDisplay.prettyName("google/gemini-2.5-flash-lite") == "Gemini 2.5 Flash Lite")
  }

  @Test func hyphenatedVersionsBecomeDecimals() {
    // "Claude Haiku 4 5" would read as a typo.
    #expect(ModelDisplay.prettyName("claude-haiku-4-5") == "Claude Haiku 4.5")
  }

  @Test func dropsAggregatorRoutingPrefix() {
    // openrouter/<vendor>/<model> — the path is routing detail, not identity.
    #expect(ModelDisplay.prettyName("openrouter/deepseek/deepseek-r1") == "DeepSeek R1")
  }

  @Test func unknownModelsAreTitleCasedNotMangled() {
    #expect(ModelDisplay.prettyName("brand-new-model") == "Brand New Model")
  }

  @Test func parameterSizesKeepTheirShape() {
    #expect(ModelDisplay.prettyName("meta-llama/llama-3.3-70b") == "Llama 3.3 70b")
  }

  @Test func compactNameTruncatesOnlyWhenNeeded() {
    #expect(ModelDisplay.compactName("gpt-5.6-terra") == "ChatGPT 5.6 Terra")
    let long = ModelDisplay.compactName("google/gemini-2.5-flash-lite", limit: 12)
    #expect(long.count == 12)
    #expect(long.hasSuffix("…"))
  }
}

@Suite struct ChipNameTests {
  @Test func dropsBrandWordTheMarkAlreadyShows() {
    #expect(ModelDisplay.chipName("gpt-5.6-terra") == "5.6 Terra")
    #expect(ModelDisplay.chipName("claude-opus-4-8") == "Opus 4.8")
    #expect(ModelDisplay.chipName("qwen/qwen3.8-flash") == "3.8 Flash")
  }

  @Test func unknownFamiliesKeepTheirFullName() {
    // No mark to lean on → the text must still identify the model.
    #expect(ModelDisplay.chipName("brand-new-model") == "Brand New Model")
  }
}

@Suite struct ContextLabelTests {
  @Test func formatsTokenCountsAtTwoFigures() {
    #expect(ModelDisplay.contextLabel(1_050_000) == "1.1M ctx")
    #expect(ModelDisplay.contextLabel(1_000_000) == "1M ctx")
    #expect(ModelDisplay.contextLabel(400_000) == "400K ctx")
    #expect(ModelDisplay.contextLabel(200_000) == "200K ctx")
    #expect(ModelDisplay.contextLabel(32_768) == "33K ctx")
    #expect(ModelDisplay.contextLabel(0) == "")
  }
}
