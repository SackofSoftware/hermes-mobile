import Foundation

/// One question of a clarify prompt. A v0.21.6+ request always carries a `questions` list
/// (one entry for a single question); the intermediate (v2026.9.14–.24) single form and the
/// legacy `clarify.request` event carry one top-level question, decoded into one of these
/// with a `nil` `qid`.
public struct ClarifyQuestion: Equatable, Sendable {
  /// Stable wire id the answer is keyed by (`q0`…`q4`). `nil` only for the intermediate and
  /// legacy single forms, whose answer is not keyed.
  public var qid: String?
  public var question: String
  /// Raw choices, best first; the first of two or more may carry the server's
  /// `" (Recommended)"` suffix — split it with ``ClarifyChoice/split(_:)`` for display and
  /// for the answer (the bare label is what gets sent). Empty = free text.
  public var choices: [String]
  /// Several choices may be picked (the answer is then a JSON-array string). Always `false`
  /// for a free-text question, as upstream normalizes it.
  public var multiSelect: Bool

  public var isFreeText: Bool { choices.isEmpty }

  public init(qid: String? = nil, question: String, choices: [String] = [], multiSelect: Bool = false) {
    self.qid = qid
    self.question = question
    self.choices = choices
    self.multiSelect = multiSelect && !choices.isEmpty
  }
}

/// A clarify prompt in any of its three wire generations, as one model: the layout comes
/// from the question count, the answer's wire shape from ``answerShape``.
///
/// Decoding picks the shape from the payload:
/// - a `questions` list with at least one usable entry (`qid` + non-blank `question`) →
///   ``AnswerShape/answers`` (v0.21.6+, and the intermediate batch); replayed `answers`
///   become ``lockedAnswers``;
/// - a `request_id` → ``AnswerShape/legacyRespond`` (the legacy `clarify.request` event,
///   decoded exactly as before: `question` defaults to `""`);
/// - a top-level non-blank `question` → ``AnswerShape/singleAnswer`` (the intermediate
///   single server request);
/// - anything else is a decode failure.
///
/// Lenient within a shape: `choices: null` (or a non-array) is free text, non-string choices
/// are dropped, `multi_select` defaults to `false`, an unusable `questions` entry is dropped
/// (the rest still render), and unknown keys are ignored.
///
/// Deliberately only `Equatable` (no value-derived card identity) — see `ApprovalRequest`.
public struct ClarifyRequest: Equatable, Sendable, Decodable {
  /// The legacy event's `request_id` (answered through `clarify.respond`). `nil` for a v7
  /// server request, which is identified by its `srq-…` id on `PendingServerRequest`.
  public var requestID: String?
  /// At least one after decoding.
  public var questions: [ClarifyQuestion]
  /// Answers the server already locked for a batch (replayed `params.answers`), keyed by
  /// qid; a `nil` value is a locked skip. Shown as locked and re-sent with the final set.
  public var lockedAnswers: [String: String?]
  public var answerShape: AnswerShape

  /// How the answer goes back on the wire.
  public enum AnswerShape: Equatable, Sendable {
    /// `request.answer {id, result: {answers: {qid: text|null}}}`; cancel-all is `{}`.
    case answers
    /// Intermediate single server request: `request.answer {id, result: {answer}}`;
    /// skip is `{answer: ""}`.
    case singleAnswer
    /// Legacy event: `clarify.respond {session_id, request_id, answer}`.
    case legacyRespond
  }

  /// Layout only: several questions render as sections with a pinned Confirm/Skip row.
  public var isMultiQuestion: Bool { questions.count > 1 }

  /// The first question's text — the single-question card and the gateway-log summary.
  public var question: String { questions.first?.question ?? "" }
  /// The first question's raw choices — the single-question card.
  public var choices: [String] { questions.first?.choices ?? [] }

  public init(
    requestID: String?,
    questions: [ClarifyQuestion],
    lockedAnswers: [String: String?] = [:],
    answerShape: AnswerShape
  ) {
    self.requestID = requestID
    self.questions = questions
    self.lockedAnswers = lockedAnswers
    self.answerShape = answerShape
  }

  /// The single-question form: a `requestID` makes it the legacy event, none the
  /// intermediate single server request.
  public init(requestID: String?, question: String, choices: [String] = [], multiSelect: Bool = false) {
    self.init(
      requestID: requestID,
      questions: [ClarifyQuestion(question: question, choices: choices, multiSelect: multiSelect)],
      answerShape: requestID == nil ? .singleAnswer : .legacyRespond
    )
  }

  public init(from decoder: Decoder) throws {
    let payload = try JSONValue(from: decoder)
    guard let request = Self.parse(payload) else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "No usable clarify question")
      )
    }
    self = request
  }

  private static func parse(_ payload: JSONValue) -> ClarifyRequest? {
    guard case .object = payload else { return nil }

    let questions = (payload["questions"]?.arrayValue ?? []).compactMap(batchQuestion)
    if !questions.isEmpty {
      return ClarifyRequest(
        requestID: nil,
        questions: questions,
        lockedAnswers: lockedAnswers(payload["answers"]),
        answerShape: .answers
      )
    }

    if let requestID = payload["request_id"]?.stringValue {
      return ClarifyRequest(
        requestID: requestID,
        question: payload["question"]?.stringValue ?? "",
        choices: choices(payload["choices"])
      )
    }

    if let question = payload["question"]?.stringValue, !isBlank(question) {
      return ClarifyRequest(
        requestID: nil,
        question: question,
        choices: choices(payload["choices"]),
        multiSelect: payload["multi_select"]?.boolValue ?? false
      )
    }
    return nil
  }

  private static func batchQuestion(_ entry: JSONValue) -> ClarifyQuestion? {
    guard let qid = entry["qid"]?.stringValue, !qid.isEmpty,
          let question = entry["question"]?.stringValue, !isBlank(question)
    else { return nil }
    return ClarifyQuestion(
      qid: qid,
      question: question,
      choices: choices(entry["choices"]),
      multiSelect: entry["multi_select"]?.boolValue ?? false
    )
  }

  private static func choices(_ value: JSONValue?) -> [String] {
    (value?.arrayValue ?? []).compactMap(\.stringValue)
  }

  /// String values lock an answer, `null` locks a skip; any other value is ignored (the
  /// question stays open rather than showing a lock the app cannot render).
  private static func lockedAnswers(_ value: JSONValue?) -> [String: String?] {
    guard case let .object(entries)? = value else { return [:] }
    var locked: [String: String?] = [:]
    for (qid, answer) in entries {
      switch answer {
      case let .string(text): locked[qid] = .some(text)
      case .null: locked[qid] = .some(nil)
      default: continue
      }
    }
    return locked
  }

  private static func isBlank(_ text: String) -> Bool {
    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}

/// Presentation helpers for a clarify choice.
public enum ClarifyChoice {
  /// The server's marker on the first of two or more choices (upstream `RECOMMENDED_LABEL`).
  public static let recommendedLabel = "(Recommended)"

  /// `("Use SwiftUI", isRecommended: true)` for `"Use SwiftUI (Recommended)"`. Mirrors
  /// upstream `strip_recommended`: trimmed, case-insensitive suffix match, the label trimmed
  /// again. The label is the text to display AND to send (the server strips it anyway; the
  /// desktop sends the bare text). A choice that is nothing but the marker keeps it as its
  /// label (never an empty row) and is not marked recommended.
  public static func split(_ raw: String) -> (label: String, isRecommended: Bool) {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let suffix = trimmed.range(
      of: recommendedLabel, options: [.caseInsensitive, .anchored, .backwards]
    ) else {
      return (trimmed, false)
    }
    let label = String(trimmed[..<suffix.lowerBound])
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return label.isEmpty ? (trimmed, false) : (label, true)
  }
}
