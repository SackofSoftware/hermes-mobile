import ComposableArchitecture
import DependenciesMacros
import Foundation

// MARK: - Client

/// The live wire to the Hermes gateway: a single WebSocket carrying newline-delimited
/// JSON-RPC 2.0. `connect` opens the socket and yields decoded server events; `send`
/// issues a request and awaits its `{id,result}` via an internal pending-request map.
@DependencyClient
public struct HermesGatewayClient: Sendable {
  /// Open a connection to the server (base URL + token) and stream decoded events.
  /// The stream finishes when the socket closes or the consumer stops iterating.
  public var connect: @Sendable (_ baseURL: URL, _ token: String?) -> AsyncStream<GatewayEvent> = { _, _ in
    AsyncStream { $0.finish() }
  }
  /// Send a JSON-RPC request on the current connection and await its result.
  public var send: @Sendable (_ method: String, _ params: JSONValue) async throws -> JSONValue
  /// Tear down the current connection.
  public var disconnect: @Sendable () -> Void
}

public enum GatewayError: Error, Equatable, Sendable {
  case notConnected
  case disconnected
  case server(String)
}

// MARK: - Live / factory

public extension HermesGatewayClient {
  static func live(session: URLSession = URLSession(configuration: .default)) -> HermesGatewayClient {
    .make { baseURL, token in
      URLSessionWebSocketTransport(url: webSocketURL(base: baseURL, token: token), session: session)
    }
  }

  /// Core factory parameterized by a transport-maker so tests can inject a fake
  /// socket. The connection state (id counter, pending map) lives in a per-connect
  /// `GatewayConnection` actor; `store` holds the current one for `send`/`disconnect`.
  static func make(
    makeTransport: @escaping @Sendable (_ baseURL: URL, _ token: String?) -> any WebSocketTransport
  ) -> HermesGatewayClient {
    let store = ConnectionStore()
    return HermesGatewayClient(
      connect: { baseURL, token in
        let (stream, continuation) = AsyncStream<GatewayEvent>.makeStream()
        let connection = GatewayConnection(transport: makeTransport(baseURL, token), events: continuation)
        store.set(connection)
        continuation.onTermination = { _ in Task { await connection.shutdown() } }
        Task { await connection.start() }
        return stream
      },
      send: { method, params in
        guard let connection = store.get() else { throw GatewayError.notConnected }
        return try await connection.send(method: method, params: params)
      },
      disconnect: {
        let connection = store.get()
        store.set(nil)
        Task { await connection?.shutdown() }
      }
    )
  }
}

extension HermesGatewayClient: DependencyKey {
  public static var liveValue: HermesGatewayClient { .live() }
  public static var testValue: HermesGatewayClient { HermesGatewayClient() }
}

public extension DependencyValues {
  var hermesGateway: HermesGatewayClient {
    get { self[HermesGatewayClient.self] }
    set { self[HermesGatewayClient.self] = newValue }
  }
}

// MARK: - Connection actor

/// Owns one socket's lifecycle: the JSON-RPC id counter, the pending-request map, and
/// the receive loop that routes frames to either the event stream or a waiting `send`.
actor GatewayConnection {
  private let transport: any WebSocketTransport
  private let events: AsyncStream<GatewayEvent>.Continuation
  private var idCounter = 0
  private var pending: [Int: CheckedContinuation<JSONValue, any Error>] = [:]
  private var receiveTask: Task<Void, Never>?
  private var isFinished = false

  init(transport: any WebSocketTransport, events: AsyncStream<GatewayEvent>.Continuation) {
    self.transport = transport
    self.events = events
  }

  func start() {
    guard receiveTask == nil else { return }
    receiveTask = Task { [weak self] in await self?.receiveLoop() }
  }

  func send(method: String, params: JSONValue) async throws -> JSONValue {
    // Never register against a torn-down connection — that continuation would
    // never be resumed (the receive loop is gone), hanging the caller forever.
    guard !isFinished else { throw GatewayError.disconnected }
    idCounter += 1
    let id = idCounter
    let request = JSONRPCRequest(id: id, method: method, params: params)
    let text = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
    return try await withCheckedThrowingContinuation { continuation in
      // Register before transmitting so a fast response can't race ahead of us.
      pending[id] = continuation
      Task { await transmit(id: id, text: text) }
    }
  }

  func shutdown() {
    guard !isFinished else { return }
    receiveTask?.cancel()
    transport.cancel()
    finish(error: .disconnected)
  }

  private func transmit(id: Int, text: String) async {
    do {
      try await transport.send(text)
    } catch {
      pending.removeValue(forKey: id)?.resume(throwing: error)
    }
  }

  private func receiveLoop() async {
    while !Task.isCancelled {
      let text: String
      do {
        text = try await transport.receive()
      } catch {
        break // socket closed or errored
      }
      // A single WS message may carry multiple newline-delimited frames.
      for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
        handle(frame: String(line))
      }
    }
    finish(error: .disconnected)
  }

  private func handle(frame: String) {
    guard let parsed = try? InboundFrame(data: Data(frame.utf8)) else { return }
    switch parsed {
    case let .event(_, event):
      events.yield(event)
    case let .response(id, result):
      pending.removeValue(forKey: id)?.resume(returning: result)
    case let .failure(id, message):
      if let id { pending.removeValue(forKey: id)?.resume(throwing: GatewayError.server(message)) }
    case .ignored:
      break
    }
  }

  private func finish(error: GatewayError) {
    guard !isFinished else { return }
    isFinished = true
    events.finish()
    let outstanding = pending
    pending.removeAll()
    for (_, continuation) in outstanding { continuation.resume(throwing: error) }
  }
}

/// Holds the current connection so the stateless client closures can reach it.
private final class ConnectionStore: @unchecked Sendable {
  private let lock = NSLock()
  private var current: GatewayConnection?
  func set(_ connection: GatewayConnection?) { lock.withLock { current = connection } }
  func get() -> GatewayConnection? { lock.withLock { current } }
}

// MARK: - Transport

/// The minimal socket surface the connection needs. Abstracted so tests can swap in a
/// fake without a real network.
public protocol WebSocketTransport: Sendable {
  func send(_ text: String) async throws
  func receive() async throws -> String
  func cancel()
}

final class URLSessionWebSocketTransport: WebSocketTransport, @unchecked Sendable {
  private let task: URLSessionWebSocketTask

  init(url: URL, session: URLSession) {
    task = session.webSocketTask(with: url)
    task.resume()
  }

  func send(_ text: String) async throws {
    try await task.send(.string(text))
  }

  func receive() async throws -> String {
    switch try await task.receive() {
    case let .string(text): return text
    case let .data(data): return String(decoding: data, as: UTF8.self)
    @unknown default: return ""
    }
  }

  func cancel() {
    task.cancel(with: .goingAway, reason: nil)
  }
}

private func webSocketURL(base: URL, token: String?) -> URL {
  var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) ?? URLComponents()
  comps.scheme = (comps.scheme == "https" || comps.scheme == "wss") ? "wss" : "ws"
  comps.path = "/api/ws"
  comps.queryItems = token.map { [URLQueryItem(name: "token", value: $0)] }
  return comps.url ?? base
}
