import ComposableArchitecture
import HermesKit
import SwiftUI

/// The "Add profile" sheet form.
///
/// NOTE: This is a minimal placeholder wired to `AddProfileFeature` so the
/// `SessionListView` profile menu compiles and snapshots render. The full form (name
/// field with inline regex validation, clone-from-default toggle, SOUL.md editor, and
/// server-error banner) is built in Task 12, which replaces this body.
struct AddProfileView: View {
  @Bindable var store: StoreOf<AddProfileFeature>

  var body: some View {
    Form {
      Section {
        TextField("Profile name", text: $store.name)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
      }
    }
    .navigationTitle("Add profile")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Button("Cancel") { store.send(.cancelTapped) }
      }
      ToolbarItem(placement: .topBarTrailing) {
        Button("Create") { store.send(.createTapped) }
          .disabled(!store.canCreate)
      }
    }
  }
}
