import Darwin
import Foundation

public enum MonitoringEngineError: Error, LocalizedError, Equatable {
    case monitoringDisabled
    case auditAlreadyRunning

    public var errorDescription: String? {
        switch self {
        case .monitoringDisabled: "Enable monitoring before running an audit."
        case .auditAlreadyRunning: "An audit is already running."
        }
    }
}

public actor MonitoringEngine {
    public private(set) var status: MonitoringStatus = .ready
    private let configuration: MonitoringConfiguration
    private let history: any HistoryStore
    private let notifications: any NotificationDelivering
    private let inspector = TargetedFileInspector()
    private let ignoredRoots = [SQLiteHistoryStore.defaultURL().deletingLastPathComponent().path]
    private let configuredRoots: [String]
    private var coalescer: EventCoalescer
    private var trackedItems: TrackedItemStore
    private var directoryAggregates: DirectoryAggregateStore
    private var dirtyAggregates: Set<String> = []
    private var remainingPromotions = 0
    private var remainingLongHorizonQueries = 0
    private var freeSpaceDetector = FreeSpaceDetector()
    private var diagnostics = DiagnosticsSnapshot()
    private var activeAnomalies: [String: Anomaly] = [:]
    private var recentDetections: [DetectionRecord] = []
    private var freeSpace: Int64?
    private var lastFreeSpaceCheck: Date = .distantPast
    private var lastPeriodicAudit: Date = .distantPast
    private var accessIssues: [String: AccessIssue] = [:]
    private var monitor: FSEventsMonitor?
    private var monitoredRoots: [String] = []
    private var eventTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var safetyTask: Task<Void, Never>?
    private var snapshotContinuation: AsyncStream<MonitoringSnapshot>.Continuation?
    private var historyAvailable = false
    private var historyHasFailed = false
    private var lastHistoryRetry: Date = .distantPast
    private var notificationsEnabled = true
    private var lifecycleGeneration = 0
    private var startingGeneration: Int?
    private var manualAuditRunning = false

    public init(configuration: MonitoringConfiguration = MonitoringConfiguration(), history: (any HistoryStore)? = nil, notifications: (any NotificationDelivering)? = nil) {
        self.configuration = configuration
        self.history = history ?? SQLiteHistoryStore()
        self.notifications = notifications ?? LocalNotificationService(capacity: configuration.maxPendingNotifications)
        configuredRoots = Array(Set(configuration.watchedRoots.prefix(configuration.maxWatchedRoots).map(PathRules.normalize)).sorted())
        coalescer = EventCoalescer(roots: configuration.normalizedRoots, capacity: configuration.maxDirtyPaths)
        trackedItems = TrackedItemStore(capacity: configuration.maxTrackedItems)
        directoryAggregates = DirectoryAggregateStore(capacity: configuration.maxTrackedDirectoryAggregates)
        for root in configuration.normalizedRoots {
            directoryAggregates.upsert(DirectoryAggregate(path: root, lastSeen: .distantPast, sampleCapacity: configuration.maxRecentSamplesPerItem))
        }
        diagnostics.trackedDirectoryAggregates = directoryAggregates.aggregates.count
        diagnostics.aggregateEvictions = directoryAggregates.evictions
        diagnostics.aggregateOverflows = directoryAggregates.overflows
    }

    public func snapshots() -> AsyncStream<MonitoringSnapshot> {
        snapshotContinuation?.finish()
        var continuation: AsyncStream<MonitoringSnapshot>.Continuation!
        let stream = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation = $0 }
        snapshotContinuation = continuation
        emitSnapshot()
        return stream
    }

    public func start() async {
        guard startingGeneration == nil, status == .ready || status == .stopped else { return }
        lifecycleGeneration += 1
        let generation = lifecycleGeneration
        startingGeneration = generation
        defer { if startingGeneration == generation { startingGeneration = nil } }
        let now = Date()
        await prepareHistoryIfNeeded(at: now, force: true)
        guard lifecycleGeneration == generation else { return }
        refreshMonitoringRoots()
        await checkFreeSpace(at: now, force: true)
        guard lifecycleGeneration == generation else { return }
        await applyHistoryRetention(at: now)
        await runTargetedAudit(at: now, startup: true, requiredGeneration: generation)
        guard lifecycleGeneration == generation else { return }
        lastPeriodicAudit = now
        safetyTask = Task { [weak self, interval = configuration.safetyInterval, generation] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { break }
                guard let self else { break }
                let now = Date()
                await self.refreshMonitoringRoots()
                guard await self.lifecycleIsCurrent(generation) else { break }
                await self.prepareHistoryIfNeeded(at: now)
                guard await self.lifecycleIsCurrent(generation) else { break }
                await self.checkFreeSpace(at: now)
                guard await self.lifecycleIsCurrent(generation) else { break }
                await self.runPeriodicAuditIfDue(at: now, requiredGeneration: generation)
            }
        }
        await refreshHistoryStatistics()
        emitSnapshot()
    }

    public func stop() {
        lifecycleGeneration += 1
        startingGeneration = nil
        eventTask?.cancel()
        debounceTask?.cancel()
        safetyTask?.cancel()
        monitor?.stop()
        eventTask = nil
        debounceTask = nil
        safetyTask = nil
        monitor = nil
        monitoredRoots = []
        status = .stopped
        emitSnapshot()
    }

    public func snapshot() -> MonitoringSnapshot {
        MonitoringSnapshot(status: status, freeSpace: freeSpace, recentAnomaly: activeAnomalies.values.max(by: { $0.detectedAt < $1.detectedAt }), recentDetections: recentDetections, accessIssues: accessIssues.values.sorted(by: { $0.root < $1.root }), diagnostics: diagnostics)
    }

    public func diagnosticsSnapshot() -> DiagnosticsSnapshot { diagnostics }

    public func setNotificationsEnabled(_ enabled: Bool) { notificationsEnabled = enabled }

    public func runManualAudit(at now: Date = Date()) async throws {
        guard status == .monitoring || status == .degraded else { throw MonitoringEngineError.monitoringDisabled }
        guard !manualAuditRunning else { throw MonitoringEngineError.auditAlreadyRunning }
        manualAuditRunning = true
        defer { manualAuditRunning = false }
        let generation = lifecycleGeneration
        await runTargetedAudit(at: now, startup: false, manual: true, requiredGeneration: generation)
        guard lifecycleIsCurrent(generation), status == .monitoring || status == .degraded else { throw MonitoringEngineError.monitoringDisabled }
    }

    public func resetData() async throws {
        guard !manualAuditRunning else { throw MonitoringEngineError.auditAlreadyRunning }
        let shouldResume = status == .monitoring || status == .degraded || startingGeneration != nil
        stop()
        historyAvailable = false
        do { try await history.reset() }
        catch {
            if shouldResume { await start() }
            throw error
        }
        historyAvailable = true
        historyHasFailed = false
        resetRuntimeState()
        await refreshHistoryStatistics()
        emitSnapshot()
        if shouldResume { await start() }
    }

    func lifecycleResourceCounts() -> (monitors: Int, tasks: Int) {
        (monitor == nil ? 0 : 1, [eventTask, debounceTask, safetyTask].compactMap { $0 }.count)
    }

    public func ingestSyntheticEvents(_ paths: [String]) {
        receive(FileSystemEventBatch(paths: Array(paths.prefix(configuration.maxRawEventsPerBatch)), receivedCount: paths.count, droppedCount: max(0, paths.count - configuration.maxRawEventsPerBatch)))
    }

    public func flushPendingEvents(at now: Date = Date()) async {
        debounceTask?.cancel()
        debounceTask = nil
        await processDirtyPaths(at: now)
    }

    @discardableResult
    public func processSample(path: String, type: ItemType = .file, size: Int64, itemCount: Int64? = nil, isApproximate: Bool = false, at now: Date = Date()) async -> Anomaly? {
        resetBatchBudgets()
        let result = await process(InspectedItem(path: PathRules.normalize(path), type: type, size: max(0, size), itemCount: itemCount, isApproximate: isApproximate), at: now)
        let aggregateResults = await flushAggregates(at: now)
        await deliver(([result.notification] + aggregateResults.notifications).compactMap { $0 })
        emitSnapshot()
        return result.anomaly ?? aggregateResults.anomalies.last
    }

    func runTargetedAudit(at now: Date = Date(), startup: Bool, manual: Bool = false, requiredGeneration: Int? = nil) async {
        let started = Date()
        let pathLimit = startup ? configuration.maxStartupAuditPaths : configuration.maxPeriodicAuditPaths
        var remainingEntries = configuration.maxAuditEntries
        resetBatchBudgets()
        await prepareHistoryIfNeeded(at: now)
        guard lifecycleIsCurrent(requiredGeneration) else { return }
        let targets = await auditTargets(limit: pathLimit, startup: startup)
        guard lifecycleIsCurrent(requiredGeneration) else { return }
        var pending: [Anomaly] = []
        diagnostics.reconciliationRuns += 1

        for target in targets.prefix(pathLimit) {
            guard lifecycleIsCurrent(requiredGeneration) else { return }
            guard remainingEntries > 0, Date().timeIntervalSince(started) < configuration.maxAuditDuration else {
                diagnostics.droppedOrCollapsedWork += 1
                break
            }
            if let severity = target.unresolvedSeverity, target.type == .directory,
               ensureAggregate(target.path, at: now), var aggregate = directoryAggregates.aggregates[target.path] {
                aggregate.severity = severity
                aggregate.lastNotification = target.lastAnomalyUpdate
                aggregate.lastNotifiedSize = target.lastKnownSize ?? 0
                directoryAggregates.upsert(aggregate)
            } else if let severity = target.unresolvedSeverity, target.type == .file, trackedItems.items[target.path] == nil {
                let item = TrackedItem(path: PathRules.normalize(target.path), type: .file, source: target.source, samples: SampleRing(capacity: configuration.maxRecentSamplesPerItem), lastSeen: target.lastAnomalyUpdate ?? now, severity: severity, lastNotification: target.lastAnomalyUpdate, lastNotifiedSize: target.lastKnownSize ?? 0)
                let previousEvictions = trackedItems.evictions
                if let evicted = trackedItems.upsert(item) { subtractContribution(of: evicted, at: now) }
                diagnostics.trackedItemEvictions += trackedItems.evictions - previousEvictions
            }
            let budget = min(configuration.maxAuditEntriesPerPath, remainingEntries)
            let normalizedTarget = PathRules.normalize(target.path)
            let specialized = normalizedTarget.contains("/Library/Containers/com.apple.Safari/Data/Library/WebKit/WebsiteData")
            let shallowRoot = configuredRoots.contains(normalizedTarget) && target.unresolvedSeverity == nil
            let depth = specialized ? configuration.maxAuditDepth : (shallowRoot ? min(2, configuration.maxAuditDepth) : configuration.maxAuditDepth)
            let result = inspector.inspect(path: target.path, maxEntries: budget, maxDepth: depth, excluding: ignoredRoots)
            remainingEntries -= result.visitedEntries
            diagnostics.reconciliationWorkCount += result.visitedEntries
            if startup { diagnostics.startupAuditPathsInspected += 1 }
            else if manual { diagnostics.manualAuditPathsInspected += 1 }
            else { diagnostics.periodicAuditPathsInspected += 1 }
            if let issue = result.accessIssue { record(issue: issue) }
            if result.accessIssue == nil { await resolveMissingItems(under: target.path, at: now) }
            for item in result.items {
                let outcome = await process(item, at: now, forceEvaluation: true)
                guard lifecycleIsCurrent(requiredGeneration) else { return }
                if let notification = outcome.notification, pending.count < configuration.maxPendingNotifications { pending.append(notification) }
            }
            if result.truncated { diagnostics.droppedOrCollapsedWork += 1 }
        }

        let aggregateResults = await flushAggregates(at: now)
        guard lifecycleIsCurrent(requiredGeneration) else { return }
        pending.append(contentsOf: aggregateResults.notifications.prefix(max(0, configuration.maxPendingNotifications - pending.count)))
        await deliver(pending)
        await applyHistoryRetention(at: now)
        await refreshHistoryStatistics()
        if startup { diagnostics.lastStartupAudit = now }
        else if manual { diagnostics.lastManualAudit = now }
        else { diagnostics.lastPeriodicAudit = now }
        emitSnapshot()
    }

    private func runPeriodicAuditIfDue(at now: Date, requiredGeneration: Int? = nil) async {
        guard now.timeIntervalSince(lastPeriodicAudit) >= configuration.periodicAuditInterval else { return }
        lastPeriodicAudit = now
        await runTargetedAudit(at: now, startup: false, requiredGeneration: requiredGeneration)
    }

    private func receive(_ batch: FileSystemEventBatch, requiredGeneration: Int? = nil) {
        guard lifecycleIsCurrent(requiredGeneration) else { return }
        diagnostics.fseventsReceived += batch.receivedCount
        diagnostics.droppedOrCollapsedWork += batch.droppedCount
        let previousOverflows = coalescer.overflowCount
        let previousCollapsed = coalescer.collapsedCount
        coalescer.ingest(batch.paths.filter { path in !ignoredRoots.contains(where: { PathRules.contains($0, path) }) })
        diagnostics.dirtyPathCount = coalescer.count
        diagnostics.dirtyPathOverflows += coalescer.overflowCount - previousOverflows
        diagnostics.droppedOrCollapsedWork += coalescer.collapsedCount - previousCollapsed
        guard debounceTask == nil else { return }
        debounceTask = Task { [weak self, delay = configuration.debounce, generation = requiredGeneration] in
            do { try await Task.sleep(for: delay) } catch { return }
            await self?.processDirtyPaths(at: Date(), requiredGeneration: generation)
        }
    }

    private func processDirtyPaths(at now: Date, requiredGeneration: Int? = nil) async {
        guard lifecycleIsCurrent(requiredGeneration) else { return }
        debounceTask = nil
        let started = ContinuousClock.now
        let paths = coalescer.drain()
        guard !paths.isEmpty else { return }
        resetBatchBudgets()
        await prepareHistoryIfNeeded(at: now)
        guard lifecycleIsCurrent(requiredGeneration) else { return }
        diagnostics.coalescedBatches += 1
        diagnostics.dirtyPathCount = 0
        var pending: [Anomaly] = []
        pending.reserveCapacity(min(configuration.maxPendingNotifications, 8))
        for path in paths {
            let result = inspector.inspect(path: path, maxEntries: configuration.maxInspectionEntries, maxDepth: configuration.maxInspectionDepth, excluding: ignoredRoots)
            if let issue = result.accessIssue { record(issue: issue) }
            if result.truncated { diagnostics.droppedOrCollapsedWork += 1 }
            if result.accessIssue == nil { await resolveMissingItems(under: path, at: now) }
            for item in result.items {
                let outcome = await process(item, at: now)
                guard lifecycleIsCurrent(requiredGeneration) else { return }
                if let notification = outcome.notification {
                    if pending.count < configuration.maxPendingNotifications { pending.append(notification) }
                    else { diagnostics.droppedOrCollapsedWork += 1 }
                }
            }
        }
        let aggregateResults = await flushAggregates(at: now)
        guard lifecycleIsCurrent(requiredGeneration) else { return }
        pending.append(contentsOf: aggregateResults.notifications.prefix(max(0, configuration.maxPendingNotifications - pending.count)))
        await deliver(pending)
        await checkFreeSpace(at: now)
        await applyHistoryRetention(at: now)
        await refreshHistoryStatistics()
        let elapsed = started.duration(to: .now).components
        diagnostics.lastProcessingLatencyMilliseconds = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
        emitSnapshot()
    }

    private func process(_ inspected: InspectedItem, at now: Date, forceEvaluation: Bool = false) async -> (anomaly: Anomaly?, notification: Anomaly?) {
        let path = PathRules.normalize(inspected.path)
        if inspected.type == .directory {
            reconcileAggregate(path: path, size: inspected.size, itemCount: inspected.itemCount ?? 0, approximate: inspected.isApproximate, at: now, forceEvaluation: forceEvaluation)
            return (nil, nil)
        }

        let safariWAL = SafariWebKit.isWAL(path: path)
        let previous = trackedItems.items[path]
        guard previous != nil || safariWAL || inspected.size >= configuration.minimumTrackedFileSize || monitoringRoot(for: path) != nil else { return (nil, nil) }
        let analyze = safariWAL || inspected.size >= configuration.minimumTrackedFileSize || (previous?.size ?? 0) >= configuration.minimumTrackedFileSize || (previous?.severity ?? .normal) != .normal
        let source: SourceClassification = analyze ? SourceAttribution.source(for: path) : .generic
        var item = previous ?? TrackedItem(path: path, type: .file, source: source, samples: SampleRing(capacity: configuration.maxRecentSamplesPerItem), lastSeen: now)
        item.lastSeen = now
        item.source = source
        let changed = item.samples.values.last?.size != inspected.size
        if !changed, !forceEvaluation {
            trackedItems.upsert(item)
            return (nil, nil)
        }
        if changed {
            let delta = inspected.size - (previous?.size ?? 0)
            updateParentAggregates(for: path, byteDelta: delta, itemDelta: previous == nil ? 1 : 0, at: now, allowPromotion: true)
            item.samples.append(SizeSample(timestamp: now, size: inspected.size))
        }

        let detectorSource: SourceClassification = safariWAL ? source : .generic
        var evaluation = analyze ? GrowthDetector.evaluate(samples: item.samples.values, source: detectorSource, configuration: configuration) : .normal
        if analyze, historyAvailable, changed {
            do { try await history.record(sample: SizeSample(timestamp: now, size: inspected.size), path: path, type: .file, source: source) }
            catch { historyFailed("Sample persistence failed", error: error) }
        }
        if analyze, historyAvailable, remainingLongHorizonQueries > 0 {
            remainingLongHorizonQueries -= 1
            diagnostics.longHorizonQueries += 1
            do {
                let checkpoints = try await history.longHorizonCheckpoints(path: path, at: now)
                let long = LongHorizonDetector.evaluate(current: SizeSample(timestamp: now, size: inspected.size), checkpoints: checkpoints, type: .file, configuration: configuration)
                promote(&evaluation, long)
            } catch { historyFailed("Long-horizon query failed", error: error) }
        }

        let previousSeverity = item.severity
        let shouldNotify = GrowthDetector.shouldNotify(item: &item, evaluation: evaluation, now: now, configuration: configuration)
        let previousEvictions = trackedItems.evictions
        if let evicted = trackedItems.upsert(item) {
            subtractContribution(of: evicted, at: now)
            activeAnomalies.removeValue(forKey: evicted.path)
        }
        diagnostics.trackedItemEvictions += trackedItems.evictions - previousEvictions
        diagnostics.trackedItemCount = trackedItems.items.count
        if changed { diagnostics.sampleCount += 1 }

        if evaluation.severity == .normal {
            activeAnomalies.removeValue(forKey: path)
            if previousSeverity != .normal, historyAvailable {
                do { try await history.resolveAnomaly(path: path, at: now) }
                catch { historyFailed("Anomaly resolution failed", error: error) }
            }
            return (nil, nil)
        }
        let anomaly = Anomaly(path: path, source: source, severity: evaluation.severity, currentSize: inspected.size, growth: evaluation.growth, interval: evaluation.interval, reason: evaluation.reason, detectedAt: now, category: evaluation.category)
        if trackedItems.items[path] != nil { activeAnomalies[path] = anomaly }
        diagnostics.anomalyCount += 1
        if evaluation.category == .creep { diagnostics.creepAnomalies += 1 }
        if historyAvailable {
            do { try await history.record(anomaly: anomaly) }
            catch { historyFailed("Anomaly persistence failed", error: error) }
        }
        return (anomaly, shouldNotify ? anomaly : nil)
    }

    private func updateParentAggregates(for path: String, byteDelta: Int64, itemDelta: Int64, at now: Date, allowPromotion: Bool) {
        guard byteDelta != 0 || itemDelta != 0, let root = monitoringRoot(for: path) else { return }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        var chain: [String] = []
        var candidate = parent
        let maxDepth = max(1, configuration.maxParentPropagationDepth)
        while PathRules.contains(root, candidate), chain.count < maxDepth {
            chain.append(candidate)
            if candidate == root { break }
            candidate = URL(fileURLWithPath: candidate).deletingLastPathComponent().path
        }
        if !chain.contains(root) {
            if chain.count == maxDepth { chain.removeLast() }
            chain.append(root)
        }
        if allowPromotion, directoryAggregates.aggregates[parent] == nil { _ = ensureAggregate(parent, at: now) }

        for aggregatePath in chain where directoryAggregates.aggregates[aggregatePath] != nil {
            guard var aggregate = directoryAggregates.aggregates[aggregatePath] else { continue }
            aggregate.size = max(0, saturatedAdd(aggregate.size, byteDelta))
            aggregate.itemCount = max(0, saturatedAdd(aggregate.itemCount, itemDelta))
            aggregate.lastSeen = now
            aggregate.recentGrowth = max(0, saturatedAdd(aggregate.recentGrowth, max(0, byteDelta)))
            aggregate.isApproximate = true
            directoryAggregates.upsert(aggregate)
            dirtyAggregates.insert(aggregatePath)
            diagnostics.parentPropagationUpdates += 1
        }
    }

    private func reconcileAggregate(path: String, size: Int64, itemCount: Int64, approximate: Bool, at now: Date, forceEvaluation: Bool) {
        guard ensureAggregate(path, at: now), var aggregate = directoryAggregates.aggregates[path] else { return }
        let changed = aggregate.size != size || aggregate.itemCount != itemCount || aggregate.isApproximate != approximate
        aggregate.recentGrowth = max(0, size - aggregate.size)
        aggregate.size = max(0, size)
        aggregate.itemCount = max(0, itemCount)
        aggregate.isApproximate = approximate
        aggregate.lastSeen = now
        directoryAggregates.upsert(aggregate)
        if changed || forceEvaluation { dirtyAggregates.insert(path) }
    }

    private func ensureAggregate(_ path: String, at now: Date) -> Bool {
        let path = PathRules.normalize(path)
        if directoryAggregates.aggregates[path] != nil { return true }
        guard remainingPromotions > 0, monitoringRoot(for: path) != nil else { return false }
        remainingPromotions -= 1
        let previousEvictions = directoryAggregates.evictions
        let previousOverflows = directoryAggregates.overflows
        let rejected = directoryAggregates.upsert(DirectoryAggregate(path: path, lastSeen: now, sampleCapacity: configuration.maxRecentSamplesPerItem))
        if directoryAggregates.aggregates[path] != nil { diagnostics.aggregatePromotions += 1 }
        diagnostics.aggregateEvictions += directoryAggregates.evictions - previousEvictions
        diagnostics.aggregateOverflows += directoryAggregates.overflows - previousOverflows
        if let rejected { activeAnomalies.removeValue(forKey: rejected.path) }
        diagnostics.trackedDirectoryAggregates = directoryAggregates.aggregates.count
        return directoryAggregates.aggregates[path] != nil
    }

    private func subtractContribution(of item: TrackedItem, at now: Date) {
        updateParentAggregates(for: item.path, byteDelta: -item.size, itemDelta: -1, at: now, allowPromotion: false)
    }

    private func flushAggregates(at now: Date) async -> (anomalies: [Anomaly], notifications: [Anomaly]) {
        let paths = dirtyAggregates.sorted()
        dirtyAggregates.removeAll(keepingCapacity: true)
        var anomalies: [Anomaly] = []
        var notifications: [Anomaly] = []
        for path in paths {
            guard var aggregate = directoryAggregates.aggregates[path] else { continue }
            let sample = SizeSample(timestamp: now, size: aggregate.size, itemCount: aggregate.itemCount, isApproximate: aggregate.isApproximate)
            if aggregate.samples.values.last != sample { aggregate.samples.append(sample) }
            if historyAvailable {
                do { try await history.record(sample: sample, path: path, type: .directory, source: SourceAttribution.source(for: path)) }
                catch { historyFailed("Aggregate persistence failed", error: error) }
            }
            var evaluation = GrowthDetector.evaluateDirectoryRecent(samples: aggregate.samples.values, configuration: configuration)
            var checkpoints: [HistoricalCheckpoint] = []
            if historyAvailable, remainingLongHorizonQueries > 0 {
                remainingLongHorizonQueries -= 1
                diagnostics.longHorizonQueries += 1
                do {
                    checkpoints = try await history.longHorizonCheckpoints(path: path, at: now)
                    promote(&evaluation, LongHorizonDetector.evaluate(current: sample, checkpoints: checkpoints, type: .directory, configuration: configuration))
                } catch { historyFailed("Aggregate long-horizon query failed", error: error) }
            } else {
                promote(&evaluation, LongHorizonDetector.evaluate(current: sample, checkpoints: [], type: .directory, configuration: configuration))
            }
            if sample.isApproximate || aggregate.samples.values.contains(where: \.isApproximate) || checkpoints.contains(where: { $0.sample.isApproximate }) { evaluation = .normal }
            if configuration.normalizedRoots.contains(path), evaluation.category == .largeAggregate { evaluation = .normal }

            let previousSeverity = aggregate.severity
            aggregate.severity = evaluation.severity
            if evaluation.severity == .normal {
                activeAnomalies.removeValue(forKey: path)
                if previousSeverity != .normal, historyAvailable {
                    do { try await history.resolveAnomaly(path: path, at: now) }
                    catch { historyFailed("Aggregate anomaly resolution failed", error: error) }
                }
                directoryAggregates.upsert(aggregate)
                continue
            }

            let baseline = (checkpoints.map(\.sample) + aggregate.samples.values).min { lhs, rhs in
                abs(now.timeIntervalSince(lhs.timestamp) - evaluation.interval) < abs(now.timeIntervalSince(rhs.timestamp) - evaluation.interval)
            }
            let countGrowth = baseline.flatMap { old in sample.itemCount.flatMap { current in old.itemCount.map { current - $0 } } } ?? 0
            let anomaly = Anomaly(path: path, source: SourceAttribution.source(for: path), severity: evaluation.severity, currentSize: aggregate.size, growth: evaluation.growth, interval: evaluation.interval, reason: evaluation.reason, detectedAt: now, category: evaluation.category, itemCountGrowth: countGrowth, isApproximate: aggregate.isApproximate || (baseline?.isApproximate ?? false))
            activeAnomalies[path] = anomaly
            anomalies.append(anomaly)
            diagnostics.anomalyCount += 1
            if evaluation.category == .creep { diagnostics.creepAnomalies += 1 }

            let cooldown = evaluation.category == .creep ? configuration.slowGrowthNotificationCooldown : configuration.notificationCooldown
            let notify = previousSeverity == .normal
                || evaluation.severity > previousSeverity
                || aggregate.size - aggregate.lastNotifiedSize >= configuration.notificationGrowthStep
                || (aggregate.lastNotification.map { now.timeIntervalSince($0) >= cooldown && aggregate.size != aggregate.lastNotifiedSize } ?? true)
            if notify {
                aggregate.lastNotification = now
                aggregate.lastNotifiedSize = aggregate.size
                notifications.append(anomaly)
            }
            directoryAggregates.upsert(aggregate)
            if historyAvailable {
                do { try await history.record(anomaly: anomaly) }
                catch { historyFailed("Aggregate anomaly persistence failed", error: error) }
            }
        }
        diagnostics.trackedDirectoryAggregates = directoryAggregates.aggregates.count
        return (anomalies, notifications)
    }

    private func resolveMissingItems(under inspectedPath: String, at now: Date) async {
        let normalizedPath = PathRules.normalize(inspectedPath)
        let descendantPrefix = normalizedPath == "/" ? "/" : normalizedPath + "/"
        let isInspected = { (path: String) in path == normalizedPath || path.hasPrefix(descendantPrefix) }
        let missing = trackedItems.items.values.filter { item in
            guard isInspected(item.path) else { return false }
            var metadata = stat()
            return Darwin.lstat(item.path, &metadata) != 0 && errno == ENOENT
        }
        for item in missing {
            subtractContribution(of: item, at: now)
            trackedItems.remove(item.path)
            activeAnomalies.removeValue(forKey: item.path)
            if historyAvailable {
                do { try await history.resolveAnomaly(path: item.path, at: now) }
                catch { historyFailed("Deleted anomaly resolution failed", error: error) }
            }
        }
        let missingAggregates = directoryAggregates.aggregates.keys.filter { path in
            guard !configuredRoots.contains(path), isInspected(path) else { return false }
            var metadata = stat()
            return Darwin.lstat(path, &metadata) != 0 && errno == ENOENT
        }
        for path in missingAggregates {
            directoryAggregates.remove(path)
            activeAnomalies.removeValue(forKey: path)
            if historyAvailable { try? await history.resolveAnomaly(path: path, at: now) }
        }
        diagnostics.trackedItemCount = trackedItems.items.count
        diagnostics.trackedDirectoryAggregates = directoryAggregates.aggregates.count
    }

    private func auditTargets(limit: Int, startup: Bool) async -> [AuditPath] {
        var targets: [AuditPath] = []
        if historyAvailable {
            do { targets.append(contentsOf: try await history.auditPaths(limit: limit)) }
            catch { historyFailed("Audit path query failed", error: error) }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let known = (configuredRoots + [home + "/Library/Containers/com.apple.Safari/Data/Library/WebKit/WebsiteData"]).sorted { $0.count > $1.count }
        let knownTargets = known.map { AuditPath(path: $0, type: .directory, source: .generic, unresolvedSeverity: nil, lastAnomalyUpdate: nil) }
        let aggregateLimit = startup ? limit : min(limit, configuration.maxReconciliationPathsPerAudit)
        let aggregateTargets = directoryAggregates.aggregates.values.sorted(by: aggregatePriority).prefix(aggregateLimit).map {
            AuditPath(path: $0.path, type: .directory, source: .generic, unresolvedSeverity: $0.severity == .normal ? nil : $0.severity, lastAnomalyUpdate: $0.lastNotification, lastKnownSize: $0.lastNotifiedSize)
        }
        if startup { targets.append(contentsOf: knownTargets); targets.append(contentsOf: aggregateTargets) }
        else { targets.append(contentsOf: aggregateTargets); targets.append(contentsOf: knownTargets) }

        var seen: Set<String> = []
        return targets.filter { seen.insert(PathRules.normalize($0.path)).inserted }.prefix(limit).map { $0 }
    }

    private func aggregatePriority(_ lhs: DirectoryAggregate, _ rhs: DirectoryAggregate) -> Bool {
        if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
        if lhs.recentGrowth != rhs.recentGrowth { return lhs.recentGrowth > rhs.recentGrowth }
        if lhs.size != rhs.size { return lhs.size > rhs.size }
        if lhs.lastSeen != rhs.lastSeen { return lhs.lastSeen > rhs.lastSeen }
        return lhs.path < rhs.path
    }

    private func monitoringRoot(for path: String) -> String? {
        configuration.normalizedRoots.filter { PathRules.contains($0, path) }.max(by: { $0.count < $1.count })
    }

    private func resetBatchBudgets() {
        remainingPromotions = configuration.maxPromotedAggregatesPerBatch
        remainingLongHorizonQueries = configuration.maxLongHorizonQueriesPerBatch
    }

    private func promote(_ value: inout GrowthEvaluation, _ candidate: GrowthEvaluation) {
        if candidate.severity > value.severity || (candidate.severity == value.severity && candidate.growth > value.growth) { value = candidate }
    }

    private func saturatedAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let value = lhs.addingReportingOverflow(rhs)
        return value.overflow ? (rhs >= 0 ? .max : .min) : value.partialValue
    }

    private func accessIssue(for root: String) -> AccessIssue? {
        let descriptor = Darwin.open(root, O_RDONLY | O_DIRECTORY)
        guard descriptor >= 0 else {
            if let issue = TargetedFileInspector.permissionIssue(NSError(domain: NSPOSIXErrorDomain, code: Int(errno)), path: root) { return issue }
            if errno == ENOENT { return AccessIssue(root: root, kind: .missing, message: "Configured monitoring root is missing.") }
            return AccessIssue(root: root, message: "Configured monitoring root is unavailable.")
        }
        Darwin.close(descriptor)
        return nil
    }

    private func record(issue: AccessIssue) {
        let root = configuredRoots.filter { PathRules.contains($0, issue.root) }.max(by: { $0.count < $1.count }) ?? issue.root
        guard accessIssues[root] != nil || accessIssues.count < configuration.maxWatchedRoots else { return }
        let issue = AccessIssue(root: root, kind: issue.kind, message: issue.message)
        if accessIssues[root] != issue { diagnostics.errorCount += 1 }
        accessIssues[root] = issue
        status = .degraded
    }

    private func checkFreeSpace(at now: Date, force: Bool = false) async {
        guard force || now.timeIntervalSince(lastFreeSpaceCheck) >= 60 else { return }
        lastFreeSpaceCheck = now
        let volume = FileManager.default.homeDirectoryForCurrentUser
        guard let values = try? volume.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]),
              let available = values.volumeAvailableCapacityForImportantUsage,
              let totalValue = values.volumeTotalCapacity else { return }
        let total = Int64(totalValue)
        freeSpace = available
        let previous = freeSpaceDetector.severity
        let result = freeSpaceDetector.evaluate(available: available, total: total, now: now, configuration: configuration)
        if result.severity == .normal {
            activeAnomalies.removeValue(forKey: volume.path)
            if previous != .normal, historyAvailable { try? await history.resolveAnomaly(path: volume.path, at: now) }
            emitSnapshot()
            return
        }
        let anomaly = Anomaly(path: volume.path, source: .generic, severity: result.severity, currentSize: available, growth: 0, interval: 0, reason: "Low free disk space", detectedAt: now, category: .lowFreeSpace)
        activeAnomalies[volume.path] = anomaly
        if result.shouldNotify {
            if historyAvailable { try? await history.record(anomaly: anomaly) }
            await deliver([anomaly])
        }
        emitSnapshot()
    }

    private func deliver(_ anomalies: [Anomaly]) async {
        guard notificationsEnabled else { return }
        for anomaly in anomalies.prefix(configuration.maxPendingNotifications) {
            do {
                if try await notifications.deliver(anomaly) { diagnostics.notificationCount += 1 }
            } catch { recordError("Notification delivery failed: \(error)") }
        }
    }

    private func refreshHistoryStatistics() async {
        guard historyAvailable else { return }
        do {
            diagnostics.sqliteFileSize = try await history.statistics().fileSize
            recentDetections = try await history.recentDetections(limit: 8)
        }
        catch { historyFailed("History statistics failed", error: error) }
    }

    private func refreshMonitoringRoots() {
        let previousIssues = accessIssues
        let checkedIssues = Dictionary(uniqueKeysWithValues: configuredRoots.compactMap { root in accessIssue(for: root).map { (root, $0) } })
        let refreshedIssues = checkedIssues.filter { root, issue in
            issue.kind != .missing || !configuration.normalizedRoots.contains { monitoredRoot in
                monitoredRoot != root && checkedIssues[monitoredRoot] == nil && PathRules.contains(monitoredRoot, root)
            }
        }
        diagnostics.errorCount += refreshedIssues.filter { previousIssues[$0.key] != $0.value }.count
        diagnostics.recoveryCount += previousIssues.keys.filter { refreshedIssues[$0] == nil }.count
        accessIssues = refreshedIssues
        let accessibleRoots = configuration.normalizedRoots.filter { accessIssues[$0] == nil }
        status = accessIssues.isEmpty && !accessibleRoots.isEmpty ? .monitoring : .degraded
        guard accessibleRoots != monitoredRoots || monitor == nil else { return }
        eventTask?.cancel()
        monitor?.stop()
        eventTask = nil
        monitor = nil
        monitoredRoots = []
        guard !accessibleRoots.isEmpty else { return }
        let monitor = FSEventsMonitor(roots: accessibleRoots, latency: configuration.debounce.timeInterval, maxBatchSize: configuration.maxRawEventsPerBatch, maxBufferedBatches: configuration.maxBufferedEventBatches)
        do {
            try monitor.start()
            self.monitor = monitor
            monitoredRoots = accessibleRoots
            let events = monitor.events
            let generation = lifecycleGeneration
            eventTask = Task { [weak self] in
                for await batch in events {
                    guard !Task.isCancelled else { break }
                    guard await self?.lifecycleIsCurrent(generation) == true else { break }
                    await self?.receive(batch, requiredGeneration: generation)
                }
            }
        } catch {
            recordError("FSEvents unavailable: \(error)")
            status = .degraded
        }
    }

    private func prepareHistoryIfNeeded(at now: Date, force: Bool = false) async {
        guard !historyAvailable else { return }
        let retryInterval = min(60, max(1, configuration.safetyInterval.timeInterval))
        guard force || now.timeIntervalSince(lastHistoryRetry) >= retryInterval else { return }
        lastHistoryRetry = now
        do {
            try await history.prepare()
            historyAvailable = true
            if historyHasFailed { historyHasFailed = false; diagnostics.recoveryCount += 1 }
        } catch {
            historyHasFailed = true
            recordError("History unavailable: \(error)")
        }
    }

    private func applyHistoryRetention(at now: Date) async {
        guard historyAvailable else { return }
        do { try await history.applyRetention(now: now) }
        catch { historyFailed("History retention failed", error: error) }
    }

    private func historyFailed(_ context: String, error: Error) {
        historyAvailable = false
        historyHasFailed = true
        recordError("\(context): \(error)")
    }

    private func recordError(_ message: @autoclosure () -> String) {
        diagnostics.errorCount += 1
        Diagnostics.debug(message())
    }

    private func resetRuntimeState() {
        coalescer = EventCoalescer(roots: configuration.normalizedRoots, capacity: configuration.maxDirtyPaths)
        trackedItems = TrackedItemStore(capacity: configuration.maxTrackedItems)
        directoryAggregates = DirectoryAggregateStore(capacity: configuration.maxTrackedDirectoryAggregates)
        for root in configuration.normalizedRoots {
            directoryAggregates.upsert(DirectoryAggregate(path: root, lastSeen: .distantPast, sampleCapacity: configuration.maxRecentSamplesPerItem))
        }
        dirtyAggregates.removeAll(keepingCapacity: false)
        activeAnomalies.removeAll(keepingCapacity: false)
        recentDetections.removeAll(keepingCapacity: false)
        freeSpaceDetector = FreeSpaceDetector()
        diagnostics.dirtyPathCount = 0
        diagnostics.trackedItemCount = 0
        diagnostics.trackedDirectoryAggregates = directoryAggregates.aggregates.count
        diagnostics.sampleCount = 0
        diagnostics.anomalyCount = 0
        diagnostics.sqliteFileSize = 0
    }

    private func lifecycleIsCurrent(_ generation: Int?) -> Bool {
        generation == nil || generation == lifecycleGeneration
    }

    private func emitSnapshot() {
        snapshotContinuation?.yield(snapshot())
        Diagnostics.metric("status=\(status.label) events=\(diagnostics.fseventsReceived) dirty=\(diagnostics.dirtyPathCount) tracked=\(diagnostics.trackedItemCount) aggregates=\(diagnostics.trackedDirectoryAggregates) samples=\(diagnostics.sampleCount) anomalies=\(diagnostics.anomalyCount) creep=\(diagnostics.creepAnomalies) notifications=\(diagnostics.notificationCount) errors=\(diagnostics.errorCount) sqlite=\(diagnostics.sqliteFileSize) dropped=\(diagnostics.droppedOrCollapsedWork)")
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
