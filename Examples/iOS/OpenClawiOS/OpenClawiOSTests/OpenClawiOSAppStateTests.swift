import XCTest
@testable import OpenClawiOS

@MainActor
final class OpenClawiOSAppStateTests: XCTestCase {
    actor TickProbe {
        private(set) var count = 0
        func increment() { self.count += 1 }
    }

    func testInitialDeploymentStateIsStopped() {
        let state = OpenClawAppState()

        XCTAssertEqual(state.deploymentState, .stopped)
        XCTAssertEqual(state.statusText, "Not deployed")
        XCTAssertFalse(state.isDeployed)
        XCTAssertEqual(state.liveActivityStatusText, "Idle")
    }

    func testDefaultProviderSelectionAndModelSuggestion() {
        let state = OpenClawAppState()

        XCTAssertEqual(state.selectedProvider, .openAI)
        XCTAssertEqual(state.selectedModelID, OpenClawAppState.DeployProvider.openAI.defaultModelID)
        XCTAssertEqual(state.availableProviders.count, OpenClawAppState.DeployProvider.allCases.count)
    }

    func testAttachmentStagingAndRemovalLifecycle() {
        let state = OpenClawAppState()

        let staged = state.stageAttachment(
            data: Data([1, 2, 3, 4]),
            mimeType: "image/png",
            fileName: "sample.png"
        )
        XCTAssertTrue(staged)
        XCTAssertEqual(state.pendingAttachments.count, 1)
        XCTAssertTrue(state.hasPendingAttachments)
        XCTAssertEqual(state.pendingAttachments.first?.fileName, "sample.png")
        XCTAssertEqual(state.pendingAttachments.first?.mimeType, "image/png")

        if let id = state.pendingAttachments.first?.id {
            state.removePendingAttachment(id: id)
        }
        XCTAssertEqual(state.pendingAttachments.count, 0)
        XCTAssertFalse(state.hasPendingAttachments)
    }

    func testAttachmentStagingRejectsOversizedPayload() {
        let state = OpenClawAppState()
        let oversized = Data(repeating: 0x01, count: (10 * 1024 * 1024) + 1)

        let staged = state.stageAttachment(
            data: oversized,
            mimeType: "application/octet-stream",
            fileName: "oversized.bin"
        )
        XCTAssertFalse(staged)
        XCTAssertTrue(state.pendingAttachments.isEmpty)
    }

    func testPersistedSettingsRoundTripTelegramChatIDWithoutPlaintextToken() throws {
        let settings = OpenClawAppState.PersistedSettings(
            discordChannelID: "discord-channel",
            openAICompatibleBaseURL: "https://api.openai.com/v1",
            selectedProvider: .openAI,
            selectedModelID: "gpt-4.1-mini",
            localRuntime: "llmfarm",
            localModelPath: "",
            localFallbackModelPaths: "",
            localContextWindow: 4096,
            localTemperature: 0.7,
            localTopP: 0.95,
            localTopK: 40,
            localMaxTokens: 512,
            localUseMetal: true,
            localStreamTokens: true,
            localAllowCancellation: true,
            localRequestTimeoutMs: 60_000,
            defaultAgentID: "main",
            discordAgentID: "",
            webchatAgentID: "",
            personality: "",
            telegramBotToken: "telegram-secret",
            telegramChatID: "100200300"
        )

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(OpenClawAppState.PersistedSettings.self, from: data)
        let encodedString = String(decoding: data, as: UTF8.self)

        XCTAssertEqual(decoded.telegramChatID, "100200300")
        XCTAssertFalse(encodedString.contains("telegramBotToken"))
    }

    func testPersistedSettingsDecodesLegacyTelegramToken() throws {
        let legacy = """
        {
          "telegramBotToken": "legacy-token",
          "telegramChatID": "42"
        }
        """
        let decoded = try JSONDecoder().decode(
            OpenClawAppState.PersistedSettings.self,
            from: Data(legacy.utf8)
        )

        XCTAssertEqual(decoded.telegramBotToken, "legacy-token")
        XCTAssertEqual(decoded.telegramChatID, "42")
    }

    func testIntentBridgeReturnsNotReadyWhenAppStateIsUnbound() async {
        let bridge = OpenClawIntentBridge.shared
        bridge.unbindForTesting()

        let status = await bridge.deployFromIntent()
        XCTAssertTrue(status.contains("not ready"))
    }

    func testIntentBridgeRejectsEmptyQuickAskPrompt() async {
        let bridge = OpenClawIntentBridge.shared
        let state = OpenClawAppState()
        bridge.bind(state)

        let status = await bridge.quickAskFromIntent("   ")
        XCTAssertEqual(status, "Prompt is empty.")

        bridge.unbindForTesting()
    }

    func testIntentBridgePreviewReturnsNotReadyWhenUnbound() async {
        let bridge = OpenClawIntentBridge.shared
        bridge.unbindForTesting()

        let summary = await bridge.previewIntentGraphFromIntent("hello")
        XCTAssertTrue(summary.contains("not ready"))
    }

    func testIntentGraphNodeKindQueryReturnsKnownEntities() async throws {
        let query = IntentGraphNodeKindEntityQuery()
        let entities = try await query.suggestedEntities()
        let ids = Set(entities.map(\.id))

        XCTAssertTrue(ids.contains("run"))
        XCTAssertTrue(ids.contains("model"))
        XCTAssertTrue(ids.contains("output"))
    }

    func testBackgroundManagerRunsAutomationTickHook() async {
        let manager = BackgroundContinuationManager.shared
        let probe = TickProbe()
        manager.bindAutomationTickHandler {
            await probe.increment()
        }

        await manager.runAutomationTickForTesting()
        let count = await probe.count
        XCTAssertEqual(count, 1)

        manager.bindAutomationTickHandler(nil)
    }
}
