import SwiftUI

/// The message composer: a growing text field above a toolbar row with a model/reasoning
/// chip (tappable → picker), a (disabled) voice button, and a send/interrupt button in the
/// Hermes brand colour.
struct ComposerView: View {
  @Binding var text: String
  let isSending: Bool
  let canSend: Bool
  let model: String?
  let reasoningEffort: String?
  let onModelTap: () -> Void
  let onSend: () -> Void
  let onInterrupt: () -> Void

  var body: some View {
    VStack(spacing: 10) {
      TextField("Message", text: $text, axis: .vertical)
        .lineLimit(1 ... 6)
        .onSubmit(onSend)

      HStack(spacing: 12) {
        modelChip
        Spacer()
        voiceButton
        sendButton
      }
    }
    .padding(12)
    .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 22))
    .padding(.horizontal)
    .padding(.vertical, 8)
  }

  private var modelChip: some View {
    Button(action: onModelTap) {
      HStack(spacing: 5) {
        Text(modelLabel)
          .lineLimit(1)
        if let effort = reasoningEffort, !effort.isEmpty {
          Text("·").foregroundStyle(.tertiary)
          Text(effort)
        }
        Image(systemName: "chevron.up.chevron.down").font(.caption2)
      }
      .font(.footnote.weight(.medium))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(.quaternary, in: Capsule())
    }
    .buttonStyle(.plain)
  }

  private var voiceButton: some View {
    // Placeholder — voice input ships later.
    Button(action: {}) {
      Image(systemName: "mic.fill").font(.title3)
    }
    .foregroundStyle(.tertiary)
    .disabled(true)
  }

  @ViewBuilder
  private var sendButton: some View {
    if isSending {
      Button(action: onInterrupt) {
        Image(systemName: "stop.circle.fill").font(.title)
      }
      .foregroundStyle(.red)
    } else {
      Button(action: onSend) {
        Image(systemName: "arrow.up.circle.fill").font(.title)
      }
      .foregroundStyle(Color.hermesAccent)
      .disabled(!canSend)
    }
  }

  private var modelLabel: String {
    if let model, !model.isEmpty { return model }
    return "Model"
  }
}
