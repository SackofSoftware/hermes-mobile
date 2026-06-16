import ComposableArchitecture
import HermesKit
import SnapshotTesting
import SwiftUI
import XCTest

@testable import HermesMobile

final class ComposerSnapshotTests: SnapshotTestCase {
  // MARK: ComposerView

  func testComposer_idle() {
    let view = ComposerHost {
      ComposerView(
        text: .constant(""),
        isSending: false,
        canSend: false,
        model: "claude-opus-4-8",
        reasoningEffort: "high",
        focused: $0,
        onModelTap: {}, onSend: {}, onInterrupt: {}
      )
    }
    .frame(width: device.size?.width ?? 390)
    assertSnapshot(of: view, as: componentImage())
  }

  func testComposer_typingAndSending() {
    let view = VStack(spacing: 20) {
      ComposerHost {
        ComposerView(
          text: .constant("Summarize the streaming protocol"),
          isSending: false, canSend: true,
          model: "claude-sonnet-4-6", reasoningEffort: "medium",
          focused: $0,
          onModelTap: {}, onSend: {}, onInterrupt: {}
        )
      }
      ComposerHost {
        ComposerView(
          text: .constant(""),
          isSending: true, canSend: false,
          model: "claude-opus-4-8", reasoningEffort: nil,
          focused: $0,
          onModelTap: {}, onSend: {}, onInterrupt: {}
        )
      }
    }
    .frame(width: device.size?.width ?? 390)
    assertSnapshot(of: view, as: componentImage())
  }

  func testComposer_recordingWaveform() {
    let view = ComposerHost {
      ComposerView(
        text: .constant(""),
        isSending: false, canSend: false,
        model: "claude-opus-4-8", reasoningEffort: "high",
        recording: .recording,
        waveformLevels: [0.1, 0.35, 0.6, 0.8, 0.5, 0.25, 0.4, 0.7, 0.9, 0.55, 0.3, 0.15, 0.45, 0.65],
        recordingSeconds: 7,
        focused: $0,
        onModelTap: {}, onSend: {}, onInterrupt: {}
      )
    }
    .frame(width: device.size?.width ?? 390)
    assertSnapshot(of: view, as: componentImage())
  }

  func testComposer_transcribing() {
    let view = ComposerHost {
      ComposerView(
        text: .constant(""),
        isSending: false, canSend: false,
        model: "claude-opus-4-8", reasoningEffort: "high",
        recording: .transcribing,
        focused: $0,
        onModelTap: {}, onSend: {}, onInterrupt: {}
      )
    }
    .frame(width: device.size?.width ?? 390)
    assertSnapshot(of: view, as: componentImage())
  }

  func testComposer_attachmentChips() {
    let attachments = [
      ComposerAttachment(id: id(1), kind: .image, filename: "sunset.png", mimeType: "image/png", data: solidPNG(.systemOrange)),
      ComposerAttachment(id: id(2), kind: .pdf, filename: "report.pdf", mimeType: "application/pdf", data: Data([0x25])),
      ComposerAttachment(id: id(3), kind: .file, filename: "notes.txt", mimeType: "text/plain", data: Data([0x41])),
    ]
    let view = ComposerHost {
      ComposerView(
        text: .constant("What's in these?"),
        isSending: false, canSend: true,
        model: "claude-opus-4-8", reasoningEffort: "high",
        attachments: attachments,
        focused: $0,
        onModelTap: {}, onSend: {}, onInterrupt: {}
      )
    }
    .frame(width: device.size?.width ?? 390)
    assertSnapshot(of: view, as: componentImage())
  }

  func testComposer_attachmentUploadingAndFailed() {
    let attachments = [
      ComposerAttachment(id: id(1), kind: .image, filename: "photo.png", mimeType: "image/png", data: solidPNG(.systemBlue), uploadState: .uploading),
      ComposerAttachment(id: id(2), kind: .file, filename: "data.csv", mimeType: "text/csv", data: Data([0x41]), uploadState: .failed("boom")),
    ]
    let view = ComposerHost {
      ComposerView(
        text: .constant(""),
        isSending: true, canSend: false,
        model: "claude-opus-4-8", reasoningEffort: "high",
        attachments: attachments,
        focused: $0,
        onModelTap: {}, onSend: {}, onInterrupt: {}
      )
    }
    .frame(width: device.size?.width ?? 390)
    assertSnapshot(of: view, as: componentImage())
  }

  // MARK: ModelPickerSheet

  func testModelPickerSheet() {
    let picker = ChatFeature.State.ModelPicker(
      isLoading: false,
      options: ModelOptions(
        providers: [
          .init(name: "OpenAI", slug: "openai", models: ["gpt-5", "gpt-5-mini"], authenticated: true,
                capabilities: ["gpt-5": .init(reasoning: true), "gpt-5-mini": .init(reasoning: true)]),
          // Unconfigured — appears disabled below, with a configure hint.
          .init(name: "Anthropic", slug: "anthropic", models: [], authenticated: false,
                warning: "paste ANTHROPIC_API_KEY to activate"),
        ],
        currentModel: "gpt-5"
      )
    )
    let view = ModelPickerSheet(
      picker: picker,
      currentModel: "gpt-5", // reasoning-capable → effort options drop down under it, "high" selected
      currentEffort: "high",
      isBusy: false,
      onSelectModel: { _ in }, onSelectEffort: { _ in }, onDone: {}
    )
    assertSnapshot(of: view, as: deviceImage())
  }

  func testModelPickerSheet_nonReasoningModelHidesEffort() {
    let picker = ChatFeature.State.ModelPicker(
      isLoading: false,
      options: ModelOptions(
        providers: [
          .init(name: "Anthropic", slug: "anthropic",
                models: ["claude-opus-4-8", "claude-haiku-4-5"], authenticated: true,
                capabilities: [
                  "claude-opus-4-8": .init(reasoning: true),
                  "claude-haiku-4-5": .init(reasoning: false),
                ]),
        ],
        currentModel: "claude-haiku-4-5"
      )
    )
    let view = ModelPickerSheet(
      picker: picker,
      currentModel: "claude-haiku-4-5", // no reasoning → effort section hidden
      currentEffort: nil,
      isBusy: false,
      onSelectModel: { _ in }, onSelectEffort: { _ in }, onDone: {}
    )
    assertSnapshot(of: view, as: deviceImage())
  }
}
