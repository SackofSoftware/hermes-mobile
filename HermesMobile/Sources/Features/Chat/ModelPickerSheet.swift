import HermesKit
import SwiftUI

/// Model picker — models only. Reasoning effort is its own small sheet, opened from the
/// composer's effort badge: with effort embedded here, "turn effort up" meant scrolling
/// past every model to the bottom of this list.
///
/// Only configured providers are listed — set up new ones in Settings › Providers. Applies
/// via `config.set`, carrying the section's provider slug so the gateway routes the model to
/// the provider it was shown under instead of guessing from the id (#100).
struct ModelPickerSheet: View {
  let picker: ChatFeature.State.ModelPicker
  let currentModel: String?
  let isBusy: Bool
  /// `(model id, provider selection slug)` — the slug is appended as `--provider <slug>`.
  let onSelectModel: (String, String?) -> Void
  let onDone: () -> Void

  @State private var searchText = ""

  private var isSearching: Bool {
    !searchText.trimmingCharacters(in: .whitespaces).isEmpty
  }

  /// Search-filtered providers (`ModelOptions.filteredProviders(matching:)`); the full
  /// ordered list when the box is empty. Filtering keeps provider sections intact so
  /// identical model names across providers stay unambiguous.
  private var visibleProviders: [ModelOptions.Provider] {
    (picker.options?.filteredProviders(matching: searchText)) ?? []
  }

  /// Providers whose model list is expanded; nil until the user first toggles one.
  /// While nil the DEFAULT applies — only the current model's provider open — computed
  /// lazily so it works no matter when the async options load lands. The wall of every
  /// provider's every model was the main thing that made picking feel like work.
  @State private var expanded: Set<String>?

  private var effectiveExpanded: Set<String> {
    if let expanded { return expanded }
    guard let providers = picker.options?.orderedProviders else { return [] }
    if let current = currentModel,
       let owner = providers.first(where: { $0.models.contains(current) }) {
      return [owner.id]
    }
    return Set(providers.first.map { [$0.id] } ?? [])
  }

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
            // An apply failure keeps the list usable — the rolled-back row is right below.
            if let applyError = picker.applyError {
              Section {
                Label(applyError, systemImage: "exclamationmark.triangle")
                  .font(.footnote).foregroundStyle(.red)
              }
            }
            if isBusy {
              Section {
                Label("Finish or stop the current turn to switch models.", systemImage: "hourglass")
                  .font(.footnote).foregroundStyle(.secondary)
              }
            }
            // While searching every matching section is open — a hit hidden behind a
            // collapsed header would read as "no results".
            ForEach(visibleProviders) { provider in
              Section {
                if isSearching || effectiveExpanded.contains(provider.id) {
                  configuredModels(provider)
                }
              } header: {
                providerHeader(provider)
              }
            }
          }
          .overlay {
            if visibleProviders.isEmpty && isSearching {
              ContentUnavailableView.search(text: searchText)
            }
          }
        }
      }
      .navigationTitle("Model")
      .navigationBarTitleDisplayMode(.inline)
      .searchable(
        text: $searchText,
        placement: .navigationBarDrawer(displayMode: .always),
        prompt: "Search models"
      )
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done", action: onDone)
        }
      }
    }
  }

  /// Tappable section header: name, model count, and a disclosure chevron. A checkmark
  /// dot marks the provider that owns the current model even while collapsed.
  private func providerHeader(_ provider: ModelOptions.Provider) -> some View {
    let isOpen = effectiveExpanded.contains(provider.id)
    let ownsCurrent = currentModel.map { provider.models.contains($0) } ?? false
    return Button {
      withAnimation(.snappy) {
        var next = effectiveExpanded
        if isOpen { next.remove(provider.id) } else { next.insert(provider.id) }
        expanded = next
      }
    } label: {
      HStack(spacing: 6) {
        Text(provider.name)
        if ownsCurrent {
          Image(systemName: "checkmark.circle.fill")
            .font(.caption2)
            .foregroundStyle(Color.hermesAccent)
        }
        Spacer()
        if !isOpen {
          Text("\(provider.models.count)")
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        Image(systemName: "chevron.right")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.tertiary)
          .rotationEffect(.degrees(isOpen ? 90 : 0))
      }
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(provider.name), \(provider.models.count) models")
    .accessibilityHint(isOpen ? "Collapses the section" : "Expands the section")
  }

  @ViewBuilder
  private func configuredModels(_ provider: ModelOptions.Provider) -> some View {
    ForEach(provider.models, id: \.self) { model in
      selectableRow(
        ModelDisplay.prettyName(model),
        subtitle: model,
        context: picker.contextWindows[model].map(ModelDisplay.contextLabel),
        selected: model == currentModel,
        icon: ProviderIconView(provider: provider.id, model: model)
      ) { onSelectModel(model, provider.selectionSlug) }
    }
  }

  private func selectableRow(
    _ label: String,
    subtitle: String? = nil,
    context: String? = nil,
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
        VStack(alignment: .leading, spacing: 1) {
          Text(label).foregroundStyle(isBusy ? .secondary : .primary)
          // The raw id stays available — you sometimes need to match it against the
          // agent's logs — but demoted so the readable name leads.
          if let subtitle, subtitle != label {
            Text(subtitle).font(.caption2).foregroundStyle(.tertiary)
          }
        }
        Spacer()
        // Context window, right-aligned where the eye can compare down the column.
        if let context, !context.isEmpty {
          Text(context)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
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
