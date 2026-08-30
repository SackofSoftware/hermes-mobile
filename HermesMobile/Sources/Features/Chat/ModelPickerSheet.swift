import HermesKit
import SwiftUI

/// Interactive model + reasoning-effort picker.
///
/// Model and effort are SEPARATE choices and are shown that way: a "Reasoning effort"
/// section of its own, not a sub-list nested under whichever model happens to be selected.
/// The old nesting implied effort was a property of that one row, made the levels appear and
/// disappear as you moved between models, and buried the current effort where you had to
/// hunt for it.
///
/// Only configured providers are listed — set up new ones in Settings › Providers. Applies
/// via `config.set`.
struct ModelPickerSheet: View {
  let picker: ChatFeature.State.ModelPicker
  let currentModel: String?
  let currentEffort: String?
  let isBusy: Bool
  let onSelectModel: (String) -> Void
  let onSelectEffort: (String) -> Void
  let onDone: () -> Void

  var body: some View {
    NavigationStack {
      Group {
        if picker.isLoading {
          ProgressView("Loading models…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = picker.error {
          ContentUnavailableView("Couldn’t load models", systemImage: "exclamationmark.triangle",
                                 description: Text(error))
        } else {
          List {
            if isBusy {
              Section {
                Label("Finish or stop the current turn to switch models.", systemImage: "hourglass")
                  .font(.footnote).foregroundStyle(.secondary)
              }
            }
            ForEach(picker.options?.orderedProviders ?? []) { provider in
              Section(provider.name) {
                configuredModels(provider)
              }
            }
            // Effort stands on its own, always in the same place. Hidden entirely for a
            // model that doesn't reason, since the control would do nothing.
            if picker.options?.supportsReasoning(currentModel) ?? true {
              Section {
                ForEach(ModelOptions.reasoningEfforts, id: \.self) { effort in
                  effortRow(effort, selected: effort == currentEffort) { onSelectEffort(effort) }
                }
              } header: {
                Text("Reasoning effort")
              } footer: {
                Text("Higher effort means slower, more thorough answers. Applies to the selected model.")
              }
            }
          }
        }
      }
      .navigationTitle("Model")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done", action: onDone)
        }
      }
    }
  }

  @ViewBuilder
  private func configuredModels(_ provider: ModelOptions.Provider) -> some View {
    ForEach(provider.models, id: \.self) { model in
      selectableRow(
        model,
        selected: model == currentModel,
        icon: ProviderIconView(provider: provider.id, model: model)
      ) { onSelectModel(model) }
    }
  }

  private func selectableRow(
    _ label: String,
    selected: Bool,
    icon: ProviderIconView? = nil,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack {
        if let icon {
          icon
          // Dim the mark in step with the label while a turn is running.
          .opacity(isBusy ? 0.5 : 1)
        }
        Text(label).foregroundStyle(isBusy ? .secondary : .primary)
        Spacer()
        if selected {
          Image(systemName: "checkmark").foregroundStyle(Color.hermesAccent).fontWeight(.semibold)
        }
      }
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .disabled(isBusy)
  }

  /// A reasoning-effort option. A peer of the model rows, not a child of one — so no
  /// indent and no elbow stem, and it reads at the same weight as the model it applies to.
  private func effortRow(_ effort: String, selected: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack {
        Text(effort.capitalized).foregroundStyle(isBusy ? .secondary : .primary)
        Spacer()
        if selected {
          Image(systemName: "checkmark").foregroundStyle(Color.hermesAccent).fontWeight(.semibold)
        }
      }
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .disabled(isBusy)
  }
}
