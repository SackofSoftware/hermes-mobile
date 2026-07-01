import HermesKit
import SwiftUI

/// Presentation-only info sheet explaining how push notifications work and offering two
/// actions: ask the agent to install the `hermes-push` plugin (pre-fills a new chat), or
/// snooze ("Later"). A small text link opens the plugin's GitHub page.
///
/// It deliberately talks about the **plugin only** — the relay/gateway is publisher infra
/// the user never has to know about. The two actions are surfaced as closures so both call
/// sites (the sessions-list auto-present and Settings) reuse the same view.
struct PushSetupGuideView: View {
  @Environment(\.dismiss) private var dismiss

  /// When the plugin is already installed/available, the sheet is purely informational:
  /// the install actions (Ask agent / Later) are hidden.
  let pluginInstalled: Bool
  /// Open a new chat with the install prompt pre-filled (the caller dismisses + routes).
  let onAskAgent: () -> Void
  /// Snooze the prompt (the caller dismisses + persists the backoff).
  let onLater: () -> Void

  private static let pluginURL = URL(string: PushSetup.pluginURLString)!

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          header

          point(
            "How it works",
            icon: "bell.badge",
            text: "Hermes can ping you when your agent needs you — like an approval request — even while the app is closed."
          )

          point(
            "It runs on your own agent",
            icon: "lock.shield",
            text: "Notifications come from a small plugin on your own Hermes agent, relayed to Apple. Only a generic alert (e.g. “Approval needed”) leaves your server — your messages and data never do."
          )

          if !pluginInstalled {
            VStack(spacing: 12) {
              Button {
                onAskAgent()
              } label: {
                Label("Ask agent to install plugin", systemImage: "sparkles")
                  .frame(maxWidth: .infinity)
              }
              .buttonStyle(.borderedProminent)
              .controlSize(.large)

              Button("Later") { onLater() }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
            }
            .padding(.top, 4)
          }

          Link("View the plugin on GitHub", destination: Self.pluginURL)
            .font(.footnote)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .navigationTitle("Push notifications")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close") { dismiss() }
        }
      }
    }
  }

  private var header: some View {
    HStack(spacing: 12) {
      Image(systemName: "bell.badge.fill")
        .font(.largeTitle)
        .foregroundStyle(.tint)
      Text("Get pinged when your agent needs you.")
        .font(.title3.weight(.semibold))
    }
  }

  private func point(_ title: String, icon: String, text: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Label(title, systemImage: icon).font(.headline)
      Text(text)
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
  }
}

#Preview("Not installed") {
  PushSetupGuideView(pluginInstalled: false, onAskAgent: {}, onLater: {})
}

#Preview("Installed") {
  PushSetupGuideView(pluginInstalled: true, onAskAgent: {}, onLater: {})
}
