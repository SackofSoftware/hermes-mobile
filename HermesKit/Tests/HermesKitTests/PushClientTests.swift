import Foundation
import Testing

@testable import HermesKit

struct PushClientTests {
  // MARK: device-token Data → lowercase hex

  @Test func hexTokenEncodesKnownBytes() {
    let data = Data([0x00, 0x0f, 0xab, 0xff])
    #expect(PushClient.hexToken(from: data) == "000fabff")
  }

  @Test func hexTokenIsEmptyForEmptyData() {
    #expect(PushClient.hexToken(from: Data()) == "")
  }

  // MARK: compile-time apns_env constant

  @Test func apnsEnvMatchesBuildConfiguration() {
    // Tests run under a Debug build → sandbox.
    #if DEBUG
      #expect(PushClient.apnsEnv == "sandbox")
    #else
      #expect(PushClient.apnsEnv == "production")
    #endif
    #expect(["sandbox", "production"].contains(PushClient.apnsEnv))
  }

  // MARK: payload → session_id parsing

  @Test func sessionIDParsesFromPayload() {
    #expect(PushClient.sessionID(fromPayload: ["session_id": "abc"]) == "abc")
  }

  @Test func sessionIDIsNilWhenMissingOrEmpty() {
    #expect(PushClient.sessionID(fromPayload: [:]) == nil)
    #expect(PushClient.sessionID(fromPayload: ["session_id": ""]) == nil)
    #expect(PushClient.sessionID(fromPayload: ["session_id": 42]) == nil)
  }

  // MARK: payload → PushTap (session_id + optional type)

  @Test func tapParsesSessionAndType() {
    let tap = PushClient.tap(fromPayload: ["session_id": "abc", "type": "approval"])
    #expect(tap == PushTap(sessionID: "abc", type: "approval"))
    #expect(tap?.isApproval == true)
  }

  @Test func tapHasNilTypeWhenMissingOrEmpty() {
    #expect(PushClient.tap(fromPayload: ["session_id": "abc"]) == PushTap(sessionID: "abc", type: nil))
    #expect(PushClient.tap(fromPayload: ["session_id": "abc", "type": ""]) == PushTap(sessionID: "abc", type: nil))
    #expect(PushClient.tap(fromPayload: ["session_id": "abc"])?.isApproval == false)
  }

  @Test func tapIsNilForMalformedPayload() {
    #expect(PushClient.tap(fromPayload: [:]) == nil)
    #expect(PushClient.tap(fromPayload: ["session_id": ""]) == nil)
  }

  // MARK: pure foreground-presentation decision

  @Test func suppressesForegroundOnlyForTheSessionBeingViewed() {
    // Same session in the foreground → suppress (false).
    #expect(PushClient.shouldPresentForeground(
      incomingSessionID: "s1", currentlyViewingSessionID: "s1"
    ) == false)
    // Different session → present.
    #expect(PushClient.shouldPresentForeground(
      incomingSessionID: "s2", currentlyViewingSessionID: "s1"
    ) == true)
    // No chat open → present.
    #expect(PushClient.shouldPresentForeground(
      incomingSessionID: "s1", currentlyViewingSessionID: nil
    ) == true)
    // Malformed incoming (no session) → present (don't silently drop).
    #expect(PushClient.shouldPresentForeground(
      incomingSessionID: nil, currentlyViewingSessionID: "s1"
    ) == true)
  }

  // MARK: testValue (no-op double)

  @Test func testValueDeniesAndYieldsEmptyStreams() async {
    let client = PushClient.testValue
    #expect(await client.requestAuthorization() == false)
    #expect(await client.authorizationStatus() == .notDetermined)
    var tokens: [String] = []
    for await token in client.register() { tokens.append(token) }
    #expect(tokens.isEmpty)
    var taps: [PushTap] = []
    for await tap in client.incomingTaps() { taps.append(tap) }
    #expect(taps.isEmpty)
  }

  // MARK: in-memory authorize flow

  @Test func inMemoryAuthorizeReturnsConfiguredResult() async {
    let granted = PushClient.inMemory(granted: true)
    #expect(await granted.client.requestAuthorization() == true)
    #expect(await granted.client.authorizationStatus() == .authorized)

    let denied = PushClient.inMemory(granted: false, status: .notDetermined)
    #expect(await denied.client.requestAuthorization() == false)
    #expect(await denied.client.authorizationStatus() == .denied)
  }

  // MARK: in-memory register flow (token via AsyncStream)

  @Test func inMemoryRegisterYieldsInjectedToken() async {
    let push = PushClient.inMemory()
    // Retain the stream so it isn't torn down before we emit (per project memory).
    let stream = push.client.register()
    var iterator = stream.makeAsyncIterator()
    push.emit(token: "deadbeef")
    let received = await iterator.next()
    #expect(received == "deadbeef")
  }

  // MARK: in-memory incoming taps

  @Test func inMemoryIncomingTapsDeliversInjectedTap() async {
    let push = PushClient.inMemory()
    let stream = push.client.incomingTaps()
    var iterator = stream.makeAsyncIterator()
    push.emit(tap: PushTap(sessionID: "session-7"))
    let received = await iterator.next()
    #expect(received == PushTap(sessionID: "session-7"))
  }

  // MARK: in-memory badge + current-session spies

  @Test func inMemoryRecordsBadgeCount() async {
    let push = PushClient.inMemory()
    #expect(push.badgeCount == 0)
    await push.client.setBadgeCount(3)
    #expect(push.badgeCount == 3)
    await push.client.setBadgeCount(0)
    #expect(push.badgeCount == 0)
  }

  @Test func inMemoryRecordsCurrentSession() {
    let push = PushClient.inMemory()
    #expect(push.currentSession == nil)
    push.client.setCurrentSession("s9")
    #expect(push.currentSession == "s9")
    push.client.setCurrentSession(nil)
    #expect(push.currentSession == nil)
  }

  // MARK: PushBridge token stream (outside the UIKit guard → testable on macOS)

  @Test func bridgeTokenStreamReplaysLastTokenToLateSubscriber() async {
    let bridge = PushBridge()
    // Token arrives BEFORE anyone subscribes (the launch race)…
    bridge.tokenReceived(Data([0xde, 0xad, 0xbe, 0xef]))
    // …then the late subscriber still gets the cached token.
    let stream = bridge.tokenStream()
    var iterator = stream.makeAsyncIterator()
    #expect(await iterator.next() == "deadbeef")
    // And a live subscriber keeps receiving subsequent tokens.
    bridge.tokenReceived(Data([0x0f, 0xf0]))
    #expect(await iterator.next() == "0ff0")
  }

  // MARK: PushBridge tap buffering (cold-launch race, #46)

  @Test func bridgeTapStreamDeliversBufferedTapToFirstSubscriber() async {
    let bridge = PushBridge()
    // Tap arrives BEFORE anyone subscribes (launch-from-push race)…
    bridge.tapReceived(["session_id": "s1", "type": "approval"])
    // …then the first subscriber still receives the buffered tap.
    let stream = bridge.tapStream()
    var iterator = stream.makeAsyncIterator()
    #expect(await iterator.next() == PushTap(sessionID: "s1", type: "approval"))
  }

  @Test func bridgeTapBufferIsConsumeOnce() async {
    let bridge = PushBridge()
    bridge.tapReceived(["session_id": "s1"])
    // The first subscriber drains the buffer…
    let firstStream = bridge.tapStream()
    var first = firstStream.makeAsyncIterator()
    #expect(await first.next() == PushTap(sessionID: "s1"))
    // …so a later second subscriber must NOT see the stale tap again (re-yielding it
    // would re-navigate). Its first value is the next live tap, used as a sentinel.
    let secondStream = bridge.tapStream()
    var second = secondStream.makeAsyncIterator()
    bridge.tapReceived(["session_id": "s2"])
    #expect(await second.next() == PushTap(sessionID: "s2"))
  }

  @Test func bridgeTapDeliveredLiveIsNotBuffered() async {
    let bridge = PushBridge()
    // A live subscriber receives the tap directly…
    let liveStream = bridge.tapStream()
    var live = liveStream.makeAsyncIterator()
    bridge.tapReceived(["session_id": "s1"])
    #expect(await live.next() == PushTap(sessionID: "s1"))
    // …and because it was delivered, it is NOT cached: a new subscriber gets nothing
    // buffered — its first value is the next live tap (sentinel), never the old one.
    let lateStream = bridge.tapStream()
    var late = lateStream.makeAsyncIterator()
    bridge.tapReceived(["session_id": "s2"])
    #expect(await late.next() == PushTap(sessionID: "s2"))
  }

  @Test func bridgeTapReachesAllLiveSubscribers() async {
    let bridge = PushBridge()
    let streamA = bridge.tapStream()
    let streamB = bridge.tapStream()
    var a = streamA.makeAsyncIterator()
    var b = streamB.makeAsyncIterator()
    bridge.tapReceived(["session_id": "s1", "type": "complete"])
    let expected = PushTap(sessionID: "s1", type: "complete")
    #expect(await a.next() == expected)
    #expect(await b.next() == expected)
  }
}
