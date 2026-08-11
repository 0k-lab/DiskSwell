import CoreFoundation
import Foundation

public struct DiskSwellPreferences: Sendable, Equatable {
    public var launchAtLogin = true
    public var showInDock = false
    public var monitoringEnabled = true
    public var notificationsEnabled = true
    public var automaticallyChecksForUpdates = true
    public var diagnosticsEnabled = false

    public init() {}
}

public final class PreferencesStore: @unchecked Sendable {
    private enum Key {
        static let launchAtLogin = "launchAtLogin"
        static let showInDock = "showInDock"
        static let monitoringEnabled = "monitoringEnabled"
        static let notificationsEnabled = "notificationsEnabled"
        static let automaticallyChecksForUpdates = "automaticallyChecksForUpdates"
        static let diagnosticsEnabled = "diagnosticsEnabled"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func load() -> DiskSwellPreferences {
        var preferences = DiskSwellPreferences()
        preferences.launchAtLogin = bool(forKey: Key.launchAtLogin, default: preferences.launchAtLogin)
        preferences.showInDock = bool(forKey: Key.showInDock, default: preferences.showInDock)
        preferences.monitoringEnabled = bool(forKey: Key.monitoringEnabled, default: preferences.monitoringEnabled)
        preferences.notificationsEnabled = bool(forKey: Key.notificationsEnabled, default: preferences.notificationsEnabled)
        preferences.automaticallyChecksForUpdates = bool(forKey: Key.automaticallyChecksForUpdates, default: preferences.automaticallyChecksForUpdates)
        preferences.diagnosticsEnabled = bool(forKey: Key.diagnosticsEnabled, default: preferences.diagnosticsEnabled)
        return preferences
    }

    public func save(_ preferences: DiskSwellPreferences) {
        defaults.set(preferences.launchAtLogin, forKey: Key.launchAtLogin)
        defaults.set(preferences.showInDock, forKey: Key.showInDock)
        defaults.set(preferences.monitoringEnabled, forKey: Key.monitoringEnabled)
        defaults.set(preferences.notificationsEnabled, forKey: Key.notificationsEnabled)
        defaults.set(preferences.automaticallyChecksForUpdates, forKey: Key.automaticallyChecksForUpdates)
        defaults.set(preferences.diagnosticsEnabled, forKey: Key.diagnosticsEnabled)
    }

    private func bool(forKey key: String, default defaultValue: Bool) -> Bool {
        guard let value = defaults.object(forKey: key) as? NSNumber,
              CFGetTypeID(value) == CFBooleanGetTypeID() else { return defaultValue }
        return value.boolValue
    }
}

public enum LaunchAtLoginStatus: Sendable, Equatable {
    case enabled
    case disabled
    case requiresApproval
    case unavailable
}

@MainActor
public protocol LaunchAtLoginServicing: AnyObject {
    var status: LaunchAtLoginStatus { get }
    func register() throws
    func unregister() throws
}

public struct LaunchAtLoginResult: Sendable, Equatable {
    public let isEnabled: Bool
    public let status: LaunchAtLoginStatus
    public let message: String?
}

@MainActor
public enum LaunchAtLoginController {
    public static func apply(_ enabled: Bool, using service: any LaunchAtLoginServicing) -> LaunchAtLoginResult {
        do {
            if enabled, service.status != .enabled { try service.register() }
            if !enabled, service.status != .disabled { try service.unregister() }
            return result(for: service.status)
        } catch {
            return LaunchAtLoginResult(isEnabled: service.status == .enabled, status: service.status, message: error.localizedDescription)
        }
    }

    public static func current(using service: any LaunchAtLoginServicing) -> LaunchAtLoginResult {
        result(for: service.status)
    }

    private static func result(for status: LaunchAtLoginStatus) -> LaunchAtLoginResult {
        switch status {
        case .enabled:
            LaunchAtLoginResult(isEnabled: true, status: status, message: nil)
        case .disabled:
            LaunchAtLoginResult(isEnabled: false, status: status, message: nil)
        case .requiresApproval:
            LaunchAtLoginResult(isEnabled: false, status: status, message: "Allow DiskSwell in System Settings → General → Login Items.")
        case .unavailable:
            LaunchAtLoginResult(isEnabled: false, status: status, message: "Launch at Login is unavailable for this copy of DiskSwell.")
        }
    }
}

public enum DiagnosticsReport {
    public static func make(
        snapshot: MonitoringSnapshot,
        version: String,
        build: String,
        macOSVersion: String,
        architecture: String,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        maximumLength: Int = 8_192
    ) -> String {
        let diagnostics = snapshot.diagnostics
        let issues = snapshot.accessIssues.prefix(16).map {
            "- \(redact($0.root, homeDirectory: homeDirectory).prefix(240)): \($0.kind.rawValue)"
        }
        let date = ISO8601DateFormatter()
        let lines = [
            "DiskSwell Diagnostics",
            "Version: \(version) (\(build))",
            "macOS: \(macOSVersion)",
            "Architecture: \(architecture)",
            "Monitoring: \(snapshot.status.label)",
            "FSEvents received: \(diagnostics.fseventsReceived)",
            "Coalesced batches: \(diagnostics.coalescedBatches)",
            "Dirty paths: \(diagnostics.dirtyPathCount) (overflow \(diagnostics.dirtyPathOverflows))",
            "Tracked items: \(diagnostics.trackedItemCount) (evicted \(diagnostics.trackedItemEvictions))",
            "Directory aggregates: \(diagnostics.trackedDirectoryAggregates) (evicted \(diagnostics.aggregateEvictions), overflow \(diagnostics.aggregateOverflows))",
            "History samples/anomalies: \(diagnostics.sampleCount)/\(diagnostics.anomalyCount)",
            "SQLite bytes: \(diagnostics.sqliteFileSize)",
            "Dropped/collapsed work: \(diagnostics.droppedOrCollapsedWork)",
            "Errors/recoveries: \(diagnostics.errorCount)/\(diagnostics.recoveryCount)",
            "Last startup audit: \(diagnostics.lastStartupAudit.map(date.string) ?? "Never")",
            "Last periodic audit: \(diagnostics.lastPeriodicAudit.map(date.string) ?? "Never")",
            "Last manual audit: \(diagnostics.lastManualAudit.map(date.string) ?? "Never")",
            "Permission limitations: \(issues.isEmpty ? "None" : "")",
        ] + issues
        return String(lines.joined(separator: "\n").prefix(max(1, maximumLength)))
    }

    public static func redact(_ text: String, homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        let homeRedacted = homeDirectory.isEmpty ? text : text.replacingOccurrences(of: homeDirectory, with: "~")
        guard let expression = try? NSRegularExpression(pattern: #"/(Users|home)/[^/\n]+"#) else { return homeRedacted }
        let range = NSRange(homeRedacted.startIndex..., in: homeRedacted)
        return expression.stringByReplacingMatches(in: homeRedacted, range: range, withTemplate: "~")
    }
}
