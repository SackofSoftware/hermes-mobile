import ComposableArchitecture
import HermesKit
import SwiftUI
import UIKit

/// Settings sheet: server info, token re-paste/clear, manual reconnect, and a link to
/// the live connection debug log.
struct SettingsView: View {
  @Bindable var store: StoreOf<SettingsFeature>
  /// Presentation-only: the "how push works / install the plugin" info sheet. Pure view
  /// state — there's no reducer behavior behind it.
  @State private var showingPushGuide = false

  var body: some View {
    Form {
      Section("Server") {
        LabeledContent("URL", value: store.serverURLString)
      }

      Section {
        SecureField("Session token", text: $store.token)
          .textContentType(.password)
        Button("Save token") { store.send(.saveTokenTapped) }
          .disabled(!store.canSaveToken)
        if store.savedConfirmation {
          Label("Token saved", systemImage: "checkmark.circle")
            .foregroundStyle(.green).font(.footnote)
        }
      } header: {
        Text("Token")
      } footer: {
        Text("Re-paste the stable token if it changed on the server.")
      }

      Section("Connection") {
        Button("Reconnect") { store.send(.reconnectTapped) }
        NavigationLink {
          ConnectionDebugView(entries: store.log)
        } label: {
          LabeledContent("Debug log", value: "\(store.log.count)")
        }
      }

      Section {
        Picker("Chat transcript engine", selection: $store.chatRenderer) {
          ForEach(ChatRendererKind.allCases, id: \.self) { kind in
            Text(kind.displayName).tag(kind)
          }
        }
      } header: {
        Text("Experimental")
      } footer: {
        Text("Switches the chat transcript rendering engine. Experimental — reopen a chat to compare.")
      }

      Section {
        if store.pushAvailable {
          Toggle(
            "Notify me about approvals",
            isOn: Binding(
              get: { store.notificationsEnabled },
              set: { store.send(.notificationsToggled($0)) }
            )
          )
          if store.notificationsDenied {
            VStack(alignment: .leading, spacing: 4) {
              Label("Notifications are turned off", systemImage: "bell.slash")
                .foregroundStyle(.orange).font(.footnote)
              if let url = URL(string: UIApplication.openSettingsURLString) {
                Link("Enable in iOS Settings", destination: url)
                  .font(.footnote)
              }
            }
          }
          Button("Send test notification") { store.send(.sendTestPushTapped) }
            .disabled(store.testPushStatus == .sending)
          switch store.testPushStatus {
          case .idle:
            EmptyView()
          case .sending:
            Label("Sending…", systemImage: "paperplane")
              .foregroundStyle(.secondary).font(.footnote)
          case .sent:
            Label("Test notification sent", systemImage: "checkmark.circle")
              .foregroundStyle(.green).font(.footnote)
          case .failed:
            Label("Couldn't send test notification", systemImage: "exclamationmark.triangle")
              .foregroundStyle(.orange).font(.footnote)
          }
          Button("How push notifications work") { showingPushGuide = true }
            .font(.footnote)
        } else {
          Label("Notifications aren't available on this server", systemImage: "bell.slash")
            .foregroundStyle(.secondary).font(.footnote)
          Button("How to enable push notifications") { showingPushGuide = true }
        }
      } header: {
        Text("Notifications")
      } footer: {
        if store.pushAvailable {
          Text("Get a push when Hermes needs your approval, even while the app is closed.")
        } else {
          Text("Needs the hermes-push plugin running on your agent.")
        }
      }

      Section {
        Button("Clear token & disconnect", role: .destructive) {
          store.send(.clearTokenTapped)
        }
      } footer: {
        Text("Removes the token from the Keychain and returns to the connection screen.")
      }
    }
    .navigationTitle("Settings")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("Done") { store.send(.doneTapped) }
      }
    }
    .sheet(isPresented: $showingPushGuide) {
      PushSetupGuideView(
        onAskAgent: {
          showingPushGuide = false
          store.send(.askAgentToInstallTapped)
        },
        onLater: { showingPushGuide = false }
      )
    }
    .task { store.send(.task) }
  }
}
