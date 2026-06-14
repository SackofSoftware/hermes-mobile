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

    await store.send(.gatewayEvent(.messageStart)) {
      $0.transcript = [ChatRow(id: uuid(0), kind: .message(role: .assistant, text: "", isComplete: false))]
      $0.streamingRowID = uuid(0)
      $0.isSending = true
    }
    await store.send(.gatewayEvent(.messageDelta(text: "Hel"))) {
      $0.transcript[id: uuid(0)]?.kind = .message(role: .assistant, text: "Hel", isComplete: false)
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
      $0.transcript.append(ChatRow(id: uuid(1), kind: .message(role: .assistant, text: "", isComplete: false)))
      $0.streamingRowID = uuid(1)
      $0.thinkingRowID = nil
      $0.isSending = true
    }
    await store.send(.gatewayEvent(.messageComplete(text: "pong", usage: nil))) {
      $0.transcript[id: uuid(1)]?.kind = .message(role: .assistant, text: "pong", isComplete: true)
      $0.streamingRowID = nil
      $0.isSending = false
    }
  }

  @Test func toolStartThenComplete() async {
    let store = TestStore(initialState: ChatFeature.State(connection: conn)) {
      ChatFeature()
    } withDependencies: { $0.uuid = .incrementing }

    await store.send(.gatewayEvent(.toolStart(toolID: "t1", name: "read_file", args: .object(["path": .string("/x")])))) {
      $0.transcript = [ChatRow(id: uuid(0), kind: .tool(name: "read_file", state: .running, result: nil, durationS: nil))]
      $0.toolRowIDs = ["t1": uuid(0)]
    }
    await store.send(.gatewayEvent(.toolComplete(toolID: "t1", name: "read_file", result: "ok", durationS: 1.5))) {
      $0.transcript[id: uuid(0)]?.kind = .tool(name: "read_file", state: .complete, result: "ok", durationS: 1.5)
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
    let store = TestStore(initialState: ChatFeature.State(connection: conn)) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = ImmediateClock()
      $0.hermesGateway.connect = { @Sendable _, _ in AsyncStream { $0.yield(.ready) } }
      $0.hermesGateway.send = { @Sendable _, _ in
        .object([
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

  @Test func historyResponseSeedsTranscriptSkippingNonChatRoles() async {
    let store = TestStore(initialState: ChatFeature.State(connection: conn)) {
      ChatFeature()
    } withDependencies: { $0.uuid = .incrementing }

    let messages = [
      SessionMessage(id: 1, role: "user", content: "Hi"),
      SessionMessage(id: 2, role: "assistant", content: "Hello"),
      SessionMessage(id: 3, role: "tool", content: "ignored"), // not user/assistant → skipped
    ]
    await store.send(.historyResponse(messages)) {
      $0.transcript = [
        ChatRow(id: self.uuid(0), kind: .message(role: .user, text: "Hi", isComplete: true)),
        ChatRow(id: self.uuid(1), kind: .message(role: .assistant, text: "Hello", isComplete: true)),
      ]
    }
  }

  @Test func unknownAndSessionInfoEventsAreInertInTheFold() async {
    let store = TestStore(initialState: ChatFeature.State(connection: conn)) {
      ChatFeature()
    }
    // Forward-compat: events the UI doesn't model must not mutate state or crash.
    await store.send(.gatewayEvent(.unknown(type: "tool.progress", raw: .object([:]))))
    await store.send(.gatewayEvent(.sessionInfo(SessionInfo(model: "claude"))))
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
}
