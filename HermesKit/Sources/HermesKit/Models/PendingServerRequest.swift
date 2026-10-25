import Foundation

/// Which credential a secret card collects.
public enum SecretKind: Equatable, Sendable { case sudo, secret }

/// A blocking interactive request the agent is waiting on — the card `ChatFeature` presents
/// (`ChatFeature.State.PendingInteraction`), whether it came from a legacy `*.request` event
/// or a v7 server request. Lives with the models so `PendingServerRequest` does not depend on
/// the feature.
public enum PendingInteraction: Equatable, Sendable {
  case approval(ApprovalRequest)
  case clarify(ClarifyRequest)
  case secret(SecretKind, SecretPrompt)

  /// The transcript status-row kind for this card's outcome rows.
  public var statusKind: String {
    switch self {
    case .approval: "approval"
    case .clarify: "clarify"
    case .secret: "secret"
    }
  }
}

/// The v7 server-request methods the app renders as a card.
public enum PromptMethod: String, CaseIterable, Sendable {
  case approval, clarify, sudo, secret

  /// The `request.answer` result that skips this prompt (approval: `{choice: "deny"}`;
  /// clarify: `{}`, cancel-all; sudo / secret: `{value: ""}`).
  var skipResult: JSONValue {
    switch self {
    case .approval: .object(["choice": .string("deny")])
    case .clarify: .object([:])
    case .sudo, .secret: .object(["value": .string("")])
    }
  }

  /// The banner for a prompt of this kind the phone cannot read (left unanswered on purpose).
  public var unreadableMessage: String {
    let prompt = switch self {
    case .approval: "an approval request"
    case .clarify: "a question"
    case .sudo: "a password request"
    case .secret: "a secret request"
    }
    return "Couldn’t show \(prompt) from the agent. Answer it on another device, or stop the turn."
  }

  /// The failure context when sending ``skipResult`` for a malformed prompt fails.
  var skipFailureContext: String {
    self == .approval ? "Couldn’t deny a malformed approval" : "Couldn’t skip a malformed \(rawValue) prompt"
  }
}

/// `request.answer`'s acknowledgement: `ok` = this answer resolved the request;
/// `expired` = it was no longer open (another surface answered first, or it timed out).
public enum AnswerStatus: Equatable, Sendable {
  case ok, expired

  /// Parse a `request.answer` response; any status other than `ok` / `expired` throws.
  init(response: JSONValue) throws {
    switch response["status"]?.stringValue {
    case "ok": self = .ok
    case "expired": self = .expired
    default: throw GatewayError.server("Malformed request.answer result")
    }
  }
}

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
  /// The card this request presents.
  public var kind: PendingInteraction

  public init(id: String, kind: PendingInteraction) {
    self.id = id
    self.kind = kind
  }

  /// The wire method this request arrived as.
  public var method: PromptMethod {
    switch kind {
    case .approval: .approval
    case .clarify: .clarify
    case .secret(.sudo, _): .sudo
    case .secret(.secret, _): .secret
    }
  }

  /// Decode a server request the app renders. `nil` when the method is not rendered here
  /// (``PromptMethod``), or when a rendered method's params do not decode — see
  /// ``malformedSkip(for:params:)`` for what the caller answers then.
  ///
  /// An approval whose params decode but carry nothing to show (no command, description or
  /// danger pattern) does not decode: a content-less card would only invite a blind approve.
  /// Likewise a `secret` naming neither a `prompt` nor an `env_var` (a blind field); a `sudo`
  /// may be empty (v2026.9.14 sends no `command`). A clarify takes the v7 shapes only
  /// (``ClarifyRequest/init(serverRequestParams:)``).
  public init?(id: String, method: String, params: JSONValue) {
    guard let method = PromptMethod(rawValue: method) else { return nil }
    switch method {
    case .approval:
      guard let request = params.decoded(ApprovalRequest.self), request.hasContent else { return nil }
      self.init(id: id, kind: .approval(request))
    case .clarify:
      guard let request = ClarifyRequest(serverRequestParams: params) else { return nil }
      self.init(id: id, kind: .clarify(request))
    case .sudo, .secret:
      guard var prompt = params.decoded(SecretPrompt.self) else { return nil }
      let kind: SecretKind = method == .sudo ? .sudo : .secret
      if kind == .secret, !prompt.namesASecret { return nil }
      // The srq id identifies a v7 prompt; a stray legacy `request_id` is meaningless here.
      prompt.requestID = nil
      self.init(id: id, kind: .secret(kind, prompt))
    }
  }

  /// The `request.answer` result that skips a rendered method whose params are not a JSON
  /// object at all (`null`, missing, an array, a scalar) — a request no client can render
  /// (``PromptMethod/skipResult``).
  ///
  /// `nil` for an object that merely fails the phone's decode: that may be a newer wire shape
  /// a desktop sharing the session renders, so the phone stays silent (and banners) rather
  /// than deny or cancel it for everyone. `nil` too for every method the app does not render
  /// — those get nothing, or the window-owned 4404 decline (see `windowOwnedMethods`).
  public static func malformedSkip(for method: String, params: JSONValue) -> JSONValue? {
    if case .object = params { return nil }
    return PromptMethod(rawValue: method)?.skipResult
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
