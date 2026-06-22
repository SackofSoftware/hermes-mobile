import HermesKit
import SwiftUI
import UIKit

/// Pushed details screen behind the Token segment's "Learn how to connect securely →"
/// disclosure. Static, honest guidance about *why* token mode is loopback-only and *how* to
/// expose a Hermes agent safely over a private network (Tailscale) rather than the public
/// internet. Mirrors the desktop's security note.
///
/// Scope: static copy + a single external Tailscale link. No Tailscale SDK, no network
/// detection — just words, a copy affordance on the commands, and one `Link`. The layout is a
/// custom card stack (not a stock `Form`) purely for presentation.
struct SecureConnectionInfoView: View {
  /// True when the server we probed advertises password login. Used to nudge the user back
  /// to the safer Password method rather than a static token.
  var passwordAvailable: Bool = false

  private let tailscaleURL = URL(string: "https://tailscale.com")!

  private static let brand = LinearGradient(
    colors: [.blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing
  )
  private static let tailscaleBrand = LinearGradient(
    colors: [.blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing
  )

  var body: some View {
    ScrollView {
      VStack(spacing: 20) {
        hero
        whyCard
        howCard
        tailnetCard
        tailscaleLink
        if passwordAvailable { passwordNudge }
      }
      .padding(20)
      .frame(maxWidth: .infinity)
    }
    .background(Color(.systemGroupedBackground))
    .navigationTitle("Connect securely")
    .navigationBarTitleDisplayMode(.inline)
  }

  // MARK: - Sections

  private var hero: some View {
    VStack(spacing: 14) {
      ZStack {
        Circle()
          .fill(Self.brand)
          .frame(width: 76, height: 76)
          .shadow(color: .blue.opacity(0.3), radius: 12, y: 6)
        Image(systemName: "lock.shield.fill")
          .font(.system(size: 34, weight: .semibold))
          .foregroundStyle(.white)
      }
      VStack(spacing: 6) {
        Text("Token access stays private")
          .font(.title2.weight(.bold))
          .multilineTextAlignment(.center)
        Text("""
        A session token is a master key to your agent. Here's how to use it without putting it \
        on the open internet.
        """)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      }
    }
    .padding(.top, 8)
    .padding(.horizontal, 4)
  }

  private var whyCard: some View {
    calloutCard(tint: .orange, icon: "exclamationmark.shield.fill", title: "Full, never-expiring access") {
      Text("""
      Anyone holding your token can act as you — indefinitely. That's why Hermes only accepts \
      token sign-in when the agent is bound to a trusted, private network, not the open internet.
      """)
    }
  }

  private var howCard: some View {
    card {
      cardHeader(icon: "terminal.fill", title: "Expose it safely", tint: .blue)
      stepRow(number: 1, text: "Bind the agent beyond loopback — but only inside a network you control:")
      CommandCard(command: "hermes serve --host 0.0.0.0 --insecure")
      stepRow(number: 2, text: "Set the shared token the dashboard and this app will use:")
      CommandCard(command: "export HERMES_DASHBOARD_SESSION_TOKEN=…")
    }
  }

  private var tailnetCard: some View {
    calloutCard(tint: .indigo, icon: "point.3.connected.trianglepath.dotted", title: "Your tailnet is the trust boundary") {
      Text("Every device that can reach the agent is one you've explicitly added. Never expose ")
        + Text("--insecure").font(.system(.subheadline, design: .monospaced)).foregroundColor(.primary)
        + Text(" to the public internet.")
    }
  }

  private var tailscaleLink: some View {
    Link(destination: tailscaleURL) {
      HStack(spacing: 14) {
        ZStack {
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Self.tailscaleBrand)
            .frame(width: 44, height: 44)
          Image(systemName: "network")
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(.white)
        }
        VStack(alignment: .leading, spacing: 2) {
          Text("Set up Tailscale")
            .font(.headline)
            .foregroundStyle(.primary)
          Text("Private addresses reachable only by your tailnet")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 8)
        Image(systemName: "arrow.up.forward")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.secondary)
      }
      .padding(16)
      .frame(maxWidth: .infinity)
      .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .strokeBorder(Color.blue.opacity(0.25), lineWidth: 1)
      )
    }
  }

  private var passwordNudge: some View {
    calloutCard(tint: .green, icon: "checkmark.seal.fill", title: "This server supports password login") {
      Text("Prefer ")
        + Text("Password").fontWeight(.semibold).foregroundColor(.primary)
        + Text(" sign-in — it uses short-lived, rotating session cookies instead of a permanent token.")
    }
  }

  // MARK: - Building blocks

  /// A plain rounded "surface" card.
  @ViewBuilder
  private func card(@ViewBuilder _ content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      content()
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
  }

  private func cardHeader(icon: String, title: String, tint: Color) -> some View {
    HStack(spacing: 10) {
      Image(systemName: icon)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(tint)
        .frame(width: 28, height: 28)
        .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      Text(title)
        .font(.headline)
      Spacer()
    }
  }

  /// A tinted, bordered callout: leading glyph chip + bold title + secondary body.
  @ViewBuilder
  private func calloutCard(
    tint: Color, icon: String, title: String, @ViewBuilder message: () -> some View
  ) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: icon)
        .font(.headline)
        .foregroundStyle(tint)
        .frame(width: 30, height: 30)
        .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.subheadline.weight(.semibold))
        message()
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .strokeBorder(tint.opacity(0.18), lineWidth: 1)
    )
  }

  private func stepRow(number: Int, text: String) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Text("\(number)")
        .font(.caption.weight(.bold))
        .foregroundStyle(.white)
        .frame(width: 20, height: 20)
        .background(Color.blue, in: Circle())
      Text(text)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
  }

  /// A monospaced, copy-friendly command chip with a `$` prompt and a copy button.
  private struct CommandCard: View {
    let command: String
    @State private var copied = false

    var body: some View {
      HStack(spacing: 10) {
        Text(verbatim: "$")
          .font(.system(.footnote, design: .monospaced))
          .foregroundStyle(.tertiary)
        Text(command)
          .font(.system(.footnote, design: .monospaced))
          .foregroundStyle(.primary)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
        Button {
          UIPasteboard.general.string = command
          withAnimation(.easeInOut(duration: 0.15)) { copied = true }
        } label: {
          Image(systemName: copied ? "checkmark" : "doc.on.doc")
            .font(.footnote.weight(.medium))
            .foregroundStyle(copied ? Color.green : Color.accentColor)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(copied ? "Copied" : "Copy command")
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
  }
}

#Preview("Password available") {
  NavigationStack {
    SecureConnectionInfoView(passwordAvailable: true)
  }
}

#Preview("Token only") {
  NavigationStack {
    SecureConnectionInfoView(passwordAvailable: false)
  }
}
