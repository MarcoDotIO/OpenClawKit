import Foundation
import Testing
@testable import OpenClawKit

@Suite("OpenClawSDK facade", .serialized)
struct OpenClawSDKFacadeTests {
    private struct StaticIntentProvider: ModelProvider {
        let id = "intent-static"

        func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
            ModelGenerationResponse(
                text: "intent:\(request.prompt)",
                providerID: self.id,
                modelID: "intent-model"
            )
        }
    }

    @Test
    func configFacadeRoundTrip() async throws {
        let sdk = OpenClawSDK.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclawkit-facade-config", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("openclaw.json", isDirectory: false)

        let config = OpenClawConfig(gateway: GatewayConfig(host: "127.0.0.1", port: 18888, authMode: "token"))
        try await sdk.saveConfig(config, to: path)
        let loaded = try await sdk.loadConfig(from: path)
        #expect(loaded.gateway.port == 18888)
    }

    @Test
    func commandAndBinaryFacadeFunctions() async throws {
        let sdk = OpenClawSDK.shared
        let result = try await sdk.runCommandWithTimeout(["/bin/echo", "ok"], timeoutMs: 5_000)
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("ok"))

        let binary = try sdk.ensureBinary("sh")
        #expect(binary.contains("sh"))
    }

    @Test
    func replyFacadeFlowReturnsOutboundMessage() async throws {
        let sdk = OpenClawSDK.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclawkit-facade-reply", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sessions = root.appendingPathComponent("sessions.json", isDirectory: false)
        let config = OpenClawConfig()

        let outbound = try await sdk.getReplyFromConfig(
            config: config,
            sessionStoreURL: sessions,
            inbound: InboundMessage(channel: .webchat, peerID: "u1", text: "hello")
        )
        #expect(outbound.text == "OK")
    }

    @Test
    func intentGraphFacadeBuildsGraphFromRunRequest() async throws {
        let sdk = OpenClawSDK.shared
        let request = AgentRunRequest(
            runID: "run-ig-1",
            sessionKey: "session-ig",
            prompt: "Summarize this note",
            toolCalls: [
                AgentToolCall(name: "calendar.lookup"),
                AgentToolCall(name: "contacts.lookup"),
            ],
            modelProviderID: "intent-static",
            workspaceRootPath: "/tmp/workspace"
        )

        let graph = await sdk.makeIntentGraph(for: request)
        let runNode = graph.nodes.first(where: { $0.kind == .run })
        let toolNodes = graph.nodes.filter { $0.kind == .tool }
        let invokesEdges = graph.edges.filter { $0.kind == .invokes }

        #expect(graph.runID == request.runID)
        #expect(graph.sessionKey == request.sessionKey)
        #expect(runNode?.metadata["requestedProviderID"] == "intent-static")
        #expect(toolNodes.count == 2)
        #expect(invokesEdges.count == 2)
    }

    @Test
    func intentGraphFacadeRunsAndReturnsGraphAndOutput() async throws {
        let sdk = OpenClawSDK.shared
        let runtime = EmbeddedAgentRuntime()
        await runtime.registerModelProvider(StaticIntentProvider())

        let request = AgentRunRequest(
            runID: "run-ig-2",
            sessionKey: "session-ig",
            prompt: "Generate an answer",
            modelProviderID: "intent-static"
        )

        let response = try await sdk.runIntentGraph(
            request,
            runtime: runtime,
            timeoutMs: 5_000
        )

        #expect(response.graph.runID == request.runID)
        #expect(response.result.runID == request.runID)
        #expect(response.result.output.contains("intent:"))
    }
}
