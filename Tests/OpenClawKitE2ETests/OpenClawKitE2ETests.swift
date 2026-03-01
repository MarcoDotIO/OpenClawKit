import Foundation
import Testing
@testable import OpenClawKit

@Suite("OpenClawKit E2E")
struct OpenClawKitE2ETests {
    struct StaticProvider: ModelProvider {
        let id: String
        let text: String

        func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
            _ = request
            return ModelGenerationResponse(text: self.text, providerID: self.id, modelID: "static")
        }
    }

    @Test
    func embeddedAgentRuntimeRoundTrip() async throws {
        let gateway = GatewayClient()
        try await gateway.connect(to: GatewayEndpoint(url: URL(string: "ws://127.0.0.1:18789")!))

        let runtime = EmbeddedAgentRuntime(gatewayClient: gateway)
        let result = try await runtime.run(AgentRunRequest(sessionKey: "main", prompt: "ping"))
        #expect(result.sessionKey == "main")
        #expect(result.output == "OK")

        await gateway.disconnect()
    }

    @Test
    func adaptiveRouterUsesDiagnosticsFeedbackLoop() async throws {
        let sdk = OpenClawSDK.shared
        let diagnostics = RuntimeDiagnosticsPipeline(eventLimit: 200)
        let router = ModelRouter(
            defaultProviderID: "alpha",
            providers: [
                StaticProvider(id: "alpha", text: "alpha-output"),
                StaticProvider(id: "beta", text: "beta-output"),
            ],
            adaptiveRoutingConfig: AdaptiveRoutingConfig(
                enabled: true,
                minSamplesPerProvider: 1,
                explorationRate: 0,
                decisionWindow: 100,
                objective: .balanced
            )
        )

        for _ in 0..<3 {
            await diagnostics.record(
                RuntimeDiagnosticEvent(
                    subsystem: "runtime",
                    name: "model.call.failed",
                    metadata: [
                        "providerID": "alpha",
                        "modelID": "alpha-model",
                    ]
                )
            )
            await diagnostics.record(
                RuntimeDiagnosticEvent(
                    subsystem: "runtime",
                    name: "model.call.completed",
                    metadata: [
                        "providerID": "beta",
                        "modelID": "beta-model",
                        "latencyMs": "12",
                    ]
                )
            )
        }

        let optimized = await sdk.optimizeModelRouter(router, using: diagnostics)
        #expect(optimized?.providers.isEmpty == false)
        let response = try await router.generate(
            ModelGenerationRequest(
                sessionKey: "main",
                prompt: "optimize route",
                metadata: ["fallbackProviderIDs": "alpha,beta"]
            )
        )
        #expect(response.providerID == "beta")
    }
}

