import Clocks
import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

private struct FailingReplyTransport: WebSocketTransport {
  let base = FakeTransport { frame, inbound in
    let request = try! JSONDecoder().decode(JSONValue.self, from: Data(frame.utf8))
    if let id = request["id"]?.intValue {
      inbound.yield(#"{"id":\#(id),"result":{"declines_not_shown":true}}"#)
    }
  }
  func send(_ text: String) async throws {
    let frame = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    guard frame["method"]?.stringValue == "client.capabilities" else {
      throw GatewayError.server("send failed")
    }
    try await base.send(text)
  }
  func receive() async throws -> String { try await base.receive() }
  func cancel() { base.cancel() }
}

@MainActor
struct ServerRequestTests {
  private let url = URL(string: "http://test.local:9119")!
  private let windowMethods = ["terminal.read", "preview.read", "window.read", "preview.act", "tour"]

  // Exercise the real connection actor and feed its events into an exhaustive reducer.
  // Awaiting advertisement is the barrier: no scheduling guess before injecting bridges.
  @Test(arguments: [JSONValue.object([:]), .object(["declines_not_shown": .bool(false)]),
                    .object(["declines_not_shown": .bool(true)])])
  func declinesOnlyWindowBridges(capabilities: JSONValue) async throws {
    let transport = FakeTransport { frame, inbound in
      let request = try! JSONDecoder().decode(JSONValue.self, from: Data(frame.utf8))
      if request["method"]?.stringValue == "client.capabilities", let id = request["id"]?.intValue {
        let result: JSONValue = .object(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "result": capabilities])
        inbound.yield(String(decoding: try! JSONRPCRequest.wireEncoder.encode(result), as: UTF8.self))
      }
    }
    let (events, continuation) = AsyncStream<GatewayEvent>.makeStream()
    let connection = GatewayConnection(transport: transport, events: continuation)
    await connection.start()
    for method in windowMethods {
      await connection.handleServerRequest(id: "before/" + method, method: method, params: .object([:]))
    }
    #expect(transport.sent.isEmpty) // support is unknown until a successful advertisement
    await connection.advertiseServerRequests()
    let store = TestStore(initialState: ChatFeature.State(connection: ServerConnection(baseURL: url, token: "t"))) {
      ChatFeature()
    }
    let methods = windowMethods + ["vault.unlock", "vault.2fa", "vault.anything", "setup_choose",
      "display.install.sudo", "clarify", "sudo", "secret", "future.method"]
    for method in methods {
      await connection.handleServerRequest(id: "srq/" + method, method: method, params: .object([:]))
    }
    await connection.handleServerRequest(id: "approval", method: "approval", params: .object(["command": .string("rm foo")]))
    var iterator = events.makeAsyncIterator()
    let event = try #require(await iterator.next())
    await store.send(.gatewayEvent(event)) {
      $0.present(.approval(ApprovalRequest(serverRequestID: "approval", command: "rm foo")))
    }
    let frames = try transport.sent.map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
    #expect(frames.first?["method"]?.stringValue == "client.capabilities")
    #expect(frames.first?["params"] == .object(["server_requests": .bool(true)]))
    let replies = Array(frames.dropFirst())
    if capabilities["declines_not_shown"]?.boolValue == true {
      #expect(replies.count == windowMethods.count)
      for (method, reply) in zip(windowMethods, replies) {
        #expect(reply == .object([
          "jsonrpc": .string("2.0"), "id": .string("srq/" + method),
          "error": .object(["code": .number(4404), "message": .string("Not shown on this client")]),
        ]))
      }
    } else {
      #expect(replies.isEmpty)
    }
    #expect(transport.sent.allSatisfy { !$0.contains(#"\/"#) })
    await connection.shutdown()
    await store.finish()
  }

  @Test(arguments: [JSONValue.null, .array([]), .object(["command": .number(9)]),
                    .object(["choices": .string("once")])])
  func malformedApprovalIsDenied(payload: JSONValue) async throws {
    let transport = FakeTransport { frame, inbound in
      let request = try! JSONDecoder().decode(JSONValue.self, from: Data(frame.utf8))
      if let id = request["id"]?.intValue {
        inbound.yield(#"{"jsonrpc":"2.0","id":\#(id),"result":{"status":"ok"}}"#)
      }
    }
    let (events, continuation) = AsyncStream<GatewayEvent>.makeStream()
    let connection = GatewayConnection(transport: transport, events: continuation)
    await connection.start()
    await connection.handleServerRequest(id: "srq/bad", method: "approval", params: payload)
    // handleServerRequest awaits the denial RPC, but the receive loop remains free to ack it.
    let request = try #require(transport.sent.first)
    let frame = try JSONDecoder().decode(JSONValue.self, from: Data(request.utf8))
    #expect(frame["method"]?.stringValue == "request.answer")
    #expect(frame["params"] == .object([
      "id": .string("srq/bad"), "result": .object(["choice": .string("deny")]),
    ]))
    await connection.shutdown()
    var iterator = events.makeAsyncIterator()
    #expect(await iterator.next() == nil) // no malformed card was presented
  }

  /// A failed advertisement opens the ready gate first and only then surfaces, so the
  /// `.ready` reset can't wipe it; the socket stays up, and nothing retries on this
  /// connection (the next connect re-advertises — no background retry loop).
  @Test func advertisementFailureSurfacesAfterReadyAndIsNotRetried() async throws {
    let clock = TestClock()
    let attempts = LockIsolated(0)
    let transport = FakeTransport { frame, inbound in
      let request = try! JSONDecoder().decode(JSONValue.self, from: Data(frame.utf8))
      if let id = request["id"]?.intValue {
        attempts.withValue { $0 += 1 }
        inbound.yield(#"{"jsonrpc":"2.0","id":\#(id),"error":{"message":"busy"}}"#)
      }
    }
    let client = HermesGatewayClient.make(clock: clock) { _ in transport }
    var initial = ChatFeature.State(connection: ServerConnection(baseURL: url, token: "t"))
    initial.hasRequestedSession = true // isolate protocol bootstrap from session hydration
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.hermesGateway = client
      $0.debugLog.append = { _ in }
    }
    let message = "Couldn’t enable approvals and other prompts: busy"
    await store.send(.task) { $0.hasStarted = true }
    transport.inject(#"{"method":"event","params":{"type":"gateway.ready"}}"#)
    await store.receive(\.gatewayEvent) { $0.status = .ready }
    await store.receive(\.gatewayEvent) {
      $0.serverRequestsUnavailable = message
      $0.errorBanner = message
    }
    await clock.advance(by: .seconds(120))
    transport.inject(#"{"method":"event","params":{"type":"probe.ack","payload":{}}}"#)
    await store.receive(\.gatewayEvent) // probe.ack: the receive loop survived the failure
    #expect(attempts.value == 1)
    await store.send(.teardown)
    await store.finish()
  }

  /// The ready gate holds `.ready` until the advertisement is acknowledged, so the
  /// reducer's first `session.resume` (sent on `.ready`) always follows it on the wire.
  /// Frames read meanwhile are yielded at once, and the acknowledged `declines_not_shown`
  /// is what later licenses a 4404.
  @Test func readyWaitsForTheAdvertisementWhichPrecedesSessionResume() async throws {
    let capabilitiesID = LockIsolated<Int?>(nil)
    let transport = FakeTransport { frame, inbound in
      let request = try! JSONDecoder().decode(JSONValue.self, from: Data(frame.utf8))
      guard let id = request["id"]?.intValue else { return }
      if request["method"]?.stringValue == "client.capabilities" {
        capabilitiesID.setValue(id) // acknowledged by the test, below
      } else {
        inbound.yield(#"{"jsonrpc":"2.0","id":\#(id),"result":{"session_id":"live"}}"#)
      }
    }
    let client = HermesGatewayClient.make { _ in transport }
    let events = client.connect(url, .token("t"))
    var iterator = events.makeAsyncIterator()
    transport.inject(#"{"method":"event","params":{"type":"gateway.ready"}}"#)
    transport.inject(#"{"method":"event","params":{"type":"probe.window","payload":{}}}"#)
    #expect(await iterator.next() == .unknown(type: "probe.window", raw: .object([:])))
    await waitUntil { capabilitiesID.value != nil }
    let id = try #require(capabilitiesID.value)
    transport.inject(#"{"jsonrpc":"2.0","id":\#(id),"result":{"server_requests":["approval"],"declines_not_shown":true}}"#)
    #expect(await iterator.next() == .ready)

    _ = try await client.send("session.resume", .object(["session_id": .string("stored")]))
    let methods = transport.sent.compactMap {
      (try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)))?["method"]?.stringValue
    }
    #expect(methods == ["client.capabilities", "session.resume"])

    transport.inject(#"{"jsonrpc":"2.0","id":"srq-tour","method":"tour","params":{}}"#)
    await waitUntil { transport.sent.count == 3 }
    let decline = try JSONDecoder().decode(JSONValue.self, from: Data(try #require(transport.sent.last).utf8))
    #expect(decline["error"]?["code"] == .number(4404)) // declines_not_shown was stored
    client.disconnect()
  }

  /// A hung `client.capabilities` must not strand the chat: the 5 s cap releases `.ready`,
  /// and the advertisement's own late failure (the 30 s request timeout) still surfaces.
  @Test func hungAdvertisementReachesReadyAfterTheCap() async throws {
    let clock = TestClock()
    let transport = FakeTransport() // never answers
    let client = HermesGatewayClient.make(clock: clock) { _ in transport }
    let events = client.connect(url, .token("t"))
    var iterator = events.makeAsyncIterator()
    transport.inject(#"{"method":"event","params":{"type":"gateway.ready"}}"#)
    transport.inject(#"{"method":"event","params":{"type":"probe.window","payload":{}}}"#)
    #expect(await iterator.next() == .unknown(type: "probe.window", raw: .object([:])))
    await waitUntil { transport.sent.count == 1 }
    for _ in 0..<20 { await Task.yield() } // the cap + request-timeout sleeps reach the clock
    await clock.advance(by: GatewayConnection.advertisementReadyCap)
    #expect(await iterator.next() == .ready)
    await clock.advance(by: .seconds(25))
    #expect(await iterator.next() == .serverRequestsUnavailable(
      message: "Couldn’t enable approvals and other prompts: request timed out: client.capabilities"
    ))
    client.disconnect()
  }

  @Test(arguments: ["tour", "approval"])
  func automaticSendFailureDoesNotEndTurn(method: String) async throws {
    let transport = FailingReplyTransport()
    let (events, continuation) = AsyncStream<GatewayEvent>.makeStream()
    let connection = GatewayConnection(transport: transport, events: continuation)
    await connection.start()
    await connection.advertiseServerRequests()
    await connection.handleServerRequest(id: "failed", method: method, params: .null)
    var iterator = events.makeAsyncIterator()
    let failure = try #require(await iterator.next())
    var initial = ChatFeature.State(connection: ServerConnection(baseURL: url, token: "t"), status: .ready)
    initial.isSending = true
    let store = TestStore(initialState: initial) { ChatFeature() }
    await store.send(.gatewayEvent(failure)) {
      $0.errorBanner = method == "tour"
        ? "Couldn’t decline a window request: send failed"
        : "Couldn’t deny a malformed approval: send failed"
    }
    #expect(!transport.base.cancelled)
    await connection.shutdown()
    await store.finish()
  }

  @Test func approvalPresentationPreservesWireEventOrder() async throws {
    let transport = FakeTransport()
    let client = HermesGatewayClient.make { _ in transport }
    let events = client.connect(url, .token("t"))
    transport.inject(
      #"{"id":"approval","method":"approval","params":{"command":"rm foo"}}"#
        + "\n" + #"{"method":"event","params":{"type":"message.complete","payload":{"text":"done"}}}"#
    )
    var iterator = events.makeAsyncIterator()
    #expect(await iterator.next() == .approvalServerRequest(
      ApprovalRequest(serverRequestID: "approval", command: "rm foo")
    ))
    #expect(await iterator.next() == .messageComplete(text: "done", usage: nil))
    client.disconnect()
  }

  @Test func missingApprovalParamsAreStillAnswered() async throws {
    let transport = FakeTransport { frame, inbound in
      let request = try! JSONDecoder().decode(JSONValue.self, from: Data(frame.utf8))
      if let id = request["id"]?.intValue {
        inbound.yield(#"{"id":\#(id),"result":{"status":"expired"}}"#)
        inbound.yield(#"{"method":"event","params":{"type":"probe.answered","payload":{}}}"#)
      }
    }
    let client = HermesGatewayClient.make { _ in transport }
    let events = client.connect(url, .token("t"))
    transport.inject(#"{"jsonrpc":"2.0","id":"missing/params","method":"approval"}"#)
    var iterator = events.makeAsyncIterator()
    #expect(await iterator.next() == .unknown(type: "probe.answered", raw: .object([:])))
    let frame = try JSONDecoder().decode(JSONValue.self, from: Data(try #require(transport.sent.first).utf8))
    #expect(frame["method"]?.stringValue == "request.answer")
    #expect(frame["params"] == .object([
      "id": .string("missing/params"), "result": .object(["choice": .string("deny")]),
    ]))
    client.disconnect()
  }

  /// v2026.9.14 speaks v7 without `client.capabilities`: its `-32601` opens the ready gate
  /// at once (no cap wait — the clock never moves before `.ready`), raises nothing, and is
  /// never re-sent. Driven through an injected `gateway.ready` frame, the real trigger.
  @Test func unknownAdvertisementMethodIsSilentAndNotRetried() async throws {
    let clock = TestClock()
    let transport = FakeTransport { frame, inbound in
      let request = try! JSONDecoder().decode(JSONValue.self, from: Data(frame.utf8))
      guard let id = request["id"]?.intValue else { return }
      inbound.yield(#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32601,"message":"unknown method: client.capabilities"}}"#)
    }
    let (events, continuation) = AsyncStream<GatewayEvent>.makeStream()
    let connection = GatewayConnection(transport: transport, events: continuation, clock: clock)
    await connection.start()
    var iterator = events.makeAsyncIterator()
    transport.inject(#"{"method":"event","params":{"type":"gateway.ready"}}"#)
    #expect(await iterator.next() == .ready)

    await clock.advance(by: .seconds(120))
    transport.inject(#"{"method":"event","params":{"type":"probe.ack","payload":{}}}"#)
    // The next event is the probe: no `.serverRequestsUnavailable` / `.serverRequestFailed`.
    #expect(await iterator.next() == .unknown(type: "probe.ack", raw: .object([:])))
    let methods = transport.sent.compactMap {
      (try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)))?["method"]?.stringValue
    }
    #expect(methods == ["client.capabilities"])
    await connection.shutdown()
  }

  @Test func advertisementFailureSurfacesWithoutEndingTurnAndIsNotRetried() async throws {
    let attempts = LockIsolated(0)
    let transport = FakeTransport { frame, inbound in
      let request = try! JSONDecoder().decode(JSONValue.self, from: Data(frame.utf8))
      if let id = request["id"]?.intValue {
        attempts.withValue { $0 += 1 }
        inbound.yield(#"{"jsonrpc":"2.0","id":\#(id),"error":{"message":"busy"}}"#)
      }
    }
    let (events, continuation) = AsyncStream<GatewayEvent>.makeStream()
    let connection = GatewayConnection(transport: transport, events: continuation)
    await connection.start()
    await connection.advertiseServerRequests()
    var initial = ChatFeature.State(connection: ServerConnection(baseURL: url, token: "t"), status: .ready)
    initial.isSending = true
    initial.present(.approval(ApprovalRequest(command: "rm foo")))
    let store = TestStore(initialState: initial) { ChatFeature() }
    var iterator = events.makeAsyncIterator()
    let failure = try #require(await iterator.next())
    await store.send(.gatewayEvent(failure)) {
      $0.serverRequestsUnavailable = "Couldn’t enable approvals and other prompts: busy"
      $0.errorBanner = "Couldn’t enable approvals and other prompts: busy"
    }
    await connection.advertiseServerRequests() // one attempt per connection
    #expect(attempts.value == 1)
    await connection.handleServerRequest(id: "bridge", method: "tour", params: .object([:]))
    #expect(transport.sent.count == 1) // `declines_not_shown` never confirmed → no 4404
    await connection.shutdown()
    await store.finish()
  }

  // MARK: Reducer: wire generation + the standing advertisement failure

  @Test func readyResetsTheStandingAdvertisementFailure() async {
    var initial = ChatFeature.State(connection: ServerConnection(baseURL: url, token: "t"))
    initial.hasRequestedSession = true
    let store = TestStore(initialState: initial) { ChatFeature() }
    await store.send(.gatewayEvent(.serverRequestsUnavailable(message: "Couldn’t enable approvals and other prompts: busy"))) {
      $0.serverRequestsUnavailable = "Couldn’t enable approvals and other prompts: busy"
      $0.errorBanner = "Couldn’t enable approvals and other prompts: busy"
    }
    // A (re)connected socket re-advertises: the old connection's failure is moot.
    await store.send(.gatewayEvent(.ready)) {
      $0.status = .ready
      $0.serverRequestsUnavailable = nil
      $0.errorBanner = nil
    }
  }

  /// The hydrate that lands right after `.ready` clears stale connection banners — but this
  /// connection's advertisement failure is not stale, so it stays up. The hydrate's `info`
  /// also records the wire generation (a string contract included).
  @Test func hydrateKeepsTheAdvertisementFailureAndRecordsTheContract() async throws {
    let message = "Couldn’t enable approvals and other prompts: busy"
    var initial = ChatFeature.State(connection: ServerConnection(baseURL: url, token: "t"), resumeStoredID: "stored")
    initial.status = .ready
    initial.hasRequestedSession = true
    initial.serverRequestsUnavailable = message
    initial.errorBanner = "Connection lost."
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable _, _ in .object([:]) } // post-hydrate fetches
    }
    store.exhaustivity = .off(showSkippedAssertions: false) // the post-hydrate fetch effects
    let response = try JSONDecoder().decode(ActivateResponse.self, from: Data(#"""
      {"session_id":"live","resumed":"stored","running":false,"messages":[],
       "info":{"model":"m","desktop_contract":"8"}}
      """#.utf8))
    await store.send(.activateResult(.success(response))) {
      $0.liveSessionID = "live"
      $0.hasHydrated = true
      $0.model = "m"
      $0.desktopContract = 8
      $0.errorBanner = message
    }
    #expect(store.state.serverRequestsUnavailable == message)
    await store.send(.teardown)
  }

  @Test func sessionInfoRecordsTheContractOnlyWhenPresent() async {
    var initial = ChatFeature.State(connection: ServerConnection(baseURL: url, token: "t"), status: .ready)
    initial.model = "m"
    let store = TestStore(initialState: initial) { ChatFeature() }
    await store.send(.gatewayEvent(.sessionInfo(SessionInfo(desktopContract: 7)))) {
      $0.desktopContract = 7
    }
    // A partial `session.info` without the field leaves the recorded generation alone.
    await store.send(.gatewayEvent(.sessionInfo(SessionInfo(model: "m"))))
  }
}
