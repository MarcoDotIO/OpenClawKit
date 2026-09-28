import Foundation
import Testing
@testable import OpenClawKit

@Suite("ThinkLevel parity (2026.9.6)")
struct ThinkLevelParityTests {
    @Test
    func caseOrderMatchesUpstreamAllThinkingLevels() {
        #expect(ThinkLevel.allCases.map(\.rawValue) == [
            "off", "minimal", "low", "medium", "high", "xhigh", "adaptive", "max", "ultra",
        ])
    }

    @Test(arguments: [
        ("adaptive", ThinkLevel.adaptive),
        ("auto", .adaptive),
        ("A-U_T O", .adaptive),
        ("max", .max),
        ("MAX", .max),
        ("m-a_x", .max),
        ("ultra", .ultra),
        ("Ultra", .ultra),
        ("ul tra", .ultra),
        ("xhigh", .xhigh),
        ("x-high", .xhigh),
        ("extra_high", .xhigh),
        ("off", .off),
        ("none", .off),
        (" NONE ", .off),
        ("on", .low),
        ("enable", .low),
        ("enabled", .low),
        ("min", .minimal),
        ("minimal", .minimal),
        ("think", .minimal),
        ("low", .low),
        ("thinkhard", .low),
        ("think-hard", .low),
        ("think_hard", .low),
        ("mid", .medium),
        ("med", .medium),
        ("medium", .medium),
        ("thinkharder", .medium),
        ("think-harder", .medium),
        ("harder", .medium),
        ("high", .high),
        ("ultrathink", .high),
        ("thinkhardest", .high),
        ("highest", .high),
    ])
    func normalizeMatchesUpstreamAliases(raw: String, expected: ThinkLevel) {
        #expect(ThinkLevel.normalize(raw) == expected)
    }

    @Test
    func normalizeRejectsUnknownAndEmptyValues() {
        #expect(ThinkLevel.normalize(nil) == nil)
        #expect(ThinkLevel.normalize("") == nil)
        #expect(ThinkLevel.normalize("  ") == nil)
        #expect(ThinkLevel.normalize("think hard") == nil)
        #expect(ThinkLevel.normalize("maximum") == nil)
    }

    @Test
    func ranksMatchUpstreamThinkingLevelRanks() {
        let ranks = Dictionary(uniqueKeysWithValues: ThinkLevel.allCases.map { ($0, $0.rank) })
        #expect(ranks == [
            .off: 0, .minimal: 10, .low: 20, .medium: 30, .adaptive: 30,
            .high: 40, .xhigh: 60, .max: 70, .ultra: 80,
        ])
    }

    @Test
    func ultraIsNeverSentToProviderTransports() {
        #expect(ThinkLevel.ultra.providerTransportLevel == .max)
        for level in ThinkLevel.allCases where level != .ultra {
            #expect(level.providerTransportLevel == level)
        }
    }

    @Test
    func clampingFollowsResolveSupportedThinkingLevelFromProfile() {
        let base: [ThinkLevel] = [.off, .minimal, .low, .medium, .high]
        #expect(ThinkLevel.medium.clamped(toSupported: base) == .medium)
        #expect(ThinkLevel.ultra.clamped(toSupported: base) == .high)
        #expect(ThinkLevel.xhigh.clamped(toSupported: base + [.max]) == .high)
        #expect(ThinkLevel.ultra.clamped(toSupported: base + [.xhigh, .max]) == .max)
        #expect(ThinkLevel.adaptive.clamped(toSupported: base, defaultLevel: .high) == .high)
        #expect(ThinkLevel.adaptive.clamped(toSupported: base, defaultLevel: .off) == .medium)
        #expect(ThinkLevel.minimal.clamped(toSupported: [.low, .medium, .high, .xhigh, .max]) == .low)
        #expect(ThinkLevel.off.clamped(toSupported: [.low, .medium]) == .low)
        #expect(ThinkLevel.high.clamped(toSupported: [.off]) == .off)
        #expect(ThinkLevel.high.clamped(toSupported: []) == .off)
    }

    @Test
    func codableAcceptsAliasesAndEncodesCanonicalValues() throws {
        let decoded = try JSONDecoder().decode([ThinkLevel].self, from: Data(#"["none","MAX","ultra","x-high"]"#.utf8))
        #expect(decoded == [.off, .max, .ultra, .xhigh])
        let encoded = try JSONEncoder().encode([ThinkLevel.max, .ultra])
        #expect(String(decoding: encoded, as: UTF8.self) == #"["max","ultra"]"#)
    }

    @Test
    func xhighSupportResolvesLegacyCodexProviderAndNewOpenAIModels() {
        #expect(ThinkLevel.supportsXHighThinking(providerID: "openai-codex", modelID: "gpt-5.3-codex"))
        #expect(ThinkLevel.supportsXHighThinking(providerID: "openai", modelID: "gpt-5.3-codex"))
        #expect(ThinkLevel.supportsXHighThinking(providerID: "openai", modelID: "gpt-6-astra"))
        #expect(ThinkLevel.supportsXHighThinking(providerID: "openai", modelID: "gpt-5.6-terra"))
        #expect(ThinkLevel.supportsXHighThinking(providerID: "anthropic", modelID: "gpt-6-astra") == false)
        #expect(ThinkLevel.supportedLevels(providerID: "openai", modelID: "gpt-6-sol").contains(.xhigh))
        #expect(ThinkLevel.supportedLevels(providerID: "openai", modelID: "gpt-6-sol").contains(.ultra) == false)
    }

    actor CapturingProvider: ModelProvider {
        let id = "thinking-capture"
        private(set) var lastRequest: ModelGenerationRequest?

        func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
            self.lastRequest = request
            return ModelGenerationResponse(text: "ok", providerID: self.id)
        }

        func snapshot() -> ModelGenerationRequest? {
            self.lastRequest
        }
    }

    @Test
    func agentRuntimeSendsMaxToProvidersWhenSessionRequestsUltra() async throws {
        let router = ModelRouter()
        let provider = CapturingProvider()
        await router.register(provider)
        let runtime = EmbeddedAgentRuntime(modelRouter: router)
        try await runtime.setDefaultModelProviderID(provider.id)

        _ = try await runtime.run(
            AgentRunRequest(
                runID: "run-ultra",
                sessionKey: "session-ultra",
                prompt: "hello",
                thinkingLevel: .ultra,
                reasoningLevel: .on
            )
        )

        let request = try #require(await provider.snapshot())
        #expect(request.policy.thinkingLevel == .max)
        #expect(request.metadata["thinkingLevel"] == "max")
        #expect(request.policy.reasoningEffort == .high)
    }
}
