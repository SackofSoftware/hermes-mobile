import ComposableArchitecture
import HermesKit
import SwiftUI

/// Root view: the onboarding screen until connected, then the session list with a
/// navigation stack that pushes chat screens.
struct AppView: View {
  @Bindable var store: StoreOf<AppFeature>

  var body: some View {
    content
      .task { store.send(.task) }
      .sheet(item: $store.scope(state: \.reauth, action: \.reauth)) { reauthStore in
        ReauthView(store: reauthStore)
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

#Preview {
  AppView(
    store: Store(initialState: AppFeature.State()) {
      AppFeature()
    }
  )
}
