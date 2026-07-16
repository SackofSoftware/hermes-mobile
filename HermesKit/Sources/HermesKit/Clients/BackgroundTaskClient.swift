import ComposableArchitecture
import DependenciesMacros
import Foundation

/// Requests a finite window of background execution (~30s) so the gateway socket can keep
/// streaming after the app is backgrounded mid-turn (keep-running-session-alive plan).
/// Wraps `UIApplication.beginBackgroundTask`/`endBackgroundTask` behind a dependency so
/// `AppFeature` stays testable and never touches UIKit directly. The client owns the
/// mandatory end-on-expiry bookkeeping: every begun task is ended exactly once — via
/// `end()`, on replacement by a newer `begin`, or inside the expiration handler (where
/// iOS requires it before the process is suspended).
@DependencyClient
public struct BackgroundTaskClient: Sendable {
  /// Start a finite background task. The returned stream yields **once** if iOS expires
  /// the task early (the ~30s window ran out while still backgrounded), then finishes; it
  /// finishes without yielding when the task is ended normally (`end()` or replacement).
  /// Beginning while a task is already active replaces it (the prior task is ended and
  /// its stream finishes without a yield).
  public var begin: @Sendable (_ name: String) async -> AsyncStream<Void> = { _ in .finished }
  /// End the active background task, returning execution to normal suspension rules.
  /// Idempotent — a no-op when no task is active (safe to call on `.active` unconditionally).
  public var end: @Sendable () async -> Void
}

extension BackgroundTaskClient: DependencyKey {
  /// No-op double: `begin` grants nothing (already-finished stream, no expiry ever), `end`
  /// does nothing. Override with `.inMemory()` to drive expiry in tests. (Spelled out so
  /// the `@DependencyClient` macro's unimplemented closures don't leak into the default.)
  public static var testValue: BackgroundTaskClient {
    BackgroundTaskClient(
      begin: { _ in .finished },
      end: {}
    )
  }
}

public extension DependencyValues {
  var backgroundTask: BackgroundTaskClient {
    get { self[BackgroundTaskClient.self] }
    set { self[BackgroundTaskClient.self] = newValue }
  }
}

// MARK: - In-memory (deterministic test variant)

/// Thread-safe bookkeeping for the in-memory client: one active task at a time, with the
/// same end-exactly-once rules as the live UIKit wrapper.
private final class BackgroundTaskBox: @unchecked Sendable {
  private let lock = NSLock()
  private var _activeTaskName: String?
  private var _continuation: AsyncStream<Void>.Continuation?
  private var _beginCount = 0
  private var _endCount = 0

  var activeTaskName: String? { lock.withLock { _activeTaskName } }
  var beginCount: Int { lock.withLock { _beginCount } }
  var endCount: Int { lock.withLock { _endCount } }

  func begin(name: String) -> AsyncStream<Void> {
    // Replace semantics: the prior task (if any) is ended, its stream finishing silently.
    finishActive(expired: false)
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    lock.withLock {
      _activeTaskName = name
      _continuation = continuation
      _beginCount += 1
    }
    return stream
  }

  func end() {
    finishActive(expired: false)
  }

  /// Simulate iOS expiring the active task: yield once, finish, and end the task (the
  /// live wrapper's expiration handler does the same mandatory bookkeeping).
  func expire() {
    finishActive(expired: true)
  }

  private func finishActive(expired: Bool) {
    let continuation: AsyncStream<Void>.Continuation? = lock.withLock {
      guard _activeTaskName != nil else { return nil }
      defer {
        _activeTaskName = nil
        _continuation = nil
        _endCount += 1
      }
      return _continuation
    }
    guard let continuation else { return }
    if expired { continuation.yield(()) }
    continuation.finish()
  }
}

public extension BackgroundTaskClient {
  /// A deterministic, controllable client for tests: `expire()` drives the early-expiry
  /// yield, and spy properties expose begin/end bookkeeping. Mirrors the
  /// `AudioRecorderClient` / `PushClient` in-memory variants.
  struct InMemory: Sendable {
    public let client: BackgroundTaskClient
    private let box: BackgroundTaskBox

    public init() {
      let box = BackgroundTaskBox()
      self.box = box
      self.client = BackgroundTaskClient(
        begin: { name in box.begin(name: name) },
        end: { box.end() }
      )
    }

    /// Simulate iOS expiring the active task early (yields once into the `begin` stream).
    public func expire() { box.expire() }
    /// The name of the currently active task, or `nil` when none is running.
    public var activeTaskName: String? { box.activeTaskName }
    /// How many tasks have been begun (spy hook for tests).
    public var beginCount: Int { box.beginCount }
    /// How many tasks have been ended — explicitly, by replacement, or by expiry.
    public var endCount: Int { box.endCount }
  }

  /// Convenience: a controllable in-memory client + handle for driving expiry.
  static func inMemory() -> InMemory { InMemory() }
}

// MARK: - Live (iOS only)

// `UIApplication.beginBackgroundTask` is iOS-only; the package is also built/tested on
// macOS via `swift test`, so the live wrapper is compiled in only where UIKit exists.
// Elsewhere `liveValue` falls back to the no-op double (no background-task API).
#if canImport(UIKit)
  import UIKit

  /// Owns the single active `UIBackgroundTaskIdentifier` and the mandatory bookkeeping:
  /// every begun task is ended exactly once — explicitly via `end()`, on replacement by a
  /// newer `begin`, or in the expiration handler (iOS kills apps that skip that call).
  private final class LiveBackgroundTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var taskID: UIBackgroundTaskIdentifier = .invalid
    private var continuation: AsyncStream<Void>.Continuation?

    @MainActor
    func begin(name: String) -> AsyncStream<Void> {
      // Replace semantics: end any prior task first (its stream finishes without a yield).
      finishActive(expired: false)
      let (stream, continuation) = AsyncStream<Void>.makeStream()
      let id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
        // The expiration handler is invoked on the main thread; iOS mandates ending the
        // task synchronously here, after we let the policy layer react via the yield.
        MainActor.assumeIsolated {
          self?.finishActive(expired: true)
        }
      }
      guard id != .invalid else {
        // Background execution unavailable (e.g. disabled) — behave like instant expiry
        // so the caller falls through to its clean-disconnect path.
        continuation.yield(())
        continuation.finish()
        return stream
      }
      lock.withLock {
        self.taskID = id
        self.continuation = continuation
      }
      return stream
    }

    @MainActor
    func end() {
      finishActive(expired: false)
    }

    @MainActor
    private func finishActive(expired: Bool) {
      let (id, continuation) = lock.withLock {
        defer {
          taskID = .invalid
          self.continuation = nil
        }
        return (taskID, self.continuation)
      }
      if expired { continuation?.yield(()) }
      continuation?.finish()
      if id != .invalid {
        UIApplication.shared.endBackgroundTask(id)
      }
    }
  }

  extension BackgroundTaskClient {
    public static var liveValue: BackgroundTaskClient {
      let box = LiveBackgroundTaskBox()
      return BackgroundTaskClient(
        begin: { name in await box.begin(name: name) },
        end: { await box.end() }
      )
    }
  }
#else
  extension BackgroundTaskClient {
    /// No background-task API off-device (macOS `swift test`): the no-op double.
    public static var liveValue: BackgroundTaskClient { testValue }
  }
#endif
