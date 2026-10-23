import Foundation
import Testing

@testable import HermesKit

struct SessionDateSectionTests {
  private let calendar = SessionDateBucketTests.calendar()
  private let now = SessionDateBucketTests.thuNoon // Thu 18 Jun 2026, noon

  private func day(_ month: Int, _ day: Int, _ hour: Int = 10, year: Int = 2026) -> Date {
    SessionDateBucketTests.date(year, month, day, hour)
  }

  private func entry(_ id: String, _ date: Date?, stem: String? = nil) -> SessionBranchEntry {
    SessionBranchEntry(session: Session(id: id, updatedAt: date), branchStem: stem)
  }

  private func group(_ entries: [SessionBranchEntry]) -> [SessionDateSection] {
    groupEntriesByDate(entries, now: now, calendar: calendar)
  }

  @Test func emptyInputYieldsNoSections() {
    #expect(group([]) == [])
  }

  @Test func singleBucketYieldsOneSection() {
    let sections = group([
      entry("a", day(6, 18, 11)),
      entry("b", day(6, 18, 9)),
    ])
    #expect(sections.map(\.id) == ["today"])
    #expect(sections[0].label == "Today")
    #expect(sections[0].entries.map(\.id) == ["a", "b"])
  }

  @Test func opensASectionPerBucketInOrderWithLabels() {
    let sections = group([
      entry("today", day(6, 18)),
      entry("yesterday", day(6, 17)),
      entry("lastWeek1", day(6, 12)),
      entry("lastWeek2", day(6, 9)),
      entry("may", day(5, 2)),
      entry("prior", day(12, 3, year: 2025)),
    ])
    #expect(sections.map(\.id) == ["today", "yesterday", "last-week", "m-2026-5", "my-2025-12"])
    #expect(sections.map(\.label) == ["Today", "Yesterday", "Last week", "May", "December 2025"])
    #expect(sections[2].entries.map(\.id) == ["lastWeek1", "lastWeek2"])
  }

  @Test func branchChildrenStayWithTheirParentAcrossABucketBoundary() {
    // Parent is today; its branches are older but must not split off under a new header.
    let sections = group([
      entry("parent", day(6, 18)),
      entry("child1", day(6, 17), stem: "├─ "),
      entry("child2", day(6, 2), stem: "└─ "),
      entry("next", day(6, 17)),
    ])
    #expect(sections.map(\.id) == ["today", "yesterday"])
    #expect(sections[0].entries.map(\.id) == ["parent", "child1", "child2"])
    #expect(sections[1].entries.map(\.id) == ["next"])
  }

  @Test func staleParentBucketsOnItsFreshestBranch() {
    // flattenSessionsWithBranches lifts a cluster by its freshest member, so a stale
    // parent with a fresh branch sorts first — it must land in the fresh section rather
    // than open an out-of-order "May" header above "Today".
    let sections = group([
      entry("parent", day(5, 2)),
      entry("child", day(6, 18, 11), stem: "└─ "),
      entry("other", day(6, 18, 9)),
    ])
    #expect(sections.map(\.id) == ["today"])
    #expect(sections[0].entries.map(\.id) == ["parent", "child", "other"])
  }

  @Test func undatedRowsGoToATrailingOlderSection() {
    let sections = group([
      entry("a", day(6, 18)),
      entry("b", nil),
      entry("c", nil),
    ])
    #expect(sections.map(\.id) == ["today", SessionDateSection.olderID])
    #expect(sections[1].label == "Older")
    #expect(sections[1].entries.map(\.id) == ["b", "c"])
  }

  @Test func undatedParentWithADatedBranchBucketsOnTheBranch() {
    let sections = group([
      entry("parent", nil),
      entry("child", day(6, 17), stem: "└─ "),
    ])
    #expect(sections.map(\.id) == ["yesterday"])
    #expect(sections[0].entries.map(\.id) == ["parent", "child"])
  }

  @Test func preservesInputOrderAndNeverReSorts() {
    // Out-of-recency order inside one bucket stays exactly as given.
    let sections = group([
      entry("older", day(6, 18, 5)),
      entry("newer", day(6, 18, 11)),
    ])
    #expect(sections.flatMap(\.entries).map(\.id) == ["older", "newer"])
  }

  @Test func nonMonotonicInputNeverDuplicatesASection() {
    // A key that already has a section appends to the current one: ids stay unique,
    // nothing is moved.
    let sections = group([
      entry("t1", day(6, 18)),
      entry("y", day(6, 17)),
      entry("t2", day(6, 18)),
    ])
    #expect(sections.map(\.id) == ["today", "yesterday"])
    #expect(sections[1].entries.map(\.id) == ["y", "t2"])
    #expect(sections.flatMap(\.entries).map(\.id) == ["t1", "y", "t2"])
  }

  @Test func producesNoEmptySections() {
    let sections = group([
      entry("a", day(6, 18)),
      entry("b", day(5, 2)),
      entry("c", nil),
    ])
    #expect(sections.allSatisfy { !$0.entries.isEmpty })
    #expect(sections.flatMap(\.entries).count == 3)
  }

  @Test func leadingBranchChildStillOpensASection() {
    let sections = group([
      entry("orphanChild", day(6, 17), stem: "└─ "),
      entry("a", day(6, 17)),
    ])
    #expect(sections.map(\.id) == ["yesterday"])
    #expect(sections[0].entries.map(\.id) == ["orphanChild", "a"])
  }

  @Test func sectionsFollowNow() {
    let entries = [entry("a", day(6, 18, 22))]
    #expect(group(entries).map(\.id) == ["today"])
    let nextMorning = SessionDateBucketTests.date(2026, 6, 19, 9)
    #expect(groupEntriesByDate(entries, now: nextMorning, calendar: calendar).map(\.id) == ["yesterday"])
  }
}
