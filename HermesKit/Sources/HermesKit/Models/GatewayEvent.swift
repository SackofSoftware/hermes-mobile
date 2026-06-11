import Foundation

/// A decoded server→client event from the gateway. Shapes verified against the M0
/// probe (`docs/plans/...` → "M0 findings"): streaming message events carry **no
/// message id**, and `session_id` lives on the event frame, not the payload.
public enum GatewayEvent: Equatable, Sendable {
  case ready
  case sessionInfo(SessionInfo)
  case messageStart
  case messageDelta(text: String)
  case messageComplete(text: String, usage: Usage?)
  case thinkingDelta(text: String)
  case reasoningAvailable(text: String)
  case statusUpdate(kind: String, text: String)
  case toolStart(toolID: String?, name: String, args: JSONValue)
  case toolComplete(toolID: String?, name: String?, result: String?, durationS: Double?)
  case approvalRequest(ApprovalRequest)
  case clarifyRequest(ClarifyRequest)
  case sudoRequest(SecretPrompt)
  case secretRequest(SecretPrompt)
  case error(message: String)
  /// Any event type we don't model (incl. ones ignored for MVP like `tool.progress`,
  /// `tool.generating`, `background.complete`, `skin.changed`). Never throws.
  case unknown(type: String, raw: JSONValue)

  /// Map an event `type` + `payload` to a case. Unknown types fall through to `.unknown`.
  init(type: String, payload: JSONValue?) {
    let p = payload ?? .object([:])
    switch type {
    case "gateway.ready":
      self = .ready
    case "session.info":
      self = .sessionInfo(payload?.decoded(SessionInfo.self) ?? SessionInfo())
    case "message.start":
      self = .messageStart
    case "message.delta":
      self = .messageDelta(text: p["text"]?.stringValue ?? "")
    case "message.complete":
      self = .messageComplete(text: p["text"]?.stringValue ?? "", usage: p["usage"]?.decoded(Usage.self))
    case "thinking.delta":
      self = .thinkingDelta(text: p["text"]?.stringValue ?? "")
    case "reasoning.delta":
      // Incremental reasoning folds into the same collapsible "thinking" row.
      self = .thinkingDelta(text: p["text"]?.stringValue ?? "")
    case "reasoning.available":
      self = .reasoningAvailable(text: p["text"]?.stringValue ?? "")
    case "status.update":
      self = .statusUpdate(kind: p["kind"]?.stringValue ?? "", text: p["text"]?.stringValue ?? "")
    case "tool.start":
      self = .toolStart(toolID: p["tool_id"]?.stringValue, name: p["name"]?.stringValue ?? "", args: p["args"] ?? .null)
    case "tool.complete":
      self = .toolComplete(
        toolID: p["tool_id"]?.stringValue,
        name: p["name"]?.stringValue,
        result: p["result"]?.stringValue,
        durationS: p["duration_s"]?.doubleValue
      )
    case "approval.request":
      if let req = p.decoded(ApprovalRequest.self) { self = .approvalRequest(req) }
      else { self = .unknown(type: type, raw: p) }
    case "clarify.request":
      if let req = p.decoded(ClarifyRequest.self) { self = .clarifyRequest(req) }
      else { self = .unknown(type: type, raw: p) }
    case "sudo.request":
      if let req = p.decoded(SecretPrompt.self) { self = .sudoRequest(req) }
      else { self = .unknown(type: type, raw: p) }
    case "secret.request":
      if let req = p.decoded(SecretPrompt.self) { self = .secretRequest(req) }
      else { self = .unknown(type: type, raw: p) }
    case "error":
      self = .error(message: p["message"]?.stringValue ?? "")
    default:
      self = .unknown(type: type, raw: p)
    }
  }
}

// MARK: - Payload helper types

/// Token / context / cost accounting attached to `message.complete` and `session.info`.
/// Lenient: every field is optional. Verified shape from the M0 probe.
public struct Usage: Equatable, Sendable, Decodable {
  public var model: String?
  public var input: Int?
  public var output: Int?
  public var total: Int?
  public var contextUsed: Int?
  public var contextMax: Int?
  public var contextPercent: Int?
  public var costUSD: Double?

  enum CodingKeys: String, CodingKey {
    case model, input, output, total
    case contextUsed = "context_used"
    case contextMax = "context_max"
    case contextPercent = "context_percent"
    case costUSD = "cost_usd"
  }
}

/// `session.info` runtime metadata. Large and volatile on the wire — we decode only
/// the few fields the UI needs and ignore the rest (Codable skips unknown keys).
public struct SessionInfo: Equatable, Sendable, Decodable {
  public var model: String?
  public var running: Bool?
  public var version: String?
  public var cwd: String?
  public var profileName: String?
  public var usage: Usage?

  enum CodingKeys: String, CodingKey {
    case model, running, version, cwd, usage
    case profileName = "profile_name"
  }

  public init(
    model: String? = nil, running: Bool? = nil, version: String? = nil,
    cwd: String? = nil, profileName: String? = nil, usage: Usage? = nil
  ) {
    self.model = model
    self.running = running
    self.version = version
    self.cwd = cwd
    self.profileName = profileName
    self.usage = usage
  }
}

/// Payload for `sudo.request` / `secret.request`. Shape not yet verified against a
/// live request — to confirm in M2 (Tasks 9–10).
public struct SecretPrompt: Equatable, Sendable, Decodable {
  public var requestID: String
  public var prompt: String?

  enum CodingKeys: String, CodingKey {
    case requestID = "request_id"
    case prompt
  }

  public init(requestID: String, prompt: String? = nil) {
    self.requestID = requestID
    self.prompt = prompt
  }
}
