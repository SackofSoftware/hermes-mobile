import ComposableArchitecture
import HermesKit
import SwiftUI

/// Placeholder root view. Will be replaced by connection-gated navigation
/// (onboarding → session list → chat) as M1 features land.
struct AppView: View {
  let store: StoreOf<AppFeature>

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "staroflife.fill")
        .font(.largeTitle)
        .foregroundStyle(.tint)
      Text("Hermes Mobile")
        .font(.title2.weight(.semibold))
      Text("Scaffold ready")
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
    .task { store.send(.task) }
  }
}

#Preview {
  AppView(
    store: Store(initialState: AppFeature.State()) {
      AppFeature()
    }
  )
}
