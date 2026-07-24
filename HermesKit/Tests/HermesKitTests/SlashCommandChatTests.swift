import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

/// Slash-command support (#36), Task 3: the one-shot `commands.catalog` fetch fired when a
/// session becomes ready, capability-gated the attach way — `-32601` flips
/// `commandsUnsupported` (suppressing future fetches), any other failure stays silent with
/// the catalog `nil` so the next hydrate naturally retries.
///
/// Task 4: the computed `slashSuggestions` (pure derivation from `composerText` + catalog,
/// nothing stored) and `.slashSuggestionTapped` (inserts the suggestion's text, nothing else).
@MainActor
struct SlashCommandChatTests {
  private let conn = ServerConnection(baseURL: URL(string: "http://mac.tailnet:9119")!, token: "t")

  /// A realistic `commands.catalog` payload: two categorized built-ins (one with
  /// subcommands + an alias) and one uncategorized skill route appended last.
  nonisolated private static let catalogPayload: JSONValue = .object([
    "pairs": .array([
      .array([.string("/status"), .string("Show session status")]),
      .array([.string("/reasoning"), .string("Set reasoning effort")]),
      .array([.string("/plan"), .string("Skill: make a plan")]),
    ]),
    "sub": .object(["/reasoning": .array([.string("none"), .string("low"), .string("high")])]),
    "canon": .object([
      "/status": .string("/status"),
      "/st": .string("/status"),
      "/reasoning": .string("/reasoning"),
      "/plan": .string("/plan"),
    ]),
    "categories": .array([
      .object([
        "name": .string("Session"),
        "pairs": .array([
          .array([.string("/status"), .string("Show session status")]),
          .array([.string("/reasoning"), .string("Set reasoning effort")]),
        ]),
      ]),
    ]),
  ])

  /// What `catalogPayload` decodes to (Task 1's lenient decode).
  nonisolated private static let expectedCatalog = CommandCatalog(
    commands: [
      SlashCommand(name: "/status", description: "Show session status", category: "Session", isSkill: false),
      SlashCommand(name: "/reasoning", description: "Set reasoning effort", category: "Session", isSkill: false),
      SlashCommand(name: "/plan", description: "Skill: make a plan", category: nil, isSkill: true),
    ],
    subcommands: ["/reasoning": ["none", "low", "high"]],
    canonical: [
      "/status": "/status",
      "/st": "/status",
      "/reasoning": "/reasoning",
      "/plan": "/plan",
    ]
  )

  /// A minimal `session.resume` payload (idle turn, info + usage present so no fallback
  /// `session.usage` fetch muddies the call log).
  nonisolated private static let activatePayload: JSONValue = .object([
    "session_id": .string("live123"),
    "stored_session_id": .string("stored123"),
    "messages": .array([]),
    "running": .bool(false),
    "info": .object([
      "model": .string("claude-opus-4-8"),
      "usage": .object([
        "context_used": .number(1), "context_max": .number(200_000), "context_percent": .number(0),
      ]),
    ]),
  ])

  // MARK: Successful fetch

  @Test func hydrateReadyFetchesAndPopulatesCatalog() async {
    // Once the hydrate reaches ready, the one-shot `commands.catalog` fetch fires (with the
    // live session id) and populates `commandCatalog`; a later hydrate of the same screen
    // does NOT refetch a loaded catalog.
    let catalogCalls = LockIsolated(0)
    let catalogParams = LockIsolated<JSONValue?>(nil)
    let store = TestStore(initialState: ChatFeature.State(connection: conn, resumeStoredID: "stored123")) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable method, params in
        if method == "commands.catalog" {
          catalogCalls.withValue { $0 += 1 }
          catalogParams.setValue(params)
          return Self.catalogPayload
        }
        return Self.activatePayload
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.gatewayEvent(.ready))
    await store.receive(\.activateResult.success)
    await store.receive(\.commandCatalogLoaded) {
      $0.commandCatalog = Self.expectedCatalog
    }
    #expect(store.state.commandsUnsupported == false)
    #expect(catalogParams.value?["session_id"]?.stringValue == "live123")
    #expect(catalogCalls.value == 1)

    // A second hydrate (foreground over the healthy socket) must NOT refetch — the catalog
    // is already loaded.
    await store.send(.foreground)
    await store.receive(\.activateResult.success)
    await store.send(.teardown)
    #expect(catalogCalls.value == 1)
  }

  @Test func freshSessionCreateFetchesCatalog() async {
    // A brand-new chat resolves through `session.create` (no hydrate ever fires), so the
    // catalog fetch rides the create result — otherwise a fresh chat would have no slash
    // panel until the first foreground re-hydrate.
    let store = TestStore(initialState: ChatFeature.State(connection: conn)) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable method, _ in
        if method == "commands.catalog" { return Self.catalogPayload }
        return .object([
          "session_id": .string("live123"),
          "stored_session_id": .string("stored123"),
          "message_count": .number(0),
        ])
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.gatewayEvent(.ready))
    await store.receive(\.sessionResult.success) {
      $0.liveSessionID = "live123"
      $0.storedSessionID = "stored123"
    }
    await store.receive(\.commandCatalogLoaded) {
      $0.commandCatalog = Self.expectedCatalog
    }
    await store.send(.teardown)
  }

  // MARK: Capability gate (attach pattern)

  @Test func unknownMethodFlipsCommandsUnsupportedAndSuppressesFutureFetches() async {
    // An old agent answers `-32601` ("unknown method") → `commandsUnsupported` latches, no
    // banner (nothing the user did failed), and later hydrates never poke the agent again.
    let catalogCalls = LockIsolated(0)
    let store = TestStore(initialState: ChatFeature.State(connection: conn, resumeStoredID: "stored123")) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable method, _ in
        if method == "commands.catalog" {
          catalogCalls.withValue { $0 += 1 }
          throw GatewayError.server("unknown method: commands.catalog")
        }
        return Self.activatePayload
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.gatewayEvent(.ready))
    await store.receive(\.activateResult.success)
    await store.receive(\.commandsUnsupportedDetected) {
      $0.commandsUnsupported = true
    }
    #expect(store.state.commandCatalog == nil)
    #expect(store.state.errorBanner == nil)
    #expect(catalogCalls.value == 1)

    // The next hydrate skips the fetch entirely — the capability is ruled out.
    await store.send(.foreground)
    await store.receive(\.activateResult.success)
    await store.send(.teardown)
    #expect(catalogCalls.value == 1)
  }

  // MARK: Transient failure retries on the next hydrate

  @Test func transientCatalogFailureLeavesNilAndNextHydrateRefetches() async {
    // A transient failure (network / server hiccup) is silent: no banner, catalog stays
    // `nil`, `commandsUnsupported` stays false — and the next hydrate naturally refetches.
    let catalogCalls = LockIsolated(0)
    let store = TestStore(initialState: ChatFeature.State(connection: conn, resumeStoredID: "stored123")) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable method, _ in
        if method == "commands.catalog" {
          let attempt = catalogCalls.withValue { $0 += 1; return $0 }
          guard attempt > 1 else { throw GatewayError.server("catalog exploded") }
          return Self.catalogPayload
        }
        return Self.activatePayload
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.gatewayEvent(.ready))
    await store.receive(\.activateResult.success)
    await waitUntil { catalogCalls.value == 1 }
    // Silent: no state change, no banner — the catalog just stays unloaded.
    #expect(store.state.commandCatalog == nil)
    #expect(store.state.commandsUnsupported == false)
    #expect(store.state.errorBanner == nil)

    // The next hydrate refetches and succeeds this time.
    await store.send(.foreground)
    await store.receive(\.activateResult.success)
    await store.receive(\.commandCatalogLoaded) {
      $0.commandCatalog = Self.expectedCatalog
    }
    #expect(catalogCalls.value == 2)
    await store.send(.teardown)
  }

  @Test func emptyCatalogPayloadStaysNilForLaterRetry() async {
    // The lenient decode never throws, so a garbage/empty payload surfaces as an EMPTY
    // catalog — as useless as none. It must NOT latch: state stays `nil` (silent) so a
    // later hydrate can still recover a real catalog.
    let catalogCalls = LockIsolated(0)
    let store = TestStore(initialState: ChatFeature.State(connection: conn, resumeStoredID: "stored123")) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable method, _ in
        if method == "commands.catalog" {
          catalogCalls.withValue { $0 += 1 }
          return .object([:]) // no pairs/sub/canon/categories at all
        }
        return Self.activatePayload
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.gatewayEvent(.ready))
    await store.receive(\.activateResult.success)
    await waitUntil { catalogCalls.value == 1 }
    await store.send(.teardown)
    #expect(store.state.commandCatalog == nil)
    #expect(store.state.commandsUnsupported == false)
  }

  // MARK: Computed suggestions (Task 4)

  /// A loaded-catalog state with no gateway plumbing: the suggestion tests exercise only
  /// the pure computed property + the tap action, no effects fire.
  private func stateWithCatalog() -> ChatFeature.State {
    var state = ChatFeature.State(connection: conn)
    state.commandCatalog = Self.expectedCatalog
    return state
  }

  @Test func typingSlashYieldsFullSuggestionList() async {
    // The issue's core affordance: typing "/" surfaces the whole curated catalog in
    // category order with the skill route last — derived from the computed property,
    // no stored suggestion state.
    let store = TestStore(initialState: stateWithCatalog()) { ChatFeature() }

    await store.send(.binding(.set(\.composerText, "/"))) {
      $0.composerText = "/"
    }
    #expect(store.state.slashSuggestions.map(\.name) == ["/status", "/reasoning", "/plan"])
    #expect(store.state.slashSuggestions.map(\.isSkill) == [false, false, true])
  }

  @Test func typingFiltersSuggestions() async {
    // Continued typing narrows by case-insensitive prefix; aliases resolve to their
    // canonical row ("/st" matches "/status" both directly and via the "/st" alias —
    // shown once).
    let store = TestStore(initialState: stateWithCatalog()) { ChatFeature() }

    await store.send(.binding(.set(\.composerText, "/re"))) {
      $0.composerText = "/re"
    }
    #expect(store.state.slashSuggestions.map(\.name) == ["/reasoning"])

    await store.send(.binding(.set(\.composerText, "/st"))) {
      $0.composerText = "/st"
    }
    #expect(store.state.slashSuggestions.map(\.name) == ["/status"])

    // Subcommand mode: a known command + space + partial completes from the `sub` map.
    await store.send(.binding(.set(\.composerText, "/reasoning l"))) {
      $0.composerText = "/reasoning l"
    }
    #expect(store.state.slashSuggestions.map(\.name) == ["low"])
  }

  @Test func tapInsertsCommandAndClearsPanel() async throws {
    // Tapping a command row puts "/name " (trailing space, ready for args) in the
    // composer and changes NOTHING else; the computed suggestions clear on their own
    // ("/status " has no subcommands).
    let store = TestStore(initialState: stateWithCatalog()) { ChatFeature() }

    await store.send(.binding(.set(\.composerText, "/st"))) {
      $0.composerText = "/st"
    }
    let suggestion = try #require(store.state.slashSuggestions.first)
    await store.send(.slashSuggestionTapped(suggestion)) {
      $0.composerText = "/status "
    }
    #expect(store.state.slashSuggestions.isEmpty)

    // A subcommand tap inserts "/cmd sub" (no trailing space — the arg is complete).
    await store.send(.binding(.set(\.composerText, "/reasoning l"))) {
      $0.composerText = "/reasoning l"
    }
    let sub = try #require(store.state.slashSuggestions.first)
    await store.send(.slashSuggestionTapped(sub)) {
      $0.composerText = "/reasoning low"
    }
  }

  @Test func nonSlashInputNeverProducesSuggestions() async {
    // Ordinary prose — including a mid-sentence slash and multiline text — must never
    // pop the panel.
    let store = TestStore(initialState: stateWithCatalog()) { ChatFeature() }

    await store.send(.binding(.set(\.composerText, "hello"))) {
      $0.composerText = "hello"
    }
    #expect(store.state.slashSuggestions.isEmpty)

    await store.send(.binding(.set(\.composerText, "see /status for details"))) {
      $0.composerText = "see /status for details"
    }
    #expect(store.state.slashSuggestions.isEmpty)

    await store.send(.binding(.set(\.composerText, "/status\nsecond line"))) {
      $0.composerText = "/status\nsecond line"
    }
    #expect(store.state.slashSuggestions.isEmpty)
  }

  @Test func suggestionsEmptyWhenCommandsUnsupported() async {
    // Backward-compat guard: an old agent (commandsUnsupported latched) never shows the
    // panel — even defensively against a somehow-populated catalog. And with no catalog
    // loaded yet (nil), "/" likewise yields nothing.
    var unsupported = stateWithCatalog()
    unsupported.commandsUnsupported = true
    let store = TestStore(initialState: unsupported) { ChatFeature() }

    await store.send(.binding(.set(\.composerText, "/"))) {
      $0.composerText = "/"
    }
    #expect(store.state.slashSuggestions.isEmpty)

    let nilCatalog = TestStore(initialState: ChatFeature.State(connection: conn)) { ChatFeature() }
    await nilCatalog.send(.binding(.set(\.composerText, "/"))) {
      $0.composerText = "/"
    }
    #expect(nilCatalog.state.slashSuggestions.isEmpty)
  }
}
