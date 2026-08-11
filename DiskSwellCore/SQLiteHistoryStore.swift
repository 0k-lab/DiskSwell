import Foundation
import SQLite3

public enum SQLiteHistoryError: Error, CustomStringConvertible {
    case open(String)
    case statement(String)

    public var description: String {
        switch self {
        case let .open(message): "SQLite open failed: \(message)"
        case let .statement(message): "SQLite statement failed: \(message)"
        }
    }
}

public actor SQLiteHistoryStore: HistoryStore {
    public static let hardLimitBytes: Int64 = 96 * .megabyte
    public let url: URL
    private var connection: SQLiteConnection?
    private var database: OpaquePointer? { connection?.pointer }
    private var lastRetention: Date = .distantPast

    public init(url: URL = SQLiteHistoryStore.defaultURL()) { self.url = url }

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("DiskSwell", isDirectory: true).appendingPathComponent("history.sqlite3")
    }

    public func prepare() throws {
        guard database == nil else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var opened: OpaquePointer?
        guard sqlite3_open_v2(url.path, &opened, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let opened { sqlite3_close(opened) }
            throw SQLiteHistoryError.open(message)
        }
        connection = SQLiteConnection(opened)
        do {
            try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON; PRAGMA auto_vacuum=INCREMENTAL; PRAGMA wal_autocheckpoint=256;")
            let pageSize = max(1, try scalar("PRAGMA page_size;"))
            try execute("PRAGMA max_page_count=\(Self.hardLimitBytes / pageSize);")
            try execute("""
            CREATE TABLE IF NOT EXISTS tracked_path (
                id INTEGER PRIMARY KEY,
                path TEXT NOT NULL UNIQUE,
                item_type TEXT NOT NULL,
                source TEXT NOT NULL,
                origin TEXT
            );
            CREATE TABLE IF NOT EXISTS sample (
                id INTEGER PRIMARY KEY,
                path_id INTEGER NOT NULL REFERENCES tracked_path(id) ON DELETE CASCADE,
                timestamp REAL NOT NULL,
                size INTEGER NOT NULL,
                item_count INTEGER,
                approximate INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS sample_path_time ON sample(path_id, timestamp);
            CREATE TABLE IF NOT EXISTS anomaly (
                id INTEGER PRIMARY KEY,
                path_id INTEGER NOT NULL REFERENCES tracked_path(id) ON DELETE CASCADE,
                first_detected REAL NOT NULL,
                last_updated REAL NOT NULL,
                severity INTEGER NOT NULL,
                growth INTEGER NOT NULL,
                interval REAL NOT NULL,
                reason TEXT NOT NULL,
                category TEXT NOT NULL DEFAULT 'surge',
                current_size INTEGER NOT NULL DEFAULT 0,
                item_count_growth INTEGER NOT NULL DEFAULT 0,
                approximate INTEGER NOT NULL DEFAULT 0,
                resolved REAL
            );
            CREATE INDEX IF NOT EXISTS anomaly_path_time ON anomaly(path_id, last_updated);
            """)
            if try !columnExists("sample", "item_count") { try execute("ALTER TABLE sample ADD COLUMN item_count INTEGER;") }
            if try !columnExists("sample", "approximate") { try execute("ALTER TABLE sample ADD COLUMN approximate INTEGER NOT NULL DEFAULT 0;") }
            if try !columnExists("anomaly", "category") { try execute("ALTER TABLE anomaly ADD COLUMN category TEXT NOT NULL DEFAULT 'surge';") }
            if try !columnExists("anomaly", "current_size") { try execute("ALTER TABLE anomaly ADD COLUMN current_size INTEGER NOT NULL DEFAULT 0;") }
            if try !columnExists("anomaly", "item_count_growth") { try execute("ALTER TABLE anomaly ADD COLUMN item_count_growth INTEGER NOT NULL DEFAULT 0;") }
            if try !columnExists("anomaly", "approximate") { try execute("ALTER TABLE anomaly ADD COLUMN approximate INTEGER NOT NULL DEFAULT 0;") }
            try execute("PRAGMA user_version=3;")
        } catch {
            connection = nil
            throw error
        }
    }

    public func record(sample: SizeSample, path: String, type: ItemType, source: SourceClassification) throws {
        let pathID = try upsertPath(path, type: type, source: source)
        try statement("""
            INSERT INTO sample(path_id, timestamp, size, item_count, approximate)
            SELECT ?, ?, ?, ?, ?
            WHERE COALESCE((SELECT size FROM sample WHERE path_id = ? ORDER BY timestamp DESC LIMIT 1), -1) != ?
               OR NOT ((SELECT item_count FROM sample WHERE path_id = ? ORDER BY timestamp DESC LIMIT 1) IS ?)
               OR COALESCE((SELECT approximate FROM sample WHERE path_id = ? ORDER BY timestamp DESC LIMIT 1), -1) != ?;
            """,
            bindings: [.integer(pathID), .double(sample.timestamp.timeIntervalSince1970), .integer(sample.size), sample.itemCount.map(Binding.integer) ?? .null, .integer(sample.isApproximate ? 1 : 0), .integer(pathID), .integer(sample.size), .integer(pathID), sample.itemCount.map(Binding.integer) ?? .null, .integer(pathID), .integer(sample.isApproximate ? 1 : 0)])
    }

    public func record(anomaly: Anomaly) throws {
        let pathID = try upsertPath(anomaly.path, type: .file, source: anomaly.source)
        try statement("""
            UPDATE anomaly SET last_updated = ?, severity = ?, growth = ?, interval = ?, reason = ?, category = ?, current_size = ?, item_count_growth = ?, approximate = ?
            WHERE id = (SELECT id FROM anomaly WHERE path_id = ? AND resolved IS NULL ORDER BY last_updated DESC LIMIT 1);
            """,
            bindings: [.double(anomaly.detectedAt.timeIntervalSince1970), .integer(Int64(anomaly.severity.rawValue)), .integer(anomaly.growth), .double(anomaly.interval), .text(anomaly.reason), .text(anomaly.category.rawValue), .integer(anomaly.currentSize), .integer(anomaly.itemCountGrowth), .integer(anomaly.isApproximate ? 1 : 0), .integer(pathID)])
        if sqlite3_changes(database) == 0 {
            try statement("INSERT INTO anomaly(path_id, first_detected, last_updated, severity, growth, interval, reason, category, current_size, item_count_growth, approximate) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);", bindings: [.integer(pathID), .double(anomaly.detectedAt.timeIntervalSince1970), .double(anomaly.detectedAt.timeIntervalSince1970), .integer(Int64(anomaly.severity.rawValue)), .integer(anomaly.growth), .double(anomaly.interval), .text(anomaly.reason), .text(anomaly.category.rawValue), .integer(anomaly.currentSize), .integer(anomaly.itemCountGrowth), .integer(anomaly.isApproximate ? 1 : 0)])
        }
    }

    public func resolveAnomaly(path: String, at: Date) throws {
        try statement("UPDATE anomaly SET resolved = ? WHERE resolved IS NULL AND path_id = (SELECT id FROM tracked_path WHERE path = ?);", bindings: [.double(at.timeIntervalSince1970), .text(path)])
    }

    public func applyRetention(now: Date) throws {
        guard now.timeIntervalSince(lastRetention) >= 60 * 60 else { return }
        let timestamp = now.timeIntervalSince1970
        try execute("BEGIN IMMEDIATE;")
        do {
            try deleteSamples(olderThan: timestamp - 30 * 24 * 60 * 60)
            try downsample(from: timestamp - 30 * 24 * 60 * 60, to: timestamp - 7 * 24 * 60 * 60, bucket: 60 * 60)
            try downsample(from: timestamp - 7 * 24 * 60 * 60, to: timestamp - 24 * 60 * 60, bucket: 15 * 60)
            try downsample(from: timestamp - 24 * 60 * 60, to: timestamp - 60 * 60, bucket: 60)
            try statement("DELETE FROM anomaly WHERE resolved IS NOT NULL AND resolved < ?;", bindings: [.double(timestamp - 30 * 24 * 60 * 60)])
            try execute("""
                DELETE FROM anomaly WHERE id NOT IN (SELECT id FROM anomaly ORDER BY last_updated DESC LIMIT 10000);
                DELETE FROM tracked_path
                WHERE NOT EXISTS (SELECT 1 FROM sample WHERE sample.path_id = tracked_path.id)
                  AND NOT EXISTS (SELECT 1 FROM anomaly WHERE anomaly.path_id = tracked_path.id);
                COMMIT;
                PRAGMA incremental_vacuum(256);
                """)
            lastRetention = now
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    public func statistics() throws -> HistoryStatistics {
        let samples = try scalar("SELECT COUNT(*) FROM sample;")
        let anomalies = try scalar("SELECT COUNT(*) FROM anomaly;")
        let size = [url, URL(fileURLWithPath: url.path + "-wal"), URL(fileURLWithPath: url.path + "-shm")].reduce(Int64(0)) {
            $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return HistoryStatistics(sampleCount: Int(samples), anomalyCount: Int(anomalies), fileSize: size)
    }

    public func reset() throws {
        connection = nil
        let files = [url, URL(fileURLWithPath: url.path + "-wal"), URL(fileURLWithPath: url.path + "-shm")]
        for file in files where FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
        lastRetention = .distantPast
        try prepare()
    }

    public func samples(path: String, limit: Int = 100_000) throws -> [SizeSample] {
        var output: [SizeSample] = []
        try query("SELECT timestamp, size, item_count, approximate FROM sample WHERE path_id = (SELECT id FROM tracked_path WHERE path = ?) ORDER BY timestamp LIMIT ?;", bindings: [.text(path), .integer(Int64(max(1, limit)))]) { row in
            output.append(Self.sample(row))
        }
        return output
    }

    public func longHorizonCheckpoints(path: String, at now: Date) async throws -> [HistoricalCheckpoint] {
        let windows: [TimeInterval] = [24 * 60 * 60, 7 * 24 * 60 * 60, 14 * 24 * 60 * 60, 21 * 24 * 60 * 60, 30 * 24 * 60 * 60]
        return try windows.compactMap { window in
            let target = now.timeIntervalSince1970 - window
            let before = try oneSample("""
                SELECT s.timestamp, s.size, s.item_count, s.approximate FROM sample s
                WHERE s.path_id = (SELECT id FROM tracked_path WHERE path = ?) AND s.timestamp <= ?
                ORDER BY s.timestamp DESC LIMIT 1;
                """, bindings: [.text(path), .double(target)])
            let sample = try before ?? oneSample("""
                SELECT s.timestamp, s.size, s.item_count, s.approximate FROM sample s
                WHERE s.path_id = (SELECT id FROM tracked_path WHERE path = ?) AND s.timestamp >= ? AND s.timestamp <= ?
                ORDER BY s.timestamp LIMIT 1;
                """, bindings: [.text(path), .double(target), .double(now.timeIntervalSince1970)])
            guard let sample else { return nil }
            let age = now.timeIntervalSince(sample.timestamp)
            guard age >= window / 2, age <= window * 1.5 else { return nil }
            return HistoricalCheckpoint(window: window, sample: sample)
        }
    }

    public func auditPaths(limit: Int) async throws -> [AuditPath] {
        var output: [AuditPath] = []
        try query("""
            SELECT tp.path, tp.item_type, tp.source, tp.origin,
                   (SELECT severity FROM anomaly WHERE path_id = tp.id AND resolved IS NULL ORDER BY last_updated DESC LIMIT 1),
                   (SELECT last_updated FROM anomaly WHERE path_id = tp.id AND resolved IS NULL ORDER BY last_updated DESC LIMIT 1),
                   (SELECT size FROM sample WHERE path_id = tp.id ORDER BY timestamp DESC LIMIT 1)
            FROM tracked_path tp
            WHERE tp.item_type = 'directory' OR EXISTS (SELECT 1 FROM anomaly WHERE path_id = tp.id AND resolved IS NULL)
            ORDER BY (SELECT MAX(last_updated) FROM anomaly WHERE path_id = tp.id) DESC,
                     (SELECT MAX(timestamp) FROM sample WHERE path_id = tp.id) DESC,
                     tp.path
            LIMIT ?;
            """, bindings: [.integer(Int64(max(1, limit)))]) { row in
            guard let pathText = sqlite3_column_text(row, 0), let typeText = sqlite3_column_text(row, 1), let sourceText = sqlite3_column_text(row, 2),
                  let type = ItemType(rawValue: String(cString: typeText)) else { return }
            let sourceValue = String(cString: sourceText)
            let metadata = sqlite3_column_text(row, 3).map { String(cString: $0) }
            let source = Self.source(storedValue: sourceValue, metadata: metadata)
            let severity = sqlite3_column_type(row, 4) == SQLITE_NULL ? nil : AnomalySeverity(rawValue: Int(sqlite3_column_int(row, 4)))
            let updated = sqlite3_column_type(row, 5) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(row, 5))
            let size = sqlite3_column_type(row, 6) == SQLITE_NULL ? nil : sqlite3_column_int64(row, 6)
            output.append(AuditPath(path: String(cString: pathText), type: type, source: source, unresolvedSeverity: severity, lastAnomalyUpdate: updated, lastKnownSize: size))
        }
        return output
    }

    public func recentDetections(limit: Int) async throws -> [DetectionRecord] {
        var output: [DetectionRecord] = []
        try query("""
            SELECT a.id, tp.path, tp.source, tp.origin, a.severity,
                   COALESCE(NULLIF(a.current_size, 0), (SELECT size FROM sample WHERE path_id = tp.id ORDER BY timestamp DESC LIMIT 1), 0),
                   a.growth, a.interval,
                   a.reason, a.category, a.first_detected, a.last_updated, a.resolved, a.item_count_growth, a.approximate
            FROM anomaly a JOIN tracked_path tp ON tp.id = a.path_id
            ORDER BY a.last_updated DESC LIMIT ?;
            """, bindings: [.integer(Int64(max(1, limit)))]) { row in
            guard let pathText = sqlite3_column_text(row, 1), let sourceText = sqlite3_column_text(row, 2),
                  let severity = AnomalySeverity(rawValue: Int(sqlite3_column_int(row, 4))),
                  let reason = sqlite3_column_text(row, 8), let categoryText = sqlite3_column_text(row, 9),
                  let category = AnomalyCategory(rawValue: String(cString: categoryText)) else { return }
            let path = String(cString: pathText)
            let storedSource = Self.source(storedValue: String(cString: sourceText), metadata: sqlite3_column_text(row, 3).map { String(cString: $0) })
            output.append(DetectionRecord(
                id: sqlite3_column_int64(row, 0),
                path: path,
                source: storedSource == .generic ? SourceAttribution.source(for: path) : storedSource,
                severity: severity,
                currentSize: sqlite3_column_int64(row, 5),
                growth: sqlite3_column_int64(row, 6),
                interval: sqlite3_column_double(row, 7),
                reason: String(cString: reason),
                category: category,
                detectedAt: Date(timeIntervalSince1970: sqlite3_column_double(row, 10)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(row, 11)),
                resolvedAt: sqlite3_column_type(row, 12) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(row, 12)),
                itemCountGrowth: sqlite3_column_int64(row, 13),
                isApproximate: sqlite3_column_int(row, 14) != 0
            ))
        }
        return output
    }

    private func upsertPath(_ path: String, type: ItemType, source: SourceClassification) throws -> Int64 {
        let metadata: String?
        switch source {
        case .generic: metadata = nil
        case let .safariWebKit(origin): metadata = origin
        case let .application(name, _): metadata = name
        }
        try statement("""
            INSERT INTO tracked_path(path, item_type, source, origin) VALUES(?, ?, ?, ?)
            ON CONFLICT(path) DO UPDATE SET item_type = excluded.item_type, source = excluded.source, origin = excluded.origin;
            """,
            bindings: [.text(path), .text(type.rawValue), .text(source.storageValue), metadata.map(Binding.text) ?? .null])
        return try scalar("SELECT id FROM tracked_path WHERE path = ?;", bindings: [.text(path)])
    }

    private static func source(storedValue: String, metadata: String?) -> SourceClassification {
        switch (storedValue, metadata) {
        case ("safari-webkit", _): .safariWebKit(origin: metadata)
        case ("application-verified", let name?): .application(name: name, confidence: .verified)
        case ("application-likely", let name?): .application(name: name, confidence: .likely)
        default: .generic
        }
    }

    private func deleteSamples(olderThan timestamp: TimeInterval) throws {
        try statement("DELETE FROM sample WHERE timestamp < ?;", bindings: [.double(timestamp)])
    }

    private func downsample(from: TimeInterval, to: TimeInterval, bucket: Int) throws {
        try statement("""
            DELETE FROM sample
            WHERE timestamp >= ? AND timestamp < ?
              AND id NOT IN (
                SELECT MIN(id) FROM sample WHERE timestamp >= ? AND timestamp < ?
                GROUP BY path_id, CAST(timestamp / ? AS INTEGER)
              );
            """,
            bindings: [.double(from), .double(to), .double(from), .double(to), .integer(Int64(bucket))])
    }

    private func columnExists(_ table: String, _ column: String) throws -> Bool {
        var found = false
        try query("PRAGMA table_info(\(table));") { row in
            if let name = sqlite3_column_text(row, 1), String(cString: name) == column { found = true }
        }
        return found
    }

    private func oneSample(_ sql: String, bindings: [Binding]) throws -> SizeSample? {
        var output: SizeSample?
        try query(sql, bindings: bindings) { output = Self.sample($0) }
        return output
    }

    private static func sample(_ row: OpaquePointer) -> SizeSample {
        SizeSample(
            timestamp: Date(timeIntervalSince1970: sqlite3_column_double(row, 0)),
            size: sqlite3_column_int64(row, 1),
            itemCount: sqlite3_column_type(row, 2) == SQLITE_NULL ? nil : sqlite3_column_int64(row, 2),
            isApproximate: sqlite3_column_int(row, 3) != 0
        )
    }

    private enum Binding {
        case integer(Int64)
        case double(Double)
        case text(String)
        case null
    }

    private func execute(_ sql: String) throws {
        guard let database else { throw SQLiteHistoryError.statement("database is not prepared") }
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(error)
            throw SQLiteHistoryError.statement(message)
        }
    }

    private func statement(_ sql: String, bindings: [Binding] = []) throws {
        try query(sql, bindings: bindings) { _ in }
    }

    private func scalar(_ sql: String, bindings: [Binding] = []) throws -> Int64 {
        var value: Int64 = 0
        try query(sql, bindings: bindings) { value = sqlite3_column_int64($0, 0) }
        return value
    }

    private func query(_ sql: String, bindings: [Binding] = [], row: (OpaquePointer) -> Void) throws {
        guard let database else { throw SQLiteHistoryError.statement("database is not prepared") }
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &prepared, nil) == SQLITE_OK, let prepared else { throw SQLiteHistoryError.statement(String(cString: sqlite3_errmsg(database))) }
        defer { sqlite3_finalize(prepared) }
        for (index, binding) in bindings.enumerated() {
            let position = Int32(index + 1)
            switch binding {
            case let .integer(value): sqlite3_bind_int64(prepared, position, value)
            case let .double(value): sqlite3_bind_double(prepared, position, value)
            case let .text(value): sqlite3_bind_text(prepared, position, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            case .null: sqlite3_bind_null(prepared, position)
            }
        }
        while true {
            let result = sqlite3_step(prepared)
            if result == SQLITE_ROW { row(prepared); continue }
            guard result == SQLITE_DONE else { throw SQLiteHistoryError.statement(String(cString: sqlite3_errmsg(database))) }
            return
        }
    }
}

private final class SQLiteConnection: @unchecked Sendable {
    let pointer: OpaquePointer
    init(_ pointer: OpaquePointer) { self.pointer = pointer }
    deinit { sqlite3_close(pointer) }
}
