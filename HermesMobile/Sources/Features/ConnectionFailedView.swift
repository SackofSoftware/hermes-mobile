import ComposableArchitecture
import HermesKit
import SwiftUI

/// Shown instead of onboarding when **launch auto-connect** fails for a reason unrelated to
/// the stored credentials. They're still good, so the screen never asks for them again — it
/// names the server it couldn't reach, says why, and offers a Retry. **Change server** is the
/// non-destructive way out when the agent moved host/port (it lands on prefilled onboarding);
/// **Log Out** — behind a confirmation — abandons the session via the full-logout recipe in
/// `AppFeature`.
///
/// It also carries a tertiary link to `AgentSetupGuideView`, the app's single connection-help
/// surface: launch transport failures no longer pass through onboarding at all, and this
/// screen shows exactly the failures the guide explains (a host-header 400, a 404 from a route
/// that moved, a `.decoding` reply that "doesn't look like Hermes"). Presentation is view-local
/// `@State` — the same way the login screen does it — so nothing about a sheet reaches the
/// reducer.
struct ConnectionFailedView: View {
  @Bindable var store: StoreOf<ConnectionFailedFeature>

  @State private var showsSetupGuide = false

  var body: some View {
    // Scrolls so the buttons stay reachable at accessibility Dynamic Type sizes; the
    // `minHeight` keeps the default-size layout (title centred, buttons at the bottom)
    // pixel-identical to a plain `VStack`.
    GeometryReader { proxy in
      ScrollView {
        content
          .frame(maxWidth: .infinity, minHeight: proxy.size.height)
      }
      .scrollBounceBehavior(.basedOnSize)
    }
    .confirmationDialog(
      $store.scope(state: \.confirmationDialog, action: \.confirmationDialog)
    )
    .sheet(isPresented: $showsSetupGuide) {
      AgentSetupGuideView()
    }
  }

  private var content: some View {
    VStack(spacing: 24) {
      Spacer(minLength: 0)

      Image(systemName: "wifi.exclamationmark")
        .font(.system(size: 56, weight: .light))
        .foregroundStyle(.orange)
        .accessibilityHidden(true)

      VStack(spacing: 12) {
        Text("Can’t reach the server")
          .font(.title2.weight(.semibold))
          .multilineTextAlignment(.center)

        // Monospaced and deliberately UNCAPPED (no `lineLimit`): a long tailnet host with no
        // break opportunities must wrap rather than truncate — the URL is the whole point of
        // the screen ("which server?"), so an ellipsis would drop the only fact it carries.
        Text(store.serverURLText)
          .font(.footnote.monospaced())
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)

        // Capped, unlike the URL above: this line can quote a server-supplied `detail`, and
        // the three escape routes sit BELOW it inside the `ScrollView`. The reducer already
        // clamps the quote (`ConnectionFailedFeature.State.sanitizedServerDetail`); this is
        // the belt-and-braces half, so no reason string can ever push Retry off the screen.
        Text(store.reasonText)
          .font(.callout)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .lineLimit(6)
      }
      .padding(.horizontal, 8)

      Spacer(minLength: 0)

      VStack(spacing: 12) {
        Button {
          store.send(.retryTapped)
        } label: {
          // Fixed-height container so swapping the label for a spinner doesn't make the
          // button (and everything above it) jump.
          Group {
            if store.isRetrying {
              ProgressView()
                .progressViewStyle(.circular)
            } else {
              Text("Retry")
            }
          }
          .frame(maxWidth: .infinity, minHeight: 22)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(store.isRetrying)
        .accessibilityLabel(store.isRetrying ? "Retrying" : "Retry")

        // The escape hatch for "the agent moved": editing the URL must not cost a logout.
        // Deliberately NOT disabled while retrying — a probe can run up to URLSession's 60s
        // default, and the foreground auto-retry arms it without the user asking, so the two
        // ways off this screen must never be greyed out by it.
        // The full-width frame goes on the LABEL, not outside `.buttonStyle` — a bordered
        // button hugs its label, so an outer `.frame(maxWidth: .infinity)` only stretches the
        // (untappable) layout box around a narrow pill.
        Button {
          store.send(.changeServerTapped)
        } label: {
          Text("Change server")
            .frame(maxWidth: .infinity, minHeight: 22)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)

        // Tertiary, above the destructive one: the failures this screen reports are the
        // ones the guide answers (host-header 400, a moved route's 404, a reply that
        // doesn't look like Hermes), and reaching help must not require a detour through
        // Change server hoping onboarding's re-probe renders the footer link.
        Button("Need help setting up your agent?") {
          showsSetupGuide = true
        }
        .buttonStyle(.borderless)
        .font(.footnote)

        Button("Log Out") {
          store.send(.logoutButtonTapped)
        }
        .buttonStyle(.plain)
        .font(.callout)
        .foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 32)
    .padding(.vertical, 40)
  }
}

#Preview {
  ConnectionFailedView(
    store: Store(
      initialState: ConnectionFailedFeature.State(
        connection: ServerConnection(
          baseURL: URL(string: "http://mac.tailnet:9119")!,
          token: "t"
        ),
        reason: .unreachable
      )
    ) {
      ConnectionFailedFeature()
    }
  )
}
