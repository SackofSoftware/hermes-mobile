import ComposableArchitecture
import HermesKit
import SnapshotTesting
import SwiftUI
import XCTest

@testable import HermesMobile

final class SessionSnapshotTests: SnapshotTestCase {
  // MARK: SessionRowView

  func testSessionRow() {
    let view = SessionRowView(
      session: Session(
        id: "20260610_120231_afcca6",
        title: "Refactor the streaming parser",
        updatedAt: Date(timeIntervalSince1970: 1_749_556_800),
        preview: "Can you help me refactor the WebSocket JSON-RPC parser?"
      ),
      now: now
    )
    .padding()
    .frame(width: device.size?.width ?? 390)
    assertSnapshot(of: view, as: componentImage())
  }

  func testSessionRow_active() {
    // A session the agent is currently working — renders the brand-tinted glow.
    let view = SessionRowView(
      session: Session(
        id: "20260610_120231_afcca6",
        title: "Refactor the streaming parser",
        updatedAt: Date(timeIntervalSince1970: 1_749_599_700),
        isActive: true
      ),
      now: now,
      isActive: true
    )
    .padding()
    .frame(width: device.size?.width ?? 390)
    assertSnapshot(of: view, as: componentImage())
  }

  func testSessionRow_searchResult() {
    // A search result: no title, `id` is a meaningless stored id, so the snippet is
    // promoted to the headline instead of showing the raw id.
    let view = SessionRowView(
      session: Session(
        id: "20260610_120231_afcca6",
        title: nil,
        updatedAt: Date(timeIntervalSince1970: 1_749_556_800),
        preview: "Can you help me refactor the WebSocket JSON-RPC parser?"
      ),
      now: now,
      showsPreview: true
    )
    .padding()
    .frame(width: device.size?.width ?? 390)
    assertSnapshot(of: view, as: componentImage())
  }

  // MARK: SessionListView

  func testSessionList() {
    let now = self.now
    let mobile = "/Users/me/dev/hermes-mobile"
    // 6 sessions in one workspace (triggers "Show more"), 1 in another.
    var sessions: [Session] = (0..<6).map { i in
      Session(id: "m\(i)",
              title: ["Refactor the streaming parser", "Plan the iOS MVP", "UX polish pass",
                      "Model picker", "Workspace grouping", "Unread badges"][i],
              updatedAt: Date(timeIntervalSince1970: 1_749_556_800 - Double(i) * 86_400),
              cwd: mobile,
              startedAt: Date(timeIntervalSince1970: 1_749_556_800 - Double(i) * 86_400),
              messageCount: 10)
    }
    sessions.append(
      Session(id: "a1", title: nil,
              updatedAt: Date(timeIntervalSince1970: 1_749_300_000),
              cwd: "/Users/me/dev/hermes-agent",
              startedAt: Date(timeIntervalSince1970: 1_749_300_000), messageCount: 4)
    )
    // m0 has new activity since last seen (10 > 7) → unread; the rest are read.
    var seen = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.messageCount ?? 0) })
    seen["m0"] = 7

    let view = NavigationStack {
      SessionListView(
        store: Store(
          initialState: SessionListFeature.State(
            connection: ServerConnection(baseURL: URL(string: "http://mac.tailnet:9119")!, token: "t"),
            sessions: IdentifiedArray(uniqueElements: sessions),
            now: now,
            seenCounts: seen,
            expandedGroups: [mobile]
          )
        ) {
          SessionListFeature()
        } withDependencies: {
          $0.hermesREST.sessions = { _, _, _, _ in sessions }
          $0.continuousClock = ImmediateClock()
          $0.date = .constant(now)
        }
      )
    }
    assertSnapshot(of: view, as: deviceImage())
  }

  func testSessionList_pinnedSection() {
    let now = self.now
    let mobile = "/Users/me/dev/hermes-mobile"
    let sessions: [Session] = (0..<4).map { i in
      Session(id: "m\(i)",
              title: ["Refactor the streaming parser", "Plan the iOS MVP",
                      "UX polish pass", "Workspace grouping"][i],
              updatedAt: Date(timeIntervalSince1970: 1_749_556_800 - Double(i) * 86_400),
              cwd: mobile,
              startedAt: Date(timeIntervalSince1970: 1_749_556_800 - Double(i) * 86_400),
              messageCount: 10)
    }
    let seen = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.messageCount ?? 0) })

    let view = NavigationStack {
      SessionListView(
        store: Store(
          initialState: SessionListFeature.State(
            connection: ServerConnection(baseURL: URL(string: "http://mac.tailnet:9119")!, token: "t"),
            sessions: IdentifiedArray(uniqueElements: sessions),
            now: now,
            seenCounts: seen,
            pinnedIDs: ["m1"] // "Plan the iOS MVP" floats to the top Pinned section
          )
        ) {
          SessionListFeature()
        } withDependencies: {
          $0.hermesREST.sessions = { _, _, _, _ in sessions }
          $0.continuousClock = ImmediateClock()
          $0.date = .constant(now)
        }
      )
    }
    assertSnapshot(of: view, as: deviceImage())
  }

  func testSessionList_chronological() {
    let now = self.now
    // Two workspaces, but chronological mode shows one flat recency-ordered list.
    let sessions: [Session] = (0..<5).map { i in
      Session(id: "m\(i)",
              title: ["Refactor the streaming parser", "Plan the iOS MVP", "UX polish pass",
                      "Model picker", "Workspace grouping"][i],
              updatedAt: Date(timeIntervalSince1970: 1_749_556_800 - Double(i) * 86_400),
              cwd: i.isMultiple(of: 2) ? "/Users/me/dev/hermes-mobile" : "/Users/me/dev/hermes-agent",
              startedAt: Date(timeIntervalSince1970: 1_749_556_800 - Double(i) * 86_400),
              messageCount: 10)
    }
    let seen = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.messageCount ?? 0) })

    let view = NavigationStack {
      SessionListView(
        store: Store(
          initialState: SessionListFeature.State(
            connection: ServerConnection(baseURL: URL(string: "http://mac.tailnet:9119")!, token: "t"),
            sessions: IdentifiedArray(uniqueElements: sessions),
            now: now,
            seenCounts: seen,
            groupingMode: .chronological
          )
        ) {
          SessionListFeature()
        } withDependencies: {
          $0.hermesREST.sessions = { _, _, _, _ in sessions }
          $0.continuousClock = ImmediateClock()
          $0.date = .constant(now)
        }
      )
    }
    assertSnapshot(of: view, as: deviceImage())
  }

  // MARK: ArchivedSessionsView

  func testArchivedSessions() {
    let now = self.now
    let sessions: [Session] = [
      Session(id: "x0", title: "Old experiment",
              updatedAt: Date(timeIntervalSince1970: 1_749_300_000),
              cwd: "/Users/me/dev/hermes-mobile", messageCount: 6),
      Session(id: "x1", title: "Scratch session",
              updatedAt: Date(timeIntervalSince1970: 1_749_200_000),
              cwd: "/Users/me/dev/hermes-agent", messageCount: 3),
    ]
    let view = NavigationStack {
      ArchivedSessionsView(
        store: Store(
          initialState: ArchivedSessionsFeature.State(
            connection: ServerConnection(baseURL: URL(string: "http://mac.tailnet:9119")!, token: "t"),
            sessions: IdentifiedArray(uniqueElements: sessions),
            now: now
          )
        ) {
          ArchivedSessionsFeature()
        } withDependencies: {
          $0.hermesREST.archivedSessions = { _, _, _ in sessions }
          $0.date = .constant(now)
        }
      )
    }
    assertSnapshot(of: view, as: deviceImage())
  }

  func testArchivedSessions_empty() {
    let now = self.now
    let view = NavigationStack {
      ArchivedSessionsView(
        store: Store(
          initialState: ArchivedSessionsFeature.State(
            connection: ServerConnection(baseURL: URL(string: "http://mac.tailnet:9119")!, token: "t"),
            now: now
          )
        ) {
          ArchivedSessionsFeature()
        } withDependencies: {
          $0.hermesREST.archivedSessions = { _, _, _ in [] }
          $0.date = .constant(now)
        }
      )
    }
    assertSnapshot(of: view, as: deviceImage())
  }
}
