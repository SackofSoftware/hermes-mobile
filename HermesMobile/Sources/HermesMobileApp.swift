import ComposableArchitecture
import HermesKit
import SwiftUI

@main
struct HermesMobileApp: App {
  @MainActor
  static let store = Store(initialState: AppFeature.State()) {
    AppFeature()
  }

  var body: some Scene {
    WindowGroup {
      AppView(store: HermesMobileApp.store)
    }
  }
}
