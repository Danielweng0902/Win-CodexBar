import Foundation
import Testing

@testable import CodexBarCore

#if canImport(SQLite3)
import SQLite3

struct OpenCodeLocalUsageReaderTests {
    @Test
    func `selects only openai provider records`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try Self.createDatabase(at: env.databaseURL)
        let now = Date(timeIntervalSince1970: 1_772_798_400)
        try Self.insertMessage(
            databaseURL: env.databaseURL, createdMs: Self.ms(now), cost: 1.5,
            model: "gpt-5.1-codex", providerID: "openai")
        try Self.insertMessage(
            databaseURL: env.databaseURL, createdMs: Self.ms(now), cost: 9,
            model: "glm-5.3-max", providerID: "nchc")
        try Self.insertMessage(
            databaseURL: env.databaseURL, createdMs: Self.ms(now), cost: 9,
            model: "claude-sonnet-4-5", providerID: "opencode-go")
        try Self.insertMessage(
            databaseURL: env.databaseURL, createdMs: Self.ms(now), cost: 9,
            model: "gpt-5.1", providerID: "openrouter")

        let loaded = try OpenCodeLocalUsageReader(databaseURLs: [env.databaseURL])
            .loadDailyReport(since: now.addingTimeInterval(-3600), until: now, calendar: .current)
        let result = try #require(loaded)
        let entry = try #require(result.report.data.first)
        #expect(result.report.data.count == 1)
        #expect(entry.costUSD == 1.5)
        #expect(entry.requestCount == 1)
        #expect(entry.modelsUsed == ["gpt-5.1-codex"])
    }

    @Test
    func `step finish parts win over message fallback without double counting`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try Self.createDatabase(at: env.databaseURL)
        let now = Date(timeIntervalSince1970: 1_772_798_400)
        let withParts = try Self.insertMessage(
            databaseURL: env.databaseURL, createdMs: Self.ms(now), cost: 5,
            model: "gpt-5.1-codex", providerID: "openai")
        try Self.insertStepFinishPart(
            databaseURL: env.databaseURL, messageID: withParts, createdMs: Self.ms(now), cost: 2,
            tokens: ["input": 10, "output": 5, "reasoning": 1, "cache": ["read": 4, "write": 0]])
        try Self.insertMessage(
            databaseURL: env.databaseURL, createdMs: Self.ms(now), cost: 3,
            model: "gpt-5.1-codex", providerID: "openai")

        let loaded = try OpenCodeLocalUsageReader(databaseURLs: [env.databaseURL])
            .loadDailyReport(since: now.addingTimeInterval(-3600), until: now, calendar: .current)
        let result = try #require(loaded)
        let entry = try #require(result.report.data.first)
        #expect(entry.costUSD == 5)
        #expect(entry.requestCount == 2)
        #expect(entry.inputTokens == 10)
        #expect(entry.outputTokens == 5)
        #expect(entry.reasoningTokens == 1)
        #expect(entry.cacheReadTokens == 4)
        #expect(entry.cacheCreationTokens == 0)
        // The message-level fallback row has no token metadata, so the day's aggregate total
        // is conservatively unknown even though the component dimensions merge additively.
        #expect(entry.totalTokens == nil)
    }

    @Test
    func `v2 session messages add new turns without double counting migrated ones`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try Self.createDatabase(at: env.databaseURL, includeSessionMessages: true)
        let now = Date(timeIntervalSince1970: 1_772_798_400)
        let migratedID = try Self.insertMessage(
            databaseURL: env.databaseURL, createdMs: Self.ms(now), cost: 3,
            model: "gpt-5.1-codex", providerID: "openai")
        try Self.insertSessionMessage(
            databaseURL: env.databaseURL, id: migratedID, createdMs: Self.ms(now), cost: 3,
            model: "gpt-5.1-codex")
        try Self.insertSessionMessage(
            databaseURL: env.databaseURL, createdMs: Self.ms(now), cost: 2,
            model: "gpt-5.2", tokens: ["input": 7, "output": 3, "total": 10])
        try Self.insertSessionMessage(
            databaseURL: env.databaseURL, createdMs: Self.ms(now), cost: 9,
            model: "glm-5.3-max", providerID: "nchc")

        let loaded = try OpenCodeLocalUsageReader(databaseURLs: [env.databaseURL])
            .loadDailyReport(since: now.addingTimeInterval(-3600), until: now, calendar: .current)
        let result = try #require(loaded)
        let entry = try #require(result.report.data.first)
        #expect(entry.costUSD == 5)
        #expect(entry.requestCount == 2)
        #expect(entry.modelsUsed?.sorted() == ["gpt-5.1-codex", "gpt-5.2"])
    }

    @Test
    func `v2 only database without legacy tables is read`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try Self.createV2OnlyDatabase(at: env.databaseURL)
        let now = Date(timeIntervalSince1970: 1_772_798_400)
        try Self.insertSessionMessage(
            databaseURL: env.databaseURL, createdMs: Self.ms(now), cost: 1,
            model: "gpt-5.1-codex", tokens: ["input": 2, "output": 1, "total": 3])

        let loaded = try OpenCodeLocalUsageReader(databaseURLs: [env.databaseURL])
            .loadDailyReport(since: now.addingTimeInterval(-3600), until: now, calendar: .current)
        let result = try #require(loaded)
        let entry = try #require(result.report.data.first)
        #expect(entry.costUSD == 1)
        #expect(entry.requestCount == 1)
        #expect(entry.totalTokens == 3)
    }

    @Test
    func `recorded zero cost keeps token history`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try Self.createDatabase(at: env.databaseURL)
        let now = Date(timeIntervalSince1970: 1_772_798_400)
        try Self.insertMessage(
            databaseURL: env.databaseURL, createdMs: Self.ms(now), cost: 0,
            model: "gpt-5.1-codex", providerID: "openai",
            tokens: ["input": 100, "output": 50, "total": 150])

        let loaded = try OpenCodeLocalUsageReader(databaseURLs: [env.databaseURL])
            .loadDailyReport(since: now.addingTimeInterval(-3600), until: now, calendar: .current)
        let result = try #require(loaded)
        let entry = try #require(result.report.data.first)
        #expect(entry.costUSD == 0)
        #expect(entry.totalTokens == 150)
    }

    @Test
    func `missing and non numeric cost rows are skipped`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try Self.createDatabase(at: env.databaseURL)
        let now = Date(timeIntervalSince1970: 1_772_798_400)
        try Self.insertMessage(
            databaseURL: env.databaseURL, createdMs: Self.ms(now), cost: 1,
            model: "gpt-5.1-codex", providerID: "openai")
        try Self.insertMessage(
            databaseURL: env.databaseURL, createdMs: Self.ms(now), cost: nil,
            model: "gpt-5.1-codex", providerID: "openai")
        try Self.insertRawMessage(
            databaseURL: env.databaseURL,
            json: "{\"providerID\":\"openai\",\"role\":\"assistant\",\"cost\":\"free\"}")

        let result = try OpenCodeLocalUsageReader(databaseURLs: [env.databaseURL])
            .loadDailyReport(since: now.addingTimeInterval(-3600), until: now, calendar: .current)
        let entry = try #require(result?.report.data.first)
        #expect(entry.requestCount == 1)
        #expect(entry.costUSD == 1)
    }

    @Test
    func `negative or overflowing token counts are dropped`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try Self.createDatabase(at: env.databaseURL)
        let now = Date(timeIntervalSince1970: 1_772_798_400)
        try Self.insertMessage(
            databaseURL: env.databaseURL, createdMs: Self.ms(now), cost: 1,
            model: "negative", providerID: "openai",
            tokens: ["input": -5, "output": 1, "total": -4])
        try Self.insertMessage(
            databaseURL: env.databaseURL, createdMs: Self.ms(now), cost: 1,
            model: "overflow", providerID: "openai",
            tokens: ["input": Int.max, "output": 1, "total": Int.max])

        let result = try OpenCodeLocalUsageReader(databaseURLs: [env.databaseURL])
            .loadDailyReport(since: now.addingTimeInterval(-3600), until: now, calendar: .current)
        let entry = try #require(result?.report.data.first)
        #expect(entry.requestCount == 2)
        #expect(entry.totalTokens == nil)
        #expect(entry.modelsUsed?.sorted() == ["negative", "overflow"])
    }

    @Test
    func `rows outside the requested window are excluded`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try Self.createDatabase(at: env.databaseURL)
        let now = Date(timeIntervalSince1970: 1_772_798_400)
        try Self.insertMessage(
            databaseURL: env.databaseURL, createdMs: Self.ms(now), cost: 1,
            model: "gpt-5.1-codex", providerID: "openai")
        try Self.insertMessage(
            databaseURL: env.databaseURL,
            createdMs: Self.ms(now.addingTimeInterval(-48 * 3600)), cost: 8,
            model: "gpt-5.1-codex", providerID: "openai")

        let result = try OpenCodeLocalUsageReader(databaseURLs: [env.databaseURL])
            .loadDailyReport(since: now.addingTimeInterval(-3600), until: now, calendar: .current)
        let entry = try #require(result?.report.data.first)
        #expect(entry.requestCount == 1)
        #expect(entry.costUSD == 1)
    }

    @Test
    func `missing database or empty history returns nil`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }

        #expect(try OpenCodeLocalUsageReader(databaseURLs: [env.databaseURL])
            .loadDailyReport(since: Date.distantPast, until: Date(), calendar: .current) == nil)

        try Self.createDatabase(at: env.databaseURL)
        try Self.insertMessage(
            databaseURL: env.databaseURL, createdMs: 1_772_798_400_000, cost: 9,
            model: "glm-5.3-max", providerID: "nchc")

        #expect(try OpenCodeLocalUsageReader(databaseURLs: [env.databaseURL])
            .loadDailyReport(since: Date.distantPast, until: Date(), calendar: .current) == nil)
    }

    @Test
    func `idle wal database without sidecars is still read`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try Self.createDatabase(at: env.databaseURL)
        let now = Date(timeIntervalSince1970: 1_772_798_400)
        try Self.insertMessage(
            databaseURL: env.databaseURL, createdMs: Self.ms(now), cost: 4,
            model: "gpt-5.1-codex", providerID: "openai")
        try Self.configureIdleWAL(at: env.databaseURL)

        let loaded = try OpenCodeLocalUsageReader(databaseURLs: [env.databaseURL])
            .loadDailyReport(since: now.addingTimeInterval(-3600), until: now, calendar: .current)
        let result = try #require(loaded)
        let entry = try #require(result.report.data.first)
        #expect(entry.costUSD == 4)
    }

    @Test
    func `active wal frames are read`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try Self.createDatabase(at: env.databaseURL)
        let now = Date(timeIntervalSince1970: 1_772_798_400)

        var writer = try Self.OpenWriter(url: env.databaseURL)
        defer { writer.close() }
        try writer.exec("PRAGMA journal_mode = WAL;")
        try writer.insertMessage(createdMs: Self.ms(now), cost: 6, model: "gpt-5.1-codex", providerID: "openai")
        // Keep the write transaction uncommitted... committed but un-checkpointed frames must be visible.
        try writer.exec("PRAGMA wal_checkpoint(PASSIVE);")

        let loaded = try OpenCodeLocalUsageReader(databaseURLs: [env.databaseURL])
            .loadDailyReport(since: now.addingTimeInterval(-3600), until: now, calendar: .current)
        let result = try #require(loaded)
        let entry = try #require(result.report.data.first)
        #expect(entry.costUSD == 6)
        #expect(entry.requestCount == 1)
    }

    @Test
    func `absolute OPENCODE_DB override is honored`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try Self.createDatabase(at: env.databaseURL)
        let now = Date(timeIntervalSince1970: 1_772_798_400)
        try Self.insertMessage(
            databaseURL: env.databaseURL, createdMs: Self.ms(now), cost: 2,
            model: "gpt-5.1-codex", providerID: "openai")

        let reader = OpenCodeLocalUsageReader(
            homeDirectory: env.root,
            environment: ["OPENCODE_DB": env.databaseURL.path])
        let loaded = try reader.loadDailyReport(
            since: now.addingTimeInterval(-3600), until: now, calendar: .current)
        let result = try #require(loaded)
        #expect(result.scope.databaseFilename == "opencode.db")
    }

    @Test
    func `channel database candidates are ordered before the default`() {
        let dataDirectory = URL(fileURLWithPath: "/tmp/opencode-data", isDirectory: true)
        let candidates = OpenCodeLocalUsageReader.candidateDatabaseURLs(
            dataDirectory: dataDirectory,
            environment: ["OPENCODE_UPDATE_CHANNEL": "canary"])
        #expect(candidates.map(\.lastPathComponent) == ["opencode-canary.db", "opencode.db"])

        let disabled = OpenCodeLocalUsageReader.candidateDatabaseURLs(
            dataDirectory: dataDirectory,
            environment: ["OPENCODE_UPDATE_CHANNEL": "canary", "OPENCODE_DISABLE_CHANNEL_DB": "1"])
        #expect(disabled.map(\.lastPathComponent) == ["opencode.db"])

        let stable = OpenCodeLocalUsageReader.candidateDatabaseURLs(
            dataDirectory: dataDirectory,
            environment: ["OPENCODE_UPDATE_CHANNEL": "latest"])
        #expect(stable.map(\.lastPathComponent) == ["opencode.db"])

        let relative = OpenCodeLocalUsageReader.candidateDatabaseURLs(
            dataDirectory: dataDirectory,
            environment: ["OPENCODE_DB": "custom.db"])
        #expect(relative.map(\.lastPathComponent) == ["custom.db"])
    }

    @Test
    func `scope fingerprint is stable for identical rows`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try Self.createDatabase(at: env.databaseURL)
        let now = Date(timeIntervalSince1970: 1_772_798_400)
        try Self.insertMessage(
            databaseURL: env.databaseURL, createdMs: Self.ms(now), cost: 1,
            model: "gpt-5.1-codex", providerID: "openai")

        let firstLoaded = try OpenCodeLocalUsageReader(databaseURLs: [env.databaseURL])
            .loadDailyReport(since: now.addingTimeInterval(-3600), until: now, calendar: .current)
        let first = try #require(firstLoaded)
        let secondLoaded = try OpenCodeLocalUsageReader(databaseURLs: [env.databaseURL])
            .loadDailyReport(since: now.addingTimeInterval(-3600), until: now, calendar: .current)
        let second = try #require(secondLoaded)
        #expect(first.scope == second.scope)

        try Self.insertMessage(
            databaseURL: env.databaseURL, createdMs: Self.ms(now), cost: 1,
            model: "gpt-5.1-codex", providerID: "openai")
        let thirdLoaded = try OpenCodeLocalUsageReader(databaseURLs: [env.databaseURL])
            .loadDailyReport(since: now.addingTimeInterval(-3600), until: now, calendar: .current)
        let third = try #require(thirdLoaded)
        #expect(first.scope != third.scope)
    }
}

extension OpenCodeLocalUsageReaderTests {
    private struct Environment {
        let root: URL
        let databaseURL: URL
    }

    private static func makeEnvironment() throws -> Environment {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenCodeLocalUsageReaderTests-\(UUID().uuidString)", isDirectory: true)
        let directory = root
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("share", isDirectory: true)
            .appendingPathComponent("opencode", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return Environment(root: root, databaseURL: directory.appendingPathComponent("opencode.db", isDirectory: false))
    }

    private static func createDatabase(
        at url: URL,
        includeParts: Bool = true,
        includeSessionMessages: Bool = false) throws
    {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw SQLiteTestError.open }
        defer { sqlite3_close(db) }
        try Self.exec(
            db: db,
            sql: """
                CREATE TABLE message (
                  id TEXT PRIMARY KEY,
                  session_id TEXT NOT NULL,
                  data TEXT NOT NULL,
                  time_created INTEGER,
                  time_updated INTEGER
                );
                CREATE TABLE part (
                  id TEXT PRIMARY KEY,
                  message_id TEXT NOT NULL,
                  session_id TEXT NOT NULL,
                  data TEXT NOT NULL,
                  time_created INTEGER,
                  time_updated INTEGER
                );
            """)
        if !includeParts {
            try Self.exec(db: db, sql: "DROP TABLE part")
        }
        if includeSessionMessages {
            try Self.exec(
                db: db,
                sql: """
                    CREATE TABLE session_message (
                      id TEXT PRIMARY KEY,
                      session_id TEXT NOT NULL,
                      type TEXT NOT NULL,
                      seq INTEGER NOT NULL,
                      time_created INTEGER NOT NULL,
                      time_updated INTEGER NOT NULL,
                      data TEXT NOT NULL
                    );
                """)
        }
    }

    private static func createV2OnlyDatabase(at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw SQLiteTestError.open }
        defer { sqlite3_close(db) }
        try Self.exec(
            db: db,
            sql: """
                CREATE TABLE session_message (
                  id TEXT PRIMARY KEY,
                  session_id TEXT NOT NULL,
                  type TEXT NOT NULL,
                  seq INTEGER NOT NULL,
                  time_created INTEGER NOT NULL,
                  time_updated INTEGER NOT NULL,
                  data TEXT NOT NULL
                );
            """)
    }

    private static func configureIdleWAL(at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw SQLiteTestError.open }
        do {
            try Self.exec(db: db, sql: "PRAGMA journal_mode = WAL; PRAGMA wal_checkpoint(TRUNCATE);")
        } catch {
            sqlite3_close(db)
            throw error
        }
        guard sqlite3_close(db) == SQLITE_OK else { throw SQLiteTestError.close }

        for suffix in ["-wal", "-shm"] {
            let sidecarURL = URL(fileURLWithPath: url.path + suffix)
            if FileManager.default.fileExists(atPath: sidecarURL.path) {
                try FileManager.default.removeItem(at: sidecarURL)
            }
        }
    }

    @discardableResult
    private static func insertMessage(
        databaseURL: URL,
        createdMs: Int64,
        cost: Double?,
        model: String? = nil,
        providerID: String = "openai",
        tokens: Any? = nil) throws -> String
    {
        let messageID = UUID().uuidString
        var payload: [String: Any] = [
            "providerID": providerID,
            "role": "assistant",
            "time": ["created": createdMs],
        ]
        if let cost {
            payload["cost"] = cost
        }
        if let model {
            payload["modelID"] = model
        }
        if let tokens {
            payload["tokens"] = tokens
        }
        try Self.insertRawMessage(databaseURL: databaseURL, id: messageID, createdMs: createdMs, json: Self.json(payload))
        return messageID
    }

    private static func insertRawMessage(
        databaseURL: URL,
        id: String = UUID().uuidString,
        createdMs: Int64 = 0,
        json: String) throws
    {
        var db: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK else { throw SQLiteTestError.open }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "INSERT INTO message (id, session_id, data, time_created, time_updated) VALUES (?, ?, ?, ?, ?)",
            -1,
            &stmt,
            nil) == SQLITE_OK
        else { throw SQLiteTestError.prepare }
        defer { sqlite3_finalize(stmt) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, id, -1, transient)
        sqlite3_bind_text(stmt, 2, "session-1", -1, transient)
        sqlite3_bind_text(stmt, 3, json, -1, transient)
        sqlite3_bind_int64(stmt, 4, createdMs)
        sqlite3_bind_int64(stmt, 5, createdMs)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteTestError.step }
    }

    private static func insertStepFinishPart(
        databaseURL: URL,
        messageID: String,
        createdMs: Int64,
        cost: Double,
        tokens: [String: Any] = ["input": 1, "output": 1, "total": 2]) throws
    {
        var db: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK else { throw SQLiteTestError.open }
        defer { sqlite3_close(db) }

        let payload: [String: Any] = [
            "type": "step-finish",
            "cost": cost,
            "tokens": tokens,
        ]

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "INSERT INTO part (id, message_id, session_id, data, time_created, time_updated) VALUES (?, ?, ?, ?, ?, ?)",
            -1,
            &stmt,
            nil) == SQLITE_OK
        else { throw SQLiteTestError.prepare }
        defer { sqlite3_finalize(stmt) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, UUID().uuidString, -1, transient)
        sqlite3_bind_text(stmt, 2, messageID, -1, transient)
        sqlite3_bind_text(stmt, 3, "session-1", -1, transient)
        sqlite3_bind_text(stmt, 4, Self.json(payload), -1, transient)
        sqlite3_bind_int64(stmt, 5, createdMs)
        sqlite3_bind_int64(stmt, 6, createdMs)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteTestError.step }
    }

    private static func insertSessionMessage(
        databaseURL: URL,
        id: String = UUID().uuidString,
        createdMs: Int64,
        cost: Double,
        model: String,
        providerID: String = "openai",
        tokens: [String: Any]? = nil) throws
    {
        var db: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK else { throw SQLiteTestError.open }
        defer { sqlite3_close(db) }

        var payload: [String: Any] = [
            "model": ["providerID": providerID, "id": model],
            "cost": cost,
            "time": ["created": createdMs],
        ]
        if let tokens {
            payload["tokens"] = tokens
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            """
            INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data)
            VALUES (?, ?, 'assistant', 0, ?, ?, ?)
            """,
            -1,
            &stmt,
            nil) == SQLITE_OK
        else { throw SQLiteTestError.prepare }
        defer { sqlite3_finalize(stmt) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, id, -1, transient)
        sqlite3_bind_text(stmt, 2, "session-1", -1, transient)
        sqlite3_bind_int64(stmt, 3, createdMs)
        sqlite3_bind_int64(stmt, 4, createdMs)
        sqlite3_bind_text(stmt, 5, Self.json(payload), -1, transient)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteTestError.step }
    }

    private static func json(_ payload: [String: Any]) -> String {
        let data = try? JSONSerialization.data(withJSONObject: payload)
        return String(data: data ?? Data(), encoding: .utf8) ?? "{}"
    }

    private static func exec(db: OpaquePointer?, sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
            sqlite3_free(message)
            throw SQLiteTestError.exec
        }
    }

    private static func ms(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1000)
    }

    private enum SQLiteTestError: Error {
        case close
        case open
        case prepare
        case step
        case exec
    }

    /// A database connection that stays open across WAL writes, exercising the reader's
    /// normal (non-immutable) open path against a live WAL.
    private struct OpenWriter {
        private var db: OpaquePointer?

        init(url: URL) throws {
            guard sqlite3_open(url.path, &self.db) == SQLITE_OK else { throw SQLiteTestError.open }
        }

        func exec(_ sql: String) throws {
            try OpenCodeLocalUsageReaderTests.exec(db: self.db, sql: sql)
        }

        func insertMessage(createdMs: Int64, cost: Double, model: String, providerID: String) throws {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                self.db,
                "INSERT INTO message (id, session_id, data, time_created, time_updated) VALUES (?, ?, ?, ?, ?)",
                -1,
                &stmt,
                nil) == SQLITE_OK
            else { throw SQLiteTestError.prepare }
            defer { sqlite3_finalize(stmt) }

            let payload: [String: Any] = [
                "providerID": providerID,
                "role": "assistant",
                "modelID": model,
                "cost": cost,
                "time": ["created": createdMs],
            ]
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(stmt, 1, UUID().uuidString, -1, transient)
            sqlite3_bind_text(stmt, 2, "session-1", -1, transient)
            sqlite3_bind_text(stmt, 3, OpenCodeLocalUsageReaderTests.json(payload), -1, transient)
            sqlite3_bind_int64(stmt, 4, createdMs)
            sqlite3_bind_int64(stmt, 5, createdMs)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteTestError.step }
        }

        mutating func close() {
            if let db {
                sqlite3_close(db)
            }
            self.db = nil
        }
    }
}

#endif
