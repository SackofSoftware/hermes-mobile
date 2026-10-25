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

  private func wire(_ value: JSONValue) -> String {
    String(decoding: try! JSONRPCRequest.wireEncoder.encode(value), as: UTF8.self)
  }

  private func serverRequestFrame(id: String, method: String, params: JSONValue) -> String {
    wire(.object(["jsonrpc": .string("2.0"), "id": .string(id), "method": .string(method), "params": params]))
  }

  private func probe(_ type: String) -> String {
    #"{"method":"event","params":{"type":"\#(type)","payload":{}}}"#
  }

  /// The decline matrix, driven end to end through injected frames (the receive loop's real
  /// routing) and fed into an exhaustive reducer: before the advertisement nothing is
  /// declined (support unknown); after it, window-owned bridges get a 4404 only when
  /// `declines_not_shown` was acknowledged; every unrendered prompt — `vault.code` included —
  /// gets nothing on every backend; a rendered approval is queued and presented. Routing is
  /// synchronous on the receive loop, so a probe event read back is the "nothing more" barrier.
  @Test(arguments: [JSONValue.object([:]), .object(["declines_not_shown": .bool(false)]),
                    .object(["declines_not_shown": .bool(true)])])
  func declineMatrixThroughInjectedFrames(capabilities: JSONValue) async throws {
    let transport = FakeTransport { frame, inbound in
      let request = try! JSONDecoder().decode(JSONValue.self, from: Data(frame.utf8))
      if request["method"]?.stringValue == "client.capabilities", let id = request["id"]?.intValue {
        let result: JSONValue = .object(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "result": capabilities])
        inbound.yield(String(decoding: try! JSONRPCRequest.wireEncoder.encode(result), as: UTF8.self))
      }
    }
    let client = HermesGatewayClient.make { _ in transport }
    let events = client.connect(url, .token("t"))
    var iterator = events.makeAsyncIterator()
    for method in windowMethods {
      transport.inject(serverRequestFrame(id: "before/" + method, method: method, params: .object([:])))
    }
    transport.inject(probe("probe.before"))
    #expect(await iterator.next() == .unknown(type: "probe.before", raw: .object([:])))
    #expect(transport.sent.isEmpty) // support is unknown until a successful advertisement

    transport.inject(#"{"method":"event","params":{"type":"gateway.ready"}}"#)
    #expect(await iterator.next() == .ready)
    let methods = windowMethods + ["vault.unlock_prompt", "vault.save_login", "vault.code", "setup_choose",
      "display.install.sudo", "clarify", "sudo", "secret", "future.method"]
    for method in methods {
      transport.inject(serverRequestFrame(
        id: "srq/" + method, method: method,
        params: .object(["session_id": .string("live"), "path": .string("/tmp/a")])
      ))
    }
    transport.inject(serverRequestFrame(
      id: "srq-approval", method: "approval",
      params: .object(["session_id": .string("live"), "command": .string("rm /tmp/foo")])
    ))
    transport.inject(probe("probe.after"))
    let event = try #require(await iterator.next())
    #expect(await iterator.next() == .unknown(type: "probe.after", raw: .object([:])))

    let declines = capabilities["declines_not_shown"]?.boolValue == true
    await waitUntil { transport.sent.count == 1 + (declines ? windowMethods.count : 0) }
    for _ in 0..<200 { await Task.yield() } // a stray extra reply would land meanwhile
    let frames = try transport.sent.map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
    #expect(frames.first?["method"]?.stringValue == "client.capabilities")
    #expect(frames.first?["params"] == .object(["server_requests": .bool(true)]))
    let replies = Array(frames.dropFirst())
    if declines {
      #expect(Set(replies.compactMap { $0["id"]?.stringValue }) == Set(windowMethods.map { "srq/" + $0 }))
      for reply in replies {
        #expect(reply["error"] == .object(["code": .number(4404), "message": .string("Not shown on this client")]))
        #expect(reply["jsonrpc"] == .string("2.0"))
      }
    } else {
      #expect(replies.isEmpty)
    }
    #expect(transport.sent.allSatisfy { !$0.contains(#"\/"#) }) // every frame via `wireEncoder`

    let store = TestStore(initialState: ChatFeature.State(connection: ServerConnection(baseURL: url, token: "t"))) {
      ChatFeature()
    }
    let expected = PendingServerRequest(id: "srq-approval", kind: .approval(ApprovalRequest(command: "rm /tmp/foo")))
    await store.send(.gatewayEvent(event)) {
      $0.serverRequests = [expected]
      $0.present(expected.interaction)
    }
    client.disconnect()
    await store.finish()
  }

  /// A rendered approval whose params are malformed — or carry nothing to show — is denied
  /// through `request.answer`, never presented. The probe yielded by the fake on the answer
  /// arrives FIRST, so no card event preceded it.
  @Test(arguments: [JSONValue.null, .array([]), .object(["command": .number(9)]),
                    .object(["choices": .string("once")]), .object(["session_id": .string("live")])])
  func malformedApprovalIsDenied(payload: JSONValue) async throws {
    let transport = FakeTransport { frame, inbound in
      let request = try! JSONDecoder().decode(JSONValue.self, from: Data(frame.utf8))
      if let id = request["id"]?.intValue {
        inbound.yield(#"{"jsonrpc":"2.0","id":\#(id),"result":{"status":"ok"}}"#)
        inbound.yield(#"{"method":"event","params":{"type":"probe.answered","payload":{}}}"#)
      }
    }
    let client = HermesGatewayClient.make { _ in transport }
    let events = client.connect(url, .token("t"))
    var iterator = events.makeAsyncIterator()
    transport.inject(serverRequestFrame(id: "srq/bad", method: "approval", params: payload))
    #expect(await iterator.next() == .unknown(type: "probe.answered", raw: .object([:])))
    let frame = try JSONDecoder().decode(JSONValue.self, from: Data(try #require(transport.sent.first).utf8))
    #expect(frame["method"]?.stringValue == "request.answer")
    #expect(frame["params"] == .object([
      "id": .string("srq/bad"), "result": .object(["choice": .string("deny")]),
    ]))
    #expect(transport.sent.count == 1)
    client.disconnect()
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

  /// A failed automatic send (a 4404 decline, a malformed approval's deny) banners without
  /// ending the turn or the socket. Driven through injected frames.
  @Test(arguments: ["tour", "approval"])
  func automaticSendFailureDoesNotEndTurn(method: String) async throws {
    let transport = FailingReplyTransport()
    let client = HermesGatewayClient.make { _ in transport }
    let events = client.connect(url, .token("t"))
    var iterator = events.makeAsyncIterator()
    transport.base.inject(#"{"method":"event","params":{"type":"gateway.ready"}}"#)
    #expect(await iterator.next() == .ready) // declines_not_shown acknowledged
    transport.base.inject(serverRequestFrame(id: "failed", method: method, params: .null))
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
    client.disconnect()
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
    #expect(await iterator.next() == .serverRequest(
      PendingServerRequest(id: "approval", kind: .approval(ApprovalRequest(command: "rm foo")))
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
    transport.inject(serverRequestFrame(id: "bridge", method: "tour", params: .object([:])))
    transport.inject(probe("probe.after"))
    #expect(await iterator.next() == .unknown(type: "probe.after", raw: .object([:])))
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
