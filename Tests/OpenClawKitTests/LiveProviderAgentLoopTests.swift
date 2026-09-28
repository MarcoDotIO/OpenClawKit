import Foundation
import Testing
@testable import OpenClawKit

/// Live `EmbeddedAgentRuntime` runs with one real `AgentTool` (a deterministic calculator) against
/// catalog-configured providers built by `ModelProviderFactory`.
///
/// Each provider needs `OPENCLAW_LIVE_PROVIDER_TESTS=1` plus its key; see `LiveProviderSupport.swift`.
@Suite("Live provider: agent loop", .serialized)
struct LiveProviderAgentLoopTests {
    private static let prompt = "Use the calculator tool to multiply 1234 by 5678, then reply with only the resulting number."
    private static let expectedProduct = "7006652"

    private func makeRuntime(_ provider: any ModelProvider) -> EmbeddedAgentRuntime {
        EmbeddedAgentRuntime(
            toolRegistry: AgentToolRegistry(tools: [LiveCalculatorTool()]),
            modelRouter: ModelRouter(defaultProviderID: provider.id, providers: [provider]),
            transcriptStore: InMemorySessionTranscriptStore()
        )
    }

    /// Runs the calculator prompt and checks the tool round trip, output, usage and transcript.
    private func runCalculatorLoop(_ kind: LiveProviderKind, thinkingLevel: ThinkLevel?, headers: [String: String] = [:]) async throws {
        let provider = try LiveProviderConfigs.factoryProvider(kind, headers: headers)
        #expect(provider.capabilities.supportsTools)
        let runtime = self.makeRuntime(provider)
        let sessionKey = "live-agent-\(kind.rawValue)"
        let result = try await liveCall {
            try await runtime.run(
                AgentRunRequest(sessionKey: sessionKey, prompt: Self.prompt, thinkingLevel: thinkingLevel, maxToolIterations: 4),
                timeoutMs: 90_000
            )
        }
        LiveUsageLedger.record("agent-loop.\(kind.rawValue).run", model: result.modelID, agentUsage: result.usage, iterations: result.iterations)
        #expect(result.toolResults.map(\.name).contains("calculator"))
        #expect(result.toolResults.first?.output.isError == false)
        #expect(result.toolResults.first?.output.text == Self.expectedProduct)
        #expect(result.output.filter(\.isNumber).contains(Self.expectedProduct), "output: \(result.output)")
        #expect(result.iterations >= 2)
        #expect(result.usage.totalTokens > 0)
        let roles = try await runtime.history(sessionKey: sessionKey).map(\.role)
        #expect(roles.first == "user")
        #expect(roles.contains("toolResult"))
        #expect(roles.last == "assistant")
    }

    /// Streams the calculator prompt through `runEvents` and checks assistant/tool/lifecycle events.
    private func streamCalculatorLoop(_ kind: LiveProviderKind, headers: [String: String] = [:]) async throws {
        let provider = try LiveProviderConfigs.factoryProvider(kind, headers: headers)
        let runtime = self.makeRuntime(provider)
        let sessionKey = "live-agent-stream-\(kind.rawValue)"
        let frames = try await liveCall {
            var frames: [AgentEventFrame] = []
            for try await frame in runtime.runEvents(
                AgentRunRequest(sessionKey: sessionKey, prompt: Self.prompt, thinkingLevel: kind == .openAI ? .off : nil, maxToolIterations: 4),
                timeoutMs: 90_000
            ) {
                frames.append(frame)
            }
            return frames
        }
        let usageFrames = frames.filter { $0.stream == .usage }
        let input = usageFrames.compactMap { $0.data["input"]?.intValue }.reduce(0, +)
        let output = usageFrames.compactMap { $0.data["output"]?.intValue }.reduce(0, +)
        LiveUsageLedger.record(
            "agent-loop.\(kind.rawValue).runEvents",
            model: LiveProviderEnvironment.model(kind),
            usage: ModelUsage(inputTokens: input, outputTokens: output)
        )
        #expect(frames.contains { $0.stream == .tool })
        let assistantText = frames.filter { $0.stream == .assistant }.compactMap { $0.data["delta"]?.stringValue }.joined()
        #expect(assistantText.filter(\.isNumber).contains(Self.expectedProduct), "streamed: \(assistantText)")
        #expect(!usageFrames.isEmpty)
        #expect(frames.last?.stream == .lifecycle)
        #expect(frames.last?.data["phase"]?.stringValue == "end")
        let roles = try await runtime.history(sessionKey: sessionKey).map(\.role)
        #expect(roles.contains("toolResult"))
        #expect(roles.last == "assistant")
    }

    @Test(.enabled(if: LiveProviderEnvironment.isEnabled(.openAI), "needs OPENCLAW_LIVE_PROVIDER_TESTS=1 and OPENAI_API_KEY"))
    func openAIAgentLoopRunsCalculatorTool() async throws {
        try await self.runCalculatorLoop(.openAI, thinkingLevel: .off)
    }

    @Test(.enabled(if: LiveProviderEnvironment.isEnabled(.openAI), "needs OPENCLAW_LIVE_PROVIDER_TESTS=1 and OPENAI_API_KEY"))
    func openAIAgentLoopStreamsCalculatorTool() async throws {
        try await self.streamCalculatorLoop(.openAI)
    }

    @Test(.enabled(if: LiveProviderEnvironment.isEnabled(.anthropic), "needs OPENCLAW_LIVE_PROVIDER_TESTS=1 and ANTHROPIC_API_KEY"))
    func anthropicAgentLoopRunsCalculatorTool() async throws {
        try await anthropicLive {
            try await self.runCalculatorLoop(.anthropic, thinkingLevel: nil, headers: LiveProviderEnvironment.anthropicHeaders)
        }
    }

    @Test(.enabled(if: LiveProviderEnvironment.isEnabled(.anthropic), "needs OPENCLAW_LIVE_PROVIDER_TESTS=1 and ANTHROPIC_API_KEY"))
    func anthropicAgentLoopStreamsCalculatorTool() async throws {
        try await anthropicLive {
            try await self.streamCalculatorLoop(.anthropic, headers: LiveProviderEnvironment.anthropicHeaders)
        }
    }

    @Test(.enabled(if: LiveProviderEnvironment.isEnabled(.xai), "needs OPENCLAW_LIVE_PROVIDER_TESTS=1 and XAI_API_KEY"))
    func xaiAgentLoopRunsCalculatorTool() async throws {
        try await self.runCalculatorLoop(.xai, thinkingLevel: nil)
    }
}
