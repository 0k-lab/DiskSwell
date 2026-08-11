import Foundation
import SQLite3
import Testing
@testable import DiskSwellCore

@Test("SQLite history removes, downsamples, and deduplicates samples")
func sqliteRetention() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DiskSwellSQLiteTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SQLiteHistoryStore(url: directory.appendingPathComponent("history.sqlite3"))
    try await store.prepare()
    let nowValue = floor(2_000_000_000.0 / 3_600) * 3_600 + 1_800
    let now = Date(timeIntervalSince1970: nowValue)
    let path = "/tmp/history-item"
    var size: Int64 = 1

    func add(_ timestamp: TimeInterval) async throws {
        size += 1
        try await store.record(sample: SizeSample(timestamp: Date(timeIntervalSince1970: timestamp), size: size), path: path, type: .file, source: .generic)
    }

    try await add(nowValue - 31 * 24 * 60 * 60)
    let eightDays = floor((nowValue - 8 * 24 * 60 * 60) / 3_600) * 3_600 + 100
    try await add(eightDays)
    try await add(eightDays + 20)
    let twoDays = floor((nowValue - 2 * 24 * 60 * 60) / 900) * 900 + 100
    try await add(twoDays)
    try await add(twoDays + 20)
    let twoHours = floor((nowValue - 2 * 60 * 60) / 60) * 60 + 10
    try await add(twoHours)
    try await add(twoHours + 20)
    try await add(nowValue - 30 * 60)
    try await add(nowValue - 29 * 60)
    try await store.record(sample: SizeSample(timestamp: Date(timeIntervalSince1970: nowValue - 28 * 60), size: size), path: path, type: .file, source: .generic) // identical size is not persisted

    try await store.applyRetention(now: now)
    let samples = try await store.samples(path: path)
    let statistics = try await store.statistics()
    #expect(samples.count == 5)
    #expect(samples.allSatisfy { $0.timestamp >= now.addingTimeInterval(-30 * 24 * 60 * 60) })
    #expect(statistics.sampleCount == 5)
    #expect(statistics.fileSize < SQLiteHistoryStore.hardLimitBytes)
}

@Test("SQLite history preserves application attribution confidence")
func sqliteApplicationAttribution() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DiskSwellSQLiteTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SQLiteHistoryStore(url: directory.appendingPathComponent("history.sqlite3"))
    try await store.prepare()
    let source = SourceClassification.application(name: "Telegram", confidence: .likely)
    let now = Date()
    try await store.record(sample: SizeSample(timestamp: now, size: 1), path: "/tmp/Telegram", type: .directory, source: .generic)
    try await store.record(anomaly: Anomaly(path: "/tmp/Telegram", source: source, severity: .warning, currentSize: 2, growth: 1, interval: 1, reason: "test", detectedAt: now, itemCountGrowth: 3))
    #expect(try await store.auditPaths(limit: 1).first?.source == source)
    let detection = try #require(await store.recentDetections(limit: 1).first)
    #expect(detection.source == source)
    #expect(detection.currentSize == 2)
    #expect(detection.itemCountGrowth == 3)
    #expect(detection.resolvedAt == nil)
    try await store.resolveAnomaly(path: "/tmp/Telegram", at: now.addingTimeInterval(1))
    #expect(try await store.recentDetections(limit: 1).first?.resolvedAt != nil)
}

@Test("Recent legacy detections recover application attribution from their path")
func sqliteLegacyDetectionAttribution() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DiskSwellSQLiteTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SQLiteHistoryStore(url: directory.appendingPathComponent("history.sqlite3"))
    try await store.prepare()
    let path = "/tmp/home/Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram/stable"
    try await store.record(anomaly: Anomaly(path: path, source: .generic, severity: .warning, currentSize: 2, growth: 1, interval: 1, reason: "test", detectedAt: Date()))
    #expect(try await store.recentDetections(limit: 1).first?.source == .application(name: "Telegram", confidence: .likely))
}

@Test("SQLite initialization can retry after a corrupt database is replaced")
func sqlitePrepareRecovers() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DiskSwellSQLiteTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("history.sqlite3")
    try Data("not a sqlite database".utf8).write(to: url)
    let store = SQLiteHistoryStore(url: url)

    do {
        try await store.prepare()
        Issue.record("Corrupt SQLite file unexpectedly prepared")
    } catch {}

    try FileManager.default.removeItem(at: url)
    try await store.prepare()
    #expect(try await store.statistics().sampleCount == 0)
}

@Test("Thirty-day aggregate checkpoints survive retention")
func sqliteLongHorizonAggregateHistory() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DiskSwellSQLiteTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SQLiteHistoryStore(url: directory.appendingPathComponent("history.sqlite3"))
    try await store.prepare()
    let day: TimeInterval = 24 * 60 * 60
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let path = "/tmp/Builds"
    for (daysAgo, gib, count) in [(30.0, 2, 50), (21.0, 4, 500), (14.0, 7, 1_500), (7.0, 11, 3_000), (1.0, 15, 4_500), (0.0, 16, 5_000)] {
        try await store.record(sample: SizeSample(timestamp: now.addingTimeInterval(-daysAgo * day), size: Int64(gib) * .gigabyte, itemCount: Int64(count), isApproximate: true), path: path, type: .directory, source: .generic)
    }
    try await store.applyRetention(now: now)
    let checkpoints = try await store.longHorizonCheckpoints(path: path, at: now)
    let samples = try await store.samples(path: path)
    #expect(samples.count == 6)
    #expect(checkpoints.count == 5)
    let thirtyDaySize = checkpoints.first(where: { $0.window == 30 * day })?.sample.size
    let sevenDayCount = checkpoints.first(where: { $0.window == 7 * day })?.sample.itemCount
    #expect(thirtyDaySize == Int64(2) * .gigabyte)
    #expect(sevenDayCount == 3_000)
    #expect(samples.allSatisfy { $0.itemCount != nil && $0.isApproximate })
    #expect(try await store.statistics().fileSize < SQLiteHistoryStore.hardLimitBytes)
}

@Test("Legacy SQLite schema migrates aggregate and detection detail columns")
func sqliteSchemaMigration() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DiskSwellSQLiteTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("history.sqlite3")
    var database: OpaquePointer?
    #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
    let legacy = """
        CREATE TABLE tracked_path (id INTEGER PRIMARY KEY, path TEXT NOT NULL UNIQUE, item_type TEXT NOT NULL, source TEXT NOT NULL, origin TEXT);
        CREATE TABLE sample (id INTEGER PRIMARY KEY, path_id INTEGER NOT NULL REFERENCES tracked_path(id), timestamp REAL NOT NULL, size INTEGER NOT NULL);
        CREATE TABLE anomaly (id INTEGER PRIMARY KEY, path_id INTEGER NOT NULL REFERENCES tracked_path(id), first_detected REAL NOT NULL, last_updated REAL NOT NULL, severity INTEGER NOT NULL, growth INTEGER NOT NULL, interval REAL NOT NULL, reason TEXT NOT NULL, resolved REAL);
        """
    #expect(sqlite3_exec(database, legacy, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(database)
    database = nil

    let store = SQLiteHistoryStore(url: url)
    try await store.prepare()
    let sample = SizeSample(timestamp: Date(), size: 42, itemCount: 7, isApproximate: true)
    do {
        try await store.record(sample: sample, path: "/tmp/migrated", type: .directory, source: .generic)
        let migrated = try await store.samples(path: "/tmp/migrated")
        #expect(migrated.count == 1)
        #expect(migrated.first?.size == 42)
        #expect(migrated.first?.itemCount == 7)
        #expect(migrated.first?.isApproximate == true)
        try await store.record(anomaly: Anomaly(path: "/tmp/migrated", source: .generic, severity: .warning, currentSize: 42, growth: 8, interval: 60, reason: "Migrated", detectedAt: Date()))
        #expect(try await store.recentDetections(limit: 1).first?.currentSize == 42)
    } catch {
        Issue.record("Migration use failed: \(error)")
    }
}
