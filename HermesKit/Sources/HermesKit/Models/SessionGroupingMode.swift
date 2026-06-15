import Foundation

/// How the session list groups its rows. A device-local UI preference (persisted in
/// `PreferencesClient`), independent of the fetch order — both modes render the same
/// recency-sorted `sessions` array, just differently:
/// - `.workspace` groups rows by `cwd` (desktop-style), with the Pinned section on top.
/// - `.chronological` shows one flat, last-active-ordered list (no workspace headers).
public enum SessionGroupingMode: String, Sendable, CaseIterable, Equatable {
  case workspace
  case chronological

  /// Default when nothing is persisted yet.
  public static let `default`: SessionGroupingMode = .workspace
}
