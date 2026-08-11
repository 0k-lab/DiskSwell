import AppKit
import DiskSwellCore
import ServiceManagement
import SwiftUI
@preconcurrency import UserNotifications

@main
struct DiskSwellApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @StateObject private var model = AppModel()
    @State private var currentAlertExpanded = false
    @State private var expandedDetectionIDs: Set<Int64> = []

    var body: some Scene {
        MenuBarExtra("DiskSwell", systemImage: model.snapshot.recentAnomaly == nil ? "internaldrive" : "externaldrive.badge.exclamationmark") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: model.snapshot.recentAnomaly == nil ? "internaldrive" : "externaldrive.badge.exclamationmark")
                        .font(.title2)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("DiskSwell").font(.headline)
                        HStack(spacing: 4) {
                            Circle().fill(Self.statusColor(model.snapshot.status)).frame(width: 7, height: 7)
                            Text(model.snapshot.status.label).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                HStack {
                    Text("Free space").foregroundStyle(.secondary)
                    Spacer()
                    Text(Self.bytes(model.snapshot.freeSpace)).fontWeight(.medium).monospacedDigit()
                }

                let recent = model.snapshot.recentDetections.filter { $0.path != model.snapshot.recentAnomaly?.path }.prefix(4)
                let detectionCount = recent.count + (model.snapshot.recentAnomaly == nil ? 0 : 1)
                if detectionCount > 0 {
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            if let anomaly = model.snapshot.recentAnomaly {
                                Text("Current alert").font(.caption).foregroundStyle(.secondary)
                                anomalyDisclosure(anomaly)
                            }
                            if !recent.isEmpty {
                                Text("Recent detections").font(.caption).foregroundStyle(.secondary)
                                ForEach(recent) { detectionDisclosure($0) }
                            }
                        }
                    }
                    .frame(maxHeight: 480)
                    .fixedSize(horizontal: false, vertical: true)
                }

                if let issue = model.snapshot.accessIssues.first {
                    Divider()
                    Text("Monitoring unavailable for:").font(.caption)
                    Text((issue.root as NSString).abbreviatingWithTildeInPath).lineLimit(2)
                    Text(issue.message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if model.snapshot.accessIssues.contains(where: { $0.kind == .permissionDenied }) {
                        Button("Fix Access…") {
                            openWindow(id: "access")
                            NSApplication.shared.activate(ignoringOtherApps: true)
                        }
                    }
                }

                Divider()
                if model.preferences.diagnosticsEnabled {
                    Text("Events \(model.snapshot.diagnostics.fseventsReceived) · Dirty \(model.snapshot.diagnostics.dirtyPathCount) · Tracked \(model.snapshot.diagnostics.trackedItemCount)")
                        .font(.caption2).foregroundStyle(.secondary)
                    Divider()
                }

                if model.updater.menuStatusMessage != nil {
                    UpdateMenuStatus(controller: model.updater)
                    Divider()
                }

                HStack {
                    Button {
                        openSettings()
                        NSApplication.shared.activate(ignoringOtherApps: true)
                    } label: { Label("Settings…", systemImage: "gearshape") }
                    .keyboardShortcut(",")
                    UpdateMenuControls(controller: model.updater)
                    Spacer()
                    Button { NSApplication.shared.terminate(nil) } label: { Label("Quit", systemImage: "power") }
                        .keyboardShortcut("q")
                }
            }
            .padding(10)
            .frame(width: 340)
        }
        .menuBarExtraStyle(.window)

        Window("DiskSwell Access", id: "access") {
            AccessAssistantView(model: model)
        }
        .windowResizability(.contentSize)

        Settings { SettingsView(model: model) }
    }

    private static func bytes(_ value: Int64?) -> String {
        guard let value else { return "Unknown" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private static func interval(_ seconds: TimeInterval) -> String {
        if seconds >= 24 * 60 * 60 { return "\(Int(seconds / (24 * 60 * 60))) days" }
        if seconds >= 60 * 60 { return "\(Int(seconds / (60 * 60))) hours" }
        return seconds < 60 ? "\(Int(seconds)) sec" : "\(Int(seconds / 60)) min"
    }

    private static func statusColor(_ status: MonitoringStatus) -> Color {
        switch status {
        case .monitoring: .green
        case .ready: .blue
        case .degraded: .orange
        case .stopped: .secondary
        }
    }

    private func anomalyDisclosure(_ anomaly: Anomaly) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.easeInOut(duration: 0.15)) { currentAlertExpanded.toggle() } } label: {
                summary(source: anomaly.source, path: anomaly.path, size: anomaly.currentSize, status: nil, expanded: currentAlertExpanded)
            }
            .buttonStyle(.plain)
            if currentAlertExpanded {
                Divider()
                detail("Source", anomaly.source.label)
                detail("Status", anomaly.severity.label)
                detail("Reason", anomaly.reason)
                detail("Path", (anomaly.path as NSString).abbreviatingWithTildeInPath)
                detail("Detected", anomaly.detectedAt.formatted(date: .abbreviated, time: .shortened))
                if anomaly.growth > 0 { detail("Growth", "+\(Self.bytes(anomaly.growth)) in \(Self.interval(anomaly.interval))") }
                if anomaly.itemCountGrowth > 0 { detail("Files", "+\(anomaly.itemCountGrowth.formatted())") }
                Button("Show in Finder") { Self.showInFinder(anomaly.path) }.frame(maxWidth: .infinity)
            }
        }
        .padding(7)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func detectionDisclosure(_ detection: DetectionRecord) -> some View {
        let expanded = expandedDetectionIDs.contains(detection.id)
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if expanded { expandedDetectionIDs.remove(detection.id) }
                    else { expandedDetectionIDs.insert(detection.id) }
                }
            } label: {
                summary(source: detection.source, path: detection.path, size: detection.currentSize, status: detection.resolvedAt == nil ? "Active" : "Resolved", expanded: expanded)
            }
            .buttonStyle(.plain)
            if expanded {
                Divider()
                detail("Source", detection.source.label)
                detail("Severity", detection.severity.label)
                detail("Reason", detection.reason)
                detail("Path", (detection.path as NSString).abbreviatingWithTildeInPath)
                detail("Detected", detection.detectedAt.formatted(date: .abbreviated, time: .shortened))
                if detection.growth > 0 { detail("Growth", "+\(Self.bytes(detection.growth)) in \(Self.interval(detection.interval))") }
                if detection.itemCountGrowth > 0 { detail("Files", "+\(detection.itemCountGrowth.formatted())") }
                Button("Show in Finder") { Self.showInFinder(detection.path) }.frame(maxWidth: .infinity)
            }
        }
        .padding(7)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func summary(source: SourceClassification, path: String, size: Int64, status: String?, expanded: Bool) -> some View {
        HStack(spacing: 8) {
            Group {
                if let icon = Self.applicationIcon(for: source, path: path) {
                    Image(nsImage: icon).resizable().scaledToFit()
                } else {
                    Image(systemName: sourceSymbol(source))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(sourceColor(source))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(sourceColor(source).opacity(0.16), in: RoundedRectangle(cornerRadius: 7))
                }
            }
            .frame(width: 28, height: 28)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(sourceTitle(source)).fontWeight(.medium).lineLimit(1)
                Text(PathRules.safeDisplayName(path)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(Self.bytes(size)).monospacedDigit()
                if let status {
                    Text(status).font(.caption2.weight(.medium)).foregroundStyle(status == "Active" ? .orange : .secondary)
                }
            }
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.caption.bold()).foregroundStyle(.secondary).frame(width: 10)
        }
        .contentShape(Rectangle())
    }

    private static func applicationIcon(for source: SourceClassification, path: String) -> NSImage? {
        let workspace = NSWorkspace.shared
        let identified = SourceAttribution.applicationBundleIdentifier(for: path)
            .flatMap { workspace.urlForApplication(withBundleIdentifier: $0) }
        let running: URL? = if case let .application(name, _) = source {
            workspace.runningApplications.first { $0.localizedName == name }?.bundleURL
        } else {
            nil
        }
        guard let application = identified ?? running else { return nil }
        return workspace.icon(forFile: application.path)
    }

    private func sourceTitle(_ source: SourceClassification) -> String {
        switch source {
        case .generic: "Filesystem"
        case let .safariWebKit(origin): origin.map { "Safari · \($0)" } ?? "Safari"
        case let .application(name, _): name
        }
    }

    private func sourceSymbol(_ source: SourceClassification) -> String {
        switch source {
        case .generic: "folder.fill"
        case .safariWebKit: "safari.fill"
        case .application: "macwindow"
        }
    }

    private func sourceColor(_ source: SourceClassification) -> Color {
        switch source {
        case .generic: .orange
        case .safariWebKit: .purple
        case .application: .blue
        }
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
            Text(value).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        }
        .font(.caption)
    }

    private static func showInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

private struct AccessAssistantView: View {
    @ObservedObject var model: AppModel
    @State private var notificationAuthorization: UNAuthorizationStatus?

    private var permissionIssues: [AccessIssue] {
        model.snapshot.accessIssues.filter { $0.kind == .permissionDenied }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("DiskSwell Access").font(.title2.bold())
            Text("Review the access DiskSwell uses to detect storage growth.")
                .foregroundStyle(.secondary)

            protectedLocationsStatus

            if !permissionIssues.isEmpty {
                Text("DiskSwell only observes storage growth. It never deletes, modifies, or uploads monitored data.")
                    .font(.callout).foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Blocked locations").font(.headline)
                    ForEach(permissionIssues.prefix(4), id: \.root) { issue in
                        Label((issue.root as NSString).abbreviatingWithTildeInPath, systemImage: "folder")
                            .lineLimit(2).textSelection(.enabled)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("How to fix access").font(.headline)
                    Text("1. Open Full Disk Access settings.")
                    Text("2. Enable DiskSwell, or press + and choose DiskSwell.")
                    Text("3. Accept macOS's Quit & Reopen prompt.")
                }

                HStack {
                    Button("Show DiskSwell in Finder", action: Self.revealApp)
                    Spacer()
                    Button("Open Full Disk Access Settings", action: Self.openFullDiskAccessSettings)
                        .keyboardShortcut(.defaultAction)
                }
            }

            Divider()
            notificationStatus
        }
        .padding(20)
        .frame(width: 480)
        .task {
            notificationAuthorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        }
    }

    @ViewBuilder
    private var protectedLocationsStatus: some View {
        if !permissionIssues.isEmpty {
            statusRow(
                symbol: "exclamationmark.circle.fill",
                color: .red,
                title: "Protected Locations",
                status: "Needs attention",
                detail: "Full Disk Access is recommended for complete Library, Safari, and application-container monitoring."
            )
        } else if model.snapshot.status == .ready || model.snapshot.status == .stopped {
            statusRow(
                symbol: "minus.circle.fill",
                color: .secondary,
                title: "Protected Locations",
                status: "Not checked",
                detail: "Enable monitoring to check access to configured protected locations."
            )
        } else {
            statusRow(
                symbol: "checkmark.circle.fill",
                color: .green,
                title: "Protected Locations",
                status: "Accessible",
                detail: "No macOS privacy denial was detected for configured locations."
            )
        }
    }

    @ViewBuilder
    private var notificationStatus: some View {
        switch notificationAuthorization ?? .notDetermined {
        case .authorized, .provisional, .ephemeral:
            statusRow(
                symbol: "checkmark.circle.fill",
                color: .green,
                title: "Notifications (Optional)",
                status: "Allowed",
                detail: "DiskSwell may deliver disk-growth alerts."
            )
        case .denied:
            statusRow(
                symbol: "xmark.circle.fill",
                color: .red,
                title: "Notifications (Optional)",
                status: "Disabled",
                detail: "Alerts are blocked in System Settings; monitoring still works."
            )
        case .notDetermined:
            statusRow(
                symbol: "circle",
                color: .secondary,
                title: "Notifications (Optional)",
                status: "Not requested",
                detail: "DiskSwell asks only when its first alert needs delivery."
            )
        @unknown default:
            statusRow(
                symbol: "questionmark.circle.fill",
                color: .secondary,
                title: "Notifications (Optional)",
                status: "Unknown",
                detail: "Notification access could not be determined."
            )
        }
    }

    private func statusRow(symbol: String, color: Color, title: String, status: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.title2).foregroundStyle(color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(title).fontWeight(.semibold)
                    Spacer()
                    Text(status).font(.callout.weight(.medium)).foregroundStyle(color)
                }
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    private static func revealApp() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    private static func openFullDiskAccessSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var snapshot = MonitoringSnapshot(status: .ready, freeSpace: nil, recentAnomaly: nil, accessIssues: [], diagnostics: DiagnosticsSnapshot())
    @Published var preferences: DiskSwellPreferences
    @Published var launchAtLoginEnabled = false
    @Published var launchAtLoginMessage: String?
    @Published var dockMessage: String?
    @Published var auditState: SettingsOperationState = .idle
    @Published var resetState: SettingsOperationState = .idle
    @Published var diagnosticsCopyMessage: String?

    let watchedRoots = MonitoringConfiguration.defaultRoots()
    let updater: UpdateController
    private let engine: MonitoringEngine
    private let preferenceStore: PreferencesStore
    private let launchService: any LaunchAtLoginServicing
    private var monitoringTask: Task<Void, Never>?
    private var monitoringTransitionTask: Task<Void, Never>?
    private var notificationTransitionTask: Task<Void, Never>?

    init(
        engine: MonitoringEngine = MonitoringEngine(),
        preferenceStore: PreferencesStore = PreferencesStore(),
        launchService: any LaunchAtLoginServicing = MainAppLaunchService(),
        updater: UpdateController = UpdateController()
    ) {
        self.engine = engine
        self.preferenceStore = preferenceStore
        self.launchService = launchService
        self.updater = updater
        preferences = preferenceStore.load()
        updater.setAutomaticChecksEnabled(preferences.automaticallyChecksForUpdates)
        monitoringTask = Task { [weak self, engine] in
            let stream = await engine.snapshots()
            guard let preferences = self?.preferences else { return }
            self?.applyLaunchAtLoginPreference()
            await engine.setNotificationsEnabled(preferences.notificationsEnabled)
            if preferences.monitoringEnabled { await engine.start() }
            for await snapshot in stream {
                guard !Task.isCancelled else { break }
                guard let self else { break }
                self.snapshot = snapshot
            }
            await engine.stop()
        }
    }

    deinit {
        monitoringTask?.cancel()
        monitoringTransitionTask?.cancel()
        notificationTransitionTask?.cancel()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        preferences.launchAtLogin = enabled
        preferenceStore.save(preferences)
        applyLaunchAtLoginPreference()
    }

    func refreshLaunchAtLogin() {
        apply(LaunchAtLoginController.current(using: launchService))
    }

    func setShowInDock(_ enabled: Bool) {
        preferences.showInDock = enabled
        preferenceStore.save(preferences)
        refreshDockState()
    }

    func refreshDockState() {
        let desiredPolicy: NSApplication.ActivationPolicy = preferences.showInDock ? .regular : .accessory
        dockMessage = NSApplication.shared.activationPolicy() == desiredPolicy ? nil : "Quit and reopen DiskSwell to apply this change."
    }

    func setMonitoringEnabled(_ enabled: Bool) {
        preferences.monitoringEnabled = enabled
        preferenceStore.save(preferences)
        monitoringTransitionTask?.cancel()
        monitoringTransitionTask = Task { [engine] in
            if enabled { await engine.start() } else { await engine.stop() }
        }
    }

    func setNotificationsEnabled(_ enabled: Bool) {
        preferences.notificationsEnabled = enabled
        preferenceStore.save(preferences)
        notificationTransitionTask?.cancel()
        notificationTransitionTask = Task { [engine] in await engine.setNotificationsEnabled(enabled) }
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        preferences.automaticallyChecksForUpdates = enabled
        preferenceStore.save(preferences)
        updater.setAutomaticChecksEnabled(enabled)
    }

    func setDiagnosticsEnabled(_ enabled: Bool) {
        preferences.diagnosticsEnabled = enabled
        preferenceStore.save(preferences)
        diagnosticsCopyMessage = nil
    }

    func runAudit() {
        guard auditState != .running else { return }
        auditState = .running
        Task { [weak self, engine] in
            do {
                try await engine.runManualAudit()
                self?.auditState = .completed("Audit completed.")
            } catch {
                self?.auditState = .failed(error.localizedDescription)
            }
        }
    }

    func copyDiagnostics() {
        let info = Bundle.main.infoDictionary
        let report = DiagnosticsReport.make(
            snapshot: snapshot,
            version: info?["CFBundleShortVersionString"] as? String ?? "Unknown",
            build: info?["CFBundleVersion"] as? String ?? "Unknown",
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: Self.architecture
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        diagnosticsCopyMessage = "Copied."
    }

    func resetData() {
        guard resetState != .running else { return }
        resetState = .running
        Task { [weak self, engine] in
            do {
                try await engine.resetData()
                self?.resetState = .completed("DiskSwell data was reset.")
            } catch {
                self?.resetState = .failed(error.localizedDescription)
            }
        }
    }

    private func applyLaunchAtLoginPreference() {
        apply(LaunchAtLoginController.apply(preferences.launchAtLogin, using: launchService))
    }

    private func apply(_ result: LaunchAtLoginResult) {
        launchAtLoginEnabled = result.isEnabled
        launchAtLoginMessage = result.message
        preferences.launchAtLogin = result.isEnabled
        preferenceStore.save(preferences)
    }

    private static var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }
}

enum SettingsOperationState: Equatable {
    case idle
    case running
    case completed(String)
    case failed(String)

    var message: String? {
        switch self {
        case .idle, .running: nil
        case let .completed(message), let .failed(message): message
        }
    }
}

@MainActor
private final class MainAppLaunchService: LaunchAtLoginServicing {
    private let service = SMAppService.mainApp

    var status: LaunchAtLoginStatus {
        switch service.status {
        case .enabled: .enabled
        case .notRegistered: .disabled
        case .requiresApproval: .requiresApproval
        case .notFound: .unavailable
        @unknown default: .unavailable
        }
    }

    func register() throws { try service.register() }
    func unregister() throws { try service.unregister() }
}

private final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        let policy: NSApplication.ActivationPolicy = PreferencesStore().load().showInDock ? .regular : .accessory
        NSApplication.shared.setActivationPolicy(policy)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        Diagnostics.debug("Application started")
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        defer { completionHandler() }
        guard response.actionIdentifier == LocalNotificationService.showInFinderAction,
              let path = response.notification.request.content.userInfo["path"] as? String else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
