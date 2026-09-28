import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import OpenClawCore
import OpenClawModels
import OpenClawProtocol

/// Live end-to-end tests for OpenAI Chat Completions (`OpenAIModelProvider`).
///
/// Disabled unless `OPENCLAW_LIVE_PROVIDER_TESTS=1` and `OPENAI_API_KEY` are set; see
/// `LiveProviderSupport.swift`.
@Suite(
    "Live provider: OpenAI Chat Completions",
    .serialized,
    .enabled(if: LiveProviderEnvironment.isEnabled(.openAI), "needs OPENCLAW_LIVE_PROVIDER_TESTS=1 and OPENAI_API_KEY")
)
struct LiveProviderOpenAIChatCompletionsTests {
    private let model = LiveProviderEnvironment.model(.openAI)

    private func configuration(apiKey: String?) -> OpenAIModelConfig {
        OpenAIModelConfig(enabled: true, modelID: self.model, apiKey: apiKey, baseURL: "https://api.openai.com/v1")
    }

    /// Provider on the contract-v2 Chat Completions engine (explicit transport).
    private func makeProvider(apiKey: String? = LiveProviderEnvironment.apiKey(.openAI)) -> OpenAIModelProvider {
        OpenAIModelProvider(configuration: self.configuration(apiKey: apiKey), transport: ModelStreamingHTTPClient())
    }

    /// Provider from the default public initializer (simple text requests go through OpenAIKit).
    private func makeDefaultProvider(apiKey: String? = LiveProviderEnvironment.apiKey(.openAI)) -> OpenAIModelProvider {
        OpenAIModelProvider(configuration: self.configuration(apiKey: apiKey))
    }

    private func policy(maxTokens: Int = LiveProviderFixtures.smallOutput, stream: Bool = false) -> ModelGenerationPolicy {
        ModelGenerationPolicy(streamTokens: stream, maxTokens: maxTokens, reasoningEffort: ModelReasoningEffort.none)
    }

    @Test
    func plainGenerateDefaultPath() async throws {
        let response = try await liveCall {
            try await self.makeDefaultProvider().generate(
                ModelGenerationRequest(sessionKey: "live-openai-chat", prompt: LiveProviderFixtures.pongPrompt)
            )
        }
        LiveUsageLedger.record("openai-chat.plainGenerateDefaultPath", model: response.modelID, usage: response.usage)
        #expect(response.text.lowercased().contains("pong"))
        #expect(response.stopReason == .stop)
        #expect(response.usage != nil)
    }

    @Test
    func plainGenerateReportsUsageAndStopReason() async throws {
        let response = try await liveCall {
            try await self.makeProvider().generate(
                ModelGenerationRequest(
                    sessionKey: "live-openai-chat",
                    prompt: LiveProviderFixtures.pongPrompt,
                    systemPrompt: "You are terse.",
                    policy: self.policy()
                )
            )
        }
        LiveUsageLedger.record("openai-chat.plainGenerate", model: response.modelID, usage: response.usage)
        #expect(response.text.lowercased().contains("pong"))
        #expect(response.stopReason == .stop)
        let usage = try #require(response.usage)
        #expect(usage.inputTokens > 0)
        #expect(usage.outputTokens > 0)
        #expect(usage.totalTokens >= usage.inputTokens + usage.outputTokens)
    }

    @Test
    func streamingAccumulatesTextAndReportsUsage() async throws {
        let capture = try await liveCollect(
            await self.makeProvider().generateStream(
                ModelGenerationRequest(
                    sessionKey: "live-openai-chat",
                    prompt: "Count from 1 to 5 separated by spaces. Output only the numbers.",
                    policy: self.policy(stream: true)
                )
            )
        )
        LiveUsageLedger.record("openai-chat.streaming", model: self.model, usage: capture.usage)
        let final = try #require(capture.final)
        #expect(capture.chunks.last?.isFinal == true)
        #expect(capture.textChunkCount >= 1)
        #expect(capture.text.contains("1 2 3 4 5"))
        #expect(final.stopReason == .stop)
        let usage = try #require(capture.usage, "stream_options.include_usage should report usage")
        #expect(usage.outputTokens > 0)
    }

    @Test
    func toolCallRoundTrip() async throws {
        let provider = self.makeProvider()
        let user = ModelMessage.user(LiveProviderFixtures.toolPrompt)
        let first = try await liveCall {
            try await provider.generate(
                ModelGenerationRequest(
                    sessionKey: "live-openai-chat-tools",
                    prompt: "",
                    systemPrompt: LiveProviderFixtures.toolSystemPrompt,
                    policy: self.policy(maxTokens: LiveProviderFixtures.toolOutput),
                    messages: [user],
                    tools: [LiveProviderFixtures.addTool],
                    toolChoice: .required
                )
            )
        }
        LiveUsageLedger.record("openai-chat.toolCall.turn1", model: first.modelID, usage: first.usage)
        #expect(first.stopReason == .toolUse)
        let call = try #require(first.toolCalls.first)
        #expect(call.name == "add_numbers")
        let arguments = try #require(LiveProviderFixtures.addArguments(call))
        #expect(arguments.a + arguments.b == 42)

        let second = try await liveCall {
            try await provider.generate(
                ModelGenerationRequest(
                    sessionKey: "live-openai-chat-tools",
                    prompt: "",
                    systemPrompt: LiveProviderFixtures.toolSystemPrompt,
                    policy: self.policy(maxTokens: LiveProviderFixtures.toolOutput),
                    messages: [user, first.assistantMessage, .toolResult(LiveProviderFixtures.addResult(for: call))],
                    tools: [LiveProviderFixtures.addTool]
                )
            )
        }
        LiveUsageLedger.record("openai-chat.toolCall.turn2", model: second.modelID, usage: second.usage)
        #expect(second.toolCalls.isEmpty)
        #expect(second.stopReason == .stop)
        #expect(second.text.contains("42"))
    }

    @Test
    func streamingToolCallAssemblesArguments() async throws {
        let capture = try await liveCollect(
            await self.makeProvider().generateStream(
                ModelGenerationRequest(
                    sessionKey: "live-openai-chat-tools",
                    prompt: "",
                    policy: self.policy(maxTokens: LiveProviderFixtures.toolOutput, stream: true),
                    messages: [.user(LiveProviderFixtures.toolPrompt)],
                    tools: [LiveProviderFixtures.addTool],
                    toolChoice: .required
                )
            )
        )
        LiveUsageLedger.record("openai-chat.streamingToolCall", model: self.model, usage: capture.usage)
        let final = try #require(capture.final)
        #expect(final.stopReason == .toolUse)
        #expect(!capture.toolCallDeltas.isEmpty)
        let call = try #require(final.toolCalls.first)
        #expect(call.name == "add_numbers")
        #expect(call.id.hasPrefix("call_"))
        let arguments = try #require(LiveProviderFixtures.addArguments(call))
        #expect(arguments.a + arguments.b == 42)
    }

    @Test
    func parallelToolCallsParseAndStream() async throws {
        let request = ModelGenerationRequest(
            sessionKey: "live-openai-chat-parallel",
            prompt: "",
            policy: self.policy(maxTokens: LiveProviderFixtures.toolOutput),
            messages: [.user(LiveProviderFixtures.parallelToolPrompt)],
            tools: [LiveProviderFixtures.addTool],
            toolChoice: .required
        )
        let response = try await liveCall { try await self.makeProvider().generate(request) }
        LiveUsageLedger.record("openai-chat.parallelTools", model: response.modelID, usage: response.usage)
        #expect(LiveProviderFixtures.isParallelAddPair(response.toolCalls), "calls: \(response.toolCalls)")

        let capture = try await liveCollect(await self.makeProvider().generateStream(request))
        LiveUsageLedger.record("openai-chat.parallelTools.stream", model: self.model, usage: capture.usage)
        let final = try #require(capture.final)
        #expect(LiveProviderFixtures.isParallelAddPair(final.toolCalls), "streamed calls: \(final.toolCalls)")
    }

    @Test
    func namedToolChoiceAndSystemMessagesInTranscript() async throws {
        let response = try await liveCall {
            try await self.makeProvider().generate(
                ModelGenerationRequest(
                    sessionKey: "live-openai-chat-named",
                    prompt: "",
                    policy: self.policy(maxTokens: LiveProviderFixtures.toolOutput),
                    messages: [
                        .system("Always use tools for arithmetic."),
                        .user("What is 40 plus 2?"),
                    ],
                    tools: [LiveProviderFixtures.addTool],
                    toolChoice: .named("add_numbers")
                )
            )
        }
        LiveUsageLedger.record("openai-chat.namedToolChoice", model: response.modelID, usage: response.usage)
        let call = try #require(response.toolCalls.first)
        #expect(call.name == "add_numbers")
        #expect(LiveProviderFixtures.addArguments(call).map { $0.a + $0.b } == 42)
    }

    @Test
    func imageInputThroughAttachmentsAndMessages() async throws {
        let legacy = try await liveCall {
            try await self.makeProvider().generate(
                ModelGenerationRequest(
                    sessionKey: "live-openai-chat-image",
                    prompt: LiveProviderFixtures.colorPrompt,
                    policy: self.policy(),
                    attachments: [LiveProviderFixtures.redSquare]
                )
            )
        }
        LiveUsageLedger.record("openai-chat.image.attachments", model: legacy.modelID, usage: legacy.usage)
        #expect(legacy.text.lowercased().contains("red"), "answer: \(legacy.text)")

        let transcript = try await liveCall {
            try await self.makeProvider().generate(
                ModelGenerationRequest(
                    sessionKey: "live-openai-chat-image",
                    prompt: "",
                    policy: self.policy(),
                    messages: [.user(content: [.text(LiveProviderFixtures.colorPrompt), .image(LiveProviderFixtures.redSquare)])]
                )
            )
        }
        LiveUsageLedger.record("openai-chat.image.messages", model: transcript.modelID, usage: transcript.usage)
        #expect(transcript.text.lowercased().contains("red"), "answer: \(transcript.text)")
    }

    @Test
    func jsonSchemaStructuredOutputValidates() async throws {
        let response = try await liveCall {
            try await self.makeProvider().generate(
                ModelGenerationRequest(
                    sessionKey: "live-openai-chat-json",
                    prompt: LiveProviderFixtures.cityPrompt,
                    policy: self.policy(maxTokens: LiveProviderFixtures.toolOutput),
                    responseFormat: LiveProviderFixtures.cityFormat
                )
            )
        }
        LiveUsageLedger.record("openai-chat.jsonSchema", model: response.modelID, usage: response.usage)
        #expect(response.stopReason == .stop)
        #expect(LiveProviderFixtures.validateCityJSON(response.text) != nil, "not schema-valid JSON: \(response.text)")
    }

    @Test
    func outputLimitMapsToLengthStopReason() async throws {
        let response = try await liveCall {
            try await self.makeProvider().generate(
                ModelGenerationRequest(
                    sessionKey: "live-openai-chat",
                    prompt: "Write the numbers from 1 to 200 separated by commas.",
                    policy: self.policy(maxTokens: 16)
                )
            )
        }
        LiveUsageLedger.record("openai-chat.lengthStop", model: response.modelID, usage: response.usage)
        #expect(response.stopReason == .length)
        #expect(!response.text.isEmpty)
    }

    @Test
    func invalidKeyMapsToAuthenticationError() async throws {
        await expectAuthenticationFailure("openai-chat.generate.defaultPath") {
            _ = try await self.makeDefaultProvider(apiKey: LiveProviderKind.openAI.invalidKey)
                .generate(ModelGenerationRequest(sessionKey: "live-invalid", prompt: "hi"))
        }
        let provider = self.makeProvider(apiKey: LiveProviderKind.openAI.invalidKey)
        await expectAuthenticationFailure("openai-chat.generate") {
            _ = try await provider.generate(ModelGenerationRequest(sessionKey: "live-invalid", prompt: "hi", policy: self.policy()))
        }
        await expectAuthenticationFailure("openai-chat.stream") {
            for try await _ in await provider.generateStream(
                ModelGenerationRequest(sessionKey: "live-invalid", prompt: "hi", policy: self.policy(stream: true))
            ) {}
        }
    }
}
