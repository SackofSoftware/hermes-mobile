import Foundation

// MARK: - SlashSuggestion

/// One row in the slash-command autocomplete panel: either a command from the catalog
/// (built-in or skill route) or a subcommand completion for an already-typed command.
public struct SlashSuggestion: Equatable, Sendable, Identifiable {
  /// Stable identity for list diffing: the command name, or "/cmd sub".
  public let id: String
  /// Primary monospaced label: "/compress" for commands, "low" for subcommands.
  public let name: String
  /// Secondary description text; empty for subcommand completions.
  public let description: String
  /// True for dynamic skill routes (panel shows a skill icon).
  public let isSkill: Bool
  /// The exact text a tap puts in the composer: "/compress " (trailing space,
  /// ready for args) or "/reasoning low".
  public let insertionText: String

  public init(id: String, name: String, description: String, isSkill: Bool, insertionText: String) {
    self.id = id
    self.name = name
    self.description = description
    self.isSkill = isSkill
    self.insertionText = insertionText
  }
}

// MARK: - SlashSuggestionFilter

/// Pure, stateless suggestion derivation from the composer text and the cached
/// catalog — recomputed on every keystroke, nothing stored, nothing to keep in sync.
///
/// Rules (desktop parity, prefix-only, no fuzzy):
/// - Text must begin with "/" and contain no newline — else `[]` (a mid-sentence
///   slash never triggers the panel).
/// - Bare "/" → the full curated catalog in category order, skills last.
/// - First token, no space yet ("/qu") → case-insensitive prefix match on canonical
///   names AND aliases; a matched alias displays its canonical row.
/// - Known command + space + partial ("/reasoning l") → subcommand completions from
///   the `sub` map. Any other post-space text → `[]` (args are freeform).
public enum SlashSuggestionFilter {
  public static func suggestions(for text: String, catalog: CommandCatalog?) -> [SlashSuggestion] {
    guard let catalog, text.hasPrefix("/"), !text.contains(where: \.isNewline) else { return [] }

    guard let spaceIndex = text.firstIndex(of: " ") else {
      return commandSuggestions(query: text, catalog: catalog)
    }
    let command = String(text[..<spaceIndex])
    let partial = String(text[text.index(after: spaceIndex)...])
    return subcommandSuggestions(command: command, partial: partial, catalog: catalog)
  }

  // MARK: Command mode (no space yet)

  private static func commandSuggestions(query: String, catalog: CommandCatalog) -> [SlashSuggestion] {
    let lowered = query.lowercased()

    let isMatch: (SlashCommand) -> Bool
    if lowered == "/" {
      // Bare "/" shows everything (catalog order: categories first, skills last).
      isMatch = { _ in true }
    } else {
      // Canonical names reached through an alias whose name prefix-matches the query
      // ("/fork" → show the "/branch" row). Filtering over `catalog.commands` keeps
      // catalog order and dedupes an alias + direct double match for free.
      let aliasTargets = Set(
        catalog.canonical
          .filter { $0.key.lowercased().hasPrefix(lowered) }
          .map { $0.value.lowercased() }
      )
      isMatch = { command in
        let name = command.name.lowercased()
        return name.hasPrefix(lowered) || aliasTargets.contains(name)
      }
    }

    return catalog.commands.filter(isMatch).map { command in
      SlashSuggestion(
        id: command.name,
        name: command.name,
        description: command.description,
        isSkill: command.isSkill,
        insertionText: command.name + " "
      )
    }
  }

  // MARK: Subcommand mode (command + space + partial)

  private static func subcommandSuggestions(
    command: String,
    partial: String,
    catalog: CommandCatalog
  ) -> [SlashSuggestion] {
    // A second space means the first argument is complete — args are freeform.
    guard !partial.contains(" ") else { return [] }

    // Resolve an alias so "/fork <partial>" completes against its canonical command.
    let loweredCommand = command.lowercased()
    let canonicalName =
      catalog.canonical.first { $0.key.lowercased() == loweredCommand }?.value ?? command

    guard
      let subs = catalog.subcommands
        .first(where: { $0.key.lowercased() == canonicalName.lowercased() })?.value
    else { return [] }

    let loweredPartial = partial.lowercased()
    return subs
      .filter { loweredPartial.isEmpty || $0.lowercased().hasPrefix(loweredPartial) }
      .map { sub in
        SlashSuggestion(
          id: "\(canonicalName) \(sub)",
          name: sub,
          description: "",
          isSkill: false,
          insertionText: "\(canonicalName) \(sub)"
        )
      }
  }
}
