import Foundation

// MARK: - SlashCommand

/// One entry in the slash-command catalog: a built-in (categorized) command or a
/// dynamic skill route (uncategorized, appended by the server after the built-ins).
public struct SlashCommand: Equatable, Sendable {
  /// Canonical name including the leading slash, e.g. "/compress".
  public let name: String
  public let description: String
  /// The server's category ("Session", …); nil for skill routes.
  public let category: String?
  /// True for dynamic skill routes — entries present in `pairs` but in no category.
  public let isSkill: Bool

  public init(name: String, description: String, category: String? = nil, isSkill: Bool = false) {
    self.name = name
    self.description = description
    self.category = category
    self.isSkill = isSkill
  }
}

// MARK: - CommandCatalog

/// The `commands.catalog` gateway response, mobile-curated. Decoded leniently — a
/// malformed or partial payload degrades (skipped entries, empty maps), never throws,
/// same rule as events. The `mobileHiddenCommands` hide-list of terminal-only commands
/// is applied at decode so downstream code never sees them.
public struct CommandCatalog: Equatable, Sendable, Decodable {
  /// Hide-list already applied; category order preserved, skill routes appended last.
  public let commands: [SlashCommand]
  /// Subcommand completions keyed by canonical name, e.g. "/reasoning" → ["none", "low", …].
  public let subcommands: [String: [String]]
  /// Lowercased alias → canonical name (self-mappings included), e.g. "/reset" → "/new".
  public let canonical: [String: String]

  public init(
    commands: [SlashCommand] = [],
    subcommands: [String: [String]] = [:],
    canonical: [String: String] = [:]
  ) {
    self.commands = commands
    self.subcommands = subcommands
    self.canonical = canonical
  }

  /// Terminal-only commands with no sensible mobile surface (screen control, clipboard,
  /// TUI chrome, host-process management). Static and unit-tested; applied at decode.
  /// Redundant-with-native-UI commands (/model, /new, …) are deliberately NOT here —
  /// they stay visible for desktop muscle-memory parity.
  public static let mobileHiddenCommands: Set<String> = [
    "/clear", "/redraw", "/history", "/prompt", "/snapshot", "/config", "/statusbar",
    "/timestamps", "/skin", "/indicator", "/busy", "/copy", "/paste", "/image", "/quit",
    "/handoff", "/tools", "/toolsets", "/pet", "/hatch", "/reload", "/reload-mcp",
    "/reload-skills", "/browser", "/plugins", "/billing", "/platforms", "/journey",
  ]

  enum CodingKeys: String, CodingKey {
    case pairs, sub, canon, categories
  }

  public init(from decoder: Decoder) throws {
    guard let c = try? decoder.container(keyedBy: CodingKeys.self) else {
      self.init()
      return
    }

    let allPairs = Self.decodePairs((try? c.decodeIfPresent(JSONValue.self, forKey: .pairs)) ?? nil)
    let categories = Self.decodeCategories((try? c.decodeIfPresent(JSONValue.self, forKey: .categories)) ?? nil)

    var commands: [SlashCommand] = []
    var categorizedNames: Set<String> = []
    var seen: Set<String> = []

    // Categorized built-ins first, in the server's category + pair order.
    for category in categories {
      for pair in category.pairs {
        let key = pair.name.lowercased()
        // Track hidden names too — a hidden categorized command must not resurface
        // as a "skill" from the flat pairs list below.
        categorizedNames.insert(key)
        guard !Self.mobileHiddenCommands.contains(key), !seen.contains(key) else { continue }
        seen.insert(key)
        commands.append(
          SlashCommand(name: pair.name, description: pair.description, category: category.name, isSkill: false)
        )
      }
    }

    // Entries in `pairs` appearing in no category are the appended skill routes.
    for pair in allPairs {
      let key = pair.name.lowercased()
      guard !categorizedNames.contains(key) else { continue }
      guard !Self.mobileHiddenCommands.contains(key), !seen.contains(key) else { continue }
      seen.insert(key)
      commands.append(SlashCommand(name: pair.name, description: pair.description, category: nil, isSkill: true))
    }

    self.init(
      commands: commands,
      subcommands: Self.decodeSubcommands((try? c.decodeIfPresent(JSONValue.self, forKey: .sub)) ?? nil),
      canonical: Self.decodeCanonical((try? c.decodeIfPresent(JSONValue.self, forKey: .canon)) ?? nil)
    )
  }

  // MARK: Lenient field decoding

  private struct Pair {
    let name: String
    let description: String
  }

  private struct Category {
    let name: String
    let pairs: [Pair]
  }

  /// `[[name, desc], …]` — entries without a string name are skipped; a missing
  /// description degrades to "".
  private static func decodePairs(_ value: JSONValue?) -> [Pair] {
    guard let items = value?.arrayValue else { return [] }
    return items.compactMap { item in
      guard let parts = item.arrayValue, let name = parts.first?.stringValue, !name.isEmpty else { return nil }
      let description = parts.count > 1 ? (parts[1].stringValue ?? "") : ""
      return Pair(name: name, description: description)
    }
  }

  /// `[{name, pairs}, …]` — entries without a string name are skipped.
  private static func decodeCategories(_ value: JSONValue?) -> [Category] {
    guard let items = value?.arrayValue else { return [] }
    return items.compactMap { item in
      guard let name = item["name"]?.stringValue, !name.isEmpty else { return nil }
      return Category(name: name, pairs: decodePairs(item["pairs"]))
    }
  }

  /// `{"/cmd": [subs]}` — non-array values are skipped, non-string members dropped;
  /// hidden commands lose their subcommand entries.
  private static func decodeSubcommands(_ value: JSONValue?) -> [String: [String]] {
    guard case let .object(raw)? = value else { return [:] }
    var result: [String: [String]] = [:]
    for (key, entry) in raw {
      guard !mobileHiddenCommands.contains(key.lowercased()) else { continue }
      guard let members = entry.arrayValue else { continue }
      result[key] = members.compactMap(\.stringValue)
    }
    return result
  }

  /// `{alias: canonical}` — non-string values skipped; entries whose alias OR target
  /// is hidden are dropped (an alias must never resurface a hidden command).
  private static func decodeCanonical(_ value: JSONValue?) -> [String: String] {
    guard case let .object(raw)? = value else { return [:] }
    var result: [String: String] = [:]
    for (key, entry) in raw {
      guard let target = entry.stringValue else { continue }
      guard
        !mobileHiddenCommands.contains(key.lowercased()),
        !mobileHiddenCommands.contains(target.lowercased())
      else { continue }
      result[key] = target
    }
    return result
  }
}
