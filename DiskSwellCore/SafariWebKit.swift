import AppKit
import Darwin

public enum SafariWebKit {
    private static let marker = "/Library/Containers/com.apple.Safari/Data/Library/WebKit/WebsiteData/"
    private static let metadataNames = ["origin", "Origin", "origin.txt"]

    public static func isWAL(path: String) -> Bool {
        let normalized = PathRules.normalize(path)
        let name = URL(fileURLWithPath: normalized).lastPathComponent.lowercased()
        return normalized.contains(marker) && (name.hasSuffix("-wal") || name.hasSuffix(".sqlite-wal") || name.hasSuffix(".sqlite3-wal"))
    }

    public static func isWebsiteData(path: String) -> Bool {
        PathRules.normalize(path).contains(marker)
    }

    public static func origin(forPath path: String) -> String? {
        let normalized = PathRules.normalize(path)
        guard normalized.contains(marker) else { return nil }
        var directory = URL(fileURLWithPath: normalized).deletingLastPathComponent()
        for _ in 0..<8 {
            for name in metadataNames {
                if let text = smallMetadataFile(at: directory.appendingPathComponent(name)), let host = host(in: text) { return host }
            }
            if let host = legacyHost(in: directory.lastPathComponent) { return host }
            guard directory.path.contains(marker.dropLast()) else { break }
            directory.deleteLastPathComponent()
        }
        return nil
    }

    private static func smallMetadataFile(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4_096) else { return nil }
        return binaryOrigin(in: data) ?? String(data: data, encoding: .utf8)
    }

    private static func binaryOrigin(in data: Data) -> String? {
        var offset = 0
        func string() -> String? {
            guard offset + 5 <= data.count else { return nil }
            let length = Int(data[offset])
                | Int(data[offset + 1]) << 8
                | Int(data[offset + 2]) << 16
                | Int(data[offset + 3]) << 24
            offset += 4
            guard length > 0, length <= 1_024, data[offset] == 1, offset + 1 + length <= data.count else { return nil }
            offset += 1
            defer { offset += length }
            return String(data: data[offset..<(offset + length)], encoding: .utf8)
        }
        guard let scheme = string(), let host = string() else { return nil }
        return "\(scheme)://\(host)"
    }

    private static func host(in text: String) -> String? {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'{}[](),;"))
        for token in text.components(separatedBy: separators) where token.contains("://") {
            if let host = URLComponents(string: token)?.host.flatMap(sanitize) { return host }
        }
        return nil
    }

    private static func legacyHost(in name: String) -> String? {
        let parts = name.split(separator: "_")
        guard parts.count >= 2, parts[0] == "http" || parts[0] == "https" else { return nil }
        return sanitize(String(parts[1]))
    }

    private static func sanitize(_ value: String) -> String? {
        let host = value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        guard !host.isEmpty, host.count <= 253, host.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return host
    }
}

enum SourceAttribution {
    static func source(for path: String) -> SourceClassification {
        source(for: path, applicationName: installedApplicationName)
    }

    static func source(for path: String, applicationName: (String) -> String?) -> SourceClassification {
        let path = PathRules.normalize(path)
        if SafariWebKit.isWebsiteData(path: path) {
            return .safariWebKit(origin: SafariWebKit.origin(forPath: path))
        }
        if path.contains("/Library/Developer/Xcode/") {
            return .application(name: "Xcode", confidence: .verified)
        }
        if let identifier = component(after: "/Library/Containers/", in: path) {
            return .application(name: safeName(applicationName(identifier)) ?? identifier, confidence: .verified)
        }
        if let identifier = component(after: "/Library/Group Containers/", in: path) {
            let candidate = groupBundleIdentifier(identifier)
            let name = safeName(applicationName(candidate)) ?? friendlyIdentifier(candidate)
            return .application(name: name, confidence: .likely)
        }
        if let name = component(after: "/Library/Application Support/", in: path).flatMap(safeName) {
            return .application(name: name, confidence: .likely)
        }
        if path.contains("/Downloads/"), let agent = quarantineAgent(at: path) {
            return .application(name: agent, confidence: .likely)
        }
        return .generic
    }

    static func quarantineAgent(in value: String) -> String? {
        let fields = value.split(separator: ";", omittingEmptySubsequences: false)
        guard fields.count > 2 else { return nil }
        return safeName(String(fields[2]))
    }

    private static func installedApplicationName(_ identifier: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier),
              let bundle = Bundle(url: url), bundle.bundleIdentifier == identifier else { return nil }
        return (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
    }

    private static func component(after marker: String, in path: String) -> String? {
        guard let range = path.range(of: marker) else { return nil }
        return path[range.upperBound...].split(separator: "/").first.map(String.init)
    }

    private static func groupBundleIdentifier(_ identifier: String) -> String {
        let parts = identifier.split(separator: ".")
        guard parts.count > 1 else { return identifier }
        let first = String(parts[0])
        let isTeamIdentifier = first.count == 10 && first.allSatisfy { $0.isUppercase || $0.isNumber }
        return first == "group" || isTeamIdentifier ? parts.dropFirst().joined(separator: ".") : identifier
    }

    private static func friendlyIdentifier(_ identifier: String) -> String {
        safeName(identifier.split(separator: ".").last.map(String.init)) ?? identifier
    }

    private static func safeName(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : String(cleaned.prefix(80))
    }

    private static func quarantineAgent(at path: String) -> String? {
        var buffer = [UInt8](repeating: 0, count: 1_024)
        let count = path.withCString { file in
            "com.apple.quarantine".withCString { name in
                buffer.withUnsafeMutableBytes { bytes in
                    getxattr(file, name, bytes.baseAddress, bytes.count, 0, 0)
                }
            }
        }
        guard count > 0 else { return nil }
        return quarantineAgent(in: String(decoding: buffer.prefix(count), as: UTF8.self))
    }
}
