import HermesKit
import SwiftUI

/// Pushed details screen behind the Token segment's "Learn how to connect securely →"
/// disclosure. Static, honest guidance about *why* token mode is loopback-only and *how* to
/// expose a Hermes agent safely over a private network (Tailscale) rather than the public
/// internet. Mirrors the desktop's security note.
///
/// Scope: static copy + a single external Tailscale link. No Tailscale SDK, no network
/// detection — just words and one `Link`.
struct SecureConnectionInfoView: View {
  /// True when the server we probed advertises password login. Used to nudge the user back
  /// to the safer Password method rather than a static token.
  var passwordAvailable: Bool = false

  private let tailscaleURL = URL(string: "https://tailscale.com")!

  var body: some View {
    Form {
      Section {
        Text("""
        A session token grants **full, never-expiring access** to your agent. Because anyone \
        holding it can act as you, Hermes only accepts token sign-in when the agent is bound \
        to a trusted, private network — not the open internet.
        """)
      } header: {
        Text("Why token mode is private-network only")
      }

      Section {
        Text("""
        Run the agent so it listens beyond loopback, but only inside a network you control:
        """)
        codeBlock("hermes serve --host 0.0.0.0 --insecure")
        Text("Set the shared token the dashboard and this app will use:")
        codeBlock("export HERMES_DASHBOARD_SESSION_TOKEN=…")
        Text("""
        The trust boundary is your **tailnet** (or equivalent VPN): every device that can \
        reach the agent is one you've explicitly added. Never expose `--insecure` to the \
        public internet.
        """)
      } header: {
        Text("How to expose it safely")
      }

      Section {
        Link(destination: tailscaleURL) {
          Label("Set up Tailscale", systemImage: "arrow.up.forward.app")
        }
      } header: {
        Text("Private network")
      } footer: {
        Text("Tailscale gives every device a private address reachable only by your tailnet.")
      }

      if passwordAvailable {
        Section {
          Label {
            Text("This server supports password login — prefer **Password** sign-in, which "
              + "uses short-lived, rotating session cookies instead of a permanent token.")
          } icon: {
            Image(systemName: "lock.shield")
              .foregroundStyle(.green)
          }
          .font(.footnote)
        }
      }
    }
    .navigationTitle("Connect securely")
    .navigationBarTitleDisplayMode(.inline)
  }

  /// A monospaced, copy-friendly command line. Kept inline (no separate component) — this is
  /// the only place it's used.
  @ViewBuilder
  private func codeBlock(_ text: String) -> some View {
    Text(text)
      .font(.system(.footnote, design: .monospaced))
      .textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(8)
      .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 6))
  }
}

#Preview {
  NavigationStack {
    SecureConnectionInfoView(passwordAvailable: true)
  }
}
