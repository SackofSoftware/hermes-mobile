import ComposableArchitecture
import DependenciesMacros
import Foundation

/// Non-authoritative client persistence for the chat: an instant-paint snapshot (capped
/// transcript tail + model/usage) plus a turn-start anchor for the elapsed timer. Backed by
/// SQLite (`ChatSnapshotStore`) but kept **behind this client boundary** — no reactive
/// `@FetchAll`; the reducer reads once and the server always wins on hydrate. Mirrors the
/// `PreferencesClient` shape with a `live` + `.inMemory()` test variant.
@DependencyClient
public struct ChatSnapshotClient: Sendable {
  /// Read the cached snapshot for a session (or `nil` if none) — used for instant paint.
  public var loadSnapshot: @Sendable (_ sessionID: String) -> ChatSnapshot?
  /// Persist (replace) the cached snapshot for a session.
  public var saveSnapshot: @Sendable (_ sessionID: String, _ snapshot: ChatSnapshot) -> Void
  /// Record the client-side turn-start instant (the elapsed-timer anchor).
  public var setTurnAnchor: @Sendable (_ sessionID: String, _ startedAt: Date) -> Void
  /// Drop the turn-start anchor (turn completed/errored/interrupted).
  public var clearTurnAnchor: @Sendable (_ sessionID: String) -> Void
  /// Read the persisted turn-start anchor for a session, if any.
  public var turnAnchor: @Sendable (_ sessionID: String) -> Date?
  /// Wipe every snapshot + anchor (logout).
  public var wipeAll: @Sendable () -> Void
}

public extension ChatSnapshotClient {
  /// SQLite-backed implementation. If the on-disk store can't be opened, falls back to a
  /// no-op cache so a persistence failure never breaks the app (the cache is optional).
  static func live() -> ChatSnapshotClient {
    guard let store = try? ChatSnapshotStore.live() else { return .noop }
    return .backed(by: store)
  }

  /// Deterministic in-memory store for previews and tests.
  static func inMemory() -> ChatSnapshotClient {
    guard let store = try? ChatSnapshotStore.inMemory() else { return .noop }
    return .backed(by: store)
  }

  /// A cache that quietly does nothing — used when the SQLite store is unavailable.
  static var noop: ChatSnapshotClient {
    ChatSnapshotClient(
      loadSnapshot: { _ in nil },
      saveSnapshot: { _, _ in },
      setTurnAnchor: { _, _ in },
      clearTurnAnchor: { _ in },
      turnAnchor: { _ in nil },
      wipeAll: {}
    )
  }

  private static func backed(by store: ChatSnapshotStore) -> ChatSnapshotClient {
    ChatSnapshotClient(
      loadSnapshot: { try? store.loadSnapshot($0) ?? nil },
      saveSnapshot: { try? store.saveSnapshot($0, $1) },
      setTurnAnchor: { try? store.setTurnAnchor($0, $1) },
      clearTurnAnchor: { try? store.clearTurnAnchor($0) },
      turnAnchor: { try? store.turnAnchor($0) ?? nil },
      wipeAll: { try? store.wipeAll() }
    )
  }
}

extension ChatSnapshotClient: DependencyKey {
  public static var liveValue: ChatSnapshotClient { .live() }
  public static var testValue: ChatSnapshotClient { .inMemory() }
}

public extension DependencyValues {
  var chatSnapshot: ChatSnapshotClient {
    get { self[ChatSnapshotClient.self] }
    set { self[ChatSnapshotClient.self] = newValue }
  }
}
