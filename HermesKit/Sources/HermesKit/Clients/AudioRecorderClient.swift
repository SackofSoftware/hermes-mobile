import ComposableArchitecture
import DependenciesMacros
import Foundation

/// Recorded audio ready to upload to the transcription endpoint (#7). `mimeType` starts
/// with `audio/` so the agent's `/api/audio/transcribe` accepts it.
public struct RecordedAudio: Equatable, Sendable {
  public let data: Data
  public let mimeType: String

  public init(data: Data, mimeType: String) {
    self.data = data
    self.mimeType = mimeType
  }
}

public enum AudioRecorderError: Error, Equatable, Sendable {
  case permissionDenied
  case notRecording
  case unavailable
}

/// Records microphone audio for voice input and streams live amplitude so the composer
/// can draw a recording waveform (#7). Wraps `AVAudioSession`/`AVAudioRecorder` behind a
/// dependency so reducers stay testable and never touch AVFoundation directly.
@DependencyClient
public struct AudioRecorderClient: Sendable {
  /// Prompt for (or read) microphone permission. `false` ⇒ denied.
  public var requestPermission: @Sendable () async -> Bool = { false }
  /// Begin recording to a temp file with metering enabled.
  public var startRecording: @Sendable () async throws -> Void
  /// Stop and return the recorded audio bytes.
  public var stopRecording: @Sendable () async throws -> RecordedAudio
  /// Abort recording and discard the file (no audio returned).
  public var cancel: @Sendable () async -> Void
  /// A stream of normalized (0...1) amplitude samples while recording, for the waveform.
  /// Finishes when recording stops.
  public var levels: @Sendable () -> AsyncStream<Float> = { AsyncStream { $0.finish() } }

  /// Map a metering power reading (dBFS, ~-160…0) to a 0...1 amplitude for the waveform.
  /// `-50 dB` is treated as the silence floor — pure so it's unit-testable on any platform.
  public static func normalizeLevel(dBFS: Float) -> Float {
    let floor: Float = -50
    if dBFS <= floor { return 0 }
    if dBFS >= 0 { return 1 }
    return (dBFS - floor) / -floor
  }
}

extension AudioRecorderClient: DependencyKey {
  /// A usable test double: permission granted, canned audio, and a short finite levels
  /// stream. Override individual closures in tests to exercise specific paths.
  public static var testValue: AudioRecorderClient {
    AudioRecorderClient(
      requestPermission: { true },
      startRecording: {},
      stopRecording: { RecordedAudio(data: Data([0x00, 0x01]), mimeType: "audio/m4a") },
      cancel: {},
      levels: {
        AsyncStream { continuation in
          for level: Float in [0.2, 0.6, 0.4] { continuation.yield(level) }
          continuation.finish()
        }
      }
    )
  }
}

public extension DependencyValues {
  var audioRecorder: AudioRecorderClient {
    get { self[AudioRecorderClient.self] }
    set { self[AudioRecorderClient.self] = newValue }
  }
}

// MARK: - Live (iOS only)

// AVAudioSession/AVAudioApplication are iOS-only; the package is also built/tested on
// macOS via `swift test`, so the live recorder is compiled in only where UIKit exists.
// Elsewhere `liveValue` falls back to the no-op test double (no microphone).
#if canImport(UIKit)
  import AVFoundation

  /// Serializes access to the non-Sendable `AVAudioRecorder` and owns the temp file.
  private actor AudioRecorderEngine {
    private var recorder: AVAudioRecorder?
    private var fileURL: URL?

    func start() throws {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .defaultToSpeaker])
      try session.setActive(true)

      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("hermes-voice-\(UUID().uuidString).m4a")
      let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 44_100.0,
        AVNumberOfChannelsKey: 1,
        AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
      ]
      let recorder = try AVAudioRecorder(url: url, settings: settings)
      recorder.isMeteringEnabled = true
      guard recorder.record() else { throw AudioRecorderError.unavailable }
      self.recorder = recorder
      self.fileURL = url
    }

    /// Current normalized amplitude, or `nil` once recording has stopped.
    func sample() -> Float? {
      guard let recorder, recorder.isRecording else { return nil }
      recorder.updateMeters()
      return AudioRecorderClient.normalizeLevel(dBFS: recorder.averagePower(forChannel: 0))
    }

    func stop() throws -> RecordedAudio {
      guard let recorder, let url = fileURL else { throw AudioRecorderError.notRecording }
      recorder.stop()
      self.recorder = nil
      self.fileURL = nil
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
      let data = try Data(contentsOf: url)
      try? FileManager.default.removeItem(at: url)
      return RecordedAudio(data: data, mimeType: "audio/m4a")
    }

    func cancel() {
      recorder?.stop()
      recorder = nil
      if let url = fileURL { try? FileManager.default.removeItem(at: url) }
      fileURL = nil
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
  }

  extension AudioRecorderClient {
    public static var liveValue: AudioRecorderClient {
      let engine = AudioRecorderEngine()
      return AudioRecorderClient(
        requestPermission: {
          await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
              continuation.resume(returning: granted)
            }
          }
        },
        startRecording: { try await engine.start() },
        stopRecording: { try await engine.stop() },
        cancel: { await engine.cancel() },
        levels: {
          AsyncStream { continuation in
            let task = Task {
              // Poll metering at ~15 Hz until the engine reports recording stopped.
              while !Task.isCancelled {
                guard let level = await engine.sample() else { break }
                continuation.yield(level)
                try? await Task.sleep(for: .milliseconds(66))
              }
              continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
          }
        }
      )
    }
  }
#else
  extension AudioRecorderClient {
    /// No microphone off-device (macOS `swift test`): fall back to the no-op double.
    public static var liveValue: AudioRecorderClient { testValue }
  }
#endif
