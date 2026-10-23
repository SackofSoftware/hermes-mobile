import HermesKit
import SwiftUI

/// One interactive session in the session list, rendered as the desktop's "Inbox style" card:
/// a header line (workspace · age), the title, a preview line, and a footer (model · message
/// count). Natural height — no min-height floor (#79).
///
/// Deliberately separate from `SessionRowView` (which stays the compact one-liner for cron run
/// peeks and the archived sheet) so each style owns its own glow/pulse state and can diverge.
struct SessionCardView: View {
  let session: Session
  /// Reference date the age is relative to (injected so it's controllable).
  var now: Date = Date()
  /// Desktop-style `└─`/`├─` elbow for a nested branch row; `nil` for top-level rows.
  var branchStem: String?
  /// New activity since the user last opened this session.
  var isUnread: Bool = false
  /// Whether this session is pinned (shows a small pin glyph in the header).
  var isPinned: Bool = false
  /// Whether the agent is currently working this session — renders a brand-tinted glow.
  var isActive: Bool = false
  /// `false` for search hits, which carry no `cwd`: the header leaves the workspace out.
  var showsWorkspace: Bool = true

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// Drives the gentle opacity pulse of the active glow (held flat when reduce-motion is on).
  @State private var pulsing = false

  private static let relativeFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.dateTimeStyle = .named
    return formatter
  }()

  var body: some View {
    let content = SessionCardContent(session: session, showsWorkspace: showsWorkspace)
    return VStack(alignment: .leading, spacing: 4) {
      header(content)
      Text(content.title)
        .font(.headline)
        .fontWeight(isUnread ? .bold : .semibold)
        // `fixedSize(vertical:)` keeps the title at its ideal (up to two-line) height
        // whatever height the row is offered.
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
      if let preview = content.preview {
        Text(preview)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      if content.hasFooter {
        footer(content)
      }
    }
    .padding(.vertical, 4)
    .modifier(CardActiveGlow(isActive: isActive, reduceMotion: reduceMotion, pulsing: pulsing))
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      content.accessibilityLabel(age: age, isUnread: isUnread, isPinned: isPinned, isActive: isActive)
    )
    .onAppear { updatePulsing() }
    // Drive the pulse off `isActive` too: when a poll flips it true on a card that's already
    // on screen (no re-onAppear), this starts the animation; flips to false stop it.
    .onChange(of: isActive) { updatePulsing() }
    .onChange(of: reduceMotion) { updatePulsing() }
  }

  private func header(_ content: SessionCardContent) -> some View {
    HStack(spacing: 6) {
      if isUnread {
        Circle().fill(Color.hermesAccent).frame(width: 8, height: 8)
      }
      if let branchStem {
        Text(branchStem)
          .font(.caption.monospaced())
          .foregroundStyle(.tertiary)
      }
      if let workspace = content.workspace {
        Text(workspace)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      if isPinned {
        Image(systemName: "pin.fill")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      if let age {
        Text(age)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
  }

  private func footer(_ content: SessionCardContent) -> some View {
    HStack(spacing: 8) {
      if let model = content.model {
        Text(model)
          .lineLimit(1)
      }
      if let messageCount = content.messageCount {
        Text(messageCount)
          .lineLimit(1)
      }
    }
    .font(.caption)
    .foregroundStyle(.tertiary)
  }

  private var age: String? {
    session.updatedAt.map { Self.relativeFormatter.localizedString(for: $0, relativeTo: now) }
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

/// The card's own brand-tinted border + halo while the agent is working the session — a copy of
/// `SessionRowView`'s `ActiveGlow` so the two row styles can diverge. Purely visual: the
/// card's combined accessibility label already announces "Working".
private struct CardActiveGlow: ViewModifier {
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
    )
  }
}
