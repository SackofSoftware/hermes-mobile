import HermesKit
import SwiftUI

/// A live feed of decoded gateway events (newest last) for connection debugging.
struct ConnectionDebugView: View {
  let entries: [GatewayLogEntry]

  var body: some View {
    List {
      ForEach(entries) { entry in
        VStack(alignment: .leading, spacing: 2) {
          Text(entry.type)
            .font(.caption.monospaced().weight(.semibold))
            .foregroundStyle(.tint)
          if !entry.summary.isEmpty {
            Text(entry.summary)
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
              .lineLimit(3)
          }
        }
      }
    }
    .overlay {
      if entries.isEmpty {
        ContentUnavailableView(
          "No events yet",
          systemImage: "dot.radiowaves.left.and.right",
          description: Text("Open a chat to see gateway events stream in.")
        )
      }
    }
    .navigationTitle("Debug log")
    .navigationBarTitleDisplayMode(.inline)
  }
}
