import Foundation

/// Payload for an `approval.request` event — the agent is blocked waiting for the
/// user to approve/deny a dangerous action (e.g. a destructive shell command).
/// Responded to via `approval.respond`.
///
/// Wire shape verified against `hermes-agent` `tools/approval.py` (`approval_data`):
/// `{command, description, pattern_key, pattern_keys}`. **There is no `request_id`** —
/// unlike clarify/sudo/secret (which are queue-keyed by `request_id`), approvals are
/// resolved per-session via a FIFO queue, so `approval.respond` only needs
/// `session_id` + `choice` + `all`. Every field is therefore optional and decoded
/// leniently: a malformed/partial payload still yields an approval prompt rather than
/// silently degrading to `.unknown` and hanging the turn.
/// Deliberately only `Equatable`: the card's view identity comes from the reducer's monotonic
/// `pendingInteractionToken`, never from the request's value — two back-to-back approvals can
/// be *equal* (an agent retrying the same command), which is exactly the pair a value-derived
/// id cannot tell apart.
public struct ApprovalRequest: Equatable, Sendable, Decodable {
  /// The command awaiting approval (shown verbatim in the card).
  public var command: String?
  /// Human-readable summary of what will happen (server's `description`).
  public var detail: String?
  /// The danger pattern that matched (server's `pattern_key`).
  public var patternKey: String?
  /// All matched danger patterns when several commands are batched together.
  public var patternKeys: [String]

  enum CodingKeys: String, CodingKey {
    case command
    case detail = "description"
    case patternKey = "pattern_key"
    case patternKeys = "pattern_keys"
  }

  public init(
    command: String? = nil,
    detail: String? = nil,
    patternKey: String? = nil,
    patternKeys: [String] = []
  ) {
    self.command = command
    self.detail = detail
    self.patternKey = patternKey
    self.patternKeys = patternKeys
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    command = try c.decodeIfPresent(String.self, forKey: .command)
    detail = try c.decodeIfPresent(String.self, forKey: .detail)
    patternKey = try c.decodeIfPresent(String.self, forKey: .patternKey)
    patternKeys = try c.decodeIfPresent([String].self, forKey: .patternKeys) ?? []
  }

  /// Whether the card may offer the session-wide "Approve all in this session"
  /// escalation (`choice: "session"`, which persists the matched danger pattern for the
  /// rest of the session and `resolve_all`s the queue). A push-tap-recovered request
  /// (#30 workaround) carries no command and no pattern — approving it blind is already
  /// the leap the honest recovery copy covers, but silently whitelisting an UNSEEN
  /// pattern goes a step further, so the toggle is hidden. Content-derived on purpose:
  /// no `isSynthesized` marker exists anywhere (the recovered card is distinguished
  /// only by its content).
  public var offersSessionApproval: Bool {
    command?.isEmpty == false || patternKey?.isEmpty == false || !patternKeys.isEmpty
  }
}

/// Payload for a `clarify.request` event. `choices` is empty when the agent expects
/// free-text. Responded to via `clarify.respond`.
/// Shape not yet verified against a live request — to confirm in M2 (Task 10).
public struct ClarifyRequest: Equatable, Sendable, Decodable {
  public var requestID: String
  public var question: String
  public var choices: [String]

  enum CodingKeys: String, CodingKey {
    case requestID = "request_id"
    case question
    case choices
  }

  public init(requestID: String, question: String, choices: [String] = []) {
    self.requestID = requestID
    self.question = question
    self.choices = choices
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    requestID = try c.decode(String.self, forKey: .requestID)
    question = try c.decodeIfPresent(String.self, forKey: .question) ?? ""
    choices = try c.decodeIfPresent([String].self, forKey: .choices) ?? []
  }
}
