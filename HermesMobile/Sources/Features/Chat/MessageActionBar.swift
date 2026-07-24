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
    HStack(spacing: 20) {
      Button(action: onCopy) {
        Image(systemName: isCopied ? "checkmark" : "document.on.document")
          .foregroundStyle(isCopied ? Color.green : Color.secondary)
      }
      .accessibilityLabel(isCopied ? "Copied" : "Copy message")
      .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isCopied)

      Button(action: onBranch) {
        Image(systemName: "arrow.triangle.branch")
          .foregroundStyle(.secondary)
          .opacity(isBranchDisabled ? 0.4 : 1)
      }
      .disabled(isBranchDisabled)
      .accessibilityLabel("Branch in new chat")

      Spacer(minLength: 0)
    }
    .font(.footnote.weight(.medium))
    .buttonStyle(.plain)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
