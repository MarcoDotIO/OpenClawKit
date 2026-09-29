#if canImport(UserNotifications)
import Foundation
import Testing
import UserNotifications
@testable import OpenClawKit

private final class RecordingNotificationCenter: NotificationCentering, @unchecked Sendable {
    private let lock = NSLock()
    private var added: [String] = []
    let status: NotificationAuthorizationStatus

    init(status: NotificationAuthorizationStatus) {
        self.status = status
    }

    func authorizationStatus() async -> NotificationAuthorizationStatus {
        self.status
    }

    func add(_ request: UNNotificationRequest) async throws {
        try Task.checkCancellation()
        self.lock.withLock { self.added.append(request.identifier) }
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) async {}

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) async {}

    func deliveredNotifications() async -> [NotificationSnapshot] {
        self.lock.withLock { self.added }.map { NotificationSnapshot(identifier: $0, userInfo: ["source": "test"]) }
    }
}

struct OpenClawNotificationCenterTests {
    @Test func `authorization states map with unknown states denied`() {
        #expect(LiveNotificationCenter.map(.authorized) == .authorized)
        #expect(LiveNotificationCenter.map(.provisional) == .provisional)
        #expect(LiveNotificationCenter.map(.denied) == .denied)
        #expect(LiveNotificationCenter.map(.notDetermined) == .notDetermined)
        #expect(NotificationAuthorizationStatus.provisional.allowsPosting)
        #expect(NotificationAuthorizationStatus.ephemeral.allowsPosting)
        #expect(!NotificationAuthorizationStatus.denied.allowsPosting)
        #expect(!NotificationAuthorizationStatus.notDetermined.allowsPosting)
    }

    @Test func `notification centering can be faked for node handlers`() async throws {
        let center = RecordingNotificationCenter(status: .authorized)
        let params = OpenClawSystemNotifyParams(title: "Build", body: "Done", priority: .timeSensitive)
        let content = params.makeNotificationContent()
        try await center.add(UNNotificationRequest(identifier: "n-1", content: content, trigger: nil))
        let delivered = await center.deliveredNotifications()
        #expect(delivered.map(\.identifier) == ["n-1"])
        #expect(delivered.first?.userInfo["source"] as? String == "test")
        #expect(await center.authorizationStatus() == .authorized)
    }

    @Test func `system notify params map to notification content`() {
        let passive = OpenClawSystemNotifyParams(title: "T", body: "B", sound: "none", priority: .passive)
            .makeNotificationContent()
        #expect(passive.title == "T")
        #expect(passive.body == "B")
        #expect(passive.sound == nil)
        #expect(passive.interruptionLevel == .passive)

        let urgent = OpenClawSystemNotifyParams(title: "T", body: "B", priority: .timeSensitive)
            .makeNotificationContent()
        #expect(urgent.sound != nil)
        #expect(urgent.interruptionLevel == .timeSensitive)
        #expect(OpenClawSystemNotifyParams(title: "", body: "").makeNotificationContent().interruptionLevel == .active)
    }
}
#endif
