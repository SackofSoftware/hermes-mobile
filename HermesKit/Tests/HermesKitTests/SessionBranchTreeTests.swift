import Foundation
import Testing

@testable import HermesKit

struct SessionBranchTreeTests {
  private func session(
    _ id: String, parent: String? = nil, updatedAt: Double? = nil, startedAt: Double? = nil,
    lineageRoot: String? = nil
  ) -> Session {
    Session(
      id: id,
      updatedAt: updatedAt.map { Date(timeIntervalSince1970: $0) },
      startedAt: startedAt.map { Date(timeIntervalSince1970: $0) },
      parentSessionID: parent,
      lineageRootID: lineageRoot
    )
  }

  // MARK: - Passthrough

  @Test func emptyInputStaysEmpty() {
    #expect(flattenSessionsWithBranches([]) == [])
  }

  @Test func singleSessionPassesThroughWithoutStem() {
    let entries = flattenSessionsWithBranches([session("only", updatedAt: 1)])
    #expect(entries.map(\.id) == ["only"])
    #expect(entries[0].branchStem == nil)
  }

  @Test func flatListWithoutParentsKeepsInputOrder() {
    // No parent links → no regrouping; the caller's (recency-sorted) order is preserved.
    let entries = flattenSessionsWithBranches([
      session("a", updatedAt: 3),
      session("b", updatedAt: 2),
      session("c", updatedAt: 1),
    ])
    #expect(entries.map(\.id) == ["a", "b", "c"])
    #expect(entries.allSatisfy { $0.branchStem == nil })
  }

  // MARK: - Nesting + stems

  @Test func branchNestsUnderParentWithLastSiblingStem() {
    let entries = flattenSessionsWithBranches([
      session("parent", updatedAt: 10),
      session("branch", parent: "parent", updatedAt: 5),
      session("other", updatedAt: 8),
    ])
    #expect(entries.map(\.id) == ["parent", "branch", "other"])
    #expect(entries.map(\.branchStem) == [nil, "└─ ", nil])
  }

  @Test func middleSiblingGetsTeeStemAndLastGetsElbow() {
    // Siblings sort by recency descending: b2 (newer) first with "├─ ", b1 last with "└─ ".
    let entries = flattenSessionsWithBranches([
      session("parent", updatedAt: 10),
      session("b1", parent: "parent", updatedAt: 4),
      session("b2", parent: "parent", updatedAt: 6),
    ])
    #expect(entries.map(\.id) == ["parent", "b2", "b1"])
    #expect(entries.map(\.branchStem) == [nil, "├─ ", "└─ "])
  }

  @Test func branchOfBranchNestsUnderItsOwnParent() {
    let entries = flattenSessionsWithBranches([
      session("root", updatedAt: 10),
      session("child", parent: "root", updatedAt: 8),
      session("grandchild", parent: "child", updatedAt: 6),
    ])
    #expect(entries.map(\.id) == ["root", "child", "grandchild"])
    #expect(entries.map(\.branchStem) == [nil, "└─ ", "└─ "])
  }

  @Test func nilUpdatedAtSortsLastMatchingTheLanes() {
    // Recency is `updatedAt ?? .distantPast` — the SAME rule the pinned/workspace/
    // chronological lanes sort by, so nesting can't reorder flat rows those lanes already
    // placed. (`startedAt` is deliberately NOT a fallback here: the REST decode already
    // folds `started_at` into `updatedAt` when `last_active` is absent, and a divergent
    // fallback would float nil-`updatedAt` rows the lanes sank to the bottom.)
    let entries = flattenSessionsWithBranches([
      session("parent", updatedAt: 10),
      session("b1", parent: "parent", startedAt: 7), // no updatedAt → last among siblings
      session("b2", parent: "parent", updatedAt: 5),
    ])
    #expect(entries.map(\.id) == ["parent", "b2", "b1"])
    #expect(entries.map(\.branchStem) == [nil, "├─ ", "└─ "])
  }

  // MARK: - Group recency lift

  @Test func freshBranchLiftsWholeParentGroup() {
    // "stale" parent's branch is the newest thing in the list — the whole cluster
    // floats above "fresh" instead of the parent sinking to its own timestamp.
    let entries = flattenSessionsWithBranches([
      session("fresh", updatedAt: 10),
      session("stale", updatedAt: 2),
      session("branch", parent: "stale", updatedAt: 20),
    ])
    #expect(entries.map(\.id) == ["stale", "branch", "fresh"])
    #expect(entries.map(\.branchStem) == [nil, "└─ ", nil])
  }

  @Test func grandchildRecencyLiftsRootGroup() {
    let entries = flattenSessionsWithBranches([
      session("fresh", updatedAt: 10),
      session("root", updatedAt: 1),
      session("child", parent: "root", updatedAt: 2),
      session("grandchild", parent: "child", updatedAt: 30),
    ])
    #expect(entries.map(\.id) == ["root", "child", "grandchild", "fresh"])
  }

  @Test func equalGroupRecencyKeepsInputOrder() {
    let entries = flattenSessionsWithBranches([
      session("a", updatedAt: 5),
      session("b", updatedAt: 5),
      session("c", updatedAt: 5),
    ])
    #expect(entries.map(\.id) == ["a", "b", "c"])
  }

  // MARK: - Caller-owned top-level order

  @Test func unsortedTopLevelKeepsInputOrderButStillNests() {
    // Pin-order lanes: roots stay exactly where the input put them (no recency lift),
    // while a branch still nests recency-sorted under its (also-present) parent.
    let entries = flattenSessionsWithBranches(
      [
        session("older", updatedAt: 1),
        session("parent", updatedAt: 2),
        session("branch", parent: "parent", updatedAt: 30),
        session("newer", updatedAt: 10),
      ],
      sortTopLevelByRecency: false
    )
    #expect(entries.map(\.id) == ["older", "parent", "branch", "newer"])
    #expect(entries.map(\.branchStem) == [nil, nil, "└─ ", nil])
  }

  // MARK: - Compression-projected parents (lineage-root aliasing)

  @Test func branchNestsUnderCompressionProjectedParentViaLineageRoot() {
    // The parent auto-compressed: its list row's id rotated to the continuation tip
    // ("tip") while `_lineage_root_id` kept the original id the branch's
    // `parent_session_id` still points at. The alias keeps the branch nested.
    let entries = flattenSessionsWithBranches([
      session("tip", updatedAt: 10, lineageRoot: "root"),
      session("branch", parent: "root", updatedAt: 5),
    ])
    #expect(entries.map(\.id) == ["tip", "branch"])
    #expect(entries.map(\.branchStem) == [nil, "└─ "])
  }

  @Test func lineageAliasMatchingSelfDoesNotNest() {
    // Degenerate: a row whose lineage root is claimed as its own parent id still never
    // nests under itself.
    let entries = flattenSessionsWithBranches([
      session("tip", parent: "root", updatedAt: 10, lineageRoot: "root"),
      session("a", updatedAt: 5),
    ])
    #expect(entries.map(\.id) == ["tip", "a"])
    #expect(entries.allSatisfy { $0.branchStem == nil })
  }

  // MARK: - Orphans + safety

  @Test func orphanWithAbsentParentDeNestsToTopLevel() {
    // Parent archived / outside this slice → the branch renders as a normal row.
    let entries = flattenSessionsWithBranches([
      session("a", updatedAt: 10),
      session("orphan", parent: "gone", updatedAt: 5),
    ])
    #expect(entries.map(\.id) == ["a", "orphan"])
    #expect(entries.allSatisfy { $0.branchStem == nil })
  }

  @Test func selfParentIsIgnored() {
    let entries = flattenSessionsWithBranches([
      session("loop", parent: "loop", updatedAt: 10),
      session("a", updatedAt: 5),
    ])
    #expect(entries.map(\.id) == ["loop", "a"])
    #expect(entries.allSatisfy { $0.branchStem == nil })
  }

  @Test func parentCycleEmitsEveryoneViaTrailingSweep() {
    // a↔b cycle: both are "nested" so neither is a top-level root; the trailing sweep
    // must still emit both (flat) — nothing is ever dropped.
    let entries = flattenSessionsWithBranches([
      session("a", parent: "b", updatedAt: 10),
      session("b", parent: "a", updatedAt: 5),
    ])
    #expect(entries.map(\.id).sorted() == ["a", "b"])
    #expect(entries.count == 2)
  }

  @Test func childOfACycleFallsThroughTheSweepFlat() {
    // z's parent sits inside an a↔b cycle: no member of the cluster is a top-level root,
    // so the whole cluster (cycle members AND z) is emitted by the trailing sweep, flat —
    // z loses its stem but is never dropped.
    let entries = flattenSessionsWithBranches([
      session("solo", updatedAt: 20),
      session("a", parent: "b", updatedAt: 10),
      session("b", parent: "a", updatedAt: 5),
      session("z", parent: "a", updatedAt: 1),
    ])
    #expect(entries.map(\.id).sorted() == ["a", "b", "solo", "z"])
    #expect(entries.count == 4)
    #expect(entries.first?.id == "solo")
    #expect(entries.allSatisfy { $0.branchStem == nil })
  }

  @Test func whitespaceOnlyParentIDTreatedAsNoParent() {
    let entries = flattenSessionsWithBranches([
      session("a", updatedAt: 10),
      session("b", parent: "  ", updatedAt: 5),
    ])
    #expect(entries.map(\.id) == ["a", "b"])
    #expect(entries.allSatisfy { $0.branchStem == nil })
  }

  @Test func everyInputSessionAppearsExactlyOnce() {
    let input = [
      session("root", updatedAt: 9),
      session("c1", parent: "root", updatedAt: 8),
      session("c2", parent: "root", updatedAt: 7),
      session("gc", parent: "c1", updatedAt: 6),
      session("orphan", parent: "missing", updatedAt: 5),
      session("solo", updatedAt: 4),
      session("x", parent: "y", updatedAt: 3),
      session("y", parent: "x", updatedAt: 2),
    ]
    let entries = flattenSessionsWithBranches(input)
    #expect(entries.map(\.id).sorted() == input.map(\.id).sorted())
  }
}
