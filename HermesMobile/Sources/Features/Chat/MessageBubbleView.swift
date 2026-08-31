import HermesKit
import SwiftUI

/// A user or assistant message. Assistant text renders as native Markdown.
struct MessageBubbleView: View {
  let role: ChatRow.Role
  let text: String
  let isComplete: Bool
  /// Code-block copy plumbing (#9), forwarded to `MarkdownText` for assistant messages.
  var copiedToken: String?
  var tokenPrefix: String = ""
  var onCopyCode: ((_ text: String, _ token: String) -> Void)?
  /// Raw bytes of images the user attached to this message (#8), shown as thumbnails.
  var attachmentImages: [Data] = []
  /// Connection used to fetch files the AGENT sent (`hermes-media://` markers). Nil in
  /// previews/snapshots, where the markers are simply stripped and nothing is fetched.
  var connection: ServerConnection?

  /// Message text with any `hermes-media://` markers pulled out. Returns the original
  /// string untouched when there are none, which is almost every message.
  private var parsed: (text: String, media: [MediaMarker]) {
    MediaMarkerParser.extract(from: text)
  }

  var body: some View {
    HStack(alignment: .top) {
      if role == .user { Spacer(minLength: 32) }
      VStack(alignment: role == .user ? .trailing : .leading, spacing: 4) {
        if !attachmentImages.isEmpty { imageThumbnails }
        if !text.isEmpty {
          if role == .assistant {
            // Assistant text renders as bubble-less, leading-aligned, full-width plain
            // content (Claude-app style) — only user messages keep a bubble.
            MarkdownText(
              text: parsed.text,
              copiedToken: copiedToken,
              tokenPrefix: tokenPrefix,
              onCopyCode: onCopyCode
            )
            .frame(maxWidth: .infinity, alignment: .leading)
          } else {
            Text(text)
              .textSelection(.enabled)
              .padding(.horizontal, 12)
              .padding(.vertical, 8)
              .background(bubbleColor, in: .rect(cornerRadius: 14))
          }
        }
        // Files the agent sent, under its message. Markers were stripped from the text
        // above, so a Markdown renderer never sees a scheme it can't fetch.
        if role == .assistant, !parsed.media.isEmpty, let connection {
          ForEach(parsed.media) { marker in
            MediaAttachmentView(marker: marker, connection: connection)
          }
        }
        // YouTube links get a tappable thumbnail card beneath the text (the inline link
        // stays clickable too — the card adds, it doesn't hide).
        if role == .assistant, isComplete {
          ForEach(YouTubeLink.findAll(in: parsed.text)) { link in
            YouTubeCardView(link: link)
          }
        }
        if !isComplete {
          ProgressView().controlSize(.mini)
        }
      }
    }
  }

  private var imageThumbnails: some View {
    VStack(alignment: role == .user ? .trailing : .leading, spacing: 4) {
      ForEach(Array(attachmentImages.enumerated()), id: \.offset) { _, data in
        if let image = UIImage(data: data) {
          Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: 220, maxHeight: 220)
            .clipShape(.rect(cornerRadius: 12))
        }
      }
    }
  }

  /// The user bubble fill; assistant text is bubble-less so this is only read for `.user`.
  private var bubbleColor: Color {
    Color.accentColor.opacity(0.18)
  }
}
