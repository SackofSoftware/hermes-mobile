import HermesKit
import SwiftUI

/// A tool/skill activity row: a per-tool glyph, ONE plain-English line, running spinner /
/// duration, and a chevron that opens the detail sheet.
///
/// This deliberately no longer prints the raw tool name (`browser_navigate`,
/// `session_search`, …) under the title. A working turn produces a dozen of these rows, and
/// the raw identifiers made the transcript read like a stack trace. `ToolDisplay` maps the
/// tool to a verb and a glyph instead; the raw name and full arguments are one tap away in
/// the detail sheet, which is where they belong.
struct ToolStatusView: View {
  let name: String
  let title: String
  let state: ChatRow.ToolState
  let durationS: Double?
  let hasDetail: Bool
  let onTap: () -> Void

  var body: some View {
    let display = ToolDisplay.forTool(name)
    let headline = ToolDisplay.headline(name: name, title: title)
    return Button(action: onTap) {
      HStack(spacing: 10) {
        // Per-tool glyph so the list is scannable by shape, not only by reading. It also
        // carries the state: the tool's own symbol while running, a green check once done.
        Image(systemName: state == .running ? display.symbol : "checkmark.circle.fill")
          .font(.callout)
          .foregroundStyle(state == .running ? Color.secondary : Color.green)
          .frame(width: 20)
        Text(headline)
          .font(.callout)
          .foregroundStyle(state == .running ? Color.secondary : Color.primary)
          .lineLimit(1)
          .truncationMode(.middle)
          .frame(maxWidth: .infinity, alignment: .leading)
        if state == .running { ProgressView().controlSize(.mini) }
        if let durationS {
          Text(String(format: "%.1fs", durationS)).font(.caption).foregroundStyle(.secondary)
        }
        if hasDetail {
          Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
      }
      .padding(.vertical, 5)
      .frame(maxWidth: .infinity, alignment: .leading)
      // The raw name still reaches VoiceOver (and the detail sheet) — only the visual
      // clutter is gone, not the information.
      .accessibilityLabel("\(headline), tool \(name)")
    }
    .buttonStyle(.plain)
    .disabled(!hasDetail)
  }
}
