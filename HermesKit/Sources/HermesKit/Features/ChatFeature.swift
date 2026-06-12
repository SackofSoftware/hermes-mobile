import ComposableArchitecture
import Foundation

/// The live chat surface for one session. Owns the WebSocket lifecycle, folds the
/// gateway event stream into a transcript, sends prompts, and reconnects with backoff.
///
/// Session bootstrap (unified): the first `gateway.ready` with no stored id sends
/// `session.create`; any ready *with* a stored id (resume entry, or a reconnect after
/// we've learned the id) sends `session.resume`. History is hydrated over REST.
///
/// Streaming fold rules are verified against the M0 probe: message events carry no id,
/// so a single in-flight assistant row is tracked; `session_id` is frame-level.
@Reducer
public struct ChatFeature {
  @ObservableState
  public struct State: Equatable {
    public var connection: ServerConnection
    public var title: String?
    public var transcript: IdentifiedArrayOf<ChatRow>
    public var composerText: String
    public var status: Status
    public var activity: String?     // latest status.update text (transient footer)
    public var errorBanner: String?
    public var isSending: Bool

    // Bookkeeping (internal).
    var liveSessionID: String?
    var storedSessionID: String?
    var streamingRowID: ChatRow.ID?
    var thinkingRowID: ChatRow.ID?
    var toolRowIDs: [String: ChatRow.ID]
    var reconnectAttempt: Int
    var hasRequestedSession: Bool

    public enum Status: Equatable, Sendable {
      case connecting
      case ready
      case reconnecting
    }

    public init(
      connection: ServerConnection,
      resumeStoredID: String? = nil,
      title: String? = nil,
      transcript: IdentifiedArrayOf<ChatRow> = [],
      composerText: String = "",
      status: Status = .connecting
    ) {
      self.connection = connection
      self.storedSessionID = resumeStoredID
      self.title = title
      self.transcript = transcript
      self.composerText = composerText
      self.status = status
      self.activity = nil
      self.errorBanner = nil
      self.isSending = false
      self.liveSessionID = nil
      self.streamingRowID = nil
      self.thinkingRowID = nil
      self.toolRowIDs = [:]
      self.reconnectAttempt = 0
      self.hasRequestedSession = false
    }

    public var canSend: Bool {
      !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && liveSessionID != nil
    }
  }

  public enum Action: BindableAction {
    case binding(BindingAction<State>)
    case task
    case onDisappear
    case gatewayEvent(GatewayEvent)
    case gatewayClosed
    case reconnectTick
    case sessionResult(Result<SessionHandle, GatewayError>)
    case historyResponse([SessionMessage])
    case composerSubmitted
    case interruptTapped
  }

  private enum CancelID { case socket, reconnect }

  @Dependency(\.hermesGateway) var gateway
  @Dependency(\.hermesREST) var rest
  @Dependency(\.continuousClock) var clock
  @Dependency(\.uuid) var uuid

  public init() {}

  public var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case .task:
        var effects: [Effect<Action>] = [connect(state.connection)]
        if let stored = state.storedSessionID {
          effects.append(loadHistory(stored, connection: state.connection))
        }
        return .merge(effects)

      case .onDisappear:
        return .merge(.cancel(id: CancelID.socket), .cancel(id: CancelID.reconnect))

      case let .gatewayEvent(event):
        return reduce(event: event, into: &state)

      case .gatewayClosed:
        state.status = .reconnecting
        state.hasRequestedSession = false
        state.reconnectAttempt += 1
        let delay = backoffDelay(attempt: state.reconnectAttempt)
        return .run { [clock] send in
          try await clock.sleep(for: delay)
          await send(.reconnectTick)
        }
        .cancellable(id: CancelID.reconnect, cancelInFlight: true)

      case .reconnectTick:
        return connect(state.connection)

      case let .sessionResult(.success(handle)):
        state.liveSessionID = handle.sessionID
        state.storedSessionID = handle.storedSessionID ?? state.storedSessionID
        state.status = .ready
        return .none

      case let .sessionResult(.failure(error)):
        state.errorBanner = error.message
        return .none

      case let .historyResponse(messages):
        // Seed the transcript with prior user/assistant messages (REST hydration).
        let rows = messages.compactMap { message -> ChatRow? in
          guard let role = ChatRow.Role(restRole: message.role) else { return nil }
          return ChatRow(id: uuid(), kind: .message(role: role, text: message.content ?? "", isComplete: true))
        }
        state.transcript.insert(contentsOf: rows, at: 0)
        return .none

      case .composerSubmitted:
        guard state.canSend, let sessionID = state.liveSessionID else { return .none }
        let text = state.composerText
        state.transcript.append(ChatRow(id: uuid(), kind: .message(role: .user, text: text, isComplete: true)))
        state.composerText = ""
        state.errorBanner = nil
        state.isSending = true
        return .run { [gateway] _ in
          _ = try? await gateway.send("prompt.submit", .object([
            "session_id": .string(sessionID), "text": .string(text),
          ]))
        }

      case .interruptTapped:
        guard let sessionID = state.liveSessionID else { return .none }
        state.isSending = false
        return .run { [gateway] _ in
          _ = try? await gateway.send("session.interrupt", .object(["session_id": .string(sessionID)]))
        }
      }
    }
  }

  // MARK: - Event fold

  private func reduce(event: GatewayEvent, into state: inout State) -> Effect<Action> {
    switch event {
    case .ready:
      state.status = .ready
      state.reconnectAttempt = 0
      guard !state.hasRequestedSession else { return .none }
      state.hasRequestedSession = true
      return bootstrapSession(stored: state.storedSessionID)

    case .messageStart:
      let id = uuid()
      state.transcript.append(ChatRow(id: id, kind: .message(role: .assistant, text: "", isComplete: false)))
      state.streamingRowID = id
      state.thinkingRowID = nil
      state.activity = nil
      state.errorBanner = nil
      state.isSending = true
      return .none

    case let .messageDelta(text):
      appendToStreamingMessage(text, into: &state)
      return .none

    case let .messageComplete(text, _):
      if let id = state.streamingRowID {
        state.transcript[id: id]?.kind = .message(role: .assistant, text: text, isComplete: true)
      }
      state.streamingRowID = nil
      state.thinkingRowID = nil
      state.activity = nil
      state.isSending = false
      return .none

    case let .thinkingDelta(text):
      appendToThinking(text, into: &state)
      return .none

    case let .reasoningAvailable(text):
      appendToThinking(text, into: &state)
      return .none

    case let .statusUpdate(_, text):
      state.activity = text
      return .none

    case let .toolStart(toolID, name, _):
      let id = uuid()
      state.transcript.append(ChatRow(id: id, kind: .tool(name: name, state: .running, result: nil, durationS: nil)))
      if let toolID { state.toolRowIDs[toolID] = id }
      return .none

    case let .toolComplete(toolID, name, result, durationS):
      if let toolID, let id = state.toolRowIDs[toolID], case let .tool(existing, _, _, _) = state.transcript[id: id]?.kind {
        state.transcript[id: id]?.kind = .tool(name: name ?? existing, state: .complete, result: result, durationS: durationS)
      }
      return .none

    case let .error(message):
      state.errorBanner = message
      state.isSending = false
      return .none

    case .sessionInfo, .approvalRequest, .clarifyRequest, .sudoRequest, .secretRequest, .unknown:
      // sessionInfo: not needed yet. Interactive requests: handled in M2 (Tasks 9–10).
      return .none
    }
  }

  private func appendToStreamingMessage(_ text: String, into state: inout State) {
    guard let id = state.streamingRowID,
          case let .message(role, existing, _) = state.transcript[id: id]?.kind
    else { return }
    state.transcript[id: id]?.kind = .message(role: role, text: existing + text, isComplete: false)
  }

  private func appendToThinking(_ text: String, into state: inout State) {
    if let id = state.thinkingRowID, case let .thinking(existing) = state.transcript[id: id]?.kind {
      state.transcript[id: id]?.kind = .thinking(text: existing + text)
    } else {
      let id = uuid()
      state.transcript.append(ChatRow(id: id, kind: .thinking(text: text)))
      state.thinkingRowID = id
    }
  }

  // MARK: - Effects

  private func connect(_ connection: ServerConnection) -> Effect<Action> {
    .run { [gateway] send in
      for await event in gateway.connect(connection.baseURL, connection.token) {
        await send(.gatewayEvent(event))
      }
      await send(.gatewayClosed)
    }
    .cancellable(id: CancelID.socket, cancelInFlight: true)
  }

  private func bootstrapSession(stored: String?) -> Effect<Action> {
    .run { [gateway] send in
      let method = stored == nil ? "session.create" : "session.resume"
      let params: JSONValue = stored.map { .object(["session_id": .string($0)]) }
        ?? .object(["title": .string("Mobile chat")])
      do {
        let result = try await gateway.send(method, params)
        if let handle = result.decoded(SessionHandle.self) {
          await send(.sessionResult(.success(handle)))
        } else {
          await send(.sessionResult(.failure(.server("Malformed \(method) result"))))
        }
      } catch let error as GatewayError {
        await send(.sessionResult(.failure(error)))
      } catch {
        await send(.sessionResult(.failure(.disconnected)))
      }
    }
  }

  private func loadHistory(_ storedID: String, connection: ServerConnection) -> Effect<Action> {
    .run { [rest] send in
      if let messages = try? await rest.messages(connection, storedID) {
        await send(.historyResponse(messages))
      }
    }
  }
}

private func backoffDelay(attempt: Int) -> Duration {
  .seconds(min(30.0, pow(2.0, Double(max(0, attempt - 1)))))
}

private extension ChatRow.Role {
  init?(restRole: String) {
    switch restRole {
    case "user": self = .user
    case "assistant": self = .assistant
    default: return nil // skip tool/system messages in history for MVP
    }
  }
}
