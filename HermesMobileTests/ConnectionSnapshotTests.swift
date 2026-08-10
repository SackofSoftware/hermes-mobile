import ComposableArchitecture
import HermesKit
import SnapshotTesting
import SwiftUI
import XCTest

@testable import HermesMobile

final class ConnectionSnapshotTests: SnapshotTestCase {
  func testConnectionView_idle() {
    let view = ConnectionView(
      store: Store(initialState: ConnectionFeature.State()) { ConnectionFeature() }
    )
    assertSnapshot(of: view, as: deviceImage())
  }

  func testConnectionView_reachable() {
    let view = ConnectionView(
      store: Store(
        initialState: ConnectionFeature.State(
          serverURL: "http://mac.tailnet:9119",
          token: "••••••••",
          status: .reachable(version: "0.16.0")
        )
      ) { ConnectionFeature() }
    )
    assertSnapshot(of: view, as: deviceImage())
  }

  /// Arrived here from the launch retry screen's *Change server*, which stashes that screen
  /// rather than discarding it: a "Back to the connection screen" row sits above everything
  /// else. It is gated on `canReturnToConnectionFailed`, so every other baseline in this suite
  /// (and every other route to onboarding) renders without it.
  func testConnectionView_returnToConnectionFailed() {
    let view = ConnectionView(
      store: Store(
        initialState: ConnectionFeature.State(
          serverURL: "http://mac.tailnet:9119",
          method: .password,
          capability: .passwordAvailable(provider: "basic", displayName: "Password"),
          status: .unreachable,
          canReturnToConnectionFailed: true
        )
      ) { ConnectionFeature() }
    )
    assertSnapshot(of: view, as: deviceImage())
  }

  /// Unreachable server: red failure footer plus the contextual "Need help setting up
  /// your agent?" link (shown only for `.unreachable` / `.notHermes` — the stuck moment).
  func testConnectionView_unreachable() {
    let view = ConnectionView(
      store: Store(
        initialState: ConnectionFeature.State(
          serverURL: "http://mac.tailnet:9119",
          status: .unreachable
        )
      ) { ConnectionFeature() }
    )
    assertSnapshot(of: view, as: deviceImage())
  }

  /// Not-Hermes server: orange footer plus the same contextual setup-help link — the
  /// second of the two `statusFooter` branches that render it.
  func testConnectionView_notHermes() {
    let view = ConnectionView(
      store: Store(
        initialState: ConnectionFeature.State(
          serverURL: "http://mac.tailnet:9119",
          status: .notHermes
        )
      ) { ConnectionFeature() }
    )
    assertSnapshot(of: view, as: deviceImage())
  }

  /// Auth failure: NO setup-help link — those users are past setup (pins the negative
  /// side of the `.unreachable`/`.notHermes` gate).
  func testConnectionView_invalidCredentials() {
    let view = ConnectionView(
      store: Store(
        initialState: ConnectionFeature.State(
          serverURL: "http://mac.tailnet:9119",
          username: "you",
          method: .password,
          status: .invalidCredentials
        )
      ) { ConnectionFeature() }
    )
    assertSnapshot(of: view, as: deviceImage())
  }

  func testConnectionView_invalidToken() {
    let view = ConnectionView(
      store: Store(
        initialState: ConnectionFeature.State(
          serverURL: "http://mac.tailnet:9119",
          token: "wrong",
          status: .invalidToken
        )
      ) { ConnectionFeature() }
    )
    assertSnapshot(of: view, as: deviceImage())
  }
}
