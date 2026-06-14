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
    /// A blocking request from the agent (approval/clarify/secret). While set, the
    /// composer is disabled and a card is the focal point.
    public var pendingInteraction: PendingInteraction?
    /// The tool/skill row whose detail sheet is open, if any (Task 4).
    public var presentedTool: ChatRow?
    /// Current model + reasoning effort (from `session.info`), shown in the composer chip.
    public var model: String?
    public var reasoningEffort: String?
    /// The model/reasoning picker sheet, when open (Task 7).
    public var modelPicker: ModelPicker?

    /// State for the interactive model + reasoning-effort picker.
    public struct ModelPicker: Equatable, Sendable {
      public var isLoading: Bool
      public var options: ModelOptions?
      public var error: String?

      public init(isLoading: Bool = true, options: ModelOptions? = nil, error: String? = nil) {
        self.isLoading = isLoading
        self.options = options
        self.error = error
      }
    }

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

    /// A blocking interactive request the agent is waiting on.
    public enum PendingInteraction: Equatable, Sendable {
      case approval(ApprovalRequest)
      case clarify(ClarifyRequest)        // wired in Task 10
      case secret(SecretKind, SecretPrompt) // wired in Task 10

      public enum SecretKind: Equatable, Sendable { case sudo, secret }
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
      self.pendingInteraction = nil
      self.presentedTool = nil
      self.model = nil
      self.reasoningEffort = nil
      self.modelPicker = nil
    }

    public var canSend: Bool {
      !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && liveSessionID != nil
        && pendingInteraction == nil
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
    case respondToApproval(approve: Bool, all: Bool)
    case respondToClarify(answer: String)
    case respondToSecret(value: String)
    case copyRow(id: ChatRow.ID)
    case toolTapped(id: ChatRow.ID)
    case toolDetailDismissed
    case modelChipTapped
    case modelOptionsResponse(Result<ModelOptions, GatewayError>)
    case modelSelected(String)
    case reasoningSelected(String)
    case modelPickerDismissed
  }

  private enum CancelID { case socket, reconnect }

  @Dependency(\.hermesGateway) var gateway
  @Dependency(\.hermesREST) var rest
  @Dependency(\.continuousClock) var clock
  @Dependency(\.uuid) var uuid
  @Dependency(\.pasteboard) var pasteboard
  @Dependency(\.debugLog) var debugLog

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
        // Finalize anything mid-stream so a dropped socket doesn't leave a row
        // spinning forever; the transcript itself persists across the reconnect.
        finalizeInFlight(into: &state)
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

      case let .respondToApproval(approve, all):
        guard case let .approval(request) = state.pendingInteraction,
              let sessionID = state.liveSessionID
        else { return .none }
        state.pendingInteraction = nil
        state.transcript.append(
          ChatRow(id: uuid(), kind: .status(kind: "approval", text: approve ? "Approved" : "Denied"))
        )
        let requestID = request.requestID
        let choice = approve ? "approve" : "deny"
        return .run { [gateway] _ in
          _ = try? await gateway.send("approval.respond", .object([
            "session_id": .string(sessionID),
            "request_id": .string(requestID),
            "choice": .string(choice),
            "all": .bool(all),
          ]))
        }

      case let .respondToClarify(answer):
        guard case let .clarify(request) = state.pendingInteraction,
              let sessionID = state.liveSessionID
        else { return .none }
        state.pendingInteraction = nil
        // Echo the answer so the transcript records what was chosen/typed.
        state.transcript.append(
          ChatRow(id: uuid(), kind: .status(kind: "clarify", text: answer))
        )
        let requestID = request.requestID
        return .run { [gateway] _ in
          _ = try? await gateway.send("clarify.respond", .object([
            "session_id": .string(sessionID),
            "request_id": .string(requestID),
            "answer": .string(answer),
          ]))
        }

      case let .respondToSecret(value):
        guard case let .secret(kind, prompt) = state.pendingInteraction,
              let sessionID = state.liveSessionID
        else { return .none }
        state.pendingInteraction = nil
        // Never echo the secret value into the transcript.
        let label = kind == .sudo ? "Password submitted" : "Secret submitted"
        state.transcript.append(
          ChatRow(id: uuid(), kind: .status(kind: "secret", text: label))
        )
        // Method + value key differ per kind (verified against tui_gateway/server.py):
        // sudo.respond → "password", secret.respond → "value".
        let method = kind == .sudo ? "sudo.respond" : "secret.respond"
        let valueKey = kind == .sudo ? "password" : "value"
        let requestID = prompt.requestID
        return .run { [gateway] _ in
          _ = try? await gateway.send(method, .object([
            "session_id": .string(sessionID),
            "request_id": .string(requestID),
            valueKey: .string(value),
          ]))
        }

      case let .copyRow(id):
        guard let text = state.transcript[id: id]?.copyText, !text.isEmpty else { return .none }
        return .run { [pasteboard] _ in pasteboard.copy(text) }

      case let .toolTapped(id):
        guard let row = state.transcript[id: id], case .tool = row.kind else { return .none }
        state.presentedTool = row
        return .none

      case .toolDetailDismissed:
        state.presentedTool = nil
        return .none

      case .modelChipTapped:
        guard let sessionID = state.liveSessionID else { return .none }
        state.modelPicker = State.ModelPicker(isLoading: true)
        return .run { [gateway] send in
          do {
            let result = try await gateway.send("model.options", .object(["session_id": .string(sessionID)]))
            if let options = result.decoded(ModelOptions.self) {
              await send(.modelOptionsResponse(.success(options)))
            } else {
              await send(.modelOptionsResponse(.failure(.server("Malformed model.options result"))))
            }
          } catch let error as GatewayError {
            await send(.modelOptionsResponse(.failure(error)))
          } catch {
            await send(.modelOptionsResponse(.failure(.disconnected)))
          }
        }

      case let .modelOptionsResponse(.success(options)):
        state.modelPicker?.isLoading = false
        state.modelPicker?.options = options
        return .none

      case let .modelOptionsResponse(.failure(error)):
        state.modelPicker?.isLoading = false
        state.modelPicker?.error = error.message
        return .none

      case let .modelSelected(model):
        // Blocked mid-turn (server returns 4009); the picker disables selection too.
        guard !state.isSending, let sessionID = state.liveSessionID else { return .none }
        state.model = model // optimistic; reconciled by the next session.info
        return configSet(key: "model", value: model, sessionID: sessionID)

      case let .reasoningSelected(effort):
        guard !state.isSending, let sessionID = state.liveSessionID else { return .none }
        state.reasoningEffort = effort
        return configSet(key: "reasoning", value: effort, sessionID: sessionID)

      case .modelPickerDismissed:
        state.modelPicker = nil
        return .none
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
      // Defer creating the assistant row until the first delta — a tool-only turn emits
      // message.start with no text, and an eager empty row renders as a blank bubble.
      state.streamingRowID = nil
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
      } else if !text.isEmpty {
        // No deltas arrived (non-streamed reply) — materialise the row now.
        state.transcript.append(ChatRow(id: uuid(), kind: .message(role: .assistant, text: text, isComplete: true)))
      }
      // else: empty tool-only turn → no row at all.
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

    case let .toolStart(toolID, name, title, argsText):
      let id = uuid()
      let detail = argsText.map { ToolDetail(argsText: $0) }
      state.transcript.append(ChatRow(id: id, kind: .tool(
        name: name, title: title?.nonEmpty ?? name, state: .running, detail: detail, durationS: nil
      )))
      if let toolID { state.toolRowIDs[toolID] = id }
      return .none

    case let .toolComplete(toolID, name, title, args, resultText, inlineDiff, durationS):
      let detail = ToolDetail(args: args, resultText: resultText?.nonEmpty, inlineDiff: inlineDiff?.nonEmpty)
      if let toolID, let id = state.toolRowIDs[toolID],
         case let .tool(existingName, existingTitle, _, existingDetail, _) = state.transcript[id: id]?.kind {
        // Merge: keep the start-time args_text; fill in result/diff/structured args.
        let merged = ToolDetail(
          argsText: existingDetail?.argsText,
          args: detail.args, resultText: detail.resultText, inlineDiff: detail.inlineDiff
        )
        state.transcript[id: id]?.kind = .tool(
          name: name ?? existingName,
          title: title?.nonEmpty ?? existingTitle,
          state: .complete,
          detail: merged.isEmpty ? nil : merged,
          durationS: durationS
        )
      } else {
        // tool.complete with no prior start — create the row directly.
        let resolvedName = name ?? ""
        state.transcript.append(ChatRow(id: uuid(), kind: .tool(
          name: resolvedName,
          title: title?.nonEmpty ?? resolvedName,
          state: .complete,
          detail: detail.isEmpty ? nil : detail,
          durationS: durationS
        )))
      }
      return .none

    case let .error(message):
      state.errorBanner = message
      state.isSending = false
      return .none

    case let .approvalRequest(request):
      state.pendingInteraction = .approval(request)
      state.activity = nil
      return .none

    case let .clarifyRequest(request):
      state.pendingInteraction = .clarify(request)
      state.activity = nil
      return .none

    case let .sudoRequest(prompt):
      state.pendingInteraction = .secret(.sudo, prompt)
      state.activity = nil
      return .none

    case let .secretRequest(prompt):
      state.pendingInteraction = .secret(.secret, prompt)
      state.activity = nil
      return .none

    case let .sessionInfo(info):
      // Update the model/reasoning chip; later session.info events can be partial, so
      // only overwrite fields that are present.
      if let model = info.model?.nonEmpty { state.model = model }
      if let effort = info.reasoningEffort?.nonEmpty { state.reasoningEffort = effort }
      return .none

    case .unknown:
      return .none
    }
  }

  private func appendToStreamingMessage(_ text: String, into state: inout State) {
    if let id = state.streamingRowID,
       case let .message(role, existing, _) = state.transcript[id: id]?.kind {
      state.transcript[id: id]?.kind = .message(role: role, text: existing + text, isComplete: false)
    } else {
      // First delta of the turn — create the assistant row lazily (see `.messageStart`).
      let id = uuid()
      state.transcript.append(ChatRow(id: id, kind: .message(role: .assistant, text: text, isComplete: false)))
      state.streamingRowID = id
    }
  }

  /// Close out any row that was still streaming when the socket dropped: mark the
  /// in-flight assistant message complete and clear the streaming/thinking pointers
  /// so reconnect starts clean. Idempotent.
  private func finalizeInFlight(into state: inout State) {
    if let id = state.streamingRowID,
       case let .message(role, text, _) = state.transcript[id: id]?.kind {
      state.transcript[id: id]?.kind = .message(role: role, text: text, isComplete: true)
    }
    state.streamingRowID = nil
    state.thinkingRowID = nil
    state.isSending = false
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
    .run { [gateway, debugLog] send in
      for await event in gateway.connect(connection.baseURL, connection.token) {
        debugLog.append(event) // mirror into the app-wide debug buffer (Task 12)
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

  /// Change a session setting (model / reasoning) over the gateway. Fire-and-forget —
  /// the authoritative value comes back on the next `session.info`.
  private func configSet(key: String, value: String, sessionID: String) -> Effect<Action> {
    .run { [gateway] _ in
      _ = try? await gateway.send("config.set", .object([
        "session_id": .string(sessionID),
        "key": .string(key),
        "value": .string(value),
      ]))
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
