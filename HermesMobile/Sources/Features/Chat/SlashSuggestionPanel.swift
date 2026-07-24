import HermesKit
import SwiftUI

/// The slash-command autocomplete panel (#36), shown between the transcript and the
/// composer while the composer text is a slash query. Thin view: the rows come from the
/// reducer's computed `slashSuggestions`, and a tap only reports the selection upward —
/// the reducer rewrites `composerText`, which recomputes (and clears) the panel. Nothing
/// here touches focus, so the keyboard stays up across a selection.
///
/// At most ~5 rows are visible; longer lists scroll inside the panel (a half-row peeks
/// to hint at the overflow). Command names are monospaced with a secondary description;
/// dynamic skill routes get a sparkles icon.
struct SlashSuggestionPanel: View {
  let suggestions: [SlashSuggestion]
  let onTap: (SlashSuggestion) -> Void

  /// Fixed row height so the ~5-row cap (and the snapshots) are deterministic.
  private static let rowHeight: CGFloat = 40
  private static let maxVisibleRows: CGFloat = 5.5

  var body: some View {
    ScrollView {
      LazyVStack(spacing: 0) {
        ForEach(suggestions) { suggestion in
          Button {
            onTap(suggestion)
          } label: {
            row(suggestion)
          }
          .buttonStyle(.plain)
        }
      }
    }
    .frame(height: panelHeight)
    .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 14))
    .padding(.horizontal)
    .padding(.bottom, 2)
    .accessibilityLabel("Command suggestions")
  }

  /// Grows with the list up to the cap; a half-visible sixth row signals scrollability.
  private var panelHeight: CGFloat {
    Self.rowHeight * min(CGFloat(suggestions.count), Self.maxVisibleRows)
  }

  private func row(_ suggestion: SlashSuggestion) -> some View {
    HStack(spacing: 8) {
      Text(suggestion.name)
        .font(.system(.callout, design: .monospaced).weight(.medium))
        .lineLimit(1)
        .layoutPriority(1)
      if !suggestion.description.isEmpty {
        Text(suggestion.description)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      Spacer(minLength: 0)
      if suggestion.isSkill {
        Image(systemName: "sparkles")
          .font(.caption)
          .foregroundStyle(.secondary)
          .accessibilityLabel("Skill")
      }
    }
    .padding(.horizontal, 12)
    .frame(height: Self.rowHeight)
    .contentShape(.rect)
  }
}
