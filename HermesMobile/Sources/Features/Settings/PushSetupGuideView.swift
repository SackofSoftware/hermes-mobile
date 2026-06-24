import SwiftUI
import UIKit

/// Static, presentation-only info sheet explaining how push notifications work and how to
/// install the `hermes-push` plugin on the user's own Hermes agent. There is no reducer
/// state behind it — it's presented via local `@State` from `SettingsView` (mirrors the
/// context-usage popover convention: pure presentation stays out of the reducer).
///
/// It deliberately talks about the **plugin only** — the relay/gateway is publisher infra
/// the user never has to know about.
struct PushSetupGuideView: View {
  @Environment(\.dismiss) private var dismiss

  /// Public repo for the plugin users install on their own agent.
  private static let pluginURL = URL(string: "https://github.com/goncharik/hermes-mobile-push-plugin")!
  private static let installCommand =
    "pip install git+https://github.com/goncharik/hermes-mobile-push-plugin.git"
  /// A ready-to-paste instruction the user can hand to their own agent to self-install.
  private static let installPrompt = """
    Please install the hermes-push plugin so I can receive push notifications on my phone. \
    Run: pip install git+https://github.com/goncharik/hermes-mobile-push-plugin.git — it's a \
    standard Hermes plugin (entry-point group "hermes_agent.plugins"). Then restart yourself \
    so the plugin loads and its REST routes mount.
    """

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
            text: "Notifications are triggered by a small plugin on your Hermes agent and relayed to Apple. Only a generic alert (e.g. “Approval needed”) leaves your server — your messages and data never do."
          )

          VStack(alignment: .leading, spacing: 8) {
            Label("Install the plugin", systemImage: "terminal")
              .font(.headline)
            Text("On the machine running your Hermes agent, install the plugin and restart the agent:")
              .font(.subheadline)
              .foregroundStyle(.secondary)
            CopyableBlock(text: Self.installCommand)

            Text("Or just ask your agent to install it — paste this prompt:")
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .padding(.top, 4)
            CopyableBlock(text: Self.installPrompt)
          }

          Link(destination: Self.pluginURL) {
            Label("View the plugin on GitHub", systemImage: "arrow.up.right.square")
          }
          .font(.body.weight(.medium))

          Text("Once the plugin is running, reopen Settings — the notifications toggle will appear.")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .navigationTitle("Push notifications")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
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

/// A monospaced box with a top-trailing copy button — mirrors the chat's `CodeBlockView`
/// (`doc.on.doc` → green `checkmark` on copy). Self-contained: the "copied" feedback is
/// local `@State` (this sheet has no reducer), and it copies via `UIPasteboard` directly
/// since copying is a pure view concern here.
private struct CopyableBlock: View {
  let text: String
  @State private var isCopied = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Text(text)
      .font(.system(.footnote, design: .monospaced))
      .textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(10)
      .padding(.trailing, 28) // leave room for the copy button
      .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
      .overlay(alignment: .topTrailing) {
        Button(action: copy) {
          Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
            .font(.caption.weight(.medium))
            .foregroundStyle(isCopied ? Color.green : Color.secondary)
            .padding(6)
            .background(.thinMaterial, in: .circle)
        }
        .buttonStyle(.plain)
        .padding(6)
        .accessibilityLabel(isCopied ? "Copied" : "Copy")
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isCopied)
      }
  }

  private func copy() {
    UIPasteboard.general.string = text
    isCopied = true
    Task {
      try? await Task.sleep(for: .seconds(2))
      isCopied = false
    }
  }
}

#Preview {
  PushSetupGuideView()
}
