import HermesKit
import SwiftUI

/// Interactive model + reasoning-effort picker. Configured providers are listed first and
/// are selectable; unconfigured providers appear disabled with a "how to configure" hint
/// (they can't be set up from mobile). The reasoning-effort options drop down inline under
/// the selected model when that model supports reasoning. Applies via `config.set`.
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
                if provider.isConfigured {
                  configuredModels(provider)
                } else {
                  unconfiguredRow(provider)
                }
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
      selectableRow(model, selected: model == currentModel) { onSelectModel(model) }
      // Reasoning effort drops down under the selected, reasoning-capable model.
      if model == currentModel, picker.options?.supportsReasoning(model) ?? true {
        ForEach(ModelOptions.reasoningEfforts, id: \.self) { effort in
          effortRow(effort, selected: effort == currentEffort) { onSelectEffort(effort) }
        }
      }
    }
  }

  private func unconfiguredRow(_ provider: ModelOptions.Provider) -> some View {
    Label(provider.warning ?? "Not configured", systemImage: "lock")
      .font(.footnote)
      .foregroundStyle(.secondary)
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
    .buttonStyle(.plain)
    .disabled(isBusy)
  }

  /// An indented reasoning-effort option shown beneath the selected model.
  private func effortRow(_ effort: String, selected: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Image(systemName: "arrow.turn.down.right").font(.caption2).foregroundStyle(.tertiary)
        Text(effort).font(.subheadline).foregroundStyle(isBusy ? .tertiary : .secondary)
        Spacer()
        if selected {
          Image(systemName: "checkmark").font(.subheadline).foregroundStyle(Color.hermesAccent).fontWeight(.semibold)
        }
      }
      .padding(.leading, 12)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .disabled(isBusy)
  }
}
