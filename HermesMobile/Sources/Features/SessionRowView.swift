import HermesKit
import SwiftUI

/// One row in the session list: title (or id), relative timestamp, preview.
struct SessionRowView: View {
  let session: Session

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(session.title ?? session.id)
          .font(.headline)
          .lineLimit(1)
        Spacer()
        if let updatedAt = session.updatedAt {
          Text(updatedAt, format: .relative(presentation: .named))
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
