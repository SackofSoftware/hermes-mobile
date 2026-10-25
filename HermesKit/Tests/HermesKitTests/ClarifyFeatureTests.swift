import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

@MainActor
struct ClarifyFeatureTests {
  private let conn = ServerConnection(baseURL: URL(string: "http://mac.tailnet:9119")!, token: "t")
  private func uuid(_ n: Int) -> UUID {
    UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012x", n))")!
  }

  private func readyState() -> ChatFeature.State {
    var state = ChatFeature.State(connection: conn)
    state.liveSessionID = "live"
    return state
  }

  // MARK: - Request pins the card / blocks the composer

  @Test func clarifyRequestPinsCardAndBlocksComposer() async {
    let request = ClarifyRequest(requestID: "c1", question: "Which file?", choices: ["a.txt", "b.txt"])
    var initial = readyState()
    initial.composerText = "hi"
    let store = TestStore(initialState: initial) { ChatFeature() }
    #expect(store.state.canSend)

    await store.send(.gatewayEvent(.clarifyRequest(request))) {
      $0.pendingInteraction = .clarify(request)
      $0.pendingInteractionToken = 1
    }
    #expect(!store.state.canSend)
  }

  @Test func sudoRequestPinsSecretCard() async {
    let prompt = SecretPrompt(requestID: "s1")
    let store = TestStore(initialState: readyState()) { ChatFeature() }

    await store.send(.gatewayEvent(.sudoRequest(prompt))) {
      $0.pendingInteraction = .secret(.sudo, prompt)
      $0.pendingInteractionToken = 1
    }
  }

  @Test func secretRequestPinsSecretCard() async {
    let prompt = SecretPrompt(requestID: "s2", prompt: "API key for X")
    let store = TestStore(initialState: readyState()) { ChatFeature() }

    await store.send(.gatewayEvent(.secretRequest(prompt))) {
      $0.pendingInteraction = .secret(.secret, prompt)
      $0.pendingInteractionToken = 1
    }
  }

  // MARK: - Responses round-trip with exact RPC params

  @Test func clarifyResponseClearsEchoesAndSends() async {
    let request = ClarifyRequest(requestID: "c1", question: "Which file?", choices: ["a.txt"])
    let sent = LockIsolated<JSONValue?>(nil)
    var initial = readyState()
    initial.pendingInteraction = .clarify(request)
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.hermesGateway.send = { @Sendable method, params in
        sent.setValue(.object(["method": .string(method), "params": params]))
        return .object(["status": .string("ok")])
      }
    }

    await store.send(.submitClarify(answers: ["": .choices(["a.txt"])])) {
      $0.pendingInteraction = nil
      $0.transcript = [ChatRow(id: self.uuid(0), kind: .status(kind: "clarify", text: "a.txt"))]
    }
    await store.finish()

    #expect(sent.value?["method"]?.stringValue == "clarify.respond")
    #expect(sent.value?["params"]?["request_id"]?.stringValue == "c1")
    #expect(sent.value?["params"]?["answer"]?.stringValue == "a.txt")
  }

  @Test func sudoResponseSendsPasswordKeyAndDoesNotEchoValue() async {
    let prompt = SecretPrompt(requestID: "s1")
    let sent = LockIsolated<JSONValue?>(nil)
    var initial = readyState()
    initial.pendingInteraction = .secret(.sudo, prompt)
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.hermesGateway.send = { @Sendable method, params in
        sent.setValue(.object(["method": .string(method), "params": params]))
        return .object(["status": .string("ok")])
      }
    }

    await store.send(.respondToSecret(value: "hunter2")) {
      $0.pendingInteraction = nil
      $0.transcript = [ChatRow(id: self.uuid(0), kind: .status(kind: "secret", text: "Password submitted"))]
    }
    await store.finish()

    #expect(sent.value?["method"]?.stringValue == "sudo.respond")
    #expect(sent.value?["params"]?["request_id"]?.stringValue == "s1")
    #expect(sent.value?["params"]?["password"]?.stringValue == "hunter2")
    // The secret value must never appear in the transcript.
    #expect(store.state.transcript.allSatisfy { if case let .status(_, text) = $0.kind { return text != "hunter2" } else { return true } })
  }

  @Test func secretResponseSendsValueKey() async {
    let prompt = SecretPrompt(requestID: "s2", prompt: "API key")
    let sent = LockIsolated<JSONValue?>(nil)
    var initial = readyState()
    initial.pendingInteraction = .secret(.secret, prompt)
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.hermesGateway.send = { @Sendable method, params in
        sent.setValue(.object(["method": .string(method), "params": params]))
        return .object(["status": .string("ok")])
      }
    }

    await store.send(.respondToSecret(value: "sk-123")) {
      $0.pendingInteraction = nil
      $0.transcript = [ChatRow(id: self.uuid(0), kind: .status(kind: "secret", text: "Secret submitted"))]
    }
    await store.finish()

    #expect(sent.value?["method"]?.stringValue == "secret.respond")
    #expect(sent.value?["params"]?["value"]?.stringValue == "sk-123")
  }

  // MARK: - Guards

  @Test func respondClarifyIgnoredWhenNoClarifyPending() async {
    let store = TestStore(initialState: readyState()) { ChatFeature() }
    // No pending interaction → response is a no-op.
    await store.send(.submitClarify(answers: ["": .other("x")]))
    await store.send(.skipClarify)
  }

  // MARK: - v7 server requests: routing

  @Test func clarifyServerRequestDecodesBothV7Shapes() {
    let batch = PendingServerRequest(id: "srq-b", method: "clarify", params: .object([
      "session_id": .string("live"),
      "questions": .array([.object([
        "qid": .string("q0"), "question": .string("Framework?"),
        "choices": .array([.string("SwiftUI (Recommended)"), .string("UIKit")]), "multi_select": .bool(false),
      ])]),
    ]))
    #expect(batch == PendingServerRequest(id: "srq-b", kind: .clarify(ClarifyRequest(
      requestID: nil,
      questions: [ClarifyQuestion(qid: "q0", question: "Framework?", choices: ["SwiftUI (Recommended)", "UIKit"])],
      answerShape: .answers
    ))))

    let single = PendingServerRequest(id: "srq-s", method: "clarify", params: .object([
      "session_id": .string("live"), "question": .string("Proceed?"),
      "choices": .array([.string("Yes"), .string("No")]),
    ]))
    #expect(single == PendingServerRequest(
      id: "srq-s", kind: .clarify(ClarifyRequest(requestID: nil, question: "Proceed?", choices: ["Yes", "No"]))
    ))

    // A stray legacy `request_id` never makes a server request legacy: it is answered
    // through `request.answer` in the single shape.
    let stray = PendingServerRequest(id: "srq-r", method: "clarify", params: .object([
      "request_id": .string("r1"), "question": .string("Pick"),
      "choices": .array([.string("A"), .string("B")]), "multi_select": .bool(true),
    ]))
    #expect(stray == PendingServerRequest(
      id: "srq-r",
      kind: .clarify(ClarifyRequest(requestID: nil, question: "Pick", choices: ["A", "B"], multiSelect: true))
    ))
    if case let .clarify(request)? = stray?.kind { #expect(request.answerShape == .singleAnswer) }
  }

  @Test(arguments: [JSONValue.null, .array([]), .object(["session_id": .string("live")]),
                    .object(["question": .string("   ")]), .object(["request_id": .string("r1")]),
                    .object(["questions": .array([.object(["question": .string("no qid")])])])])
  func malformedClarifyServerRequestIsNotRendered(params: JSONValue) {
    #expect(PendingServerRequest(id: "srq-bad", method: "clarify", params: params) == nil)
    #expect(PendingServerRequest.malformedSkip(for: "clarify") == .object([:])) // cancel-all
  }

  // MARK: - v7 server requests: answers per shape

  private func clarifyServerRequest(_ id: String, _ request: ClarifyRequest) -> PendingServerRequest {
    PendingServerRequest(id: id, kind: .clarify(request))
  }

  private func presentedState(_ request: PendingServerRequest) -> ChatFeature.State {
    var state = readyState()
    state.serverRequests = [request]
    state.present(request.interaction)
    return state
  }

  /// Answers the presented clarify card with `action`, the server acknowledging `ok`, and
  /// returns the exact `request.answer` params that went out.
  private func answer(
    _ request: ClarifyRequest, with action: ChatFeature.Action, echo: String
  ) async -> JSONValue? {
    let pending = clarifyServerRequest("srq-c", request)
    let sent = LockIsolated<JSONValue?>(nil)
    let store = TestStore(initialState: presentedState(pending)) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.hermesGateway.send = { @Sendable method, params in
        #expect(method == "request.answer")
        sent.setValue(params)
        return .object(["status": .string("ok")])
      }
    }
    await store.send(action) {
      $0.answeringServerRequestID = "srq-c" // the card stays until the server acknowledges
    }
    await store.receive(\.serverRequestAnswered) {
      $0.answeringServerRequestID = nil
      $0.transcript = [ChatRow(id: self.uuid(0), kind: .status(kind: "clarify", text: echo))]
      $0.serverRequests = []
      $0.pendingInteraction = nil
    }
    return sent.value
  }

  private let batch = ClarifyRequest(
    requestID: nil,
    questions: [
      ClarifyQuestion(qid: "q0", question: "Framework?", choices: ["SwiftUI (Recommended)", "UIKit"]),
      ClarifyQuestion(qid: "q1", question: "Targets?", choices: ["iOS/iPadOS", "macOS"], multiSelect: true),
      ClarifyQuestion(qid: "q2", question: "Language?", choices: ["Swift", "ObjC"]),
      ClarifyQuestion(qid: "q3", question: "Name?"),
      ClarifyQuestion(qid: "q4", question: "Extras?", choices: ["Widgets", "Intents"], multiSelect: true),
    ],
    answerShape: .answers
  )

  /// The v0.21.6+ shape: bare choice labels, a multi-select JSON-array string (no `\/`),
  /// Other answers as typed on a single- and a multi-select question, `null` for the
  /// unanswered question.
  @Test func answersShapeSendsExactParams() async throws {
    let sent = await answer(batch, with: .submitClarify(answers: [
      "q0": .choices(["SwiftUI (Recommended)"]),
      "q1": .choices(["iOS/iPadOS", "macOS"]),
      "q2": .other("Kotlin"),
      "q4": .other("Watch app"),
    ]), echo: "Framework?: SwiftUI\nTargets?: iOS/iPadOS, macOS\nLanguage?: Kotlin\nName?: Skipped\nExtras?: Watch app")
    #expect(sent == .object([
      "id": .string("srq-c"),
      "result": .object(["answers": .object([
        "q0": .string("SwiftUI"),
        "q1": .string(#"["iOS/iPadOS","macOS"]"#),
        "q2": .string("Kotlin"),
        "q3": .null,
        "q4": .string("Watch app"),
      ])]),
    ]))
  }

  /// An explicit skip of one question sends `null`; replayed locks are re-sent with the final
  /// set and win over whatever the card handed in.
  @Test func answersShapeSkipsAndReSendsLocks() async {
    var request = batch
    request.questions = Array(batch.questions.prefix(3))
    request.lockedAnswers = ["q0": .some("UIKit"), "q1": String?.none]
    let sent = await answer(request, with: .submitClarify(answers: [
      "q0": .choices(["SwiftUI (Recommended)"]),
      "q2": .skipped,
    ]), echo: "Framework?: UIKit\nTargets?: Skipped\nLanguage?: Skipped")
    #expect(sent?["result"] == .object(["answers": .object([
      "q0": .string("UIKit"), "q1": .null, "q2": .null,
    ])]))
  }

  @Test func answersShapeSingleQuestionAsTheCardSendsIt() async {
    let request = ClarifyRequest(
      requestID: nil,
      questions: [ClarifyQuestion(qid: "q0", question: "Proceed?", choices: ["Yes (Recommended)", "No"])],
      answerShape: .answers
    )
    // A tapped choice goes up raw (exactly as the card hands it over); the reducer sends the
    // bare label.
    let picked = await answer(request, with: .submitClarify(answers: ["q0": .choices(["Yes (Recommended)"])]), echo: "Yes")
    #expect(picked?["result"] == .object(["answers": .object(["q0": .string("Yes")])]))
    // The Other row's text is sent as typed.
    let typed = await answer(request, with: .submitClarify(answers: ["q0": .other("Later")]), echo: "Later")
    #expect(typed?["result"] == .object(["answers": .object(["q0": .string("Later")])]))
  }

  @Test func answersShapeSkipIsCancelAll() async {
    var request = batch
    request.lockedAnswers = ["q0": "UIKit"]
    let sent = await answer(request, with: .skipClarify, echo: "Skipped")
    #expect(sent == .object(["id": .string("srq-c"), "result": .object([:])]))
  }

  /// Skipping every question one by one is a complete form, and it is NOT the card's Skip:
  /// each question goes out as `null` (skipped), never the cancel-all `{}`.
  @Test func everyQuestionSkippedSendsNullForEachNotCancelAll() async {
    var request = batch
    request.questions = Array(batch.questions.prefix(3))
    var draft = ClarifyDraft()
    for question in request.questions { draft.toggleSkip(question) }
    #expect(draft.isComplete(for: request))
    let sent = await answer(
      request, with: .submitClarify(answers: draft.answers(for: request)),
      echo: "Framework?: Skipped\nTargets?: Skipped\nLanguage?: Skipped"
    )
    #expect(sent == .object([
      "id": .string("srq-c"),
      "result": .object(["answers": .object(["q0": .null, "q1": .null, "q2": .null])]),
    ]))
  }

  /// The intermediate (v2026.9.14–.24) single request answers `{answer}`, skip `{answer: ""}`.
  @Test func singleAnswerShapeSendsAnswerAndSkip() async {
    let request = ClarifyRequest(requestID: nil, question: "Proceed?", choices: ["Yes (Recommended)", "No"])
    let picked = await answer(request, with: .submitClarify(answers: ["": .choices(["Yes (Recommended)"])]), echo: "Yes")
    #expect(picked == .object(["id": .string("srq-c"), "result": .object(["answer": .string("Yes")])]))
    let other = await answer(request, with: .submitClarify(answers: ["": .other("Maybe")]), echo: "Maybe")
    #expect(other?["result"] == .object(["answer": .string("Maybe")]))
    let skipped = await answer(request, with: .skipClarify, echo: "Skipped")
    #expect(skipped?["result"] == .object(["answer": .string("")]))

    let multi = ClarifyRequest(requestID: nil, question: "Pick", choices: ["A", "B", "C"], multiSelect: true)
    let picks = await answer(multi, with: .submitClarify(answers: ["": .choices(["A", "C"])]), echo: "A, C")
    #expect(picks?["result"] == .object(["answer": .string(#"["A","C"]"#)]))
  }

  @Test(arguments: ["expired", "failure", "malformed"])
  func clarifyAnswerOutcomes(status: String) async {
    let pending = clarifyServerRequest("srq-o", ClarifyRequest(requestID: nil, question: "Proceed?", choices: ["Yes"]))
    let clock = TestClock()
    let sends = LockIsolated(0)
    let store = TestStore(initialState: presentedState(pending)) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.hermesGateway.send = { @Sendable method, _ in
        sends.withValue { $0 += 1 }
        try await clock.sleep(for: .seconds(1)) // the answer stays in flight until advanced
        if status == "failure" { throw GatewayError.timedOut(method: method) }
        return .object(["status": .string(status)])
      }
    }
    await store.send(.submitClarify(answers: ["": .choices(["Yes"])])) {
      $0.answeringServerRequestID = "srq-o"
    }
    // A second tap while the answer is in flight sends nothing.
    await store.send(.skipClarify)
    await clock.advance(by: .seconds(1))
    await store.receive(\.serverRequestAnswered) {
      $0.answeringServerRequestID = nil
      if status == "expired" {
        $0.transcript = [ChatRow(id: self.uuid(0), kind: .status(kind: "clarify", text: "Already handled elsewhere"))]
        $0.serverRequests = []
        $0.pendingInteraction = nil
      } else {
        // Still open server-side: the same card stays answerable, with a banner.
        $0.errorBanner = "Failed to send the clarify response."
      }
    }
    #expect(sends.value == 1)
    if status != "expired" {
      #expect(store.state.pendingInteractionToken == 1)
      #expect(!store.state.canSend)
    }
  }

  /// Answering the head presents the next queued request with a fresh token.
  @Test func answeringTheClarifyHeadPresentsTheNext() async {
    let first = clarifyServerRequest("srq-1", ClarifyRequest(requestID: nil, question: "First?"))
    let second = clarifyServerRequest("srq-2", ClarifyRequest(requestID: nil, question: "Second?"))
    var initial = presentedState(first)
    initial.serverRequests.append(second)
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.hermesGateway.send = { @Sendable _, _ in .object(["status": .string("ok")]) }
    }
    await store.send(.submitClarify(answers: ["": .other("one")])) { $0.answeringServerRequestID = "srq-1" }
    await store.receive(\.serverRequestAnswered) {
      $0.answeringServerRequestID = nil
      $0.transcript = [ChatRow(id: self.uuid(0), kind: .status(kind: "clarify", text: "one"))]
      $0.serverRequests = [second]
      $0.present(second.interaction)
    }
    #expect(store.state.pendingInteractionToken == 2)
  }

  // MARK: - Legacy `clarify.respond`

  /// Today's fixture, byte for byte: method, params and their values — the raw choice text
  /// (a legacy agent never sees the marker stripped), skip as an empty answer.
  @Test(arguments: 0..<3)
  func legacyClarifyWireIsUnchanged(caseIndex: Int) async {
    let (action, wireAnswer, echo): (ChatFeature.Action, String, String) = [
      (.submitClarify(answers: ["": .choices(["a.txt (Recommended)"])]), "a.txt (Recommended)", "a.txt"),
      (.submitClarify(answers: ["": .other("c.txt")]), "c.txt", "c.txt"),
      (.skipClarify, "", "Skipped"),
    ][caseIndex]
    let request = ClarifyRequest(requestID: "c1", question: "Which file?", choices: ["a.txt (Recommended)", "b.txt"])
    let sent = LockIsolated<JSONValue?>(nil)
    var initial = readyState()
    initial.present(.clarify(request))
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.hermesGateway.send = { @Sendable method, params in
        sent.setValue(.object(["method": .string(method), "params": params]))
        return .object([:])
      }
    }
    await store.send(action) {
      $0.pendingInteraction = nil
      $0.transcript = [ChatRow(id: self.uuid(0), kind: .status(kind: "clarify", text: echo))]
    }
    await store.finish()
    #expect(sent.value == .object([
      "method": .string("clarify.respond"),
      "params": .object([
        "session_id": .string("live"), "request_id": .string("c1"), "answer": .string(wireAnswer),
      ]),
    ]))
  }

  @Test func legacyClarifyFailureSurfaces() async {
    var initial = readyState()
    initial.present(.clarify(ClarifyRequest(requestID: "c1", question: "Which file?")))
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.hermesGateway.send = { @Sendable method, _ in throw GatewayError.timedOut(method: method) }
    }
    await store.send(.submitClarify(answers: ["": .other("notes.md")])) {
      $0.pendingInteraction = nil
      $0.transcript = [ChatRow(id: self.uuid(0), kind: .status(kind: "clarify", text: "notes.md"))]
    }
    await store.receive(\.legacyRespondFailed) {
      $0.transcript = [ChatRow(id: self.uuid(0), kind: .status(kind: "clarify", text: "Failed to send"))]
      $0.errorBanner = "Failed to send the clarify response."
    }
  }

  // MARK: - v7 sudo / secret server requests

  private let typedValue = "hunter2-ÿ/secret"

  /// No row, banner or other state field may ever hold the typed value.
  private func assertValueNeverStored(_ state: ChatFeature.State) {
    #expect(!String(describing: state.transcript).contains(typedValue))
    #expect(!(state.errorBanner ?? "").contains(typedValue))
  }

  @Test(arguments: [SecretKind.sudo, .secret])
  func secretServerRequestPinsTheCard(kind: SecretKind) async {
    let pending = PendingServerRequest(
      id: "srq-s", kind: .secret(kind, kind == .sudo ? SecretPrompt(command: "apt install ripgrep")
        : SecretPrompt(prompt: "Weather API key", envVar: "OPENWEATHER_API_KEY"))
    )
    let store = TestStore(initialState: readyState()) { ChatFeature() }
    await store.send(.gatewayEvent(.serverRequest(pending))) {
      $0.serverRequests = [pending]
      $0.present(pending.interaction)
    }
    #expect(store.state.pendingInteractionToken == 1)
    #expect(!store.state.canSend)
  }

  /// Answer `{value}` and skip `{value: ""}` through `request.answer` for both kinds; the
  /// card stays until the server acknowledges, and the echo never holds the value.
  @Test(arguments: [(SecretKind.sudo, true), (.sudo, false), (.secret, true), (.secret, false)])
  func secretServerRequestAnswerAndSkipParams(kind: SecretKind, answers: Bool) async {
    let pending = PendingServerRequest(id: "srq-v", kind: .secret(kind, SecretPrompt(command: "ls")))
    let sent = LockIsolated<JSONValue?>(nil)
    let store = TestStore(initialState: presentedState(pending)) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.hermesGateway.send = { @Sendable method, params in
        sent.setValue(.object(["method": .string(method), "params": params]))
        return .object(["status": .string("ok")])
      }
    }
    await store.send(answers ? .respondToSecret(value: typedValue) : .skipSecret) {
      $0.answeringServerRequestID = "srq-v"
    }
    let echo = switch (kind, answers) {
    case (.sudo, true): "Password submitted"
    case (.secret, true): "Secret submitted"
    case (.sudo, false): "Password skipped"
    case (.secret, false): "Secret skipped"
    }
    await store.receive(\.serverRequestAnswered) {
      $0.answeringServerRequestID = nil
      $0.transcript = [ChatRow(id: self.uuid(0), kind: .status(kind: "secret", text: echo))]
      $0.serverRequests = []
      $0.pendingInteraction = nil
    }
    #expect(sent.value == .object([
      "method": .string("request.answer"),
      "params": .object([
        "id": .string("srq-v"),
        "result": .object(["value": .string(answers ? typedValue : "")]),
      ]),
    ]))
    assertValueNeverStored(store.state)
  }

  @Test(arguments: ["expired", "failure", "malformed"])
  func secretAnswerOutcomes(status: String) async {
    let pending = PendingServerRequest(id: "srq-o", kind: .secret(.sudo, SecretPrompt()))
    let clock = TestClock()
    let sends = LockIsolated(0)
    let store = TestStore(initialState: presentedState(pending)) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.hermesGateway.send = { @Sendable method, _ in
        sends.withValue { $0 += 1 }
        try await clock.sleep(for: .seconds(1))
        if status == "failure" { throw GatewayError.timedOut(method: method) }
        return .object(["status": .string(status)])
      }
    }
    await store.send(.respondToSecret(value: typedValue)) { $0.answeringServerRequestID = "srq-o" }
    await store.send(.skipSecret) // a second tap while the answer is in flight sends nothing
    await clock.advance(by: .seconds(1))
    await store.receive(\.serverRequestAnswered) {
      $0.answeringServerRequestID = nil
      if status == "expired" {
        $0.transcript = [ChatRow(id: self.uuid(0), kind: .status(kind: "secret", text: "Already handled elsewhere"))]
        $0.serverRequests = []
        $0.pendingInteraction = nil
      } else {
        // Still open server-side: the same card stays answerable, with a banner.
        $0.errorBanner = "Failed to send the password."
      }
    }
    #expect(sends.value == 1)
    assertValueNeverStored(store.state)
  }

  // MARK: - Legacy `sudo.respond` / `secret.respond`

  /// Today's wire, byte for byte: sudo answers under `password`, secret under `value`; a skip
  /// sends the same respond with an empty value.
  @Test(arguments: [(SecretKind.sudo, true), (.sudo, false), (.secret, true), (.secret, false)])
  func legacySecretWireIsUnchanged(kind: SecretKind, answers: Bool) async {
    let sent = LockIsolated<JSONValue?>(nil)
    var initial = readyState()
    initial.present(.secret(kind, SecretPrompt(requestID: "s1", prompt: "Password")))
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.hermesGateway.send = { @Sendable method, params in
        sent.setValue(.object(["method": .string(method), "params": params]))
        return .object([:])
      }
    }
    let echo = switch (kind, answers) {
    case (.sudo, true): "Password submitted"
    case (.secret, true): "Secret submitted"
    case (.sudo, false): "Password skipped"
    case (.secret, false): "Secret skipped"
    }
    await store.send(answers ? .respondToSecret(value: typedValue) : .skipSecret) {
      $0.pendingInteraction = nil
      $0.transcript = [ChatRow(id: self.uuid(0), kind: .status(kind: "secret", text: echo))]
    }
    await store.finish()
    #expect(sent.value == .object([
      "method": .string(kind == .sudo ? "sudo.respond" : "secret.respond"),
      "params": .object([
        "session_id": .string("live"), "request_id": .string("s1"),
        (kind == .sudo ? "password" : "value"): .string(answers ? typedValue : ""),
      ]),
    ]))
    assertValueNeverStored(store.state)
  }

  @Test(arguments: [SecretKind.sudo, .secret])
  func legacySecretFailureSurfaces(kind: SecretKind) async {
    var initial = readyState()
    initial.present(.secret(kind, SecretPrompt(requestID: "s1")))
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.hermesGateway.send = { @Sendable method, _ in throw GatewayError.timedOut(method: method) }
    }
    let label = kind == .sudo ? "Password submitted" : "Secret submitted"
    await store.send(.respondToSecret(value: typedValue)) {
      $0.pendingInteraction = nil
      $0.transcript = [ChatRow(id: self.uuid(0), kind: .status(kind: "secret", text: label))]
    }
    await store.receive(\.legacyRespondFailed) {
      $0.transcript = [ChatRow(id: self.uuid(0), kind: .status(kind: "secret", text: "Failed to send"))]
      $0.errorBanner = kind == .sudo ? "Failed to send the password." : "Failed to send the secret."
    }
    assertValueNeverStored(store.state)
  }

  @Test func secretAnswerIgnoredWhenNoSecretPending() async {
    var initial = readyState()
    initial.present(.clarify(ClarifyRequest(requestID: "c1", question: "Which file?")))
    let store = TestStore(initialState: initial) { ChatFeature() }
    await store.send(.respondToSecret(value: "x"))
    await store.send(.skipSecret)
  }
}
