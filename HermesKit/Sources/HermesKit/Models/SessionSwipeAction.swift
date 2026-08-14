import Foundation

/// Which destructive action the session list's trailing swipe offers (and full-swipe
/// triggers). A device-local UI preference (persisted in `PreferencesClient`); the
/// long-press context menu always shows both actions regardless of this choice.
/// `.delete` is only effective while the agent supports `DELETE /api/sessions/{id}` —
/// the list clamps back to `.archive` when the capability flag is off.
public enum SessionSwipeAction: String, Codable, Sendable, CaseIterable, Equatable {
  case archive
  case delete

  /// Default when nothing is persisted yet.
  public static let `default`: SessionSwipeAction = .archive
}
