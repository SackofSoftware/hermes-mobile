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

      // Providers: which credentials the agent actually holds, what they've used, and a
      // way to add the ones it doesn't. Hidden entirely on agents without the
      // hermes-account-usage plugin — an empty section would just raise questions.
      if !store.providerUsage.isEmpty {
        Section {
          ForEach(store.providerUsage) { usage in
            providerRow(usage)
          }
        } header: {
          Text("Providers")
        } footer: {
          Text("Keys are stored on your agent, never on this device.")
        }
      }

      // Local Ollama. Scanned on demand: the agent probes loopback + online tailnet
      // peers, so this is a deliberate button rather than something that fires every
      // time Settings opens.
      Section {
        Button {
          store.send(.scanOllamaTapped)
        } label: {
          HStack {
            Label("Scan for local Ollama", systemImage: "magnifyingglass")
            Spacer()
            if store.ollamaScanState == .scanning { ProgressView().controlSize(.mini) }
          }
        }
        .disabled(store.ollamaScanState == .scanning)

        ForEach(store.ollamaServers) { server in
          VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
              ProviderIconView(provider: "ollama", model: nil, size: 16)
              Text(server.host).font(.callout.weight(.medium))
              Spacer()
              Button("Use") { store.send(.useOllamaTapped(baseURL: server.baseURL)) }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            // Only chat-capable models are listed; embedding models answer the same
            // endpoint but can't hold a conversation, so offering them would mislead.
            ForEach(server.chatModels) { model in
              HStack {
                Text(model.name).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let gb = model.sizeGB {
                  Text("\(gb, specifier: "%.1f") GB").font(.caption2).foregroundStyle(.tertiary)
                }
              }
            }
            let hidden = server.models.count - server.chatModels.count
            if hidden > 0 {
              Text("\(hidden) embedding model\(hidden == 1 ? "" : "s") not shown")
                .font(.caption2).foregroundStyle(.tertiary)
            }
          }
          .padding(.vertical, 2)
        }

        switch store.ollamaScanState {
        case let .done(found) where found == 0:
          Text("No Ollama servers reachable from your agent.")
            .font(.caption).foregroundStyle(.secondary)
        case let .failed(message):
          Text(message).font(.caption).foregroundStyle(.red)
        default:
          EmptyView()
        }
      } header: {
        Text("Local models")
      } footer: {
        Text("Looks for Ollama on the agent itself and on your online Tailscale devices.")
      }

      // Only offered when the agent supports session deletion — otherwise Archive is the
      // only destructive action and the choice would be meaningless.
      if store.deleteSupported {
        Section {
          Picker(
            "Default swipe action",
            selection: Binding(
              get: { store.defaultSwipeAction },
              set: { store.send(.defaultSwipeActionChanged($0)) }
            )
          ) {
            Text("Archive").tag(SessionSwipeAction.archive)
            Text("Delete").tag(SessionSwipeAction.delete)
          }
        } header: {
          Text("Session list")
        } footer: {
          Text("The action a full swipe on a session row triggers. The long-press menu always offers both.")
        }
      }

      Section {
        // Plugin update, offered above the toggle because an out-of-date plugin sends pushes
        // the user is actively complaining about. Shown whether or not push is currently
        // available — an installed-but-disabled plugin is still worth updating.
        if store.pluginUpdateAvailable {
          VStack(alignment: .leading, spacing: 4) {
            Label("Plugin update available", systemImage: "arrow.down.circle")
              .font(.subheadline.weight(.semibold))
            Text(pluginUpdateExplanation)
              .font(.footnote).foregroundStyle(.secondary)
          }
          Button("Update plugin") { store.send(.updatePluginTapped) }
            .disabled(store.pluginUpdate == .updating)
        } else if store.pluginUpdateNeedsManualSteps {
          // Out of date but the agent can't pull it (pip install / hand-copied directory), so
          // a button here would only 400. Route to the guide, which offers the chat prompt.
          VStack(alignment: .leading, spacing: 4) {
            Label("Plugin update available", systemImage: "arrow.down.circle")
              .font(.subheadline.weight(.semibold))
            Text("\(pluginUpdateExplanation) This copy can't be updated from the app — ask your agent to update it.")
              .font(.footnote).foregroundStyle(.secondary)
          }
          Button("How to update the plugin") { showingPushGuide = true }
            .font(.footnote)
        }
        switch store.pluginUpdate {
        case .idle:
          EmptyView()
        case .updating:
          Label("Updating…", systemImage: "arrow.triangle.2.circlepath")
            .foregroundStyle(.secondary).font(.footnote)
        case .updated:
          // A pull only changes files on disk — the running agent keeps the old code loaded.
          // This restart notice is the whole point of the success state; don't soften it.
          Label(
            "Plugin updated. Restart your Hermes agent to apply it.",
            systemImage: "exclamationmark.arrow.triangle.2.circlepath"
          )
          .foregroundStyle(.orange).font(.footnote)
        case .alreadyCurrent:
          Label("Plugin is already up to date", systemImage: "checkmark.circle")
            .foregroundStyle(.green).font(.footnote)
        case let .failed(reason):
          Label(reason, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.orange).font(.footnote)
        }

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
        // Installed → the sheet drops the "Later" snooze and asks the agent to UPDATE rather
        // than install. It is never purely informational: an installed-but-outdated plugin is
        // exactly the case that needs an action here.
        pluginInstalled: store.pushAvailable,
        onAskAgent: {
          showingPushGuide = false
          store.send(.askAgentToInstallTapped)
        },
        onLater: { showingPushGuide = false }
      )
    }
    .task { store.send(.task) }
  }

  /// Why the update matters, naming both versions when the agent reported one. Kept in the
  /// view because it is pure display copy — the decision to show it lives in the reducer.
  private var pluginUpdateExplanation: String {
    let latest = PushSetup.minimumPluginVersion
    let reason = "Older versions send a “Turn complete” push each time a delegated subagent finishes."
    guard let installed = store.pushPlugin?.version else {
      return "Update to \(latest). \(reason)"
    }
    return "Installed \(installed), latest \(latest). \(reason)"
  }

  // MARK: - Providers

  /// One provider: usage when it's set up, a way to set it up when it isn't.
  @ViewBuilder
  private func providerRow(_ usage: ProviderUsage) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        ProviderIconView(provider: usage.provider, model: nil, size: 18)
        Text(Self.providerLabel(usage.provider))
          .font(.body)
        if let plan = usage.plan, !plan.isEmpty {
          Text(plan)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
        }
        Spacer()
        if usage.configured {
          Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
      }

      if usage.configured {
        // Usage windows: a bar per window with the percentage USED and when it resets.
        ForEach(usage.windows) { window in
          usageWindowRow(window)
        }
        // Free-form agent lines (OpenRouter balance/spend, banked resets).
        ForEach(Array(usage.details.enumerated()), id: \.offset) { _, detail in
          Text(detail).font(.caption).foregroundStyle(.secondary)
        }
      } else {
        notConfiguredControls(usage)
      }
    }
    .padding(.vertical, 2)
  }

  /// A used-percentage bar plus a relative reset time computed HERE, from the ISO date —
  /// the server deliberately doesn't send "resets in 2h" because that string goes stale.
  @ViewBuilder
  private func usageWindowRow(_ window: ProviderUsage.Window) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack {
        Text(window.label).font(.caption).foregroundStyle(.secondary)
        Spacer()
        if let used = window.usedPercent {
          Text("\(Int(used.rounded()))% used")
            .font(.caption.weight(.medium))
            .foregroundStyle(used >= 90 ? .red : .secondary)
        }
      }
      if let used = window.usedPercent {
        ProgressView(value: min(max(used / 100, 0), 1))
          .tint(used >= 90 ? .red : Color.hermesAccent)
      }
      if let reset = window.resetAt, let date = Self.parseDate(reset) {
        Text("Resets \(date, format: .relative(presentation: .named))")
          .font(.caption2).foregroundStyle(.tertiary)
      }
    }
  }

  /// Setup affordance for a provider with no credential. API-key providers get an inline
  /// field; OAuth ones get an explanation, because a device-code sign-in can't be driven
  /// from the phone and a text field would be a dead end.
  @ViewBuilder
  private func notConfiguredControls(_ usage: ProviderUsage) -> some View {
    if let envKey = SettingsFeature.envKey(forProvider: usage.provider) {
      if store.editingKeyProvider == usage.provider {
        SecureField(envKey, text: Binding(
          get: { store.editingKeyValue },
          set: { store.send(.keyValueChanged($0)) }
        ))
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .font(.callout.monospaced())
        HStack {
          Button("Save") { store.send(.saveKeyTapped) }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(store.editingKeyValue.isEmpty || store.keySaveStatus == .saving)
          Button("Cancel") { store.send(.editKeyTapped(provider: nil)) }
            .controlSize(.small)
        }
        switch store.keySaveStatus {
        case .saving:
          Text("Saving…").font(.caption).foregroundStyle(.secondary)
        case let .failed(message):
          Text(message).font(.caption).foregroundStyle(.red)
        case .saved, .idle:
          EmptyView()
        }
      } else {
        Button("Add API key") { store.send(.editKeyTapped(provider: usage.provider)) }
          .font(.callout)
          .controlSize(.small)
      }
    } else {
      // openai-codex, nous, … — OAuth only.
      Text("Sign in from a terminal on the agent: hermes auth add \(usage.provider)")
        .font(.caption)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    }
  }

  /// Display name for a provider slug.
  static func providerLabel(_ provider: String) -> String {
    switch provider.lowercased() {
    case "openai-codex": return "OpenAI Codex"
    case "openrouter": return "OpenRouter"
    case "anthropic": return "Anthropic"
    case "openai": return "OpenAI"
    case "xai", "grok": return "xAI"
    case "google", "gemini": return "Google"
    default: return provider.capitalized
    }
  }

  /// Parse the ISO-8601 the plugin sends. Hermes emits a space-separated
  /// "2026-08-30 18:15:49+00:00" rather than strict RFC 3339, so try both.
  static func parseDate(_ raw: String) -> Date? {
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = iso.date(from: raw) { return d }
    iso.formatOptions = [.withInternetDateTime]
    if let d = iso.date(from: raw) { return d }
    let fallback = DateFormatter()
    fallback.locale = Locale(identifier: "en_US_POSIX")
    fallback.dateFormat = "yyyy-MM-dd HH:mm:ssXXXXX"
    if let d = fallback.date(from: raw) { return d }
    fallback.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSXXXXX"
    return fallback.date(from: raw)
  }
}
