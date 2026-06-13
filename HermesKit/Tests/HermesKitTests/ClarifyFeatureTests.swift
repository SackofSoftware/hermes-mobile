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
    }
    #expect(!store.state.canSend)
  }

  @Test func sudoRequestPinsSecretCard() async {
    let prompt = SecretPrompt(requestID: "s1")
    let store = TestStore(initialState: readyState()) { ChatFeature() }

    await store.send(.gatewayEvent(.sudoRequest(prompt))) {
      $0.pendingInteraction = .secret(.sudo, prompt)
    }
  }

  @Test func secretRequestPinsSecretCard() async {
    let prompt = SecretPrompt(requestID: "s2", prompt: "API key for X")
    let store = TestStore(initialState: readyState()) { ChatFeature() }

    await store.send(.gatewayEvent(.secretRequest(prompt))) {
      $0.pendingInteraction = .secret(.secret, prompt)
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

    await store.send(.respondToClarify(answer: "a.txt")) {
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
    await store.send(.respondToClarify(answer: "x"))
  }
}
