import SwiftUI

/// The visible per-message action row under a completed assistant message (#34):
/// **Copy** (raw Markdown, with the same transient green-checkmark feedback as the
/// code-block copy button) and **Branch in new chat** (desktop-parity seed of the
/// message into a fresh session). Small secondary-tinted icons, leading-aligned to
/// the bubble-less assistant layout — always visible, since iOS has no hover.
struct MessageActionBar: View {
  /// True while the reducer's copy-feedback token matches this row
  /// (`ChatFeature.rowCopyToken(_:)`); swaps the copy icon to a checkmark.
  let isCopied: Bool
  /// Mirrors the reducer's running-turn / in-flight-branch guards so the affordance
  /// gives instant feedback (the reducer stays the authority).
  let isBranchDisabled: Bool
  let onCopy: () -> Void
  let onBranch: () -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    // Each ~16pt glyph is padded to a comfortably tappable hit area (the padding is part
    // of the button label, and `.contentShape` makes the whole padded rect hittable —
    // bare `.plain` images over the transcript's scroll surface otherwise have a
    // footnote-sized target). The 4pt spacing keeps the VISUAL gap between icons at the
    // original 20pt (8 + 4 + 8); the negative leading inset re-aligns the first icon
    // with the assistant text's leading edge.
    HStack(spacing: 4) {
      Button(action: onCopy) {
        Image(systemName: isCopied ? "checkmark" : "document.on.document")
          .foregroundStyle(isCopied ? Color.green : Color.secondary)
          .padding(8)
          .contentShape(Rectangle())
      }
      .accessibilityLabel(isCopied ? "Copied" : "Copy message")
      .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isCopied)

      Button(action: onBranch) {
        Image(systemName: "arrow.triangle.branch")
          .foregroundStyle(.secondary)
          .opacity(isBranchDisabled ? 0.4 : 1)
          .padding(8)
          .contentShape(Rectangle())
      }
      .disabled(isBranchDisabled)
      .accessibilityLabel("Branch in new chat")

      Spacer(minLength: 0)
    }
    .font(.footnote.weight(.medium))
    .buttonStyle(.plain)
    .padding(.leading, -8)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
