import Foundation

/// A workspace group in the session list — sessions sharing a `cwd`. Mirrors the Hermes
/// desktop sidebar (`workspaceGroupsFor`): group by trimmed `cwd` (empty → "No
/// workspace"), label by the path's basename, keep groups in first-seen (recency) order,
/// and sort rows within a group by `updatedAt` (last-active) descending so the display
/// order matches the shown timestamp.
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
  /// re-sorted by `updatedAt` (last-active) desc (nil last).
  /// - Parameter assignments: session id → workspace NAME, from the agent's
  ///   `hermes-workspaces` plugin (auto-classified by topic). When a session has an
  ///   assignment it wins; otherwise we fall back to the old `cwd`-derived grouping, so
  ///   an agent without the plugin — or a chat not yet classified — behaves exactly as
  ///   before rather than collapsing into one undifferentiated pile.
  public static func grouped(
    _ sessions: [Session],
    assignments: [String: String] = [:]
  ) -> [SessionGroup] {
    var order: [String] = []
    var byID: [String: SessionGroup] = [:]

    for session in sessions {
      let assigned = assignments[session.id]?.trimmingCharacters(in: .whitespaces)
      let path = session.cwd?.trimmingCharacters(in: .whitespaces) ?? ""
      let id: String
      let groupLabel: String
      if let assigned, !assigned.isEmpty {
        // Namespaced so a workspace NAME can never collide with a cwd PATH used as an id.
        id = "ws:" + assigned
        groupLabel = assigned
      } else {
        id = path.isEmpty ? noWorkspaceID : path
        groupLabel = label(forPath: path)
      }
      if byID[id] == nil {
        order.append(id)
        byID[id] = SessionGroup(id: id, label: groupLabel, sessions: [])
      }
      byID[id]?.sessions.append(session)
    }

    return order.map { id in
      var group = byID[id]!
      group.sessions.sort { lhs, rhs in
        (lhs.updatedAt ?? .distantPast) > (rhs.updatedAt ?? .distantPast)
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
