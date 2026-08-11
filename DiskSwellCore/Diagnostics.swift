import Foundation
import OSLog

public struct DiagnosticsSnapshot: Sendable, Equatable {
    public var fseventsReceived = 0
    public var coalescedBatches = 0
    public var dirtyPathCount = 0
    public var dirtyPathOverflows = 0
    public var trackedItemCount = 0
    public var trackedItemEvictions = 0
    public var trackedDirectoryAggregates = 0
    public var aggregatePromotions = 0
    public var aggregateEvictions = 0
    public var aggregateOverflows = 0
    public var parentPropagationUpdates = 0
    public var reconciliationRuns = 0
    public var reconciliationWorkCount = 0
    public var startupAuditPathsInspected = 0
    public var periodicAuditPathsInspected = 0
    public var manualAuditPathsInspected = 0
    public var lastStartupAudit: Date?
    public var lastPeriodicAudit: Date?
    public var lastManualAudit: Date?
    public var longHorizonQueries = 0
    public var creepAnomalies = 0
    public var sampleCount = 0
    public var anomalyCount = 0
    public var notificationCount = 0
    public var errorCount = 0
    public var recoveryCount = 0
    public var sqliteFileSize: Int64 = 0
    public var lastProcessingLatencyMilliseconds = 0.0
    public var droppedOrCollapsedWork = 0

    public init() {}
}

public enum Diagnostics {
    private static let logger = Logger(subsystem: "com.diskswell.DiskSwell", category: "diagnostics")
    private static let enabled: Bool = {
        #if DEBUG
        true
        #else
        ProcessInfo.processInfo.environment["DISKSWELL_DIAGNOSTICS"] == "1"
        #endif
    }()

    public static func debug(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let renderedMessage = message()
        logger.debug("\(renderedMessage, privacy: .private)")
    }

    static func metric(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let renderedMessage = message()
        logger.debug("\(renderedMessage, privacy: .public)")
    }
}
