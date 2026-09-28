#if canImport(UserNotifications)
import Foundation
import UserNotifications

/// Delivered-notification snapshot returned by ``NotificationCentering/deliveredNotifications()``.
public struct NotificationSnapshot: @unchecked Sendable {
    /// Notification request identifier.
    public let identifier: String
    /// Notification `userInfo` payload.
    public let userInfo: [AnyHashable: Any]

    /// Creates a snapshot.
    public init(identifier: String, userInfo: [AnyHashable: Any]) {
        self.identifier = identifier
        self.userInfo = userInfo
    }
}

/// Notification authorization state, independent of the platform's `UNAuthorizationStatus` cases.
public enum NotificationAuthorizationStatus: Sendable {
    /// The user has not been asked yet.
    case notDetermined
    /// The user denied notifications (unknown future states map here too).
    case denied
    /// Notifications are authorized.
    case authorized
    /// Provisional (quiet) authorization.
    case provisional
    /// Ephemeral authorization (App Clips; iOS and visionOS only).
    case ephemeral

    /// Whether notifications can be posted (authorized, provisional or ephemeral).
    public var allowsPosting: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral: true
        case .notDetermined, .denied: false
        }
    }
}

/// Abstraction over `UNUserNotificationCenter` used by `system.notify`, `chat.push` and `watch.notify`
/// handlers, so tests can fake it and cancelled invokes can be fenced before enqueueing.
public protocol NotificationCentering: Sendable {
    /// Current authorization state.
    func authorizationStatus() async -> NotificationAuthorizationStatus
    /// Enqueues a notification request; throws `CancellationError` if the caller was cancelled.
    func add(_ request: UNNotificationRequest) async throws
    /// Removes pending requests; empty lists are ignored.
    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) async
    /// Removes delivered notifications; empty lists are ignored (no-op on tvOS).
    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) async
    /// Currently delivered notifications (always empty on tvOS).
    func deliveredNotifications() async -> [NotificationSnapshot]
}

/// ``NotificationCentering`` backed by `UNUserNotificationCenter`.
public struct LiveNotificationCenter: NotificationCentering, @unchecked Sendable {
    private let center: UNUserNotificationCenter

    /// Wraps a notification center (the app's current center by default).
    public init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    /// Reads the current authorization status.
    public func authorizationStatus() async -> NotificationAuthorizationStatus {
        let settings = await self.center.notificationSettings()
        return Self.map(settings.authorizationStatus)
    }

    static func map(_ status: UNAuthorizationStatus) -> NotificationAuthorizationStatus {
        switch status {
        case .authorized:
            return .authorized
        case .provisional:
            return .provisional
        #if os(iOS) || os(visionOS)
        case .ephemeral:
            return .ephemeral
        #endif
        case .denied:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .denied
        }
    }

    /// Enqueues a request unless the calling task was already cancelled.
    public func add(_ request: UNNotificationRequest) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            // Permission reads do not cancel with their caller; retire its effect before enqueueing.
            guard !Task.isCancelled else {
                cont.resume(throwing: CancellationError())
                return
            }
            self.center.add(request) { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume(returning: ())
                }
            }
        }
    }

    /// Removes pending requests with the given identifiers.
    public func removePendingNotificationRequests(withIdentifiers identifiers: [String]) async {
        guard !identifiers.isEmpty else { return }
        self.center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    /// Removes delivered notifications with the given identifiers (no-op on tvOS).
    public func removeDeliveredNotifications(withIdentifiers identifiers: [String]) async {
        guard !identifiers.isEmpty else { return }
        #if !os(tvOS)
        self.center.removeDeliveredNotifications(withIdentifiers: identifiers)
        #endif
    }

    /// Returns delivered notifications (empty on tvOS, where the API is unavailable).
    public func deliveredNotifications() async -> [NotificationSnapshot] {
        #if os(tvOS)
        return []
        #else
        return await withCheckedContinuation { continuation in
            self.center.getDeliveredNotifications { notifications in
                continuation.resume(
                    returning: notifications.map { notification in
                        NotificationSnapshot(
                            identifier: notification.request.identifier,
                            userInfo: notification.request.content.userInfo)
                    })
            }
        }
        #endif
    }
}

#if !os(tvOS)
extension OpenClawSystemNotifyParams {
    /// Builds notification content for `system.notify`: title, body, the default sound unless
    /// `sound` is `"none"`/empty, and an interruption level from ``priority``.
    ///
    /// Unavailable on tvOS, where notification titles and bodies cannot be displayed.
    public func makeNotificationContent() -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = self.title
        content.body = self.body
        let sound = self.sound?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if sound != "none", sound != "" {
            content.sound = .default
        }
        switch self.priority {
        case .passive:
            content.interruptionLevel = .passive
        case .timeSensitive:
            content.interruptionLevel = .timeSensitive
        case .active, nil:
            content.interruptionLevel = .active
        }
        return content
    }
}
#endif
#endif
