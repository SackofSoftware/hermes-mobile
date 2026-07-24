import Foundation
import Testing

@testable import HermesKit

struct SlashSuggestionFilterTests {
  /// Curated catalog as Task 1 produces it: category order preserved, skills last,
  /// aliases (with self-mappings) in `canonical`, subcommands keyed by canonical name.
  private let catalog = CommandCatalog(
    commands: [
      SlashCommand(name: "/new", description: "Start a new session", category: "Session"),
      SlashCommand(name: "/branch", description: "Branch the session", category: "Session"),
      SlashCommand(name: "/queue", description: "Queue a message", category: "Session"),
      SlashCommand(name: "/reasoning", description: "Set reasoning effort", category: "Settings"),
      SlashCommand(name: "/status", description: "Show session status", category: "Info"),
      SlashCommand(name: "/plan", description: "Plan a change", category: nil, isSkill: true),
      SlashCommand(name: "/quickfix", description: "Fix a small bug", category: nil, isSkill: true),
    ],
    subcommands: ["/reasoning": ["none", "low", "medium", "high"]],
    canonical: [
      "/new": "/new",
      "/reset": "/new",
      "/branch": "/branch",
      "/fork": "/branch",
      "/queue": "/queue",
      "/reasoning": "/reasoning",
      "/status": "/status",
    ]
  )

  private func suggestions(_ text: String, catalog: CommandCatalog? = nil) -> [SlashSuggestion] {
    SlashSuggestionFilter.suggestions(for: text, catalog: catalog ?? self.catalog)
  }

  // MARK: Command mode

  @Test func bareSlashShowsFullCatalogInCategoryOrderWithSkillsLast() {
    let result = suggestions("/")

    #expect(result.map(\.name) == [
      "/new", "/branch", "/queue", "/reasoning", "/status", "/plan", "/quickfix",
    ])
    #expect(result.map(\.isSkill) == [false, false, false, false, false, true, true])
    #expect(result.first?.description == "Start a new session")
  }

  @Test func prefixQueryFiltersCommandsIncludingSkills() {
    let result = suggestions("/qu")

    // "/queue" (built-in) before "/quickfix" (skill) — catalog order preserved.
    #expect(result.map(\.name) == ["/queue", "/quickfix"])
  }

  @Test func prefixMatchIsPrefixOnlyNotFuzzy() {
    // "ranch" is inside "/branch" but not a prefix of it.
    #expect(suggestions("/ranch").isEmpty)
  }

  @Test func aliasPrefixMatchDisplaysTheCanonicalRow() {
    let result = suggestions("/fo")

    // "/fork" is an alias of "/branch": show the canonical row, not the alias.
    #expect(result.map(\.name) == ["/branch"])
    #expect(result.first?.description == "Branch the session")
  }

  @Test func aliasAndDirectMatchOfSameCommandDeduplicate() {
    // "/re" prefix-matches "/reasoning" directly AND "/reset" (alias of "/new").
    let result = suggestions("/re")

    #expect(result.map(\.name) == ["/new", "/reasoning"])
  }

  @Test func matchingIsCaseInsensitive() {
    #expect(suggestions("/QU").map(\.name) == ["/queue", "/quickfix"])
    #expect(suggestions("/Fo").map(\.name) == ["/branch"])
  }

  @Test func commandInsertionTextAppendsTrailingSpace() {
    let result = suggestions("/sta")

    #expect(result.first?.insertionText == "/status ")
    // Identity is derived from the insertion text (unique in both modes).
    #expect(result.first?.id == "/status ")
  }

  // MARK: Subcommand mode

  @Test func partialSubcommandSuggestsMatchingSubs() {
    let result = suggestions("/reasoning l")

    #expect(result.map(\.name) == ["low"])
    #expect(result.first?.insertionText == "/reasoning low")
    #expect(result.first?.isSkill == false)
    #expect(result.first?.description == "")
  }

  @Test func emptyPartialAfterSpaceSuggestsAllSubs() {
    #expect(suggestions("/reasoning ").map(\.name) == ["none", "low", "medium", "high"])
  }

  @Test func subcommandMatchingIsCaseInsensitive() {
    #expect(suggestions("/REASONING L").map(\.name) == ["low"])
    #expect(suggestions("/REASONING L").first?.insertionText == "/reasoning low")
  }

  @Test func aliasResolvesToCanonicalForSubcommands() {
    // Give the canonical "/new" a sub list to prove alias resolution in sub mode.
    let catalog = CommandCatalog(
      commands: self.catalog.commands,
      subcommands: ["/new": ["blank", "fromtemplate"]],
      canonical: self.catalog.canonical
    )

    let result = suggestions("/reset b", catalog: catalog)
    #expect(result.map(\.name) == ["blank"])
    #expect(result.first?.insertionText == "/new blank")
  }

  @Test func freeformArgsProduceNoSuggestions() {
    // Command with no sub map: any argument text is freeform.
    #expect(suggestions("/status something").isEmpty)
    // A completed first argument (second space) ends suggestion mode.
    #expect(suggestions("/reasoning low ").isEmpty)
    #expect(suggestions("/reasoning low extra").isEmpty)
    // Unknown command + space → nothing.
    #expect(suggestions("/nonsense x").isEmpty)
  }

  @Test func exactSubcommandMatchSuppressesThePanel() {
    // A fully-typed subcommand needs no completion — this is what clears the panel
    // right after a subcommand tap inserts "/reasoning low" (the insertion would
    // otherwise prefix-match itself and linger as a single chosen row).
    #expect(suggestions("/reasoning low").isEmpty)
    #expect(suggestions("/REASONING LOW").isEmpty)
    // A partial that exact-matches one sub still surfaces longer siblings.
    let catalog = CommandCatalog(
      commands: self.catalog.commands,
      subcommands: ["/reasoning": ["low", "lowest"]],
      canonical: self.catalog.canonical
    )
    #expect(suggestions("/reasoning low", catalog: catalog).map(\.name) == ["lowest"])
  }

  // MARK: Guards

  @Test func leadingWhitespaceIsTrimmedLikeSubmitDoes() {
    // `composerSubmitted` trims before its slash check, so " /status" EXECUTES as a
    // slash command — the panel must agree and autocomplete it (web parity: the popover
    // trims too).
    #expect(suggestions(" /qu").map(\.name) == ["/queue", "/quickfix"])
    #expect(suggestions("  /").isEmpty == false)
  }

  @Test func midSentenceSlashNeverTriggers() {
    #expect(suggestions("hello /qu").isEmpty)
    #expect(suggestions("run /status now").isEmpty)
  }

  @Test func multilineTextNeverTriggers() {
    #expect(suggestions("/qu\nmore").isEmpty)
    #expect(suggestions("/\n").isEmpty)
  }

  @Test func nilCatalogYieldsNothing() {
    #expect(SlashSuggestionFilter.suggestions(for: "/", catalog: nil).isEmpty)
    #expect(SlashSuggestionFilter.suggestions(for: "/qu", catalog: nil).isEmpty)
  }

  @Test func nonSlashTextYieldsNothing() {
    #expect(suggestions("").isEmpty)
    #expect(suggestions("plain text").isEmpty)
  }

  @Test func emptyCatalogYieldsNothing() {
    #expect(suggestions("/", catalog: CommandCatalog()).isEmpty)
  }
}
