import Foundation

#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

/// The shared machine-local OpenCode history for assistant records whose provider is exactly
/// `openai`, consumed by every path of the ambient Codex ledger (#3273).
///
/// Architecture — the incremental-store shape requested in #4574/#4702's close comments,
/// adapted from the OpenCodex usage store's byte-cursor model to a SQLite source (which has
/// no byte offsets, but does have monotonically assigned rowids):
/// - **Row-level durable cache, windowed queries.** Decoded entries persist as indexed rows
///   in this store's own SQLite database (never Codex `cost-usage.sqlite`, never the
///   OpenCode Go reader's in-memory cache), and every read — cached publications included —
///   queries only the rows inside the requested window. Memory scales with the window, not
///   with history.
/// - **Cache-only publication.** Cached publications compare the persisted source identity
///   with the selected database path (a string comparison, no stat, no open) and then query
///   the cache; the OpenCode database is never touched.
/// - **Incremental, bounded ingestion.** Each source table keeps a `[low, high]` rowid
///   window of ingested rows. A scan costs one fingerprint stat (size, mtime, WAL size,
///   WAL mtime). When the fingerprint moved, ingestion reads only what the window is
///   missing: new rows above `high` (the common append case — a handful of rows), and, for
///   a first-ever pass on a database larger than the row budget, newest-first continuation
///   below `low` so partial passes still prioritize recent history. Late-arriving
///   `step-finish` parts are re-evaluated through a part rowid cursor. Rows persist by
///   stable source ID (part ID for part rows, message ID for fallback rows, session-message
///   ID for v2 rows), so every read is an idempotent upsert and no pass rewrites rows it
///   did not change. A raw table count that *shrank* (rows deleted) triggers a fresh
///   re-ingest; recorded costs are append-only event data upstream, so growth never
///   requires re-reading what the window already holds.
/// - The fingerprint is captured before the read and verified after; a read that observed a
///   moving source never marks itself complete, and cursors only advance to rows actually
///   read, so the next scan catches up regardless of where concurrent writes landed.
/// - Decode and write loops check cancellation every 512 rows; a cancelled pass throws and
///   its transaction rolls back whole, leaving no partial state.
///
/// Source contract (see issue #3273):
/// - Reads usage metadata only, with `SQLITE_OPEN_READONLY`. Prompts, responses, tool output
///   and `auth.json` are never read; rows are never attributed to an account.
/// - Selects only assistant records with an exact `providerID == "openai"` match.
/// - Counts valid `step-finish` parts when present (one entry per part, like the Go reader)
///   and falls back to message-level totals only when no valid parts exist.
/// - Deduplicates by stable IDs: OpenCode v2 copies legacy `message` rows into
///   `session_message` under the same IDs, so a v2 row only contributes its ID when the
///   legacy row is not itself usable (a legacy row with a missing or malformed cost
///   suppresses nothing), mirroring the Go reader's usable-legacy projection (#4587).
/// - Preserves recorded token dimensions. Recorded cost is surfaced as-is (OpenCode records
///   `$0` for subscription usage); dollars are never recomputed or reinterpreted here.
public struct OpenCodeLocalHistoryStore: Sendable {
    /// Versioned so a schema or identity change ships as a new filename and older builds
    /// keep working. v3 keys entries by part/message/session-message source ID.
    public static let cacheDatabaseFilename = "opencode-local-history-v3.sqlite"

    /// Default soft row budget for one ingestion pass. A normal database completes in a
    /// single pass; a pathological one resumes from its window on the next scan instead of
    /// stalling the refresh, mirroring how the Codex scanner defers files beyond its byte
    /// budget. Injectable so tests can exercise multi-pass convergence.
    public static let defaultIngestionRowBudget = 100_000

    private let databaseURL: URL
    private let cacheURL: URL
    private let ingestionRowBudget: Int

    public init(
        cacheRoot: URL? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment)
    {
        let dataRoot = Self.xdgDataRoot(homeDirectory: homeDirectory, environment: environment)
        let openCodeDirectory = dataRoot.appendingPathComponent("opencode", isDirectory: true)
        self.databaseURL = Self.primaryDatabaseURL(dataDirectory: openCodeDirectory, environment: environment)
        self.cacheURL = Self.resolvedCacheRoot(cacheRoot)
            .appendingPathComponent(Self.cacheDatabaseFilename, isDirectory: false)
        self.ingestionRowBudget = Self.defaultIngestionRowBudget
    }

    public init(
        databaseURL: URL,
        cacheURL: URL,
        ingestionRowBudget: Int = OpenCodeLocalHistoryStore.defaultIngestionRowBudget)
    {
        self.databaseURL = databaseURL
        self.cacheURL = cacheURL
        self.ingestionRowBudget = ingestionRowBudget
    }

    /// The store's own cache directory: a dedicated `opencode-local-history` directory under
    /// the supplied cache root (or the CodexBar caches directory), so every ambient caller
    /// converges on one location regardless of which root it passes, and "clear cost cache"
    /// has a single directory to cover.
    static func resolvedCacheRoot(_ cacheRoot: URL?) -> URL {
        let base = cacheRoot ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("CodexBar", isDirectory: true)
        return (base ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("opencode-local-history", isDirectory: true)
    }

    // MARK: - Reads

    /// A windowed report for the scan path. The OpenCode database is opened only when its
    /// fingerprint changed since the persisted ingestion; otherwise the cached rows are
    /// queried directly. `nil` means there is no matching history. Only genuine SQLite read
    /// failures throw; a missing or empty OpenCode installation never disrupts the native
    /// Codex scan.
    public func loadDailyReport(since: Date, until: Date, calendar: Calendar) throws -> CostUsageDailyReport? {
        guard FileManager.default.fileExists(atPath: self.databaseURL.path) else {
            try? self.removeAllCachedEntries()
            return nil
        }
        if self.cacheIsCurrent() {
            return try self.cachedDailyReport(since: since, until: until, calendar: calendar)
        }
        try self.ingest()
        return try self.cachedDailyReport(since: since, until: until, calendar: calendar)
    }

    /// A windowed report for cached publications: compares the persisted source identity
    /// with the selected database path (a string comparison) and queries only the rows in
    /// the requested window — no database access at all, not even a fingerprint stat
    /// (#3273 cache-only publication). `nil` when nothing usable is cached; the next scan
    /// refreshes the cache and its fingerprint gate decides whether the rows are current.
    public func cachedDailyReport(since: Date, until: Date, calendar: Calendar) -> CostUsageDailyReport? {
        guard FileManager.default.fileExists(atPath: self.cacheURL.path) else { return nil }
        do {
            return try CacheDatabase.withDatabase(at: self.cacheURL) { db in
                guard let state = try Self.cacheState(in: db),
                      state.matchesSelectedSource(self.databaseURL)
                else { return nil }
                let entries = try self.queryEntries(
                    since: since,
                    until: until,
                    calendar: calendar,
                    in: db)
                return Self.windowedReport(entries: entries, since: since, until: until, calendar: calendar)
            }
        } catch {
            // A damaged disposable cache is a rebuildable miss, never a silent omission.
            try? FileManager.default.removeItem(at: self.cacheURL)
            return nil
        }
    }

    /// Removes persisted rows and state. Called when the setting turns off so stale rows
    /// can never surface again.
    public func removeAllCachedEntries() throws {
        try CacheDatabase.withDatabase(at: self.cacheURL) { db in
            try CacheDatabase.execute(db, "BEGIN IMMEDIATE")
            try CacheDatabase.execute(db, "DELETE FROM entries")
            try CacheDatabase.execute(db, "DELETE FROM meta")
            try CacheDatabase.execute(db, "COMMIT")
        }
    }

    // MARK: - Entry model

    /// One decoded assistant turn. Compact by design: rows persist individually and only the
    /// requested window is ever loaded into memory.
    struct Entry: Equatable, Sendable {
        let sourceID: String
        let createdMs: Int64
        let costUSD: Double
        /// The model OpenCode recorded for the turn; empty when unattributed.
        let modelID: String
        let totalTokens: Int?
        let inputTokens: Int?
        let outputTokens: Int?
        let reasoningTokens: Int?
        let cacheReadTokens: Int?
        let cacheCreationTokens: Int?
    }

    // MARK: - Windowing

    /// Buckets entries into calendar-day rows keyed by the reporting calendar, matching how
    /// native Codex history is keyed, so they merge consistently with it. Windowing happens
    /// here, at read time, from the queried rows — the store never retains a pre-windowed
    /// report.
    static func windowedReport(
        entries: [Entry],
        since: Date,
        until: Date,
        calendar: Calendar) -> CostUsageDailyReport?
    {
        // Normalize the lower bound to the reporting day's start: the foreground scan passes
        // a `now`-anchored window, and a clock-time bound would drop earlier-today turns.
        let sinceStartMs = Int64(calendar.startOfDay(for: since).timeIntervalSince1970 * 1000)
        let untilMs = Int64(until.timeIntervalSince1970 * 1000)
        var dayEntries: [String: CostUsageDailyReport.Entry] = [:]
        for entry in entries {
            guard entry.createdMs >= sinceStartMs, entry.createdMs <= untilMs else { continue }
            let date = Date(timeIntervalSince1970: TimeInterval(entry.createdMs) / 1000)
            let key = CostUsageScanner.CostUsageDayRange.dayKey(from: date, calendar: calendar)
            let day = dayEntries[key] ?? CostUsageDailyReport.Entry(
                date: key,
                inputTokens: 0,
                outputTokens: 0,
                totalTokens: 0,
                requestCount: 0,
                costUSD: 0,
                modelsUsed: [],
                modelBreakdowns: [],
                costIsSourceRecorded: true)
            let breakdown = Self.breakdown(for: entry, existing: day.modelBreakdowns ?? [])
            dayEntries[key] = CostUsageDailyReport.Entry(
                date: key,
                inputTokens: Self.sum(day.inputTokens, entry.inputTokens),
                outputTokens: Self.sum(day.outputTokens, entry.outputTokens),
                cacheReadTokens: Self.sum(day.cacheReadTokens, entry.cacheReadTokens),
                cacheCreationTokens: Self.sum(day.cacheCreationTokens, entry.cacheCreationTokens),
                reasoningTokens: Self.sum(day.reasoningTokens, entry.reasoningTokens),
                totalTokens: Self.totalSum(day.totalTokens, entry.totalTokens),
                requestCount: (day.requestCount ?? 0) + 1,
                costUSD: (day.costUSD ?? 0) + entry.costUSD,
                modelsUsed: Array((day.modelsUsed ?? []) + [breakdown.modelName]).sorted(),
                modelBreakdowns: (day.modelBreakdowns ?? [])
                    .filter { $0.modelName != breakdown.modelName } + [breakdown],
                // The cost comes from OpenCode's own records, not list-price estimation.
                costIsSourceRecorded: true)
        }
        guard !dayEntries.isEmpty else { return nil }
        return CostUsageDailyReport(
            data: dayEntries.values.sorted { $0.date < $1.date },
            summary: nil)
    }

    private static func breakdown(
        for entry: Entry,
        existing: [CostUsageDailyReport.ModelBreakdown]) -> CostUsageDailyReport.ModelBreakdown
    {
        let trimmed = entry.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseModel = trimmed.isEmpty ? "unknown" : trimmed
        // Keep the source visible (#3273 contract): rows stay identifiable as OpenCode
        // local history in UI model breakdowns and CLI JSON instead of silently merging
        // into native model totals.
        let model = "\(baseModel) (OpenCode local)"
        if let match = existing.first(where: { $0.modelName == model }) {
            return CostUsageDailyReport.ModelBreakdown(
                modelName: model,
                costUSD: (match.costUSD ?? 0) + entry.costUSD,
                totalTokens: Self.totalSum(match.totalTokens, entry.totalTokens),
                requestCount: (match.requestCount ?? 0) + 1,
                inputTokens: Self.sum(match.inputTokens, entry.inputTokens),
                outputTokens: Self.sum(match.outputTokens, entry.outputTokens),
                cacheReadTokens: Self.sum(match.cacheReadTokens, entry.cacheReadTokens),
                cacheCreationTokens: Self.sum(match.cacheCreationTokens, entry.cacheCreationTokens),
                reasoningTokens: Self.sum(match.reasoningTokens, entry.reasoningTokens))
        }
        return CostUsageDailyReport.ModelBreakdown(
            modelName: model,
            costUSD: entry.costUSD,
            totalTokens: entry.totalTokens,
            requestCount: 1,
            inputTokens: entry.inputTokens,
            outputTokens: entry.outputTokens,
            cacheReadTokens: entry.cacheReadTokens,
            cacheCreationTokens: entry.cacheCreationTokens,
            reasoningTokens: entry.reasoningTokens)
    }

    /// The day's total is conservatively unknown when any contributing turn lacks one,
    /// mirroring how native Codex history aggregates days with mixed token evidence.
    private static func totalSum(_ lhs: Int?, _ rhs: Int?) -> Int? {
        guard let l = lhs, let r = rhs else { return nil }
        let (total, overflow) = l.addingReportingOverflow(r)
        return overflow ? nil : total
    }

    private static func sum(_ lhs: Int?, _ rhs: Int?) -> Int? {
        switch (lhs, rhs) {
        case let (l?, r?):
            let (total, overflow) = l.addingReportingOverflow(r)
            return overflow ? nil : total
        case let (l?, nil): return l
        case let (nil, r?): return r
        case (nil, nil): return nil
        }
    }

    // MARK: - Cache state

    private struct CacheState: Sendable {
        let sourcePath: String
        let fingerprint: DatabaseFingerprint
        let ingestComplete: Bool
        /// The `[low, high]` ingested rowid window per source table. `low == 0` means
        /// everything below is ingested; `high` is the inclusive re-read boundary above.
        let messageLow: Int64
        let messageHigh: Int64
        let sessionMessageLow: Int64
        let sessionMessageHigh: Int64
        /// Part re-evaluation cursor: parts at or above this rowid still need their
        /// messages re-evaluated (late-arriving step-finish parts).
        let partHigh: Int64
        /// Raw table row counts at ingestion time; a shrink means rows were deleted.
        let messageCount: Int64
        let partCount: Int64
        let sessionMessageCount: Int64

        /// Cache-only source validation: the persisted identity must name the database this
        /// store selected. A string comparison — the source is never opened or statted.
        func matchesSelectedSource(_ url: URL) -> Bool {
            self.sourcePath == url.resolvingSymlinksInPath().path
        }

        func matchesFingerprint(_ fingerprint: DatabaseFingerprint?) -> Bool {
            guard let fingerprint else { return false }
            return fingerprint == self.fingerprint
        }
    }

    /// True when the persisted rows were fully ingested from the current state of the
    /// selected database. A stat of the source — the only I/O a current cache costs a scan.
    private func cacheIsCurrent() -> Bool {
        guard let state = self.readCacheState(),
              state.ingestComplete,
              state.matchesSelectedSource(self.databaseURL),
              state.matchesFingerprint(DatabaseFingerprint.current(for: self.databaseURL))
        else { return false }
        return true
    }

    private static func cacheState(in db: OpaquePointer?) throws -> CacheState? {
        guard let sourcePath = try CacheDatabase.stringValue(db, "SELECT value FROM meta WHERE key = 'sourcePath'"),
              let fingerprintJSON = try CacheDatabase.stringValue(
                  db,
                  "SELECT value FROM meta WHERE key = 'fingerprint'"),
              let fingerprintData = Data(base64Encoded: fingerprintJSON),
              let fingerprint = try? JSONDecoder().decode(DatabaseFingerprint.self, from: fingerprintData)
        else { return nil }
        func intMeta(_ key: String) -> Int64 {
            (try? CacheDatabase.stringValue(db, "SELECT value FROM meta WHERE key = '\(key)'"))
                .flatMap(Int64.init) ?? 0
        }
        return CacheState(
            sourcePath: sourcePath,
            fingerprint: fingerprint,
            ingestComplete: (try CacheDatabase.stringValue(db, "SELECT value FROM meta WHERE key = 'ingestComplete'")) == "1",
            messageLow: intMeta("messageLow"),
            messageHigh: intMeta("messageHigh"),
            sessionMessageLow: intMeta("sessionMessageLow"),
            sessionMessageHigh: intMeta("sessionMessageHigh"),
            partHigh: intMeta("partHigh"),
            messageCount: intMeta("messageCount"),
            partCount: intMeta("partCount"),
            sessionMessageCount: intMeta("sessionMessageCount"))
    }

    private func readCacheState() -> CacheState? {
        guard FileManager.default.fileExists(atPath: self.cacheURL.path) else { return nil }
        do {
            return try CacheDatabase.withDatabase(at: self.cacheURL) { db in
                try Self.cacheState(in: db)
            }
        } catch {
            // A damaged disposable cache is a rebuildable miss, never a reason to silently
            // omit OpenCode history forever: drop it so the next scan starts clean.
            try? FileManager.default.removeItem(at: self.cacheURL)
            return nil
        }
    }

    // MARK: - Ingestion

    /// Advances the durable cache toward the current state of the selected database using
    /// the persisted `[low, high]` rowid windows. See the type documentation for the
    /// incremental contract; every step is an idempotent upsert keyed by source ID.
    private func ingest() throws {
        // The fingerprint must bracket the read: capture it before any row is decoded.
        guard let before = DatabaseFingerprint.current(for: self.databaseURL) else { return }
        let cached = self.readCacheState()

        try Self.withSourceDatabase(at: self.databaseURL) { db, tables in
            let counts = Self.rawCounts(db, tables: tables)
            // A fresh pass starts when there is no reusable window, the source moved, or a
            // table shrank (rows deleted — the append windows would keep deleted rows
            // alive). Fresh windows begin at the newest rows so partial, budgeted passes
            // still prioritize recent history.
            let fresh = cached.map { state in
                !state.matchesSelectedSource(self.databaseURL)
                    || counts.message < state.messageCount
                    || counts.part < state.partCount
                    || counts.sessionMessage < state.sessionMessageCount
            } ?? true

            var messageLow: Int64
            var messageHigh: Int64
            var sessionMessageLow: Int64
            var sessionMessageHigh: Int64
            var partHigh: Int64
            if fresh {
                messageHigh = (tables.hasMessage ? Self.maxRowid(db, table: "message") : 0) + 1
                sessionMessageHigh = (tables.hasSessionMessages ? Self.maxRowid(db, table: "session_message") : 0) + 1
                // Nothing below the newest rows is ingested yet; continuation passes walk
                // downward from here.
                messageLow = messageHigh
                sessionMessageLow = sessionMessageHigh
                // The newest messages are read with all their parts (the message query
                // joins parts), so part re-evaluation only needs to watch for parts that
                // arrive after this pass.
                partHigh = (tables.hasParts ? Self.maxRowid(db, table: "part") : 0) + 1
            } else if let state = cached {
                messageLow = state.messageLow
                messageHigh = state.messageHigh
                sessionMessageLow = state.sessionMessageLow
                sessionMessageHigh = state.sessionMessageHigh
                partHigh = state.partHigh
            } else {
                return
            }

            var remaining = self.ingestionRowBudget
            var exhausted = true
            var budgetSkippedAStep = false
            var entries: [Entry] = []

            // Each step runs only while budget remains; a skipped step leaves work for the
            // next pass. `wiped` defers to the transactional wipe inside `persist` so a
            // cancelled pass never leaves the cache emptied but not repopulated.
            let wiped = fresh

            // 1. New messages above the window (the common append case).
            if tables.hasMessage {
                if remaining > 0 {
                    let result = try Self.readMessageEntries(
                        db,
                        tables: tables,
                        rowidFilter: "rowid >= \(messageHigh)",
                        ascending: true,
                        limit: remaining + 1,
                        boundary: messageHigh)
                    entries.append(contentsOf: result.entries)
                    // Exhausted reads advance past the last row only via max rowid, so the
                    // boundary can never drift above rows that a later append might reuse.
                    messageHigh = result.exhausted
                        ? Self.maxRowid(db, table: "message") + 1
                        : result.cursor
                    exhausted = exhausted && result.exhausted
                    remaining -= result.entries.count
                } else {
                    budgetSkippedAStep = true
                }
            }
            // 2. Late-arriving parts: re-evaluate the messages they belong to.
            var reevaluatedMessageIDs: [String] = []
            if tables.hasParts {
                if remaining > 0 {
                    let result = try Self.readNewPartMessageIDs(
                        db,
                        partCursor: partHigh,
                        limit: remaining + 1)
                    if !result.ids.isEmpty {
                        reevaluatedMessageIDs = result.ids
                        let reevaluated = try Self.readMessageEntries(
                            db,
                            tables: tables,
                            idFilter: result.ids,
                            limit: remaining + 1,
                            boundary: partHigh)
                        entries.append(contentsOf: reevaluated.entries)
                        remaining -= reevaluated.entries.count
                    }
                    partHigh = result.exhausted
                        ? Self.maxRowid(db, table: "part") + 1
                        : result.cursor
                    exhausted = exhausted && result.exhausted
                } else {
                    budgetSkippedAStep = true
                }
            }
            // 3. New v2 session messages above the window.
            if tables.hasSessionMessages {
                if remaining > 0 {
                    let result = try Self.readSessionMessageEntries(
                        db,
                        tables: tables,
                        rowidFilter: "rowid >= \(sessionMessageHigh)",
                        ascending: true,
                        limit: remaining + 1,
                        boundary: sessionMessageHigh)
                    entries.append(contentsOf: result.entries)
                    sessionMessageHigh = result.exhausted
                        ? Self.maxRowid(db, table: "session_message") + 1
                        : result.cursor
                    exhausted = exhausted && result.exhausted
                    remaining -= result.entries.count
                } else {
                    budgetSkippedAStep = true
                }
            }
            // 4. Continue an incomplete pass downward (older rows), newest first.
            if tables.hasMessage, messageLow > 0 {
                if remaining > 0 {
                    let result = try Self.readMessageEntries(
                        db,
                        tables: tables,
                        rowidFilter: "rowid <= \(messageLow)",
                        ascending: false,
                        limit: remaining + 1,
                        boundary: messageLow)
                    entries.append(contentsOf: result.entries)
                    messageLow = result.exhausted ? 0 : result.cursor
                    exhausted = exhausted && result.exhausted
                    remaining -= result.entries.count
                } else {
                    budgetSkippedAStep = true
                }
            }
            if tables.hasSessionMessages, sessionMessageLow > 0 {
                if remaining > 0 {
                    let result = try Self.readSessionMessageEntries(
                        db,
                        tables: tables,
                        rowidFilter: "rowid <= \(sessionMessageLow)",
                        ascending: false,
                        limit: remaining + 1,
                        boundary: sessionMessageLow)
                    entries.append(contentsOf: result.entries)
                    sessionMessageLow = result.exhausted ? 0 : result.cursor
                    exhausted = exhausted && result.exhausted
                    remaining -= result.entries.count
                } else {
                    budgetSkippedAStep = true
                }
            }

            var complete = !budgetSkippedAStep
                && exhausted
                && (!tables.hasMessage || messageLow <= 0)
                && (!tables.hasSessionMessages || sessionMessageLow <= 0)

            // A write that landed mid-read would leave the persisted fingerprint describing
            // a state the rows do not fully cover. Only a stable before/after pair may
            // complete; the cursors themselves only advanced to rows actually read, so the
            // next pass catches up either way.
            let after = DatabaseFingerprint.current(for: self.databaseURL)
            if before != after {
                complete = false
            }

            try self.persist(
                entries: entries,
                fingerprint: after ?? before,
                complete: complete,
                messageLow: messageLow,
                messageHigh: messageHigh,
                sessionMessageLow: sessionMessageLow,
                sessionMessageHigh: sessionMessageHigh,
                partHigh: partHigh,
                counts: counts,
                wiped: wiped,
                purgeSourceIDs: reevaluatedMessageIDs)
        }
    }

    private func persist(
        entries: [Entry],
        fingerprint: DatabaseFingerprint,
        complete: Bool,
        messageLow: Int64,
        messageHigh: Int64,
        sessionMessageLow: Int64,
        sessionMessageHigh: Int64,
        partHigh: Int64,
        counts: SourceCounts,
        wiped: Bool,
        purgeSourceIDs: [String] = []) throws
    {
        try CacheDatabase.withDatabase(at: self.cacheURL) { db in
            try CacheDatabase.execute(db, "BEGIN IMMEDIATE")
            if wiped {
                try CacheDatabase.execute(db, "DELETE FROM entries")
            }
            if !purgeSourceIDs.isEmpty {
                // Re-evaluated messages drop their cached fallback row first: a message
                // that gained a valid step-finish part must not keep both the fallback
                // (keyed by message ID) and the part row (keyed by part ID).
                let ids = purgeSourceIDs.map { "'\(Self.escaped($0))'" }.joined(separator: ", ")
                try CacheDatabase.execute(db, "DELETE FROM entries WHERE sourceID IN (\(ids))")
            }
            for (index, entry) in entries.enumerated() {
                // Same cancellation budget as the decode loop; a throw rolls the whole
                // transaction back, so a cancelled pass leaves no partial state.
                if index % 512 == 0, Task.isCancelled {
                    throw CancellationError()
                }
                try CacheDatabase.execute(db, Self.insertSQL(for: entry))
            }
            func meta(_ key: String, _ value: Int64) throws {
                try CacheDatabase.execute(db, "INSERT OR REPLACE INTO meta (key, value) VALUES ('\(key)', '\(value)')")
            }
            let fingerprintJSON = try JSONEncoder().encode(fingerprint).base64EncodedString()
            try CacheDatabase.execute(
                db,
                "INSERT OR REPLACE INTO meta (key, value) VALUES ('sourcePath', '\(Self.escaped(fingerprint.path))')")
            try CacheDatabase.execute(
                db,
                "INSERT OR REPLACE INTO meta (key, value) VALUES ('fingerprint', '\(fingerprintJSON)')")
            try CacheDatabase.execute(
                db,
                "INSERT OR REPLACE INTO meta (key, value) VALUES ('ingestComplete', '\(complete ? 1 : 0)')")
            try meta("messageLow", messageLow)
            try meta("messageHigh", messageHigh)
            try meta("sessionMessageLow", sessionMessageLow)
            try meta("sessionMessageHigh", sessionMessageHigh)
            try meta("partHigh", partHigh)
            try meta("messageCount", counts.message)
            try meta("partCount", counts.part)
            try meta("sessionMessageCount", counts.sessionMessage)
            try CacheDatabase.execute(db, "COMMIT")
        }
    }

    private static func insertSQL(for entry: Entry) -> String {
        """
        INSERT OR REPLACE INTO entries (
          sourceID, createdMs, costUSD, modelID,
          totalTokens, inputTokens, outputTokens, reasoningTokens, cacheReadTokens, cacheCreationTokens
        ) VALUES (
          '\(escaped(entry.sourceID))', \(entry.createdMs), \(entry.costUSD), '\(escaped(entry.modelID))',
          \(entry.totalTokens.map(String.init) ?? "NULL"), \(entry.inputTokens.map(String.init) ?? "NULL"),
          \(entry.outputTokens.map(String.init) ?? "NULL"), \(entry.reasoningTokens.map(String.init) ?? "NULL"),
          \(entry.cacheReadTokens.map(String.init) ?? "NULL"), \(entry.cacheCreationTokens.map(String.init) ?? "NULL")
        )
        """
    }

    private static func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    // MARK: - Windowed cache queries

    private func queryEntries(
        since: Date,
        until: Date,
        calendar: Calendar,
        in db: OpaquePointer?) throws -> [Entry]
    {
        let sinceStartMs = Int64(calendar.startOfDay(for: since).timeIntervalSince1970 * 1000)
        let untilMs = Int64(until.timeIntervalSince1970 * 1000)
        let sql = """
            SELECT sourceID, createdMs, costUSD, modelID,
              totalTokens, inputTokens, outputTokens, reasoningTokens, cacheReadTokens, cacheCreationTokens
            FROM entries
            WHERE createdMs >= \(sinceStartMs) AND createdMs <= \(untilMs)
            ORDER BY createdMs
            """
        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard prepareResult == SQLITE_OK else {
            throw OpenCodeLocalHistorySQLiteFailure(db: db, resultCode: prepareResult)
        }
        defer { _ = sqlite3_finalize(stmt) }
        var entries: [Entry] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE {
                break
            }
            guard step == SQLITE_ROW else {
                throw OpenCodeLocalHistorySQLiteFailure(db: db, resultCode: step)
            }
            let sourceID = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let createdMs = sqlite3_column_int64(stmt, 1)
            let cost = sqlite3_column_double(stmt, 2)
            let modelID = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
            entries.append(Entry(
                sourceID: sourceID,
                createdMs: createdMs,
                costUSD: cost,
                modelID: modelID,
                totalTokens: Self.columnInt(stmt, 4),
                inputTokens: Self.columnInt(stmt, 5),
                outputTokens: Self.columnInt(stmt, 6),
                reasoningTokens: Self.columnInt(stmt, 7),
                cacheReadTokens: Self.columnInt(stmt, 8),
                cacheCreationTokens: Self.columnInt(stmt, 9)))
        }
        return entries
    }

    private static func columnInt(_ stmt: OpaquePointer?, _ index: Int32) -> Int? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        let value = sqlite3_column_int64(stmt, index)
        return Int(exactly: value)
    }

    // MARK: - Database fingerprint

    /// Mirrors the OpenCode Go reader's fingerprint: the main database plus its WAL sidecar,
    /// so WAL appends invalidate the cache without a checkpoint.
    struct DatabaseFingerprint: Codable, Equatable, Sendable {
        let path: String
        let size: UInt64
        let modificationDate: Date
        let walSize: UInt64?
        let walModificationDate: Date?

        static func current(for url: URL) -> Self? {
            let url = url.resolvingSymlinksInPath()
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? UInt64,
                  let mtime = attrs[.modificationDate] as? Date
            else { return nil }
            let walAttrs = try? FileManager.default.attributesOfItem(atPath: url.path + "-wal")
            return Self(
                path: url.path,
                size: size,
                modificationDate: mtime,
                walSize: walAttrs?[.size] as? UInt64,
                walModificationDate: walAttrs?[.modificationDate] as? Date)
        }
    }

    // MARK: - Environment resolution

    /// Resolves the XDG data root the way OpenCode's `xdg-basedir` dependency does: an
    /// absolute `XDG_DATA_HOME` wins; relative or missing values fall back to `~/.local/share`.
    static func xdgDataRoot(homeDirectory: URL, environment: [String: String]) -> URL {
        if let raw = Self.cleaned(environment["XDG_DATA_HOME"]),
           raw.hasPrefix("/")
        {
            return URL(fileURLWithPath: raw, isDirectory: true)
        }
        return homeDirectory
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("share", isDirectory: true)
    }

    /// Resolves the single database OpenCode itself would use, mirroring upstream
    /// `database.path()`: `OPENCODE_DB` selects exactly one database (`:memory:` is in-memory
    /// history an on-disk reader cannot see; absolute paths win as-is; relative names resolve
    /// inside the data directory) and is never substituted with another database. Without an
    /// explicit selection, upstream derives the channel from a build-time constant, which an
    /// external reader cannot observe — release channels and the
    /// `OPENCODE_DISABLE_CHANNEL_DB` opt-out all select the plain database, so that is the
    /// contract's selection here. Non-release channel databases stay reachable through
    /// `OPENCODE_DB`, exactly like pointing OpenCode itself at them.
    static func primaryDatabaseURL(
        dataDirectory: URL,
        environment: [String: String]) -> URL
    {
        if let override = Self.cleaned(environment["OPENCODE_DB"]) {
            if override == ":memory:" {
                return dataDirectory.appendingPathComponent("unreachable-memory-db", isDirectory: false)
            }
            if override.hasPrefix("/") {
                return URL(fileURLWithPath: override)
            }
            return dataDirectory.appendingPathComponent(override, isDirectory: false)
        }
        return dataDirectory.appendingPathComponent("opencode.db", isDirectory: false)
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

#if canImport(SQLite3) || canImport(CSQLite3)

// MARK: - SQLite helpers

enum CacheDatabase {
    static func withDatabase<T>(at url: URL, _ body: (OpaquePointer?) throws -> T) throws -> T {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var db: OpaquePointer?
        let openResult = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard openResult == SQLITE_OK, db != nil else {
            let failure = OpenCodeLocalHistorySQLiteFailure(db: db, resultCode: openResult)
            if let db {
                _ = sqlite3_close(db)
            }
            throw failure
        }
        defer { _ = sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)
        try Self.execute(db, """
            CREATE TABLE IF NOT EXISTS entries (
              sourceID TEXT NOT NULL PRIMARY KEY,
              createdMs INTEGER NOT NULL,
              costUSD REAL NOT NULL,
              modelID TEXT NOT NULL,
              totalTokens INTEGER,
              inputTokens INTEGER,
              outputTokens INTEGER,
              reasoningTokens INTEGER,
              cacheReadTokens INTEGER,
              cacheCreationTokens INTEGER
            )
            """)
        try Self.execute(db, "CREATE INDEX IF NOT EXISTS entries_created ON entries(createdMs)")
        try Self.execute(db, """
            CREATE TABLE IF NOT EXISTS meta (
              key TEXT PRIMARY KEY,
              value TEXT NOT NULL
            )
            """)
        return try body(db)
    }

    static func execute(_ db: OpaquePointer?, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw OpenCodeLocalHistorySQLiteFailure(db: db, resultCode: sqlite3_errcode(db))
        }
    }

    static func stringValue(_ db: OpaquePointer?, _ sql: String) throws -> String? {
        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard prepareResult == SQLITE_OK else {
            throw OpenCodeLocalHistorySQLiteFailure(db: db, resultCode: prepareResult)
        }
        defer { _ = sqlite3_finalize(stmt) }
        let step = sqlite3_step(stmt)
        guard step == SQLITE_ROW else { return nil }
        guard let text = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: text)
    }
}

struct OpenCodeLocalHistorySQLiteFailure: Error {
    let code: Int32
    let message: String

    init(db: OpaquePointer?, resultCode: Int32) {
        self.code = resultCode
        self.message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite failure"
    }
}

// MARK: - OpenCode database reading

extension OpenCodeLocalHistoryStore {
    struct SourceTables {
        let hasMessage: Bool
        let hasParts: Bool
        let hasSessionMessages: Bool
    }

    struct SourceCounts: Sendable {
        let message: Int64
        let part: Int64
        let sessionMessage: Int64
    }

    struct SourceRead {
        let entries: [Entry]
        /// The rowid cursor the pass advanced to (see the step call sites for semantics).
        let cursor: Int64
        /// True when the read covered every remaining row in its direction — the caller may
        /// advance past the boundary row instead of re-reading it inclusively.
        let exhausted: Bool
    }

    /// Opens the selected database read-only for the duration of one ingestion pass, with
    /// the same idle-WAL immutable fallback the OpenCode Go reader uses.
    static func withSourceDatabase(
        at url: URL,
        _ body: (OpaquePointer?, SourceTables) throws -> Void) throws
    {
        do {
            try Self.openSourceDatabase(at: url, immutable: false, body: body)
        } catch let failure as OpenCodeLocalHistorySQLiteFailure {
            // A clean WAL shutdown can remove both sidecars while leaving the database
            // header in WAL mode. Immutable mode reads that idle main file without
            // recreating the sidecars; active WALs stay on the normal path — the sidecar
            // check uses SQLite's actual `-wal`/`-shm` suffixes so an existing sidecar
            // never routes to a mode that would ignore its committed frames.
            guard failure.code == SQLITE_CANTOPEN, Self.walSidecarsAreMissing(at: url) else {
                throw failure
            }
            try Self.openSourceDatabase(at: url, immutable: true, body: body)
        }
    }

    private static func openSourceDatabase(
        at url: URL,
        immutable: Bool,
        body: (OpaquePointer?, SourceTables) throws -> Void) throws
    {
        var db: OpaquePointer?
        let filename = immutable
            ? "\(url.absoluteURL.absoluteString)?immutable=1"
            : url.path
        let flags = immutable ? SQLITE_OPEN_READONLY | SQLITE_OPEN_URI : SQLITE_OPEN_READONLY
        let openResult = sqlite3_open_v2(filename, &db, flags, nil)
        guard openResult == SQLITE_OK, db != nil else {
            let failure = OpenCodeLocalHistorySQLiteFailure(db: db, resultCode: openResult)
            if let db {
                _ = sqlite3_close(db)
            }
            throw failure
        }
        defer { _ = sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)

        let tables = SourceTables(
            hasMessage: Self.tableExists(db, "message"),
            hasParts: Self.tableExists(db, "part"),
            hasSessionMessages: Self.tableExists(db, "session_message"))
        guard tables.hasMessage || tables.hasSessionMessages else {
            // An idle WAL database with removed sidecars fails table detection with CANTOPEN
            // before any query runs. Probe readability so that case surfaces as a failure
            // the immutable fallback can handle, while a readable database without our
            // tables reads as empty history rather than an error.
            try Self.assertReadable(db)
            return
        }
        try body(db, tables)
    }

    private static func walSidecarsAreMissing(at url: URL) -> Bool {
        // SQLite names the sidecars `db-wal` and `db-shm`, not `db.wal`/`db.shm`.
        let wal = (url.path as NSString).appending("-wal")
        let shm = (url.path as NSString).appending("-shm")
        return !FileManager.default.fileExists(atPath: wal) && !FileManager.default.fileExists(atPath: shm)
    }

    private static func tableExists(_ db: OpaquePointer?, _ table: String) -> Bool {
        var stmt: OpaquePointer?
        let sql = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = '\(table)'"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { _ = sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private static func assertReadable(_ db: OpaquePointer?) throws {
        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(db, "SELECT 1 FROM sqlite_master LIMIT 1", -1, &stmt, nil)
        guard prepareResult == SQLITE_OK else {
            throw OpenCodeLocalHistorySQLiteFailure(db: db, resultCode: prepareResult)
        }
        defer { _ = sqlite3_finalize(stmt) }
        let step = sqlite3_step(stmt)
        guard step == SQLITE_ROW || step == SQLITE_DONE else {
            throw OpenCodeLocalHistorySQLiteFailure(db: db, resultCode: step)
        }
    }

    // MARK: cursor plumbing

    private static func rawCounts(_ db: OpaquePointer?, tables: SourceTables) -> SourceCounts {
        SourceCounts(
            message: tables.hasMessage ? Self.int64Value(db, "SELECT COUNT(*) FROM message") ?? 0 : 0,
            part: tables.hasParts ? Self.int64Value(db, "SELECT COUNT(*) FROM part") ?? 0 : 0,
            sessionMessage: tables.hasSessionMessages
                ? Self.int64Value(db, "SELECT COUNT(*) FROM session_message") ?? 0
                : 0)
    }

    private static func maxRowid(_ db: OpaquePointer?, table: String) -> Int64 {
        Self.int64Value(db, "SELECT COALESCE(MAX(rowid), 0) FROM \(table)") ?? 0
    }

    private static func int64Value(_ db: OpaquePointer?, _ sql: String) -> Int64? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { _ = sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(stmt, 0)
    }

    /// Message IDs whose parts arrived at or above the cursor — their message contributions
    /// need re-evaluation (a step-finish landing after the message was ingested).
    private static func readNewPartMessageIDs(
        _ db: OpaquePointer?,
        partCursor: Int64,
        limit: Int) throws -> (ids: [String], cursor: Int64, exhausted: Bool)
    {
        let sql = """
            SELECT message_id, rowid FROM part
            WHERE rowid >= \(partCursor)
            ORDER BY rowid ASC
            LIMIT \(limit)
            """
        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard prepareResult == SQLITE_OK else {
            throw OpenCodeLocalHistorySQLiteFailure(db: db, resultCode: prepareResult)
        }
        defer { _ = sqlite3_finalize(stmt) }
        var ids: [String] = []
        var cursor = partCursor
        var exhausted = true
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE {
                break
            }
            guard step == SQLITE_ROW else {
                throw OpenCodeLocalHistorySQLiteFailure(db: db, resultCode: step)
            }
            if ids.count >= limit - 1 {
                exhausted = false
                break
            }
            if let text = sqlite3_column_text(stmt, 0) {
                ids.append(String(cString: text))
            }
            cursor = sqlite3_column_int64(stmt, 1)
        }
        return (ids, cursor, exhausted)
    }

    /// Reads legacy `message` contributions — valid `step-finish` parts (one entry per
    /// part, keyed by part ID) with a message-level fallback — optionally restricted to a
    /// rowid window or a set of message IDs.
    static func readMessageEntries(
        _ db: OpaquePointer?,
        tables: SourceTables,
        rowidFilter: String? = nil,
        idFilter: [String]? = nil,
        ascending: Bool = true,
        limit: Int,
        boundary: Int64) throws -> SourceRead
    {
        // Filters address the raw `message` rowid inside the projection's FROM clause;
        // the exposed `srcRowid` alias only serves the outer ORDER BY.
        var cursorFilter = ""
        if let idFilter, !idFilter.isEmpty {
            let ids = idFilter.map { "'\(escaped($0))'" }.joined(separator: ", ")
            cursorFilter = "AND m.rowid IN (SELECT rowid FROM message WHERE id IN (\(ids)))"
        } else if let rowidFilter {
            cursorFilter = "AND m.\(rowidFilter)"
        }
        let projection = Self.providerMessagesSQL(extraFilter: cursorFilter)
        let sql = tables.hasParts
            ? Self.messageAndPartUsageSQL(providerMessages: projection)
            : Self.messageOnlyUsageSQL(providerMessages: projection)
        return try Self.stepEntries(
            db,
            sql: sql,
            ascending: ascending,
            limit: limit,
            boundary: boundary)
    }

    /// Reads v2 `session_message` contributions, optionally restricted to a rowid window.
    static func readSessionMessageEntries(
        _ db: OpaquePointer?,
        tables: SourceTables,
        rowidFilter: String,
        ascending: Bool,
        limit: Int,
        boundary: Int64) throws -> SourceRead
    {
        let sql = Self.sessionMessageUsageSQL(
            hasLegacyMessages: tables.hasMessage,
            hasParts: tables.hasParts,
            rowidFilter: "AND s.\(rowidFilter)")
        return try Self.stepEntries(
            db,
            sql: sql,
            ascending: ascending,
            limit: limit,
            boundary: boundary)
    }

    /// Runs a usage SELECT, decodes at most `limit - 1` entries, and reports the rowid
    /// cursor plus whether the read exhausted its direction. The caller advances
    /// inclusively (re-reading the boundary) unless `exhausted`, because a budget cut may
    /// land mid-way through a message's parts. A read that returns nothing leaves the
    /// cursor at the incoming `boundary`.
    private static func stepEntries(
        _ db: OpaquePointer?,
        sql: String,
        ascending: Bool,
        limit: Int,
        boundary: Int64) throws -> SourceRead
    {
        var stmt: OpaquePointer?
        let ordered = sql + "\nORDER BY srcRowid \(ascending ? "ASC" : "DESC")\nLIMIT \(limit)"
        let prepareResult = sqlite3_prepare_v2(db, ordered, -1, &stmt, nil)
        guard prepareResult == SQLITE_OK else {
            throw OpenCodeLocalHistorySQLiteFailure(db: db, resultCode: prepareResult)
        }
        defer { _ = sqlite3_finalize(stmt) }

        var entries: [Entry] = []
        var cursor = boundary
        var exhausted = true
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE {
                break
            }
            guard step == SQLITE_ROW else {
                throw OpenCodeLocalHistorySQLiteFailure(db: db, resultCode: step)
            }
            // Cancellation budget: a pathological database must not hold a scan hostage;
            // the surrounding scan treats the throw like any other skipped merge.
            if entries.count % 512 == 0, Task.isCancelled {
                throw CancellationError()
            }
            if entries.count >= limit - 1 {
                // One row past the budget tells the pass that more remain.
                exhausted = false
                break
            }
            cursor = sqlite3_column_int64(stmt, 5)
            let createdMs = sqlite3_column_int64(stmt, 0)
            let cost = sqlite3_column_double(stmt, 1)
            guard createdMs > 0, cost >= 0, cost.isFinite else { continue }
            let model = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            let sourceID = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
            let tokens = sqlite3_column_text(stmt, 3).flatMap { json in
                try? JSONDecoder().decode(TokenCounts.self, from: Data(String(cString: json).utf8))
            }
            let resolved = tokens.flatMap { $0.isValid ? $0 : nil }
            entries.append(Entry(
                sourceID: sourceID,
                createdMs: createdMs,
                costUSD: cost,
                modelID: model,
                totalTokens: resolved?.resolvedTotal,
                inputTokens: resolved?.input,
                outputTokens: resolved?.output,
                reasoningTokens: resolved?.reasoning,
                cacheReadTokens: resolved?.cache?.read,
                cacheCreationTokens: resolved?.cache?.write))
        }
        return SourceRead(entries: entries, cursor: cursor, exhausted: exhausted)
    }

    // MARK: usage SQL

    /// Legacy `message` rows for the selected provider, as a reusable projection. Exposes
    /// `srcRowid` (the message table's rowid) for cursor windows and `sourceID` (the part
    /// ID for part rows, the message ID for fallback rows) for stable upserts.
    private static func providerMessagesSQL(extraFilter: String = "") -> String {
        """
        SELECT
          m.id AS messageID,
          m.rowid AS srcRowid,
          CAST(COALESCE(json_extract(m.data, '$.time.created'), m.time_created) AS INTEGER) AS createdMs,
          CAST(json_extract(m.data, '$.cost') AS REAL) AS cost,
          json_type(m.data, '$.cost') IN ('integer', 'real') AS hasCost,
          COALESCE(json_extract(m.data, '$.modelID'), '') AS modelID,
          CASE WHEN json_type(m.data, '$.tokens') = 'object'
            THEN json_extract(m.data, '$.tokens') END AS tokens
        FROM message m
        WHERE json_valid(m.data)
          AND json_extract(m.data, '$.providerID') = 'openai'
          AND json_extract(m.data, '$.role') = 'assistant'
          \(extraFilter)
        """
    }

    /// Message-level totals only, for databases without a `part` table.
    private static func messageOnlyUsageSQL(providerMessages: String) -> String {
        """
        SELECT createdMs, cost, modelID, tokens, messageID AS sourceID, srcRowid
        FROM (\(providerMessages))
        WHERE hasCost
        """
    }

    /// Valid `step-finish` parts win (one entry per part, keyed by part ID); the message
    /// fallback contributes only when a message has no valid part, so a message is never
    /// counted twice.
    private static func messageAndPartUsageSQL(providerMessages: String) -> String {
        """
        WITH provider_messages AS (\(providerMessages))
        SELECT
          CAST(COALESCE(json_extract(p.data, '$.time.created'), p.time_created, m.createdMs) AS INTEGER)
            AS createdMs,
          CAST(json_extract(p.data, '$.cost') AS REAL) AS cost,
          m.modelID AS modelID,
          CASE WHEN json_type(p.data, '$.tokens') = 'object'
            THEN json_extract(p.data, '$.tokens') END AS tokens,
          p.id AS sourceID,
          m.srcRowid AS srcRowid
        FROM part p
        JOIN provider_messages m ON m.messageID = p.message_id
        WHERE json_valid(p.data)
          AND json_extract(p.data, '$.type') = 'step-finish'
          AND json_type(p.data, '$.cost') IN ('integer', 'real')
        UNION ALL
        SELECT createdMs, cost, modelID, tokens, messageID AS sourceID, srcRowid
        FROM provider_messages m
        WHERE hasCost
          AND NOT EXISTS (
            SELECT 1
            FROM part p
            WHERE p.message_id = m.messageID
              AND json_valid(p.data)
              AND json_extract(p.data, '$.type') = 'step-finish'
              AND json_type(p.data, '$.cost') IN ('integer', 'real')
          )
        """
    }

    /// OpenCode v2 writes new turns to `session_message` and copies older turns there under
    /// the same IDs. A v2 row only contributes its ID when the legacy `message` row is not
    /// itself usable — a legacy row with a missing, malformed, or negative cost suppresses
    /// nothing — mirroring the Go reader's usable-legacy projection (#4587).
    private static func sessionMessageUsageSQL(
        hasLegacyMessages: Bool,
        hasParts: Bool,
        rowidFilter: String = "") -> String
    {
        // Usability mirrors the legacy projection itself: a legacy row counts when a valid
        // non-negative `step-finish` part exists, or when its own cost is a valid
        // non-negative number. Only usable legacy rows suppress their migrated v2 copies.
        let usableLegacy = hasParts
            ? """
                  AND (
                    EXISTS (
                      SELECT 1 FROM part p
                      WHERE p.message_id = m.id
                        AND json_valid(p.data)
                        AND json_extract(p.data, '$.type') = 'step-finish'
                        AND json_type(p.data, '$.cost') IN ('integer', 'real')
                        AND CAST(json_extract(p.data, '$.cost') AS REAL) >= 0)
                    OR (
                      json_type(m.data, '$.cost') IN ('integer', 'real')
                        AND CAST(json_extract(m.data, '$.cost') AS REAL) >= 0))
            """
            : """
                  AND json_type(m.data, '$.cost') IN ('integer', 'real')
                  AND CAST(json_extract(m.data, '$.cost') AS REAL) >= 0
            """
        let legacyExclusion = hasLegacyMessages
            ? """
              AND NOT EXISTS (
                SELECT 1 FROM message m
                WHERE m.id = s.id
                  AND json_valid(m.data)
                  AND json_extract(m.data, '$.providerID') = 'openai'
                  AND json_extract(m.data, '$.role') = 'assistant'
            \(usableLegacy))
            """
            : ""
        return """
            SELECT
              CAST(COALESCE(json_extract(s.data, '$.time.created'), s.time_created) AS INTEGER) AS createdMs,
              CAST(json_extract(s.data, '$.cost') AS REAL) AS cost,
              COALESCE(json_extract(s.data, '$.model.id'), '') AS modelID,
              CASE WHEN json_type(s.data, '$.tokens') = 'object'
                THEN json_extract(s.data, '$.tokens') END AS tokens,
              s.id AS sourceID,
              s.rowid AS srcRowid
            FROM session_message s
            WHERE s.type = 'assistant'
              AND json_valid(s.data)
              AND json_extract(s.data, '$.model.providerID') = 'openai'
              AND json_type(s.data, '$.cost') IN ('integer', 'real')\(rowidFilter)\(legacyExclusion)
            """
    }

    private struct TokenCounts: Decodable {
        struct Cache: Decodable {
            let read: Int?
            let write: Int?
        }

        let total: Int?
        let input: Int?
        let output: Int?
        let reasoning: Int?
        let cache: Cache?

        private var components: [Int?] {
            [self.input, self.output, self.reasoning, self.cache?.read, self.cache?.write]
        }

        var resolvedTotal: Int? {
            // OpenCode separates output from reasoning and input from cache counts.
            self.total ?? (self.components.allSatisfy { $0 != nil }
                ? Self.checkedSum(self.components.compactMap(\.self)) : nil)
        }

        var isValid: Bool {
            (self.components + [self.total]).allSatisfy { ($0 ?? 0) >= 0 } && self.resolvedTotal != nil
        }

        private static func checkedSum(_ values: [Int]) -> Int? {
            var total = 0
            for value in values {
                let (partial, overflow) = total.addingReportingOverflow(value)
                guard !overflow else { return nil }
                total = partial
            }
            return total
        }
    }
}

#else

extension OpenCodeLocalHistoryStore {
    static func withSourceDatabase(
        at url: URL,
        _ body: (OpaquePointer?, SourceTables) throws -> Void) throws
    {}
}

#endif
