import Foundation

public struct InspectedItem: Sendable, Equatable {
    public let path: String
    public let type: ItemType
    public let size: Int64
    public let logicalSize: Int64
    public let itemCount: Int64?
    public let isApproximate: Bool

    public init(path: String, type: ItemType, size: Int64, logicalSize: Int64? = nil, itemCount: Int64? = nil, isApproximate: Bool = false) {
        self.path = path
        self.type = type
        self.size = size
        self.logicalSize = logicalSize ?? size
        self.itemCount = itemCount
        self.isApproximate = isApproximate
    }
}

public struct InspectionResult: Sendable, Equatable {
    public let items: [InspectedItem]
    public let accessIssue: AccessIssue?
    public let visitedEntries: Int
    public let truncated: Bool
}

public struct TargetedFileInspector: Sendable {
    private static let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey]

    public init() {}

    public func inspect(path: String, maxEntries: Int, maxDepth: Int, excluding excludedRoots: [String] = []) -> InspectionResult {
        let normalized = PathRules.normalize(path)
        let excludedRoots = excludedRoots.map(PathRules.normalize)
        guard !excludedRoots.contains(where: { PathRules.contains($0, normalized) }) else {
            return InspectionResult(items: [], accessIssue: nil, visitedEntries: 0, truncated: false)
        }
        let url = URL(fileURLWithPath: normalized)
        do {
            let values = try url.resourceValues(forKeys: Self.keys)
            if values.isRegularFile == true {
                let sizes = Self.sizes(values)
                return InspectionResult(items: [InspectedItem(path: normalized, type: .file, size: sizes.allocated, logicalSize: sizes.logical)], accessIssue: nil, visitedEntries: 1, truncated: false)
            }
            guard values.isDirectory == true else { return InspectionResult(items: [], accessIssue: nil, visitedEntries: 0, truncated: false) }
            return inspectDirectory(url, maxEntries: max(1, maxEntries), maxDepth: max(1, maxDepth), excluding: excludedRoots)
        } catch {
            return InspectionResult(items: [], accessIssue: Self.permissionIssue(error, path: normalized), visitedEntries: 0, truncated: false)
        }
    }

    public static func permissionIssue(_ error: Error, path: String) -> AccessIssue? {
        let nsError = error as NSError
        let permissionCodes = [NSFileReadNoPermissionError, NSFileWriteNoPermissionError]
        guard (nsError.domain == NSCocoaErrorDomain && permissionCodes.contains(nsError.code)) || (nsError.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(nsError.code)) else { return nil }
        return AccessIssue(root: path, kind: .permissionDenied, message: "DiskSwell cannot access this location. Additional macOS privacy permission may be required.")
    }

    private func inspectDirectory(_ root: URL, maxEntries: Int, maxDepth: Int, excluding excludedRoots: [String]) -> InspectionResult {
        var issue: AccessIssue?
        var truncated = false
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(Self.keys), options: [], errorHandler: { url, error in
            if issue == nil { issue = Self.permissionIssue(error, path: url.path) }
            truncated = true
            return true
        }) else {
            return InspectionResult(items: [], accessIssue: AccessIssue(root: root.path, message: "DiskSwell cannot enumerate this location."), visitedEntries: 0, truncated: false)
        }
        var items: [InspectedItem] = []
        items.reserveCapacity(min(maxEntries, 128))
        var total: Int64 = 0
        var logicalTotal: Int64 = 0
        var itemCount: Int64 = 0
        var visited = 0
        while let child = enumerator.nextObject() as? URL {
            let depth = child.pathComponents.count - root.pathComponents.count
            if visited >= maxEntries {
                truncated = true
                break
            }
            visited += 1
            guard let values = try? child.resourceValues(forKeys: Self.keys) else { continue }
            if excludedRoots.contains(where: { PathRules.contains($0, child.path) }) {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if values.isDirectory == true, depth >= maxDepth {
                enumerator.skipDescendants()
                truncated = true
            }
            if values.isRegularFile == true {
                let sizes = Self.sizes(values)
                total = total.addingReportingOverflow(sizes.allocated).overflow ? Int64.max : total + sizes.allocated
                logicalTotal = logicalTotal.addingReportingOverflow(sizes.logical).overflow ? Int64.max : logicalTotal + sizes.logical
                itemCount += 1
                items.append(InspectedItem(path: child.path, type: .file, size: sizes.allocated, logicalSize: sizes.logical))
            }
        }
        items.append(InspectedItem(path: root.path, type: .directory, size: total, logicalSize: logicalTotal, itemCount: itemCount, isApproximate: truncated))
        return InspectionResult(items: items, accessIssue: issue, visitedEntries: visited, truncated: truncated)
    }

    private static func sizes(_ values: URLResourceValues) -> (allocated: Int64, logical: Int64) {
        let logical = Int64(values.fileSize ?? 0)
        return (Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0), logical)
    }
}
