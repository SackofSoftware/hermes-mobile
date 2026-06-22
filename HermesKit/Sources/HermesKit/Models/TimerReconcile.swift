import Foundation

/// The reconciled state of a turn's "Thinking" elapsed timer, derived purely from the
/// server-authoritative `running` flag and a client-persisted turn-start `anchor`.
///
/// `ChatFeature` models the live timer as a cancellable `continuousClock` tick driving
/// `State.thinkingSeconds` (read by the active `.thinking` row's view) and a frozen
/// `elapsedSeconds` baked into the row on completion. This enum maps cleanly onto that:
///   - `.running(elapsed:)` — resume the live tick seeded at `elapsed` seconds (the
///     reducer can start its `continuousClock` loop and pre-set `thinkingSeconds`);
///   - `.frozen` — no live tick; show the static `Thinking · <elapsed>` disclosure from
///     the row's already-frozen `elapsedSeconds` (any stale anchor is discarded);
///   - `.none` — no in-flight turn and no timer at all.
public enum TimerState: Equatable, Sendable {
  /// A turn is running; the live tick should resume seeded at `elapsed` seconds.
  case running(elapsed: TimeInterval)
  /// No live tick; the row's frozen `elapsedSeconds` stands. A stale anchor is discarded.
  case frozen
  /// No in-flight turn and no timer.
  case none
}

/// Reconcile the elapsed timer purely from the authoritative `running` flag and an
/// optional client-persisted turn-start `anchor`, evaluated against `now`.
///
/// `running` decides **whether** the timer runs; the `anchor` only supplies the **start
/// instant**. All four branches:
///   - `running && anchor` → `.running(elapsed: now - anchor)` (resume mid-turn);
///   - `running && !anchor` → `.running(elapsed: 0)` (no anchor yet; effectively
///     anchored at `now` by the caller);
///   - `!running && anchor` → `.frozen` (discard the stale anchor; kills a phantom timer);
///   - `!running && !anchor` → `.none`.
///
/// Pure: `now` is a parameter, never read from `Date.now`/a `Clock` inside.
public func reconcileTimer(running: Bool, anchor: Date?, now: Date) -> TimerState {
  switch (running, anchor) {
  case let (true, anchor?):
    // Resume mid-turn. Clamp negatives (clock skew / future anchor) to 0.
    return .running(elapsed: max(0, now.timeIntervalSince(anchor)))
  case (true, nil):
    return .running(elapsed: 0)
  case (false, .some):
    // Turn already stopped — the anchor is stale; freeze and discard it.
    return .frozen
  case (false, nil):
    return .none
  }
}
