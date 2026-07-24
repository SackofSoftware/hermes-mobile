import Foundation
import Testing

@testable import HermesKit

struct SessionBranchTreeTests {
  private func session(
    _ id: String, parent: String? = nil, updatedAt: Double? = nil, startedAt: Double? = nil
  ) -> Session {
    Session(
      id: id,
      updatedAt: updatedAt.map { Date(timeIntervalSince1970: $0) },
      startedAt: startedAt.map { Date(timeIntervalSince1970: $0) },
      parentSessionID: parent
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

  @Test func recencyFallsBackToStartedAt() {
    // b1 has no updatedAt but a fresher startedAt than b2's updatedAt → b1 sorts first.
    let entries = flattenSessionsWithBranches([
      session("parent", updatedAt: 10),
      session("b1", parent: "parent", startedAt: 7),
      session("b2", parent: "parent", updatedAt: 5),
    ])
    #expect(entries.map(\.id) == ["parent", "b1", "b2"])
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
