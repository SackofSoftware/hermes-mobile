import Foundation
import Testing

@testable import HermesKit

struct SessionGroupTests {
  private func session(_ id: String, cwd: String?, startedAt: Double?) -> Session {
    Session(id: id, cwd: cwd, startedAt: startedAt.map { Date(timeIntervalSince1970: $0) })
  }

  @Test func groupsByWorkspaceWithBasenameLabels() {
    let groups = SessionGroup.grouped([
      session("a", cwd: "/Users/me/dev/hermes-mobile", startedAt: 3),
      session("b", cwd: "/Users/me/dev/hermes-agent", startedAt: 2),
      session("c", cwd: "/Users/me/dev/hermes-mobile", startedAt: 1),
    ])

    #expect(groups.map(\.label) == ["hermes-mobile", "hermes-agent"])
    #expect(groups[0].sessions.map(\.id) == ["a", "c"]) // same workspace, grouped together
    #expect(groups[1].sessions.map(\.id) == ["b"])
  }

  @Test func groupOrderFollowsFirstSeenRecencyOrder() {
    // Input is recency-sorted; the active project must float to the top group.
    let groups = SessionGroup.grouped([
      session("a", cwd: "/work/beta", startedAt: 10),
      session("b", cwd: "/work/alpha", startedAt: 9),
      session("c", cwd: "/work/beta", startedAt: 8),
    ])
    #expect(groups.map(\.id) == ["/work/beta", "/work/alpha"])
  }

  @Test func rowsWithinGroupSortByStartedAtDescending() {
    let groups = SessionGroup.grouped([
      session("old", cwd: "/w", startedAt: 1),
      session("new", cwd: "/w", startedAt: 5),
      session("mid", cwd: "/w", startedAt: 3),
    ])
    #expect(groups.count == 1)
    #expect(groups[0].sessions.map(\.id) == ["new", "mid", "old"])
  }

  @Test func emptyOrNilCwdGoesToNoWorkspaceBucket() {
    let groups = SessionGroup.grouped([
      session("a", cwd: nil, startedAt: 2),
      session("b", cwd: "   ", startedAt: 1),
      session("c", cwd: "/w", startedAt: 3),
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
