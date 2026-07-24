import Foundation

/// A session-list row with its optional branch elbow stem — the display-only nesting
/// unit produced by `flattenSessionsWithBranches`. Row identity stays the session id
/// (nesting never changes IDs; pin/archive/rename keep working on branch rows).
public struct SessionBranchEntry: Equatable, Sendable, Identifiable {
  public var session: Session
  /// `"└─ "` (last sibling) / `"├─ "` (middle sibling) when nested under a parent in
  /// the same rendered slice; `nil` for top-level rows (including de-nested orphans).
  public var branchStem: String?

  public var id: String { session.id }

  public init(session: Session, branchStem: String? = nil) {
    self.session = session
    self.branchStem = branchStem
  }
}

/// Flat list with branch sessions nested visually under their parent — a pure port of
/// the desktop's `session-branch-tree.ts` over the mobile `Session` model:
///
/// - children grouped by `parentSessionID` **within the given slice only** (an orphan
///   whose parent is absent — archived, filtered, another lane — de-nests to a normal
///   top-level row; nothing is ever hidden)
/// - siblings sorted by recency (last-active, else started-at), newest first
/// - a parent group sorts by its **freshest member**, so activity on any branch lifts
///   the whole cluster instead of stranding the parent at its own stale timestamp
///   (skipped when `sortTopLevelByRecency` is `false` — lanes with a caller-owned order,
///   e.g. the Pinned lane's pin order, keep top-level rows where the input put them;
///   children still nest recency-sorted underneath)
/// - depth-first emit so a branch-of-a-branch still renders under its own parent
/// - cycle-safe (self-parents ignored; a `seen` set guards pathological parent cycles)
///   with a trailing sweep so no input session is ever dropped
public func flattenSessionsWithBranches(
  _ sessions: [Session],
  sortTopLevelByRecency: Bool = true
) -> [SessionBranchEntry] {
  guard sessions.count >= 2 else {
    return sessions.map { SessionBranchEntry(session: $0) }
  }

  var byID: [String: Session] = [:]
  for session in sessions {
    byID[session.id] = session
  }

  func recency(_ session: Session) -> Date {
    session.updatedAt ?? session.startedAt ?? .distantPast
  }

  var childrenByParent: [String: [Session]] = [:]
  var nestedIDs: Set<String> = []

  for session in sessions {
    guard
      let parentID = session.parentSessionID?.trimmedNonEmpty,
      let parent = byID[parentID],
      parent.id != session.id
    else { continue }
    nestedIDs.insert(session.id)
    childrenByParent[parent.id, default: []].append(session)
  }

  // Recency-descending sibling sort, stable on ties (keeps input order).
  for key in childrenByParent.keys {
    childrenByParent[key] = childrenByParent[key]!
      .enumerated()
      .sorted { a, b in
        let ra = recency(a.element)
        let rb = recency(b.element)
        return ra != rb ? ra > rb : a.offset < b.offset
      }
      .map(\.element)
  }

  // A group sorts by its freshest member. Memoized — each subtree folded at most once;
  // the pre-seed of the node's own recency doubles as a cycle guard.
  var groupRecencyMemo: [String: Date] = [:]

  func groupRecency(_ session: Session) -> Date {
    if let cached = groupRecencyMemo[session.id] {
      return cached
    }
    groupRecencyMemo[session.id] = recency(session) // cycle guard
    let max = (childrenByParent[session.id] ?? []).reduce(recency(session)) { acc, child in
      Swift.max(acc, groupRecency(child))
    }
    groupRecencyMemo[session.id] = max
    return max
  }

  var out: [SessionBranchEntry] = []
  var seen: Set<String> = []

  func emit(_ session: Session, branchStem: String? = nil) {
    guard !seen.contains(session.id) else { return }
    seen.insert(session.id)
    out.append(SessionBranchEntry(session: session, branchStem: branchStem))
    guard let children = childrenByParent[session.id] else { return }
    for (index, child) in children.enumerated() {
      emit(child, branchStem: index == children.count - 1 ? "└─ " : "├─ ")
    }
  }

  let roots = sessions.enumerated().filter { !nestedIDs.contains($0.element.id) }
  let orderedRoots = sortTopLevelByRecency
    ? roots.sorted { a, b in
        let ra = groupRecency(a.element)
        let rb = groupRecency(b.element)
        return ra != rb ? ra > rb : a.offset < b.offset
      }
    : roots
  orderedRoots.forEach { emit($0.element) }

  // Trailing sweep: anything the walk missed (e.g. a parent cycle where every member is
  // "nested") still renders, flat.
  for session in sessions where !seen.contains(session.id) {
    out.append(SessionBranchEntry(session: session))
  }

  return out
}
