import ComposableArchitecture
import Testing

@testable import HermesKit

@MainActor
struct AppFeatureTests {
  /// Smoke test: the root feature builds, has the expected initial state, and
  /// the lifecycle action is a no-op (TestStore is exhaustive, so an unhandled
  /// state change or effect would fail this).
  @Test func initialStateAndLifecycleNoOp() async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    }
    #expect(store.state == AppFeature.State())
    await store.send(.task)
  }
}
