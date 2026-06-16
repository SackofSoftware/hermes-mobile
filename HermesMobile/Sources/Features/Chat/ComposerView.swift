import HermesKit
import SwiftUI

/// The message composer: a growing text field above a toolbar row with a model/reasoning
/// chip (tappable → picker), a voice button, and a send/interrupt button in the Hermes
/// brand colour. While recording (#7) the field is replaced by a live waveform, elapsed
/// time, and cancel/stop controls.
struct ComposerView: View {
  @Binding var text: String
  let isSending: Bool
  let canSend: Bool
  let model: String?
  let reasoningEffort: String?
  /// Voice-input state (#7): drives whether the composer shows text entry or the recorder.
  var recording: ChatFeature.State.RecordingState = .idle
  var waveformLevels: [Float] = []
  var recordingSeconds: Int = 0
  /// Attachments (#8): hide the attach control when the agent can't accept uploads.
  var attachmentsSupported: Bool = true
  /// Owned by the parent's `@FocusState` so the transcript can dismiss the keyboard.
  var focused: FocusState<Bool>.Binding
  let onModelTap: () -> Void
  let onSend: () -> Void
  let onInterrupt: () -> Void
  var onVoiceTap: () -> Void = {}
  var onCancelRecording: () -> Void = {}
  var onAttachPhotos: () -> Void = {}
  var onAttachCamera: () -> Void = {}
  var onAttachFiles: () -> Void = {}

  var body: some View {
    Group {
      if recording.isBusy {
        recordingBar
      } else {
        textComposer
      }
    }
    .padding(12)
    .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 22))
    .padding(.horizontal)
    .padding(.vertical, 8)
  }

  private var textComposer: some View {
    VStack(spacing: 10) {
      TextField("Message", text: $text, axis: .vertical)
        .lineLimit(1 ... 6)
        .focused(focused)
        .onSubmit(onSend)

      HStack(spacing: 12) {
        if attachmentsSupported { attachButton }
        modelChip
        Spacer()
        voiceButton
        sendButton
      }
    }
  }

  private var attachButton: some View {
    Menu {
      Button { onAttachPhotos() } label: { Label("Photo Library", systemImage: "photo.on.rectangle") }
      Button { onAttachCamera() } label: { Label("Camera", systemImage: "camera") }
      Button { onAttachFiles() } label: { Label("Files", systemImage: "folder") }
    } label: {
      Image(systemName: "plus")
        .font(.title3)
        .foregroundStyle(.secondary)
    }
    .accessibilityLabel("Add attachment")
  }

  @ViewBuilder
  private var recordingBar: some View {
    if recording == .transcribing {
      HStack(spacing: 10) {
        ProgressView().controlSize(.small)
        Text("Transcribing…").font(.callout).foregroundStyle(.secondary)
        Spacer()
      }
      .frame(minHeight: 40)
    } else {
      HStack(spacing: 12) {
        Button(action: onCancelRecording) {
          Image(systemName: "xmark").font(.body.weight(.semibold))
        }
        .foregroundStyle(.secondary)
        .accessibilityLabel("Cancel recording")

        RecordingWaveform(levels: waveformLevels)

        Text(Self.elapsed(recordingSeconds))
          .font(.callout.monospacedDigit())
          .foregroundStyle(.secondary)

        Button(action: onVoiceTap) {
          Image(systemName: "stop.circle.fill").font(.title)
        }
        .foregroundStyle(Color.hermesAccent)
        .accessibilityLabel("Stop and transcribe")
      }
      .frame(minHeight: 40)
    }
  }

  /// `m:ss` elapsed-time readout for the recorder.
  static func elapsed(_ seconds: Int) -> String {
    String(format: "%d:%02d", seconds / 60, seconds % 60)
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
    Button(action: onVoiceTap) {
      Image(systemName: "mic.fill").font(.title3)
    }
    .foregroundStyle(.secondary)
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

/// Live amplitude bars for the active voice recording (#7). Newest sample is on the
/// right; bars grow from the vertical center. Honors reduce-motion (no height animation).
struct RecordingWaveform: View {
  let levels: [Float]

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    GeometryReader { geo in
      HStack(alignment: .center, spacing: 2) {
        ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
          Capsule()
            .fill(Color.hermesAccent.opacity(0.85))
            .frame(width: 2.5, height: barHeight(level, in: geo.size.height))
        }
        Spacer(minLength: 0)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
      .animation(reduceMotion ? nil : .linear(duration: 0.1), value: levels)
    }
    .frame(height: 28)
    .accessibilityHidden(true)
  }

  private func barHeight(_ level: Float, in height: CGFloat) -> CGFloat {
    max(3, CGFloat(min(max(level, 0), 1)) * height)
  }
}
