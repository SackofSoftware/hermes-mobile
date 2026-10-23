import Foundation

/// One labelled date section of the session list: a run of `SessionBranchEntry` rows that
/// share a `SessionDateBucket`. Display-only — built per render from the one fetched array.
public struct SessionDateSection: Equatable, Sendable, Identifiable {
  /// The bucket key (`SessionDateBucket.key`), or `olderID` for undated rows.
  public let id: String
  public let label: String
  public var entries: [SessionBranchEntry]

  /// Identity of the trailing section that collects rows with no `updatedAt`.
  public static let olderID = "older"
  public static let olderLabel = "Older"

  public init(id: String, label: String, entries: [SessionBranchEntry]) {
    self.id = id
    self.label = label
    self.entries = entries
  }
}

/// Splits recency-ordered, branch-flattened entries into date sections. Pure; preserves
/// input order and never re-sorts.
///
/// - A section opens only on a TOP-LEVEL entry (`branchStem == nil`) whose bucket key
///   differs from the current section's; branch children append to the current section
///   unconditionally, so a parent + branches cluster never splits across a header.
/// - A top-level entry buckets on its CLUSTER's freshest `updatedAt` (itself plus the
///   branch children that follow it) — the same key `flattenSessionsWithBranches` sorts
///   clusters by, so a stale parent lifted by a fresh branch lands in the fresh section
///   instead of opening an out-of-order header above it.
/// - A cluster with no `updatedAt` at all goes to the "Older" section (such rows already
///   sort last, so it trails).
/// - A key that already has a section (only possible on a non-monotonic input) never
///   opens a second one — the rows append to the current section, mirroring the
///   desktop's `emitted` guard, so section ids stay unique.
/// - A leading branch child with no current section (cannot happen after
///   `flattenSessionsWithBranches`, but the function stays total) opens a section from
///   its own date. No empty section is ever produced.
public func groupEntriesByDate(
  _ entries: [SessionBranchEntry],
  now: Date,
  calendar: Calendar
) -> [SessionDateSection] {
  var sections: [SessionDateSection] = []
  var emitted: Set<String> = []

  func open(_ id: String, label: @autoclosure () -> String, with entry: SessionBranchEntry) {
    emitted.insert(id)
    sections.append(SessionDateSection(id: id, label: label(), entries: [entry]))
  }

  for (index, entry) in entries.enumerated() {
    if entry.branchStem != nil, !sections.isEmpty {
      sections[sections.count - 1].entries.append(entry)
      continue
    }

    // Cluster recency: this entry plus the branch children directly beneath it.
    var recency = entry.session.updatedAt
    if entry.branchStem == nil {
      var next = index + 1
      while next < entries.count, entries[next].branchStem != nil {
        if let date = entries[next].session.updatedAt {
          recency = max(recency ?? date, date)
        }
        next += 1
      }
    }

    let bucket = recency.map { SessionDateBucket.bucket(for: $0, now: now, calendar: calendar) }
    let key = bucket?.key ?? SessionDateSection.olderID

    if let current = sections.last, current.id == key || emitted.contains(key) {
      sections[sections.count - 1].entries.append(entry)
    } else {
      open(key, label: bucket?.label(calendar: calendar) ?? SessionDateSection.olderLabel, with: entry)
    }
  }

  return sections
}
