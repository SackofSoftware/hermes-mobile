import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

@MainActor
struct ChatReductionTests {
  private let conn = ServerConnection(baseURL: URL(string: "http://mac.tailnet:9119")!, token: "t")
  private func uuid(_ n: Int) -> UUID {
    UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012x", n))")!
  }

  // MARK: Streaming fold (no message id — single in-flight row)

  @Test func streamingMessageFold() async {
    let store = TestStore(initialState: ChatFeature.State(connection: conn)) {
      ChatFeature()
    } withDependencies: { $0.uuid = .incrementing }

    // message.start no longer creates a row (would render as an empty bubble); the row
    // is materialised lazily on the first delta.
    await store.send(.gatewayEvent(.messageStart)) {
      $0.isSending = true
    }
    await store.send(.gatewayEvent(.messageDelta(text: "Hel"))) {
      $0.transcript = [ChatRow(id: uuid(0), kind: .message(role: .assistant, text: "Hel", isComplete: false))]
      $0.streamingRowID = uuid(0)
    }
    await store.send(.gatewayEvent(.messageDelta(text: "lo"))) {
      $0.transcript[id: uuid(0)]?.kind = .message(role: .assistant, text: "Hello", isComplete: false)
    }
    await store.send(.gatewayEvent(.messageComplete(text: "Hello", usage: nil))) {
      $0.transcript[id: uuid(0)]?.kind = .message(role: .assistant, text: "Hello", isComplete: true)
      $0.streamingRowID = nil
      $0.isSending = false
    }
  }

  @Test func toolOnlyTurnLeavesNoEmptyMessageBubble() async {
    let store = TestStore(initialState: ChatFeature.State(connection: conn)) {
      ChatFeature()
    } withDependencies: { $0.uuid = .incrementing }

    // start → (tool activity) → complete with no text: no assistant message row at all.
    await store.send(.gatewayEvent(.messageStart)) { $0.isSending = true }
    await store.send(.gatewayEvent(.messageComplete(text: "", usage: nil))) {
      $0.isSending = false
    }
    #expect(store.state.transcript.isEmpty)
  }

  @Test func thinkingFoldsIntoOneRowThenMessageStarts() async {
    let store = TestStore(initialState: ChatFeature.State(connection: conn)) {
      ChatFeature()
    } withDependencies: { $0.uuid = .incrementing }

    await store.send(.gatewayEvent(.thinkingDelta(text: "Thinking"))) {
      $0.transcript = [ChatRow(id: uuid(0), kind: .thinking(text: "Thinking"))]
      $0.thinkingRowID = uuid(0)
    }
    await store.send(.gatewayEvent(.thinkingDelta(text: "…"))) {
      $0.transcript[id: uuid(0)]?.kind = .thinking(text: "Thinking…")
    }
    await store.send(.gatewayEvent(.messageStart)) {
      $0.thinkingRowID = nil
      $0.isSending = true
    }
    // No deltas → message.complete materialises the finalised row directly (uuid 1).
    await store.send(.gatewayEvent(.messageComplete(text: "pong", usage: nil))) {
      $0.transcript.append(ChatRow(id: uuid(1), kind: .message(role: .assistant, text: "pong", isComplete: true)))
      $0.streamingRowID = nil
      $0.isSending = false
    }
  }

  @Test func toolStartThenComplete() async {
    let store = TestStore(initialState: ChatFeature.State(connection: conn)) {
      ChatFeature()
    } withDependencies: { $0.uuid = .incrementing }

    await store.send(.gatewayEvent(.toolStart(toolID: "t1", name: "read_file", title: "Reading /x", argsText: "path=/x"))) {
      $0.transcript = [ChatRow(id: uuid(0), kind: .tool(
        name: "read_file", title: "Reading /x", state: .running,
        detail: ToolDetail(argsText: "path=/x"), durationS: nil
      ))]
      $0.toolRowIDs = ["t1": uuid(0)]
    }
    await store.send(.gatewayEvent(.toolComplete(
      toolID: "t1", name: "read_file", title: "Read 12 lines",
      args: .object(["path": .string("/x")]), resultText: "ok", inlineDiff: nil, durationS: 1.5
    ))) {
      // Merge keeps the start-time args_text; fills in result + structured args.
      $0.transcript[id: uuid(0)]?.kind = .tool(
        name: "read_file", title: "Read 12 lines", state: .complete,
        detail: ToolDetail(argsText: "path=/x", args: .object(["path": .string("/x")]), resultText: "ok", inlineDiff: nil),
        durationS: 1.5
      )
    }
  }

  @Test func toolTitleFallsBackToNameAndTapPresentsDetail() async {
    let store = TestStore(initialState: ChatFeature.State(connection: conn)) {
      ChatFeature()
    } withDependencies: { $0.uuid = .incrementing }

    // No context/summary → title falls back to the raw tool name.
    await store.send(.gatewayEvent(.toolStart(toolID: "t1", name: "grep", title: nil, argsText: nil))) {
      $0.transcript = [ChatRow(id: uuid(0), kind: .tool(
        name: "grep", title: "grep", state: .running, detail: nil, durationS: nil
      ))]
      $0.toolRowIDs = ["t1": uuid(0)]
    }
    await store.send(.gatewayEvent(.toolComplete(
      toolID: "t1", name: "grep", title: nil, args: nil, resultText: "2 matches", inlineDiff: nil, durationS: 0.2
    ))) {
      $0.transcript[id: self.uuid(0)]?.kind = .tool(
        name: "grep", title: "grep", state: .complete,
        detail: ToolDetail(resultText: "2 matches"), durationS: 0.2
      )
    }
    await store.send(.toolTapped(id: uuid(0))) {
      $0.presentedTool = $0.transcript[id: self.uuid(0)]
    }
    await store.send(.toolDetailDismissed) {
      $0.presentedTool = nil
    }
  }

  @Test func statusUpdateAndError() async {
    let store = TestStore(initialState: ChatFeature.State(connection: conn)) { ChatFeature() }

    await store.send(.gatewayEvent(.statusUpdate(kind: "lifecycle", text: "searching…"))) {
      $0.activity = "searching…"
    }
    await store.send(.gatewayEvent(.error(message: "boom"))) {
      $0.errorBanner = "boom"
    }
  }

  // MARK: Composer

  @Test func composerSubmitAppendsUserRowAndSends() async {
    var initial = ChatFeature.State(connection: conn, status: .ready)
    initial.liveSessionID = "live"
    let store = TestStore(initialState: initial) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.hermesGateway.send = { @Sendable _, _ in .object(["status": .string("streaming")]) }
    }

    await store.send(\.binding.composerText, "hello") { $0.composerText = "hello" }
    await store.send(.composerSubmitted) {
      $0.transcript = [ChatRow(id: uuid(0), kind: .message(role: .user, text: "hello", isComplete: true))]
      $0.composerText = ""
      $0.isSending = true
    }
  }

  // MARK: Bootstrap (create on first ready)

  @Test func createsSessionOnFirstReady() async {
    let sent = LockIsolated<JSONValue?>(nil)
    let store = TestStore(initialState: ChatFeature.State(connection: conn)) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = ImmediateClock()
      $0.hermesGateway.connect = { @Sendable _, _ in AsyncStream { $0.yield(.ready) } }
      $0.hermesGateway.send = { @Sendable method, params in
        sent.setValue(.object(["method": .string(method), "params": params]))
        return .object([
          "session_id": .string("live123"),
          "stored_session_id": .string("stored123"),
          "message_count": .number(0),
        ])
      }
    }

    await store.send(.task)
    await store.receive(\.gatewayEvent) {
      $0.status = .ready
      $0.hasRequestedSession = true
    }
    await store.receive(\.sessionResult.success) {
      $0.liveSessionID = "live123"
      $0.storedSessionID = "stored123"
      $0.status = .ready
    }
    // New sessions create with no title so the server auto-names from the first message.
    #expect(sent.value?["method"]?.stringValue == "session.create")
    #expect(sent.value?["params"] == .object([:]))
    #expect(sent.value?["params"]?["title"] == nil)
    await store.send(.onDisappear)
  }

  @Test func resumeReadyBootstrapsViaSessionResume() async {
    let sent = LockIsolated<JSONValue?>(nil)
    let store = TestStore(initialState: ChatFeature.State(connection: conn, resumeStoredID: "stored123")) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.hermesGateway.send = { @Sendable method, params in
        sent.setValue(.object(["method": .string(method), "params": params]))
        return .object(["session_id": .string("live123"), "stored_session_id": .string("stored123")])
      }
    }

    // A ready frame *with* a stored id must resume (not create).
    await store.send(.gatewayEvent(.ready)) {
      $0.status = .ready
      $0.hasRequestedSession = true
    }
    await store.receive(\.sessionResult.success) {
      $0.liveSessionID = "live123"
      $0.storedSessionID = "stored123"
      $0.status = .ready
    }
    #expect(sent.value?["method"]?.stringValue == "session.resume")
    #expect(sent.value?["params"]?["session_id"]?.stringValue == "stored123")
  }

  @Test func historyReconstructsToolRowsAndDropsEmptyTurns() async {
    let store = TestStore(initialState: ChatFeature.State(connection: conn)) {
      ChatFeature()
    } withDependencies: { $0.uuid = .incrementing }

    let messages = [
      SessionMessage(id: 1, role: "user", content: "Read the file"),
      // An assistant tool-call turn with no text — must NOT become an empty bubble. Its
      // tool_calls carry the command for the matching tool result row.
      SessionMessage(id: 2, role: "assistant", content: "", toolCalls: [
        ToolCallRef(id: "call_1", name: "read_file", arguments: #"{"path":"/x"}"#),
      ]),
      SessionMessage(id: 3, role: "tool", content: "file contents…", toolName: "read_file", toolCallID: "call_1"),
      SessionMessage(id: 4, role: "assistant", content: "Here's the gist."),
    ]
    await store.send(.historyResponse(messages)) {
      $0.transcript = [
        ChatRow(id: self.uuid(0), kind: .message(role: .user, text: "Read the file", isComplete: true)),
        ChatRow(id: self.uuid(1), kind: .tool(
          name: "read_file", title: "read_file", state: .complete,
          // Command (args) recovered from the assistant tool_calls + result joined.
          detail: ToolDetail(args: .object(["path": .string("/x")]), resultText: "file contents…"),
          durationS: nil
        )),
        ChatRow(id: self.uuid(2), kind: .message(role: .assistant, text: "Here's the gist.", isComplete: true)),
      ]
    }
  }

  @Test func unknownEventIsInertInTheFold() async {
    let store = TestStore(initialState: ChatFeature.State(connection: conn)) {
      ChatFeature()
    }
    // Forward-compat: events the UI doesn't model must not mutate state or crash.
    await store.send(.gatewayEvent(.unknown(type: "tool.progress", raw: .object([:]))))
  }

  @Test func sessionInfoUpdatesModelAndReasoningChip() async {
    let store = TestStore(initialState: ChatFeature.State(connection: conn)) {
      ChatFeature()
    }
    await store.send(.gatewayEvent(.sessionInfo(SessionInfo(model: "claude-opus-4-8", reasoningEffort: "high")))) {
      $0.model = "claude-opus-4-8"
      $0.reasoningEffort = "high"
    }
    // A later partial session.info (model only) must not clear the reasoning effort.
    await store.send(.gatewayEvent(.sessionInfo(SessionInfo(model: "claude-sonnet-4-6")))) {
      $0.model = "claude-sonnet-4-6"
    }
  }

  // MARK: Reconnect / backoff

  @Test func reconnectsAfterBackoffOnClose() async {
    let clock = TestClock()
    let store = TestStore(initialState: ChatFeature.State(connection: conn, status: .ready)) {
      ChatFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.uuid = .incrementing
      $0.hermesGateway.connect = { @Sendable _, _ in AsyncStream { _ in } } // stays open
    }

    await store.send(.gatewayClosed) {
      $0.status = .reconnecting
      $0.reconnectAttempt = 1
    }
    await clock.advance(by: .seconds(1)) // first backoff = 2^0 = 1s
    await store.receive(\.reconnectTick)
    await store.send(.onDisappear)
  }

  // MARK: Reconnect resilience — finalize a row that was mid-stream when the socket dropped

  @Test func closeFinalizesInFlightStreamingRow() async {
    let clock = TestClock()
    var initial = ChatFeature.State(connection: conn, status: .ready)
    initial.transcript = [ChatRow(id: uuid(0), kind: .message(role: .assistant, text: "Half", isComplete: false))]
    initial.streamingRowID = uuid(0)
    initial.thinkingRowID = uuid(1)
    initial.isSending = true
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.continuousClock = clock
      $0.uuid = .incrementing
      $0.hermesGateway.connect = { @Sendable _, _ in AsyncStream { _ in } }
    }

    await store.send(.gatewayClosed) {
      $0.status = .reconnecting
      $0.transcript[id: self.uuid(0)]?.kind = .message(role: .assistant, text: "Half", isComplete: true)
      $0.streamingRowID = nil
      $0.thinkingRowID = nil
      $0.isSending = false
      $0.reconnectAttempt = 1
    }
    await store.send(.onDisappear)
  }

  // MARK: Copy a row to the pasteboard

  @Test func copyRowPutsTextOnPasteboard() async {
    let copied = LockIsolated<String?>(nil)
    var initial = ChatFeature.State(connection: conn)
    initial.transcript = [ChatRow(id: uuid(0), kind: .message(role: .assistant, text: "copy me", isComplete: true))]
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.pasteboard.copy = { @Sendable text in copied.setValue(text) }
    }

    await store.send(.copyRow(id: uuid(0)))
    await store.finish()
    #expect(copied.value == "copy me")
  }

  @Test func copyUnknownRowIsNoOp() async {
    let store = TestStore(initialState: ChatFeature.State(connection: conn)) { ChatFeature() }
    await store.send(.copyRow(id: uuid(9))) // no such row → no effect, no state change
  }

  // MARK: Copy a code block with transient checkmark feedback (#9)

  @Test func copyCodePutsTextOnPasteboardAndShowsThenClearsCheckmark() async {
    let copied = LockIsolated<String?>(nil)
    let clock = TestClock()
    let store = TestStore(initialState: ChatFeature.State(connection: conn)) { ChatFeature() } withDependencies: {
      $0.pasteboard.copy = { @Sendable text in copied.setValue(text) }
      $0.continuousClock = clock
    }

    await store.send(.copyCode(text: "let x = 1", token: "row#0")) {
      $0.recentlyCopiedToken = "row#0"
    }
    #expect(copied.value == "let x = 1")

    await clock.advance(by: .seconds(1.5))
    await store.receive(\.copyFeedbackExpired) {
      $0.recentlyCopiedToken = nil
    }
  }

  @Test func copyingAnotherBlockMovesTheCheckmarkAndRestartsTimer() async {
    let clock = TestClock()
    let store = TestStore(initialState: ChatFeature.State(connection: conn)) { ChatFeature() } withDependencies: {
      $0.pasteboard.copy = { @Sendable _ in }
      $0.continuousClock = clock
    }

    await store.send(.copyCode(text: "a", token: "t1")) { $0.recentlyCopiedToken = "t1" }
    // Re-tapping before the first timer fires cancels it (cancelInFlight) and the
    // checkmark moves to the new block — only the second expiry arrives.
    await store.send(.copyCode(text: "b", token: "t2")) { $0.recentlyCopiedToken = "t2" }

    await clock.advance(by: .seconds(1.5))
    await store.receive(\.copyFeedbackExpired) { $0.recentlyCopiedToken = nil }
  }

  @Test func copyEmptyCodeIsNoOp() async {
    let store = TestStore(initialState: ChatFeature.State(connection: conn)) { ChatFeature() }
    await store.send(.copyCode(text: "", token: "t")) // guard → no effect, no state change
  }

  @Test func staleFeedbackExpiryDoesNotClearNewerCheckmark() async {
    // A late expiry for an old token must not wipe a checkmark that has since moved.
    var state = ChatFeature.State(connection: conn)
    state.recentlyCopiedToken = "current"
    let store = TestStore(initialState: state) { ChatFeature() }
    await store.send(.copyFeedbackExpired(token: "stale")) // token mismatch → unchanged
  }

  // MARK: Voice input (#7)

  /// Drive the common path up to an active recording with the test recorder's 3 canned
  /// level samples already folded in. Caller owns the clock so the timer stays paused.
  private func startRecording(_ store: TestStore<ChatFeature.State, ChatFeature.Action>) async {
    await store.send(.voiceButtonTapped) { $0.recording = .requestingPermission }
    await store.receive(\.recordingPermission)
    await store.receive(\.recordingStarted) { $0.recording = .recording }
    await store.receive(\.recordingLevel) { $0.waveformLevels = [0.2] }
    await store.receive(\.recordingLevel) { $0.waveformLevels = [0.2, 0.6] }
    await store.receive(\.recordingLevel) { $0.waveformLevels = [0.2, 0.6, 0.4] }
  }

  @Test func voiceRecordingTranscribesAndAppendsToComposer() async {
    var initial = ChatFeature.State(connection: conn)
    initial.composerText = "draft"
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.continuousClock = TestClock() // unadvanced → recording timer never ticks here
      $0.audioRecorder = .testValue
      $0.hermesREST.transcribe = { @Sendable _, _, _ in "hello world" }
    }

    await startRecording(store)

    await store.send(.voiceButtonTapped) { $0.recording = .transcribing }
    await store.receive(\.recordingStopped)
    await store.receive(\.transcriptionSucceeded) {
      $0.recording = .idle
      $0.waveformLevels = []
      $0.composerText = "draft hello world" // appended with a separating space
    }
  }

  @Test func voicePermissionDeniedShowsBanner() async {
    let store = TestStore(initialState: ChatFeature.State(connection: conn)) { ChatFeature() } withDependencies: {
      $0.continuousClock = TestClock()
      $0.audioRecorder = .testValue
      $0.audioRecorder.requestPermission = { @Sendable in false }
    }

    await store.send(.voiceButtonTapped) { $0.recording = .requestingPermission }
    await store.receive(\.recordingPermission) {
      $0.recording = .idle
      $0.errorBanner = "Microphone access is off. Enable it in Settings to use voice input."
    }
  }

  @Test func voiceTranscriptionFailureSurfacesServerReason() async {
    let store = TestStore(initialState: ChatFeature.State(connection: conn)) { ChatFeature() } withDependencies: {
      $0.continuousClock = TestClock()
      $0.audioRecorder = .testValue
      $0.hermesREST.transcribe = { @Sendable _, _, _ in throw RESTError.transcriptionFailed("no speech detected") }
    }

    await startRecording(store)

    await store.send(.voiceButtonTapped) { $0.recording = .transcribing }
    await store.receive(\.recordingStopped)
    await store.receive(\.voiceInputFailed) {
      $0.recording = .idle
      $0.waveformLevels = []
      $0.errorBanner = "no speech detected"
    }
  }

  @Test func recordingTimerAdvancesElapsedSeconds() async {
    let clock = TestClock()
    let store = TestStore(initialState: ChatFeature.State(connection: conn)) { ChatFeature() } withDependencies: {
      $0.continuousClock = clock
      $0.audioRecorder = .testValue
    }

    await startRecording(store)

    await clock.advance(by: .seconds(2))
    await store.receive(\.recordingTick) { $0.recordingSeconds = 1 }
    await store.receive(\.recordingTick) { $0.recordingSeconds = 2 }

    // Cancelling tears down the timer/levels and discards the recording.
    await store.send(.recordingCancelled) {
      $0.recording = .idle
      $0.waveformLevels = []
      $0.recordingSeconds = 0
    }
  }

  // MARK: Attachments (#8)

  private func imageAttachment(_ n: Int) -> ComposerAttachment {
    ComposerAttachment(
      id: uuid(n), kind: .image, filename: "photo\(n).png",
      mimeType: "image/png", data: Data([0x89, 0x50, UInt8(n)])
    )
  }

  @Test func attachmentAddAndRemove() async {
    let store = TestStore(initialState: ChatFeature.State(connection: conn)) { ChatFeature() }
    let a = imageAttachment(0)
    let b = imageAttachment(1)
    await store.send(.attachmentAdded(a)) { $0.attachments = [a] }
    await store.send(.attachmentAdded(b)) { $0.attachments = [a, b] }
    await store.send(.removeAttachment(id: a.id)) { $0.attachments = [b] }
  }

  @Test func attachmentOnlyMessageIsSendable() {
    var state = ChatFeature.State(connection: conn)
    state.liveSessionID = "live"
    #expect(state.canSend == false) // empty text + no attachments
    state.attachments = [imageAttachment(0)]
    #expect(state.canSend == true) // an attachment alone is enough to send
  }
}
