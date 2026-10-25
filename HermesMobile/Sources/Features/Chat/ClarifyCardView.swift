import HermesKit
import SwiftUI

/// Pinned card shown when the agent needs input mid-turn. Three shapes share it:
/// - clarify with choices → tappable options
/// - clarify with no choices → free-text field
/// - sudo / secret (legacy event or v7 server request) → secure-entry field, with the sudo
///   `command` / secret `env_var` line when the request carries one, and Skip
struct ClarifyCardView: View {
  enum Mode: Equatable {
    case clarify(ClarifyRequest)
    case secret(SecretKind, SecretPrompt)
  }

  let mode: Mode
  /// Called with the chosen option / typed text / secret value.
  let onSubmit: (String) -> Void
  /// Shows a Skip button when set (the secret card; clarify gains its own in Task 7).
  var onSkip: (() -> Void)?

  @State private var text = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label(title, systemImage: icon)
        .font(.subheadline.weight(.semibold))

      if !prompt.isEmpty {
        Text(prompt)
          .font(.callout)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      if let detail {
        // Clamped: this card is rigid (no bounded scroll region), so a long redacted sudo
        // command must not push the field and the composer off screen.
        Text(detail)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(3)
          .truncationMode(.middle)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      switch mode {
      case let .clarify(request) where !request.choices.isEmpty:
        VStack(spacing: 8) {
          ForEach(request.choices, id: \.self) { choice in
            Button { onSubmit(choice) } label: {
              Text(choice).frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
          }
        }
      default:
        inputField
      }
    }
    .padding()
    .background(Color(uiColor: .tertiarySystemBackground), in: .rect(cornerRadius: 14))
    .overlay(RoundedRectangle(cornerRadius: 14).stroke(.blue.opacity(0.5)))
    .padding(.horizontal)
  }

  private var inputField: some View {
    HStack(spacing: 12) {
      Group {
        if isSecure {
          SecureField("Enter value", text: $text)
        } else {
          TextField("Type a reply", text: $text, axis: .vertical)
        }
      }
      .textFieldStyle(.roundedBorder)
      .submitLabel(.send)
      .onSubmit(submit)

      if let onSkip {
        Button("Skip", action: onSkip)
          .buttonStyle(.bordered)
      }

      Button(action: submit) {
        Image(systemName: "paperplane.fill")
      }
      .buttonStyle(.borderedProminent)
      .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
  }

  private func submit() {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    onSubmit(trimmed)
    text = ""
  }

  private var isSecure: Bool {
    if case .secret = mode { return true }
    return false
  }

  private var title: String {
    switch mode {
    case .clarify: return "Clarification needed"
    case let .secret(kind, _): return kind == .sudo ? "Password required" : "Secret required"
    }
  }

  private var icon: String {
    switch mode {
    case .clarify: return "questionmark.circle"
    case .secret: return "key.fill"
    }
  }

  private var prompt: String {
    switch mode {
    case let .clarify(request): return request.question
    case let .secret(_, prompt): return prompt.prompt ?? ""
    }
  }

  /// The sudo `command` or the secret's `env_var`, when the request carries one.
  private var detail: String? {
    guard case let .secret(kind, prompt) = mode else { return nil }
    let value = (kind == .sudo ? prompt.command : prompt.envVar)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let value, !value.isEmpty else { return nil }
    return kind == .sudo ? "$ \(value)" : "Saved as \(value)"
  }
}
