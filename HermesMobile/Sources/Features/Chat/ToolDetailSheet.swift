import HermesKit
import SwiftUI

/// Detail sheet for a tool/skill call — arguments, result, and any edit diff. Read-only.
struct ToolDetailSheet: View {
  let name: String
  let title: String
  let detail: ToolDetail
  let durationS: Double?

  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          header
          if let args = detail.argsText ?? detail.args?.displayString {
            section("Arguments", args)
          }
          if let result = detail.resultText {
            section("Result", result)
          }
          if let diff = detail.inlineDiff {
            section("Diff", diff)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
      }
      .navigationTitle(title.isEmpty ? name : title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
  }

  private var header: some View {
    HStack(spacing: 8) {
      Label(name, systemImage: "wrench.and.screwdriver")
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
      if let durationS {
        Text(String(format: "· %.1fs", durationS)).font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private func section(_ heading: String, _ body: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(heading.uppercased())
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
      Text(body)
        .font(.caption.monospaced())
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 10))
    }
  }
}
