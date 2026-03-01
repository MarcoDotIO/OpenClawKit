import XCTest
@testable import OpenClawiOS

@MainActor
final class OpenClawiOSAppStateTests: XCTestCase {
    func testInitialDeploymentStateIsStopped() {
        let state = OpenClawAppState()

        XCTAssertEqual(state.deploymentState, .stopped)
        XCTAssertEqual(state.statusText, "Not deployed")
        XCTAssertFalse(state.isDeployed)
    }

    func testDefaultProviderSelectionAndModelSuggestion() {
        let state = OpenClawAppState()

        XCTAssertEqual(state.selectedProvider, .openAI)
        XCTAssertEqual(state.selectedModelID, OpenClawAppState.DeployProvider.openAI.defaultModelID)
        XCTAssertEqual(state.availableProviders.count, OpenClawAppState.DeployProvider.allCases.count)
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
}
