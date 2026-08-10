import XCTest

@testable import HermesMobile

/// The root branch precedence in `AppView.content`. The connection-failed screen (#62) is
/// reachable purely by sitting between the `autoConnecting` spinner and the onboarding
/// fallback — reordering it would silently disable the whole feature with every reducer and
/// snapshot test still green, which is exactly what this pins.
final class AppViewRootScreenTests: XCTestCase {
  private func resolve(
    home: Bool = false, autoConnecting: Bool = false, connectionFailed: Bool = false
  ) -> AppView.RootScreen {
    .resolve(hasHome: home, autoConnecting: autoConnecting, hasConnectionFailed: connectionFailed)
  }

  func testOnboardingIsTheFallback() {
    XCTAssertEqual(resolve(), .onboarding)
  }

  /// The whole point of the feature: with no home and no probe running, a populated slot must
  /// beat onboarding.
  func testConnectionFailedBeatsOnboarding() {
    XCTAssertEqual(resolve(connectionFailed: true), .connectionFailed)
  }

  /// …but a probe in flight still shows the spinner (the slot is only populated after the
  /// probe fails, so this is belt-and-braces on the ordering).
  func testConnectingBeatsConnectionFailed() {
    XCTAssertEqual(resolve(autoConnecting: true, connectionFailed: true), .connecting)
  }

  /// A live session list wins over everything — a retry screen must never render over it.
  func testHomeBeatsEverything() {
    XCTAssertEqual(resolve(home: true, autoConnecting: true, connectionFailed: true), .home)
    XCTAssertEqual(resolve(home: true, connectionFailed: true), .home)
  }
}
