import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

/// The root branch precedence the app shell renders (`AppFeature.State.rootScreen`). The
/// connection-failed screen (#62) is reachable purely by sitting between the `autoConnecting`
/// spinner and the onboarding fallback — reordering it would silently disable the whole feature
/// with every reducer and snapshot test still green, which is exactly what this pins.
///
/// Lives in the package, not the app target: the rule is pure state → enum, so it costs a
/// `swift test` millisecond rather than a simulator run.
struct AppRootScreenTests {
  private let connection = ServerConnection(baseURL: URL(string: "http://mac.tailnet:9119")!, token: "tok")

  private func state(
    home: Bool = false, autoConnecting: Bool = false, connectionFailed: Bool = false
  ) -> AppFeature.State {
    AppFeature.State(
      home: home ? SessionListFeature.State(connection: connection) : nil,
      autoConnecting: autoConnecting,
      connectionFailed: connectionFailed
        ? ConnectionFailedFeature.State(connection: connection, reason: .unreachable)
        : nil
    )
  }

  @Test func onboardingIsTheFallback() {
    #expect(state().rootScreen == .onboarding)
  }

  /// The whole point of the feature: with no home and no probe running, a populated slot must
  /// beat onboarding.
  @Test func connectionFailedBeatsOnboarding() {
    #expect(state(connectionFailed: true).rootScreen == .connectionFailed)
  }

  /// …but a probe in flight still shows the spinner (the slot is only populated after the
  /// probe fails, so this is belt-and-braces on the ordering).
  @Test func connectingBeatsConnectionFailed() {
    #expect(state(autoConnecting: true, connectionFailed: true).rootScreen == .connecting)
  }

  /// A live session list wins over everything — a retry screen must never render over it.
  @Test func homeBeatsEverything() {
    #expect(state(home: true, autoConnecting: true, connectionFailed: true).rootScreen == .home)
    #expect(state(home: true, connectionFailed: true).rootScreen == .home)
  }
}
