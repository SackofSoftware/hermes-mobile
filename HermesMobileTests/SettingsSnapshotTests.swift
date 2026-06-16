import ComposableArchitecture
import HermesKit
import SnapshotTesting
import SwiftUI
import XCTest

@testable import HermesMobile

final class SettingsSnapshotTests: SnapshotTestCase {
  func testSettingsView() {
    var initial = SettingsFeature.State(connection: connection)
    initial.log = [
      GatewayLogEntry(id: 0, type: "gateway.ready", summary: ""),
      GatewayLogEntry(id: 1, type: "message.delta", summary: "Here's the gist"),
    ]
    let view = NavigationStack {
      SettingsView(
        store: Store(initialState: initial) { SettingsFeature() } withDependencies: {
          $0.debugLog = .testValue // inert stream for a deterministic render
        }
      )
    }
    assertSnapshot(of: view, as: deviceImage())
  }

  func testConnectionDebugView() {
    let view = NavigationStack {
      ConnectionDebugView(entries: [
        GatewayLogEntry(id: 0, type: "gateway.ready", summary: ""),
        GatewayLogEntry(id: 1, type: "tool.start", summary: "read_file"),
        GatewayLogEntry(id: 2, type: "message.delta", summary: "WebSocket JSON-RPC at /api/ws"),
        GatewayLogEntry(id: 3, type: "status.update", summary: "[lifecycle] thinking…"),
      ])
    }
    assertSnapshot(of: view, as: deviceImage())
  }
}
