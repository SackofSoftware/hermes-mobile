import ComposableArchitecture
import HermesKit
import SwiftUI

/// The "Add profile" sheet form. Mirrors the desktop create-profile dialog: a name field
/// with inline regex validation (showing `ProfileName.hint`), a "Clone from default"
/// toggle (on by default), an optional multiline SOUL.md editor, and a server-error
/// warning banner below the form. Primary action **Create profile** (enabled only when
/// `store.canCreate`, busy while `isCreating`); secondary **Cancel**.
///
/// All behaviour lives in `AddProfileFeature` — this view only binds to it.
struct AddProfileView: View {
  @Bindable var store: StoreOf<AddProfileFeature>

  var body: some View {
    Form {
      Section {
        TextField("Profile name", text: $store.name)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .foregroundStyle(store.nameError == nil ? Color.primary : Color.red)
      } header: {
        Text("Name")
      } footer: {
        Text(ProfileName.hint)
          .foregroundStyle(store.nameError == nil ? Color.secondary : Color.red)
      }

      Section {
        Toggle("Clone from default", isOn: $store.cloneFromDefault)
      } footer: {
        Text("Copy config, skills, and SOUL.md from your default profile.")
      }

      Section {
        TextField(
          "The system prompt / persona for this profile. Leave blank to keep the cloned default.",
          text: $store.soul,
          axis: .vertical
        )
        .lineLimit(4...10)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
      } header: {
        Text("SOUL.md — optional")
      }

      if let banner = store.errorBanner {
        Section {
          Label {
            Text(banner)
          } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundStyle(.orange)
          }
          .font(.footnote)
          .foregroundStyle(.red)
        }
      }

      Section {
        Button {
          store.send(.createTapped)
        } label: {
          HStack {
            Spacer()
            if store.isCreating {
              ProgressView()
            } else {
              Text("Create profile")
            }
            Spacer()
          }
        }
        .disabled(!store.canCreate)
      }
    }
    .navigationTitle("Add profile")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Button("Cancel") { store.send(.cancelTapped) }
      }
    }
  }
}
