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

  var sent: [String] { lock.withLock { _sent } }

  func send(_ text: String) async throws {
    lock.withLock { _sent.append(text) }
    onSend(text, inboundContinuation)
  }

  func receive() async throws -> String {
    guard let next = await iterator.next() else { throw GatewayError.disconnected }
    return next
  }

  func cancel() { inboundContinuation.finish() }
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
    let client = HermesGatewayClient.make { _, _ in transport }
    let stream = client.connect(url, nil)
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
    let client = HermesGatewayClient.make { _, _ in transport }
    let stream = client.connect(url, nil)

    transport.inject(#"{"jsonrpc":"2.0","method":"event","params":{"type":"message.delta","session_id":"s","payload":{"text":"hi"}}}"#)

    var iterator = stream.makeAsyncIterator()
    #expect(await iterator.next() == .messageDelta(text: "hi"))
  }

  @Test func multipleNewlineDelimitedFramesInOneMessage() async throws {
    let transport = FakeTransport()
    let client = HermesGatewayClient.make { _, _ in transport }
    let stream = client.connect(url, nil)

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
    let client = HermesGatewayClient.make { _, _ in transport }
    let stream = client.connect(url, nil)
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
    let client = HermesGatewayClient.make { _, _ in transport }
    let stream = client.connect(url, nil)
    defer { withExtendedLifetime(stream) {} }

    async let first = client.send("m", .object(["k": .string("a")]))
    async let second = client.send("m", .object(["k": .string("b")]))
    let (a, b) = try await (first, second)

    let ea = try #require(a["echo"]?.intValue)
    let eb = try #require(b["echo"]?.intValue)
    #expect(ea != eb)
  }

  @Test func sendBeforeConnectThrowsNotConnected() async {
    let client = HermesGatewayClient.make { _, _ in FakeTransport() }
    await #expect(throws: GatewayError.notConnected) {
      _ = try await client.send("session.create", .object([:]))
    }
  }

  @Test func socketCloseFailsPendingAndFinishesStream() async throws {
    // Close the socket the moment the first request is transmitted (pending is
    // already registered by then, so this is deterministic).
    let transport = FakeTransport { _, inbound in inbound.finish() }
    let client = HermesGatewayClient.make { _, _ in transport }
    let stream = client.connect(url, nil)

    await #expect(throws: GatewayError.disconnected) {
      _ = try await client.send("session.create", .object([:]))
    }
    var iterator = stream.makeAsyncIterator()
    #expect(await iterator.next() == nil) // stream finished
  }
}
