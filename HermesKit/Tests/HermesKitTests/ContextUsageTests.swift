import Foundation
import Testing

@testable import HermesKit

/// Pure display-derivation tests for the context-window gauge: token formatting,
/// the gauge label, fill fraction, and the severity thresholds mirroring the Hermes
/// TUI status bar (`<50` normal, `≥50` moderate, `>80` high, `≥95` critical).
@Suite struct ContextUsageTests {

  // MARK: formatTokens

  @Test func formatTokensBelowOneThousand() {
    #expect(Usage.formatTokens(0) == "0")
    #expect(Usage.formatTokens(1) == "1")
    #expect(Usage.formatTokens(999) == "999")
  }

  @Test func formatTokensThousands() {
    #expect(Usage.formatTokens(1_000) == "1k")
    #expect(Usage.formatTokens(1_250) == "1k")        // rounds down to nearest whole k
    #expect(Usage.formatTokens(1_500) == "2k")        // rounds up to nearest whole k
    #expect(Usage.formatTokens(125_000) == "125k")
    #expect(Usage.formatTokens(999_000) == "999k")
  }

  @Test func formatTokensMillions() {
    #expect(Usage.formatTokens(1_000_000) == "1M")
    #expect(Usage.formatTokens(1_500_000) == "1.5M")
    #expect(Usage.formatTokens(2_000_000) == "2M")
  }

  @Test func formatTokensExactThresholds() {
    #expect(Usage.formatTokens(1_000) == "1k")
    #expect(Usage.formatTokens(1_000_000) == "1M")
  }

  @Test func formatTokensRollsOverToMillion() {
    // Values that round up to a full 1000k roll over to "1M" rather than "1000k".
    #expect(Usage.formatTokens(999_000) == "999k")
    #expect(Usage.formatTokens(999_500) == "1M")
    #expect(Usage.formatTokens(999_999) == "1M")
    #expect(Usage.formatTokens(1_000_000) == "1M")
  }

  @Test func formatTokensNegativeClampsToZero() {
    #expect(Usage.formatTokens(-5) == "0")
  }

  // MARK: tokenLabel

  @Test func tokenLabelMaxKnown() {
    let u = Usage(contextUsed: 125_000, contextMax: 200_000)
    #expect(u.tokenLabel == "125k/200k")
  }

  @Test func tokenLabelUsedOnly() {
    let u = Usage(contextUsed: 125_000)
    #expect(u.tokenLabel == "125k tok")
  }

  @Test func tokenLabelTotalOnly() {
    // No contextUsed, but total present → falls back to total.
    let u = Usage(total: 42_000)
    #expect(u.tokenLabel == "42k tok")
  }

  @Test func tokenLabelEmpty() {
    #expect(Usage().tokenLabel == nil)
    #expect(Usage(contextUsed: 0).tokenLabel == nil)
  }

  @Test func tokenLabelMaxKnownWithoutUsed() {
    // Max known but no used/total → render 0 used against the max, never nil.
    let u = Usage(contextMax: 200_000)
    #expect(u.tokenLabel == "0/200k")
  }

  // MARK: contextFraction

  @Test func contextFractionFromPercent() {
    #expect(Usage(contextPercent: 62).contextFraction == 0.62)
  }

  @Test func contextFractionPercentClamped() {
    #expect(Usage(contextPercent: 150).contextFraction == 1.0)
    #expect(Usage(contextPercent: -10).contextFraction == 0.0)
  }

  @Test func contextFractionFromRatioWhenNoPercent() {
    let u = Usage(contextUsed: 50_000, contextMax: 200_000)
    #expect(u.contextFraction == 0.25)
  }

  @Test func contextFractionRatioClamped() {
    let u = Usage(contextUsed: 300_000, contextMax: 200_000)
    #expect(u.contextFraction == 1.0)
  }

  @Test func contextFractionNilWhenMaxUnknown() {
    #expect(Usage(contextUsed: 50_000).contextFraction == nil)
    #expect(Usage().contextFraction == nil)
  }

  @Test func contextFractionPrefersPercentOverRatio() {
    let u = Usage(contextUsed: 50_000, contextMax: 200_000, contextPercent: 90)
    #expect(u.contextFraction == 0.90)
  }

  // MARK: contextPercentLabel — ring center

  @Test func contextPercentLabelFromPercent() {
    #expect(Usage(contextPercent: 69).contextPercentLabel == "69%")
    #expect(Usage(contextPercent: 0).contextPercentLabel == "0%")
    #expect(Usage(contextPercent: 100).contextPercentLabel == "100%")
  }

  @Test func contextPercentLabelFromRatioRounds() {
    // 124k/200k = 62%, rounded from the fraction when no explicit percent is present.
    #expect(Usage(contextUsed: 124_000, contextMax: 200_000).contextPercentLabel == "62%")
  }

  @Test func contextPercentLabelNilWhenMaxUnknown() {
    #expect(Usage(contextUsed: 125_000).contextPercentLabel == nil)
    #expect(Usage().contextPercentLabel == nil)
  }

  // MARK: severity — boundary percents

  @Test(arguments: [
    (0, ContextSeverity.normal),
    (49, .normal),
    (50, .moderate),
    (79, .moderate),
    (80, .moderate),
    (81, .high),
    (94, .high),
    (95, .critical),
    (100, .critical),
    (150, .critical),
  ])
  func severityFromPercent(percent: Int, expected: ContextSeverity) {
    #expect(Usage(contextPercent: percent).severity == expected)
  }

  @Test func severityInitDirect() {
    #expect(ContextSeverity(percent: 49.9) == .normal)
    #expect(ContextSeverity(percent: 50) == .moderate)
    #expect(ContextSeverity(percent: 80) == .moderate)
    #expect(ContextSeverity(percent: 80.1) == .high)
    #expect(ContextSeverity(percent: 94.9) == .high)
    #expect(ContextSeverity(percent: 95) == .critical)
  }

  @Test func severityFallsBackToFractionWhenNoPercent() {
    // 90% via ratio, no explicit percent.
    let u = Usage(contextUsed: 180_000, contextMax: 200_000)
    #expect(u.severity == .high)
  }

  @Test func severityDefaultsToNormalWhenUnknown() {
    #expect(Usage().severity == .normal)
  }

  // MARK: decoding the new compressions field

  @Test func decodesCompressionsField() throws {
    let json = #"{"context_used":125000,"context_max":200000,"context_percent":62,"compressions":3}"#
    let u = try JSONDecoder().decode(Usage.self, from: Data(json.utf8))
    #expect(u.compressions == 3)
    #expect(u.contextPercent == 62)
  }

  @Test func compressionsAbsentDecodesNil() throws {
    let json = #"{"context_used":1000}"#
    let u = try JSONDecoder().decode(Usage.self, from: Data(json.utf8))
    #expect(u.compressions == nil)
  }
}
