import Foundation

/// A workspace group in the session list — sessions sharing a `cwd`. Mirrors the Hermes
/// desktop sidebar (`workspaceGroupsFor`): group by trimmed `cwd` (empty → "No
/// workspace"), label by the path's basename, keep groups in first-seen (recency) order,
/// and sort rows within a group by `startedAt` descending so they don't reshuffle as
/// messages land.
public struct SessionGroup: Equatable, Sendable, Identifiable {
  public let id: String      // the cwd, or "__no_workspace__"
  public let label: String   // basename of cwd, or "No workspace"
  public var sessions: [Session]

  public init(id: String, label: String, sessions: [Session]) {
    self.id = id
    self.label = label
    self.sessions = sessions
  }

  static let noWorkspaceID = "__no_workspace__"
  static let noWorkspaceLabel = "No workspace"

  /// Group `sessions` by workspace. Input order is preserved as group order (the list is
  /// already recency-sorted, so an active project floats up); rows within each group are
  /// re-sorted by `startedAt` desc (nil last).
  public static func grouped(_ sessions: [Session]) -> [SessionGroup] {
    var order: [String] = []
    var byID: [String: SessionGroup] = [:]

    for session in sessions {
      let path = session.cwd?.trimmingCharacters(in: .whitespaces) ?? ""
      let id = path.isEmpty ? noWorkspaceID : path
      if byID[id] == nil {
        order.append(id)
        byID[id] = SessionGroup(id: id, label: label(forPath: path), sessions: [])
      }
      byID[id]?.sessions.append(session)
    }

    return order.map { id in
      var group = byID[id]!
      group.sessions.sort { lhs, rhs in
        (lhs.startedAt ?? .distantPast) > (rhs.startedAt ?? .distantPast)
      }
      return group
    }
  }

  /// Folder basename of a workspace path, or the "No workspace" label for empty paths.
  static func label(forPath path: String) -> String {
    guard !path.isEmpty else { return noWorkspaceLabel }
    let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
    let base = trimmed.split(separator: "/").last.map(String.init)
    // Mirror desktop `baseName(path) || path`: root ("/") has no basename → use the path.
    return base?.nonEmpty ?? path.nonEmpty ?? noWorkspaceLabel
  }
}

private extension String {
  var nonEmpty: String? { isEmpty ? nil : self }
}
