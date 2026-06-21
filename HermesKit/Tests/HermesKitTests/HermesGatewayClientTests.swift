import Clocks
import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

/// A fake `WebSocketTransport`: records sent frames, lets the test inject inbound
/// frames, and can auto-respond to sends via the `onSend` hook.
final class FakeTransport: WebSocketTransport, @unchecked Sendable {
  let inboundContinuation: AsyncStream<String>.Continuation
  private var iterator: AsyncStream<String>.AsyncIterator
  private let lock = NSLock()
  private var _sent: [String] = []
  private let onSend: @Sendable (_ frame: String, _ inbound: AsyncStream<String>.Continuation) -> Void

  init(onSend: @escaping @Sendable (String, AsyncStream<String>.Continuation) -> Void = { _, _ in }) {
    let (stream, continuation) = AsyncStream<String>.makeStream()
    inboundContinuation = continuation
    iterator = stream.makeAsyncIterator()
    self.onSend = onSend
  }

  private var _cancelled = false
  /// True once `cancel()` has run — lets a test assert the connection actor actually shut the
  /// transport down (e.g. on consumer cancel / stream termination).
  var cancelled: Bool { lock.withLock { _cancelled } }

  var sent: [String] { lock.withLock { _sent } }

  func send(_ text: String) async throws {
    lock.withLock { _sent.append(text) }
    onSend(text, inboundContinuation)
  }

  func receive() async throws -> String {
    guard let next = await iterator.next() else { throw GatewayError.disconnected }
    return next
  }

  func cancel() {
    lock.withLock { _cancelled = true }
    inboundContinuation.finish()
  }
  func inject(_ frame: String) { inboundContinuation.yield(frame) }
}

private func requestID(_ frame: String) -> Int? {
  (try? JSONDecoder().decode(JSONValue.self, from: Data(frame.utf8)))?["id"]?.intValue
}

@Suite struct HermesGatewayClientTests {
  private let url = URL(string: "http://test.local:9119")!

  @Test func sendResolvesOnMatchingResult() async throws {
    let transport = FakeTransport { frame, inbound in
      if let id = requestID(frame) {
        inbound.yield(#"{"jsonrpc":"2.0","id":\#(id),"result":{"status":"streaming"}}"#)
      }
    }
    let client = HermesGatewayClient.make { _ in transport }
    let stream = client.connect(url, .token("t"))
    defer { withExtendedLifetime(stream) {} } // the connection lives as long as the stream

    let result = try await client.send("prompt.submit", .object(["text": .string("hi")]))
    #expect(result == .object(["status": .string("streaming")]))

    // The outbound frame is a well-formed JSON-RPC request.
    let sent = try #require(transport.sent.first)
    let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(sent.utf8))
    #expect(decoded["method"]?.stringValue == "prompt.submit")
    #expect(decoded["jsonrpc"]?.stringValue == "2.0")
  }

  @Test func eventsAreYieldedOnStream() async throws {
    let transport = FakeTransport()
    let client = HermesGatewayClient.make { _ in transport }
    let stream = client.connect(url, .token("t"))

    transport.inject(#"{"jsonrpc":"2.0","method":"event","params":{"type":"message.delta","session_id":"s","payload":{"text":"hi"}}}"#)

    var iterator = stream.makeAsyncIterator()
    #expect(await iterator.next() == .messageDelta(text: "hi"))
  }

  @Test func multipleNewlineDelimitedFramesInOneMessage() async throws {
    let transport = FakeTransport()
    let client = HermesGatewayClient.make { _ in transport }
    let stream = client.connect(url, .token("t"))

    transport.inject(
      #"{"jsonrpc":"2.0","method":"event","params":{"type":"message.delta","payload":{"text":"a"}}}"#
      + "\n"
      + #"{"jsonrpc":"2.0","method":"event","params":{"type":"message.delta","payload":{"text":"b"}}}"#
    )

    var iterator = stream.makeAsyncIterator()
    #expect(await iterator.next() == .messageDelta(text: "a"))
    #expect(await iterator.next() == .messageDelta(text: "b"))
  }

  @Test func errorResponseThrows() async throws {
    let transport = FakeTransport { frame, inbound in
      if let id = requestID(frame) {
        inbound.yield(#"{"jsonrpc":"2.0","id":\#(id),"error":{"message":"bad session"}}"#)
      }
    }
    let client = HermesGatewayClient.make { _ in transport }
    let stream = client.connect(url, .token("t"))
    defer { withExtendedLifetime(stream) {} }

    await #expect(throws: GatewayError.server("bad session")) {
      _ = try await client.send("session.resume", .object(["session_id": .string("nope")]))
    }
  }

  @Test func concurrentSendsCorrelateByID() async throws {
    // Echo each request's id back in its result — proves the pending map routes
    // each response to the correct waiter.
    let transport = FakeTransport { frame, inbound in
      if let id = requestID(frame) {
        inbound.yield(#"{"jsonrpc":"2.0","id":\#(id),"result":{"echo":\#(id)}}"#)
      }
    }
    let client = HermesGatewayClient.make { _ in transport }
    let stream = client.connect(url, .token("t"))
    defer { withExtendedLifetime(stream) {} }

    async let first = client.send("m", .object(["k": .string("a")]))
    async let second = client.send("m", .object(["k": .string("b")]))
    let (a, b) = try await (first, second)

    let ea = try #require(a["echo"]?.intValue)
    let eb = try #require(b["echo"]?.intValue)
    #expect(ea != eb)
  }

  @Test func sendBeforeConnectThrowsNotConnected() async {
    let client = HermesGatewayClient.make { _ in FakeTransport() }
    await #expect(throws: GatewayError.notConnected) {
      _ = try await client.send("session.create", .object([:]))
    }
  }

  @Test func sendTimesOutWhenServerNeverResponds() async throws {
    // The transport accepts the send but never yields a matching response; advancing the
    // injected TestClock past the timeout must reject `send` with `.timedOut(method:)`.
    // Deterministic: no wall-clock racing — the timeout fires only when WE advance.
    let clock = TestClock()
    let transport = FakeTransport() // no onSend → no inbound frame ever
    let client = HermesGatewayClient.make(requestTimeout: .seconds(30), clock: clock) { _ in transport }
    let stream = client.connect(url, .token("t"))
    defer { withExtendedLifetime(stream) {} }

    // Run `send` in a detached task so we can advance the clock while it's suspended on
    // its pending continuation; capture whatever it throws.
    let thrown = LockIsolated<(any Error)?>(nil)
    let task = Task {
      do { _ = try await client.send("prompt.submit", .object(["text": .string("hi")])) }
      catch { thrown.setValue(error) }
    }
    // Yield enough for `send` to register its pending continuation and the timeout task to
    // reach `clock.sleep`, then fire the timeout deterministically by advancing the clock.
    for _ in 0..<20 { await Task.yield() }
    await clock.advance(by: .seconds(30))
    await task.value

    #expect(thrown.value as? GatewayError == .timedOut(method: "prompt.submit"))
  }

  @Test func normalResponseResolvesAndTimeoutDoesNotFire() async throws {
    // A fast response resolves `send` and cancels its timer. Advancing the TestClock well
    // past the timeout afterwards must produce no spurious late throw — the result stands.
    let clock = TestClock()
    let transport = FakeTransport { frame, inbound in
      if let id = requestID(frame) {
        inbound.yield(#"{"jsonrpc":"2.0","id":\#(id),"result":{"status":"streaming"}}"#)
      }
    }
    let client = HermesGatewayClient.make(requestTimeout: .seconds(30), clock: clock) { _ in transport }
    let stream = client.connect(url, .token("t"))
    defer { withExtendedLifetime(stream) {} }

    let result = try await client.send("prompt.submit", .object(["text": .string("hi")]))
    #expect(result == .object(["status": .string("streaming")]))

    // Advance past the (now-cancelled) timeout window; the resolved value must be unaffected
    // and no late `.timedOut` can fire.
    await clock.advance(by: .seconds(60))
    #expect(result == .object(["status": .string("streaming")]))
  }

  @Test func socketCloseFailsPendingAndFinishesStream() async throws {
    // Close the socket the moment the first request is transmitted (pending is
    // already registered by then, so this is deterministic).
    let transport = FakeTransport { _, inbound in inbound.finish() }
    let client = HermesGatewayClient.make { _ in transport }
    let stream = client.connect(url, .token("t"))

    await #expect(throws: GatewayError.disconnected) {
      _ = try await client.send("session.create", .object([:]))
    }
    var iterator = stream.makeAsyncIterator()
    #expect(await iterator.next() == nil) // stream finished
  }

  // MARK: - Auth-regime URL branching

  /// Regression guard (hard requirement): a `.token` session must build the *exact* legacy
  /// WS URL `…/api/ws?token=<token>` — byte-identical, never minting a ticket.
  @Test func tokenModeBuildsByteIdenticalWSURL() async throws {
    let captured = LockIsolated<URL?>(nil)
    let minted = LockIsolated(false)
    let client = HermesGatewayClient.make(
      mintTicket: { _, _ in minted.setValue(true); return "should-not-mint" },
      makeTransport: { wsURL in captured.setValue(wsURL); return FakeTransport() }
    )
    let stream = client.connect(url, .token("sekret"))
    defer { withExtendedLifetime(stream) {} }

    // The transport is built asynchronously inside `connect`'s setup Task; spin until set.
    for _ in 0..<50 where captured.value == nil { await Task.yield() }

    #expect(captured.value?.absoluteString == "ws://test.local:9119/api/ws?token=sekret")
    #expect(minted.value == false) // token mode never mints a ticket
  }

  /// A `.cookie` session mints a fresh ws-ticket then connects with `…/api/ws?ticket=<t>`.
  @Test func cookieModeMintsTicketThenConnectsWithTicket() async throws {
    let captured = LockIsolated<URL?>(nil)
    let mintArgs = LockIsolated<(URL, CookieSession)?>(nil)
    let cookieSession = CookieSession(
      cookies: [SerializedCookie(name: "hermes_session_at", value: "abc", domain: "test.local", path: "/")],
      username: "alice", provider: "basic"
    )
    let client = HermesGatewayClient.make(
      mintTicket: { base, cs in mintArgs.setValue((base, cs)); return "T1CKET" },
      makeTransport: { wsURL in captured.setValue(wsURL); return FakeTransport() }
    )
    let stream = client.connect(url, .cookie(cookieSession))
    defer { withExtendedLifetime(stream) {} }

    for _ in 0..<50 where captured.value == nil { await Task.yield() }

    #expect(captured.value?.absoluteString == "ws://test.local:9119/api/ws?ticket=T1CKET")
    #expect(mintArgs.value?.0 == url)            // minted against the base URL
    #expect(mintArgs.value?.1 == cookieSession)  // with the persisted cookie session
  }

  /// A `401` from the ticket mint (`authExpired`) yields `.authExpired` on the stream and
  /// finishes — never building a transport (non-retryable; the reducer routes to re-auth).
  @Test func cookieModeMintAuthExpiredYieldsAuthExpiredAndFinishes() async throws {
    let built = LockIsolated(false)
    let client = HermesGatewayClient.make(
      mintTicket: { _, _ in throw GatewayError.authExpired },
      makeTransport: { _ in built.setValue(true); return FakeTransport() }
    )
    let stream = client.connect(url, .cookie(CookieSession(cookies: [], username: "u", provider: "basic")))

    var iterator = stream.makeAsyncIterator()
    #expect(await iterator.next() == .authExpired)
    #expect(await iterator.next() == nil) // then finished
    #expect(built.value == false)         // no socket was opened
  }

  /// A transient mint failure finishes the stream like a dropped socket (no `.authExpired`)
  /// so the reducer's existing backoff re-calls `connect` and re-mints.
  @Test func cookieModeTransientMintFinishesStreamWithoutAuthExpired() async throws {
    let client = HermesGatewayClient.make(
      mintTicket: { _, _ in throw GatewayError.ticketUnavailable },
      makeTransport: { _ in FakeTransport() }
    )
    let stream = client.connect(url, .cookie(CookieSession(cookies: [], username: "u", provider: "basic")))

    var iterator = stream.makeAsyncIterator()
    #expect(await iterator.next() == nil) // finished, no .authExpired emitted
  }

  /// After a successful **cookie** connect, terminating the stream (consumer cancels →
  /// `onTermination`) must shut the opened transport down. Guards the lost-shutdown leak
  /// where the cookie-path `onTermination` clobbered the connection's shutdown handler.
  @Test func cookieModeStreamTerminationShutsDownOpenedConnection() async throws {
    let captured = LockIsolated<URL?>(nil)
    let transport = FakeTransport()
    let client = HermesGatewayClient.make(
      mintTicket: { _, _ in "T1CKET" },
      makeTransport: { wsURL in captured.setValue(wsURL); return transport }
    )
    // Scope the stream so it's fully released (its `onTermination` then fires) after connect.
    do {
      let stream = client.connect(url, .cookie(CookieSession(cookies: [], username: "u", provider: "basic")))
      // Wait for the async mint+open to build the transport before dropping the stream.
      for _ in 0..<100 where captured.value == nil { await Task.yield() }
      #expect(captured.value != nil) // connection opened
      _ = stream
    }
    // The dropped stream's termination handler shuts the opened connection down (async).
    for _ in 0..<100 where !transport.cancelled { await Task.yield() }
    #expect(transport.cancelled) // socket was torn down, not leaked
  }
}
