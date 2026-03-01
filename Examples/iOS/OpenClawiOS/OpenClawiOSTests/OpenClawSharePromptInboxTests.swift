import XCTest
@testable import OpenClawiOS

@MainActor
final class OpenClawSharePromptInboxTests: XCTestCase {
    private func makeUserDefaults() -> UserDefaults {
        let suiteName = "io.marcodotio.openclaw.shareinbox.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Unable to create test suite defaults")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    func testEnqueueThenDequeueRoundTrip() {
        let defaults = self.makeUserDefaults()
        SharePromptInbox.enqueue(prompt: "Summarize this article.", userDefaults: defaults)

        let dequeued = SharePromptInbox.dequeue(userDefaults: defaults)
        XCTAssertEqual(dequeued?.prompt, "Summarize this article.")
        XCTAssertNil(SharePromptInbox.dequeue(userDefaults: defaults))
    }

    func testBlankPromptIsNotEnqueued() {
        let defaults = self.makeUserDefaults()
        SharePromptInbox.enqueue(prompt: "   ", userDefaults: defaults)

        XCTAssertNil(SharePromptInbox.dequeue(userDefaults: defaults))
    }
}
