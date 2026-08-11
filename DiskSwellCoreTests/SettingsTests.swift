import Foundation
import Testing
@testable import DiskSwellCore

@Test("Settings defaults are safe and persisted values survive reload")
func settingsPersistence() {
    let (defaults, suite) = testDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = PreferencesStore(defaults: defaults)
    let initial = store.load()
    #expect(initial.launchAtLogin)
    #expect(!initial.showInDock)
    #expect(initial.monitoringEnabled)
    #expect(initial.notificationsEnabled)
    #expect(initial.automaticallyChecksForUpdates)
    #expect(!initial.diagnosticsEnabled)

    var changed = initial
    changed.launchAtLogin = false
    changed.showInDock = true
    changed.monitoringEnabled = false
    changed.notificationsEnabled = false
    changed.automaticallyChecksForUpdates = false
    changed.diagnosticsEnabled = true
    store.save(changed)
    #expect(PreferencesStore(defaults: defaults).load() == changed)
}

@Test("Invalid legacy preference values fall back independently")
func invalidSettingsFallback() {
    let (defaults, suite) = testDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("yes", forKey: "launchAtLogin")
    defaults.set(1, forKey: "showInDock")
    defaults.set(false, forKey: "monitoringEnabled")
    let loaded = PreferencesStore(defaults: defaults).load()
    #expect(loaded.launchAtLogin)
    #expect(!loaded.showInDock)
    #expect(!loaded.monitoringEnabled)
    #expect(loaded.notificationsEnabled)
    #expect(loaded.automaticallyChecksForUpdates)
}

@Test("Release tags compare correctly and checksums require the package filename")
func updateReleaseValidation() {
    #expect(ReleaseVersion("v1.2.0")! > ReleaseVersion("1.1.9")!)
    #expect(ReleaseVersion("1.2") == nil)
    #expect(ReleaseVersion("1.2.0-beta") == nil)

    let digest = String(repeating: "a", count: 64)
    #expect(ReleaseChecksum.sha256(in: "\(digest)  DiskSwell.pkg\n", for: "DiskSwell.pkg") == digest)
    #expect(ReleaseChecksum.sha256(in: "\(digest)  Other.pkg\n", for: "DiskSwell.pkg") == nil)

    let signature = "Signed with a trusted timestamp\n1. Developer ID Installer: DiskSwell (ABCDE12345)"
    #expect(InstallerPackageTrust.matches(signature, teamID: "ABCDE12345"))
    #expect(!InstallerPackageTrust.matches(signature, teamID: "WRONG12345"))
    #expect(!InstallerPackageTrust.matches(signature.replacing("Signed with a trusted timestamp", with: "No trusted timestamp"), teamID: "ABCDE12345"))
}

@Test("Release migration prefers the new organization and trusts both namespaces")
func releaseOrganizationMigration() {
    #expect(DiskSwellReleaseLocation.latestReleaseURLs.map(\.absoluteString) == [
        "https://github.com/0k-lab/DiskSwell/releases/latest",
        "https://github.com/kricha-lab/DiskSwell/releases/latest",
    ])
    let assets = DiskSwellReleaseLocation.assets(for: URL(string: "https://github.com/0k-lab/DiskSwell/releases/tag/v1.2.3")!)
    #expect(assets?.version == ReleaseVersion("1.2.3"))
    #expect(assets?.packageURL.absoluteString == "https://github.com/0k-lab/DiskSwell/releases/download/v1.2.3/DiskSwell.pkg")
    #expect(assets?.checksumURL.absoluteString == "https://github.com/0k-lab/DiskSwell/releases/download/v1.2.3/DiskSwell.pkg.sha256")
    #expect(DiskSwellReleaseLocation.assets(for: URL(string: "https://example.com/0k-lab/DiskSwell/releases/tag/v1.2.3")!) == nil)
    #expect(DiskSwellReleaseLocation.isTrustedAssetURL(URL(string: "https://github.com/0k-lab/DiskSwell/releases/download/v1.2.3/DiskSwell.pkg")!))
    #expect(DiskSwellReleaseLocation.isTrustedAssetURL(URL(string: "https://github.com/kricha-lab/DiskSwell/releases/download/v1.2.3/DiskSwell.pkg")!))
    #expect(!DiskSwellReleaseLocation.isTrustedAssetURL(URL(string: "https://github.com/ok-lab/DiskSwell/releases/download/v1.2.3/DiskSwell.pkg")!))
    #expect(!DiskSwellReleaseLocation.isTrustedAssetURL(URL(string: "http://github.com/0k-lab/DiskSwell/releases/download/v1.2.3/DiskSwell.pkg")!))
}

@MainActor
@Test("Launch at Login reports native state and errors without mutating the machine")
func launchAtLoginBoundary() {
    let service = MockLaunchAtLoginService()
    var result = LaunchAtLoginController.apply(true, using: service)
    #expect(result.isEnabled)
    #expect(service.registerCount == 1)

    result = LaunchAtLoginController.apply(false, using: service)
    #expect(!result.isEnabled)
    #expect(service.unregisterCount == 1)

    service.registrationResult = .requiresApproval
    result = LaunchAtLoginController.apply(true, using: service)
    #expect(!result.isEnabled)
    #expect(result.status == .requiresApproval)
    #expect(result.message?.contains("System Settings") == true)

    service.status = .disabled
    service.registrationError = TestError.failed
    result = LaunchAtLoginController.apply(true, using: service)
    #expect(!result.isEnabled)
    #expect(result.message != nil)
}

@Test("Repeated monitoring transitions retain at most one monitor and release all tasks")
func repeatedMonitoringTransitions() async {
    var configuration = MonitoringConfiguration(watchedRoots: [FileManager.default.temporaryDirectory.path])
    configuration.maxStartupAuditPaths = 0
    configuration.safetyInterval = .seconds(86_400)
    let engine = MonitoringEngine(configuration: configuration, history: InMemoryHistoryStore(), notifications: SettingsRecordingNotifications())

    for _ in 0..<5 {
        async let first: Void = engine.start()
        async let duplicate: Void = engine.start()
        _ = await (first, duplicate)
        let active = await engine.lifecycleResourceCounts()
        #expect(active.monitors == 1)
        #expect((2...3).contains(active.tasks))
        await engine.stop()
        #expect(await engine.lifecycleResourceCounts().monitors == 0)
        #expect(await engine.lifecycleResourceCounts().tasks == 0)
    }

    await engine.start()
    #expect(await engine.status == .monitoring)
    await engine.stop()
}

@Test("Notification suppression preserves detection and history without replay")
func notificationSuppression() async {
    var configuration = MonitoringConfiguration(watchedRoots: [FileManager.default.temporaryDirectory.path])
    configuration.maxStartupAuditPaths = 0
    let history = RecordingSettingsHistory()
    let notifications = SettingsRecordingNotifications()
    let engine = MonitoringEngine(configuration: configuration, history: history, notifications: notifications)
    await engine.setNotificationsEnabled(false)
    await engine.start()

    let first = await engine.processSample(path: FileManager.default.temporaryDirectory.appendingPathComponent("suppressed").path, size: 2 * .gigabyte)
    #expect(first != nil)
    #expect(await history.anomalyCount == 1)
    #expect(await notifications.deliveryCount == 0)

    await engine.setNotificationsEnabled(true)
    #expect(await notifications.deliveryCount == 0)
    let second = await engine.processSample(path: FileManager.default.temporaryDirectory.appendingPathComponent("delivered").path, size: 2 * .gigabyte)
    let deliveredCount = await notifications.deliveryCount
    let deliveredPaths = await notifications.paths
    #expect(second != nil)
    #expect(deliveredCount > 0)
    #expect(!deliveredPaths.contains(where: { $0.hasSuffix("/suppressed") }))
    await engine.stop()
}

@Test("Copied diagnostics are bounded and redact home paths and usernames")
func diagnosticsRedaction() {
    var diagnostics = DiagnosticsSnapshot()
    diagnostics.fseventsReceived = 42
    diagnostics.lastManualAudit = Date(timeIntervalSince1970: 1_000)
    let snapshot = MonitoringSnapshot(
        status: .degraded,
        freeSpace: nil,
        recentAnomaly: nil,
        accessIssues: [AccessIssue(root: "/Users/alice/Library/Containers", kind: .permissionDenied, message: "private")],
        diagnostics: diagnostics
    )
    let report = DiagnosticsReport.make(snapshot: snapshot, version: "1.0", build: "1", macOSVersion: "macOS", architecture: "arm64", homeDirectory: "/Users/alice", maximumLength: 512)
    #expect(report.count <= 512)
    #expect(report.contains("~/Library/Containers"))
    #expect(!report.contains("alice"))
    #expect(!report.contains("private"))
    #expect(!DiskSwellPreferences().diagnosticsEnabled)
}

@Test("Reset clears only history, preserves preferences, and resumes monitoring")
func resetDataLifecycle() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DiskSwellResetTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let (defaults, suite) = testDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    var preferences = DiskSwellPreferences()
    preferences.showInDock = true
    PreferencesStore(defaults: defaults).save(preferences)

    var configuration = MonitoringConfiguration(watchedRoots: [directory.path])
    configuration.maxStartupAuditPaths = 0
    let history = SQLiteHistoryStore(url: directory.appendingPathComponent("history.sqlite3"))
    let engine = MonitoringEngine(configuration: configuration, history: history, notifications: SettingsRecordingNotifications())
    await engine.start()
    _ = await engine.processSample(path: directory.appendingPathComponent("large").path, size: 2 * .gigabyte)
    #expect(try await history.statistics().sampleCount > 0)

    try await engine.resetData()
    let statistics = try await history.statistics()
    #expect(statistics.sampleCount == 0)
    #expect(statistics.anomalyCount == 0)
    #expect(PreferencesStore(defaults: defaults).load().showInDock)
    #expect(await engine.status == .monitoring)
    #expect(await engine.lifecycleResourceCounts().monitors == 1)
    await engine.stop()
}

@Test("Manual audit uses existing caps and rejects overlap")
func boundedManualAudit() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DiskSwellAuditTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for index in 0..<20 {
        FileManager.default.createFile(atPath: directory.appendingPathComponent("file-\(index)").path, contents: Data([0]))
    }
    var configuration = MonitoringConfiguration(watchedRoots: [directory.path])
    configuration.maxStartupAuditPaths = 0
    configuration.maxPeriodicAuditPaths = 1
    configuration.maxAuditEntries = 3
    configuration.maxAuditEntriesPerPath = 3
    let history = SlowAuditHistory(path: directory.path)
    let engine = MonitoringEngine(configuration: configuration, history: history, notifications: SettingsRecordingNotifications())
    await engine.start()

    let first = Task { try await engine.runManualAudit() }
    try await Task.sleep(for: .milliseconds(20))
    do {
        try await engine.runManualAudit()
        Issue.record("Overlapping audit unexpectedly started")
    } catch {
        #expect(error as? MonitoringEngineError == .auditAlreadyRunning)
    }
    try await first.value
    let diagnostics = await engine.diagnosticsSnapshot()
    #expect(diagnostics.manualAuditPathsInspected == 1)
    #expect(diagnostics.reconciliationWorkCount <= 3)
    #expect(diagnostics.lastManualAudit != nil)
    await engine.stop()
}

private func testDefaults() -> (UserDefaults, String) {
    let suite = "DiskSwellTests.\(UUID().uuidString)"
    return (UserDefaults(suiteName: suite)!, suite)
}

private enum TestError: Error { case failed }

@MainActor
private final class MockLaunchAtLoginService: LaunchAtLoginServicing {
    var status: LaunchAtLoginStatus = .disabled
    var registrationResult: LaunchAtLoginStatus = .enabled
    var registrationError: Error?
    var registerCount = 0
    var unregisterCount = 0

    func register() throws {
        registerCount += 1
        if let registrationError { throw registrationError }
        status = registrationResult
    }

    func unregister() {
        unregisterCount += 1
        status = .disabled
    }
}

private actor SettingsRecordingNotifications: NotificationDelivering {
    private(set) var deliveryCount = 0
    private(set) var paths: [String] = []
    func deliver(_ anomaly: Anomaly) -> Bool { deliveryCount += 1; paths.append(anomaly.path); return true }
}

private actor RecordingSettingsHistory: HistoryStore {
    private(set) var anomalyCount = 0
    func prepare() {}
    func record(sample: SizeSample, path: String, type: ItemType, source: SourceClassification) {}
    func record(anomaly: Anomaly) { anomalyCount += 1 }
    func resolveAnomaly(path: String, at: Date) {}
    func applyRetention(now: Date) {}
    func statistics() -> HistoryStatistics { HistoryStatistics(sampleCount: 0, anomalyCount: anomalyCount, fileSize: 0) }
}

private actor SlowAuditHistory: HistoryStore {
    let path: String
    init(path: String) { self.path = path }
    func prepare() {}
    func record(sample: SizeSample, path: String, type: ItemType, source: SourceClassification) {}
    func record(anomaly: Anomaly) {}
    func resolveAnomaly(path: String, at: Date) {}
    func applyRetention(now: Date) {}
    func statistics() -> HistoryStatistics { HistoryStatistics(sampleCount: 0, anomalyCount: 0, fileSize: 0) }
    func auditPaths(limit: Int) async -> [AuditPath] {
        guard limit > 0 else { return [] }
        try? await Task.sleep(for: .milliseconds(100))
        return [AuditPath(path: path, type: .directory, source: .generic, unresolvedSeverity: nil, lastAnomalyUpdate: nil)]
    }
}
