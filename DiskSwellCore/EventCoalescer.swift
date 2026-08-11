import Foundation

public struct EventCoalescer: Sendable {
    public let roots: [String]
    public let capacity: Int
    private var buckets: [String: String] = [:]
    public private(set) var overflowCount = 0
    public private(set) var collapsedCount = 0

    public init(roots: [String], capacity: Int) {
        self.roots = PathRules.deduplicatedRoots(roots)
        self.capacity = max(1, capacity)
    }

    public mutating func ingest(_ paths: some Sequence<String>) {
        for rawPath in paths {
            let path = PathRules.normalize(rawPath)
            guard let root = roots.first(where: { PathRules.contains($0, path) }) else { continue }
            guard buckets[path] == nil, buckets[root] == nil else { continue }
            if buckets.count < capacity { buckets[path] = path }
            else { collapseTowardRoot(root) }
        }
    }

    public mutating func drain() -> [String] {
        let result = buckets.values.sorted()
        buckets.removeAll(keepingCapacity: true)
        return result
    }

    public var count: Int { buckets.count }

    private mutating func collapseTowardRoot(_ root: String) {
        let removed = buckets.keys.filter { PathRules.contains(root, buckets[$0] ?? "") }
        for key in removed { buckets.removeValue(forKey: key) }
        if removed.isEmpty, buckets.count >= capacity, let victim = buckets.keys.sorted().last {
            buckets.removeValue(forKey: victim)
            collapsedCount += 1
        }
        buckets[root] = root
        overflowCount += 1
        collapsedCount += max(1, removed.count)
    }
}
