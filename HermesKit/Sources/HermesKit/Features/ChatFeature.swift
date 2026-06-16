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
    /// Draft text for the rename alert. `nil` = alert closed; non-nil = alert open
    /// with the in-progress title (Task 4).
    public var renameDraft: String?
    /// Token of the code block whose copy button was most recently tapped, for the
    /// transient "copied" checkmark. Cleared by a clock-driven effect (#9).
    public var recentlyCopiedToken: String?
    /// Voice-input recording lifecycle (#7).
    public var recording: RecordingState
    /// Rolling window of normalized (0...1) mic amplitudes driving the recording waveform.
    public var waveformLevels: [Float]
    /// Seconds elapsed while recording, for the composer's mm:ss readout.
    public var recordingSeconds: Int
    /// Files staged for the next message (#8), uploaded on submit.
    public var attachments: [ComposerAttachment]
    /// Set once the agent rejects an attach RPC as unknown (`-32601`) — too old to support
    /// uploads. Hides the attach affordance for the rest of the session.
    public var attachmentsUnsupported: Bool

    /// Voice-input state machine: tap mic → permission → record (waveform) → stop →
    /// transcribe → text appended to the composer.
    public enum RecordingState: Equatable, Sendable {
      case idle
      case requestingPermission
      case recording
      case transcribing

      /// Anything other than `.idle` means the composer is in voice mode.
      public var isBusy: Bool { self != .idle }
    }

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
      self.renameDraft = nil
      self.recentlyCopiedToken = nil
      self.recording = .idle
      self.waveformLevels = []
      self.recordingSeconds = 0
      self.attachments = []
      self.attachmentsUnsupported = false
    }

    public var canSend: Bool {
      let hasContent = !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !attachments.isEmpty
      return hasContent
        && liveSessionID != nil
        && pendingInteraction == nil
    }

    /// Rename is only meaningful once we have a live session id (otherwise `confirmRename`
    /// silently no-ops) — drives whether the toolbar Rename control is enabled.
    public var canRename: Bool { liveSessionID != nil }
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
    case promptSubmitFailed(message: String)
    case interruptTapped
    case respondToApproval(approve: Bool, all: Bool)
    case respondToClarify(answer: String)
    case respondToSecret(value: String)
    case copyRow(id: ChatRow.ID)
    case copyCode(text: String, token: String)
    case copyFeedbackExpired(token: String)
    // Voice input (#7)
    case voiceButtonTapped
    case recordingPermission(Bool)
    case recordingStarted
    case recordingLevel(Float)
    case recordingTick
    case recordingStopped(RecordedAudio)
    case transcriptionSucceeded(String)
    case voiceInputFailed(message: String)
    case recordingCancelled
    case toolTapped(id: ChatRow.ID)
    case toolDetailDismissed
    case modelChipTapped
    case modelOptionsResponse(Result<ModelOptions, GatewayError>)
    case modelSelected(String)
    case reasoningSelected(String)
    case modelPickerDismissed
    case renameButtonTapped
    case confirmRename
    case renameFailed(previousTitle: String?)
    case cancelRename
    // Attachments (#8)
    case attachmentAdded(ComposerAttachment)
    case removeAttachment(id: ComposerAttachment.ID)
  }

  private enum CancelID { case socket, reconnect, copyFeedback, voiceLevels, voiceTimer }

  @Dependency(\.hermesGateway) var gateway
  @Dependency(\.hermesREST) var rest
  @Dependency(\.continuousClock) var clock
  @Dependency(\.uuid) var uuid
  @Dependency(\.pasteboard) var pasteboard
  @Dependency(\.audioRecorder) var audioRecorder
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
        let wasRecording = state.recording.isBusy
        state.recording = .idle
        state.waveformLevels = []
        state.recordingSeconds = 0
        return .merge(
          .cancel(id: CancelID.socket),
          .cancel(id: CancelID.reconnect),
          .cancel(id: CancelID.voiceLevels),
          .cancel(id: CancelID.voiceTimer),
          // Release the mic/session if we leave mid-recording.
          wasRecording ? .run { [audioRecorder] _ in await audioRecorder.cancel() } : .none
        )

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
        // Seed the transcript from REST history. user/assistant text → message rows;
        // `tool` rows → reconstructed tool rows (so resumed sessions show tool/skill
        // activity). Empty-content turns (an assistant tool-call turn with no text) are
        // dropped so they don't render as blank bubbles.
        // Index tool-call args by id so a `tool` result row can show the command it ran.
        var argsByCallID: [String: String] = [:]
        for message in messages {
          for call in message.toolCalls ?? [] {
            if let id = call.id, let args = call.arguments?.nonEmpty { argsByCallID[id] = args }
          }
        }
        let rows = messages.compactMap { historyRow(from: $0, argsByCallID: argsByCallID) }
        state.transcript.insert(contentsOf: rows, at: 0)
        return .none

      case .composerSubmitted:
        guard state.canSend, let sessionID = state.liveSessionID else { return .none }
        let text = state.composerText
        state.transcript.append(ChatRow(id: uuid(), kind: .message(role: .user, text: text, isComplete: true)))
        state.composerText = ""
        state.errorBanner = nil
        state.isSending = true
        // prompt.submit acks fast (`{status:"streaming"}`); the turn streams via events,
        // so success does nothing here — only a thrown error (timeout / server / drop)
        // surfaces. Don't swallow it (Issue #6: a stuck server left the spinner hung).
        return .run { [gateway] send in
          do {
            _ = try await gateway.send("prompt.submit", .object([
              "session_id": .string(sessionID), "text": .string(text),
            ]))
          } catch let error as GatewayError {
            await send(.promptSubmitFailed(message: error.message))
          } catch {
            await send(.promptSubmitFailed(message: GatewayError.disconnected.message))
          }
        }

      case let .promptSubmitFailed(message):
        state.errorBanner = "Prompt failed: \(message)"
        state.isSending = false
        state.activity = nil
        return .none

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

      case let .copyCode(text, token):
        guard !text.isEmpty else { return .none }
        state.recentlyCopiedToken = token
        // Copy now; clear the checkmark after a beat. Re-tapping any block restarts
        // the timer (cancelInFlight) so the latest copy owns the feedback.
        return .merge(
          .run { [pasteboard] _ in pasteboard.copy(text) },
          .run { [clock] send in
            try await clock.sleep(for: .seconds(1.5))
            await send(.copyFeedbackExpired(token: token))
          }
          .cancellable(id: CancelID.copyFeedback, cancelInFlight: true)
        )

      case let .copyFeedbackExpired(token):
        if state.recentlyCopiedToken == token { state.recentlyCopiedToken = nil }
        return .none

      // MARK: Voice input (#7)

      case .voiceButtonTapped:
        switch state.recording {
        case .idle:
          state.recording = .requestingPermission
          return .run { [audioRecorder] send in
            await send(.recordingPermission(audioRecorder.requestPermission()))
          }
        case .recording:
          // Stop and hand the audio off to transcription.
          state.recording = .transcribing
          return .merge(
            .cancel(id: CancelID.voiceLevels),
            .cancel(id: CancelID.voiceTimer),
            .run { [audioRecorder] send in
              await send(.recordingStopped(try await audioRecorder.stopRecording()))
            } catch: { _, send in
              await send(.voiceInputFailed(message: "Couldn’t finish recording."))
            }
          )
        case .requestingPermission, .transcribing:
          return .none
        }

      case let .recordingPermission(granted):
        guard granted else {
          state.recording = .idle
          state.errorBanner = "Microphone access is off. Enable it in Settings to use voice input."
          return .none
        }
        return .run { [audioRecorder] send in
          try await audioRecorder.startRecording()
          await send(.recordingStarted)
        } catch: { _, send in
          await send(.voiceInputFailed(message: "Couldn’t start recording."))
        }

      case .recordingStarted:
        state.recording = .recording
        state.waveformLevels = []
        state.recordingSeconds = 0
        return .merge(
          .run { [audioRecorder] send in
            for await level in audioRecorder.levels() {
              await send(.recordingLevel(level))
            }
          }
          .cancellable(id: CancelID.voiceLevels, cancelInFlight: true),
          .run { [clock] send in
            while true {
              try await clock.sleep(for: .seconds(1))
              await send(.recordingTick)
            }
          }
          .cancellable(id: CancelID.voiceTimer, cancelInFlight: true)
        )

      case let .recordingLevel(level):
        state.waveformLevels.append(level)
        let maxBars = 48
        if state.waveformLevels.count > maxBars {
          state.waveformLevels.removeFirst(state.waveformLevels.count - maxBars)
        }
        return .none

      case .recordingTick:
        state.recordingSeconds += 1
        return .none

      case let .recordingStopped(audio):
        return .run { [rest, connection = state.connection] send in
          do {
            let text = try await rest.transcribe(connection, audio.dataURL, audio.mimeType)
            await send(.transcriptionSucceeded(text))
          } catch {
            let message = (error as? RESTError)?.message ?? "Couldn’t transcribe the audio."
            await send(.voiceInputFailed(message: message))
          }
        }

      case let .transcriptionSucceeded(text):
        state.recording = .idle
        state.waveformLevels = []
        state.recordingSeconds = 0
        let transcript = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !transcript.isEmpty {
          // Append to whatever's already typed, with a single separating space.
          if state.composerText.isEmpty {
            state.composerText = transcript
          } else {
            state.composerText += (state.composerText.hasSuffix(" ") ? "" : " ") + transcript
          }
        }
        return .none

      case let .voiceInputFailed(message):
        state.recording = .idle
        state.waveformLevels = []
        state.recordingSeconds = 0
        state.errorBanner = message
        return .merge(.cancel(id: CancelID.voiceLevels), .cancel(id: CancelID.voiceTimer))

      case .recordingCancelled:
        state.recording = .idle
        state.waveformLevels = []
        state.recordingSeconds = 0
        return .merge(
          .cancel(id: CancelID.voiceLevels),
          .cancel(id: CancelID.voiceTimer),
          .run { [audioRecorder] _ in await audioRecorder.cancel() }
        )

      // MARK: Attachments (#8)

      case let .attachmentAdded(attachment):
        state.attachments.append(attachment)
        return .none

      case let .removeAttachment(id):
        state.attachments.removeAll { $0.id == id }
        return .none

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

      case .renameButtonTapped:
        // Pre-fill the alert with the current title.
        state.renameDraft = state.title ?? ""
        return .none

      case .confirmRename:
        guard let sessionID = state.liveSessionID, let draft = state.renameDraft else {
          state.renameDraft = nil
          return .none
        }
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // The gateway `session.title` method rejects an empty title (server error 4021),
        // so an empty/whitespace draft is a no-op: just close the alert, don't round-trip.
        guard !trimmed.isEmpty else {
          state.renameDraft = nil
          return .none
        }
        let previousTitle = state.title
        // Optimistic: update the header immediately; roll back on RPC failure.
        state.title = trimmed
        state.renameDraft = nil
        state.errorBanner = nil
        return .run { [gateway] send in
          do {
            _ = try await gateway.send("session.title", .object([
              "session_id": .string(sessionID),
              "title": .string(trimmed),
            ]))
          } catch {
            await send(.renameFailed(previousTitle: previousTitle))
          }
        }

      case let .renameFailed(previousTitle):
        state.title = previousTitle
        state.errorBanner = "Couldn’t rename the session."
        return .none

      case .cancelRename:
        state.renameDraft = nil
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
      // New sessions send no title so the server auto-names from the first message
      // (passing any title disables Hermes' auto-title generation).
      let params: JSONValue = stored.map { .object(["session_id": .string($0)]) }
        ?? .object([:])
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

  /// Map a stored history message to a transcript row. `user`/`assistant` text → message
  /// rows (empty turns dropped — an assistant tool-call turn has no text); `tool` rows →
  /// reconstructed tool rows with the command (args, looked up by `tool_call_id`) and
  /// result. Other roles are skipped.
  private func historyRow(from message: SessionMessage, argsByCallID: [String: String]) -> ChatRow? {
    switch message.role {
    case "user", "assistant":
      guard let text = message.content?.nonEmpty else { return nil }
      let role: ChatRow.Role = message.role == "user" ? .user : .assistant
      return ChatRow(id: uuid(), kind: .message(role: role, text: text, isComplete: true))
    case "tool":
      let name = message.toolName?.nonEmpty ?? "tool"
      let argsString = message.toolCallID.flatMap { argsByCallID[$0] }
      let parsedArgs = argsString.flatMap(Self.parseArgs)
      let detail = ToolDetail(
        argsText: parsedArgs == nil ? argsString : nil,
        args: parsedArgs,
        resultText: message.content?.nonEmpty
      )
      return ChatRow(id: uuid(), kind: .tool(
        name: name, title: name, state: .complete,
        detail: detail.isEmpty ? nil : detail, durationS: nil
      ))
    default:
      return nil
    }
  }

  /// Parse a tool-call `arguments` JSON string into a structured value for the detail
  /// sheet — only when it's an object (a bare scalar stays raw text).
  private static func parseArgs(_ string: String) -> JSONValue? {
    guard let data = string.data(using: .utf8),
          let value = try? JSONDecoder().decode(JSONValue.self, from: data),
          case .object = value
    else { return nil }
    return value
  }
}

private func backoffDelay(attempt: Int) -> Duration {
  .seconds(min(30.0, pow(2.0, Double(max(0, attempt - 1)))))
}
