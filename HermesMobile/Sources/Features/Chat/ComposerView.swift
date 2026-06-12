import SwiftUI

/// The message composer: a growing text field plus a send (or interrupt) button.
struct ComposerView: View {
  @Binding var text: String
  let isSending: Bool
  let canSend: Bool
  let onSend: () -> Void
  let onInterrupt: () -> Void

  var body: some View {
    HStack(alignment: .bottom, spacing: 8) {
      TextField("Message", text: $text, axis: .vertical)
        .textFieldStyle(.roundedBorder)
        .lineLimit(1 ... 5)
        .onSubmit(onSend)
      if isSending {
        Button(action: onInterrupt) {
          Image(systemName: "stop.circle.fill").font(.title2)
        }
        .foregroundStyle(.red)
      } else {
        Button(action: onSend) {
          Image(systemName: "arrow.up.circle.fill").font(.title2)
        }
        .disabled(!canSend)
      }
    }
    .padding(.horizontal)
    .padding(.vertical, 8)
  }
}
