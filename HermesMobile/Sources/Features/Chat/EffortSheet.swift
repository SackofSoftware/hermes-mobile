import HermesKit
import SwiftUI

/// The effort-only sheet, opened from the composer's effort badge.
///
/// Deliberately tiny — a fixed low detent, the slider, nothing else. Changing effort is a
/// one-gesture tweak; it shouldn't cost opening (and scrolling) the model catalog.
struct EffortSheet: View {
  let effort: String?
  let isBusy: Bool
  let onSelect: (String) -> Void
  let onDone: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Spacer()
        Button("Done", action: onDone).fontWeight(.semibold)
      }
      EffortSliderView(effort: effort, isBusy: isBusy, onSelect: onSelect)
      Text("Higher effort means slower, more thorough answers. Applies to the selected model.")
        .font(.caption)
        .foregroundStyle(.secondary)
      Spacer(minLength: 0)
    }
    .padding(20)
    .presentationDetents([.height(210)])
    .presentationDragIndicator(.visible)
  }
}
