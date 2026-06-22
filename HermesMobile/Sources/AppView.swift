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
      // foreground out to reconnect/re-activate + list refresh and background out to an
      // immediate snapshot/anchor flush. Behaviour is unit-tested via `scenePhaseChanged`.
      .onChange(of: scenePhase) { _, newPhase in
        store.send(.scenePhaseChanged(newPhase.appPhase))
      }
  }

  @ViewBuilder
  private var content: some View {
    if let homeStore = store.scope(state: \.home, action: \.home) {
      NavigationStack(path: $store.scope(state: \.path, action: \.path)) {
        SessionListView(store: homeStore)
      } destination: { chatStore in
        ChatView(store: chatStore)
      }
    } else if store.autoConnecting {
      ProgressView("Connecting…")
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
