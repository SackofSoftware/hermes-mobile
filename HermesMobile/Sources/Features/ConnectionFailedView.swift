import ComposableArchitecture
import HermesKit
import SwiftUI

/// Shown instead of onboarding when **launch auto-connect** fails for a transport reason.
/// The stored credentials are still good, so the screen never asks for them again — it just
/// names the server it couldn't reach, says why, and offers a Retry. Log Out is the escape
/// hatch for someone who genuinely wants to abandon the session (it runs the full-logout
/// recipe in `AppFeature`).
struct ConnectionFailedView: View {
  let store: StoreOf<ConnectionFailedFeature>

  var body: some View {
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

        // Monospaced + `.byCharWrapping` so a long tailnet host wraps instead of
        // truncating — the URL is the whole point of the screen ("which server?").
        Text(store.serverURLText)
          .font(.footnote.monospaced())
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .lineLimit(3)

        Text(store.reasonText)
          .font(.callout)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
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

        Button("Log Out", role: .destructive) {
          store.send(.logoutTapped)
        }
        .buttonStyle(.plain)
        .font(.callout)
        .foregroundStyle(.secondary)
        .disabled(store.isRetrying)
      }
    }
    .padding(.horizontal, 32)
    .padding(.vertical, 40)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
