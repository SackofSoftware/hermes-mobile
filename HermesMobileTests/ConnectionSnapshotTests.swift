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
