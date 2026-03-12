import Foundation
import Testing
@testable import OpenClawKit

@Suite("Agent runtime")
struct AgentRuntimeTests {
    struct EchoTool: AgentTool {
        let name = "echo"

        func execute(arguments: [String: AnyCodable]) async throws -> AnyCodable {
            arguments["text"] ?? AnyCodable("")
        }
    }

    struct SlowTool: AgentTool {
        let name = "slow"

        func execute(arguments _: [String: AnyCodable]) async throws -> AnyCodable {
            try await Task.sleep(nanoseconds: 300_000_000)
            return AnyCodable("done")
        }
    }

    struct StreamingProvider: ModelProvider {
        let id = "streaming-provider"

        func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
            ModelGenerationResponse(text: "fallback-\(request.prompt)", providerID: self.id, modelID: "streaming")
        }

        func generateStream(_ request: ModelGenerationRequest) async -> AsyncThrowingStream<ModelStreamChunk, Error> {
            _ = request
            return AsyncThrowingStream { continuation in
                continuation.yield(ModelStreamChunk(text: "stream-", isFinal: false))
                continuation.yield(ModelStreamChunk(text: "output", isFinal: false))
                continuation.yield(ModelStreamChunk(text: "", isFinal: true))
                continuation.finish()
            }
        }
    }

    struct PromptEchoProvider: ModelProvider {
        let id = "prompt-echo"

        func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
            ModelGenerationResponse(text: request.prompt, providerID: self.id, modelID: "echo")
        }
    }

    actor InspectingProvider: ModelProvider {
        let id = "inspecting-provider"
        private(set) var lastRequest: ModelGenerationRequest?

        func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
            self.lastRequest = request
            return ModelGenerationResponse(text: "ok", providerID: self.id, modelID: request.modelID ?? "default")
        }

        func snapshot() -> ModelGenerationRequest? {
            self.lastRequest
        }
    }

    @Test
    func toolCallsExecuteInRunLifecycle() async throws {
        let runtime = EmbeddedAgentRuntime()
        await runtime.registerTool(EchoTool())
        let result = try await runtime.run(
            AgentRunRequest(
                runID: "run-b",
                sessionKey: "main",
                prompt: "use tool",
                toolCalls: [AgentToolCall(name: "echo", arguments: ["text": AnyCodable("hello")])]
            )
        )

        #expect(result.toolResults.count == 1)
        #expect(result.events.first?.kind == .runStarted)
        #expect(result.events.last?.kind == .runCompleted)
    }

    @Test
    func runTimesOutWhenToolIsSlow() async throws {
        let runtime = EmbeddedAgentRuntime()
        await runtime.registerTool(SlowTool())

        do {
            _ = try await runtime.run(
                AgentRunRequest(
                    runID: "run-timeout",
                    sessionKey: "main",
                    prompt: "slow",
                    toolCalls: [AgentToolCall(name: "slow")]
                ),
                timeoutMs: 50
            )
            Issue.record("Expected timeout")
        } catch {
            #expect(String(describing: error).lowercased().contains("timed"))
        }
    }

    @Test
    func runtimePublishesFailureDiagnosticsOnTimeout() async throws {
        let pipeline = RuntimeDiagnosticsPipeline(eventLimit: 50)
        let runtime = EmbeddedAgentRuntime(diagnosticsSink: await pipeline.sink())
        await runtime.registerTool(SlowTool())

        do {
            _ = try await runtime.run(
                AgentRunRequest(
                    runID: "run-timeout-diagnostics",
                    sessionKey: "main",
                    prompt: "slow",
                    toolCalls: [AgentToolCall(name: "slow")],
                    modelProviderID: "openai"
                ),
                timeoutMs: 50
            )
            Issue.record("Expected timeout")
        } catch {
            #expect(String(describing: error).lowercased().contains("timed"))
        }

        let snapshot = await pipeline.usageSnapshot()
        #expect(snapshot.runsStarted == 1)
        #expect(snapshot.runsFailed == 1)
        #expect(snapshot.runsTimedOut == 1)
        #expect(snapshot.modelFailures == 1)
        let events = await pipeline.recentEvents(limit: 10)
        #expect(events.contains(where: { $0.name == "run.failed" && $0.metadata["timedOut"] == "true" }))
        #expect(events.contains(where: { $0.name == "model.call.failed" && $0.metadata["timedOut"] == "true" }))
        #expect(events.contains(where: { $0.name == "model.call.failed" && $0.metadata["providerID"] == "openai" }))
    }

    @Test
    func runStreamEmitsChunksAndFinalMarker() async throws {
        let router = ModelRouter()
        await router.register(StreamingProvider())
        let runtime = EmbeddedAgentRuntime(modelRouter: router)
        try await runtime.setDefaultModelProviderID("streaming-provider")

        let stream = await runtime.runStream(
            AgentRunRequest(
                runID: "run-stream",
                sessionKey: "session-stream",
                prompt: "stream me"
            )
        )

        var chunks: [AgentRunStreamChunk] = []
        for try await chunk in stream {
            chunks.append(chunk)
        }

        #expect(chunks.count == 3)
        #expect(chunks.dropLast().map(\.text).joined() == "stream-output")
        #expect(chunks.last?.isFinal == true)
        #expect(chunks.last?.runID == "run-stream")
        #expect(chunks.last?.sessionKey == "session-stream")
    }

    @Test
    func runNormalizesAttachmentsAndInjectsAttachmentContext() async throws {
        let router = ModelRouter()
        await router.register(PromptEchoProvider())
        let runtime = EmbeddedAgentRuntime(
            modelRouter: router,
            mediaPipeline: MediaPipeline(maxBytes: 1_024 * 1_024)
        )
        try await runtime.setDefaultModelProviderID("prompt-echo")

        let result = try await runtime.run(
            AgentRunRequest(
                runID: "run-attachments",
                sessionKey: "session-attachments",
                prompt: "describe this image",
                attachments: [
                    MediaAttachment(
                        id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
                        mimeType: "image/png",
                        data: Data([1, 2, 3, 4]),
                        fileName: "photo.png"
                    ),
                ]
            )
        )

        let normalized = try #require(result.attachments.first)
        #expect(result.attachments.count == 1)
        #expect(normalized.metadata["kind"] == "image")
        #expect(normalized.metadata["bytes"] == "4")
        #expect(result.output.contains("## Attachments"))
        #expect(result.output.contains("photo.png"))
        #expect(result.output.contains("image/png"))
        #expect(result.output.contains("## User Request"))
        #expect(result.output.contains("describe this image"))
    }

    @Test
    func runFailsWhenAttachmentExceedsConfiguredMaxBytes() async throws {
        let runtime = EmbeddedAgentRuntime(mediaPipeline: MediaPipeline(maxBytes: 2))

        do {
            _ = try await runtime.run(
                AgentRunRequest(
                    runID: "run-attachment-too-large",
                    sessionKey: "session-attachments",
                    prompt: "analyze attachment",
                    attachments: [
                        MediaAttachment(
                            mimeType: "application/octet-stream",
                            data: Data(repeating: 0x01, count: 2_048)
                        )
                    ]
                )
            )
            Issue.record("Expected attachment size validation failure")
        } catch {
            #expect(String(describing: error).contains("maximum supported size"))
        }
    }

    @Test
    func runThreadsSessionThinkingAndModelOverridesIntoGenerationRequest() async throws {
        let router = ModelRouter()
        let provider = InspectingProvider()
        await router.register(provider)
        let runtime = EmbeddedAgentRuntime(modelRouter: router)
        try await runtime.setDefaultModelProviderID("inspecting-provider")

        _ = try await runtime.run(
            AgentRunRequest(
                runID: "run-controls",
                sessionKey: "session-controls",
                prompt: "hello",
                modelProviderID: "openai-codex",
                modelID: "gpt-5.3-codex",
                thinkingLevel: .xhigh,
                reasoningLevel: .stream,
                verboseLevel: .full,
                responseUsage: .full,
                elevatedLevel: .ask
            )
        )

        let request = try #require(await provider.snapshot())
        #expect(request.providerID == "openai-codex")
        #expect(request.modelID == "gpt-5.3-codex")
        #expect(request.policy.thinkingLevel == .xhigh)
        #expect(request.policy.reasoningLevel == .stream)
        #expect(request.policy.verboseLevel == .full)
        #expect(request.policy.responseUsage == .full)
        #expect(request.policy.elevatedLevel == .ask)
        #expect(request.policy.reasoningEffort == .high)
        #expect(request.metadata["thinkingLevel"] == "xhigh")
        #expect(request.metadata["reasoningLevel"] == "stream")
        #expect(request.metadata["verboseLevel"] == "full")
    }

    @Test
    func runMapsReasoningEffortAcrossThinkingLevels() async throws {
        let router = ModelRouter()
        let provider = InspectingProvider()
        await router.register(provider)
        let runtime = EmbeddedAgentRuntime(modelRouter: router)
        try await runtime.setDefaultModelProviderID("inspecting-provider")

        func capturedRequest(
            thinkingLevel: ThinkLevel?,
            reasoningLevel: ReasoningLevel?
        ) async throws -> ModelGenerationRequest {
            _ = try await runtime.run(
                AgentRunRequest(
                    runID: UUID().uuidString,
                    sessionKey: "session-controls",
                    prompt: "hello",
                    modelProviderID: "openai-codex",
                    thinkingLevel: thinkingLevel,
                    reasoningLevel: reasoningLevel
                )
            )
            return try #require(await provider.snapshot())
        }

        let low = try await capturedRequest(thinkingLevel: .minimal, reasoningLevel: .stream)
        #expect(low.policy.reasoningEffort == .low)

        let medium = try await capturedRequest(thinkingLevel: .medium, reasoningLevel: .on)
        #expect(medium.policy.reasoningEffort == .medium)

        let disabled = try await capturedRequest(thinkingLevel: .xhigh, reasoningLevel: .off)
        #expect(disabled.policy.reasoningEffort == nil)
        #expect(disabled.metadata["thinkingLevel"] == "xhigh")
        #expect(disabled.metadata["reasoningLevel"] == "off")

        let implicit = try await capturedRequest(thinkingLevel: nil, reasoningLevel: nil)
        #expect(implicit.policy.reasoningEffort == nil)
        #expect(implicit.metadata.isEmpty)
    }

}
