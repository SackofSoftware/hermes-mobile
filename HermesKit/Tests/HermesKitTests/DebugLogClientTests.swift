import Foundation
import Testing

@testable import HermesKit

struct DebugLogClientTests {
  @Test func appendAccumulatesSnapshotWithSequentialIDsAndSummaries() {
    let log = DebugLogClient.ringBuffer()
    log.append(.ready)
    log.append(.messageDelta(text: "Hello"))

    let entries = log.snapshot()
    #expect(entries.map(\.id) == [0, 1])
    #expect(entries.map(\.type) == ["gateway.ready", "message.delta"])
    #expect(entries[1].summary == "Hello")
  }

  @Test func ringBufferCapsToCapacity() {
    let log = DebugLogClient.ringBuffer(capacity: 3)
    for _ in 0..<5 { log.append(.ready) }

    let entries = log.snapshot()
    #expect(entries.count == 3)
    // Oldest dropped: ids should be the last three appended.
    #expect(entries.map(\.id) == [2, 3, 4])
  }

  @Test func streamPrimesWithCurrentSnapshotThenBroadcastsAppends() async {
    let log = DebugLogClient.ringBuffer()
    log.append(.ready) // present before subscribing

    var iterator = log.stream().makeAsyncIterator()
    let primed = await iterator.next()
    #expect(primed?.map(\.type) == ["gateway.ready"])

    log.append(.error(message: "boom"))
    let next = await iterator.next()
    #expect(next?.map(\.type) == ["gateway.ready", "error"])
    #expect(next?.last?.summary == "boom")
  }

  @Test func multilineSummaryIsCollapsedAndTruncated() {
    let log = DebugLogClient.ringBuffer()
    log.append(.messageComplete(text: "line one\nline two", usage: nil))
    #expect(log.snapshot().last?.summary == "line one⏎line two")
  }
}
