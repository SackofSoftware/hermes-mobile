import ComposableArchitecture
import HermesKit
import SwiftUI

/// Root view: the onboarding screen until connected, then the session list with a
/// navigation stack that pushes chat screens.
struct AppView: View {
  @Bindable var store: StoreOf<AppFeature>
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    content
      .task { store.send(.task) }
      .sheet(item: $store.scope(state: \.reauth, action: \.reauth)) { reauthStore in
        ReauthView(store: reauthStore)
      }
      // Observe lifecycle here (view stays thin) and dispatch into the reducer, which fans
      // foreground out to reconnect/re-hydrate + list refresh and background out to an
      // immediate snapshot/anchor flush. Behaviour is unit-tested via `scenePhaseChanged`.
      .onChange(of: scenePhase) { _, newPhase in
        store.send(.scenePhaseChanged(newPhase.appPhase))
      }
  }

  /// Which root branch wins. Extracted from the `if`/`else` chain **only** so its
  /// PRECEDENCE is unit-testable: the connection-failed screen is reachable purely by
  /// sitting between `autoConnecting` and the onboarding fallback, and reordering it would
  /// silently disable the whole feature with every other test still green.
  enum RootScreen: Equatable {
    case home
    case connecting
    case connectionFailed
    case onboarding

    static func resolve(
      hasHome: Bool, autoConnecting: Bool, hasConnectionFailed: Bool
    ) -> RootScreen {
      if hasHome { return .home }
      if autoConnecting { return .connecting }
      if hasConnectionFailed { return .connectionFailed }
      return .onboarding
    }
  }

  private var rootScreen: RootScreen {
    .resolve(
      hasHome: store.home != nil,
      autoConnecting: store.autoConnecting,
      hasConnectionFailed: store.connectionFailed != nil
    )
  }

  @ViewBuilder
  private var content: some View {
    if rootScreen == .home, let homeStore = store.scope(state: \.home, action: \.home) {
      NavigationStack(path: $store.scope(state: \.path, action: \.path)) {
        SessionListView(store: homeStore)
      } destination: { _ in
        // The path holds only thin session-key markers — the REAL chat state lives in the
        // app-level live-chat slot, so a running turn's socket survives pops. Defensive
        // empty view if the slot is missing (e.g. after logout mid-pop).
        if let chatStore = store.scope(state: \.liveChat, action: \.liveChat) {
          ChatView(store: chatStore)
            // The view's disappearance routes through the PARENT (never the scoped child
            // store): `AppFeature.chatViewDisappeared` guards a nil slot (logout/quit may
            // have cleared it while the screen was still animating away) and owns the
            // idle-pop teardown policy — deferred here until the pop animation finished,
            // so the outgoing screen stays rendered and no action hits an absent child.
            .onDisappear { store.send(.chatViewDisappeared) }
        }
      }
    } else if rootScreen == .connecting {
      ProgressView("Connecting…")
    } else if rootScreen == .connectionFailed,
              let failedStore = store.scope(
                state: \.connectionFailed,
                action: \.connectionFailed
              ) {
      // Launch auto-connect failed for a reason that isn't a verdict on the credentials
      // (no network, or a proxy reporting the agent down): the stored credentials are fine,
      // so keep them and offer a retry instead of dropping to onboarding. Auth failures never
      // populate this slot — they fall through to the branch below.
      ConnectionFailedView(store: failedStore)
    } else {
      NavigationStack {
        ConnectionView(store: store.scope(state: \.onboarding, action: \.onboarding))
          .navigationTitle("Connect to Hermes")
          .navigationBarTitleDisplayMode(.inline)
      }
    }
  }
}

private extension ScenePhase {
  /// Map SwiftUI's `ScenePhase` onto HermesKit's SwiftUI-free `AppFeature.ScenePhase`.
  var appPhase: AppFeature.ScenePhase {
    switch self {
    case .active: return .active
    case .inactive: return .inactive
    case .background: return .background
    @unknown default: return .inactive
    }
  }
}

#Preview {
  AppView(
    store: Store(initialState: AppFeature.State()) {
      AppFeature()
    }
  )
}
