import Foundation

/// Which credential a secret card collects. Lives with the models (not inside
/// `ChatFeature.State.PendingInteraction`) so `PendingServerRequest` does not depend on
/// the feature.
public enum SecretKind: Equatable, Sendable { case sudo, secret }

/// One open v7 server→client prompt (`{"id":"srq-…","method":…,"params":…}`). `id` is the
/// `srq-…` request id — the only place the app stores it; answers go out as
/// `request.answer {id, result}`. `ChatFeature` keeps these in one ordered queue per slot
/// and presents the head.
///
/// Deliberately only `Equatable` (no value-derived card identity): two back-to-back
/// requests can carry equal payloads, and the card identity is the reducer's
/// `pendingInteractionToken`.
public struct PendingServerRequest: Equatable, Sendable, Identifiable {
  public var id: String
  public var kind: Kind

  public enum Kind: Equatable, Sendable {
    case approval(ApprovalRequest)
    case clarify(ClarifyRequest)
    case secret(SecretKind, SecretPrompt)
  }

  public init(id: String, kind: Kind) {
    self.id = id
    self.kind = kind
  }

  /// The wire method this request arrived as (`approval`, `clarify`, `sudo`, `secret`).
  public var method: String {
    switch kind {
    case .approval: "approval"
    case .clarify: "clarify"
    case .secret(.sudo, _): "sudo"
    case .secret(.secret, _): "secret"
    }
  }

  /// Decode a server request the app renders. `nil` when the method is not rendered here,
  /// or when a rendered method's params are malformed — the caller then answers with
  /// ``malformedSkip(for:)`` so the agent is never left hanging.
  ///
  /// Rendered today: `approval`, `clarify`. An approval whose params decode but carry nothing
  /// to show (no command, description or danger pattern) counts as malformed: on v7 the real
  /// card is always recoverable from the replay, so a content-less card would only invite a
  /// blind approve.
  ///
  /// A clarify server request is answered through `request.answer`, never `clarify.respond`,
  /// so it only accepts the two v7 shapes: a usable `questions` list (`.answers`) or a
  /// top-level non-blank `question` (`.singleAnswer`). A stray `request_id` (the legacy
  /// event's key) does not make it legacy — it is answered in the single shape, or is
  /// malformed when no question is left.
  public init?(id: String, method: String, params: JSONValue) {
    switch method {
    case "approval":
      guard let request = params.decoded(ApprovalRequest.self), request.hasContent else { return nil }
      self.init(id: id, kind: .approval(request))
    case "clarify":
      guard var request = params.decoded(ClarifyRequest.self) else { return nil }
      if request.answerShape == .legacyRespond {
        guard let only = request.questions.first,
              !only.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        request = ClarifyRequest(
          requestID: nil, question: only.question, choices: only.choices,
          multiSelect: params["multi_select"]?.boolValue ?? false
        )
      }
      self.init(id: id, kind: .clarify(request))
    default:
      return nil
    }
  }

  /// The `request.answer` result that skips a rendered method whose params failed to decode
  /// (approval: `{choice: "deny"}`; clarify: `{}`, cancel-all). `nil` for every method the
  /// app does not render — those get nothing, or the window-owned 4404 decline (see
  /// `windowOwnedMethods`).
  public static func malformedSkip(for method: String) -> JSONValue? {
    switch method {
    case "approval": .object(["choice": .string("deny")])
    case "clarify": .object([:])
    default: nil
    }
  }

  /// Window-owned bridges: the only methods the phone may decline with the non-settling
  /// `4404` ("Not shown on this client"), and only once the advertisement acknowledged
  /// `declines_not_shown`. Every other unrendered method (`vault.*`, `setup_choose`,
  /// `display.install.sudo`, anything new) gets no reply at all: an error settles at once
  /// and a 4404 on a prompt can feed a refusal string to the password manager.
  public static let windowOwnedMethods: Set<String> = [
    "terminal.read", "preview.read", "window.read", "preview.act", "tour",
  ]
}

/// A `request.cancel` event payload: the server withdrew an open server request
/// (`reason`: `timeout | interrupted | shutdown | resolved | session_closed`, or an approval
/// caller's own wording). Not emitted when another client answered by response frame.
public struct RequestCancel: Equatable, Sendable, Decodable {
  /// The `srq-…` id of the withdrawn request.
  public var id: String
  public var method: String?
  public var reason: String?

  public init(id: String, method: String? = nil, reason: String? = nil) {
    self.id = id
    self.method = method
    self.reason = reason
  }
}
