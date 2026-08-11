import Foundation
import CoreServices
import Testing
@testable import DiskSwellCore

@Test("The monitoring core starts ready without a UI process")
func monitoringEngineStartsReady() async {
    let engine = MonitoringEngine(history: InMemoryHistoryStore(), notifications: RecordingNotifications())
    #expect(await engine.status == .ready)
    #expect(await engine.status.label == "Ready")
}

@Test("Overlapping roots are normalized and deduplicated")
func rootDeduplication() {
    let roots = PathRules.deduplicatedRoots(["/tmp/watch", "/tmp/watch/child", "/tmp/other", "/tmp/watch/"])
    #expect(roots == ["/tmp/other", "/tmp/watch"])
}

@Test("File events stay precise until the dirty-path limit is reached")
func fileEventsStayPrecise() {
    let root = "/tmp/home/Library"
    var coalescer = EventCoalescer(roots: [root], capacity: 4_096)
    let events = (0..<1_000).map { "\(root)/Containers/com.apple.Safari/Data/Library/WebKit/WebsiteData/origin-\($0)/localstorage.sqlite3-wal" }
    coalescer.ingest(events)
    let paths = coalescer.drain()
    #expect(paths == events.sorted())
    #expect(coalescer.overflowCount == 0)
}

@Test("Routine directory events are skipped without hiding reconciliation")
func directoryEventFiltering() {
    let directory = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir)
    #expect(!FSEventsMonitor.shouldInspect(directory | FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)))
    #expect(FSEventsMonitor.shouldInspect(directory | FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved)))
    #expect(FSEventsMonitor.shouldInspect(directory | FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)))
    #expect(FSEventsMonitor.shouldInspect(FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile)))
}

@Test("Unrelated watched roots remain distinct")
func unrelatedRootsRemainDistinct() {
    var coalescer = EventCoalescer(roots: ["/tmp/Library", "/tmp/Downloads"], capacity: 8)
    coalescer.ingest(["/tmp/Library/A/file", "/tmp/Downloads/B/file"])
    #expect(coalescer.drain().count == 2)
}

@Test("Dirty path overflow stays bounded and records collapse")
func dirtyOverflowIsBounded() {
    var coalescer = EventCoalescer(roots: ["/tmp/root-a", "/tmp/root-b"], capacity: 8)
    coalescer.ingest((0..<100).map { "/tmp/root-a/group-\($0)/child/file" })
    coalescer.ingest((0..<100).map { "/tmp/root-b/group-\($0)/child/file" })
    #expect(coalescer.count <= 8)
    #expect(coalescer.overflowCount > 0)
    #expect(coalescer.collapsedCount > 0)
    #expect(coalescer.drain().count <= 8)
}

@Test("Fifty thousand synthetic events keep coalescer memory bounded")
func eventStormIsBounded() {
    var coalescer = EventCoalescer(roots: ["/tmp/storm"], capacity: 128)
    for index in 0..<50_000 {
        coalescer.ingest(CollectionOfOne("/tmp/storm/project-\(index)/build/file"))
    }
    #expect(coalescer.count <= 128)
    #expect(coalescer.overflowCount > 0)
}

@Test("Tracked items deterministically evict the stalest low-priority item")
func trackedItemsAreBounded() {
    var store = TrackedItemStore(capacity: 3)
    let now = Date(timeIntervalSince1970: 1_000)
    for index in 0..<4 {
        var samples = SampleRing(capacity: 2)
        samples.append(SizeSample(timestamp: now.addingTimeInterval(Double(index)), size: Int64(index)))
        store.upsert(TrackedItem(path: "/item-\(index)", type: .file, source: .generic, samples: samples, lastSeen: now.addingTimeInterval(Double(index))))
    }
    #expect(store.items.count == 3)
    #expect(store.items["/item-0"] == nil)
    #expect(store.evictions == 1)
}

@Test("Tracked-item overflow retains existing higher-severity items")
func trackedItemsRetainHighPriorityState() {
    var store = TrackedItemStore(capacity: 2)
    let now = Date(timeIntervalSince1970: 1_000)
    for index in 0..<2 {
        var samples = SampleRing(capacity: 2)
        samples.append(SizeSample(timestamp: now, size: Int64.gigabyte))
        store.upsert(TrackedItem(path: "/critical-\(index)", type: .file, source: .generic, samples: samples, lastSeen: now, severity: .critical))
    }
    var samples = SampleRing(capacity: 2)
    samples.append(SizeSample(timestamp: now.addingTimeInterval(60), size: 1))
    store.upsert(TrackedItem(path: "/normal", type: .file, source: .generic, samples: samples, lastSeen: now.addingTimeInterval(60)))
    #expect(store.items.count == 2)
    #expect(store.items["/normal"] == nil)
    #expect(store.evictions == 1)
}

@Test("Sample ring never exceeds its configured capacity")
func samplesAreBounded() {
    var ring = SampleRing(capacity: 32)
    for index in 0..<100 { ring.append(SizeSample(timestamp: Date(timeIntervalSince1970: Double(index)), size: Int64(index))) }
    #expect(ring.count == 32)
    #expect(ring.values.first?.size == 68)
    #expect(ring.values.last?.size == 99)
}

@Test("Slow small growth remains normal")
func slowGrowthIsNormal() {
    let config = MonitoringConfiguration(watchedRoots: ["/tmp"])
    let samples = [
        SizeSample(timestamp: Date(timeIntervalSince1970: 0), size: 50 * .megabyte),
        SizeSample(timestamp: Date(timeIntervalSince1970: 24 * 60 * 60), size: 80 * .megabyte),
    ]
    #expect(GrowthDetector.evaluate(samples: samples, source: .generic, configuration: config).severity == .normal)
}

@Test("Generic rapid growth and absolute size rules detect warning and critical states")
func genericGrowthRules() {
    let config = MonitoringConfiguration(watchedRoots: ["/tmp"])
    let start = Date(timeIntervalSince1970: 1_000)
    let warning = GrowthDetector.evaluate(samples: [
        SizeSample(timestamp: start, size: 200 * .megabyte),
        SizeSample(timestamp: start.addingTimeInterval(2 * 60), size: 800 * .megabyte),
    ], source: .generic, configuration: config)
    let critical = GrowthDetector.evaluate(samples: [
        SizeSample(timestamp: start, size: 200 * .megabyte),
        SizeSample(timestamp: start.addingTimeInterval(10 * 60), size: 3 * .gigabyte),
    ], source: .generic, configuration: config)
    let absolute = GrowthDetector.evaluate(samples: [SizeSample(timestamp: start, size: 1 * .gigabyte)], source: .generic, configuration: config)
    #expect(warning.severity == .warning)
    #expect(critical.severity == .critical)
    #expect(absolute.severity == .warning)
}

@Test("Notification policy escalates, suppresses cooldown spam, and permits recurrence")
func anomalyNotificationPolicy() {
    let config = MonitoringConfiguration(watchedRoots: ["/tmp"])
    let start = Date(timeIntervalSince1970: 2_000)
    var ring = SampleRing(capacity: 32)
    ring.append(SizeSample(timestamp: start, size: 1 * .gigabyte))
    var item = TrackedItem(path: "/tmp/growing", type: .file, source: .generic, samples: ring, lastSeen: start)
    var evaluation = GrowthDetector.evaluate(samples: item.samples.values, source: item.source, configuration: config)
    #expect(GrowthDetector.shouldNotify(item: &item, evaluation: evaluation, now: start, configuration: config))

    item.samples.append(SizeSample(timestamp: start.addingTimeInterval(60), size: 1 * .gigabyte + 10 * .megabyte))
    evaluation = GrowthDetector.evaluate(samples: item.samples.values, source: item.source, configuration: config)
    #expect(!GrowthDetector.shouldNotify(item: &item, evaluation: evaluation, now: start.addingTimeInterval(60), configuration: config))

    item.samples.append(SizeSample(timestamp: start.addingTimeInterval(120), size: 3 * .gigabyte))
    evaluation = GrowthDetector.evaluate(samples: item.samples.values, source: item.source, configuration: config)
    #expect(evaluation.severity == .critical)
    #expect(GrowthDetector.shouldNotify(item: &item, evaluation: evaluation, now: start.addingTimeInterval(120), configuration: config))

    item.samples.append(SizeSample(timestamp: start.addingTimeInterval(180), size: 100 * .megabyte))
    evaluation = GrowthDetector.evaluate(samples: item.samples.values, source: item.source, configuration: config)
    #expect(!GrowthDetector.shouldNotify(item: &item, evaluation: evaluation, now: start.addingTimeInterval(180), configuration: config))
    #expect(item.severity == .normal)

    item.samples.append(SizeSample(timestamp: start.addingTimeInterval(240), size: 1 * .gigabyte))
    evaluation = GrowthDetector.evaluate(samples: item.samples.values, source: item.source, configuration: config)
    #expect(GrowthDetector.shouldNotify(item: &item, evaluation: evaluation, now: start.addingTimeInterval(240), configuration: config))
}

@Test("Free-space detector transitions and suppresses repeated notifications")
func freeSpaceTransitions() {
    var detector = FreeSpaceDetector()
    let config = MonitoringConfiguration(watchedRoots: ["/tmp"])
    let now = Date(timeIntervalSince1970: 3_000)
    #expect(detector.evaluate(available: 30 * .gigabyte, total: 200 * .gigabyte, now: now, configuration: config).severity == .normal)
    let warning = detector.evaluate(available: 15 * .gigabyte, total: 200 * .gigabyte, now: now, configuration: config)
    #expect(warning.severity == .warning && warning.shouldNotify)
    #expect(!detector.evaluate(available: 14 * .gigabyte, total: 200 * .gigabyte, now: now.addingTimeInterval(60), configuration: config).shouldNotify)
    let critical = detector.evaluate(available: 8 * .gigabyte, total: 200 * .gigabyte, now: now.addingTimeInterval(120), configuration: config)
    #expect(critical.severity == .critical && critical.shouldNotify)
    let emergency = detector.evaluate(available: 4 * .gigabyte, total: 200 * .gigabyte, now: now.addingTimeInterval(180), configuration: config)
    #expect(emergency.severity == .emergency && emergency.shouldNotify)
}

@Test("Safari WAL size and runaway growth thresholds are specialized")
func safariWALRules() async {
    let path = "/tmp/home/Library/Containers/com.apple.Safari/Data/Library/WebKit/WebsiteData/Default/hash/LocalStorage/localstorage.sqlite3-wal"
    let start = Date(timeIntervalSince1970: 4_000)
    let smallEngine = MonitoringEngine(history: InMemoryHistoryStore(), notifications: RecordingNotifications())
    let warningEngine = MonitoringEngine(history: InMemoryHistoryStore(), notifications: RecordingNotifications())
    let criticalEngine = MonitoringEngine(history: InMemoryHistoryStore(), notifications: RecordingNotifications())
    #expect(await smallEngine.processSample(path: path, size: 100 * .megabyte, at: start) == nil)
    #expect(await warningEngine.processSample(path: path, size: 600 * .megabyte, at: start)?.severity == .warning)
    #expect(await criticalEngine.processSample(path: path, size: 2 * .gigabyte + 100 * .megabyte, at: start)?.severity == .critical)

    let runawayEngine = MonitoringEngine(history: InMemoryHistoryStore(), notifications: RecordingNotifications())
    #expect(await runawayEngine.processSample(path: path, size: 100 * .megabyte, at: start) == nil)
    #expect(await runawayEngine.processSample(path: path, size: 400 * .megabyte, at: start.addingTimeInterval(60))?.severity == .emergency)
}

@Test("Recent Safari runaway growth is not diluted by an old sample")
func recentSafariRunawayGrowth() {
    let config = MonitoringConfiguration(watchedRoots: ["/tmp"])
    let start = Date(timeIntervalSince1970: 4_000)
    let evaluation = GrowthDetector.evaluate(samples: [
        SizeSample(timestamp: start, size: 100 * .megabyte),
        SizeSample(timestamp: start.addingTimeInterval(59 * 60), size: 1 * .gigabyte),
        SizeSample(timestamp: start.addingTimeInterval(60 * 60), size: 1 * .gigabyte + 300 * .megabyte),
    ], source: .safariWebKit(origin: nil), configuration: config)
    #expect(evaluation.severity == .emergency)
    #expect(evaluation.interval == 60)
}

@Test("Sparse files preserve logical size but monitor allocated bytes")
func sparseSafariWALInspection() throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let wal = root.appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/WebKit/WebsiteData/Default/hash/LocalStorage/localstorage.sqlite3-wal")
    try FileManager.default.createDirectory(at: wal.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: wal.path, contents: nil)
    let handle = try FileHandle(forWritingTo: wal)
    try handle.truncate(atOffset: UInt64(2 * Int64.gigabyte + 1))
    try handle.close()
    let result = TargetedFileInspector().inspect(path: wal.path, maxEntries: 4, maxDepth: 2)
    #expect(result.items.first?.logicalSize == 2 * .gigabyte + 1)
    #expect(result.items.first.map { $0.size < $0.logicalSize } == true)
    let directory = TargetedFileInspector().inspect(path: wal.deletingLastPathComponent().path, maxEntries: 4, maxDepth: 2).items.last
    #expect(directory.map { $0.size < $0.logicalSize } == true)
    #expect(SafariWebKit.isWAL(path: wal.path))
}

@Test("Directory inspection stops at its entry budget and marks its partial aggregate")
func directoryInspectionIsBounded() throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for index in 0..<100 { FileManager.default.createFile(atPath: root.appendingPathComponent("file-\(index)").path, contents: Data([0])) }
    let result = TargetedFileInspector().inspect(path: root.path, maxEntries: 10, maxDepth: 2)
    #expect(result.truncated)
    #expect(result.visitedEntries == 10)
    #expect(result.items.last?.type == .directory)
    #expect(result.items.last?.isApproximate == true)
    #expect(result.items.last?.itemCount == 10)
}

@Test("Approximate directory aggregates stay bounded without alerting")
func approximateDirectoryAggregateDoesNotAlert() async {
    let root = "/tmp/diskswell-aggregate-\(UUID().uuidString)"
    let builds = root + "/Builds"
    var config = MonitoringConfiguration(watchedRoots: [root])
    config.maxTrackedItems = 128
    config.maxTrackedDirectoryAggregates = 4
    config.directorySizeWarning = 100 * .megabyte
    config.directorySizeCritical = 500 * .megabyte
    let notifications = RecordingNotifications()
    let engine = MonitoringEngine(configuration: config, history: InMemoryHistoryStore(), notifications: notifications)
    let now = Date(timeIntervalSince1970: 10_000)
    for index in 0..<2_000 {
        _ = await engine.processSample(path: "\(builds)/artifact-\(index)", size: 1 * .megabyte, at: now.addingTimeInterval(Double(index)))
    }
    let diagnostics = await engine.diagnosticsSnapshot()
    #expect(diagnostics.trackedItemCount == 128)
    #expect(diagnostics.trackedDirectoryAggregates <= 4)
    #expect(await notifications.anomalies.isEmpty)
}

@Test("Directory aggregate overflow is deterministic and bounded")
func directoryAggregatesAreBounded() async {
    let root = "/tmp/diskswell-aggregate-bound-\(UUID().uuidString)"
    var config = MonitoringConfiguration(watchedRoots: [root])
    config.maxTrackedItems = 8
    config.maxTrackedDirectoryAggregates = 3
    config.minimumTrackedFileSize = .max
    let engine = MonitoringEngine(configuration: config, history: InMemoryHistoryStore(), notifications: RecordingNotifications())
    for index in 0..<100 { await engine.processSample(path: "\(root)/project-\(index)/file", size: 1) }
    let diagnostics = await engine.diagnosticsSnapshot()
    #expect(diagnostics.trackedDirectoryAggregates == 3)
    #expect(diagnostics.aggregateOverflows > 0)
    #expect(diagnostics.parentPropagationUpdates > 0)
}

@Test("Long history distinguishes sustained creep from a short surge")
func longHorizonCreep() {
    var config = MonitoringConfiguration(watchedRoots: ["/tmp"])
    config.directorySizeWarning = 100 * .gigabyte
    let day: TimeInterval = 24 * 60 * 60
    let now = Date(timeIntervalSince1970: 30 * day)
    let current = SizeSample(timestamp: now, size: 16 * .gigabyte, itemCount: 5_000, isApproximate: true)
    let checkpoints = [
        HistoricalCheckpoint(window: day, sample: SizeSample(timestamp: now.addingTimeInterval(-day), size: 15 * .gigabyte, itemCount: 4_700, isApproximate: true)),
        HistoricalCheckpoint(window: 7 * day, sample: SizeSample(timestamp: now.addingTimeInterval(-7 * day), size: 11 * .gigabyte, itemCount: 3_500, isApproximate: true)),
        HistoricalCheckpoint(window: 14 * day, sample: SizeSample(timestamp: now.addingTimeInterval(-14 * day), size: 7 * .gigabyte, itemCount: 2_000, isApproximate: true)),
        HistoricalCheckpoint(window: 21 * day, sample: SizeSample(timestamp: now.addingTimeInterval(-21 * day), size: 4 * .gigabyte, itemCount: 900, isApproximate: true)),
        HistoricalCheckpoint(window: 30 * day, sample: SizeSample(timestamp: now.addingTimeInterval(-29 * day), size: 2 * .gigabyte, itemCount: 200, isApproximate: true)),
    ]
    let recent = GrowthDetector.evaluateDirectoryRecent(samples: checkpoints.map(\.sample) + [current], configuration: config)
    let creep = LongHorizonDetector.evaluate(current: current, checkpoints: checkpoints, type: .directory, configuration: config)
    #expect(recent == .normal)
    #expect(creep.category == .creep)
    #expect(creep.severity == .critical)
    #expect(creep.reason == "Sustained directory growth")
    #expect(creep.interval >= 29 * day)
}

@Test("Stable large directories do not trigger growth anomalies")
func stableLargeDirectoryIsNormal() {
    let config = MonitoringConfiguration(watchedRoots: ["/tmp"])
    let day: TimeInterval = 24 * 60 * 60
    let now = Date(timeIntervalSince1970: 30 * day)
    let current = SizeSample(timestamp: now, size: 20 * .gigabyte, itemCount: 5_000)
    let checkpoints = [1.0, 7.0, 30.0].map {
        HistoricalCheckpoint(window: $0 * day, sample: SizeSample(timestamp: now.addingTimeInterval(-$0 * day), size: 20 * .gigabyte, itemCount: 5_000))
    }
    #expect(LongHorizonDetector.evaluate(current: current, checkpoints: checkpoints, type: .directory, configuration: config) == .normal)
}

@Test("Each persisted long-horizon window uses its configured threshold")
func longHorizonWindows() {
    let config = MonitoringConfiguration(watchedRoots: ["/tmp"])
    let day: TimeInterval = 24 * 60 * 60
    let now = Date(timeIntervalSince1970: 40 * day)
    let cases: [(TimeInterval, Int64)] = [
        (day, config.longGrowth24Hours),
        (7 * day, config.longGrowth7Days),
        (30 * day, config.longGrowth30Days),
    ]
    for (window, threshold) in cases {
        let current = SizeSample(timestamp: now, size: threshold + 1)
        let checkpoint = HistoricalCheckpoint(window: window, sample: SizeSample(timestamp: now.addingTimeInterval(-window), size: 0))
        let evaluation = LongHorizonDetector.evaluate(current: current, checkpoints: [checkpoint], type: .file, configuration: config)
        #expect(evaluation.category == .creep)
        #expect(evaluation.growth == threshold + 1)
        #expect(evaluation.interval == window)
    }
    #expect(config.periodicAuditInterval == day)
}

@Test("Cold start revisits a previously unresolved growing directory")
func startupAuditFindsUnresolvedDirectory() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let builds = root.appendingPathComponent("Builds")
    try FileManager.default.createDirectory(at: builds, withIntermediateDirectories: true)
    for index in 0..<12 {
        try Data(repeating: 1, count: 1_024).write(to: builds.appendingPathComponent("build-\(index)"))
    }
    let currentSize = TargetedFileInspector().inspect(path: builds.path, maxEntries: 32, maxDepth: 8).items.last?.size ?? 0
    #expect(currentSize > 0)
    let now = Date()
    let history = StartupHistoryStore(path: builds.path, checkpoint: SizeSample(timestamp: now.addingTimeInterval(-24 * 60 * 60), size: 0, itemCount: 2))
    var config = MonitoringConfiguration(watchedRoots: [root.path])
    config.maxStartupAuditPaths = 1
    config.maxAuditEntries = 32
    config.maxAuditEntriesPerPath = 32
    config.longGrowth24Hours = 1
    let engine = MonitoringEngine(configuration: config, history: history, notifications: RecordingNotifications())
    await engine.start()
    let anomaly = await engine.snapshot().recentAnomaly
    #expect(anomaly?.path == PathRules.normalize(builds.path))
    #expect(anomaly?.category == .creep)
    #expect(anomaly?.growth == currentSize)
    #expect(anomaly?.itemCountGrowth == 10)
    await engine.stop()
}

@Test("Startup audit finds an existing Safari WAL and respects work limits")
func startupAuditFindsExistingSafariWAL() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let websiteData = root.appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/WebKit/WebsiteData")
    let wal = websiteData.appendingPathComponent("Default/hash/LocalStorage/localstorage.sqlite3-wal")
    try FileManager.default.createDirectory(at: wal.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 1, count: 4_096).write(to: wal)
    let inspection = TargetedFileInspector().inspect(path: websiteData.path, maxEntries: 16, maxDepth: 8)
    let allocatedSize = inspection.items.first(where: { $0.path.hasSuffix("/Default/hash/LocalStorage/localstorage.sqlite3-wal") })?.size ?? 0
    #expect(allocatedSize > 0)
    var config = MonitoringConfiguration(watchedRoots: [websiteData.path])
    config.maxStartupAuditPaths = 1
    config.maxAuditEntries = 16
    config.maxAuditEntriesPerPath = 16
    config.safariWALWarning = 1
    config.safariWALCritical = allocatedSize * 2
    let engine = MonitoringEngine(configuration: config, history: InMemoryHistoryStore(), notifications: RecordingNotifications())
    await engine.start()
    let snapshot = await engine.snapshot()
    #expect(snapshot.recentAnomaly?.path == PathRules.normalize(wal.path))
    #expect(snapshot.recentAnomaly?.category == .safariWAL)
    #expect(snapshot.diagnostics.startupAuditPathsInspected == 1)
    #expect(snapshot.diagnostics.reconciliationWorkCount <= 16)
    await engine.stop()
}

@Test("Deep inspection stops before descendants beyond its depth cap")
func deepDirectoryInspectionIsBounded() throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    var directory = root
    for index in 0..<20 {
        directory.appendPathComponent("level-\(index)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    try Data([1]).write(to: directory.appendingPathComponent("leaf"))
    let result = TargetedFileInspector().inspect(path: root.path, maxEntries: 100, maxDepth: 3)
    #expect(result.truncated)
    #expect(result.visitedEntries <= 4)
    #expect(result.items.last?.isApproximate == true)
    #expect(!result.items.contains(where: { $0.path.hasSuffix("/leaf") }))
}

@Test("Rename and deletion reconciliation removes phantom aggregate bytes")
func renameAndDeletionReconcileAggregates() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let builds = root.appendingPathComponent("Builds")
    try FileManager.default.createDirectory(at: builds, withIntermediateDirectories: true)
    let first = builds.appendingPathComponent("first.bin")
    try Data(repeating: 1, count: 16).write(to: first)
    let allocatedSize = TargetedFileInspector().inspect(path: first.path, maxEntries: 1, maxDepth: 1).items.first?.size ?? 0
    #expect(allocatedSize > 0)
    var config = MonitoringConfiguration(watchedRoots: [root.path])
    config.directorySizeWarning = max(1, allocatedSize / 2)
    config.directorySizeCritical = allocatedSize * 2
    let engine = MonitoringEngine(configuration: config, history: InMemoryHistoryStore(), notifications: RecordingNotifications())
    await engine.ingestSyntheticEvents([builds.path])
    await engine.flushPendingEvents()
    #expect(await engine.snapshot().recentAnomaly?.path == builds.path)

    let moved = builds.appendingPathComponent("moved.bin")
    try FileManager.default.moveItem(at: first, to: moved)
    await engine.ingestSyntheticEvents([builds.path])
    await engine.flushPendingEvents()
    let renamedSize = await engine.snapshot().recentAnomaly?.currentSize
    #expect(renamedSize == allocatedSize)

    try FileManager.default.removeItem(at: moved)
    await engine.ingestSyntheticEvents([builds.path])
    await engine.flushPendingEvents()
    #expect(await engine.snapshot().recentAnomaly == nil)
}

@Test("Targeted inspection skips an excluded persistence subtree")
func directoryInspectionExcludesPersistence() throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let persistence = root.appendingPathComponent("DiskSwell")
    let sibling = root.appendingPathComponent("Other")
    try FileManager.default.createDirectory(at: persistence, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
    try Data([1]).write(to: persistence.appendingPathComponent("history.sqlite3"))
    try Data([2]).write(to: sibling.appendingPathComponent("changed.bin"))
    let result = TargetedFileInspector().inspect(path: root.path, maxEntries: 10, maxDepth: 3, excluding: [persistence.path])
    #expect(!result.items.contains(where: { $0.path.hasSuffix("/DiskSwell/history.sqlite3") }))
    #expect(result.items.contains(where: { $0.path.hasSuffix("/Other/changed.bin") }))
}

@Test("Safari origin attribution reads only nearby small metadata and falls back safely")
func safariOriginAttribution() throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/WebKit/WebsiteData/Default/hash/LocalStorage")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let wal = directory.appendingPathComponent("localstorage.sqlite3-wal")
    FileManager.default.createFile(atPath: wal.path, contents: nil)
    try Data("{\"origin\":\"https://Example.COM/path\"}".utf8).write(to: directory.appendingPathComponent("origin"))
    #expect(SafariWebKit.origin(forPath: wal.path) == "example.com")

    let binaryOrigin = Data([
        4, 0, 0, 0, 1, 104, 116, 116, 112,
        9, 0, 0, 0, 1, 49, 50, 55, 46, 48, 46, 48, 46, 49,
        1, 61, 34,
    ])
    try binaryOrigin.write(to: directory.appendingPathComponent("origin"))
    #expect(SafariWebKit.origin(forPath: wal.path) == "127.0.0.1")
    #expect(SourceAttribution.source(for: wal.path, applicationName: { _ in nil }) == .safariWebKit(origin: "127.0.0.1"))

    try FileManager.default.removeItem(at: directory.appendingPathComponent("origin"))
    #expect(SafariWebKit.origin(forPath: wal.path) == nil)
}

@Test("Source attribution distinguishes verified owners from likely hints")
func sourceAttributionConfidence() {
    let names = ["com.example.Editor": "Example Editor", "ru.keepcoder.Telegram": "Telegram"]
    let resolve: (String) -> String? = { names[$0] }
    #expect(SourceAttribution.source(for: "/tmp/home/Library/Developer/Xcode/DerivedData/App", applicationName: resolve) == .application(name: "Xcode", confidence: .verified))
    #expect(SourceAttribution.source(for: "/tmp/home/Library/Containers/com.example.Editor/Data/file", applicationName: resolve) == .application(name: "Example Editor", confidence: .verified))
    #expect(SourceAttribution.source(for: "/tmp/home/Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram/stable", applicationName: resolve) == .application(name: "Telegram", confidence: .likely))
    #expect(SourceAttribution.applicationBundleIdentifier(for: "/tmp/home/Library/Containers/com.example.Editor/Data/file") == "com.example.Editor")
    #expect(SourceAttribution.applicationBundleIdentifier(for: "/tmp/home/Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram/stable") == "ru.keepcoder.Telegram")
    #expect(SourceAttribution.source(for: "/tmp/home/Library/Application Support/Example Cache/data", applicationName: resolve) == .application(name: "Example Cache", confidence: .likely))
    #expect(SourceAttribution.quarantineAgent(in: "0081;66ac8f00;Safari;UUID") == "Safari")
    #expect(SourceAttribution.source(for: "/tmp/home/Library/ordinary-file", applicationName: resolve) == .generic)
}

@Test("Safari website databases get origin attribution without WAL thresholds")
func safariWebsiteDatabaseAttribution() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let originDirectory = root.appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/WebKit/WebsiteData/Default/hash")
    let database = originDirectory.appendingPathComponent("IndexedDB/IndexedDB.sqlite3")
    try FileManager.default.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{\"origin\":\"http://127.0.0.1\"}".utf8).write(to: originDirectory.appendingPathComponent("origin"))

    let engine = MonitoringEngine(configuration: MonitoringConfiguration(watchedRoots: [root.path]), history: InMemoryHistoryStore(), notifications: RecordingNotifications())
    let start = Date(timeIntervalSince1970: 8_000)
    #expect(await engine.processSample(path: database.path, size: 0, at: start) == nil)
    let anomaly = await engine.processSample(path: database.path, size: 600 * .megabyte, at: start.addingTimeInterval(18))
    #expect(anomaly?.source == .safariWebKit(origin: "127.0.0.1"))
    #expect(anomaly?.severity == .warning)
    #expect(anomaly?.category == .surge)
}

@Test("Engine tracked state remains bounded")
func engineTrackedStateBound() async {
    var config = MonitoringConfiguration(watchedRoots: ["/tmp"])
    config.maxTrackedItems = 3
    config.minimumTrackedFileSize = 0
    let engine = MonitoringEngine(configuration: config, history: InMemoryHistoryStore(), notifications: RecordingNotifications())
    for index in 0..<10 { await engine.processSample(path: "/tmp/item-\(index)", size: Int64(index + 1)) }
    let diagnostics = await engine.diagnosticsSnapshot()
    #expect(diagnostics.trackedItemCount == 3)
    #expect(diagnostics.trackedItemEvictions == 7)
}

@Test("A missing child covered by an accessible root does not degrade monitoring")
func coveredMissingRootIsIgnored() async {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let missing = root.appendingPathComponent("missing").path
    let config = MonitoringConfiguration(watchedRoots: [root.path, missing])
    let engine = MonitoringEngine(configuration: config, history: InMemoryHistoryStore(), notifications: RecordingNotifications())
    await engine.start()
    let snapshot = await engine.snapshot()
    #expect(snapshot.status == .monitoring)
    #expect(snapshot.accessIssues.isEmpty)
    await engine.stop()
}

@Test("Permission errors explain the required Full Disk Access permission")
func permissionErrorIsActionable() {
    let error = NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
    let issue = TargetedFileInspector.permissionIssue(error, path: "/private")
    #expect(issue?.kind == .permissionDenied)
    #expect(issue?.message.contains("Full Disk Access") == true)
}

@Test("A root that appears later is monitored without restarting the app")
func missingRootRecovers() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    var config = MonitoringConfiguration(watchedRoots: [root.path])
    config.safetyInterval = .milliseconds(10)
    let engine = MonitoringEngine(configuration: config, history: InMemoryHistoryStore(), notifications: RecordingNotifications())
    await engine.start()
    #expect(await engine.snapshot().status == .degraded)

    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try await Task.sleep(for: .milliseconds(100))
    let snapshot = await engine.snapshot()
    #expect(snapshot.status == .monitoring)
    #expect(snapshot.accessIssues.isEmpty)
    #expect(snapshot.diagnostics.recoveryCount >= 1)
    await engine.stop()
}

@Test("Transient history failure recovers without stopping monitoring")
func historyFailureRecovers() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var config = MonitoringConfiguration(watchedRoots: [root.path])
    config.safetyInterval = .milliseconds(10)
    let history = RecoveringHistoryStore()
    let engine = MonitoringEngine(configuration: config, history: history, notifications: RecordingNotifications())
    await engine.start()
    try await Task.sleep(for: .milliseconds(1_200))
    let diagnostics = await engine.diagnosticsSnapshot()
    #expect(await history.prepareCount >= 2)
    #expect(diagnostics.errorCount >= 1)
    #expect(diagnostics.recoveryCount >= 1)
    #expect(await engine.status == .monitoring)
    await engine.stop()
}

@Test("Suppressed notifications are not counted as delivered")
func suppressedNotificationIsNotCounted() async {
    let engine = MonitoringEngine(history: InMemoryHistoryStore(), notifications: SuppressingNotifications())
    _ = await engine.processSample(path: "/tmp/large", size: 2 * .gigabyte)
    let diagnostics = await engine.diagnosticsSnapshot()
    #expect(diagnostics.anomalyCount == 1)
    #expect(diagnostics.notificationCount == 0)
}

@Test("Different anomalous paths each notify")
func differentAnomalousPathsNotify() async {
    let notifications = RecordingNotifications()
    let engine = MonitoringEngine(history: InMemoryHistoryStore(), notifications: notifications)
    _ = await engine.processSample(path: "/tmp/large-a", size: 2 * .gigabyte)
    _ = await engine.processSample(path: "/tmp/large-b", size: 2 * .gigabyte)
    #expect(await notifications.anomalies.map(\.path) == ["/tmp/large-a", "/tmp/large-b"])
}

@Test("Deleting an anomalous file clears tracked and menu state")
func deletingAnomalousFileClearsState() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("large.bin")
    try Data(repeating: 1, count: 4_096).write(to: file)

    var config = MonitoringConfiguration(watchedRoots: [root.path])
    config.minimumTrackedFileSize = 1
    config.largeFileWarning = 1
    let engine = MonitoringEngine(configuration: config, history: InMemoryHistoryStore(), notifications: RecordingNotifications())
    await engine.ingestSyntheticEvents([file.path])
    await engine.flushPendingEvents()
    #expect(await engine.snapshot().recentAnomaly?.path == file.path)

    try FileManager.default.removeItem(at: file)
    await engine.ingestSyntheticEvents([file.path])
    await engine.flushPendingEvents()
    #expect(await engine.snapshot().recentAnomaly == nil)
    #expect(await engine.diagnosticsSnapshot().trackedItemCount == 0)
}

private actor RecordingNotifications: NotificationDelivering {
    private(set) var anomalies: [Anomaly] = []
    func deliver(_ anomaly: Anomaly) -> Bool {
        if anomalies.count < 128 { anomalies.append(anomaly) }
        return true
    }
}

private actor SuppressingNotifications: NotificationDelivering {
    func deliver(_ anomaly: Anomaly) -> Bool { false }
}

private actor RecoveringHistoryStore: HistoryStore {
    private(set) var prepareCount = 0

    func prepare() throws {
        prepareCount += 1
        if prepareCount == 1 { throw SQLiteHistoryError.open("test failure") }
    }

    func record(sample: SizeSample, path: String, type: ItemType, source: SourceClassification) {}
    func record(anomaly: Anomaly) {}
    func resolveAnomaly(path: String, at: Date) {}
    func applyRetention(now: Date) {}
    func statistics() -> HistoryStatistics { HistoryStatistics(sampleCount: 0, anomalyCount: 0, fileSize: 0) }
}

private actor StartupHistoryStore: HistoryStore {
    let path: String
    let checkpoint: SizeSample

    init(path: String, checkpoint: SizeSample) {
        self.path = PathRules.normalize(path)
        self.checkpoint = checkpoint
    }

    func prepare() {}
    func record(sample: SizeSample, path: String, type: ItemType, source: SourceClassification) {}
    func record(anomaly: Anomaly) {}
    func resolveAnomaly(path: String, at: Date) {}
    func applyRetention(now: Date) {}
    func statistics() -> HistoryStatistics { HistoryStatistics(sampleCount: 1, anomalyCount: 1, fileSize: 0) }
    func longHorizonCheckpoints(path: String, at: Date) async -> [HistoricalCheckpoint] {
        path == self.path ? [HistoricalCheckpoint(window: 24 * 60 * 60, sample: checkpoint)] : []
    }
    func auditPaths(limit: Int) async -> [AuditPath] {
        [AuditPath(path: path, type: .directory, source: .generic, unresolvedSeverity: .warning, lastAnomalyUpdate: checkpoint.timestamp, lastKnownSize: checkpoint.size)]
    }
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("DiskSwellTests-\(UUID().uuidString)", isDirectory: true)
}
