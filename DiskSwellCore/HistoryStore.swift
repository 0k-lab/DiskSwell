import Foundation

public struct HistoryStatistics: Sendable, Equatable {
    public let sampleCount: Int
    public let anomalyCount: Int
    public let fileSize: Int64
}

public struct HistoricalCheckpoint: Sendable, Equatable {
    public let window: TimeInterval
    public let sample: SizeSample

    public init(window: TimeInterval, sample: SizeSample) {
        self.window = window
        self.sample = sample
    }
}

public struct AuditPath: Sendable, Equatable {
    public let path: String
    public let type: ItemType
    public let source: SourceClassification
    public let unresolvedSeverity: AnomalySeverity?
    public let lastAnomalyUpdate: Date?
    public let lastKnownSize: Int64?

    public init(path: String, type: ItemType, source: SourceClassification, unresolvedSeverity: AnomalySeverity?, lastAnomalyUpdate: Date?, lastKnownSize: Int64? = nil) {
        self.path = path
        self.type = type
        self.source = source
        self.unresolvedSeverity = unresolvedSeverity
        self.lastAnomalyUpdate = lastAnomalyUpdate
        self.lastKnownSize = lastKnownSize
    }
}

public struct DetectionRecord: Sendable, Equatable, Identifiable {
    public let id: Int64
    public let path: String
    public let source: SourceClassification
    public let severity: AnomalySeverity
    public let currentSize: Int64
    public let growth: Int64
    public let interval: TimeInterval
    public let reason: String
    public let category: AnomalyCategory
    public let detectedAt: Date
    public let updatedAt: Date
    public let resolvedAt: Date?
    public let itemCountGrowth: Int64
    public let isApproximate: Bool

    public init(id: Int64, path: String, source: SourceClassification, severity: AnomalySeverity, currentSize: Int64, growth: Int64, interval: TimeInterval, reason: String, category: AnomalyCategory, detectedAt: Date, updatedAt: Date, resolvedAt: Date?, itemCountGrowth: Int64 = 0, isApproximate: Bool = false) {
        self.id = id
        self.path = path
        self.source = source
        self.severity = severity
        self.currentSize = currentSize
        self.growth = growth
        self.interval = interval
        self.reason = reason
        self.category = category
        self.detectedAt = detectedAt
        self.updatedAt = updatedAt
        self.resolvedAt = resolvedAt
        self.itemCountGrowth = itemCountGrowth
        self.isApproximate = isApproximate
    }
}

public protocol HistoryStore: Sendable {
    func prepare() async throws
    func record(sample: SizeSample, path: String, type: ItemType, source: SourceClassification) async throws
    func record(anomaly: Anomaly) async throws
    func resolveAnomaly(path: String, at: Date) async throws
    func applyRetention(now: Date) async throws
    func statistics() async throws -> HistoryStatistics
    func longHorizonCheckpoints(path: String, at: Date) async throws -> [HistoricalCheckpoint]
    func auditPaths(limit: Int) async throws -> [AuditPath]
    func recentDetections(limit: Int) async throws -> [DetectionRecord]
    func reset() async throws
}

public extension HistoryStore {
    func longHorizonCheckpoints(path: String, at: Date) async throws -> [HistoricalCheckpoint] { [] }
    func auditPaths(limit: Int) async throws -> [AuditPath] { [] }
    func recentDetections(limit: Int) async throws -> [DetectionRecord] { [] }
    func reset() async throws {}
}

public actor InMemoryHistoryStore: HistoryStore {
    public init() {}
    public func prepare() {}
    public func record(sample: SizeSample, path: String, type: ItemType, source: SourceClassification) {}
    public func record(anomaly: Anomaly) {}
    public func resolveAnomaly(path: String, at: Date) {}
    public func applyRetention(now: Date) {}
    public func statistics() -> HistoryStatistics { HistoryStatistics(sampleCount: 0, anomalyCount: 0, fileSize: 0) }
}
