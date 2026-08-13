import Foundation

/// A composer draft frozen while a turn (or slash exec) was running (#66): mid-turn the
/// send button queues instead of submitting — the queue lives CLIENT-side because the
/// server's `queued_prompt` slot is a single merge-only slot with no edit/delete API
/// (`session.interrupt` silently clears it), so server-side queuing can't support the
/// panel's Edit/Delete/Send-now interactions. Entries drain head-first through the normal
/// submit pipeline when the session goes idle; nothing is ever sent mid-turn, so old
/// agents (which 4009 a busy `prompt.submit`) behave identically.
///
/// Deliberately in-memory only (v1): the queue survives navigation/backgrounding via the
/// live-chat slot but dies with the process — the same lifetime as an unsent composer
/// draft, which is the honest mental model. Attachment bytes must never be persisted to
/// the snapshot store regardless.
public struct QueuedPrompt: Equatable, Identifiable, Sendable {
  public let id: UUID
  /// Trimmed at enqueue (mirrors submit's trim) so the panel and the eventual submit agree.
  public var text: String
  /// Staged attachments frozen with the draft; uploaded at drain time like any submit.
  public var attachments: [ComposerAttachment]

  public init(id: UUID, text: String, attachments: [ComposerAttachment] = []) {
    self.id = id
    self.text = text
    self.attachments = attachments
  }
}
