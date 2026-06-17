import Foundation
import Testing

@testable import HermesKit

/// Pure-logic tests for the Thinking indicator model: the `formatElapsed` formatter and
/// the `ChatRow.copyText` thinking branch.
@Suite struct ThinkingModelTests {
  @Test func formatElapsedBoundaries() {
    #expect(formatElapsed(0) == "0s")
    #expect(formatElapsed(5) == "5s")
    #expect(formatElapsed(59) == "59s")
    #expect(formatElapsed(60) == "1m 0s")
    #expect(formatElapsed(61) == "1m 1s")
    #expect(formatElapsed(3599) == "59m 59s")
    #expect(formatElapsed(3600) == "1h 0m 0s")
    #expect(formatElapsed(3661) == "1h 1m 1s")
    #expect(formatElapsed(7325) == "2h 2m 5s")
  }

  @Test func formatElapsedNegativeFloorsToZero() {
    #expect(formatElapsed(-1) == "0s")
    #expect(formatElapsed(-1000) == "0s")
  }

  @Test func copyTextReasoningOnly() {
    let row = ChatRow(
      id: UUID(),
      kind: .thinking(reasoning: "weighing options", status: nil, elapsedSeconds: 12, isComplete: true)
    )
    #expect(row.copyText == "weighing options")
  }

  @Test func copyTextReasoningPlusStatus() {
    let row = ChatRow(
      id: UUID(),
      kind: .thinking(
        reasoning: "weighing options",
        status: "Context: 42% used",
        elapsedSeconds: 12,
        isComplete: true
      )
    )
    #expect(row.copyText == "weighing options\n\nContext: 42% used")
  }

  @Test func copyTextStatusOnly() {
    let row = ChatRow(
      id: UUID(),
      kind: .thinking(reasoning: "", status: "Context: 42% used", elapsedSeconds: 0, isComplete: true)
    )
    #expect(row.copyText == "Context: 42% used")
  }

  @Test func copyTextEmptyStatusIgnored() {
    let row = ChatRow(
      id: UUID(),
      kind: .thinking(reasoning: "reasoning", status: "", elapsedSeconds: 0, isComplete: true)
    )
    #expect(row.copyText == "reasoning")
  }
}
