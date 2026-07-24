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
  /// Subcommand completions keyed by LOWERCASED canonical name (normalized once at
  /// decode), e.g. "/reasoning" → ["none", "low", …].
  public let subcommands: [String: [String]]
  /// LOWERCASED alias (normalized once at decode) → canonical name (self-mappings
  /// included), e.g. "/reset" → "/new".
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

  /// True when a typed command name (NO leading slash, e.g. "status", "st", "deploy")
  /// resolves to a curated, non-hidden command — a visible command/skill route or a known
  /// alias. Both maps already had the `mobileHiddenCommands` hide-list applied at decode, so
  /// a hidden or genuinely-unknown name returns `false`. The submit gate uses this so a
  /// manually-typed hidden command (`/new`, `/quit`, `/branch`, …) NEVER reaches
  /// `slash.exec` — where it would run in the isolated slash-worker subprocess and report
  /// fake success while this live session is untouched — and instead falls through to a
  /// plain `prompt.submit` (byte-identical to the old-agent / nil-catalog backward-compat
  /// path). Skill routes stay executable (they live in `commands` with `isSkill == true`).
  public func resolvesCommand(named name: String) -> Bool {
    let key = "/" + name.lowercased()
    if canonical[key] != nil { return true }
    return commands.contains { $0.name.lowercased() == key }
  }

  /// Commands with no usable mobile surface. Static and unit-tested; applied at decode.
  /// Two groups, both verified against `tui_gateway/server.py` + `hermes_cli/commands.py`:
  ///
  /// 1. **Terminal-only** — screen control, clipboard, TUI chrome, host-process management
  ///    (`/clear`, `/redraw`, `/copy`, … plus the gateway's `_TUI_EXTRA` chrome
  ///    `/density`, `/logs`, `/mouse`).
  /// 2. **No live effect on this client** — commands the gateway runs inside `_SlashWorker`,
  ///    a SEPARATE `python -m tui_gateway.slash_worker` subprocess with its own `HermesCLI`.
  ///    Only `model`, `personality`, `prompt`, `compress`/`compact`, `fast`, `reload-mcp`
  ///    and `stop` are mirrored back onto the live gateway session
  ///    (`_mirror_slash_side_effects`, verified `tui_gateway/server.py`); everything else
  ///    mutates the worker's own conversation and renders output that READS like success
  ///    while this session is untouched. `/new` (+`/reset`), `/sessions` and `/resume`
  ///    rebind the WORKER's session (so later worker commands would target the wrong one),
  ///    `/reasoning <effort>` is session-scoped to the worker's agent, `/branch` (+alias
  ///    `/fork`) branches only the WORKER's DB session, `/yolo` toggles the worker's own
  ///    approval-bypass state (the desktop drives it via a dedicated `session.yolo` RPC,
  ///    never `slash.exec`), and `/voice` toggles voice on the worker subprocess (voice is
  ///    process-global on the gateway and the app owns its own mic UI). The app offers the
  ///    native equivalents (new chat, session list, reasoning picker, voice input), and the
  ///    desktop reference likewise routes them to native surfaces or drops them from its
  ///    palette (`desktop-slash-commands.ts`).
  ///
  /// Commands that DO reach the live session stay visible even where native UI duplicates
  /// them (`/model`, `/title` — the worker shares the session key, so its DB title write
  /// lands on this session).
  public static let mobileHiddenCommands: Set<String> = [
    "/clear", "/redraw", "/history", "/prompt", "/snapshot", "/config", "/statusbar",
    "/timestamps", "/skin", "/indicator", "/busy", "/copy", "/paste", "/image", "/quit",
    "/handoff", "/tools", "/toolsets", "/pet", "/hatch", "/reload", "/reload-mcp",
    "/reload-skills", "/browser", "/plugins", "/billing", "/platforms", "/journey",
    "/density", "/logs", "/mouse",
    "/new", "/reset", "/sessions", "/resume", "/reasoning",
    "/branch", "/yolo", "/voice",
  ]

  enum CodingKeys: String, CodingKey {
    case pairs, sub, canon, categories
  }

  public init(from decoder: Decoder) throws {
    guard let c = try? decoder.container(keyedBy: CodingKeys.self) else {
      self.init()
      return
    }

    let allPairs = Self.decodePairs(try? c.decode(JSONValue.self, forKey: .pairs))
    let categories = Self.decodeCategories(try? c.decode(JSONValue.self, forKey: .categories))

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
      subcommands: Self.decodeSubcommands(try? c.decode(JSONValue.self, forKey: .sub)),
      canonical: Self.decodeCanonical(try? c.decode(JSONValue.self, forKey: .canon))
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
  /// hidden commands lose their subcommand entries. Keys are lowercased here, ONCE, so
  /// lookups downstream are plain subscripts. Members are deduped case-insensitively
  /// (first spelling wins): a `SlashSuggestion`'s identity is its insertion text, so a
  /// server list repeating a subcommand would hand the panel's `ForEach` duplicate ids.
  private static func decodeSubcommands(_ value: JSONValue?) -> [String: [String]] {
    guard case let .object(raw)? = value else { return [:] }
    var result: [String: [String]] = [:]
    for (key, entry) in raw {
      let lowered = key.lowercased()
      guard !mobileHiddenCommands.contains(lowered) else { continue }
      guard let members = entry.arrayValue else { continue }
      var seen: Set<String> = []
      result[lowered] = members.compactMap(\.stringValue).filter { seen.insert($0.lowercased()).inserted }
    }
    return result
  }

  /// `{alias: canonical}` — non-string values skipped; entries whose alias OR target
  /// is hidden are dropped (an alias must never resurface a hidden command). Alias keys
  /// are lowercased here, ONCE, so lookups downstream are plain subscripts.
  private static func decodeCanonical(_ value: JSONValue?) -> [String: String] {
    guard case let .object(raw)? = value else { return [:] }
    var result: [String: String] = [:]
    for (key, entry) in raw {
      let lowered = key.lowercased()
      guard let target = entry.stringValue else { continue }
      guard
        !mobileHiddenCommands.contains(lowered),
        !mobileHiddenCommands.contains(target.lowercased())
      else { continue }
      result[lowered] = target
    }
    return result
  }
}
