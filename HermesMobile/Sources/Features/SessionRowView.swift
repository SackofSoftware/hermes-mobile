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
  /// Whether the agent is currently working this session — renders a brand-tinted glow.
  var isActive: Bool = false

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// Drives the gentle opacity pulse of the active glow (held flat when reduce-motion is on).
  @State private var pulsing = false

  private static let relativeFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.dateTimeStyle = .named
    return formatter
  }()

  var body: some View {
    // Search results have no title and `session.id` is a meaningless stored id, so
    // promote the snippet to the headline instead of showing the raw id.
    let snippet = session.preview.flatMap { $0.isEmpty ? nil : $0 }
    let promotesSnippet = showsPreview && session.title == nil && snippet != nil
    let headline = session.title ?? (promotesSnippet ? snippet! : session.id)

    return VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        if isUnread {
          Circle().fill(Color.hermesAccent).frame(width: 8, height: 8)
            .accessibilityLabel("Unread")
        }
        Text(headline)
          .font(.headline)
          .fontWeight(isUnread ? .semibold : .regular)
          .lineLimit(promotesSnippet ? 2 : 1)
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
      // Show the snippet as a secondary line only when it isn't already the headline.
      if showsPreview, !promotesSnippet, let preview = snippet {
        Text(preview)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
    }
    .padding(.vertical, 2)
    .modifier(ActiveGlow(isActive: isActive, reduceMotion: reduceMotion, pulsing: pulsing))
    .onAppear { updatePulsing() }
    // Drive the pulse off `isActive` too: when a poll flips it true on a row that's
    // already on screen (no re-onAppear), this starts the animation; flips to false stop it.
    .onChange(of: isActive) { updatePulsing() }
    .onChange(of: reduceMotion) { updatePulsing() }
  }

  /// Start the repeating pulse while active (and motion is allowed); otherwise hold it flat.
  private func updatePulsing() {
    if isActive, !reduceMotion {
      guard !pulsing else { return }
      withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
        pulsing = true
      }
    } else if pulsing {
      withAnimation(.easeInOut(duration: 0.2)) {
        pulsing = false
      }
    }
  }
}

/// A subtle brand-tinted border + halo around an actively-working session row.
/// When reduce-motion is on it stays static; otherwise its opacity gently pulses.
private struct ActiveGlow: ViewModifier {
  let isActive: Bool
  let reduceMotion: Bool
  let pulsing: Bool

  func body(content: Content) -> some View {
    guard isActive else { return AnyView(content) }
    // Reduce-motion: a steady glow. Otherwise pulse between a clearly-visible resting
    // level and full intensity (the resting level is what a static render shows).
    let intensity: Double = reduceMotion ? 0.8 : (pulsing ? 1.0 : 0.7)
    return AnyView(
      content
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.hermesAccent.opacity(0.12 * intensity))
            .overlay(
              RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.hermesAccent.opacity(0.85 * intensity), lineWidth: 1.5)
            )
            .shadow(color: Color.hermesAccent.opacity(0.6 * intensity), radius: 8)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Working")
    )
  }
}
