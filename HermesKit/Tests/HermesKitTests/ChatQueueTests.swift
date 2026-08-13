import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

/// Prompt queuing while a turn runs (#66): mid-turn `.composerSubmitted` freezes the
/// draft into `queuedPrompts` (no wire traffic), and the queue drains head-first through
/// the normal submit pipeline once the session goes idle.
@MainActor
struct ChatQueueTests {
  private let conn = ServerConnection(baseURL: URL(string: "http://mac.tailnet:9119")!, token: "t")
  private func uuid(_ n: Int) -> UUID {
    UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012x", n))")!
  }

  /// A chat mid-turn: live session bound, turn streaming (`isSending`).
  private func runningState(composerText: String = "") -> ChatFeature.State {
    var state = ChatFeature.State(connection: conn)
    state.liveSessionID = "live123"
    state.storedSessionID = "stored123"
    state.status = .ready
    state.isSending = true
    state.composerText = composerText
    return state
  }

  // MARK: Enqueue

  @Test func submittingMidTurnQueuesTheDraftAndClearsComposer() async {
    let store = TestStore(initialState: runningState(composerText: "  next thought  ")) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
    }

    await store.send(.composerSubmitted) {
      $0.queuedPrompts = [QueuedPrompt(id: self.uuid(0), text: "next thought")]
      $0.composerText = ""
    }
  }

  @Test func submittingDuringSlashExecQueues() async {
    var initial = runningState(composerText: "follow-up")
    initial.isSending = false
    initial.slashExecInFlight = true
    let store = TestStore(initialState: initial) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
    }

    await store.send(.composerSubmitted) {
      $0.queuedPrompts = [QueuedPrompt(id: self.uuid(0), text: "follow-up")]
      $0.composerText = ""
    }
  }

  @Test func twoEnqueuesStaySeparateOrderedEntries() async {
    let store = TestStore(initialState: runningState(composerText: "first")) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
    }

    await store.send(.composerSubmitted) {
      $0.queuedPrompts = [QueuedPrompt(id: self.uuid(0), text: "first")]
      $0.composerText = ""
    }
    await store.send(.binding(.set(\.composerText, "second"))) {
      $0.composerText = "second"
    }
    await store.send(.composerSubmitted) {
      $0.queuedPrompts = [
        QueuedPrompt(id: self.uuid(0), text: "first"),
        QueuedPrompt(id: self.uuid(1), text: "second"),
      ]
      $0.composerText = ""
    }
  }

  @Test func enqueueFreezesStagedAttachments() async {
    let attachment = ComposerAttachment(
      id: uuid(9), kind: .image, filename: "photo.jpg", mimeType: "image/jpeg",
      data: Data([0x1]), uploadState: .pending
    )
    var initial = runningState(composerText: "with a photo")
    initial.attachments = [attachment]
    let store = TestStore(initialState: initial) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
    }

    await store.send(.composerSubmitted) {
      $0.queuedPrompts = [
        QueuedPrompt(id: self.uuid(0), text: "with a photo", attachments: [attachment])
      ]
      $0.composerText = ""
      $0.attachments = []
    }
  }

  // MARK: Enqueue gates

  @Test func pendingApprovalBlocksQueuing() async {
    var initial = runningState(composerText: "queued behind a card")
    initial.present(.approval(ApprovalRequest(command: "rm -rf /tmp/x")))
    let store = TestStore(initialState: initial) { ChatFeature() }

    // A blocking card locks queuing exactly like sending — decide the card first.
    await store.send(.composerSubmitted)
  }

  @Test func branchInFlightBlocksQueuing() async {
    var initial = runningState(composerText: "text")
    initial.isBranching = true
    let store = TestStore(initialState: initial) { ChatFeature() }

    await store.send(.composerSubmitted)
  }

  @Test func pendingPasteBlocksQueuing() async {
    var initial = runningState(composerText: "text")
    initial.pendingPasteCount = 1
    let store = TestStore(initialState: initial) { ChatFeature() }

    await store.send(.composerSubmitted)
  }

  @Test func whitespaceOnlyDraftDoesNotQueue() async {
    let store = TestStore(initialState: runningState(composerText: "   \n  ")) { ChatFeature() }

    await store.send(.composerSubmitted)
  }

  @Test func degenerateSlashMidTurnFailsLocallyKeepingComposer() async {
    // Same local check the idle path runs: "/" with an empty parsed name must not be
    // queued (it would only fail at drain time) and must not destroy the payload.
    var initial = runningState(composerText: "/ payload after the slash")
    initial.commandCatalog = CommandCatalog(
      commands: [SlashCommand(name: "/status", description: "")]
    )
    let store = TestStore(initialState: initial) { ChatFeature() }

    await store.send(.composerSubmitted) {
      $0.errorBanner = "Command failed: empty command"
    }
  }
}
