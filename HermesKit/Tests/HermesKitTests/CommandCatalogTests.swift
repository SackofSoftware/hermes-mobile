import Foundation
import Testing

@testable import HermesKit

struct CommandCatalogTests {
  private func decode(_ json: String) throws -> CommandCatalog {
    try JSONDecoder().decode(CommandCatalog.self, from: Data(json.utf8))
  }

  /// A realistic `commands.catalog` result mirroring the server's shape: categorized
  /// built-ins (+ a "User commands" quick-command bucket), skill routes appended to
  /// `pairs` only, aliases (with self-mappings) in `canon`, subcommands in `sub`.
  private let fullFixture = """
    {
      "pairs": [
        ["/new", "Start a new session"],
        ["/compress", "Compress the conversation context"],
        ["/reasoning", "Set reasoning effort [none|low|medium|high]"],
        ["/status", "Show session status"],
        ["/clear", "Clear the screen"],
        ["/quit", "Exit the TUI"],
        ["/deploy", "exec: ./deploy.sh"],
        ["/code-review", "Review the current changes"],
        ["/research", "Deep-research a topic"]
      ],
      "sub": {
        "/reasoning": ["none", "low", "medium", "high"],
        "/skin": ["dark", "light"]
      },
      "canon": {
        "/new": "/new",
        "/reset": "/new",
        "/compress": "/compress",
        "/compact": "/compress",
        "/reasoning": "/reasoning",
        "/status": "/status",
        "/clear": "/clear",
        "/cls": "/clear",
        "/quit": "/quit",
        "/deploy": "/deploy",
        "/code-review": "/code-review",
        "/research": "/research"
      },
      "categories": [
        {"name": "Session", "pairs": [["/new", "Start a new session"], ["/compress", "Compress the conversation context"]]},
        {"name": "Settings", "pairs": [["/reasoning", "Set reasoning effort [none|low|medium|high]"]]},
        {"name": "Info", "pairs": [["/status", "Show session status"]]},
        {"name": "TUI", "pairs": [["/clear", "Clear the screen"], ["/quit", "Exit the TUI"]]},
        {"name": "User commands", "pairs": [["/deploy", "exec: ./deploy.sh"]]}
      ],
      "skill_count": 2,
      "warning": ""
    }
    """

  // MARK: Full fixture

  @Test func decodesFullFixtureInCategoryOrderWithSkillsLast() throws {
    let catalog = try decode(fullFixture)

    #expect(catalog.commands.map(\.name) == [
      "/new", "/compress", "/reasoning", "/status", "/deploy", "/code-review", "/research",
    ])
    #expect(catalog.commands.first?.description == "Start a new session")
  }

  @Test func categorizedCommandsKeepTheirCategoryAndAreNotSkills() throws {
    let catalog = try decode(fullFixture)
    let byName = Dictionary(uniqueKeysWithValues: catalog.commands.map { ($0.name, $0) })

    #expect(byName["/new"]?.category == "Session")
    #expect(byName["/compress"]?.category == "Session")
    #expect(byName["/reasoning"]?.category == "Settings")
    #expect(byName["/deploy"]?.category == "User commands")
    #expect(catalog.commands.filter { $0.category != nil }.allSatisfy { !$0.isSkill })
  }

  @Test func uncategorizedPairsAreMarkedAsSkills() throws {
    let catalog = try decode(fullFixture)
    let skills = catalog.commands.filter(\.isSkill)

    #expect(skills.map(\.name) == ["/code-review", "/research"])
    #expect(skills.allSatisfy { $0.category == nil })
    // Skills come after every built-in.
    let index = catalog.commands.firstIndex(where: \.isSkill)
    let firstSkillIndex = try #require(index)
    #expect(catalog.commands[..<firstSkillIndex].allSatisfy { !$0.isSkill })
  }

  @Test func hideListRemovesTerminalOnlyCommands() throws {
    let catalog = try decode(fullFixture)

    #expect(!catalog.commands.contains { $0.name == "/clear" })
    #expect(!catalog.commands.contains { $0.name == "/quit" })
    // Hidden categorized names never resurface as skills from the flat pairs list.
    #expect(!catalog.commands.contains { $0.isSkill && ($0.name == "/clear" || $0.name == "/quit") })
  }

  @Test func aliasesAreMappedAndHiddenOnesDropped() throws {
    let catalog = try decode(fullFixture)

    #expect(catalog.canonical["/reset"] == "/new")
    #expect(catalog.canonical["/compact"] == "/compress")
    #expect(catalog.canonical["/new"] == "/new")
    // Hidden canonical target → the alias and self-mapping are both gone.
    #expect(catalog.canonical["/cls"] == nil)
    #expect(catalog.canonical["/clear"] == nil)
    #expect(catalog.canonical["/quit"] == nil)
  }

  @Test func subcommandsAreMappedAndHiddenOnesDropped() throws {
    let catalog = try decode(fullFixture)

    #expect(catalog.subcommands["/reasoning"] == ["none", "low", "medium", "high"])
    #expect(catalog.subcommands["/skin"] == nil)
  }

  @Test func decodesViaJSONValueRoundTrip() throws {
    // Production path: the gateway returns a JSONValue result re-decoded via `decoded()`.
    let value = try JSONDecoder().decode(JSONValue.self, from: Data(fullFixture.utf8))
    let catalog = try #require(value.decoded(CommandCatalog.self))

    #expect(catalog.commands.count == 7)
    #expect(catalog.canonical["/reset"] == "/new")
  }

  @Test func hideListMatchingIsCaseInsensitive() throws {
    // A server emitting "/Clear" (any casing) is still hidden — pairs, categories, sub
    // entries, and aliases alike.
    let catalog = try decode(
      """
      {
        "pairs": [["/Clear", "Clear the screen"], ["/QUIT", "Exit"], ["/ok", "fine"]],
        "sub": {"/Clear": ["all"]},
        "canon": {"/CLS": "/Clear", "/ok": "/ok"},
        "categories": [
          {"name": "TUI", "pairs": [["/Clear", "Clear the screen"], ["/QUIT", "Exit"]]}
        ]
      }
      """
    )

    #expect(catalog.commands.map(\.name) == ["/ok"])
    #expect(catalog.subcommands.isEmpty)
    #expect(catalog.canonical == ["/ok": "/ok"])
  }

  @Test func subAndCanonKeysAreLowercasedAtDecode() throws {
    // Case is normalized ONCE at decode so the suggestion filter can use plain
    // subscripts; values keep their casing.
    let catalog = try decode(
      """
      {
        "sub": {"/Reasoning": ["Low", "High"]},
        "canon": {"/Reset": "/new"}
      }
      """
    )

    #expect(catalog.subcommands == ["/reasoning": ["Low", "High"]])
    #expect(catalog.canonical == ["/reset": "/new"])
  }

  @Test func hideListContainsOnlySlashPrefixedLowercaseNames() {
    for name in CommandCatalog.mobileHiddenCommands {
      #expect(name.hasPrefix("/"))
      #expect(name == name.lowercased())
    }
    #expect(CommandCatalog.mobileHiddenCommands.contains("/quit"))
    // Native-UI-redundant commands stay visible (muscle-memory parity).
    #expect(!CommandCatalog.mobileHiddenCommands.contains("/model"))
    #expect(!CommandCatalog.mobileHiddenCommands.contains("/new"))
  }

  // MARK: Lenient decoding

  @Test func emptyObjectDecodesToEmptyCatalog() throws {
    let catalog = try decode("{}")

    #expect(catalog.commands.isEmpty)
    #expect(catalog.subcommands.isEmpty)
    #expect(catalog.canonical.isEmpty)
  }

  @Test func nonObjectPayloadDegradesToEmptyCatalog() throws {
    #expect(try decode("[]") == CommandCatalog())
    #expect(try decode(#""nonsense""#) == CommandCatalog())
  }

  @Test func malformedPairEntriesAreSkippedNotFatal() throws {
    let catalog = try decode(
      """
      {
        "pairs": [42, "junk", [], ["", "empty name"], ["/ok", "fine"], ["/nameonly"], ["/numdesc", 5], null],
        "categories": []
      }
      """
    )

    #expect(catalog.commands.map(\.name) == ["/ok", "/nameonly", "/numdesc"])
    // Missing / non-string description degrades to "".
    #expect(catalog.commands.map(\.description) == ["fine", "", ""])
  }

  @Test func missingCategoriesMakesEveryPairASkill() throws {
    let catalog = try decode(#"{"pairs": [["/plan", "Plan a change"]]}"#)

    #expect(catalog.commands == [
      SlashCommand(name: "/plan", description: "Plan a change", category: nil, isSkill: true)
    ])
  }

  @Test func malformedCategoryEntriesAreSkipped() throws {
    let catalog = try decode(
      """
      {
        "pairs": [["/a", "a"], ["/b", "b"]],
        "categories": [17, {"pairs": [["/a", "a"]]}, {"name": "Good", "pairs": [["/b", "b"]]}, null]
      }
      """
    )

    // The nameless category is dropped, so /a falls through to the skill bucket.
    #expect(catalog.commands.map(\.name) == ["/b", "/a"])
    #expect(catalog.commands[0].category == "Good")
    #expect(catalog.commands[1].isSkill)
  }

  @Test func malformedSubAndCanonEntriesAreSkipped() throws {
    let catalog = try decode(
      """
      {
        "sub": {"/reasoning": ["low", 3, "high"], "/broken": "not-an-array", "/alsobad": {"x": 1}},
        "canon": {"/reset": "/new", "/broken": 12, "/alsobad": null}
      }
      """
    )

    #expect(catalog.subcommands == ["/reasoning": ["low", "high"]])
    #expect(catalog.canonical == ["/reset": "/new"])
  }

  @Test func duplicateNamesAreDeduplicatedKeepingTheFirst() throws {
    let catalog = try decode(
      """
      {
        "pairs": [["/dup", "flat"], ["/solo", "skill"]],
        "categories": [
          {"name": "One", "pairs": [["/dup", "first"]]},
          {"name": "Two", "pairs": [["/dup", "second"]]}
        ]
      }
      """
    )

    #expect(catalog.commands.map(\.name) == ["/dup", "/solo"])
    #expect(catalog.commands[0].description == "first")
    #expect(catalog.commands[0].category == "One")
  }
}
