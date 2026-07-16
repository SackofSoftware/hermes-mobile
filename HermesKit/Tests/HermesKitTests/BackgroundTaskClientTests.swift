import Foundation
import Testing

@testable import HermesKit

struct BackgroundTaskClientTests {
  // MARK: Begin/end bookkeeping

  @Test func beginTracksActiveTaskAndEndClearsIt() async {
    let inMemory = BackgroundTaskClient.inMemory()
    let client = inMemory.client

    _ = await client.begin("grace")
    #expect(inMemory.activeTaskName == "grace")
    #expect(inMemory.beginCount == 1)
    #expect(inMemory.endCount == 0)

    await client.end()
    #expect(inMemory.activeTaskName == nil)
    #expect(inMemory.endCount == 1)
  }

  @Test func endIsIdempotentWithNoActiveTask() async {
    let inMemory = BackgroundTaskClient.inMemory()
    let client = inMemory.client

    // No task begun — end must be a safe no-op (called unconditionally on `.active`).
    await client.end()
    #expect(inMemory.endCount == 0)

    _ = await client.begin("grace")
    await client.end()
    await client.end()
    // The begun task is ended exactly once; the second end is a no-op.
    #expect(inMemory.endCount == 1)
  }

  @Test func normalEndFinishesStreamWithoutYield() async {
    let inMemory = BackgroundTaskClient.inMemory()
    let client = inMemory.client

    let stream = await client.begin("grace")
    await client.end()

    var yields = 0
    for await _ in stream { yields += 1 }
    // A clean end (`.active` before the window ran out) must NOT look like an expiry.
    #expect(yields == 0)
  }

  // MARK: Expiry

  @Test func expiryYieldsExactlyOnceAndEndsTheTask() async {
    let inMemory = BackgroundTaskClient.inMemory()
    let client = inMemory.client

    let stream = await client.begin("grace")
    inMemory.expire()
    inMemory.expire() // a second expiry must not double-fire

    var yields = 0
    for await _ in stream { yields += 1 }
    // Finite loop (stream finished after the single yield); one expiry signal only.
    #expect(yields == 1)
    // Expiry performs the mandatory end bookkeeping itself.
    #expect(inMemory.activeTaskName == nil)
    #expect(inMemory.endCount == 1)
  }

  @Test func endAfterExpiryIsANoOp() async {
    let inMemory = BackgroundTaskClient.inMemory()
    let client = inMemory.client

    _ = await client.begin("grace")
    inMemory.expire()
    await client.end()
    // Already ended by the expiration bookkeeping — no double end.
    #expect(inMemory.endCount == 1)
  }

  // MARK: Double-begin replacement

  @Test func doubleBeginReplacesThePriorTask() async {
    let inMemory = BackgroundTaskClient.inMemory()
    let client = inMemory.client

    let first = await client.begin("first")
    let second = await client.begin("second")

    // The prior task was ended by the replacement; its stream finished without a yield.
    var firstYields = 0
    for await _ in first { firstYields += 1 }
    #expect(firstYields == 0)
    #expect(inMemory.activeTaskName == "second")
    #expect(inMemory.beginCount == 2)
    #expect(inMemory.endCount == 1)

    // Expiry targets the replacement, not the replaced task.
    inMemory.expire()
    var secondYields = 0
    for await _ in second { secondYields += 1 }
    #expect(secondYields == 1)
    #expect(inMemory.endCount == 2)
  }

  // MARK: Test double

  @Test func testValueBeginReturnsFinishedStreamAndEndIsNoOp() async {
    let client = BackgroundTaskClient.testValue

    let stream = await client.begin("anything")
    var yields = 0
    for await _ in stream { yields += 1 }
    // Already-finished stream: never signals expiry, never hangs a for-await.
    #expect(yields == 0)

    await client.end() // must not trip an unimplemented-dependency failure
  }
}
