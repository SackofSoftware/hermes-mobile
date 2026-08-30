import Foundation

/// Human-readable presentation for a tool activity row.
///
/// The agent names tools for itself, not for a reader: `browser_navigate`, `session_search`,
/// `skill_view`, `search_files`. Shown raw — and the row used to show BOTH a title and the
/// raw name underneath — a working turn reads like a stack trace. This maps each tool to a
/// plain-English verb and a matching glyph, so a glance down the transcript says what the
/// agent did rather than which function it called.
///
/// Unknown tools degrade gracefully: `some_new_tool` → "Some new tool", which is still
/// better than the bare identifier and never wrong.
public struct ToolDisplay: Equatable, Sendable {
  /// Plain-English verb phrase, e.g. "Ran command".
  public let verb: String
  /// SF Symbol for the row, chosen per tool family so the list is scannable by shape.
  public let symbol: String

  public init(verb: String, symbol: String) {
    self.verb = verb
    self.symbol = symbol
  }

  /// Verb + glyph for a raw tool name. Matching is on the normalized name, then on
  /// family prefixes, so provider-namespaced variants (`mcp__x__read_file`) still land
  /// somewhere sensible.
  public static func forTool(_ rawName: String) -> ToolDisplay {
    let name = normalize(rawName)

    if let exact = table[name] { return exact }

    // Family fallbacks — order matters, most specific first.
    if name.hasPrefix("browser") { return .init(verb: "Browsed", symbol: "globe") }
    if name.contains("search") { return .init(verb: "Searched", symbol: "magnifyingglass") }
    if name.contains("skill") { return .init(verb: "Used a skill", symbol: "wand.and.stars") }
    if name.contains("write") || name.contains("edit") {
      return .init(verb: "Edited a file", symbol: "square.and.pencil")
    }
    if name.contains("read") || name.contains("file") {
      return .init(verb: "Read a file", symbol: "doc.text")
    }
    if name.contains("memory") || name.contains("recall") {
      return .init(verb: "Recalled", symbol: "brain")
    }

    return .init(verb: humanize(name), symbol: "wrench.and.screwdriver")
  }

  // MARK: - Table

  /// Exact matches for the tools that actually show up in this agent's transcripts.
  private static let table: [String: ToolDisplay] = [
    "terminal": .init(verb: "Ran a command", symbol: "terminal"),
    "shell_exec": .init(verb: "Ran a command", symbol: "terminal"),
    "execute_code": .init(verb: "Ran code", symbol: "chevron.left.forwardslash.chevron.right"),
    "browser_navigate": .init(verb: "Opened a page", symbol: "globe"),
    "browser_click": .init(verb: "Clicked", symbol: "hand.tap"),
    "browser_console": .init(verb: "Checked the console", symbol: "terminal.fill"),
    "browser_back": .init(verb: "Went back", symbol: "arrow.uturn.backward"),
    "browser_snapshot": .init(verb: "Looked at the page", symbol: "globe"),
    "search_files": .init(verb: "Searched files", symbol: "doc.text.magnifyingglass"),
    "session_search": .init(verb: "Searched past chats", symbol: "clock.arrow.circlepath"),
    "web_search": .init(verb: "Searched the web", symbol: "magnifyingglass"),
    "read_file": .init(verb: "Read a file", symbol: "doc.text"),
    "write_file": .init(verb: "Wrote a file", symbol: "square.and.pencil"),
    "edit_file": .init(verb: "Edited a file", symbol: "square.and.pencil"),
    "list_files": .init(verb: "Listed files", symbol: "folder"),
    "skill_view": .init(verb: "Opened a skill", symbol: "wand.and.stars"),
    "skill_run": .init(verb: "Ran a skill", symbol: "wand.and.stars"),
    "send_message": .init(verb: "Sent a message", symbol: "paperplane"),
    "image_generate": .init(verb: "Made an image", symbol: "photo"),
  ]

  // MARK: - Helpers

  /// Lowercase, strip an MCP/provider namespace (`mcp__server__tool` → `tool`).
  private static func normalize(_ raw: String) -> String {
    let lower = raw.lowercased()
    guard let tail = lower.components(separatedBy: "__").last, !tail.isEmpty else { return lower }
    return tail
  }

  /// `some_new_tool` → "Some new tool".
  private static func humanize(_ name: String) -> String {
    let words = name.replacingOccurrences(of: "_", with: " ")
      .replacingOccurrences(of: "-", with: " ")
      .trimmingCharacters(in: .whitespaces)
    guard let first = words.first else { return name }
    return String(first).uppercased() + words.dropFirst()
  }

  /// The single line a row should show.
  ///
  /// The server's `title` is usually the tool's *object* — a path, a URL, a query, a skill
  /// name — so "Opened a page" + "example.com/thing" reads naturally as one line. When the
  /// title is missing, or is just the tool name again, the verb stands alone rather than
  /// repeating itself ("Ran a command · terminal" helps nobody).
  public static func headline(name: String, title: String?) -> String {
    let display = forTool(name)
    guard let object = title?.trimmingCharacters(in: .whitespacesAndNewlines), !object.isEmpty
    else { return display.verb }
    // A title equal to the raw name (the reducer's fallback) carries no information.
    if object.caseInsensitiveCompare(name) == .orderedSame { return display.verb }
    // A bare glob or wildcard is noise too — it's in the detail sheet if wanted.
    if object == "*" { return display.verb }
    return "\(display.verb) · \(shorten(object))"
  }

  /// Keep the object end-weighted: a long path or URL is most identifiable at its tail,
  /// so trim from the FRONT rather than truncating the useful part away.
  static func shorten(_ object: String, limit: Int = 48) -> String {
    let flat = object.replacingOccurrences(of: "\n", with: " ")
    guard flat.count > limit else { return flat }
    return "…" + String(flat.suffix(limit - 1))
  }
}
