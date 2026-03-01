import XCTest
@testable import OpenClawiOS

@MainActor
final class OpenClawIntentBridgeTests: XCTestCase {
    func testQuickAskReturnsNotReadyWhenUnbound() async {
        let bridge = OpenClawIntentBridge.shared
        bridge.unbindForTesting()

        let response = await bridge.quickAskFromIntent("hello")
        XCTAssertEqual(response, "OpenClaw is not ready yet. Open the app and try again.")
    }

    func testPreviewReturnsNotReadyWhenUnbound() async {
        let bridge = OpenClawIntentBridge.shared
        bridge.unbindForTesting()

        let response = await bridge.previewIntentGraphFromIntent("hello")
        XCTAssertEqual(response, "OpenClaw is not ready yet. Open the app and try again.")
    }

    func testIntentGraphNodeKindQueryReturnsExpectedEntities() async throws {
        let query = IntentGraphNodeKindEntityQuery()
        let entities = try await query.suggestedEntities()
        let ids = Set(entities.map(\.id))
        XCTAssertTrue(ids.contains("run"))
        XCTAssertTrue(ids.contains("prompt"))
        XCTAssertTrue(ids.contains("tool"))
    }
}
