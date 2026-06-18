#if DEBUG
import ComposableArchitecture
import Foundation
import HermesKit

/// Seeded "demo mode" used **only** for App Store screenshot capture (never shipped in
/// Release — the whole file is `#if DEBUG`). Activated by the `HERMES_DEMO` env var, whose
/// value selects a scenario. Each scenario builds a fully-seeded `AppFeature.State` plus a
/// set of inert dependency overrides so no live socket/REST traffic mutates the curated
/// state on screen.
///
/// Launch from the host shell with, e.g.:
///   SIMCTL_CHILD_HERMES_DEMO=chat xcrun simctl launch <udid> me.honcharenko.HermesMobile
enum DemoMode {
  /// The selected scenario name, or `nil` when the env var is unset (normal launch).
  static var scenario: String? {
    guard let raw = ProcessInfo.processInfo.environment["HERMES_DEMO"]?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !raw.isEmpty
    else { return nil }
    return raw.lowercased()
  }

  static var isActive: Bool { scenario != nil }

  // Fixed reference values so relative timestamps render deterministically.
  private static let now = Date(timeIntervalSince1970: 1_749_600_000)
  private static let connection = ServerConnection(
    baseURL: URL(string: "http://mac.tailnet:9119")!,
    token: "demo-token"
  )

  /// Build the root store for the active scenario.
  static func makeStore() -> StoreOf<AppFeature> {
    let scenario = self.scenario ?? "chat"
    return Store(initialState: state(for: scenario)) {
      AppFeature()
    } withDependencies: { deps in
      configure(&deps)
    }
  }

  // MARK: Dependency overrides

  private static func configure(_ deps: inout DependencyValues) {
    // Never open a real socket — a never-emitting stream keeps the seeded transcript /
    // ready status frozen exactly as authored.
    deps.hermesGateway.connect = { _, _ in AsyncStream { _ in } }
    // Session-list refresh + poll return the seeded sessions unchanged — both the unscoped
    // (`rest.sessions`) and the profile-scoped (`profiles.sessions`) fetch paths.
    deps.hermesREST.sessions = { _, _, _, _ in seededSessions }
    deps.hermesProfiles.sessions = { _, _, _, _, _, _ in seededSessions }
    // The agent always exposes the default profile, so the "default" pill is always present.
    deps.hermesProfiles.list = { _ in [Profile(name: "default", isDefault: true)] }
    // Deterministic relative timestamps.
    deps.date = .constant(now)
    // Persisted UI prefs, pre-seeded so `reloadPrefs` keeps our curated grouping/pins.
    deps.preferences = demoPreferences
  }

  private static var demoPreferences: PreferencesClient {
    var client = PreferencesClient.inMemory()
    client.loadServerURL = { connection.baseURL.absoluteString }
    client.loadGroupingMode = { .chronological }
    client.loadPinnedIDs = { ["s0"] }
    client.loadSeenCounts = {
      // s1 has unread activity (seen < messageCount); the rest are caught up.
      var seen = Dictionary(uniqueKeysWithValues: seededSessions.map { ($0.id, $0.messageCount ?? 0) })
      seen["s1"] = 6
      return seen
    }
    return client
  }

  // MARK: Scenario → state

  private static func state(for scenario: String) -> AppFeature.State {
    switch scenario {
    case "sessions":
      return AppFeature.State(home: sessionListState)
    case "work":
      return chatScenario(workChat)
    case "voice":
      return chatScenario(voiceChat)
    case "connect":
      return AppFeature.State(
        onboarding: ConnectionFeature.State(
          serverURL: "http://mac.tailnet:9119",
          token: "••••••••••••",
          status: .reachable(version: "0.16.0")
        )
      )
    default: // "chat"
      return chatScenario(heroChat)
    }
  }

  /// A chat scenario needs a home (so the nav stack has a root) plus one pushed chat.
  private static func chatScenario(_ chat: ChatFeature.State) -> AppFeature.State {
    AppFeature.State(home: sessionListState, path: StackState([chat]))
  }

  // MARK: Sessions

  private static let seededSessions: [Session] = {
    // Everyday life: planning, research, writing, travel — no dev workspaces, so the list
    // is grouped chronologically (a flat recency list under "Pinned").
    var sessions: [Session] = [
      ("s0", "Plan a long weekend in Lisbon", false),
      ("s1", "Summarize my unread newsletters", true),
      ("s2", "Draft a thank-you note to Sarah", false),
      ("s3", "Weekly meal plan & grocery list", false),
      ("s4", "Compare two health insurance plans", false),
      ("s5", "Birthday gift ideas for Mom", false),
    ].enumerated().map { idx, t in
      Session(
        id: t.0,
        title: t.1,
        updatedAt: Date(timeIntervalSince1970: 1_749_597_600 - Double(idx) * 7_200),
        startedAt: Date(timeIntervalSince1970: 1_749_597_600 - Double(idx) * 7_200),
        messageCount: 12,
        isActive: t.2
      )
    }
    // A cron-scheduled session → pulled into the always-on "Cron Jobs" section.
    sessions.append(
      Session(
        id: "cron0",
        title: "Morning news digest",
        updatedAt: Date(timeIntervalSince1970: 1_749_560_000),
        startedAt: Date(timeIntervalSince1970: 1_749_560_000),
        messageCount: 3,
        source: "cron"
      )
    )
    return sessions
  }()

  private static var sessionListState: SessionListFeature.State {
    SessionListFeature.State(
      connection: connection,
      sessions: IdentifiedArray(uniqueElements: seededSessions),
      now: now,
      pinnedIDs: ["s0"],
      groupingMode: .chronological
    )
  }

  // MARK: Chat transcripts

  private static func rowID(_ n: Int) -> UUID {
    UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012x", n))")!
  }

  /// Panel 1 — hero: a clean everyday Q&A (research / summarize) with one tool call.
  private static var heroChat: ChatFeature.State {
    var state = ChatFeature.State(
      connection: connection,
      title: "Weekend reading",
      transcript: IdentifiedArray(uniqueElements: [
        ChatRow(id: rowID(0), kind: .message(
          role: .user, text: "Summarize the three articles I saved about better sleep.", isComplete: true)),
        ChatRow(id: rowID(1), kind: .tool(
          name: "web_fetch", title: "Read 3 saved articles", state: .complete,
          detail: ToolDetail(resultText: "3 articles"), durationS: 1.1)),
        ChatRow(id: rowID(2), kind: .message(
          role: .assistant,
          text: "Here's the gist:\n\n- **Keep a steady schedule** — same sleep and wake time, even on weekends\n- **Wind down screens** 60–90 min before bed, and dim the lights\n- **Watch caffeine** — it has a ~6-hour half-life, so stop by early afternoon",
          isComplete: true)),
      ]),
      status: .ready
    )
    state.model = "claude-opus-4-8"
    state.usage = .init(contextUsed: 48_000, contextMax: 200_000, contextPercent: 24)
    return state
  }

  /// Panel 3 — "watch it work": the agent researching + acting across tools, live.
  private static var workChat: ChatFeature.State {
    var state = ChatFeature.State(
      connection: connection,
      title: "Lisbon trip",
      transcript: IdentifiedArray(uniqueElements: [
        ChatRow(id: rowID(0), kind: .message(
          role: .user,
          text: "Find 3 well-rated hotels in Lisbon under €150 and add the trip to my calendar.",
          isComplete: true)),
        ChatRow(id: rowID(1), kind: .tool(
          name: "web_search", title: "Searched hotels in Lisbon", state: .complete,
          detail: ToolDetail(resultText: "hotels"), durationS: 0.9)),
        ChatRow(id: rowID(2), kind: .tool(
          name: "web_fetch", title: "Compared 12 options by rating & price", state: .complete,
          detail: ToolDetail(resultText: "compared"), durationS: 1.6)),
        ChatRow(id: rowID(3), kind: .tool(
          name: "calendar", title: "Adding “Lisbon trip” to your calendar", state: .running,
          detail: nil, durationS: nil)),
        ChatRow(id: rowID(4), kind: .thinking(
          reasoning: "Shortlisting three places under €150 with the best reviews, then blocking the dates on your calendar.",
          status: "Updating calendar…", elapsedSeconds: 0, isComplete: false)),
      ]),
      status: .ready
    )
    state.thinkingSeconds = 7
    state.model = "claude-opus-4-8"
    state.usage = .init(contextUsed: 96_000, contextMax: 200_000, contextPercent: 48)
    return state
  }

  /// Panel 4 — voice input: the composer mid-recording with a live waveform (writing help).
  private static var voiceChat: ChatFeature.State {
    var state = ChatFeature.State(
      connection: connection,
      title: "Mom's birthday",
      transcript: IdentifiedArray(uniqueElements: [
        ChatRow(id: rowID(0), kind: .message(
          role: .user, text: "Help me write a warm birthday message for my mom.", isComplete: true)),
        ChatRow(id: rowID(1), kind: .message(
          role: .assistant,
          text: "Here's a start:\n\n“Happy birthday, Mom! Thank you for always believing in me — I hope your day is every bit as wonderful as you are.”\n\nWant it more playful, or short enough for a card?",
          isComplete: true)),
      ]),
      status: .ready
    )
    state.recording = .recording
    state.waveformLevels = [0.1, 0.35, 0.6, 0.8, 0.5, 0.25, 0.4, 0.7, 0.9, 0.55, 0.3, 0.15, 0.45, 0.65]
    state.recordingSeconds = 6
    state.model = "claude-opus-4-8"
    return state
  }
}
#endif
