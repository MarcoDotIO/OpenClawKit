import Foundation
import Testing
import OpenClawAppIntents
import OpenClawKit

@Suite("App Intents embedded host")
struct OpenClawAppIntentsEmbeddedHostTests {
    struct ChunkProvider: ModelProvider {
        let id = "intent-stream"

        func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
            ModelGenerationResponse(text: "unused", providerID: self.id, modelID: "stream")
        }

        func generateStream(_ request: ModelGenerationRequest) async -> AsyncThrowingStream<ModelStreamChunk, Error> {
            AsyncThrowingStream { continuation in
                continuation.yield(ModelStreamChunk(text: "Hello ", isFinal: false))
                continuation.yield(ModelStreamChunk(text: "there", isFinal: false))
                continuation.yield(ModelStreamChunk(text: "", isFinal: true))
                continuation.finish()
            }
        }
    }

    private func makeHost() async throws -> EmbeddedOpenClawIntentHost {
        let router = ModelRouter()
        await router.register(ChunkProvider())
        let runtime = EmbeddedAgentRuntime(modelRouter: router)
        try await runtime.setDefaultModelProviderID("intent-stream")
        return EmbeddedOpenClawIntentHost(runtime: runtime, defaultSessionKey: "intents", usesLocalModels: true)
    }

    @Test
    func embeddedRunsStreamCumulativeText() async throws {
        let host = try await self.makeHost()
        var events: [OpenClawIntentRunEvent] = []
        for try await event in try await host.send(prompt: "hi", sessionKey: nil, agentId: nil) {
            events.append(event)
        }
        #expect(events.first?.phase == .running)
        #expect(events.last?.phase == .completed)
        #expect(events.last?.text == "Hello there")
        #expect(events.last?.fractionCompleted == 1)
        #expect(events.allSatisfy { $0.sessionKey == "intents" })
        #expect(host.prefersBackgroundGPU)

        let sessions = try await host.sessions(matching: "INT", limit: 5)
        #expect(sessions.map(\.sessionKey) == ["intents"])
        #expect(try await host.sessions(forKeys: ["intents", "other"]).map(\.title) == ["intents", "other"])
        #expect(try await host.agents().map(\.agentId) == ["main"])
        await #expect(throws: OpenClawIntentError.self) {
            try await host.startTalk(sessionKey: nil)
        }
        await #expect(throws: OpenClawIntentError.emptyPrompt) {
            _ = try await host.send(prompt: " ", sessionKey: nil, agentId: nil)
        }
    }

    @Test
    func actionsRunAgainstTheEmbeddedHost() async throws {
        let host = try await self.makeHost()
        let text = try await OpenClawIntentActions.ask(prompt: "hi", sessionKey: "s", host: host)
        #expect(text == "Hello there")
        await host.abort(sessionKey: "s")
    }
}
