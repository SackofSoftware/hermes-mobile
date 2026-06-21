import Foundation
import Testing

@testable import HermesKit

/// Pure `reconcileTimer` — table-driven over all four `running × anchor` branches.
struct TimerReconcileTests {
  private let now = Date(timeIntervalSince1970: 10_000)

  @Test func runningWithAnchorResumesAtElapsed() {
    let anchor = now.addingTimeInterval(-42)
    #expect(reconcileTimer(running: true, anchor: anchor, now: now) == .running(elapsed: 42))
  }

  @Test func runningWithoutAnchorStartsAtZero() {
    #expect(reconcileTimer(running: true, anchor: nil, now: now) == .running(elapsed: 0))
  }

  @Test func notRunningWithStaleAnchorFreezesAndDiscards() {
    let anchor = now.addingTimeInterval(-120)
    #expect(reconcileTimer(running: false, anchor: anchor, now: now) == .frozen)
  }

  @Test func notRunningWithoutAnchorIsNone() {
    #expect(reconcileTimer(running: false, anchor: nil, now: now) == TimerState.none)
  }

  @Test func futureAnchorClampsElapsedToZero() {
    let anchor = now.addingTimeInterval(30)  // clock skew: anchor ahead of now
    #expect(reconcileTimer(running: true, anchor: anchor, now: now) == .running(elapsed: 0))
  }

  @Test func zeroElapsedWhenAnchorEqualsNow() {
    #expect(reconcileTimer(running: true, anchor: now, now: now) == .running(elapsed: 0))
  }
}
