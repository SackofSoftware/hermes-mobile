import ComposableArchitecture
import HermesKit
import SnapshotTesting
import SwiftUI
import XCTest

@testable import HermesMobile

/// Renders the feature views to PNGs (under `__Snapshots__/`). On first run there's
/// no baseline, so each assertion records the image and reports a failure — that's
/// expected; the PNGs are the deliverable.
final class PreviewSnapshotTests: XCTestCase {
  private let device = ViewImageConfig.iPhone13Pro
  /// Fixed reference "now" so relative timestamps are deterministic.
  private let now = Date(timeIntervalSince1970: 1_749_600_000)

  // MARK: ConnectionView (Task 6)

  func testConnectionView_idle() {
    let view = ConnectionView(
      store: Store(initialState: ConnectionFeature.State()) { ConnectionFeature() }
    )
    assertSnapshot(of: view, as: .image(layout: .device(config: device)))
  }

  func testConnectionView_reachable() {
    let view = ConnectionView(
      store: Store(
        initialState: ConnectionFeature.State(
          serverURL: "http://mac.tailnet:9119",
          token: "••••••••",
          status: .reachable(version: "0.16.0")
        )
      ) { ConnectionFeature() }
    )
    assertSnapshot(of: view, as: .image(layout: .device(config: device)))
  }

  func testConnectionView_invalidToken() {
    let view = ConnectionView(
      store: Store(
        initialState: ConnectionFeature.State(
          serverURL: "http://mac.tailnet:9119",
          token: "wrong",
          status: .invalidToken
        )
      ) { ConnectionFeature() }
    )
    assertSnapshot(of: view, as: .image(layout: .device(config: device)))
  }

  // MARK: SessionRowView (Task 7)

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
    assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
  }

  // MARK: SessionListView (Task 7)

  func testSessionList() {
    let now = self.now
    let sessions: [Session] = [
      Session(id: "s1", title: "Refactor the streaming parser",
              updatedAt: Date(timeIntervalSince1970: 1_749_556_800),
              preview: "Can you help me refactor the WebSocket JSON-RPC parser?"),
      Session(id: "s2", title: "Plan the iOS MVP",
              updatedAt: Date(timeIntervalSince1970: 1_749_470_400),
              preview: "Let's lock the connection model and milestones."),
      Session(id: "s3", title: nil,
              updatedAt: Date(timeIntervalSince1970: 1_749_384_000),
              preview: "quick question about cron jobs"),
    ]
    let view = NavigationStack {
      SessionListView(
        store: Store(
          initialState: SessionListFeature.State(
            connection: ServerConnection(baseURL: URL(string: "http://mac.tailnet:9119")!, token: "t"),
            sessions: IdentifiedArray(uniqueElements: sessions),
            now: now
          )
        ) {
          SessionListFeature()
        } withDependencies: {
          // Keep the on-appear .task from hitting the network during render.
          $0.hermesREST.sessions = { _, _, _, _ in sessions }
          $0.continuousClock = ImmediateClock()
          $0.date = .constant(now)
        }
      )
    }
    assertSnapshot(of: view, as: .image(layout: .device(config: device)))
  }
}
