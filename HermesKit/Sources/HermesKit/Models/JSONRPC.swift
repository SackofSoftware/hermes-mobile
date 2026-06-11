import Foundation

// MARK: - JSONValue

/// A loss-tolerant representation of arbitrary JSON. Used for protocol surfaces
/// whose shape we don't fully model (tool args, the `unknown` event payload, the
/// raw `result` of a JSON-RPC response that a later layer decodes into a type).
public enum JSONValue: Equatable, Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])
}

extension JSONValue: Codable {
  public init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() {
      self = .null
    } else if let b = try? c.decode(Bool.self) {
      self = .bool(b)
    } else if let d = try? c.decode(Double.self) {
      self = .number(d)
    } else if let s = try? c.decode(String.self) {
      self = .string(s)
    } else if let a = try? c.decode([JSONValue].self) {
      self = .array(a)
    } else if let o = try? c.decode([String: JSONValue].self) {
      self = .object(o)
    } else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON value")
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .null: try c.encodeNil()
    case .bool(let b): try c.encode(b)
    case .number(let d): try c.encode(d)
    case .string(let s): try c.encode(s)
    case .array(let a): try c.encode(a)
    case .object(let o): try c.encode(o)
    }
  }
}

public extension JSONValue {
  /// Object member access, e.g. `payload["text"]`.
  subscript(_ key: String) -> JSONValue? {
    if case .object(let o) = self { return o[key] }
    return nil
  }

  var stringValue: String? { if case .string(let s) = self { return s }; return nil }
  var doubleValue: Double? { if case .number(let d) = self { return d }; return nil }
  var intValue: Int? { if case .number(let d) = self { return Int(d) }; return nil }
  var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
  var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }

  /// Re-decode this value into a concrete `Decodable` type. Returns nil on mismatch.
  func decoded<T: Decodable>(_ type: T.Type = T.self) -> T? {
    guard let data = try? JSONEncoder().encode(self) else { return nil }
    return try? JSONDecoder().decode(T.self, from: data)
  }
}

// MARK: - Outbound request

/// A JSON-RPC 2.0 request the client sends to the gateway over the WebSocket.
public struct JSONRPCRequest: Encodable, Equatable, Sendable {
  public let jsonrpc = "2.0"
  public let id: Int
  public let method: String
  public let params: JSONValue

  public init(id: Int, method: String, params: JSONValue) {
    self.id = id
    self.method = method
    self.params = params
  }
}

// MARK: - Inbound frame

/// One inbound WebSocket frame, classified. The gateway is newline-delimited, so a
/// single text message may contain multiple frames; splitting is the client's job
/// (Task 5). This decodes exactly one frame and never throws on an unknown event
/// `type` — unknown events surface as `GatewayEvent.unknown`.
public enum InboundFrame: Equatable, Sendable {
  /// A server-pushed event notification: `{method:"event", params:{type, session_id, payload}}`.
  case event(sessionID: String?, GatewayEvent)
  /// A successful response to a request we sent: `{id, result}`.
  case response(id: Int, result: JSONValue)
  /// An error response: `{id, error:{message}}`.
  case failure(id: Int?, message: String)
  /// A well-formed frame we don't act on (e.g. a non-`event` notification).
  case ignored

  public init(data: Data) throws {
    let frame = try JSONDecoder().decode(JSONValue.self, from: data)

    if frame["method"]?.stringValue == "event", let params = frame["params"] {
      let type = params["type"]?.stringValue ?? ""
      let sessionID = params["session_id"]?.stringValue
      self = .event(sessionID: sessionID, GatewayEvent(type: type, payload: params["payload"]))
      return
    }

    if let id = frame["id"]?.intValue {
      if let result = frame["result"] {
        self = .response(id: id, result: result)
      } else if let message = frame["error"]?["message"]?.stringValue {
        self = .failure(id: id, message: message)
      } else if frame["error"] != nil {
        self = .failure(id: id, message: "Unknown error")
      } else {
        self = .ignored
      }
      return
    }

    self = .ignored
  }
}
