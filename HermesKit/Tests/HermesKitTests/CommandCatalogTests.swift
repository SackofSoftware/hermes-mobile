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
        ["/model", "Switch the model for this session"],
        ["/compress", "Compress the conversation context"],
        ["/goal", "Manage the standing goal"],
        ["/status", "Show session status"],
        ["/clear", "Clear the screen"],
        ["/quit", "Exit the TUI"],
        ["/new", "Start a new session"],
        ["/reasoning", "Set reasoning effort [none|low|medium|high]"],
        ["/deploy", "exec: ./deploy.sh"],
        ["/code-review", "Review the current changes"],
        ["/research", "Deep-research a topic"]
      ],
      "sub": {
        "/goal": ["show", "pause", "resume"],
        "/reasoning": ["none", "low", "medium", "high"],
        "/skin": ["dark", "light"]
      },
      "canon": {
        "/model": "/model",
        "/compress": "/compress",
        "/compact": "/compress",
        "/goal": "/goal",
        "/status": "/status",
        "/clear": "/clear",
        "/cls": "/clear",
        "/quit": "/quit",
        "/new": "/new",
        "/reset": "/new",
        "/deploy": "/deploy",
        "/code-review": "/code-review",
        "/research": "/research"
      },
      "categories": [
        {"name": "Session", "pairs": [["/model", "Switch the model for this session"], ["/compress", "Compress the conversation context"], ["/new", "Start a new session"]]},
        {"name": "Settings", "pairs": [["/goal", "Manage the standing goal"], ["/reasoning", "Set reasoning effort [none|low|medium|high]"]]},
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
      "/model", "/compress", "/goal", "/status", "/deploy", "/code-review", "/research",
    ])
    #expect(catalog.commands.first?.description == "Switch the model for this session")
  }

  @Test func categorizedCommandsKeepTheirCategoryAndAreNotSkills() throws {
    let catalog = try decode(fullFixture)
    let byName = Dictionary(uniqueKeysWithValues: catalog.commands.map { ($0.name, $0) })

    #expect(byName["/model"]?.category == "Session")
    #expect(byName["/compress"]?.category == "Session")
    #expect(byName["/goal"]?.category == "Settings")
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

  @Test func hideListRemovesCommandsWithNoLiveEffectOnMobile() throws {
    // The gateway runs worker-routed commands in a SEPARATE `slash_worker` subprocess and
    // mirrors only model/personality/prompt/compress/fast/reload-mcp/stop back onto the
    // live session, so `/new` (and its `/reset` alias) and `/reasoning` would render
    // success while this session stayed untouched — they must never be advertised.
    let catalog = try decode(fullFixture)

    #expect(!catalog.commands.contains { $0.name == "/new" })
    #expect(!catalog.commands.contains { $0.name == "/reasoning" })
    #expect(catalog.canonical["/reset"] == nil)
    #expect(catalog.canonical["/new"] == nil)
    #expect(catalog.subcommands["/reasoning"] == nil)
    // Commands that DO reach the live session stay visible.
    #expect(catalog.commands.contains { $0.name == "/model" })
    #expect(catalog.commands.contains { $0.name == "/compress" })
  }

  @Test func aliasesAreMappedAndHiddenOnesDropped() throws {
    let catalog = try decode(fullFixture)

    #expect(catalog.canonical["/compact"] == "/compress")
    #expect(catalog.canonical["/compress"] == "/compress")
    #expect(catalog.canonical["/model"] == "/model")
    // Hidden canonical target → the alias and self-mapping are both gone.
    #expect(catalog.canonical["/cls"] == nil)
    #expect(catalog.canonical["/clear"] == nil)
    #expect(catalog.canonical["/quit"] == nil)
  }

  @Test func subcommandsAreMappedAndHiddenOnesDropped() throws {
    let catalog = try decode(fullFixture)

    #expect(catalog.subcommands["/goal"] == ["show", "pause", "resume"])
    #expect(catalog.subcommands["/skin"] == nil)
  }

  @Test func decodesViaJSONValueRoundTrip() throws {
    // Production path: the gateway returns a JSONValue result re-decoded via `decoded()`.
    let value = try JSONDecoder().decode(JSONValue.self, from: Data(fullFixture.utf8))
    let catalog = try #require(value.decoded(CommandCatalog.self))

    #expect(catalog.commands.count == 7)
    #expect(catalog.canonical["/compact"] == "/compress")
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
        "sub": {"/Goal": ["Show", "Pause"]},
        "canon": {"/Compact": "/compress"}
      }
      """
    )

    #expect(catalog.subcommands == ["/goal": ["Show", "Pause"]])
    #expect(catalog.canonical == ["/compact": "/compress"])
  }

  @Test func duplicateSubcommandsAreDeduplicated() throws {
    // `SlashSuggestion.id` is its insertion text, so a server list repeating a subcommand
    // would hand the panel's `ForEach` duplicate ids. First spelling wins.
    let catalog = try decode(
      """
      {"sub": {"/goal": ["show", "pause", "SHOW", "show", "resume"]}}
      """
    )

    #expect(catalog.subcommands["/goal"] == ["show", "pause", "resume"])
  }

  @Test func hideListContainsOnlySlashPrefixedLowercaseNames() {
    for name in CommandCatalog.mobileHiddenCommands {
      #expect(name.hasPrefix("/"))
      #expect(name == name.lowercased())
    }
    #expect(CommandCatalog.mobileHiddenCommands.contains("/quit"))
    // TUI chrome (the gateway's `_TUI_EXTRA`) and worker-only commands are hidden. `/branch`,
    // `/yolo` and `/voice` run in the isolated slash-worker with NO live-session effect
    // (verified against `_mirror_slash_side_effects`), so they must never be advertised.
    for hidden in [
      "/density", "/logs", "/mouse", "/new", "/reset", "/sessions", "/resume", "/reasoning",
      "/branch", "/yolo", "/voice",
    ] {
      #expect(CommandCatalog.mobileHiddenCommands.contains(hidden), "\(hidden) must be hidden")
    }
    // Commands that DO reach the live gateway session stay visible.
    for visible in ["/model", "/title", "/compress", "/status", "/goal"] {
      #expect(!CommandCatalog.mobileHiddenCommands.contains(visible), "\(visible) must stay visible")
    }
  }

  @Test func resolvesCommandMatchesCuratedCommandsAndAliases() {
    let catalog = CommandCatalog(
      commands: [
        SlashCommand(name: "/status", description: "", category: "Session", isSkill: false),
        SlashCommand(name: "/deploy", description: "", category: nil, isSkill: true),
      ],
      subcommands: [:],
      canonical: ["/st": "/status", "/status": "/status", "/deploy": "/deploy"]
    )
    // Visible command, skill route, and alias all resolve (case-insensitively, no slash).
    #expect(catalog.resolvesCommand(named: "status"))
    #expect(catalog.resolvesCommand(named: "STATUS"))
    #expect(catalog.resolvesCommand(named: "deploy")) // skill route
    #expect(catalog.resolvesCommand(named: "st"))     // alias
    // Hidden (never in the curated maps) and unknown names do NOT resolve — they fall
    // through to a plain prompt.submit instead of reaching slash.exec.
    #expect(!catalog.resolvesCommand(named: "new"))
    #expect(!catalog.resolvesCommand(named: "branch"))
    #expect(!catalog.resolvesCommand(named: "totallyunknown"))
    #expect(!catalog.resolvesCommand(named: ""))
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
        "sub": {"/goal": ["low", 3, "high"], "/broken": "not-an-array", "/alsobad": {"x": 1}},
        "canon": {"/compact": "/compress", "/broken": 12, "/alsobad": null}
      }
      """
    )

    #expect(catalog.subcommands == ["/goal": ["low", "high"]])
    #expect(catalog.canonical == ["/compact": "/compress"])
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
