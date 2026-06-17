import ComposableArchitecture
import HermesKit
import SnapshotTesting
import SwiftUI
import XCTest

@testable import HermesMobile

final class AddProfileSnapshotTests: SnapshotTestCase {
  private func view(_ state: AddProfileFeature.State) -> some View {
    NavigationStack {
      AddProfileView(
        store: Store(initialState: state) {
          AddProfileFeature()
        }
      )
    }
  }

  /// Pristine form: empty name (no inline error), clone-from-default on, empty SOUL.md,
  /// no banner. Create is disabled.
  func testAddProfile_pristine() {
    assertSnapshot(
      of: view(AddProfileFeature.State(connection: connection)),
      as: deviceImage()
    )
  }

  /// Inline-invalid name: `testOS` (uppercase) fails the profile-name regex, so the field
  /// renders in the destructive state with `ProfileName.hint` and Create stays disabled.
  func testAddProfile_inlineInvalidName() {
    assertSnapshot(
      of: view(AddProfileFeature.State(connection: connection, name: "testOS")),
      as: deviceImage()
    )
  }

  /// Server-400 banner: a reserved-name rejection from the agent surfaces the server
  /// `detail` verbatim in the warning banner below the form.
  func testAddProfile_serverErrorBanner() {
    assertSnapshot(
      of: view(
        AddProfileFeature.State(
          connection: connection,
          name: "work",
          errorBanner: "Profile name 'work' is reserved."
        )
      ),
      as: deviceImage()
    )
  }
}
