import Foundation
import Testing
@testable import OpenClawCore
@testable import OpenClawProtocol

@Suite("Control-plane parity fixtures")
struct ControlPlaneParityFixtureTests {
    @Test
    func agentDefaultsFixtureDecodesIntoCanonicalSessionControls() throws {
        let config = try JSONDecoder().decode(
            OpenClawConfig.self,
            from: Data(ControlPlaneParityFixtures.agentDefaultsConfigJSON.utf8)
        )

        #expect(config.agents.defaultAgentID == "ops")
        #expect(config.agents.workspaceRoot == "./workspace-ops")
        #expect(config.agents.thinkingLevel == .adaptive)
        #expect(config.agents.verboseLevel == .full)
        #expect(config.agents.reasoningLevel == .stream)
        #expect(config.agents.responseUsage == .tokens)
        #expect(config.agents.elevatedLevel == .ask)
        #expect(config.agents.groupActivation == .always)
        #expect(config.agents.groupActivationNeedsSystemIntro == true)
        #expect(config.agents.sendPolicy == .allow)
        #expect(config.agents.modelOverride == "openai/gpt-5.4")
        #expect(config.agents.execHost == .node)
        #expect(config.agents.execSecurity == .allowlist)
        #expect(config.agents.execAsk == .onMiss)
        #expect(config.agents.execNode == "node20")
    }

    @Test
    func gatewayRequestFixturesDecodeIntoTypedPayloads() throws {
        let patchFrame = try JSONDecoder().decode(
            GatewayFrame.self,
            from: Data(ControlPlaneParityFixtures.sessionPatchRequestJSON.utf8)
        )
        let browserFrame = try JSONDecoder().decode(
            GatewayFrame.self,
            from: Data(ControlPlaneParityFixtures.browserRequestJSON.utf8)
        )

        let patchRequest = try #require(self.requestFrame(from: patchFrame))
        #expect(patchRequest.method == "sessions.patch")
        let patchParams = try GatewayPayloadCodec.decode(GatewaySessionPatchParams.self, from: patchRequest.params)
        #expect(patchParams.key == "primary")
        #expect(patchParams.label == "Primary Ops Session")
        #expect(patchParams.modelOverride == "openai/gpt-5.4")
        #expect(patchParams.thinkingLevel == "adaptive")
        #expect(patchParams.reasoningLevel == "stream")
        #expect(patchParams.execAsk == "on-miss")

        let browserRequest = try #require(self.requestFrame(from: browserFrame))
        #expect(browserRequest.method == "browser.request")
        let browserParams = try GatewayPayloadCodec.decode(GatewayBrowserRequestParams.self, from: browserRequest.params)
        #expect(browserParams.method == "POST")
        #expect(browserParams.path == "/tabs")
        #expect(browserParams.query?["profile"] == "default")
        #expect(browserParams.timeoutMs == 3_000)
        #expect(browserParams.workspaceRoot == "/tmp/workspace")
        #expect(browserParams.spawnedWorkspaceRoot == "/tmp/workspace/spawned")
    }

    @Test
    func llmTaskFixtureAndThinkingAliasesStayLocalToSwiftTests() throws {
        let arguments = try JSONDecoder().decode(
            [String: AnyCodable].self,
            from: Data(ControlPlaneParityFixtures.llmTaskArgumentsJSON.utf8)
        )

        #expect(arguments["prompt"] == AnyCodable("Summarize the incident"))
        #expect(arguments["provider"] == AnyCodable("openai-codex"))
        #expect(arguments["model"] == AnyCodable("gpt-5.4"))
        #expect(arguments["thinking"] == AnyCodable("adaptive"))
        #expect(arguments["authProfileId"] == AnyCodable("work-profile"))
        #expect(arguments["timeoutMs"] == AnyCodable(2_500))

        for fixture in ControlPlaneParityFixtures.thinkingAliases {
            #expect(ThinkLevel.normalize(fixture.raw) == fixture.normalized)
        }
    }

    @Test
    func blueBubblesFixtureCapturesInboundChannelEdgeShape() throws {
        let payload = try #require(
            JSONSerialization.jsonObject(
                with: Data(ControlPlaneParityFixtures.blueBubblesWebhookJSON.utf8)
            ) as? [String: Any]
        )

        #expect(payload["chatGuid"] as? String == "iMessage;-;+15551234567")
        #expect(payload["from"] as? String == "+15557654321")
        #expect(payload["isFromMe"] as? Bool == false)
        let attachments = try #require(payload["attachments"] as? [[String: Any]])
        #expect(attachments.count == 1)
        #expect(attachments.first?["mimeType"] as? String == "image/png")
        #expect(attachments.first?["fileName"] as? String == "hello.png")
    }

    private func requestFrame(from frame: GatewayFrame) -> RequestFrame? {
        guard case let .req(request) = frame else { return nil }
        return request
    }
}
