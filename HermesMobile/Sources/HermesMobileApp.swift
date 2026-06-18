import ComposableArchitecture
import HermesKit
import SwiftUI

@main
struct HermesMobileApp: App {
  @MainActor
  static let store: StoreOf<AppFeature> = {
    #if DEBUG
    if DemoMode.isActive { return DemoMode.makeStore() }
    #endif
    return Store(initialState: AppFeature.State()) {
      AppFeature()
    }
  }()

  var body: some Scene {
    WindowGroup {
      AppView(store: HermesMobileApp.store)
    }
  }
}
