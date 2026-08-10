import ComposableArchitecture
import HermesKit
import SnapshotTesting
import SwiftUI
import XCTest

@testable import HermesMobile

/// The launch-time "can't reach the server" screen (#62). The three baselines pin the two
/// reason variants (which drive different copy) and the in-flight retry state (which swaps
/// the button label for a spinner).
final class ConnectionFailedSnapshotTests: SnapshotTestCase {
  private func store(
    url: String = "http://mac.tailnet:9119",
    reason: RESTError,
    isRetrying: Bool = false
  ) -> StoreOf<ConnectionFailedFeature> {
    Store(
      initialState: ConnectionFailedFeature.State(
        connection: ServerConnection(baseURL: URL(string: url)!, token: "t"),
        reason: reason,
        isRetrying: isRetrying
      )
    ) { ConnectionFailedFeature() }
  }

  /// Offline: "check Wi-Fi/cellular" copy — no point pointing the user at their VPN.
  func testConnectionFailedView_offline() {
    let view = ConnectionFailedView(store: store(reason: .offline))
    assertSnapshot(of: view, as: deviceImage())
  }

  /// Unreachable, with a long URL: the VPN/Tailscale hint, and the URL wrapped rather than
  /// truncated — naming the server is the screen's whole job. The guarantee is structural
  /// (the `Text` carries no `lineLimit`, so it can only grow); this baseline records what
  /// that looks like, and the fixture's hyphens mean it wraps on word boundaries.
  func testConnectionFailedView_unreachableLongURL() {
    let view = ConnectionFailedView(
      store: store(
        url: "http://very-long-machine-name.tail9f3c2b.ts.net:9119",
        reason: .unreachable
      )
    )
    assertSnapshot(of: view, as: deviceImage())
  }

  /// Retry in flight: the button swaps to a spinner and is disabled — while "Change server"
  /// and "Log Out", the two ways OFF this screen, stay enabled (a probe can run to
  /// URLSession's 60s default, and the foreground auto-retry arms it unasked).
  ///
  /// The indeterminate spinner is captured at whatever rotation the render server is at, so
  /// this one baseline allows a 1% pixel budget (measured drift: ~0.4%, all of it inside the
  /// spinner) — everything else on the screen is still asserted at the strict default.
  func testConnectionFailedView_retrying() {
    let view = ConnectionFailedView(store: store(reason: .unreachable, isRetrying: true))
    assertSnapshot(of: view, as: deviceImage(precision: 0.99))
  }
}
