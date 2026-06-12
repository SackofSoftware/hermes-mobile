import HermesKit
import SwiftUI

/// One row in the session list: title (or id), relative timestamp, preview.
struct SessionRowView: View {
  let session: Session
  /// Reference date the timestamp is relative to (injected so it's controllable).
  var now: Date = Date()

  private static let relativeFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.dateTimeStyle = .named
    return formatter
  }()

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(session.title ?? session.id)
          .font(.headline)
          .lineLimit(1)
        Spacer()
        if let updatedAt = session.updatedAt {
          Text(Self.relativeFormatter.localizedString(for: updatedAt, relativeTo: now))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      if let preview = session.preview, !preview.isEmpty {
        Text(preview)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
    }
    .padding(.vertical, 2)
  }
}
