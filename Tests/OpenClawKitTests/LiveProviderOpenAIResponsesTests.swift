import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import OpenClawCore
import OpenClawModels
import OpenClawProtocol

/// Live end-to-end tests for the OpenAI Responses API (direct `OpenAIResponsesModelProvider`).
///
/// Disabled unless `OPENCLAW_LIVE_PROVIDER_TESTS=1` and `OPENAI_API_KEY` are set; see
/// `LiveProviderSupport.swift`.
@Suite(
    "Live provider: OpenAI Responses",
    .serialized,
    .enabled(if: LiveProviderEnvironment.isEnabled(.openAI), "needs OPENCLAW_LIVE_PROVIDER_TESTS=1 and OPENAI_API_KEY")
)
struct LiveProviderOpenAIResponsesTests {
    private let model = LiveProviderEnvironment.model(.openAI)

    private func makeProvider(apiKey: String? = LiveProviderEnvironment.apiKey(.openAI)) -> OpenAIResponsesModelProvider {
        OpenAIResponsesModelProvider(
            id: "openai",
            configuration: ProviderServiceConfig(
                enabled: true,
                authMode: .apiKey,
                modelID: self.model,
                apiKey: apiKey,
                baseURL: "https://api.openai.com/v1"
            ),
            runtime: ModelProviderRuntimeContext(api: .openAIResponses)
        )
    }

    /// Cheap policy: small output budget and reasoning off (`none` on GPT-5.1+/GPT-6).
    private func policy(maxTokens: Int = LiveProviderFixtures.smallOutput, stream: Bool = false) -> ModelGenerationPolicy {
        ModelGenerationPolicy(streamTokens: stream, maxTokens: maxTokens, reasoningEffort: ModelReasoningEffort.none)
    }

    @Test
    func plainGenerateDefaultPath() async throws {
        // No policy overrides: the path a caller gets from the public initializer with defaults.
        let response = try await liveCall {
            try await self.makeProvider().generate(
                ModelGenerationRequest(sessionKey: "live-openai-responses", prompt: LiveProviderFixtures.pongPrompt)
            )
        }
        LiveUsageLedger.record("openai-responses.plainGenerateDefaultPath", model: response.modelID, usage: response.usage)
        #expect(response.text.lowercased().contains("pong"))
        #expect(response.stopReason == .stop)
        #expect(response.usage != nil)
        #expect(response.modelID?.hasPrefix(self.model) == true)
    }

    @Test
    func plainGenerateReportsUsageAndStopReason() async throws {
        let response = try await liveCall {
            try await self.makeProvider().generate(
                ModelGenerationRequest(
                    sessionKey: "live-openai-responses",
                    prompt: LiveProviderFixtures.pongPrompt,
                    systemPrompt: "You are terse.",
                    policy: self.policy()
                )
            )
        }
        LiveUsageLedger.record("openai-responses.plainGenerate", model: response.modelID, usage: response.usage)
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
                    sessionKey: "live-openai-responses",
                    prompt: "Count from 1 to 5 separated by spaces. Output only the numbers.",
                    policy: self.policy(stream: true)
                )
            )
        )
        LiveUsageLedger.record("openai-responses.streaming", model: self.model, usage: capture.usage)
        let final = try #require(capture.final)
        #expect(capture.chunks.last?.isFinal == true)
        #expect(capture.chunks.filter(\.isFinal).count == 1)
        #expect(capture.textChunkCount >= 1)
        #expect(capture.text.contains("1 2 3 4 5"))
        #expect(final.stopReason == .stop)
        let usage = try #require(capture.usage)
        #expect(usage.outputTokens > 0)
    }

    @Test
    func toolCallRoundTrip() async throws {
        let provider = self.makeProvider()
        let user = ModelMessage.user(LiveProviderFixtures.toolPrompt)
        let first = try await liveCall {
            try await provider.generate(
                ModelGenerationRequest(
                    sessionKey: "live-openai-responses-tools",
                    prompt: "",
                    systemPrompt: LiveProviderFixtures.toolSystemPrompt,
                    policy: self.policy(maxTokens: LiveProviderFixtures.toolOutput),
                    messages: [user],
                    tools: [LiveProviderFixtures.addTool],
                    toolChoice: .required
                )
            )
        }
        LiveUsageLedger.record("openai-responses.toolCall.turn1", model: first.modelID, usage: first.usage)
        #expect(first.stopReason == .toolUse)
        let call = try #require(first.toolCalls.first)
        #expect(call.name == "add_numbers")
        let arguments = try #require(LiveProviderFixtures.addArguments(call))
        #expect(arguments.a + arguments.b == 42)

        let second = try await liveCall {
            try await provider.generate(
                ModelGenerationRequest(
                    sessionKey: "live-openai-responses-tools",
                    prompt: "",
                    systemPrompt: LiveProviderFixtures.toolSystemPrompt,
                    policy: self.policy(maxTokens: LiveProviderFixtures.toolOutput),
                    messages: [user, first.assistantMessage, .toolResult(LiveProviderFixtures.addResult(for: call))],
                    tools: [LiveProviderFixtures.addTool]
                )
            )
        }
        LiveUsageLedger.record("openai-responses.toolCall.turn2", model: second.modelID, usage: second.usage)
        #expect(second.toolCalls.isEmpty)
        #expect(second.stopReason == .stop)
        #expect(second.text.contains("42"))
    }

    @Test
    func streamingToolCallAssemblesArguments() async throws {
        let capture = try await liveCollect(
            await self.makeProvider().generateStream(
                ModelGenerationRequest(
                    sessionKey: "live-openai-responses-tools",
                    prompt: "",
                    policy: self.policy(maxTokens: LiveProviderFixtures.toolOutput, stream: true),
                    messages: [.user(LiveProviderFixtures.toolPrompt)],
                    tools: [LiveProviderFixtures.addTool],
                    toolChoice: .required
                )
            )
        )
        LiveUsageLedger.record("openai-responses.streamingToolCall", model: self.model, usage: capture.usage)
        let final = try #require(capture.final)
        #expect(final.stopReason == .toolUse)
        #expect(!capture.toolCallDeltas.isEmpty)
        let call = try #require(final.toolCalls.first)
        #expect(call.name == "add_numbers")
        #expect(!call.id.isEmpty)
        let arguments = try #require(LiveProviderFixtures.addArguments(call))
        #expect(arguments.a + arguments.b == 42)
    }

    @Test
    func parallelToolCallsParseAndStream() async throws {
        let request = ModelGenerationRequest(
            sessionKey: "live-openai-responses-parallel",
            prompt: "",
            policy: self.policy(maxTokens: LiveProviderFixtures.toolOutput),
            messages: [.user(LiveProviderFixtures.parallelToolPrompt)],
            tools: [LiveProviderFixtures.addTool],
            toolChoice: .required
        )
        let response = try await liveCall { try await self.makeProvider().generate(request) }
        LiveUsageLedger.record("openai-responses.parallelTools", model: response.modelID, usage: response.usage)
        #expect(LiveProviderFixtures.isParallelAddPair(response.toolCalls), "calls: \(response.toolCalls)")

        let capture = try await liveCollect(await self.makeProvider().generateStream(request))
        LiveUsageLedger.record("openai-responses.parallelTools.stream", model: self.model, usage: capture.usage)
        let final = try #require(capture.final)
        #expect(LiveProviderFixtures.isParallelAddPair(final.toolCalls), "streamed calls: \(final.toolCalls)")
        #expect(Set(capture.toolCallDeltas.map(\.index)).count == final.toolCalls.count)
    }

    @Test
    func namedToolChoiceAndSystemMessagesInTranscript() async throws {
        let response = try await liveCall {
            try await self.makeProvider().generate(
                ModelGenerationRequest(
                    sessionKey: "live-openai-responses-named",
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
        LiveUsageLedger.record("openai-responses.namedToolChoice", model: response.modelID, usage: response.usage)
        let call = try #require(response.toolCalls.first)
        #expect(call.name == "add_numbers")
        #expect(LiveProviderFixtures.addArguments(call).map { $0.a + $0.b } == 42)
    }

    @Test
    func cancellingStreamIterationStopsEarly() async throws {
        let stream = await self.makeProvider().generateStream(
            ModelGenerationRequest(
                sessionKey: "live-openai-responses-cancel",
                prompt: "Write the numbers from 1 to 60 separated by spaces.",
                policy: self.policy(maxTokens: 200, stream: true)
            )
        )
        var textChunks = 0
        var sawFinal = false
        try await liveCall {
            for try await chunk in stream {
                if chunk.kind == .text {
                    textChunks += 1
                    if textChunks == 2 {
                        break
                    }
                }
                sawFinal = sawFinal || chunk.isFinal
            }
        }
        LiveUsageLedger.record("openai-responses.cancelledStream", model: self.model, usage: nil)
        #expect(textChunks == 2)
        #expect(!sawFinal)
    }

    @Test
    func imageInputThroughAttachmentsAndMessages() async throws {
        let legacy = try await liveCall {
            try await self.makeProvider().generate(
                ModelGenerationRequest(
                    sessionKey: "live-openai-responses-image",
                    prompt: LiveProviderFixtures.colorPrompt,
                    policy: self.policy(),
                    attachments: [LiveProviderFixtures.redSquare]
                )
            )
        }
        LiveUsageLedger.record("openai-responses.image.attachments", model: legacy.modelID, usage: legacy.usage)
        #expect(legacy.text.lowercased().contains("red"), "answer: \(legacy.text)")

        let transcript = try await liveCall {
            try await self.makeProvider().generate(
                ModelGenerationRequest(
                    sessionKey: "live-openai-responses-image",
                    prompt: "",
                    policy: self.policy(),
                    messages: [.user(content: [.text(LiveProviderFixtures.colorPrompt), .image(LiveProviderFixtures.redSquare)])]
                )
            )
        }
        LiveUsageLedger.record("openai-responses.image.messages", model: transcript.modelID, usage: transcript.usage)
        #expect(transcript.text.lowercased().contains("red"), "answer: \(transcript.text)")
    }

    @Test
    func reasoningEffortToolRoundTripWithoutReplayedReasoningItems() async throws {
        // Low reasoning effort with a visible summary; the next turn replays text and calls only.
        let policy = ModelGenerationPolicy(maxTokens: 400, thinkingLevel: .low, reasoningLevel: .on)
        let provider = self.makeProvider()
        let user = ModelMessage.user(LiveProviderFixtures.toolPrompt)
        let first = try await liveCall {
            try await provider.generate(
                ModelGenerationRequest(
                    sessionKey: "live-openai-responses-reasoning",
                    prompt: "",
                    systemPrompt: LiveProviderFixtures.toolSystemPrompt,
                    policy: policy,
                    messages: [user],
                    tools: [LiveProviderFixtures.addTool]
                )
            )
        }
        LiveUsageLedger.record("openai-responses.reasoning.turn1", model: first.modelID, usage: first.usage)
        let call = try #require(first.toolCalls.first, "text: \(first.text)")
        #expect(first.usage.map { $0.reasoningTokens >= 0 } == true)

        let second = try await liveCall {
            try await provider.generate(
                ModelGenerationRequest(
                    sessionKey: "live-openai-responses-reasoning",
                    prompt: "",
                    systemPrompt: LiveProviderFixtures.toolSystemPrompt,
                    policy: policy,
                    messages: [user, first.assistantMessage, .toolResult(LiveProviderFixtures.addResult(for: call))],
                    tools: [LiveProviderFixtures.addTool]
                )
            )
        }
        LiveUsageLedger.record("openai-responses.reasoning.turn2", model: second.modelID, usage: second.usage)
        #expect(second.text.contains("42"))
    }

    @Test
    func reasoningTokensAndSummaryStream() async throws {
        let capture = try await liveCollect(
            await self.makeProvider().generateStream(
                ModelGenerationRequest(
                    sessionKey: "live-openai-responses-reasoning",
                    prompt: "A bat and a ball cost 1.10 in total. The bat costs 1.00 more than the ball. How much is the ball? Reply with only the amount.",
                    policy: ModelGenerationPolicy(streamTokens: true, maxTokens: 800, thinkingLevel: .medium, reasoningLevel: .stream)
                )
            )
        )
        LiveUsageLedger.record("openai-responses.reasoningSummary.stream", model: self.model, usage: capture.usage)
        print("[live-note] openai-responses reasoning summary chars=\(capture.reasoning.count)")
        let usage = try #require(capture.usage)
        #expect(usage.reasoningTokens > 0)
        #expect(usage.outputTokens >= usage.reasoningTokens)
        #expect(capture.text.contains("0.05") || capture.text.contains("5 cents") || capture.text.contains(".05"), "answer: \(capture.text)")
    }

    @Test
    func jsonSchemaStructuredOutputValidates() async throws {
        let response = try await liveCall {
            try await self.makeProvider().generate(
                ModelGenerationRequest(
                    sessionKey: "live-openai-responses-json",
                    prompt: LiveProviderFixtures.cityPrompt,
                    policy: self.policy(maxTokens: LiveProviderFixtures.toolOutput),
                    responseFormat: LiveProviderFixtures.cityFormat
                )
            )
        }
        LiveUsageLedger.record("openai-responses.jsonSchema", model: response.modelID, usage: response.usage)
        #expect(response.stopReason == .stop)
        #expect(LiveProviderFixtures.validateCityJSON(response.text) != nil, "not schema-valid JSON: \(response.text)")
    }

    @Test
    func outputLimitMapsToLengthStopReason() async throws {
        let response = try await liveCall {
            try await self.makeProvider().generate(
                ModelGenerationRequest(
                    sessionKey: "live-openai-responses",
                    prompt: "Write the numbers from 1 to 200 separated by commas.",
                    // The Responses API rejects max_output_tokens below 16.
                    policy: self.policy(maxTokens: 16)
                )
            )
        }
        LiveUsageLedger.record("openai-responses.lengthStop", model: response.modelID, usage: response.usage)
        #expect(response.stopReason == .length)
        #expect(!response.text.isEmpty)
    }

    @Test
    func reasoningThatExhaustsTheOutputLimitReportsLength() async throws {
        // Reasoning consumes the whole 16-token budget, so no visible text is produced.
        let request = ModelGenerationRequest(
            sessionKey: "live-openai-responses-exhausted",
            prompt: "Think carefully: how many prime numbers are there below 200? Reply with only the number.",
            policy: ModelGenerationPolicy(maxTokens: 16, reasoningEffort: .high)
        )
        let response = try await liveCall { try await self.makeProvider().generate(request) }
        LiveUsageLedger.record("openai-responses.exhaustedLimit.generate", model: response.modelID, usage: response.usage)
        #expect(response.stopReason == .length)
        #expect(response.usage?.reasoningTokens ?? 0 > 0)

        let capture = try await liveCollect(await self.makeProvider().generateStream(request))
        LiveUsageLedger.record("openai-responses.exhaustedLimit.stream", model: self.model, usage: capture.usage)
        #expect(capture.final?.stopReason == .length)
    }

    @Test
    func invalidKeyMapsToAuthenticationError() async throws {
        let provider = self.makeProvider(apiKey: LiveProviderKind.openAI.invalidKey)
        await expectAuthenticationFailure("openai-responses.generate.defaultPath") {
            _ = try await provider.generate(ModelGenerationRequest(sessionKey: "live-invalid", prompt: "hi"))
        }
        await expectAuthenticationFailure("openai-responses.generate") {
            _ = try await provider.generate(ModelGenerationRequest(sessionKey: "live-invalid", prompt: "hi", policy: self.policy()))
        }
        await expectAuthenticationFailure("openai-responses.stream") {
            for try await _ in await provider.generateStream(
                ModelGenerationRequest(sessionKey: "live-invalid", prompt: "hi", policy: self.policy(stream: true))
            ) {}
        }
    }
}
