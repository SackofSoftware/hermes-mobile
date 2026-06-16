import ComposableArchitecture
import HermesKit
import SnapshotTesting
import SwiftUI
import XCTest

@testable import HermesMobile

final class ChatSnapshotTests: SnapshotTestCase {
  // MARK: ChatView

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
    assertSnapshot(of: view, as: deviceImage())
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
    assertSnapshot(of: view, as: deviceImage())
  }

  func testChatView_sentImageAttachment() {
    let rows: [ChatRow] = [
      ChatRow(
        id: id(0),
        kind: .message(role: .user, text: "What's in this picture?", isComplete: true),
        attachmentImages: [solidPNG(.systemTeal, 200)]
      ),
      ChatRow(id: id(1), kind: .message(role: .assistant, text: "A solid teal square.", isComplete: true)),
    ]
    let view = NavigationStack {
      ChatView(
        store: Store(
          initialState: ChatFeature.State(
            connection: connection,
            title: "Vision chat",
            transcript: IdentifiedArray(uniqueElements: rows),
            status: .ready
          )
        ) {
          ChatFeature()
        } withDependencies: {
          $0.hermesGateway.connect = { _, _ in AsyncStream { _ in } }
          $0.continuousClock = ImmediateClock()
        }
      )
    }
    assertSnapshot(of: view, as: deviceImage())
  }

  // MARK: Code-block copy affordance (#9)

  private static let copySample = "Run this:\n\n```bash\nmake snapshot\n```"

  func testCodeBlock_copyButtonIdle() {
    let view = MarkdownText(text: Self.copySample, tokenPrefix: "row", onCopyCode: { _, _ in })
      .padding()
      .frame(width: 320)
      .background(Color(uiColor: .systemBackground))
    assertSnapshot(of: view, as: componentImage())
  }

  func testCodeBlock_copiedCheckmark() {
    // `copiedToken` matches the code block's token ("<prefix>#<segment index>"); the
    // sample's code is the 2nd segment (after the prose line), so index 1.
    let view = MarkdownText(
      text: Self.copySample,
      copiedToken: "row#1",
      tokenPrefix: "row",
      onCopyCode: { _, _ in }
    )
    .padding()
    .frame(width: 320)
    .background(Color(uiColor: .systemBackground))
    assertSnapshot(of: view, as: componentImage())
  }

  // MARK: Approval card

  func testApprovalCard() {
    let view = ApprovalCardView(
      request: ApprovalRequest(requestID: "r1", command: "rm -rf build/ && git clean -fdx"),
      onApprove: { _ in },
      onDeny: {}
    )
    .frame(width: device.size?.width ?? 390)
    assertSnapshot(of: view, as: componentImage())
  }

  // MARK: Clarify / secret cards

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
    assertSnapshot(of: view, as: componentImage())
  }

  func testClarifyCard_freeText() {
    let view = ClarifyCardView(
      mode: .clarify(ClarifyRequest(requestID: "c2", question: "What should I name the branch?", choices: [])),
      onSubmit: { _ in }
    )
    .frame(width: device.size?.width ?? 390)
    assertSnapshot(of: view, as: componentImage())
  }

  func testSecretCard_secure() {
    let view = ClarifyCardView(
      mode: .secret(.secret, SecretPrompt(requestID: "s1", prompt: "Enter the API key for the weather service")),
      onSubmit: { _ in }
    )
    .frame(width: device.size?.width ?? 390)
    assertSnapshot(of: view, as: componentImage())
  }

  // MARK: Tool/skill rows + detail sheet

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
    assertSnapshot(of: view, as: componentImage())
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
    assertSnapshot(of: view, as: deviceImage())
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
    assertSnapshot(of: view, as: componentImage())
  }
}
