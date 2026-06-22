import Foundation

/// The runtime fields `applyRuntimeInfo` writes into — the minimal subset of
/// `ChatFeature.State` (`model`, `reasoningEffort`, `usage`) driven by a `SessionInfo`
/// response. Extracted into a tiny value type so the merge rule is pure and exhaustively
/// unit-testable; the reducer applies into a `RuntimeInfoTarget` view over its state.
public struct RuntimeInfoTarget: Equatable, Sendable {
  public var model: String?
  public var reasoningEffort: String?
  public var usage: Usage?

  public init(model: String? = nil, reasoningEffort: String? = nil, usage: Usage? = nil) {
    self.model = model
    self.reasoningEffort = reasoningEffort
    self.usage = usage
  }
}

/// Apply a (possibly partial) `SessionInfo` onto a runtime target, mirroring the desktop
/// `applyRuntimeInfo(info)`: a field present in `info` overwrites; a field absent (`nil`)
/// **preserves** the existing value. This is what keeps a partial `session.info` push
/// (e.g. usage-only) from blanking the model or zeroing the context pill.
///
/// String fields are guarded on `.nonEmpty` — an empty-string `model`/`reasoningEffort`
/// from the server **preserves** the existing value rather than blanking it, matching the
/// live `.sessionInfo` fold (`info.model?.nonEmpty`) so a `""` push can't re-introduce the
/// blank-model regression.
///
/// Pure: no I/O, no clock — operates only on its arguments.
public func applyRuntimeInfo(_ info: SessionInfo, into target: inout RuntimeInfoTarget) {
  if let model = info.model?.nonEmpty { target.model = model }
  if let reasoningEffort = info.reasoningEffort?.nonEmpty { target.reasoningEffort = reasoningEffort }
  if let usage = info.usage { target.usage = usage }
}
