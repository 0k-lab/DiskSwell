import AppKit
import CryptoKit
import DiskSwellCore
import Foundation
import Security
import SwiftUI

@MainActor
final class UpdateController: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(String)
        case downloading(String)
        case installerOpened(String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private static let lastCheckKey = "lastUpdateCheckAt"
    private let service: UpdateService
    private let defaults: UserDefaults
    private var availableRelease: UpdateRelease?
    private var workTask: Task<Void, Never>?
    private var automaticTask: Task<Void, Never>?

    init(service: UpdateService = UpdateService(), defaults: UserDefaults = .standard) {
        self.service = service
        self.defaults = defaults
    }

    deinit {
        workTask?.cancel()
        automaticTask?.cancel()
    }

    var isBusy: Bool {
        switch state {
        case .checking, .downloading: true
        default: false
        }
    }

    var actionTitle: String {
        switch state {
        case .checking: "Checking…"
        case let .available(version): "Download and Install \(version)…"
        case let .downloading(version): "Downloading \(version)…"
        case .installerOpened: "Check Again"
        case .idle, .upToDate, .failed: "Check for Updates…"
        }
    }

    var menuActionTitle: String {
        switch state {
        case .checking: "Checking…"
        case let .available(version): "Install \(version)…"
        case .downloading: "Downloading…"
        case .upToDate: "Up to Date"
        case .idle, .installerOpened, .failed: "Updates…"
        }
    }

    var statusMessage: String? {
        switch state {
        case .idle: nil
        case .checking: "Contacting GitHub Releases…"
        case .upToDate: "You’re running the latest version."
        case let .available(version): "DiskSwell \(version) is available."
        case let .downloading(version): "Downloading and verifying DiskSwell \(version)…"
        case let .installerOpened(version): "macOS Installer opened for DiskSwell \(version)."
        case let .failed(message): message
        }
    }

    var menuStatusMessage: String? {
        switch state {
        case .checking, .available, .downloading, .failed: statusMessage
        case .idle, .upToDate, .installerOpened: nil
        }
    }

    var hasError: Bool {
        if case .failed = state { return true }
        return false
    }

    func setAutomaticChecksEnabled(_ enabled: Bool) {
        automaticTask?.cancel()
        automaticTask = nil
        guard enabled else { return }
        automaticTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let delay = self?.nextAutomaticDelay else { return }
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                if self?.isAutomaticCheckDue == true { self?.checkForUpdates(manual: false) }
            }
        }
    }

    func performPrimaryAction() {
        if case .available = state { installAvailableUpdate() } else { checkForUpdates(manual: true) }
    }

    func checkForUpdates(manual: Bool = true) {
        guard workTask == nil else { return }
        if manual { state = .checking }
        defaults.set(Date(), forKey: Self.lastCheckKey)
        workTask = Task { [weak self, service] in
            guard let self else { return }
            do {
                let release = try await service.latestRelease()
                guard release.version > service.currentVersion else {
                    availableRelease = nil
                    state = manual ? .upToDate : .idle
                    workTask = nil
                    return
                }
                availableRelease = release
                state = .available(release.version.description)
            } catch {
                state = manual ? .failed(error.localizedDescription) : .idle
                Diagnostics.debug("Automatic update check failed: \(error.localizedDescription)")
            }
            workTask = nil
        }
    }

    private func installAvailableUpdate() {
        guard workTask == nil, let release = availableRelease else { return }
        state = .downloading(release.version.description)
        workTask = Task { [weak self, service] in
            guard let self else { return }
            do {
                let package = try await service.downloadAndVerify(release)
                guard NSWorkspace.shared.open(package) else { throw UpdateError.cannotOpenInstaller }
                state = .installerOpened(release.version.description)
            } catch {
                state = .failed(error.localizedDescription)
            }
            workTask = nil
        }
    }

    private var nextAutomaticDelay: TimeInterval {
        guard let lastCheck = defaults.object(forKey: Self.lastCheckKey) as? Date else { return 10 }
        return min(24 * 60 * 60, max(10, 24 * 60 * 60 - Date().timeIntervalSince(lastCheck)))
    }

    private var isAutomaticCheckDue: Bool {
        guard let lastCheck = defaults.object(forKey: Self.lastCheckKey) as? Date else { return true }
        return Date().timeIntervalSince(lastCheck) >= 24 * 60 * 60
    }
}

struct UpdateMenuControls: View {
    @ObservedObject var controller: UpdateController

    var body: some View {
        Button(action: controller.performPrimaryAction) {
            Label(controller.menuActionTitle, systemImage: controller.state == .upToDate ? "checkmark.circle" : "arrow.triangle.2.circlepath")
        }
        .disabled(controller.isBusy)
    }
}

struct UpdateMenuStatus: View {
    @ObservedObject var controller: UpdateController

    var body: some View {
        if let message = controller.menuStatusMessage {
            HStack(spacing: 6) {
                if controller.hasError {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                } else if controller.isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
                }
                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }
}

struct UpdateSettingsControls: View {
    @ObservedObject var controller: UpdateController
    let automaticallyChecks: Binding<Bool>

    var body: some View {
        Toggle("Automatically Check for Updates", isOn: automaticallyChecks)
        Text("When enabled, DiskSwell contacts only GitHub Releases once per day. Monitoring data never leaves your Mac.")
            .font(.caption)
            .foregroundStyle(.secondary)
        HStack {
            Button(controller.actionTitle, action: controller.performPrimaryAction)
                .disabled(controller.isBusy)
            if controller.isBusy { ProgressView().controlSize(.small) }
            if let message = controller.statusMessage {
                if controller.hasError {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct UpdateService: Sendable {
    let currentVersion: ReleaseVersion

    init(currentVersion: ReleaseVersion? = nil) {
        self.currentVersion = currentVersion
            ?? ReleaseVersion(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
            ?? ReleaseVersion("0.0.0")!
    }

    func latestRelease() async throws -> UpdateRelease {
        let url = URL(string: "https://api.github.com/repos/kricha-lab/DiskSwell/releases/latest")!
        let (data, response) = try await URLSession.shared.data(for: request(url))
        if (response as? HTTPURLResponse)?.statusCode == 404 { throw UpdateError.noPublishedRelease }
        try validate(response)
        let payload = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard let version = ReleaseVersion(payload.tagName) else { throw UpdateError.invalidRelease }
        guard let package = payload.assets.first(where: { $0.name == "DiskSwell.pkg" }),
              let checksum = payload.assets.first(where: { $0.name == "DiskSwell.pkg.sha256" }),
              (1...100_000_000).contains(package.size),
              (1...4_096).contains(checksum.size),
              isTrustedAssetURL(package.downloadURL),
              isTrustedAssetURL(checksum.downloadURL) else { throw UpdateError.missingAssets }
        return UpdateRelease(version: version, packageURL: package.downloadURL, checksumURL: checksum.downloadURL)
    }

    func downloadAndVerify(_ release: UpdateRelease) async throws -> URL {
        let (checksumData, checksumResponse) = try await URLSession.shared.data(for: request(release.checksumURL))
        try validate(checksumResponse)
        guard checksumData.count <= 4_096,
              let checksumText = String(data: checksumData, encoding: .utf8),
              let expected = ReleaseChecksum.sha256(in: checksumText, for: "DiskSwell.pkg") else {
            throw UpdateError.invalidChecksum
        }

        let (downloaded, packageResponse) = try await URLSession.shared.download(for: request(release.packageURL))
        try validate(packageResponse)
        let values = try downloaded.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize, (1...100_000_000).contains(size) else { throw UpdateError.invalidPackage }

        let data = try Data(contentsOf: downloaded, options: .mappedIfSafe)
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == expected else { throw UpdateError.checksumMismatch }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskSwell-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let package = directory.appendingPathComponent("DiskSwell.pkg")
        try FileManager.default.copyItem(at: downloaded, to: package)
        try verifyPublisher(of: package)
        return package
    }

    private func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("DiskSwell/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func validate(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else { throw UpdateError.networkResponse }
    }

    private func isTrustedAssetURL(_ url: URL) -> Bool {
        url.scheme == "https"
            && url.host?.lowercased() == "github.com"
            && url.path.hasPrefix("/kricha-lab/DiskSwell/releases/download/")
    }

    private func verifyPublisher(of package: URL) throws {
        let teamID = try signingTeamIdentifier()
        let signature = try run("/usr/sbin/pkgutil", arguments: ["--check-signature", package.path])
        guard signature.status == 0,
              InstallerPackageTrust.matches(signature.output, teamID: teamID) else {
            throw UpdateError.untrustedPublisher
        }
        let assessment = try run("/usr/sbin/spctl", arguments: ["--assess", "--type", "install", "--verbose=2", package.path])
        guard assessment.status == 0 else { throw UpdateError.untrustedPublisher }
    }

    private func signingTeamIdentifier() throws -> String {
        var dynamicCode: SecCode?
        guard SecCodeCopySelf([], &dynamicCode) == errSecSuccess, let dynamicCode else {
            throw UpdateError.untrustedRunningApp
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(dynamicCode, [], &staticCode) == errSecSuccess, let staticCode else {
            throw UpdateError.untrustedRunningApp
        }
        let validationFlags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        guard SecStaticCodeCheckValidity(staticCode, validationFlags, nil) == errSecSuccess else {
            throw UpdateError.untrustedRunningApp
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let teamID = (information as? [CFString: Any])?[kSecCodeInfoTeamIdentifier] as? String,
              !teamID.isEmpty else { throw UpdateError.untrustedRunningApp }
        return teamID
    }

    private func run(_ executable: String, arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ["LC_ALL": "C"]
        process.standardOutput = output
        process.standardError = output
        do { try process.run() } catch { throw UpdateError.cannotVerifyInstaller }
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }
}

struct UpdateRelease: Sendable {
    let version: ReleaseVersion
    let packageURL: URL
    let checksumURL: URL
}

private struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let downloadURL: URL
        let size: Int

        enum CodingKeys: String, CodingKey {
            case name
            case downloadURL = "browser_download_url"
            case size
        }
    }

    let tagName: String
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }
}

private enum UpdateError: LocalizedError {
    case noPublishedRelease
    case invalidRelease
    case missingAssets
    case networkResponse
    case invalidChecksum
    case invalidPackage
    case checksumMismatch
    case untrustedRunningApp
    case untrustedPublisher
    case cannotVerifyInstaller
    case cannotOpenInstaller

    var errorDescription: String? {
        switch self {
        case .noPublishedRelease: "No published releases are available yet."
        case .invalidRelease: "The latest release has an invalid version."
        case .missingAssets: "The latest release does not contain a valid DiskSwell installer."
        case .networkResponse: "GitHub did not return a valid update response."
        case .invalidChecksum: "The update checksum is invalid."
        case .invalidPackage: "The downloaded installer is invalid."
        case .checksumMismatch: "The downloaded installer failed verification and was not opened."
        case .untrustedRunningApp: "Automatic installation requires an official signed DiskSwell build."
        case .untrustedPublisher: "The downloaded installer is not trusted as an official DiskSwell update and was not opened."
        case .cannotVerifyInstaller: "macOS could not verify the downloaded installer."
        case .cannotOpenInstaller: "macOS could not open the downloaded installer."
        }
    }
}
