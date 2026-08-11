import AppKit
import DiskSwellCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var confirmsReset = false

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at Login", isOn: Binding(get: { model.launchAtLoginEnabled }, set: { model.setLaunchAtLogin($0) }))
                if let message = model.launchAtLoginMessage { help(message) }

                Toggle("Show DiskSwell in Dock", isOn: Binding(get: { model.preferences.showInDock }, set: { model.setShowInDock($0) }))
                if let message = model.dockMessage { help(message) }
            }

            Section("Monitoring") {
                Toggle("Monitoring Enabled", isOn: Binding(get: { model.preferences.monitoringEnabled }, set: { model.setMonitoringEnabled($0) }))
                Toggle("Notifications", isOn: Binding(get: { model.preferences.notificationsEnabled }, set: { model.setNotificationsEnabled($0) }))
                Text("Turning notifications off does not stop detection or history.").font(.caption).foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Watched Locations").font(.headline)
                    ForEach(model.watchedRoots, id: \.self) { root in
                        let state = status(for: root)
                        HStack {
                            Text(label(for: root))
                            Spacer()
                            HStack(spacing: 6) {
                                Circle().fill(statusColor(state)).frame(width: 6, height: 6)
                                Text(state).foregroundStyle(.secondary)
                            }
                            .fixedSize()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack {
                    Button(model.auditState == .running ? "Running Audit…" : "Run Audit Now", action: model.runAudit)
                        .disabled(!model.preferences.monitoringEnabled || model.auditState == .running)
                    if model.auditState == .running { ProgressView().controlSize(.small) }
                    if let message = model.auditState.message { Text(message).font(.caption).foregroundStyle(.secondary) }
                }
            }

            Section("Updates") {
                UpdateSettingsControls(
                    controller: model.updater,
                    automaticallyChecks: Binding(
                        get: { model.preferences.automaticallyChecksForUpdates },
                        set: { model.setAutomaticallyChecksForUpdates($0) }
                    )
                )
            }

            Section("Advanced") {
                Toggle("Enable Diagnostics", isOn: Binding(get: { model.preferences.diagnosticsEnabled }, set: { model.setDiagnosticsEnabled($0) }))
                if model.preferences.diagnosticsEnabled {
                    diagnostics
                    HStack {
                        Button("Copy Diagnostics", action: model.copyDiagnostics)
                        if let message = model.diagnosticsCopyMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }

            Section("Data") {
                LabeledContent("History", value: bytes(model.snapshot.diagnostics.sqliteFileSize))
                LabeledContent("Retention", value: "30 days")
                HStack {
                    Button("Reset DiskSwell Data…", role: .destructive) { confirmsReset = true }
                        .disabled(model.resetState == .running)
                    if model.resetState == .running { ProgressView().controlSize(.small) }
                    if let message = model.resetState.message { Text(message).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 600, height: 650)
        .onAppear {
            model.refreshLaunchAtLogin()
            model.refreshDockState()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshLaunchAtLogin()
            model.refreshDockState()
        }
        .alert("Reset DiskSwell Data?", isPresented: $confirmsReset) {
            Button("Cancel", role: .cancel) {}
            Button("Reset Data", role: .destructive, action: model.resetData)
        } message: {
            Text("This removes DiskSwell's local monitoring history and tracked state. It does not delete or modify files on your Mac.")
        }
    }

    private var diagnostics: some View {
        let value = model.snapshot.diagnostics
        return VStack(alignment: .leading, spacing: 3) {
            Text("FSEvents: \(value.fseventsReceived) · Batches: \(value.coalescedBatches) · Dirty: \(value.dirtyPathCount)")
            Text("Tracked: \(value.trackedItemCount) · Aggregates: \(value.trackedDirectoryAggregates) · Anomalies: \(value.anomalyCount)")
            Text("Overflows/evictions: \(value.dirtyPathOverflows + value.aggregateOverflows)/\(value.trackedItemEvictions + value.aggregateEvictions)")
            Text("Monitoring: \(model.preferences.monitoringEnabled ? model.snapshot.status.label : "Paused")")
            Text("Audits: startup \(audit(value.lastStartupAudit)) · periodic \(audit(value.lastPeriodicAudit)) · manual \(audit(value.lastManualAudit))")
            if !model.snapshot.accessIssues.isEmpty { Text("Permission limitations: \(model.snapshot.accessIssues.count)") }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    }

    private func label(for root: String) -> String {
        if root.hasSuffix("/Library/Developer") { return "Developer Data" }
        if root.hasSuffix("/Library/Containers/com.apple.Safari") { return "Safari Data" }
        if root.hasSuffix("/Library/Containers") { return "Application Containers" }
        if root.hasSuffix("/Downloads") { return "Downloads" }
        if root.hasSuffix("/Library") { return "Library" }
        return PathRules.safeDisplayName(root)
    }

    private func status(for root: String) -> String {
        guard model.preferences.monitoringEnabled else { return "Paused" }
        guard let issue = model.snapshot.accessIssues.first(where: { PathRules.normalize($0.root) == PathRules.normalize(root) }) else { return "Monitoring" }
        return issue.kind == .permissionDenied ? "Limited Access" : "Unavailable"
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "Monitoring": .green
        case "Limited Access": .orange
        case "Unavailable": .red
        default: .secondary
        }
    }

    private func help(_ message: String) -> some View {
        Text(message).font(.caption).foregroundStyle(.secondary)
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private func audit(_ date: Date?) -> String {
        date?.formatted(date: .abbreviated, time: .shortened) ?? "Never"
    }
}
