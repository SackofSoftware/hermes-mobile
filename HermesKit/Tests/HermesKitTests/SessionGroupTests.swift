import Foundation
import Testing

@testable import HermesKit

struct SessionGroupTests {
  private func session(
    _ id: String, cwd: String?, startedAt: Double? = nil, updatedAt: Double? = nil
  ) -> Session {
    Session(
      id: id,
      updatedAt: updatedAt.map { Date(timeIntervalSince1970: $0) },
      cwd: cwd,
      startedAt: startedAt.map { Date(timeIntervalSince1970: $0) }
    )
  }

  @Test func groupsByWorkspaceWithBasenameLabels() {
    let groups = SessionGroup.grouped([
      session("a", cwd: "/Users/me/dev/hermes-mobile", updatedAt: 3),
      session("b", cwd: "/Users/me/dev/hermes-agent", updatedAt: 2),
      session("c", cwd: "/Users/me/dev/hermes-mobile", updatedAt: 1),
    ])

    #expect(groups.map(\.label) == ["hermes-mobile", "hermes-agent"])
    #expect(groups[0].sessions.map(\.id) == ["a", "c"]) // same workspace, grouped together
    #expect(groups[1].sessions.map(\.id) == ["b"])
  }

  @Test func groupOrderFollowsFirstSeenRecencyOrder() {
    // Input is recency-sorted; the active project must float to the top group.
    let groups = SessionGroup.grouped([
      session("a", cwd: "/work/beta", updatedAt: 10),
      session("b", cwd: "/work/alpha", updatedAt: 9),
      session("c", cwd: "/work/beta", updatedAt: 8),
    ])
    #expect(groups.map(\.id) == ["/work/beta", "/work/alpha"])
  }

  @Test func rowsWithinGroupSortByLastActiveDescending() {
    // Sort follows `updatedAt` (last-active), not `startedAt` (creation): a
    // recently-active-but-older-created session must float above a newer-created one.
    let groups = SessionGroup.grouped([
      session("old", cwd: "/w", startedAt: 5, updatedAt: 1),
      session("new", cwd: "/w", startedAt: 1, updatedAt: 5),
      session("mid", cwd: "/w", startedAt: 3, updatedAt: 3),
    ])
    #expect(groups.count == 1)
    #expect(groups[0].sessions.map(\.id) == ["new", "mid", "old"])
  }

  @Test func rowsWithNilLastActiveSortLast() {
    let groups = SessionGroup.grouped([
      session("noUpdate", cwd: "/w", updatedAt: nil),
      session("recent", cwd: "/w", updatedAt: 5),
      session("older", cwd: "/w", updatedAt: 2),
    ])
    #expect(groups.count == 1)
    #expect(groups[0].sessions.map(\.id) == ["recent", "older", "noUpdate"])
  }

  @Test func emptyOrNilCwdGoesToNoWorkspaceBucket() {
    let groups = SessionGroup.grouped([
      session("a", cwd: nil, updatedAt: 2),
      session("b", cwd: "   ", updatedAt: 1),
      session("c", cwd: "/w", updatedAt: 3),
    ])
    let noWorkspace = groups.first { $0.id == SessionGroup.noWorkspaceID }
    #expect(noWorkspace?.label == "No workspace")
    #expect(noWorkspace?.sessions.map(\.id) == ["a", "b"])
  }

  @Test func trailingSlashAndRootPathLabels() {
    #expect(SessionGroup.label(forPath: "/Users/me/dev/proj/") == "proj")
    #expect(SessionGroup.label(forPath: "/") == "/")
    #expect(SessionGroup.label(forPath: "") == "No workspace")
  }
}
