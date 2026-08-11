import Foundation

public enum GrowthDetector {
    public static func evaluate(samples: [SizeSample], source: SourceClassification, configuration: MonitoringConfiguration) -> GrowthEvaluation {
        guard let current = samples.last else { return .normal }
        var best = current.size >= configuration.largeFileWarning
            ? GrowthEvaluation(severity: .warning, growth: 0, interval: 0, reason: "Large file", category: .surge)
            : .normal

        promote(&best, candidate(samples, current, bytes: configuration.rapidGrowthWarning, window: configuration.rapidGrowthWarningWindow, severity: .warning, reason: "Rapid growth", category: .surge))
        promote(&best, candidate(samples, current, bytes: configuration.rapidGrowthCritical, window: configuration.rapidGrowthCriticalWindow, severity: .critical, reason: "Critical growth", category: .surge))
        promote(&best, candidate(samples, current, bytes: configuration.extremeGrowth, window: configuration.extremeGrowthWindow, severity: .emergency, reason: "Extreme growth", category: .surge))

        guard case .safariWebKit = source else { return best }
        if current.size >= configuration.safariWALWarning {
            promote(&best, GrowthEvaluation(severity: .warning, growth: 0, interval: 0, reason: "Large Safari/WebKit WAL", category: .safariWAL))
        }
        if current.size >= configuration.safariWALCritical {
            promote(&best, GrowthEvaluation(severity: .critical, growth: 0, interval: 0, reason: "Critical Safari/WebKit WAL size", category: .safariWAL))
        }
        let runaway = samples.dropLast().compactMap { sample -> GrowthEvaluation? in
            let interval = current.timestamp.timeIntervalSince(sample.timestamp)
            let growth = current.size - sample.size
            guard interval > 0, growth > 0,
                  Double(growth) / interval * 60 >= Double(configuration.safariRunawayBytesPerMinute) else { return nil }
            return GrowthEvaluation(severity: .emergency, growth: growth, interval: interval, reason: "Runaway Safari/WebKit WAL growth", category: .safariWAL)
        }.max { Double($0.growth) / $0.interval < Double($1.growth) / $1.interval }
        if let runaway {
            promote(&best, runaway)
        }
        return best
    }

    public static func shouldNotify(item: inout TrackedItem, evaluation: GrowthEvaluation, now: Date, configuration: MonitoringConfiguration) -> Bool {
        let previous = item.severity
        item.severity = evaluation.severity
        guard evaluation.severity != .normal else {
            item.firstSuspicious = nil
            return false
        }
        if item.firstSuspicious == nil { item.firstSuspicious = now }
        let escalated = evaluation.severity > previous
        let recurred = previous == .normal
        let grewEnough = item.size - item.lastNotifiedSize >= configuration.notificationGrowthStep
        let cooldown = evaluation.category == .creep ? configuration.slowGrowthNotificationCooldown : configuration.notificationCooldown
        let cooledDown = item.lastNotification.map { now.timeIntervalSince($0) >= cooldown && item.size != item.lastNotifiedSize } ?? true
        guard escalated || recurred || grewEnough || cooledDown else { return false }
        item.lastNotification = now
        item.lastNotifiedSize = item.size
        return true
    }

    public static func evaluateDirectoryRecent(samples: [SizeSample], configuration: MonitoringConfiguration) -> GrowthEvaluation {
        guard let current = samples.last else { return .normal }
        var best = GrowthEvaluation.normal
        promote(&best, candidate(samples, current, bytes: configuration.rapidGrowthWarning, window: configuration.rapidGrowthWarningWindow, severity: .warning, reason: "Rapid directory growth", category: .surge))
        promote(&best, candidate(samples, current, bytes: configuration.rapidGrowthCritical, window: configuration.rapidGrowthCriticalWindow, severity: .critical, reason: "Critical directory growth", category: .surge))
        promote(&best, candidate(samples, current, bytes: configuration.extremeGrowth, window: configuration.extremeGrowthWindow, severity: .emergency, reason: "Extreme directory growth", category: .surge))
        return best
    }

    private static func candidate(_ samples: [SizeSample], _ current: SizeSample, bytes: Int64, window: TimeInterval, severity: AnomalySeverity, reason: String, category: AnomalyCategory) -> GrowthEvaluation {
        guard let baseline = samples.first(where: {
            let age = current.timestamp.timeIntervalSince($0.timestamp)
            return age >= 0 && age <= window
        }) else { return .normal }
        let growth = current.size - baseline.size
        let interval = current.timestamp.timeIntervalSince(baseline.timestamp)
        guard growth >= bytes, interval > 0 else { return .normal }
        return GrowthEvaluation(severity: severity, growth: growth, interval: interval, reason: reason, category: category)
    }

    fileprivate static func promote(_ value: inout GrowthEvaluation, _ candidate: GrowthEvaluation) {
        if candidate.severity > value.severity || (candidate.severity == value.severity && candidate.growth > value.growth) { value = candidate }
    }
}

public enum LongHorizonDetector {
    public static func evaluate(current: SizeSample, checkpoints: [HistoricalCheckpoint], type: ItemType, configuration: MonitoringConfiguration) -> GrowthEvaluation {
        var best = GrowthEvaluation.normal
        let rules: [(TimeInterval, Int64, String)] = [
            (24 * 60 * 60, configuration.longGrowth24Hours, "24 hours"),
            (7 * 24 * 60 * 60, configuration.longGrowth7Days, "7 days"),
            (30 * 24 * 60 * 60, configuration.longGrowth30Days, "30 days"),
        ]
        for (window, threshold, label) in rules {
            guard let checkpoint = checkpoints.first(where: { $0.window == window }) else { continue }
            let growth = current.size - checkpoint.sample.size
            guard growth >= threshold else { continue }
            let sustained = isSustained(current: current, checkpoints: checkpoints, minimumGrowth: threshold)
            let reason = type == .directory
                ? (sustained ? "Sustained directory growth" : "Directory growth over \(label)")
                : (sustained ? "Sustained storage growth" : "Storage growth over \(label)")
            let severity: AnomalySeverity = window >= 30 * 24 * 60 * 60 || (type == .directory && current.size >= configuration.directorySizeCritical) ? .critical : .warning
            GrowthDetector.promote(&best, GrowthEvaluation(severity: severity, growth: growth, interval: current.timestamp.timeIntervalSince(checkpoint.sample.timestamp), reason: reason, category: .creep))
        }

        if type == .directory, best == .normal {
            let hasHistory = !checkpoints.isEmpty
            let newestGrowth = checkpoints.map { current.size - $0.sample.size }.max() ?? 0
            if current.size >= configuration.directorySizeCritical, !hasHistory || newestGrowth >= configuration.notificationGrowthStep {
                best = GrowthEvaluation(severity: .critical, growth: max(0, newestGrowth), interval: 0, reason: "Large directory aggregate", category: .largeAggregate)
            } else if current.size >= configuration.directorySizeWarning, !hasHistory || newestGrowth >= configuration.notificationGrowthStep {
                best = GrowthEvaluation(severity: .warning, growth: max(0, newestGrowth), interval: 0, reason: "Large directory aggregate", category: .largeAggregate)
            }
        }
        return best
    }

    private static func isSustained(current: SizeSample, checkpoints: [HistoricalCheckpoint], minimumGrowth: Int64) -> Bool {
        var timestamps: Set<Date> = []
        let ordered = (checkpoints.map(\.sample) + [current]).sorted { $0.timestamp < $1.timestamp }.filter { timestamps.insert($0.timestamp).inserted }
        guard ordered.count >= 3, current.size - (ordered.first?.size ?? current.size) >= minimumGrowth else { return false }
        let tolerance = max(128 * Int64.megabyte, minimumGrowth / 10)
        return zip(ordered, ordered.dropFirst()).allSatisfy { $1.size + tolerance >= $0.size }
    }
}

public struct FreeSpaceDetector: Sendable {
    public private(set) var severity: AnomalySeverity = .normal
    public private(set) var lastNotification: Date?

    public init() {}

    public mutating func evaluate(available: Int64, total: Int64, now: Date, configuration: MonitoringConfiguration) -> (severity: AnomalySeverity, shouldNotify: Bool) {
        let fraction = total > 0 ? Double(available) / Double(total) : 1
        let next: AnomalySeverity
        if available < configuration.freeSpaceEmergency || fraction < configuration.freeSpaceEmergencyFraction {
            next = .emergency
        } else if available < configuration.freeSpaceCritical || fraction < configuration.freeSpaceCriticalFraction {
            next = .critical
        } else if available < configuration.freeSpaceWarning || fraction < configuration.freeSpaceWarningFraction {
            next = .warning
        } else {
            next = .normal
        }
        let notify = next != .normal && (severity == .normal || next > severity || lastNotification.map { now.timeIntervalSince($0) >= 6 * 60 * 60 } ?? true)
        severity = next
        if notify { lastNotification = now }
        return (next, notify)
    }
}
