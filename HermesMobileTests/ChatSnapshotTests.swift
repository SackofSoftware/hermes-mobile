import ComposableArchitecture
import HermesKit
import SnapshotTesting
import SwiftUI
import XCTest

@testable import HermesMobile

final class ChatSnapshotTests: SnapshotTestCase {
  // MARK: ChatView

  /// Build a `ChatView` over `rows`. The transcript is rendered by the sole
  /// `UICollectionView`-backed engine.
  private func chatView(
    rows: [ChatRow],
    title: String,
    status: ChatFeature.State.Status
  ) -> some View {
    NavigationStack {
      ChatView(
        store: Store(
          initialState: ChatFeature.State(
            connection: connection,
            title: title,
            transcript: IdentifiedArray(uniqueElements: rows),
            status: status
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
  }

  private func assertChatView(
    rows: [ChatRow],
    title: String,
    status: ChatFeature.State.Status,
    file: StaticString = #file,
    testName: String = #function,
    line: UInt = #line
  ) {
    assertSnapshot(
      of: chatView(rows: rows, title: title, status: status),
      as: deviceImage(),
      file: file,
      testName: testName,
      line: line
    )
  }

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
    assertChatView(rows: rows, title: "Protocol chat", status: .ready)
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
    // .reconnecting exercises the connection banner too.
    assertChatView(rows: rows, title: "Protocol chat", status: .reconnecting)
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
    assertChatView(rows: rows, title: "Vision chat", status: .ready)
  }

  // MARK: Message action bar (#34)

  /// Completed assistant message: the copy + branch action row renders under the text
  /// (also exercised integrated in `testChatView`).
  func testChatView_messageActionBar() {
    let rows: [ChatRow] = [
      ChatRow(id: id(0), kind: .message(role: .user, text: "What renders the transcript?", isComplete: true)),
      ChatRow(id: id(1), kind: .message(
        role: .assistant,
        text: "The `UICollectionView`-backed `CollectionTranscriptView` — the only engine.",
        isComplete: true
      )),
    ]
    assertChatView(rows: rows, title: "Action bar", status: .ready)
  }

  /// A streaming (incomplete) assistant row must NOT show the action bar. Rendered as a
  /// single `rowView` cell (component snapshot): a full-device capture of a streaming row
  /// is flaky — the spinner keeps animations alive while the collection view re-pins to
  /// bottom, occasionally compositing the cell twice mid-flight.
  func testStreamingAssistantRow_noActionBar() {
    let row = ChatRow(id: id(1), kind: .message(
      role: .assistant,
      text: "The `UICollectionView`-backed",
      isComplete: false
    ))
    let chat = ChatView(
      store: Store(
        initialState: ChatFeature.State(
          connection: connection,
          title: "Action bar",
          transcript: IdentifiedArray(uniqueElements: [row]),
          status: .ready
        )
      ) {
        ChatFeature()
      } withDependencies: {
        $0.hermesGateway.connect = { _, _ in AsyncStream { _ in } }
        $0.continuousClock = ImmediateClock()
      }
    )
    let view = chat.rowView(row)
      .padding()
      .frame(width: 320)
      .background(Color(uiColor: .systemBackground))
    assertSnapshot(of: view, as: componentImage())
  }

  /// Copied state: the copy icon swaps to the green checkmark while the row's
  /// feedback token is live.
  func testMessageActionBar_copied() {
    let view = MessageActionBar(
      isCopied: true,
      isBranchDisabled: false,
      onCopy: {},
      onBranch: {}
    )
    .padding()
    .frame(width: 320)
    .background(Color(uiColor: .systemBackground))
    assertSnapshot(of: view, as: componentImage())
  }

  /// Branch disabled while a turn is running (mirrors the reducer guard).
  func testMessageActionBar_branchDisabled() {
    let view = MessageActionBar(
      isCopied: false,
      isBranchDisabled: true,
      onCopy: {},
      onBranch: {}
    )
    .padding()
    .frame(width: 320)
    .background(Color(uiColor: .systemBackground))
    assertSnapshot(of: view, as: componentImage())
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
      request: ApprovalRequest(
        command: "rm -rf build/ && git clean -fdx",
        detail: "Delete the build directory and all untracked files"
      ),
      onApprove: { _ in },
      onDeny: {}
    )
    .frame(width: device.size?.width ?? 390)
    assertSnapshot(of: view, as: componentImage())
  }

  /// Push-tap approval recovery (hermes-agent #30 workaround): the synthetic request has
  /// no command — only the recovery-copy detail — so the card must lay out command-less.
  func testApprovalCard_recovered() {
    let view = ApprovalCardView(
      request: ChatFeature.recoveredApprovalRequest,
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
