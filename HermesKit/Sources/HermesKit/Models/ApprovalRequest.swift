import Foundation

/// Payload for an `approval.request` event — the agent is blocked waiting for the
/// user to approve/deny an action. Responded to via `approval.respond`.
/// Shape not yet verified against a live request — to confirm in M2 (Task 9).
public struct ApprovalRequest: Equatable, Sendable, Decodable {
  public var requestID: String
  public var command: String?

  enum CodingKeys: String, CodingKey {
    case requestID = "request_id"
    case command
  }

  public init(requestID: String, command: String? = nil) {
    self.requestID = requestID
    self.command = command
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
