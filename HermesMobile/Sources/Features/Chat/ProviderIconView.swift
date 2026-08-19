import HermesKit
import SwiftUI

/// A small brand mark for a model provider (or, for aggregators like OpenRouter, for the
/// *model* behind the row — `openrouter/google/gemini-2.5-flash` shows Gemini, not a
/// generic OpenRouter glyph, which is what you actually want to recognise at a glance).
///
/// Art is vector (SVG in the asset catalog with `preserves-vector-representation`), so it
/// stays crisp at any Dynamic Type size. Not every provider has a mark on hand —
/// Anthropic/Claude, Grok, Kimi and OpenRouter's own logo are missing — so anything
/// unresolved falls back to a neutral SF Symbol rather than showing a broken image.
struct ProviderIconView: View {
  /// Provider name or slug, e.g. "openai-codex", "openrouter", "anthropic".
  let provider: String
  /// Optional model id; for aggregator providers this is what actually identifies the brand.
  var model: String?
  /// Rendered edge length. Defaults to roughly a body-text cap height.
  var size: CGFloat = 18

  var body: some View {
    Group {
      if let asset = Self.assetName(provider: provider, model: model) {
        Image(asset)
          .resizable()
          .aspectRatio(contentMode: .fit)
      } else {
        // Neutral stand-in: keeps rows visually aligned when a brand mark is missing.
        Image(systemName: "cpu")
          .resizable()
          .aspectRatio(contentMode: .fit)
          .foregroundStyle(.secondary)
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true) // the row's text already names the provider/model
  }

  /// Resolve an asset-catalog name from a provider slug and/or model id.
  ///
  /// Matching is substring-based on a lowercased haystack of both fields because ids
  /// arrive in many shapes: `openrouter/meta-llama/llama-3.3-70b`, `google/gemini-2.5`,
  /// `gpt-5.5`, `qwen2.5-coder`. Order matters — the most specific brands are checked
  /// first so `gemma` isn't swallowed by `gemini`, and OpenAI is checked on explicit
  /// markers (`gpt`, `codex`, `o3`) rather than a bare "open", which `openrouter` shares.
  static func assetName(provider: String, model: String?) -> String? {
    let hay = "\(provider) \(model ?? "")".lowercased()

    // Brand-specific first.
    if hay.contains("deepseek") { return "deepseek" }
    if hay.contains("gemma") { return "gemma" }
    if hay.contains("gemini") || hay.contains("google") { return "gemini" }
    if hay.contains("qwen") { return "qwen" }
    if hay.contains("llava") { return "llava" }
    if hay.contains("llama") { return "llama" }
    if hay.contains("mistral") || hay.contains("mixtral") { return "mistral" }
    if hay.contains("granite") { return "granite" }
    if hay.contains("moondream") { return "moondream" }
    if hay.contains("nemotron") { return "nemotron" }
    if hay.contains("glm") { return "glm" }
    if hay.contains("phi-") || hay.contains("phi3") || hay.contains("phi4") { return "phi" }
    // OpenAI last among matches, and only on unambiguous markers.
    if hay.contains("gpt") || hay.contains("codex") || hay.contains("openai")
      || hay.contains("o3-") || hay.contains("o4-") { return "openai" }
    return nil
  }
}

#Preview {
  VStack(alignment: .leading, spacing: 12) {
    ForEach(
      [
        ("openai-codex", "gpt-5.5"),
        ("openrouter", "google/gemini-2.5-flash-lite"),
        ("openrouter", "meta-llama/llama-3.3-70b"),
        ("openrouter", "deepseek/deepseek-r1"),
        ("anthropic", "claude-haiku-4-5"), // no mark on hand → SF Symbol fallback
      ],
      id: \.1
    ) { provider, model in
      HStack(spacing: 10) {
        ProviderIconView(provider: provider, model: model)
        Text(model).font(.callout)
      }
    }
  }
  .padding()
}
