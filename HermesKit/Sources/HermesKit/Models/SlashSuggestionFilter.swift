import Foundation

// MARK: - SlashSuggestion

/// One row in the slash-command autocomplete panel: either a command from the catalog
/// (built-in or skill route) or a subcommand completion for an already-typed command.
public struct SlashSuggestion: Equatable, Sendable, Identifiable {
  /// Primary monospaced label: "/compress" for commands, "low" for subcommands.
  public let name: String
  /// Secondary description text; empty for subcommand completions.
  public let description: String
  /// True for dynamic skill routes (panel shows a skill icon).
  public let isSkill: Bool
  /// The exact text a tap puts in the composer: "/compress " (trailing space,
  /// ready for args) or "/reasoning low".
  public let insertionText: String

  /// Stable identity for list diffing — the insertion text is unique in both modes
  /// (command names are deduped at decode; subcommand insertions embed the command).
  public var id: String { insertionText }

  public init(name: String, description: String, isSkill: Bool, insertionText: String) {
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
/// - Leading whitespace is trimmed first — `composerSubmitted` trims before its slash
///   check, so " /status" EXECUTES as a slash command and must autocomplete too.
/// - The (trimmed) text must begin with "/" and contain no newline — else `[]` (a
///   mid-sentence slash never triggers the panel).
/// - Bare "/" → the full curated catalog in category order, skills last.
/// - First token, no space yet ("/qu") → case-insensitive prefix match on canonical
///   names AND aliases; a matched alias displays its canonical row.
/// - Known command + space + partial ("/reasoning l") → subcommand completions from
///   the `sub` map; an EXACT match is suppressed (the argument is complete, so the
///   panel clears after a subcommand tap). Any other post-space text → `[]` (args are
///   freeform).
public enum SlashSuggestionFilter {
  public static func suggestions(for text: String, catalog: CommandCatalog?) -> [SlashSuggestion] {
    let text = String(text.drop(while: \.isWhitespace))
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
      // catalog order and dedupes an alias + direct double match for free. Alias keys
      // are lowercased at decode.
      let aliasTargets = Set(
        catalog.canonical
          .filter { $0.key.hasPrefix(lowered) }
          .map { $0.value.lowercased() }
      )
      isMatch = { command in
        let name = command.name.lowercased()
        return name.hasPrefix(lowered) || aliasTargets.contains(name)
      }
    }

    return catalog.commands.filter(isMatch).map { command in
      SlashSuggestion(
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

    // Resolve an alias so "/fork <partial>" completes against its canonical command
    // (keys lowercased at decode → direct subscripts).
    let loweredCommand = command.lowercased()
    let canonicalName = catalog.canonical[loweredCommand] ?? command

    guard let subs = catalog.subcommands[canonicalName.lowercased()] else { return [] }

    let loweredPartial = partial.lowercased()
    return subs
      .filter { sub in
        let lowered = sub.lowercased()
        // Exact match suppressed: the argument is already complete, so the panel clears
        // after a subcommand tap ("/reasoning low") instead of lingering with the single
        // chosen row.
        return lowered != loweredPartial
          && (loweredPartial.isEmpty || lowered.hasPrefix(loweredPartial))
      }
      .map { sub in
        SlashSuggestion(
          name: sub,
          description: "",
          isSkill: false,
          insertionText: "\(canonicalName) \(sub)"
        )
      }
  }
}
