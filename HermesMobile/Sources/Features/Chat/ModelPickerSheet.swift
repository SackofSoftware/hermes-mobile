import HermesKit
import SwiftUI

/// Interactive model + reasoning-effort picker. Selecting an item applies it to the live
/// session via `config.set`. Selection is disabled while a turn is in flight (the server
/// rejects mid-turn switches).
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
                Label("Finish or stop the current turn to switch models.",
                      systemImage: "hourglass")
                  .font(.footnote).foregroundStyle(.secondary)
              }
            }
            reasoningSection
            modelSections
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

  private var reasoningSection: some View {
    Section("Reasoning effort") {
      ForEach(ModelOptions.reasoningEfforts, id: \.self) { effort in
        selectableRow(effort, selected: effort == currentEffort) { onSelectEffort(effort) }
      }
    }
  }

  @ViewBuilder
  private var modelSections: some View {
    ForEach(picker.options?.usableProviders ?? []) { provider in
      Section(provider.name) {
        ForEach(provider.models, id: \.self) { model in
          selectableRow(model, selected: model == currentModel) { onSelectModel(model) }
        }
      }
    }
  }

  private func selectableRow(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack {
        Text(label).foregroundStyle(isBusy ? .secondary : .primary)
        Spacer()
        if selected {
          Image(systemName: "checkmark").foregroundStyle(Color.hermesAccent).fontWeight(.semibold)
        }
      }
      .contentShape(.rect)
    }
    .buttonStyle(.plain) // primary label text, not the accent tint
    .disabled(isBusy)
  }
}
