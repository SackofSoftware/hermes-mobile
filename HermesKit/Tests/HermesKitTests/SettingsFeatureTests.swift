import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

@MainActor
struct SettingsFeatureTests {
  private let connection = ServerConnection(baseURL: URL(string: "http://mac.tailnet:9119")!, token: "tok")

  @Test func clearTokenDeletesAndEmitsDisconnect() async {
    let deleted = LockIsolated(false)
    let preferences = PreferencesClient.inMemory()
    preferences.saveServerURL("http://mac.tailnet:9119")
    preferences.savePinnedIDs(["s1"])
    preferences.saveSeenCounts(["s1": 4])
    preferences.saveGroupingMode(.chronological)
    preferences.saveSelectedProfileID("staging")
    let store = TestStore(initialState: SettingsFeature.State(connection: connection)) {
      SettingsFeature()
    } withDependencies: {
      // Logout deletes the full session (token + any gated cookies), not just the token.
      $0.keychain.deleteSession = { @Sendable in deleted.setValue(true) }
      $0.preferences = preferences
      $0.dismiss = DismissEffect {}
    }

    await store.send(.clearTokenTapped)
    await store.receive(\.delegate.disconnect)
    #expect(deleted.value)
    #expect(preferences.loadServerURL() == nil) // logout forgets the server URL too
    #expect(preferences.loadPinnedIDs() == []) // pins are per-server — cleared on logout
    #expect(preferences.loadSeenCounts() == [:]) // unread state cleared too
    #expect(preferences.loadGroupingMode() == .workspace) // grouping pref reset on logout
    #expect(preferences.loadSelectedProfileID() == nil) // selected profile cleared on logout
  }

  @Test func reconnectEmitsReconnectDelegate() async {
    let store = TestStore(initialState: SettingsFeature.State(connection: connection)) {
      SettingsFeature()
    } withDependencies: {
      $0.dismiss = DismissEffect {}
    }

    await store.send(.reconnectTapped)
    await store.receive(\.delegate.reconnect)
  }

  @Test func saveTokenPersistsAndEmitsTokenSaved() async {
    let saved = LockIsolated<String?>(nil)
    let store = TestStore(initialState: SettingsFeature.State(connection: connection)) {
      SettingsFeature()
    } withDependencies: {
      $0.keychain.saveToken = { @Sendable token in saved.setValue(token) }
    }

    // Edit the token so it differs from the stored one.
    await store.send(\.binding.token, "newtok") {
      $0.token = "newtok"
      $0.savedConfirmation = false
    }
    await store.send(.saveTokenTapped) {
      $0.connection.token = "newtok"
      $0.savedConfirmation = true
    }
    await store.receive(\.delegate.tokenSaved)
    #expect(saved.value == "newtok")
  }

  @Test func saveTokenNoOpWhenUnchanged() async {
    let store = TestStore(initialState: SettingsFeature.State(connection: connection)) {
      SettingsFeature()
    }
    // token == connection.token → canSaveToken is false → no effect.
    #expect(!store.state.canSaveToken)
    await store.send(.saveTokenTapped)
  }

  @Test func taskStreamsDebugLogEntries() async {
    let entries = [
      GatewayLogEntry(id: 0, type: "gateway.ready", summary: ""),
      GatewayLogEntry(id: 1, type: "message.delta", summary: "Hello"),
    ]
    let store = TestStore(initialState: SettingsFeature.State(connection: connection)) {
      SettingsFeature()
    } withDependencies: {
      $0.debugLog.stream = { @Sendable in
        AsyncStream { continuation in
          continuation.yield(entries)
          continuation.finish()
        }
      }
    }

    await store.send(.task)
    await store.receive(\.logUpdated) {
      $0.log = entries
    }
  }
}
