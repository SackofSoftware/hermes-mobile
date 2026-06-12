import HermesKit
import SwiftUI

/// A collapsed tool-call row: name, running/done state, and (on completion) result.
struct ToolStatusView: View {
  let name: String
  let state: ChatRow.ToolState
  let result: String?
  let durationS: Double?

  var body: some View {
    DisclosureGroup {
      if let result, !result.isEmpty {
        Text(result)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    } label: {
      HStack(spacing: 8) {
        Image(systemName: state == .running ? "wrench.and.screwdriver" : "checkmark.seal")
          .foregroundStyle(state == .running ? Color.secondary : Color.green)
        Text(name).font(.callout.weight(.medium))
        if state == .running { ProgressView().controlSize(.mini) }
        Spacer()
        if let durationS {
          Text(String(format: "%.1fs", durationS))
            .font(.caption).foregroundStyle(.secondary)
        }
      }
    }
  }
}
