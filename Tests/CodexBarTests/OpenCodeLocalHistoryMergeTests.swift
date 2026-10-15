import CodexBarCore
import Foundation
import SQLite3
import Testing

@testable import CodexBarCore

/// Gating tests for the opt-in machine-local OpenCode history source (#3273 contract):
/// it may only join the ambient Codex ledger, never scoped homes, other providers, or a
/// default-off configuration.
@Suite(.serialized)
struct OpenCodeLocalHistoryMergeTests {
    @Test
    func `ambient codex scan merges opt-in opencode local history`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        let databaseURL = try Self.makeOpenCodeDatabase(root: env.root, day: day)

        let scannerOptions = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"))
        let merged = try await CostUsageFetcher.loadTokenResult(
            provider: .codex,
            environment: ["OPENCODE_DB": databaseURL.path],
            now: day,
            historyDays: 1,
            allowPricingRefresh: false,
            includePiSessions: false,
            includeOpenCodeLocalHistory: true,
            scannerOptions: scannerOptions)

        #expect(merged.snapshot.last30DaysTokens == 35)
        // Recorded $0 cost (subscription usage) is preserved as-is, never reinterpreted.
        #expect(merged.snapshot.last30DaysCostUSD == 0)
    }

    @Test
    func `ambient codex scan stays native when the source is off`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        let databaseURL = try Self.makeOpenCodeDatabase(root: env.root, day: day)

        let scannerOptions = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"))
        let native = try await CostUsageFetcher.loadTokenResult(
            provider: .codex,
            environment: ["OPENCODE_DB": databaseURL.path],
            now: day,
            historyDays: 1,
            allowPricingRefresh: false,
            includePiSessions: false,
            includeOpenCodeLocalHistory: false,
            scannerOptions: scannerOptions)

        #expect((native.snapshot.last30DaysTokens ?? 0) == 0)
    }

    @Test
    func `scoped codex home never merges opencode local history`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        let databaseURL = try Self.makeOpenCodeDatabase(root: env.root, day: day)
        let scopedHome = env.root.appendingPathComponent("scoped-codex-home", isDirectory: true)
        try FileManager.default.createDirectory(at: scopedHome, withIntermediateDirectories: true)

        let scannerOptions = CostUsageScanner.Options(
            codexSessionsRoot: scopedHome.appendingPathComponent("sessions", isDirectory: true),
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"))
        let scoped = try await CostUsageFetcher.loadTokenResult(
            provider: .codex,
            environment: ["OPENCODE_DB": databaseURL.path],
            now: day,
            codexHomePath: scopedHome.path,
            historyDays: 1,
            allowPricingRefresh: false,
            includePiSessions: false,
            includeOpenCodeLocalHistory: true,
            scannerOptions: scannerOptions)

        #expect((scoped.snapshot.last30DaysTokens ?? 0) == 0)
    }

    @Test
    func `claude scans never merge opencode local history`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        let databaseURL = try Self.makeOpenCodeDatabase(root: env.root, day: day)

        let scannerOptions = CostUsageScanner.Options(
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"))
        let claude = try await CostUsageFetcher.loadTokenResult(
            provider: .claude,
            environment: ["OPENCODE_DB": databaseURL.path],
            now: day,
            historyDays: 1,
            allowPricingRefresh: false,
            includePiSessions: false,
            includeOpenCodeLocalHistory: true,
            scannerOptions: scannerOptions)

        #expect((claude.snapshot.last30DaysTokens ?? 0) == 0)
    }

    @Test
    func `cached codex publication merges opt-in opencode local history`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        let databaseURL = try Self.makeOpenCodeDatabase(root: env.root, day: day)

        let options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"))
        let scanTime = day.addingTimeInterval(-60)
        var cache = CostUsageCache()
        cache.lastScanUnixMs = Int64(scanTime.timeIntervalSince1970 * 1000)
        cache.scanSinceKey = "2026-04-07"
        cache.scanUntilKey = "2026-04-09"
        cache.timeZoneIdentifier = options.calendar.timeZone.identifier
        cache.roots = CostUsageScanner.codexRootsFingerprint(options: options)
        CostUsageStoreAccess.replace(
            cacheRoot: env.cacheRoot,
            cache: cache,
            calendar: options.calendar)

        let merged = await CostUsageFetcher.loadCachedCodexTokenSnapshotResult(
            now: day,
            historyDays: 1,
            includePiSessions: false,
            includeOpenCodeLocalHistory: true,
            scannerOptions: options,
            environment: ["OPENCODE_DB": databaseURL.path])
        #expect(merged?.snapshot.last30DaysTokens == 35)

        let native = await CostUsageFetcher.loadCachedCodexTokenSnapshotResult(
            now: day,
            historyDays: 1,
            includePiSessions: false,
            scannerOptions: options,
            environment: ["OPENCODE_DB": databaseURL.path])
        #expect(native?.snapshot.last30DaysTokens == 0)
    }

    @Test
    func `cached scoped codex publication stays native`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        let databaseURL = try Self.makeOpenCodeDatabase(root: env.root, day: day)
        let scopedHome = env.root.appendingPathComponent("scoped-codex-home", isDirectory: true)
        try FileManager.default.createDirectory(at: scopedHome, withIntermediateDirectories: true)

        let options = CostUsageScanner.Options(
            codexSessionsRoot: scopedHome.appendingPathComponent("sessions", isDirectory: true),
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"))
        var cache = CostUsageCache()
        cache.lastScanUnixMs = Int64(day.timeIntervalSince1970 * 1000)
        cache.scanSinceKey = "2026-04-07"
        cache.scanUntilKey = "2026-04-09"
        cache.timeZoneIdentifier = options.calendar.timeZone.identifier
        cache.roots = CostUsageScanner.codexRootsFingerprint(options: options)
        CostUsageStoreAccess.replace(
            cacheRoot: env.cacheRoot,
            cache: cache,
            calendar: options.calendar)

        let scoped = await CostUsageFetcher.loadCachedCodexTokenSnapshotResult(
            now: day,
            codexHomePath: scopedHome.path,
            historyDays: 1,
            allowScopedCodexHome: true,
            includePiSessions: false,
            includeOpenCodeLocalHistory: true,
            scannerOptions: options,
            environment: ["OPENCODE_DB": databaseURL.path])
        #expect((scoped?.snapshot.last30DaysTokens ?? 0) == 0)
    }

    /// Builds an OpenCode SQLite database with one `openai` assistant record (35 tokens,
    /// recorded $0 cost) plus one `nchc` record that must never be selected.
    private static func makeOpenCodeDatabase(root: URL, day: Date) throws -> URL {
        let databaseURL = root.appendingPathComponent("opencode-local.db", isDirectory: false)
        var db: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK else { throw SQLiteTestError.open }
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
            """)
        let createdMs = Int64(day.timeIntervalSince1970 * 1000)
        try Self.insertRow(
            db: db,
            json: Self.json([
                "providerID": "openai",
                "role": "assistant",
                "modelID": "gpt-5.1-codex",
                "cost": 0,
                "time": ["created": createdMs],
                "tokens": ["input": 30, "output": 5, "total": 35]]),
            createdMs: createdMs)
        try Self.insertRow(
            db: db,
            json: Self.json([
                "providerID": "nchc",
                "role": "assistant",
                "modelID": "glm-5.3-max",
                "cost": 9,
                "time": ["created": createdMs],
                "tokens": ["input": 900, "output": 90, "total": 990]]),
            createdMs: createdMs)
        return databaseURL
    }

    private static func insertRow(db: OpaquePointer?, json: String, createdMs: Int64) throws {
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
        sqlite3_bind_text(stmt, 1, UUID().uuidString, -1, transient)
        sqlite3_bind_text(stmt, 2, "session-1", -1, transient)
        sqlite3_bind_text(stmt, 3, json, -1, transient)
        sqlite3_bind_int64(stmt, 4, createdMs)
        sqlite3_bind_int64(stmt, 5, createdMs)
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

    private enum SQLiteTestError: Error {
        case open
        case prepare
        case step
        case exec
    }
}
