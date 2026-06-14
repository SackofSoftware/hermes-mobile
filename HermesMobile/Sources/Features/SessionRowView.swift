import HermesKit
import SwiftUI

/// One row in the session list. Like the desktop sidebar: title (or id) + relative age +
/// an unread dot. The first-message preview is only shown for search results (`showsPreview`).
struct SessionRowView: View {
  let session: Session
  /// Reference date the timestamp is relative to (injected so it's controllable).
  var now: Date = Date()
  /// Show the preview/snippet line (used for search results, not the grouped list).
  var showsPreview: Bool = false
  /// New activity since the user last opened this session.
  var isUnread: Bool = false
  /// Whether this session is pinned (shows a small pin glyph).
  var isPinned: Bool = false

  private static let relativeFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.dateTimeStyle = .named
    return formatter
  }()

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        if isUnread {
          Circle().fill(Color.hermesAccent).frame(width: 8, height: 8)
            .accessibilityLabel("Unread")
        }
        Text(session.title ?? session.id)
          .font(.headline)
          .fontWeight(isUnread ? .semibold : .regular)
          .lineLimit(1)
        if isPinned {
          Image(systemName: "pin.fill")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Pinned")
        }
        Spacer()
        if let updatedAt = session.updatedAt {
          Text(Self.relativeFormatter.localizedString(for: updatedAt, relativeTo: now))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      if showsPreview, let preview = session.preview, !preview.isEmpty {
        Text(preview)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
    }
    .padding(.vertical, 2)
  }
}
