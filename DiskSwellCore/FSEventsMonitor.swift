import CoreServices
import Foundation

public struct FileSystemEventBatch: Sendable {
    public let paths: [String]
    public let receivedCount: Int
    public let droppedCount: Int
}

public enum FSEventsMonitorError: Error {
    case streamCreationFailed
    case streamStartFailed
}

public final class FSEventsMonitor: @unchecked Sendable {
    public let events: AsyncStream<FileSystemEventBatch>
    private let roots: [String]
    private let latency: TimeInterval
    private let maxBatchSize: Int
    private let continuation: AsyncStream<FileSystemEventBatch>.Continuation
    private let queue = DispatchQueue(label: "com.diskswell.fsevents", qos: .utility)
    private var stream: FSEventStreamRef?
    private var bufferedDrops = 0

    public init(roots: [String], latency: TimeInterval, maxBatchSize: Int, maxBufferedBatches: Int) {
        self.roots = PathRules.deduplicatedRoots(roots)
        self.latency = latency
        self.maxBatchSize = max(1, maxBatchSize)
        var continuation: AsyncStream<FileSystemEventBatch>.Continuation!
        events = AsyncStream(bufferingPolicy: .bufferingNewest(max(1, maxBufferedBatches))) { continuation = $0 }
        self.continuation = continuation
    }

    public func start() throws {
        try queue.sync {
            guard stream == nil else { return }
            var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
            let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
            guard let created = FSEventStreamCreate(nil, Self.callback, &context, roots as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else {
                throw FSEventsMonitorError.streamCreationFailed
            }
            stream = created
            FSEventStreamSetDispatchQueue(created, queue)
            guard FSEventStreamStart(created) else {
                FSEventStreamInvalidate(created)
                FSEventStreamRelease(created)
                stream = nil
                throw FSEventsMonitorError.streamStartFailed
            }
        }
    }

    public func stop() {
        queue.sync {
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        continuation.finish()
    }

    deinit { stop() }

    private func receive(count: Int, rawPaths: UnsafeMutableRawPointer?, flags: UnsafePointer<FSEventStreamEventFlags>?) {
        guard count > 0, let rawPaths else { return }
        let values = unsafeBitCast(rawPaths, to: NSArray.self)
        var paths: [String] = []
        paths.reserveCapacity(min(count, maxBatchSize))
        let dropFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped)
        var flaggedDrops = 0
        for index in 0..<min(count, maxBatchSize) {
            let eventFlags = flags?[index] ?? 0
            if eventFlags & dropFlags != 0 { flaggedDrops += 1 }
            if Self.shouldInspect(eventFlags), let path = values[index] as? String { paths.append(path) }
        }
        let batch = FileSystemEventBatch(paths: paths, receivedCount: count, droppedCount: max(0, count - maxBatchSize) + flaggedDrops + bufferedDrops)
        bufferedDrops = 0
        switch continuation.yield(batch) {
        case .enqueued: break
        case let .dropped(dropped): bufferedDrops += dropped.receivedCount + dropped.droppedCount
        case .terminated: break
        @unknown default: break
        }
    }

    private static let callback: FSEventStreamCallback = { _, context, count, paths, flags, _ in
        guard let context else { return }
        Unmanaged<FSEventsMonitor>.fromOpaque(context).takeUnretainedValue().receive(count: count, rawPaths: paths, flags: flags)
    }

    static func shouldInspect(_ flags: FSEventStreamEventFlags) -> Bool {
        let directory = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0
        let requiresReconciliation = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped) != 0
        let movedOrRemoved = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemRemoved) != 0
        return !directory || requiresReconciliation || movedOrRemoved
    }
}
