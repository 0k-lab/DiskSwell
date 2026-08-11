@preconcurrency import UserNotifications
import Foundation

public protocol NotificationDelivering: Sendable {
    @discardableResult
    func deliver(_ anomaly: Anomaly) async throws -> Bool
}

public actor LocalNotificationService: NotificationDelivering {
    public static let categoryIdentifier = "DISKSWELL_ANOMALY"
    public static let showInFinderAction = "SHOW_IN_FINDER"
    private let center: UNUserNotificationCenter
    private let capacity: Int
    private var identifiers: [String] = []
    private var requestedAuthorization = false

    public init(capacity: Int = 64, center: UNUserNotificationCenter = .current()) {
        self.capacity = max(1, capacity)
        self.center = center
        let action = UNNotificationAction(identifier: Self.showInFinderAction, title: "Show in Finder")
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.categoryIdentifier, actions: [action], intentIdentifiers: [])])
    }

    public func deliver(_ anomaly: Anomaly) async throws -> Bool {
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            guard !requestedAuthorization else { return false }
            requestedAuthorization = true
            guard try await center.requestAuthorization(options: [.alert, .sound]) else { return false }
        } else if settings.authorizationStatus != .authorized && settings.authorizationStatus != .provisional {
            return false
        }

        let content = UNMutableNotificationContent()
        content.title = "DiskSwell detected \(anomaly.reason.lowercased())"
        let name = PathRules.safeDisplayName(anomaly.path)
        let growth = anomaly.growth > 0 ? "\nGrowth: +\(Self.bytes(anomaly.growth)) in \(Self.duration(anomaly.interval))" : ""
        let count = anomaly.itemCountGrowth > 0 ? "\nFiles: +\(anomaly.itemCountGrowth.formatted())" : ""
        let sizeLabel = anomaly.isApproximate ? "Estimated size" : "Current size"
        content.body = "\(anomaly.source.label)\n\(name)\n\(sizeLabel): \(Self.bytes(anomaly.currentSize))\(growth)\(count)"
        content.categoryIdentifier = Self.categoryIdentifier
        content.userInfo = ["path": anomaly.path]
        let identifier = "anomaly-\(anomaly.path.hashValue)"
        try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        identifiers.removeAll(where: { $0 == identifier })
        identifiers.append(identifier)
        if identifiers.count > capacity {
            let removed = Array(identifiers.prefix(identifiers.count - capacity))
            identifiers.removeFirst(removed.count)
            center.removeDeliveredNotifications(withIdentifiers: removed)
        }
        return true
    }

    private static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private static func duration(_ interval: TimeInterval) -> String {
        if interval >= 24 * 60 * 60 { return "\(Int(interval / (24 * 60 * 60))) days" }
        if interval >= 60 * 60 { return "\(Int(interval / (60 * 60))) hours" }
        return interval < 60 ? "\(Int(interval)) sec" : "\(Int(interval / 60)) min"
    }
}
