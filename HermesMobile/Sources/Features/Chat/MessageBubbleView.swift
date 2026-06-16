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

  var body: some View {
    HStack(alignment: .top) {
      if role == .user { Spacer(minLength: 32) }
      VStack(alignment: role == .user ? .trailing : .leading, spacing: 4) {
        Group {
          if role == .assistant {
            MarkdownText(
              text: text,
              copiedToken: copiedToken,
              tokenPrefix: tokenPrefix,
              onCopyCode: onCopyCode
            )
          } else {
            Text(text).textSelection(.enabled)
          }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(bubbleColor, in: .rect(cornerRadius: 14))
        if !isComplete {
          ProgressView().controlSize(.mini)
        }
      }
      if role == .assistant { Spacer(minLength: 32) }
    }
  }

  private var bubbleColor: Color {
    role == .user ? Color.accentColor.opacity(0.18) : Color(uiColor: .secondarySystemBackground)
  }
}
