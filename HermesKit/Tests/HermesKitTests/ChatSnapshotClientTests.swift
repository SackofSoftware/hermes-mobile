import Foundation
import GRDB
import Testing

@testable import HermesKit

struct ChatSnapshotClientTests {
  // MARK: - Helpers

  private func messageRow(_ text: String, complete: Bool = true) -> ChatRow {
    ChatRow(id: UUID(), kind: .message(role: .assistant, text: text, isComplete: complete))
  }

  // MARK: - Snapshot round-trip

  @Test func snapshotWriteReadRoundTrip() {
    let client = ChatSnapshotClient.inMemory()
    #expect(client.loadSnapshot("s1") == nil)

    let usage = Usage(model: "gpt-5", total: 1234, contextUsed: 1000, contextMax: 8000, contextPercent: 12)
    let rows = [messageRow("hello"), messageRow("world", complete: false)]
    let snapshot = ChatSnapshot(
      model: "gpt-5",
      reasoningEffort: "high",
      usage: usage,
      runningGuess: true,
      updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
      rows: rows
    )
    client.saveSnapshot("s1", snapshot)

    let loaded = client.loadSnapshot("s1")
    #expect(loaded?.model == "gpt-5")
    #expect(loaded?.reasoningEffort == "high")
    #expect(loaded?.runningGuess == true)
    #expect(loaded?.usage == usage)
    #expect(loaded?.updatedAt == Date(timeIntervalSince1970: 1_700_000_000))
    #expect(loaded?.rows == rows)
  }

  @Test func snapshotOverwriteReplacesWholesale() {
    let client = ChatSnapshotClient.inMemory()
    client.saveSnapshot("s1", ChatSnapshot(model: "a", rows: [messageRow("one"), messageRow("two")]))
    client.saveSnapshot("s1", ChatSnapshot(model: "b", rows: [messageRow("three")]))

    let loaded = client.loadSnapshot("s1")
    #expect(loaded?.model == "b")
    #expect(loaded?.rows.count == 1)
    if case let .message(_, text, _)? = loaded?.rows.first?.kind {
      #expect(text == "three")
    } else {
      Issue.record("expected single message row")
    }
  }

  @Test func snapshotRoundTripsToolRowsWithDetail() {
    let client = ChatSnapshotClient.inMemory()
    let toolRow = ChatRow(
      id: UUID(),
      kind: .tool(
        name: "bash",
        title: "Run command",
        state: .complete,
        detail: ToolDetail(argsText: "ls", args: .object(["cmd": .string("ls")]), resultText: "file.txt"),
        durationS: 1.5
      )
    )
    client.saveSnapshot("s1", ChatSnapshot(rows: [toolRow]))
    #expect(client.loadSnapshot("s1")?.rows == [toolRow])
  }

  // MARK: - Turn anchor

  @Test func turnAnchorSetGetClear() {
    let client = ChatSnapshotClient.inMemory()
    #expect(client.turnAnchor("s1") == nil)

    let anchor = Date(timeIntervalSince1970: 1_700_000_500)
    client.setTurnAnchor("s1", anchor)
    #expect(client.turnAnchor("s1") == anchor)

    // Resetting overwrites.
    let anchor2 = Date(timeIntervalSince1970: 1_700_000_999)
    client.setTurnAnchor("s1", anchor2)
    #expect(client.turnAnchor("s1") == anchor2)

    client.clearTurnAnchor("s1")
    #expect(client.turnAnchor("s1") == nil)
  }

  @Test func turnAnchorIsPerSession() {
    let client = ChatSnapshotClient.inMemory()
    client.setTurnAnchor("s1", Date(timeIntervalSince1970: 1))
    client.setTurnAnchor("s2", Date(timeIntervalSince1970: 2))
    #expect(client.turnAnchor("s1") == Date(timeIntervalSince1970: 1))
    #expect(client.turnAnchor("s2") == Date(timeIntervalSince1970: 2))
  }

  // MARK: - wipeAll

  @Test func wipeAllClearsSnapshotsAndAnchors() {
    let client = ChatSnapshotClient.inMemory()
    client.saveSnapshot("s1", ChatSnapshot(model: "a", rows: [messageRow("hi")]))
    client.setTurnAnchor("s1", Date(timeIntervalSince1970: 1))

    client.wipeAll()

    #expect(client.loadSnapshot("s1") == nil)
    #expect(client.turnAnchor("s1") == nil)
  }

  // MARK: - Caps

  @Test func rowsAreCappedToTail() throws {
    let store = try ChatSnapshotStore.inMemory()
    let n = ChatSnapshotStore.maxRowsPerSession + 30
    let rows = (0..<n).map { messageRow("row\($0)") }
    try store.saveSnapshot("s1", ChatSnapshot(rows: rows))

    let loaded = try #require(try store.loadSnapshot("s1"))
    #expect(loaded.rows.count == ChatSnapshotStore.maxRowsPerSession)
    // The kept window is the *newest* rows.
    #expect(loaded.rows == Array(rows.suffix(ChatSnapshotStore.maxRowsPerSession)))
  }

  @Test func sessionsAreCappedByLRU() throws {
    let store = try ChatSnapshotStore.inMemory()
    let total = ChatSnapshotStore.maxSessions + 5
    for i in 0..<total {
      try store.saveSnapshot(
        "s\(i)",
        ChatSnapshot(model: "m\(i)", updatedAt: Date(timeIntervalSince1970: Double(i)), rows: [messageRow("x")])
      )
    }
    // The 5 oldest (lowest updated_at) should have been evicted.
    for i in 0..<5 {
      #expect(try store.loadSnapshot("s\(i)") == nil)
    }
    for i in 5..<total {
      #expect(try store.loadSnapshot("s\(i)") != nil)
    }
  }

  // MARK: - Migration

  @Test func freshDatabaseHasSchema() throws {
    let store = try ChatSnapshotStore.inMemory()
    let tables = try store.queue.read { db in
      try String.fetchAll(
        db,
        sql: #"SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name"#
      )
    }
    #expect(tables.contains("sessions"))
    #expect(tables.contains("turn_anchors"))
    #expect(tables.contains("snapshot_rows"))
  }

  @Test func migrationIsIdempotent() throws {
    // Running the migrator twice on the same DB must not throw or duplicate tables.
    let store = try ChatSnapshotStore.inMemory()
    try ChatSnapshotStore.migrator.migrate(store.queue)
    let applied = try store.queue.read { db in
      try ChatSnapshotStore.migrator.appliedMigrations(db)
    }
    #expect(applied == ["v1: snapshot tables"])
  }
}
