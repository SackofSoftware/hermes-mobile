import Foundation

/// Human-readable naming for model ids.
///
/// Agents identify models the way APIs do — `gpt-5.6-terra`, `claude-haiku-4-5`,
/// `openrouter/qwen/qwen3.8-flash`. Shown raw in the composer that reads like a config
/// value, not a choice you made. This turns them into the names people actually use.
///
/// Deliberately conservative: an id it doesn't recognise is title-cased rather than
/// mangled, so a new model released tomorrow still reads acceptably instead of wrongly.
public enum ModelDisplay {
  /// A display name for a model id, e.g. `gpt-5.6-terra` → "ChatGPT 5.6 Terra".
  ///
  /// Aggregator prefixes are dropped first (`openrouter/qwen/qwen3.8-flash` → the Qwen
  /// part), because the vendor path is routing detail, not identity.
  public static func prettyName(_ model: String) -> String {
    let id = model.split(separator: "/").last.map(String.init) ?? model
    let lower = id.lowercased()

    // Family prefix → the brand name people say out loud.
    let families: [(match: String, brand: String)] = [
      ("gpt-", "ChatGPT"),
      ("o3-", "OpenAI o3"),
      ("o4-", "OpenAI o4"),
      ("claude-", "Claude"),
      ("gemini-", "Gemini"),
      ("gemma-", "Gemma"),
      ("qwen", "Qwen"),
      ("deepseek-", "DeepSeek"),
      ("llama-", "Llama"),
      ("mistral-", "Mistral"),
      ("mixtral-", "Mixtral"),
      ("grok-", "Grok"),
      ("kimi-", "Kimi"),
      ("phi-", "Phi"),
      ("nemotron", "Nemotron"),
    ]

    for (match, brand) in families where lower.hasPrefix(match) {
      let rest = String(id.dropFirst(match.count))
      let tail = titleCase(rest)
      return tail.isEmpty ? brand : "\(brand) \(tail)"
    }

    // Unknown family: title-case the whole thing rather than guess a brand.
    return titleCase(id)
  }

  /// `5.6-terra` → "5.6 Terra"; `4-5` → "4.5"; `flash-lite` → "Flash Lite".
  ///
  /// The `4-5` → `4.5` rule matters for Anthropic ids (`claude-haiku-4-5`), where the
  /// hyphen is a version separator, not a word break — "Claude Haiku 4 5" reads as a typo.
  private static func titleCase(_ raw: String) -> String {
    let parts = raw.split(separator: "-").map(String.init).filter { !$0.isEmpty }
    guard !parts.isEmpty else { return "" }

    var out: [String] = []
    var index = 0
    while index < parts.count {
      let part = parts[index]
      // Join a bare number to a following bare number as a decimal version.
      if isNumeric(part), index + 1 < parts.count, isNumeric(parts[index + 1]) {
        out.append("\(part).\(parts[index + 1])")
        index += 2
        continue
      }
      out.append(capitalizeToken(part))
      index += 1
    }
    return out.joined(separator: " ")
  }

  private static func isNumeric(_ s: String) -> Bool {
    !s.isEmpty && s.allSatisfy(\.isNumber)
  }

  /// Version-ish tokens (`5.6`, `4b`, `70b`) keep their shape; words get capitalised.
  private static func capitalizeToken(_ token: String) -> String {
    if token.first?.isNumber == true { return token }
    guard let first = token.first else { return token }
    return String(first).uppercased() + token.dropFirst()
  }

  /// Short label for the composer chip, where horizontal space is scarce.
  /// Falls back to the full pretty name when it's already short.
  public static func compactName(_ model: String, limit: Int = 22) -> String {
    let pretty = prettyName(model)
    guard pretty.count > limit else { return pretty }
    return String(pretty.prefix(limit - 1)) + "…"
  }

  /// Label for the composer chip when the BRAND MARK is drawn beside it.
  ///
  /// With the OpenAI logo already in the chip, "ChatGPT 5.6 Terra" spends its scarce
  /// width saying the same thing twice — and got ellipsized into "ChatGPT 5…", the worst
  /// of both. The mark carries the brand; the text carries the version: "5.6 Terra".
  /// Unknown families keep their full name, since there's no mark to lean on.
  public static func chipName(_ model: String) -> String {
    let pretty = prettyName(model)
    let brands = [
      "ChatGPT ", "OpenAI o3 ", "OpenAI o4 ", "Claude ", "Gemini ", "Gemma ",
      "Qwen ", "DeepSeek ", "Llama ", "Mistral ", "Mixtral ", "Grok ", "Kimi ", "Phi ",
    ]
    for brand in brands where pretty.hasPrefix(brand) {
      let rest = String(pretty.dropFirst(brand.count))
      // "claude-opus-4-8" → "Opus 4.8" reads fine; a bare version like "5.5" still
      // reads fine NEXT TO THE MARK, which is the only place chipName is used.
      return rest.isEmpty ? pretty : rest
    }
    return pretty
  }

  /// "1050000 → 1M", "400000 → 400K", "200000 → 200K", "32768 → 33K".
  ///
  /// Token counts are marketing-round numbers; two significant figures is plenty and
  /// "1.05M" would imply a precision nobody uses when sizing a prompt.
  public static func contextLabel(_ tokens: Int) -> String {
    guard tokens > 0 else { return "" }
    if tokens >= 1_000_000 {
      let m = Double(tokens) / 1_000_000
      let rounded = (m * 10).rounded() / 10
      return rounded == rounded.rounded()
        ? "\(Int(rounded))M ctx"
        : String(format: "%.1fM ctx", rounded)
    }
    let k = Int((Double(tokens) / 1_000).rounded())
    return "\(k)K ctx"
  }
}
