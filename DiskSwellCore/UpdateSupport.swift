import Foundation

public struct ReleaseVersion: Comparable, CustomStringConvertible, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init?(_ value: String) {
        let normalized = value.first == "v" ? String(value.dropFirst()) : value
        let parts = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let major = Int(parts[0]), major >= 0,
              let minor = Int(parts[1]), minor >= 0,
              let patch = Int(parts[2]), patch >= 0 else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

public enum ReleaseChecksum {
    public static func sha256(in contents: String, for filename: String) -> String? {
        for line in contents.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2 else { continue }
            let digest = String(fields[0]).lowercased()
            let listedFilename = fields[1].first == "*" ? fields[1].dropFirst() : fields[1][...]
            guard listedFilename == filename,
                  digest.count == 64,
                  digest.allSatisfy(\.isHexDigit) else { continue }
            return digest
        }
        return nil
    }
}

public enum DiskSwellReleaseLocation {
    public static let owners = ["0k-lab", "kricha-lab"]

    public static var latestReleaseURLs: [URL] {
        owners.compactMap { URL(string: "https://github.com/\($0)/DiskSwell/releases/latest") }
    }

    public static func assets(for releaseURL: URL) -> (version: ReleaseVersion, packageURL: URL, checksumURL: URL)? {
        let path = releaseURL.path.split(separator: "/").map(String.init)
        guard releaseURL.scheme == "https", releaseURL.host?.lowercased() == "github.com",
              path.count == 5, owners.contains(path[0]), path[1...3] == ["DiskSwell", "releases", "tag"],
              let version = ReleaseVersion(path[4]),
              let packageURL = URL(string: "https://github.com/\(path[0])/DiskSwell/releases/download/\(path[4])/DiskSwell.pkg"),
              let checksumURL = URL(string: "https://github.com/\(path[0])/DiskSwell/releases/download/\(path[4])/DiskSwell.pkg.sha256") else { return nil }
        return (version, packageURL, checksumURL)
    }

    public static func isTrustedAssetURL(_ url: URL) -> Bool {
        url.scheme == "https"
            && url.host?.lowercased() == "github.com"
            && owners.contains { url.path.hasPrefix("/\($0)/DiskSwell/releases/download/") }
    }
}

public enum InstallerPackageTrust {
    public static func matches(_ pkgutilOutput: String, teamID: String) -> Bool {
        guard pkgutilOutput.contains("Signed with a trusted timestamp") else { return false }
        return pkgutilOutput.split(separator: "\n").contains {
            $0.contains("Developer ID Installer:") && $0.hasSuffix("(\(teamID))")
        }
    }
}
