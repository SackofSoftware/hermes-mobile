import HermesKit
import SwiftUI

/// Pinned card for a sudo password or a secret value (legacy event or v7 server request), in
/// the other cards' shape: a rigid one-line title and a **pinned row** — the secure field,
/// Skip and send — over ONE ``BoundedScrollRegion`` holding the server-controlled text (the
/// prompt, and the sudo `command` / secret `env_var` line when the request carries one), so a
/// long prompt or command scrolls in place instead of pushing the field off screen (#65).
struct SecretCardView: View {
  let kind: SecretKind
  let prompt: SecretPrompt
  /// Called with the value exactly as typed.
  let onSubmit: (String) -> Void
  let onSkip: () -> Void

  @State private var text = ""

  var body: some View {
    let promptText = prompt.displayPrompt
    let detail = prompt.displayDetail(for: kind)
    VStack(alignment: .leading, spacing: 10) {
      Label(kind == .sudo ? "Password required" : "Secret required", systemImage: "key.fill")
        .font(.subheadline.weight(.semibold))
        .lineLimit(1)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)

      if promptText != nil || detail != nil {
        BoundedScrollRegion {
          if let promptText {
            Text(promptText)
              .font(.callout)
              .textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          if let detail {
            Text(detail)
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }

      HStack(spacing: 12) {
        SecureField("Enter value", text: $text)
          .textFieldStyle(.roundedBorder)
          .submitLabel(.send)
          .onSubmit(submit)

        Button("Skip", action: onSkip)
          .buttonStyle(.bordered)

        Button(action: submit) {
          Image(systemName: "paperplane.fill")
        }
        .buttonStyle(.borderedProminent)
        .disabled(isBlank)
      }
    }
    .promptCardChrome(tint: .blue)
  }

  /// A blank entry can't be sent (Skip is the way to send nothing) — but a value that is
  /// sent goes as typed: edge whitespace may be part of a password or secret.
  private var isBlank: Bool {
    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func submit() {
    guard !isBlank else { return }
    onSubmit(text)
    text = ""
  }
}
