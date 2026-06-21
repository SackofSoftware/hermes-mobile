import Foundation
import GRDB

/// The plain-data snapshot for one session — what the cache hands back to `ChatFeature`
/// for an *instant paint* before the authoritative `session.activate` lands. This is a
/// **non-authoritative** cache: it can only make the UI appear faster, never differ from
/// the server, so every field is optional and the server replaces it wholesale on hydrate.
public struct ChatSnapshot: Equatable, Sendable {
  public var model: String?
  public var reasoningEffort: String?
  public var usage: Usage?
  /// Best-effort guess of whether the turn was running when we last persisted. Used only as
  /// a hint; the gateway's `running` flag wins on hydrate (and a cached guess must never
  /// *start* a list glow on its own).
  public var runningGuess: Bool
  public var updatedAt: Date
  /// The capped tail of transcript rows (oldest → newest within the kept window).
  public var rows: [ChatRow]

  public init(
    model: String? = nil,
    reasoningEffort: String? = nil,
    usage: Usage? = nil,
    runningGuess: Bool = false,
    updatedAt: Date = Date(),
    rows: [ChatRow] = []
  ) {
    self.model = model
    self.reasoningEffort = reasoningEffort
    self.usage = usage
    self.runningGuess = runningGuess
    self.updatedAt = updatedAt
    self.rows = rows
  }
}

/// GRDB-backed SQLite store for the chat snapshot cache. Owns a private `DatabaseQueue`
/// (file-backed for `live`, in-memory for `inMemory`) — it is **not** the app's shared
/// `defaultDatabase`, so tests stay isolated and there is no reactive observation. All
/// access goes through `ChatSnapshotClient`; this type is an implementation detail.
struct ChatSnapshotStore {
  let queue: DatabaseQueue

  /// Hard caps so a runaway transcript can't bloat the cache. We persist only the tail of a
  /// session and only a bounded number of sessions (LRU by `updated_at`).
  static let maxRowsPerSession = 200
  static let maxSessions = 50

  /// File-backed store under Application Support. Throwing on disk failure is fine — the
  /// caller falls back to a no-op cache so persistence problems never break the app.
  static func live() throws -> ChatSnapshotStore {
    let dir = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
    )
    let url = dir.appendingPathComponent("hermes-chat-snapshots.sqlite")
    return try ChatSnapshotStore(path: url.path)
  }

  /// In-memory store for previews and tests (each instance is isolated).
  static func inMemory() throws -> ChatSnapshotStore {
    try ChatSnapshotStore(path: nil)
  }

  private init(path: String?) throws {
    if let path {
      queue = try DatabaseQueue(path: path)
    } else {
      queue = try DatabaseQueue()
    }
    try Self.migrator.migrate(queue)
  }

  // MARK: - Migrations

  /// Versioned schema. New migrations append; shipped ones are never edited.
  static var migrator: DatabaseMigrator {
    var migrator = DatabaseMigrator()
    migrator.registerMigration("v1: snapshot tables") { db in
      try db.execute(sql: """
        CREATE TABLE "sessions" (
          "id" TEXT PRIMARY KEY NOT NULL,
          "model" TEXT,
          "reasoning_effort" TEXT,
          "usage_json" TEXT,
          "running_guess" INTEGER NOT NULL DEFAULT 0,
          "updated_at" REAL NOT NULL DEFAULT 0
        ) STRICT
        """)
      try db.execute(sql: """
        CREATE TABLE "turn_anchors" (
          "session_id" TEXT PRIMARY KEY NOT NULL,
          "started_at" REAL NOT NULL
        ) STRICT
        """)
      try db.execute(sql: """
        CREATE TABLE "snapshot_rows" (
          "session_id" TEXT NOT NULL,
          "idx" INTEGER NOT NULL,
          "row_json" TEXT NOT NULL,
          PRIMARY KEY ("session_id", "idx")
        ) STRICT
        """)
      try db.execute(sql: """
        CREATE INDEX "index_snapshot_rows_on_session_id"
          ON "snapshot_rows"("session_id")
        """)
    }
    return migrator
  }

  // MARK: - Codec

  private static let encoder = JSONEncoder()
  private static let decoder = JSONDecoder()

  // MARK: - Snapshot read/write

  func loadSnapshot(_ sessionID: String) throws -> ChatSnapshot? {
    try queue.read { db in
      guard
        let row = try Row.fetchOne(
          db,
          sql: """
            SELECT "model", "reasoning_effort", "usage_json", "running_guess", "updated_at"
            FROM "sessions" WHERE "id" = ?
            """,
          arguments: [sessionID]
        )
      else { return nil }

      let usage: Usage? = (row["usage_json"] as String?)
        .flatMap { $0.data(using: .utf8) }
        .flatMap { try? Self.decoder.decode(Usage.self, from: $0) }

      let rowJSONs = try String.fetchAll(
        db,
        sql: """
          SELECT "row_json" FROM "snapshot_rows"
          WHERE "session_id" = ? ORDER BY "idx" ASC
          """,
        arguments: [sessionID]
      )
      let rows: [ChatRow] = rowJSONs.compactMap { json in
        json.data(using: .utf8).flatMap { try? Self.decoder.decode(ChatRow.self, from: $0) }
      }

      return ChatSnapshot(
        model: row["model"],
        reasoningEffort: row["reasoning_effort"],
        usage: usage,
        runningGuess: (row["running_guess"] as Int64) != 0,
        updatedAt: Date(timeIntervalSince1970: row["updated_at"]),
        rows: rows
      )
    }
  }

  func saveSnapshot(_ sessionID: String, _ snapshot: ChatSnapshot) throws {
    // Cap the persisted tail to the most-recent rows.
    let tail = snapshot.rows.suffix(Self.maxRowsPerSession)
    let usageJSON = snapshot.usage
      .flatMap { try? Self.encoder.encode($0) }
      .flatMap { String(data: $0, encoding: .utf8) }

    try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO "sessions"
            ("id", "model", "reasoning_effort", "usage_json", "running_guess", "updated_at")
          VALUES (?, ?, ?, ?, ?, ?)
          ON CONFLICT("id") DO UPDATE SET
            "model" = excluded."model",
            "reasoning_effort" = excluded."reasoning_effort",
            "usage_json" = excluded."usage_json",
            "running_guess" = excluded."running_guess",
            "updated_at" = excluded."updated_at"
          """,
        arguments: [
          sessionID, snapshot.model, snapshot.reasoningEffort, usageJSON,
          snapshot.runningGuess ? 1 : 0, snapshot.updatedAt.timeIntervalSince1970,
        ]
      )

      try db.execute(
        sql: #"DELETE FROM "snapshot_rows" WHERE "session_id" = ?"#,
        arguments: [sessionID]
      )
      for (idx, chatRow) in tail.enumerated() {
        guard
          let data = try? Self.encoder.encode(chatRow),
          let json = String(data: data, encoding: .utf8)
        else { continue }
        try db.execute(
          sql: """
            INSERT INTO "snapshot_rows" ("session_id", "idx", "row_json")
            VALUES (?, ?, ?)
            """,
          arguments: [sessionID, idx, json]
        )
      }

      try Self.evictExcessSessions(db)
    }
  }

  /// Keep only the `maxSessions` most-recently-updated sessions; drop the rest (and their
  /// rows + anchors) so the cache stays bounded.
  private static func evictExcessSessions(_ db: Database) throws {
    let count = try Int.fetchOne(db, sql: #"SELECT COUNT(*) FROM "sessions""#) ?? 0
    guard count > maxSessions else { return }
    let stale = try String.fetchAll(
      db,
      sql: """
        SELECT "id" FROM "sessions"
        ORDER BY "updated_at" DESC
        LIMIT -1 OFFSET ?
        """,
      arguments: [maxSessions]
    )
    for id in stale {
      try db.execute(sql: #"DELETE FROM "sessions" WHERE "id" = ?"#, arguments: [id])
      try db.execute(sql: #"DELETE FROM "snapshot_rows" WHERE "session_id" = ?"#, arguments: [id])
      try db.execute(sql: #"DELETE FROM "turn_anchors" WHERE "session_id" = ?"#, arguments: [id])
    }
  }

  // MARK: - Turn anchor

  func setTurnAnchor(_ sessionID: String, _ startedAt: Date) throws {
    try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO "turn_anchors" ("session_id", "started_at") VALUES (?, ?)
          ON CONFLICT("session_id") DO UPDATE SET "started_at" = excluded."started_at"
          """,
        arguments: [sessionID, startedAt.timeIntervalSince1970]
      )
    }
  }

  func clearTurnAnchor(_ sessionID: String) throws {
    try queue.write { db in
      try db.execute(
        sql: #"DELETE FROM "turn_anchors" WHERE "session_id" = ?"#,
        arguments: [sessionID]
      )
    }
  }

  func turnAnchor(_ sessionID: String) throws -> Date? {
    try queue.read { db in
      let ts = try Double.fetchOne(
        db,
        sql: #"SELECT "started_at" FROM "turn_anchors" WHERE "session_id" = ?"#,
        arguments: [sessionID]
      )
      return ts.map { Date(timeIntervalSince1970: $0) }
    }
  }

  // MARK: - Wipe

  func wipeAll() throws {
    try queue.write { db in
      try db.execute(sql: #"DELETE FROM "sessions""#)
      try db.execute(sql: #"DELETE FROM "snapshot_rows""#)
      try db.execute(sql: #"DELETE FROM "turn_anchors""#)
    }
  }
}
