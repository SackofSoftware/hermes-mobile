import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

@MainActor
struct ChatInteractionTests {
  private let conn = ServerConnection(baseURL: URL(string: "http://mac.tailnet:9119")!, token: "t")
  private let request = ApprovalRequest(requestID: "r1", command: "rm -rf /tmp/x")
  private func uuid(_ n: Int) -> UUID {
    UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012x", n))")!
  }

  private func readyState() -> ChatFeature.State {
    var state = ChatFeature.State(connection: conn)
    state.liveSessionID = "live"
    return state
  }

  @Test func approvalRequestPinsCardAndBlocksComposer() async {
    var initial = readyState()
    initial.composerText = "hi"
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
    }
    #expect(store.state.canSend) // composer usable before the request

    await store.send(.gatewayEvent(.approvalRequest(request))) {
      $0.pendingInteraction = .approval(self.request)
    }
    #expect(!store.state.canSend) // blocked while a request is pending
  }

  @Test func approveClearsAppendsAndSends() async {
    let sent = LockIsolated<JSONValue?>(nil)
    var initial = readyState()
    initial.pendingInteraction = .approval(request)
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.hermesGateway.send = { @Sendable method, params in
        sent.setValue(.object(["method": .string(method), "params": params]))
        return .object(["resolved": .number(1)])
      }
    }

    await store.send(.respondToApproval(approve: true, all: false)) {
      $0.pendingInteraction = nil
      $0.transcript = [ChatRow(id: self.uuid(0), kind: .status(kind: "approval", text: "Approved"))]
    }
    await store.finish()

    #expect(sent.value?["method"]?.stringValue == "approval.respond")
    #expect(sent.value?["params"]?["request_id"]?.stringValue == "r1")
    #expect(sent.value?["params"]?["choice"]?.stringValue == "approve")
    #expect(sent.value?["params"]?["all"]?.boolValue == false)
  }

  @Test func approveAllSendsAllTrue() async {
    let sent = LockIsolated<JSONValue?>(nil)
    var initial = readyState()
    initial.pendingInteraction = .approval(request)
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.hermesGateway.send = { @Sendable _, params in
        sent.setValue(params)
        return .object(["resolved": .number(3)])
      }
    }

    await store.send(.respondToApproval(approve: true, all: true)) {
      $0.pendingInteraction = nil
      $0.transcript = [ChatRow(id: self.uuid(0), kind: .status(kind: "approval", text: "Approved"))]
    }
    await store.finish()

    #expect(sent.value?["all"]?.boolValue == true)
  }

  @Test func denySendsDenyChoice() async {
    let sent = LockIsolated<JSONValue?>(nil)
    var initial = readyState()
    initial.pendingInteraction = .approval(request)
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.hermesGateway.send = { @Sendable _, params in
        sent.setValue(params)
        return .object([:])
      }
    }

    await store.send(.respondToApproval(approve: false, all: false)) {
      $0.pendingInteraction = nil
      $0.transcript = [ChatRow(id: self.uuid(0), kind: .status(kind: "approval", text: "Denied"))]
    }
    await store.finish()

    #expect(sent.value?["choice"]?.stringValue == "deny")
  }
}
