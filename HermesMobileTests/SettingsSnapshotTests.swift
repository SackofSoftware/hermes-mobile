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

  /// Older agent without `DELETE /api/sessions/{id}` — the "Default swipe action" picker
  /// section must be hidden entirely (Archive is the only destructive action, so the
  /// choice would be meaningless). The default-state snapshot above shows it.
  func testSettingsView_deleteUnsupported() {
    var initial = SettingsFeature.State(connection: connection)
    initial.deleteSupported = false
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

  /// Notifications enabled: toggle on, push available, no test sent yet.
  func testSettingsNotificationsEnabled() {
    let initial = SettingsFeature.State(
      connection: connection,
      pushAvailable: true,
      notificationsEnabled: true
    )
    let view = NavigationStack {
      SettingsView(
        store: Store(initialState: initial) { SettingsFeature() } withDependencies: {
          $0.debugLog = .testValue
          $0.push = PushClient.inMemory(granted: true, status: .authorized).client
        }
      )
    }
    assertSnapshot(of: view, as: deviceImage())
  }

  /// Push not available on this server (plugin missing) → "not available" note, no controls.
  func testSettingsNotificationsUnavailable() {
    let initial = SettingsFeature.State(
      connection: connection,
      pushAvailable: false
    )
    let view = NavigationStack {
      SettingsView(
        store: Store(initialState: initial) { SettingsFeature() } withDependencies: {
          $0.debugLog = .testValue
          $0.push = PushClient.inMemory(granted: false, status: .notDetermined).client
        }
      )
    }
    assertSnapshot(of: view, as: deviceImage())
  }

  /// Test notification just sent → confirmation label.
  func testSettingsNotificationsTestSent() {
    let initial = SettingsFeature.State(
      connection: connection,
      pushAvailable: true,
      notificationsEnabled: true,
      testPushStatus: .sent
    )
    let view = NavigationStack {
      SettingsView(
        store: Store(initialState: initial) { SettingsFeature() } withDependencies: {
          $0.debugLog = .testValue
          $0.push = PushClient.inMemory(granted: true, status: .authorized).client
        }
      )
    }
    assertSnapshot(of: view, as: deviceImage())
  }

  /// An outdated, git-updatable plugin → the update row with the one-tap button.
  func testSettingsPluginUpdateAvailable() {
    let initial = SettingsFeature.State(
      connection: connection,
      pushAvailable: true,
      notificationsEnabled: true,
      pushPlugin: PushPluginInfo(status: .ready, version: "0.1.0", canUpdateGit: true)
    )
    let view = NavigationStack {
      SettingsView(
        store: Store(initialState: initial) { SettingsFeature() } withDependencies: {
          $0.debugLog = .testValue
          $0.push = PushClient.inMemory(granted: true, status: .authorized).client
        }
      )
    }
    assertSnapshot(of: view, as: deviceImage())
  }

  /// After a successful pull — the RESTART notice, which is the whole point of that state.
  func testSettingsPluginUpdatedNeedsRestart() {
    let initial = SettingsFeature.State(
      connection: connection,
      pushAvailable: true,
      notificationsEnabled: true,
      pushPlugin: PushPluginInfo(status: .ready, version: "0.1.0", canUpdateGit: true),
      pluginUpdate: .updated
    )
    let view = NavigationStack {
      SettingsView(
        store: Store(initialState: initial) { SettingsFeature() } withDependencies: {
          $0.debugLog = .testValue
          $0.push = PushClient.inMemory(granted: true, status: .authorized).client
        }
      )
    }
    assertSnapshot(of: view, as: deviceImage())
  }

  /// Outdated but not a git checkout → no button, pointer to the guide instead.
  func testSettingsPluginUpdateNeedsManualSteps() {
    let initial = SettingsFeature.State(
      connection: connection,
      pushAvailable: true,
      notificationsEnabled: true,
      pushPlugin: PushPluginInfo(status: .ready, version: "0.1.0", canUpdateGit: false)
    )
    let view = NavigationStack {
      SettingsView(
        store: Store(initialState: initial) { SettingsFeature() } withDependencies: {
          $0.debugLog = .testValue
          $0.push = PushClient.inMemory(granted: true, status: .authorized).client
        }
      )
    }
    assertSnapshot(of: view, as: deviceImage())
  }

  /// The "how push works" info sheet, plugin NOT installed — install action + Later snooze.
  func testPushSetupGuideView() {
    let view = PushSetupGuideView(pluginInstalled: false, onAskAgent: {}, onLater: {})
    assertSnapshot(of: view, as: deviceImage())
  }

  /// Plugin already installed — the action becomes "update" and the Later snooze drops away
  /// (there is no nag to snooze; the sheet was opened deliberately from Settings).
  func testPushSetupGuideView_installed() {
    let view = PushSetupGuideView(pluginInstalled: true, onAskAgent: {}, onLater: {})
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
