import Foundation

public struct MonitoringConfiguration: Sendable, Equatable {
    public var watchedRoots: [String]
    public var debounce: Duration = .milliseconds(750)
    public var safetyInterval: Duration = .seconds(30 * 60)
    public var maxRawEventsPerBatch = 8_192
    public var maxBufferedEventBatches = 8
    public var maxWatchedRoots = 16
    public var maxDirtyPaths = 4_096
    public var maxTrackedItems = 2_048
    public var maxTrackedDirectoryAggregates = 512
    public var maxParentPropagationDepth = 6
    public var maxPromotedAggregatesPerBatch = 128
    public var maxRecentSamplesPerItem = 32
    public var maxPendingNotifications = 64
    public var maxInspectionEntries = 1_024
    public var maxInspectionDepth = 8
    public var minimumTrackedFileSize: Int64 = 64 * .megabyte
    public var notificationCooldown: TimeInterval = 30 * 60
    public var notificationGrowthStep: Int64 = 500 * .megabyte
    public var slowGrowthNotificationCooldown: TimeInterval = 24 * 60 * 60

    public var periodicAuditInterval: TimeInterval = 24 * 60 * 60
    public var maxStartupAuditPaths = 64
    public var maxPeriodicAuditPaths = 64
    public var maxAuditEntries = 2_048
    public var maxAuditEntriesPerPath = 512
    public var maxAuditDepth = 8
    public var maxAuditDuration: TimeInterval = 2
    public var maxReconciliationPathsPerAudit = 16
    public var maxLongHorizonQueriesPerBatch = 64

    public var largeFileWarning: Int64 = 1 * .gigabyte
    public var rapidGrowthWarning: Int64 = 500 * .megabyte
    public var rapidGrowthWarningWindow: TimeInterval = 5 * 60
    public var rapidGrowthCritical: Int64 = 2 * .gigabyte
    public var rapidGrowthCriticalWindow: TimeInterval = 15 * 60
    public var extremeGrowth: Int64 = 5 * .gigabyte
    public var extremeGrowthWindow: TimeInterval = 60 * 60

    public var longGrowth24Hours: Int64 = 2 * .gigabyte
    public var longGrowth7Days: Int64 = 5 * .gigabyte
    public var longGrowth30Days: Int64 = 10 * .gigabyte
    public var directorySizeWarning: Int64 = 5 * .gigabyte
    public var directorySizeCritical: Int64 = 20 * .gigabyte

    public var safariWALWarning: Int64 = 500 * .megabyte
    public var safariWALCritical: Int64 = 2 * .gigabyte
    public var safariRunawayBytesPerMinute: Int64 = 250 * .megabyte

    public var freeSpaceWarning: Int64 = 20 * .gigabyte
    public var freeSpaceCritical: Int64 = 10 * .gigabyte
    public var freeSpaceEmergency: Int64 = 5 * .gigabyte
    public var freeSpaceWarningFraction = 0.10
    public var freeSpaceCriticalFraction = 0.05
    public var freeSpaceEmergencyFraction = 0.02

    public init(watchedRoots: [String] = MonitoringConfiguration.defaultRoots()) {
        self.watchedRoots = watchedRoots
    }

    public static func defaultRoots(home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> [String] {
        [
            home + "/Library",
            home + "/Downloads",
            home + "/Library/Developer",
            home + "/Library/Containers",
            home + "/Library/Containers/com.apple.Safari",
        ]
    }

    public var normalizedRoots: [String] { PathRules.deduplicatedRoots(Array(watchedRoots.prefix(maxWatchedRoots))) }
}

public extension Int64 {
    static let megabyte: Int64 = 1_024 * 1_024
    static let gigabyte: Int64 = 1_024 * 1_024 * 1_024
}

public enum PathRules {
    public static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    public static func contains(_ ancestor: String, _ path: String) -> Bool {
        let ancestor = normalize(ancestor)
        let path = normalize(path)
        return path == ancestor || path.hasPrefix(ancestor == "/" ? "/" : ancestor + "/")
    }

    public static func deduplicatedRoots(_ roots: [String]) -> [String] {
        var result: [String] = []
        let unique = Set(roots.map { normalize($0) })
        let ordered = unique.sorted { lhs, rhs in
            lhs.count == rhs.count ? lhs < rhs : lhs.count < rhs.count
        }
        for root in ordered {
            if !result.contains(where: { contains($0, root) }) { result.append(root) }
        }
        return result
    }

    public static func commonAncestor(_ lhs: String, _ rhs: String, boundedBy root: String) -> String {
        var candidate = normalize(lhs)
        let rhs = normalize(rhs)
        while !contains(candidate, rhs), candidate != root {
            candidate = URL(fileURLWithPath: candidate).deletingLastPathComponent().path
        }
        return contains(root, candidate) ? candidate : root
    }

    public static func safeDisplayName(_ path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        let cleaned = name.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined()
        return String(cleaned.prefix(160))
    }
}

public enum ItemType: String, Sendable, Codable {
    case file
    case directory
}

public enum SourceClassification: Sendable, Equatable {
    case generic
    case safariWebKit(origin: String?)
    case application(name: String, confidence: AttributionConfidence)

    public var label: String {
        switch self {
        case .generic: "Filesystem"
        case let .safariWebKit(origin): "Verified · Safari · \(origin ?? "Unknown website")"
        case let .application(name, confidence): "\(confidence.label) · \(name)"
        }
    }

    public var storageValue: String {
        switch self {
        case .generic: "generic"
        case .safariWebKit: "safari-webkit"
        case let .application(_, confidence): "application-\(confidence.rawValue)"
        }
    }
}

public enum AttributionConfidence: String, Sendable, Equatable {
    case verified
    case likely

    public var label: String { rawValue.capitalized }
}

public enum AnomalySeverity: Int, Sendable, Codable, Comparable {
    case normal = 0
    case warning = 1
    case critical = 2
    case emergency = 3

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .normal: "Normal"
        case .warning: "Warning"
        case .critical: "Critical"
        case .emergency: "Emergency"
        }
    }
}

public struct SizeSample: Sendable, Equatable {
    public let timestamp: Date
    public let size: Int64
    public let itemCount: Int64?
    public let isApproximate: Bool

    public init(timestamp: Date, size: Int64, itemCount: Int64? = nil, isApproximate: Bool = false) {
        self.timestamp = timestamp
        self.size = size
        self.itemCount = itemCount
        self.isApproximate = isApproximate
    }
}

public enum AnomalyCategory: String, Sendable, Codable {
    case surge
    case creep
    case largeAggregate
    case lowFreeSpace
    case safariWAL
}

public struct SampleRing: Sendable, Equatable {
    private var storage: [SizeSample]
    private var nextIndex = 0
    public let capacity: Int

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
        storage = []
        storage.reserveCapacity(self.capacity)
    }

    public mutating func append(_ sample: SizeSample) {
        if storage.count < capacity {
            storage.append(sample)
        } else {
            storage[nextIndex] = sample
            nextIndex = (nextIndex + 1) % capacity
        }
    }

    public var values: [SizeSample] {
        guard storage.count == capacity, nextIndex != 0 else { return storage }
        return Array(storage[nextIndex...]) + storage[..<nextIndex]
    }

    public var count: Int { storage.count }
}

public struct GrowthEvaluation: Sendable, Equatable {
    public let severity: AnomalySeverity
    public let growth: Int64
    public let interval: TimeInterval
    public let reason: String
    public let category: AnomalyCategory

    public static let normal = GrowthEvaluation(severity: .normal, growth: 0, interval: 0, reason: "", category: .surge)
}

public struct Anomaly: Sendable, Equatable, Identifiable {
    public let id: String
    public let path: String
    public let source: SourceClassification
    public let severity: AnomalySeverity
    public let currentSize: Int64
    public let growth: Int64
    public let interval: TimeInterval
    public let reason: String
    public let detectedAt: Date
    public let category: AnomalyCategory
    public let itemCountGrowth: Int64
    public let isApproximate: Bool

    public init(path: String, source: SourceClassification, severity: AnomalySeverity, currentSize: Int64, growth: Int64, interval: TimeInterval, reason: String, detectedAt: Date, category: AnomalyCategory = .surge, itemCountGrowth: Int64 = 0, isApproximate: Bool = false) {
        self.id = path
        self.path = path
        self.source = source
        self.severity = severity
        self.currentSize = currentSize
        self.growth = growth
        self.interval = interval
        self.reason = reason
        self.detectedAt = detectedAt
        self.category = category
        self.itemCountGrowth = itemCountGrowth
        self.isApproximate = isApproximate
    }
}

public struct TrackedItem: Sendable {
    public let path: String
    public let type: ItemType
    public var source: SourceClassification
    public var samples: SampleRing
    public var lastSeen: Date
    public var firstSuspicious: Date?
    public var severity: AnomalySeverity = .normal
    public var lastNotification: Date?
    public var lastNotifiedSize: Int64 = 0

    public var size: Int64 { samples.values.last?.size ?? 0 }

    public init(path: String, type: ItemType, source: SourceClassification, samples: SampleRing, lastSeen: Date, firstSuspicious: Date? = nil, severity: AnomalySeverity = .normal, lastNotification: Date? = nil, lastNotifiedSize: Int64 = 0) {
        self.path = path
        self.type = type
        self.source = source
        self.samples = samples
        self.lastSeen = lastSeen
        self.firstSuspicious = firstSuspicious
        self.severity = severity
        self.lastNotification = lastNotification
        self.lastNotifiedSize = lastNotifiedSize
    }
}

public struct TrackedItemStore: Sendable {
    private(set) public var items: [String: TrackedItem] = [:]
    public let capacity: Int
    public private(set) var evictions = 0

    public init(capacity: Int) { self.capacity = max(1, capacity) }

    @discardableResult
    public mutating func upsert(_ item: TrackedItem) -> TrackedItem? {
        if items[item.path] != nil {
            items[item.path] = item
            return nil
        }
        guard items.count >= capacity else {
            items[item.path] = item
            return nil
        }
        guard let victim = items.values.min(by: Self.lowerPriority) else { return item }
        guard !Self.lowerPriority(item, victim) else {
            evictions += 1
            return item
        }
        items.removeValue(forKey: victim.path)
        items[item.path] = item
        evictions += 1
        return victim
    }

    public mutating func remove(_ path: String) { items.removeValue(forKey: path) }

    private static func lowerPriority(_ lhs: TrackedItem, _ rhs: TrackedItem) -> Bool {
        if lhs.severity != rhs.severity { return lhs.severity < rhs.severity }
        if lhs.lastSeen != rhs.lastSeen { return lhs.lastSeen < rhs.lastSeen }
        if lhs.size != rhs.size { return lhs.size < rhs.size }
        return lhs.path < rhs.path
    }
}

public struct DirectoryAggregate: Sendable, Equatable {
    public let path: String
    public var size: Int64 = 0
    public var itemCount: Int64 = 0
    public var isApproximate = true
    public var lastSeen: Date
    public var recentGrowth: Int64 = 0
    public var severity: AnomalySeverity = .normal
    public var lastNotification: Date?
    public var lastNotifiedSize: Int64 = 0
    public var samples: SampleRing

    public init(path: String, lastSeen: Date, sampleCapacity: Int = 32) {
        self.path = path
        self.lastSeen = lastSeen
        samples = SampleRing(capacity: sampleCapacity)
    }
}

public struct DirectoryAggregateStore: Sendable {
    private(set) public var aggregates: [String: DirectoryAggregate] = [:]
    public let capacity: Int
    public private(set) var evictions = 0
    public private(set) var overflows = 0

    public init(capacity: Int) { self.capacity = max(1, capacity) }

    @discardableResult
    public mutating func upsert(_ aggregate: DirectoryAggregate) -> DirectoryAggregate? {
        if aggregates[aggregate.path] != nil {
            aggregates[aggregate.path] = aggregate
            return nil
        }
        guard aggregates.count >= capacity else {
            aggregates[aggregate.path] = aggregate
            return nil
        }
        overflows += 1
        guard let victim = aggregates.values.min(by: Self.lowerPriority), !Self.lowerPriority(aggregate, victim) else { return aggregate }
        aggregates.removeValue(forKey: victim.path)
        aggregates[aggregate.path] = aggregate
        evictions += 1
        return victim
    }

    public mutating func remove(_ path: String) { aggregates.removeValue(forKey: path) }

    private static func lowerPriority(_ lhs: DirectoryAggregate, _ rhs: DirectoryAggregate) -> Bool {
        if lhs.severity != rhs.severity { return lhs.severity < rhs.severity }
        if lhs.lastSeen != rhs.lastSeen { return lhs.lastSeen < rhs.lastSeen }
        if lhs.recentGrowth != rhs.recentGrowth { return lhs.recentGrowth < rhs.recentGrowth }
        if lhs.size != rhs.size { return lhs.size < rhs.size }
        return lhs.path < rhs.path
    }
}

public enum MonitoringStatus: Sendable, Equatable {
    case ready
    case monitoring
    case degraded
    case stopped

    public var label: String {
        switch self {
        case .ready: "Ready"
        case .monitoring: "Monitoring"
        case .degraded: "Monitoring (limited access)"
        case .stopped: "Stopped"
        }
    }
}

public enum AccessIssueKind: String, Sendable, Equatable {
    case permissionDenied
    case missing
    case unavailable
}

public struct AccessIssue: Sendable, Equatable {
    public let root: String
    public let kind: AccessIssueKind
    public let message: String

    public init(root: String, kind: AccessIssueKind = .unavailable, message: String) {
        self.root = root
        self.kind = kind
        self.message = message
    }
}

public struct MonitoringSnapshot: Sendable, Equatable {
    public let status: MonitoringStatus
    public let freeSpace: Int64?
    public let recentAnomaly: Anomaly?
    public let recentDetections: [DetectionRecord]
    public let accessIssues: [AccessIssue]
    public let diagnostics: DiagnosticsSnapshot

    public init(status: MonitoringStatus, freeSpace: Int64?, recentAnomaly: Anomaly?, recentDetections: [DetectionRecord] = [], accessIssues: [AccessIssue], diagnostics: DiagnosticsSnapshot) {
        self.status = status
        self.freeSpace = freeSpace
        self.recentAnomaly = recentAnomaly
        self.recentDetections = recentDetections
        self.accessIssues = accessIssues
        self.diagnostics = diagnostics
    }
}
