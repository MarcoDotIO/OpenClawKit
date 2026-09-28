import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Handles the direct Watch node's fixed command surface for ``OpenClawWatchNodeClient``.
public protocol OpenClawWatchNodeCommandHandling: Sendable {
    /// Whether local notifications may be posted; declared as the `notifications` permission on connect.
    func notificationsAuthorized() async -> Bool
    /// Handles one invoke; must always return a response (errors become `ok: false` responses).
    func handle(_ request: BridgeInvokeRequest) async -> BridgeInvokeResponse
}

/// Posts local notifications for `system.notify` on a direct Watch node.
public protocol OpenClawWatchNodeNotifying: Sendable {
    /// Whether notifications may be posted (authorized or provisional).
    func allowsPosting() async -> Bool
    /// Posts a notification immediately.
    func post(title: String, body: String, priority: OpenClawNotificationPriority, playsSound: Bool) async throws
}

/// Default ``OpenClawWatchNodeCommandHandling``: `device.info`, `device.status`, and `system.notify`.
///
/// Other commands return `INVALID_REQUEST: unsupported watchOS command`; the Gateway never routes them to
/// a direct Watch node, which may not declare them. Provider failures return `UNAVAILABLE`.
public struct OpenClawWatchNodeCommandRouter: OpenClawWatchNodeCommandHandling {
    private let deviceInfo: @Sendable () async throws -> OpenClawDeviceInfoPayload
    private let deviceStatus: @Sendable () async throws -> OpenClawDeviceStatusPayload
    private let notifier: any OpenClawWatchNodeNotifying

    /// Creates a router from device providers and a notifier.
    public init(
        deviceInfo: @escaping @Sendable () async throws -> OpenClawDeviceInfoPayload,
        deviceStatus: @escaping @Sendable () async throws -> OpenClawDeviceStatusPayload,
        notifier: any OpenClawWatchNodeNotifying)
    {
        self.deviceInfo = deviceInfo
        self.deviceStatus = deviceStatus
        self.notifier = notifier
    }

    /// Whether the notifier may post.
    public func notificationsAuthorized() async -> Bool {
        await self.notifier.allowsPosting()
    }

    /// Dispatches one invoke.
    public func handle(_ request: BridgeInvokeRequest) async -> BridgeInvokeResponse {
        do {
            switch request.command {
            case OpenClawDeviceCommand.info.rawValue:
                return try Self.encodedResponse(id: request.id, payload: await self.deviceInfo())
            case OpenClawDeviceCommand.status.rawValue:
                return try Self.encodedResponse(id: request.id, payload: await self.deviceStatus())
            case OpenClawSystemCommand.notify.rawValue:
                return try await self.handleNotification(request)
            default:
                return Self.errorResponse(
                    id: request.id,
                    code: .invalidRequest,
                    message: "INVALID_REQUEST: unsupported watchOS command")
            }
        } catch {
            return Self.errorResponse(id: request.id, code: .unavailable, message: error.localizedDescription)
        }
    }

    private func handleNotification(_ request: BridgeInvokeRequest) async throws -> BridgeInvokeResponse {
        let params = try JSONDecoder().decode(
            OpenClawSystemNotifyParams.self,
            from: Data((request.paramsJSON ?? "{}").utf8))
        let title = params.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = params.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty || !body.isEmpty else {
            return Self.errorResponse(id: request.id, code: .invalidRequest, message: "INVALID_REQUEST: empty notification")
        }
        guard await self.notifier.allowsPosting() else {
            return Self.errorResponse(id: request.id, code: .unavailable, message: "NOT_AUTHORIZED: notifications")
        }
        let sound = params.sound?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let silent = sound.map { ["none", "silent", "off"].contains($0) } == true
        try await self.notifier.post(
            title: title,
            body: body,
            priority: params.priority ?? .active,
            playsSound: !silent)
        return BridgeInvokeResponse(id: request.id, ok: true)
    }

    private static func encodedResponse(id: String, payload: some Encodable) throws -> BridgeInvokeResponse {
        let data = try JSONEncoder().encode(payload)
        guard let json = String(bytes: data, encoding: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        return BridgeInvokeResponse(id: id, ok: true, payloadJSON: json)
    }

    private static func errorResponse(
        id: String,
        code: OpenClawNodeErrorCode,
        message: String) -> BridgeInvokeResponse
    {
        BridgeInvokeResponse(id: id, ok: false, error: OpenClawNodeError(code: code, message: message))
    }
}

#if canImport(UserNotifications) && !os(tvOS)
/// ``OpenClawWatchNodeNotifying`` backed by a ``NotificationCentering`` (the app's
/// `UNUserNotificationCenter` by default). Unavailable on tvOS, which cannot show notification text.
public struct OpenClawWatchNodeUserNotifier: OpenClawWatchNodeNotifying {
    private let center: any NotificationCentering

    /// Creates a notifier.
    public init(center: any NotificationCentering = LiveNotificationCenter()) {
        self.center = center
    }

    /// Whether the center is authorized or provisional.
    public func allowsPosting() async -> Bool {
        let status = await self.center.authorizationStatus()
        return status == .authorized || status == .provisional
    }

    /// Posts an immediate notification with the priority's interruption level.
    public func post(title: String, body: String, priority: OpenClawNotificationPriority, playsSound: Bool) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        switch priority {
        case .passive:
            content.interruptionLevel = .passive
        case .timeSensitive:
            content.interruptionLevel = .timeSensitive
        case .active:
            content.interruptionLevel = .active
        }
        content.sound = playsSound ? .default : nil
        try await self.center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
#endif
