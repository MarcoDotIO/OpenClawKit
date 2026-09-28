import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import OpenClawCore
import OpenClawModels
import OpenClawProtocol

/// Live end-to-end tests for xAI.
///
/// The catalog-configured provider (built by `ModelProviderFactory` from the bundled `xai` entry)
/// uses xAI's configured API, OpenAI Responses. The directly constructed `XAIModelProvider`
/// defaults to Chat Completions and gets a smaller smoke pass.
///
/// Disabled unless `OPENCLAW_LIVE_PROVIDER_TESTS=1` and `XAI_API_KEY` are set; see
/// `LiveProviderSupport.swift`.
@Suite(
    "Live provider: xAI",
    .serialized,
    .enabled(if: LiveProviderEnvironment.isEnabled(.xai), "needs OPENCLAW_LIVE_PROVIDER_TESTS=1 and XAI_API_KEY")
)
struct LiveProviderXAITests {
    private let model = LiveProviderEnvironment.model(.xai)

    private func makeProvider(apiKey: String? = nil) throws -> any ModelProvider {
        try LiveProviderConfigs.factoryProvider(.xai, apiKey: apiKey)
    }

    private func makeChatCompletionsProvider(apiKey: String? = LiveProviderEnvironment.apiKey(.xai)) -> XAIModelProvider {
        XAIModelProvider(
            configuration: ProviderServiceConfig(
                enabled: true,
                authMode: .apiKey,
                modelID: self.model,
                apiKey: apiKey,
                baseURL: "https://api.x.ai/v1"
            )
        )
    }

    private func policy(maxTokens: Int = LiveProviderFixtures.smallOutput, stream: Bool = false) -> ModelGenerationPolicy {
        ModelGenerationPolicy(streamTokens: stream, maxTokens: maxTokens)
    }

    @Test
    func factoryProviderUsesConfiguredResponsesAPI() throws {
        let config = try LiveProviderConfigs.catalogConfig(.xai)
        #expect(config.api == .openAIResponses)
        // The factory builds XAIModelProvider with the Responses engine for this config.
        #expect(try self.makeProvider() is XAIModelProvider)
    }

    @Test
    func parallelToolCallsAndImageInput() async throws {
        let request = ModelGenerationRequest(
            sessionKey: "live-xai-parallel",
            prompt: "",
            policy: self.policy(maxTokens: LiveProviderFixtures.toolOutput),
            messages: [.user(LiveProviderFixtures.parallelToolPrompt)],
            tools: [LiveProviderFixtures.addTool],
            toolChoice: .required
        )
        let capture = try await liveCollect(await self.makeProvider().generateStream(request))
        LiveUsageLedger.record("xai-responses.parallelTools.stream", model: self.model, usage: capture.usage)
        let final = try #require(capture.final)
        #expect(LiveProviderFixtures.isParallelAddPair(final.toolCalls), "streamed calls: \(final.toolCalls)")

        let image = try await liveCall {
            try await self.makeProvider().generate(
                ModelGenerationRequest(
                    sessionKey: "live-xai-image",
                    prompt: LiveProviderFixtures.colorPrompt,
                    policy: self.policy(),
                    attachments: [LiveProviderFixtures.redSquare]
                )
            )
        }
        LiveUsageLedger.record("xai-responses.image.attachments", model: image.modelID, usage: image.usage)
        #expect(image.text.lowercased().contains("red"), "answer: \(image.text)")
    }

    @Test
    func plainGenerateReportsUsageAndStopReason() async throws {
        let response = try await liveCall {
            try await self.makeProvider().generate(
                ModelGenerationRequest(
                    sessionKey: "live-xai",
                    prompt: LiveProviderFixtures.pongPrompt,
                    systemPrompt: "You are terse.",
                    policy: self.policy()
                )
            )
        }
        LiveUsageLedger.record("xai-responses.plainGenerate", model: response.modelID, usage: response.usage)
        #expect(response.text.lowercased().contains("pong"))
        #expect(response.stopReason == .stop)
        let usage = try #require(response.usage)
        #expect(usage.inputTokens > 0)
        #expect(usage.outputTokens > 0)
    }

    @Test
    func streamingAccumulatesTextAndReportsUsage() async throws {
        let capture = try await liveCollect(
            await self.makeProvider().generateStream(
                ModelGenerationRequest(
                    sessionKey: "live-xai",
                    prompt: "Count from 1 to 5 separated by spaces. Output only the numbers.",
                    policy: self.policy(stream: true)
                )
            )
        )
        LiveUsageLedger.record("xai-responses.streaming", model: self.model, usage: capture.usage)
        let final = try #require(capture.final)
        #expect(capture.textChunkCount >= 1)
        #expect(capture.text.contains("1 2 3 4 5"))
        #expect(final.stopReason == .stop)
        #expect(try #require(capture.usage).outputTokens > 0)
    }

    @Test
    func toolCallRoundTrip() async throws {
        let provider = try self.makeProvider()
        let user = ModelMessage.user(LiveProviderFixtures.toolPrompt)
        let first = try await liveCall {
            try await provider.generate(
                ModelGenerationRequest(
                    sessionKey: "live-xai-tools",
                    prompt: "",
                    systemPrompt: LiveProviderFixtures.toolSystemPrompt,
                    policy: self.policy(maxTokens: LiveProviderFixtures.toolOutput),
                    messages: [user],
                    tools: [LiveProviderFixtures.addTool],
                    toolChoice: .required
                )
            )
        }
        LiveUsageLedger.record("xai-responses.toolCall.turn1", model: first.modelID, usage: first.usage)
        #expect(first.stopReason == .toolUse)
        let call = try #require(first.toolCalls.first)
        #expect(call.name == "add_numbers")
        let arguments = try #require(LiveProviderFixtures.addArguments(call))
        #expect(arguments.a + arguments.b == 42)

        let second = try await liveCall {
            try await provider.generate(
                ModelGenerationRequest(
                    sessionKey: "live-xai-tools",
                    prompt: "",
                    systemPrompt: LiveProviderFixtures.toolSystemPrompt,
                    policy: self.policy(maxTokens: LiveProviderFixtures.toolOutput),
                    messages: [user, first.assistantMessage, .toolResult(LiveProviderFixtures.addResult(for: call))],
                    tools: [LiveProviderFixtures.addTool]
                )
            )
        }
        LiveUsageLedger.record("xai-responses.toolCall.turn2", model: second.modelID, usage: second.usage)
        #expect(second.toolCalls.isEmpty)
        #expect(second.stopReason == .stop)
        #expect(second.text.contains("42"))
    }

    @Test
    func streamingToolCallAssemblesArguments() async throws {
        let capture = try await liveCollect(
            await self.makeProvider().generateStream(
                ModelGenerationRequest(
                    sessionKey: "live-xai-tools",
                    prompt: "",
                    policy: self.policy(maxTokens: LiveProviderFixtures.toolOutput, stream: true),
                    messages: [.user(LiveProviderFixtures.toolPrompt)],
                    tools: [LiveProviderFixtures.addTool],
                    toolChoice: .required
                )
            )
        )
        LiveUsageLedger.record("xai-responses.streamingToolCall", model: self.model, usage: capture.usage)
        let final = try #require(capture.final)
        #expect(final.stopReason == .toolUse)
        let call = try #require(final.toolCalls.first)
        #expect(call.name == "add_numbers")
        let arguments = try #require(LiveProviderFixtures.addArguments(call))
        #expect(arguments.a + arguments.b == 42)
    }

    @Test
    func jsonSchemaStructuredOutputValidates() async throws {
        let response = try await liveCall {
            try await self.makeProvider().generate(
                ModelGenerationRequest(
                    sessionKey: "live-xai-json",
                    prompt: LiveProviderFixtures.cityPrompt,
                    policy: self.policy(maxTokens: LiveProviderFixtures.toolOutput),
                    responseFormat: LiveProviderFixtures.cityFormat
                )
            )
        }
        LiveUsageLedger.record("xai-responses.jsonSchema", model: response.modelID, usage: response.usage)
        #expect(response.stopReason == .stop)
        #expect(LiveProviderFixtures.validateCityJSON(response.text) != nil, "not schema-valid JSON: \(response.text)")
    }

    @Test
    func outputLimitMapsToLengthStopReason() async throws {
        let response = try await liveCall {
            try await self.makeProvider().generate(
                ModelGenerationRequest(
                    sessionKey: "live-xai",
                    prompt: "Write the numbers from 1 to 200 separated by commas.",
                    policy: self.policy(maxTokens: 16)
                )
            )
        }
        LiveUsageLedger.record("xai-responses.lengthStop", model: response.modelID, usage: response.usage)
        #expect(response.stopReason == .length)
        #expect(!response.text.isEmpty)
    }

    @Test
    func chatCompletionsPlainAndStreaming() async throws {
        let provider = self.makeChatCompletionsProvider()
        let response = try await liveCall {
            try await provider.generate(
                ModelGenerationRequest(sessionKey: "live-xai-chat", prompt: LiveProviderFixtures.pongPrompt, policy: self.policy())
            )
        }
        LiveUsageLedger.record("xai-chat.plainGenerate", model: response.modelID, usage: response.usage)
        #expect(response.text.lowercased().contains("pong"))
        #expect(response.stopReason == .stop)
        #expect(response.usage != nil)

        let capture = try await liveCollect(
            await provider.generateStream(
                ModelGenerationRequest(sessionKey: "live-xai-chat", prompt: LiveProviderFixtures.pongPrompt, policy: self.policy(stream: true))
            )
        )
        LiveUsageLedger.record("xai-chat.streaming", model: self.model, usage: capture.usage)
        #expect(capture.text.lowercased().contains("pong"))
        #expect(capture.final?.stopReason == .stop)
    }

    @Test
    func invalidKeyMapsToAuthenticationError() async throws {
        let responses = try self.makeProvider(apiKey: LiveProviderKind.xai.invalidKey)
        await expectAuthenticationFailure("xai-responses.generate") {
            _ = try await responses.generate(ModelGenerationRequest(sessionKey: "live-invalid", prompt: "hi", policy: self.policy()))
        }
        await expectAuthenticationFailure("xai-responses.stream") {
            for try await _ in await responses.generateStream(
                ModelGenerationRequest(sessionKey: "live-invalid", prompt: "hi", policy: self.policy(stream: true))
            ) {}
        }
        await expectAuthenticationFailure("xai-chat.generate") {
            _ = try await self.makeChatCompletionsProvider(apiKey: LiveProviderKind.xai.invalidKey)
                .generate(ModelGenerationRequest(sessionKey: "live-invalid", prompt: "hi", policy: self.policy()))
        }
    }
}
