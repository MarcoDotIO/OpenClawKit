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

}

