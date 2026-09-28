import Testing
@testable import OpenClawCore
@testable import OpenClawModels

@Suite("Provider catalog thinking profiles")
struct ProviderCatalogThinkingProfileTests {
    private func profile(_ provider: String, _ model: String, runtime: String? = nil) -> ModelThinkingProfile {
        OpenClawReferenceProviderCatalog.thinkingProfile(providerID: provider, modelID: model, agentRuntime: runtime)
    }

    @Test
    func gpt6ProfilesComeFromCatalogEffortsAndOnlySynthesizeUltraForOpenClaw() {
        let astra = self.profile("openai", "gpt-6-astra")
        #expect(astra.levels == [.low, .medium, .high, .xhigh, .max])
        #expect(astra.defaultLevel == .medium)

        let openClaw = self.profile("openai", "gpt-6-astra", runtime: "openclaw")
        #expect(openClaw.levels == [.low, .medium, .high, .xhigh, .max, .ultra])

        let codex = self.profile("openai-codex", "gpt-6-astra", runtime: "codex")
        #expect(codex.levels.last == .ultra)

        #expect(astra.resolveSupported(.ultra) == .max)
        #expect(astra.resolveSupported(.off) == .low)
        #expect(astra.resolveSupported(.adaptive) == .medium)
    }

    @Test
    func gpt56VariantsOfferMaxAndDefaultToMedium() {
        let sol = self.profile("openai", "gpt-5.6-sol")
        #expect(sol.levels == [.off, .minimal, .low, .medium, .high, .xhigh, .max])
        #expect(sol.defaultLevel == .medium)
        #expect(self.profile("openai", "gpt-5.6-sol", runtime: "auto").levels.last == .ultra)

        let gpt55 = self.profile("openai", "gpt-5.5")
        #expect(gpt55.levels == [.off, .minimal, .low, .medium, .high, .xhigh])
        #expect(gpt55.defaultLevel == nil)
    }

    @Test
    func claudeFamiliesUseTheClaudeProfiles() {
        let opus5 = self.profile("anthropic", "claude-opus-5")
        #expect(opus5.levels == [.off, .minimal, .low, .medium, .adaptive, .high, .xhigh, .max])
        #expect(opus5.defaultLevel == .high)

        let opus55 = self.profile("anthropic", "opus-5.5")
        #expect(opus55.levels == [.low, .medium, .high, .xhigh, .max])
        #expect(opus55.defaultLevel == .medium)

        let opus48 = self.profile("anthropic", "claude-opus-4-8")
        #expect(opus48.levels == [.off, .minimal, .low, .medium, .adaptive, .high, .xhigh, .max])
        #expect(opus48.defaultLevel == .off)

        let sonnet46 = self.profile("anthropic", "claude-sonnet-4-6")
        #expect(sonnet46.levels == [.off, .minimal, .low, .medium, .adaptive, .high, .max])
        #expect(sonnet46.defaultLevel == .adaptive)

        let haiku = self.profile("anthropic", "claude-haiku-4-5")
        #expect(haiku.levels == ModelThinkingProfile.baseLevels)
        #expect(haiku.defaultLevel == nil)

        let routed = self.profile("github-copilot", "claude-sonnet-5")
        #expect(routed.defaultLevel == .high)
        #expect(routed.supports(.max))
    }

    @Test
    func claudeIdentityMatchesUpstreamFamilyRules() {
        #expect(ClaudeModelIdentity(modelID: "anthropic/Claude_Opus.5").isOpus5)
        #expect(ClaudeModelIdentity(modelID: "us.anthropic.claude-opus-5-5-v1").isOpus55)
        #expect(ClaudeModelIdentity(modelID: "vendor/claude-sonnet-5@2026").isSonnet5)
        #expect(!ClaudeModelIdentity(modelID: "claude-sonnet-50").isSonnet5)
        #expect(ClaudeModelIdentity(modelID: "claude-mythos-preview").requiresMandatoryAdaptive)
        #expect(!ClaudeModelIdentity(modelID: "claude-opus-4-5").supportsAdaptive)
    }

    @Test
    func genericCatalogProfilesFollowThinkingMapsAndEfforts() {
        let kimi = self.profile("moonshot", "kimi-k3")
        #expect(kimi.levels == [.low, .high, .xhigh, .max])

        let gemini = self.profile("google", "gemini-3.7-flash")
        #expect(gemini.levels == [.off, .low, .medium, .high])

        let meta = self.profile("meta", "muse-spark-1.3")
        #expect(meta.levels == [.off, .minimal, .low, .medium, .high, .xhigh])

        let cohere = self.profile("cohere", "command-a-plus-05-2026")
        #expect(cohere.levels == [.off, .minimal, .low, .medium, .high, .xhigh, .max])
        #expect(cohere.resolveSupported(.medium) == .medium)
    }

    @Test
    func nonReasoningAndBinaryModelsCollapse() {
        let qwen = self.profile("qwen", "qwen3.5-plus")
        #expect(qwen == .offOnly)
        #expect(qwen.requestedDefault(reasoning: false) == .off)

        let featherless = self.profile("featherless", "Qwen/Qwen3-32B")
        #expect(featherless.levels == ModelThinkingProfile.baseLevels)

        let unknown = self.profile("unknown-provider", "whatever")
        #expect(unknown == .base)
        #expect(unknown.requestedDefault(reasoning: true) == .medium)
    }

    @Test
    func uncataloguedOpenAIModelsUseTheOpenAIPolicy() {
        let gpt56 = self.profile("openai", "gpt-5.6")
        #expect(gpt56.levels == [.off, .minimal, .low, .medium, .high, .xhigh, .max])
    }

    @Test
    func profileInitializerSortsByRankAndValidatesDefault() {
        let profile = ModelThinkingProfile(levels: [.max, .adaptive, .off, .medium, .max], defaultLevel: .ultra)
        #expect(profile.levels == [.off, .adaptive, .medium, .max])
        #expect(profile.defaultLevel == nil)
    }

    @Test
    func modelChoicesCarryThinkingLevelsAndContextWindows() throws {
        let choices = OpenClawReferenceProviderCatalog.modelChoices(providerID: "anthropic", agentRuntime: "openclaw")
        let opus = try #require(choices.first { $0.id == "claude-opus-5" })
        #expect(opus.provider == "anthropic")
        #expect(opus.thinkingdefault == "high")
        #expect(opus.thinkinglevels?.compactMap { $0["id"]?.stringValue }.contains("max") == true)
        #expect(opus.contextwindows?.compactMap { $0["id"]?.stringValue }.contains("1m") == true)
        #expect(opus.input?.compactMap(\.stringValue).contains("image") == true)

        let appleFM = OpenClawReferenceProviderCatalog.modelChoices(providerID: "apple-fm")
        #expect(appleFM.first?.id == "system")
        #expect(appleFM.first?.local == true)
        #expect(appleFM.first?.thinkinglevels?.count == 1)
    }
}
