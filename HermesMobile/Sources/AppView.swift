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
        // A home-screen quick action may have been recorded while the app was cold- or
        // warm-launching. Drain it on becoming active, once the root screen is resolved.
        if newPhase == .active { performPendingQuickAction() }
      }
      // Cold launch: `scenePhase` may already be `.active` by the time this view appears,
      // so the onChange above never fires — drain here too. `take()` is one-shot, so the
      // two paths can't double-fire.
      .onAppear { performPendingQuickAction() }
  }

  /// Perform a pending home-screen quick action, but only when it can actually succeed:
  /// "New Chat" needs the home screen (i.e. a connected, signed-in session list). If we're
  /// still on onboarding the action is left pending, and the next activation retries — so
  /// tapping "New Chat" on a signed-out app starts the chat right after you sign in
  /// rather than silently doing nothing.
  private func performPendingQuickAction() {
    guard store.rootScreen == .home else { return }
    switch QuickActionBox.shared.take() {
    case .newChat:
      store.send(.home(.newSessionButtonTapped))
    case .none:
      break
    }
  }

  /// Which root branch wins is decided ONCE, by `AppFeature.State.rootScreen` in HermesKit
  /// (where its precedence is unit-tested by `swift test`) — this `switch` only renders the
  /// verdict. Deliberately NOT `if rootScreen == .home, let homeStore = …`: re-deriving the
  /// same optional the resolver already consulted means a disagreement falls silently through
  /// to onboarding, which is the exact failure the enum exists to prevent.
  @ViewBuilder
  private var content: some View {
    switch store.rootScreen {
    case .home:
      if let homeStore = store.scope(state: \.home, action: \.home) {
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
      }
    case .connecting:
      ProgressView("Connecting…")
    case .connectionFailed:
      // Launch auto-connect failed for a reason that isn't a verdict on the credentials
      // (no network, or a proxy reporting the agent down): the stored credentials are fine,
      // so keep them and offer a retry instead of dropping to onboarding. Auth failures never
      // populate this slot — they land on the onboarding branch below.
      if let failedStore = store.scope(state: \.connectionFailed, action: \.connectionFailed) {
        ConnectionFailedView(store: failedStore)
      }
    case .onboarding:
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
