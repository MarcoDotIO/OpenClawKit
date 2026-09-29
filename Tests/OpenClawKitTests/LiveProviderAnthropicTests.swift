import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import OpenClawCore
import OpenClawModels
import OpenClawProtocol

/// Runs an Anthropic live body. Keys that are not scoped to a workspace are rejected with
/// "must include the anthropic-workspace-id header"; without `ANTHROPIC_WORKSPACE_ID` that exact
/// failure is reported as a known issue instead of a test failure. Every other failure still fails.
func anthropicLive(_ body: () async throws -> Void) async throws {
    guard LiveProviderEnvironment.anthropicWorkspaceID == nil else {
        try await body()
        return
    }
    try await withKnownIssue("Anthropic key is not scoped to a workspace; set ANTHROPIC_WORKSPACE_ID", isIntermittent: true) {
        try await body()
    } matching: { issue in
        if case .errorCaught(let error) = issue.kind {
            return String(describing: error).contains("anthropic-workspace-id")
        }
        return false
    }
}

/// Live end-to-end tests for the Anthropic Messages API (`AnthropicModelProvider`).
///
/// Disabled unless `OPENCLAW_LIVE_PROVIDER_TESTS=1` and `ANTHROPIC_API_KEY` are set; see
/// `LiveProviderSupport.swift`.
@Suite(
    "Live provider: Anthropic Messages",
    .serialized,
    .enabled(if: LiveProviderEnvironment.isEnabled(.anthropic), "needs OPENCLAW_LIVE_PROVIDER_TESTS=1 and ANTHROPIC_API_KEY")
)
struct LiveProviderAnthropicTests {
    private let model = LiveProviderEnvironment.model(.anthropic)

    private func makeProvider(apiKey: String? = LiveProviderEnvironment.apiKey(.anthropic)) -> AnthropicModelProvider {
        AnthropicModelProvider(
            configuration: AnthropicModelConfig(
                enabled: true,
                modelID: self.model,
                apiKey: apiKey,
                maxTokens: LiveProviderFixtures.smallOutput,
                // ANTHROPIC_WORKSPACE_ID / OPENCLAW_LIVE_ANTHROPIC_WORKSPACE_ID, sent as `anthropic-workspace-id`.
                workspaceID: LiveProviderEnvironment.anthropicWorkspaceID
            )
        )
    }

    private func request(
        _ sessionKey: String,
        prompt: String = "",
        systemPrompt: String? = nil,
        maxTokens: Int = LiveProviderFixtures.smallOutput,
        stream: Bool = false,
        thinking: ThinkLevel? = nil,
        messages: [ModelMessage] = [],
        tools: [ModelToolDefinition] = [],
        toolChoice: ModelToolChoice = .auto,
        responseFormat: ModelResponseFormat = .text
    ) -> ModelGenerationRequest {
        ModelGenerationRequest(
            sessionKey: sessionKey,
            prompt: prompt,
            systemPrompt: systemPrompt,
            policy: ModelGenerationPolicy(streamTokens: stream, maxTokens: maxTokens, thinkingLevel: thinking),
            messages: messages,
            tools: tools,
            toolChoice: toolChoice,
            responseFormat: responseFormat
        )
    }

    @Test
    func plainGenerateReportsUsageAndStopReason() async throws {
        try await anthropicLive {
            let response = try await liveCall {
                try await self.makeProvider().generate(
                    self.request("live-anthropic", prompt: LiveProviderFixtures.pongPrompt, systemPrompt: "You are terse.")
                )
            }
            LiveUsageLedger.record("anthropic.plainGenerate", model: response.modelID, usage: response.usage)
            #expect(response.text.lowercased().contains("pong"))
            #expect(response.stopReason == .stop)
            #expect(response.modelID?.hasPrefix(self.model) == true)
            let usage = try #require(response.usage)
            #expect(usage.inputTokens > 0)
            #expect(usage.outputTokens > 0)
            #expect(usage.totalTokens >= usage.inputTokens + usage.outputTokens)
        }
    }

    @Test
    func streamingAccumulatesTextAndReportsUsage() async throws {
        try await anthropicLive {
            let capture = try await liveCollect(
                await self.makeProvider().generateStream(
                    self.request(
                        "live-anthropic",
                        prompt: "Count from 1 to 5 separated by spaces. Output only the numbers.",
                        stream: true
                    )
                )
            )
            LiveUsageLedger.record("anthropic.streaming", model: self.model, usage: capture.usage)
            let final = try #require(capture.final)
            #expect(capture.chunks.last?.isFinal == true)
            #expect(capture.textChunkCount >= 1)
            #expect(capture.text.contains("1 2 3 4 5"))
            #expect(final.stopReason == .stop)
            let usage = try #require(capture.usage)
            #expect(usage.inputTokens > 0)
            #expect(usage.outputTokens > 0)
        }
    }

    @Test
    func toolCallRoundTrip() async throws {
        try await anthropicLive {
            let provider = self.makeProvider()
            let user = ModelMessage.user(LiveProviderFixtures.toolPrompt)
            let first = try await liveCall {
                try await provider.generate(
                    self.request(
                        "live-anthropic-tools",
                        systemPrompt: LiveProviderFixtures.toolSystemPrompt,
                        maxTokens: LiveProviderFixtures.toolOutput,
                        messages: [user],
                        tools: [LiveProviderFixtures.addTool],
                        toolChoice: .required
                    )
                )
            }
            LiveUsageLedger.record("anthropic.toolCall.turn1", model: first.modelID, usage: first.usage)
            #expect(first.stopReason == .toolUse)
            let call = try #require(first.toolCalls.first)
            #expect(call.name == "add_numbers")
            #expect(call.id.hasPrefix("toolu_"))
            let arguments = try #require(LiveProviderFixtures.addArguments(call))
            #expect(arguments.a + arguments.b == 42)

            let second = try await liveCall {
                try await provider.generate(
                    self.request(
                        "live-anthropic-tools",
                        systemPrompt: LiveProviderFixtures.toolSystemPrompt,
                        maxTokens: LiveProviderFixtures.toolOutput,
                        messages: [user, first.assistantMessage, .toolResult(LiveProviderFixtures.addResult(for: call))],
                        tools: [LiveProviderFixtures.addTool]
                    )
                )
            }
            LiveUsageLedger.record("anthropic.toolCall.turn2", model: second.modelID, usage: second.usage)
            #expect(second.toolCalls.isEmpty)
            #expect(second.stopReason == .stop)
            #expect(second.text.contains("42"))
        }
    }

    @Test
    func streamingToolCallAssemblesArguments() async throws {
        try await anthropicLive {
            let capture = try await liveCollect(
                await self.makeProvider().generateStream(
                    self.request(
                        "live-anthropic-tools",
                        maxTokens: LiveProviderFixtures.toolOutput,
                        stream: true,
                        messages: [.user(LiveProviderFixtures.toolPrompt)],
                        tools: [LiveProviderFixtures.addTool],
                        toolChoice: .required
                    )
                )
            )
            LiveUsageLedger.record("anthropic.streamingToolCall", model: self.model, usage: capture.usage)
            let final = try #require(capture.final)
            #expect(final.stopReason == .toolUse)
            #expect(!capture.toolCallDeltas.isEmpty)
            let call = try #require(final.toolCalls.first)
            #expect(call.name == "add_numbers")
            let arguments = try #require(LiveProviderFixtures.addArguments(call))
            #expect(arguments.a + arguments.b == 42)
        }
    }

    @Test
    func parallelToolCallsAndImageInput() async throws {
        try await anthropicLive {
            let capture = try await liveCollect(
                await self.makeProvider().generateStream(
                    self.request(
                        "live-anthropic-parallel",
                        maxTokens: LiveProviderFixtures.toolOutput,
                        stream: true,
                        messages: [.user(LiveProviderFixtures.parallelToolPrompt)],
                        tools: [LiveProviderFixtures.addTool],
                        toolChoice: .required
                    )
                )
            )
            LiveUsageLedger.record("anthropic.parallelTools.stream", model: self.model, usage: capture.usage)
            let final = try #require(capture.final)
            #expect(LiveProviderFixtures.isParallelAddPair(final.toolCalls), "streamed calls: \(final.toolCalls)")

            let image = try await liveCall {
                try await self.makeProvider().generate(
                    self.request(
                        "live-anthropic-image",
                        messages: [.user(content: [.text(LiveProviderFixtures.colorPrompt), .image(LiveProviderFixtures.redSquare)])]
                    )
                )
            }
            LiveUsageLedger.record("anthropic.image.messages", model: image.modelID, usage: image.usage)
            #expect(image.text.lowercased().contains("red"), "answer: \(image.text)")
        }
    }

    @Test
    func jsonSchemaStructuredOutputValidates() async throws {
        try await anthropicLive {
            let response = try await liveCall {
                try await self.makeProvider().generate(
                    self.request(
                        "live-anthropic-json",
                        prompt: LiveProviderFixtures.cityPrompt,
                        maxTokens: LiveProviderFixtures.toolOutput,
                        responseFormat: LiveProviderFixtures.cityFormat
                    )
                )
            }
            LiveUsageLedger.record("anthropic.jsonSchema", model: response.modelID, usage: response.usage)
            #expect(response.stopReason == .stop)
            #expect(LiveProviderFixtures.validateCityJSON(response.text) != nil, "not schema-valid JSON: \(response.text)")
        }
    }

    @Test
    func outputLimitMapsToLengthStopReason() async throws {
        try await anthropicLive {
            let response = try await liveCall {
                try await self.makeProvider().generate(
                    self.request("live-anthropic", prompt: "Write the numbers from 1 to 200 separated by commas.", maxTokens: 8)
                )
            }
            LiveUsageLedger.record("anthropic.lengthStop", model: response.modelID, usage: response.usage)
            #expect(response.stopReason == .length)
            #expect(!response.text.isEmpty)
        }
    }

    @Test
    func thinkingReturnsSignedReasoningAndReplaysBeforeToolUse() async throws {
        try await anthropicLive {
            let provider = self.makeProvider()
            let user = ModelMessage.user(LiveProviderFixtures.toolPrompt)
            // Budget thinking (1024 tokens) on Haiku 4.5; the engine raises max_tokens above the budget.
            let first = try await liveCall {
                try await provider.generate(
                    self.request(
                        "live-anthropic-thinking",
                        systemPrompt: LiveProviderFixtures.toolSystemPrompt,
                        maxTokens: LiveProviderFixtures.toolOutput,
                        thinking: .low,
                        messages: [user],
                        tools: [LiveProviderFixtures.addTool]
                    )
                )
            }
            LiveUsageLedger.record("anthropic.thinking.turn1", model: first.modelID, usage: first.usage)
            #expect(first.reasoningText?.isEmpty == false)
            #expect(first.reasoningSignature?.isEmpty == false)
            let call = try #require(first.toolCalls.first, "thinking turn should call add_numbers")
            #expect(call.name == "add_numbers")

            // The signed thinking block must be replayed before tool_use or the API rejects the turn.
            let second = try await liveCall {
                try await provider.generate(
                    self.request(
                        "live-anthropic-thinking",
                        systemPrompt: LiveProviderFixtures.toolSystemPrompt,
                        maxTokens: LiveProviderFixtures.toolOutput,
                        thinking: .low,
                        messages: [user, first.assistantMessage, .toolResult(LiveProviderFixtures.addResult(for: call))],
                        tools: [LiveProviderFixtures.addTool]
                    )
                )
            }
            LiveUsageLedger.record("anthropic.thinking.turn2", model: second.modelID, usage: second.usage)
            #expect(second.text.contains("42"))
            #expect(second.stopReason == .stop)
        }
    }

    @Test
    func streamingThinkingCarriesSignature() async throws {
        try await anthropicLive {
            let capture = try await liveCollect(
                await self.makeProvider().generateStream(
                    self.request(
                        "live-anthropic-thinking",
                        prompt: "What is 12 times 12? Answer with just the number.",
                        maxTokens: LiveProviderFixtures.smallOutput,
                        stream: true,
                        thinking: .low
                    )
                )
            )
            LiveUsageLedger.record("anthropic.streamingThinking", model: self.model, usage: capture.usage)
            let final = try #require(capture.final)
            #expect(!capture.reasoning.isEmpty)
            #expect(final.reasoningSignature?.isEmpty == false)
            #expect(capture.text.contains("144"))
        }
    }

    @Test
    func invalidKeyMapsToAuthenticationError() async throws {
        let provider = self.makeProvider(apiKey: LiveProviderKind.anthropic.invalidKey)
        await expectAuthenticationFailure("anthropic.generate") {
            _ = try await provider.generate(self.request("live-invalid", prompt: "hi"))
        }
        await expectAuthenticationFailure("anthropic.stream") {
            for try await _ in await provider.generateStream(self.request("live-invalid", prompt: "hi", stream: true)) {}
        }
    }
}
