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
  private let connection = ServerConnection(baseURL: URL(string: "http://mac.tailnet:9119")!, token: "t")
  private func id(_ n: Int) -> UUID {
    UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012x", n))")!
  }

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
              preview: "Can you help me refactor the WebSocket JSON-RPC parser?",
              cwd: "/Users/me/dev/hermes-mobile",
              startedAt: Date(timeIntervalSince1970: 1_749_556_800)),
      Session(id: "s2", title: "Plan the iOS MVP",
              updatedAt: Date(timeIntervalSince1970: 1_749_470_400),
              preview: "Let's lock the connection model and milestones.",
              cwd: "/Users/me/dev/hermes-mobile",
              startedAt: Date(timeIntervalSince1970: 1_749_470_400)),
      Session(id: "s3", title: nil,
              updatedAt: Date(timeIntervalSince1970: 1_749_384_000),
              preview: "quick question about cron jobs",
              cwd: "/Users/me/dev/hermes-agent",
              startedAt: Date(timeIntervalSince1970: 1_749_384_000)),
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

  // MARK: ChatView (Task 8)

  func testChatView() {
    let rows: [ChatRow] = [
      ChatRow(id: id(0), kind: .message(role: .user, text: "Summarize the streaming protocol.", isComplete: true)),
      ChatRow(id: id(1), kind: .tool(name: "read_file", title: "Read tui_gateway/server.py", state: .complete,
                                     detail: ToolDetail(resultText: "tui_gateway/server.py"), durationS: 0.8)),
      ChatRow(id: id(2), kind: .message(
        role: .assistant,
        text: "Here's the gist:\n\n- **WebSocket** JSON-RPC at `/api/ws`\n- Responses stream as `message.delta` events\n- Tools surface via `tool.start` / `tool.complete`",
        isComplete: true
      )),
    ]
    let view = NavigationStack {
      ChatView(
        store: Store(
          initialState: ChatFeature.State(
            connection: connection,
            title: "Protocol chat",
            transcript: IdentifiedArray(uniqueElements: rows),
            status: .ready
          )
        ) {
          ChatFeature()
        } withDependencies: {
          // Don't open a real socket during render.
          $0.hermesGateway.connect = { _, _ in AsyncStream { _ in } }
          $0.continuousClock = ImmediateClock()
        }
      )
    }
    assertSnapshot(of: view, as: .image(layout: .device(config: device)))
  }

  /// Fenced code block + list rendering (Task 11 markdown polish).
  func testChatView_codeBlockAndReconnecting() {
    let rows: [ChatRow] = [
      ChatRow(id: id(0), kind: .message(role: .user, text: "Show me the connect effect.", isComplete: true)),
      ChatRow(id: id(1), kind: .message(
        role: .assistant,
        text: "Here's the gist:\n\n```swift\nfor await event in gateway.connect(url, token) {\n  await send(.gatewayEvent(event))\n}\n```\n\nThat funnels every event through one action.",
        isComplete: true
      )),
    ]
    let view = NavigationStack {
      ChatView(
        store: Store(
          initialState: ChatFeature.State(
            connection: connection,
            title: "Protocol chat",
            transcript: IdentifiedArray(uniqueElements: rows),
            status: .reconnecting // exercises the connection banner too
          )
        ) {
          ChatFeature()
        } withDependencies: {
          $0.hermesGateway.connect = { _, _ in AsyncStream { _ in } }
          $0.continuousClock = ImmediateClock()
        }
      )
    }
    assertSnapshot(of: view, as: .image(layout: .device(config: device)))
  }

  // MARK: Approval card (Task 9)

  func testApprovalCard() {
    let view = ApprovalCardView(
      request: ApprovalRequest(requestID: "r1", command: "rm -rf build/ && git clean -fdx"),
      onApprove: { _ in },
      onDeny: {}
    )
    .frame(width: device.size?.width ?? 390)
    assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
  }

  // MARK: Clarify / secret cards (Task 10)

  func testClarifyCard_choices() {
    let view = ClarifyCardView(
      mode: .clarify(ClarifyRequest(
        requestID: "c1",
        question: "Which environment should I deploy to?",
        choices: ["staging", "production"]
      )),
      onSubmit: { _ in }
    )
    .frame(width: device.size?.width ?? 390)
    assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
  }

  func testClarifyCard_freeText() {
    let view = ClarifyCardView(
      mode: .clarify(ClarifyRequest(requestID: "c2", question: "What should I name the branch?", choices: [])),
      onSubmit: { _ in }
    )
    .frame(width: device.size?.width ?? 390)
    assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
  }

  func testSecretCard_secure() {
    let view = ClarifyCardView(
      mode: .secret(.secret, SecretPrompt(requestID: "s1", prompt: "Enter the API key for the weather service")),
      onSubmit: { _ in }
    )
    .frame(width: device.size?.width ?? 390)
    assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
  }

  // MARK: Tool/skill rows + detail sheet (UX Task 4)

  func testToolRows() {
    let view = VStack(spacing: 10) {
      ToolStatusView(name: "read_file", title: "Reading server.py", state: .running,
                     durationS: nil, hasDetail: true, onTap: {})
      ToolStatusView(name: "edit_file", title: "Edited 3 lines in ChatView.swift", state: .complete,
                     durationS: 1.4, hasDetail: true, onTap: {})
      ToolStatusView(name: "todo", title: "todo", state: .complete,
                     durationS: 0.1, hasDetail: false, onTap: {})
    }
    .padding()
    .frame(width: device.size?.width ?? 390)
    assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
  }

  func testToolDetailSheet() {
    let view = ToolDetailSheet(
      name: "edit_file",
      title: "Edited 3 lines in ChatView.swift",
      detail: ToolDetail(
        args: .object(["path": .string("ChatView.swift"), "start": .number(42)]),
        resultText: "Applied edit successfully.",
        inlineDiff: "- old line\n+ new line"
      ),
      durationS: 1.4
    )
    assertSnapshot(of: view, as: .image(layout: .device(config: device)))
  }

  func testScrollToBottomButton() {
    // Over a gradient so the Liquid Glass refraction is visible (it's near-invisible on
    // flat black).
    let view = ScrollToBottomButton(action: {})
      .padding(40)
      .background(
        LinearGradient(
          colors: [.purple, .blue, .teal],
          startPoint: .topLeading, endPoint: .bottomTrailing
        )
      )
    assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
  }

  // MARK: Settings (Task 12)

  func testSettingsView() {
    var initial = SettingsFeature.State(connection: connection)
    initial.log = [
      GatewayLogEntry(id: 0, type: "gateway.ready", summary: ""),
      GatewayLogEntry(id: 1, type: "message.delta", summary: "Here's the gist"),
    ]
    let view = NavigationStack {
      SettingsView(
        store: Store(initialState: initial) { SettingsFeature() } withDependencies: {
          $0.debugLog = .testValue // inert stream for a deterministic render
        }
      )
    }
    assertSnapshot(of: view, as: .image(layout: .device(config: device)))
  }

  func testConnectionDebugView() {
    let view = NavigationStack {
      ConnectionDebugView(entries: [
        GatewayLogEntry(id: 0, type: "gateway.ready", summary: ""),
        GatewayLogEntry(id: 1, type: "tool.start", summary: "read_file"),
        GatewayLogEntry(id: 2, type: "message.delta", summary: "WebSocket JSON-RPC at /api/ws"),
        GatewayLogEntry(id: 3, type: "status.update", summary: "[lifecycle] thinking…"),
      ])
    }
    assertSnapshot(of: view, as: .image(layout: .device(config: device)))
  }
}
