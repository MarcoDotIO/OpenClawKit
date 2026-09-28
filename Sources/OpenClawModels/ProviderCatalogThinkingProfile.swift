import Foundation
import OpenClawCore

/// Thinking levels a model supports plus its default, resolved from catalog metadata.
///
/// Ports upstream `resolveThinkingProfile` (`src/auto-reply/thinking.ts`) with the built-in OpenAI
/// (`extensions/openai/thinking-policy.ts`) and Claude (`src/plugins/provider-claude-thinking.ts`) policies. Other
/// upstream plugin-specific policies are not ported; those providers use the catalog-driven generic profile.
public struct ModelThinkingProfile: Sendable, Equatable {
    /// Supported levels ordered by ``ThinkLevel/rank`` (ties keep declaration order).
    public var levels: [ThinkLevel]
    /// Model default level, when the provider declares one.
    public var defaultLevel: ThinkLevel?

    /// Creates a profile; levels are de-duplicated and sorted by rank.
    public init(levels: [ThinkLevel], defaultLevel: ThinkLevel? = nil) {
        var seen: Set<ThinkLevel> = []
        let unique = levels.filter { seen.insert($0).inserted }
        self.levels = unique.enumerated()
            .sorted { lhs, rhs in
                lhs.element.rank == rhs.element.rank ? lhs.offset < rhs.offset : lhs.element.rank < rhs.element.rank
            }
            .map(\.element)
        self.defaultLevel = defaultLevel.flatMap { unique.contains($0) ? $0 : nil }
    }

    /// Upstream `BASE_THINKING_LEVELS`: off, minimal, low, medium, high.
    public static let baseLevels: [ThinkLevel] = [.off, .minimal, .low, .medium, .high]

    /// Base profile without a default.
    public static let base = ModelThinkingProfile(levels: baseLevels)

    /// Profile for non-reasoning models: only `off`, defaulting to `off`.
    public static let offOnly = ModelThinkingProfile(levels: [.off], defaultLevel: .off)

    /// Returns whether a level is part of the profile.
    public func supports(_ level: ThinkLevel) -> Bool {
        self.levels.contains(level)
    }

    /// Clamps a requested level to the profile (upstream `resolveSupportedThinkingLevelFromProfile`).
    public func resolveSupported(_ level: ThinkLevel) -> ThinkLevel {
        level.clamped(toSupported: self.levels, defaultLevel: self.defaultLevel)
    }

    /// Level used when the user has not chosen one: the profile default, else `medium` (clamped) for reasoning
    /// models, else `off` (upstream `resolveThinkingSelectionForModel`).
    /// - Parameter reasoning: Whether the catalog row reasons.
    public func requestedDefault(reasoning: Bool) -> ThinkLevel {
        if let defaultLevel {
            return defaultLevel
        }
        return reasoning ? self.resolveSupported(.medium) : .off
    }
}

extension OpenClawReferenceProviderCatalog {
    /// Resolves the thinking profile for a provider/model pair from catalog metadata so pickers can offer
    /// `xhigh`, `max` and `ultra` only where the model supports them.
    /// - Parameters:
    ///   - providerID: Provider id or alias.
    ///   - modelID: Model id.
    ///   - agentRuntime: Agent runtime id (`openclaw`, `auto`, `codex`, …). `ultra` is only synthesized for the
    ///     OpenClaw runtime (`openclaw`/`auto`); `nil` follows upstream and never synthesizes it.
    /// - Returns: Supported levels and default.
    public static func thinkingProfile(providerID: String, modelID: String, agentRuntime: String? = nil) -> ModelThinkingProfile {
        let provider = self.normalize(providerID: providerID)
        guard !provider.isEmpty else { return .base }
        let entry = self.entry(for: provider)
        let row = self.catalogModel(providerID: provider, modelID: modelID)
        return ThinkingProfileResolver(
            provider: provider,
            modelID: row?.id ?? self.normalizeModelID(modelID, providerID: provider),
            api: row?.api ?? entry?.catalog.api,
            reasoning: row?.reasoning,
            thinkingLevelMap: row?.thinkingLevelMap,
            compat: row?.compat,
            runtime: agentRuntime?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "",
            openAIFallbackEfforts: { id in
                self.catalogModel(providerID: "openai", modelID: id)?.compat?.supportedReasoningEfforts
            }
        ).resolve()
    }
}

/// Stateless port of the upstream thinking profile resolution for one catalog context.
struct ThinkingProfileResolver {
    struct PluginProfile {
        var levels: [ThinkLevel]
        var defaultLevel: ThinkLevel?
        var preserveWhenCatalogReasoningFalse = false
    }

    let provider: String
    let modelID: String
    let api: ModelAPI?
    let reasoning: Bool?
    let thinkingLevelMap: ModelCatalogThinkingLevelMap?
    let compat: ModelCatalogCompatConfig?
    let runtime: String
    let openAIFallbackEfforts: (String) -> [String]?

    private static let openAIThinkingAPIs: Set<ModelAPI> = [
        .openAICompletions,
        .openAIResponses,
        .openAIChatGPTResponses,
        .azureOpenAIResponses,
    ]

    func resolve() -> ModelThinkingProfile {
        let pluginProfile = self.openAIProfile() ?? (self.api == .anthropicMessages ? self.claudeProfile() : nil)
        let mappedLevels: [ThinkLevel] = self.runtime.isEmpty || self.runtime == "auto" || self.runtime == "openclaw"
            ? self.listMappedThinkingLevels().filter { $0 == .xhigh || $0 == .max }
            : []
        if let pluginProfile, self.reasoning != false || pluginProfile.preserveWhenCatalogReasoningFalse {
            return self.normalize(pluginProfile, mappedLevels: mappedLevels)
        }
        if self.reasoning == false {
            return .offOnly
        }
        var profile = PluginProfile(levels: ModelThinkingProfile.baseLevels)
        self.appendCatalogAdvancedLevels(to: &profile)
        return self.normalize(profile, mappedLevels: mappedLevels)
    }

    // MARK: Generic catalog path

    /// Upstream `normalizeThinkingProfile`: drops levels the map disables (except adaptive/ultra) and appends
    /// mapped `xhigh`/`max` levels.
    private func normalize(_ profile: PluginProfile, mappedLevels: [ThinkLevel]) -> ModelThinkingProfile {
        var levels = profile.levels.filter { level in
            level == .adaptive || level == .ultra || self.thinkingLevelMap?.isDisabled(level) != true
        }
        let defaultLevel = profile.defaultLevel.flatMap { levels.contains($0) ? $0 : nil }
        if !profile.levels.isEmpty {
            for level in mappedLevels where self.thinkingLevelMap?.isDisabled(level) != true && !levels.contains(level) {
                levels.append(level)
            }
        }
        return ModelThinkingProfile(levels: levels, defaultLevel: defaultLevel)
    }

    /// Upstream `appendCatalogAdvancedThinkingLevels`.
    private func appendCatalogAdvancedLevels(to profile: inout PluginProfile) {
        if let map = self.thinkingLevelMap {
            for level in [ThinkLevel.xhigh, .max] where map.isMapped(level) {
                profile.levels.append(level)
            }
        }
        var supportsMax = profile.levels.contains(.max)
        for raw in self.compat?.supportedReasoningEfforts ?? [] {
            let effort = raw.lowercased()
            let accepted: ThinkLevel?
            switch effort {
            case "ultra":
                accepted = .ultra
            case "adaptive":
                accepted = .adaptive
            case "xhigh", "max":
                let level: ThinkLevel = effort == "max" ? .max : .xhigh
                accepted = self.thinkingLevelMap?.isDisabled(level) == true ? nil : level
            default:
                accepted = nil
            }
            if let accepted {
                profile.levels.append(accepted)
                supportsMax = supportsMax || accepted == .max
            }
        }
        if supportsMax, self.runtime == "openclaw" || self.runtime == "auto" {
            profile.levels.append(.ultra)
        }
    }

    /// Upstream `listMappedModelThinkingLevels`.
    private func listMappedThinkingLevels() -> [ThinkLevel] {
        guard let api = self.api, Self.openAIThinkingAPIs.contains(api) else { return [] }
        let format = self.compat?.thinkingFormat
        let binaryOnly = format == .qwen || format == .qwenChatTemplate || format == .zai
        if (api == .openAICompletions && binaryOnly) || self.compat?.disablesReasoningEffort == true {
            return []
        }
        let mapped = Set((self.compat?.reasoningEffortMap ?? [:]).compactMap { key, value in
            value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        return [ThinkLevel.off, .minimal, .low, .medium, .high, .xhigh, .max].filter { mapped.contains($0.rawValue) }
    }

    // MARK: OpenAI policy (extensions/openai/thinking-policy.ts, unified provider surface)

    private static let gpt6ModelIDs: Set<String> = ["gpt-6-astra", "gpt-6-sol", "gpt-6-luna"]
    private static let unifiedXHighModelPrefixes = [
        "gpt-5.6", "gpt-5.5", "gpt-5.5-pro", "gpt-5.4", "gpt-5.4-pro", "gpt-5.3-codex-spark", "gpt-5.4-mini", "gpt-5.4-nano",
    ]
    private static let codexEffortOrder = ["low", "medium", "high", "xhigh", "max", "ultra"]
    private static let codexEffortsByModel: [String: [String]] = [
        "gpt-5.6-sol": codexEffortOrder,
        "gpt-5.6-terra": codexEffortOrder,
        "gpt-5.6-luna": Array(codexEffortOrder.dropLast()),
    ]
    private static let openAILevelOrder: [ThinkLevel] = [.off, .minimal, .low, .medium, .high, .xhigh, .max, .ultra]

    private func openAIProfile() -> PluginProfile? {
        guard self.provider == "openai" || self.provider == "azure-openai-responses" else { return nil }
        let modelID = self.modelID.lowercased() == "gpt-5.4-codex" ? "gpt-5.4" : self.modelID.lowercased()
        let codexEfforts = self.compat?.supportedReasoningEfforts?.map { $0.lowercased() }
        if self.compat?.supportsReasoningEffort == false || codexEfforts?.isEmpty == true {
            let hostRuntime = self.runtime.isEmpty || self.runtime == "auto" || self.runtime == "openclaw"
            let binaryFormats: Set<ModelCompatThinkingFormat> = [.qwen, .qwenChatTemplate, .zai, .deepseek, .together]
            let binary = self.api == .openAICompletions && hostRuntime && self.compat?.thinkingFormat.map(binaryFormats.contains) == true
            return PluginProfile(levels: binary ? ModelThinkingProfile.baseLevels : [])
        }
        let canSynthesizeUltra = self.thinkingLevelMap?.isDisabled(.max) != true
        if Self.gpt6ModelIDs.contains(modelID) {
            let fallback = self.openAIFallbackEfforts(modelID) ?? []
            let efforts = codexEfforts ?? (self.runtime == "codex" ? fallback.filter { $0 != "none" } : fallback)
            let supportsUltra = ["openclaw", "codex", "auto"].contains(self.runtime)
                && efforts.contains("max")
                && (self.runtime == "codex" ? (modelID == "gpt-6-astra" || efforts.contains("ultra")) : canSynthesizeUltra)
            let defaultLevel: ThinkLevel? = efforts.contains("medium") ? .medium : (efforts.contains("low") ? .low : nil)
            return PluginProfile(
                levels: Self.codexLevels(supportsUltra ? efforts + ["ultra"] : efforts),
                defaultLevel: defaultLevel
            )
        }
        let chatGPTAPI = self.api == nil || self.api == .openAIChatGPTResponses
        let resolvedCodexEfforts = chatGPTAPI ? Self.resolveCodexEfforts(modelID: modelID, observed: codexEfforts) : nil
        let knownCodexEfforts = Self.resolveCodexEfforts(modelID: modelID, observed: nil)
        let isGPT56Variant = knownCodexEfforts != nil
        let effortSource = resolvedCodexEfforts ?? knownCodexEfforts
        let supportsMax = modelID.hasPrefix("gpt-5.6") && (self.runtime != "codex" || effortSource?.contains("max") == true)
        let supportsXHigh = Self.unifiedXHighModelPrefixes.contains { modelID.hasPrefix($0) }
        let openClawRuntime = self.runtime == "openclaw" || self.runtime == "auto"
        let supportsUltra = (modelID == "gpt-5.6" || isGPT56Variant)
            && ((openClawRuntime && (canSynthesizeUltra || codexEfforts?.contains("ultra") == true))
                || (self.runtime == "codex" && effortSource?.contains("ultra") == true))
        let needsAccountEffortValidation = self.runtime == "codex"
            && self.compat?.supportedReasoningEfforts == nil
            && chatGPTAPI
            && !supportsXHigh
            && !modelID.hasPrefix("gpt-5.6")
        var levels = ModelThinkingProfile.baseLevels
        if supportsXHigh { levels.append(.xhigh) }
        if supportsMax { levels.append(.max) }
        if supportsUltra { levels.append(.ultra) }
        if needsAccountEffortValidation { levels += [.xhigh, .max] }
        if self.runtime == "codex", let resolvedCodexEfforts {
            levels = Self.codexLevels(resolvedCodexEfforts)
        }
        let defaultLevel: ThinkLevel? = isGPT56Variant && levels.contains(.medium) ? .medium : nil
        return PluginProfile(levels: levels, defaultLevel: defaultLevel)
    }

    private static func codexLevels(_ efforts: [String]) -> [ThinkLevel] {
        let supported = Set(efforts.compactMap { effort -> ThinkLevel? in
            let normalized = effort.lowercased()
            return normalized == "none" ? .off : ThinkLevel(rawValue: normalized)
        })
        return self.openAILevelOrder.filter { supported.contains($0) }
    }

    /// Upstream `resolveOpenAICodexReasoningEfforts`.
    private static func resolveCodexEfforts(modelID: String, observed: [String]?) -> [String]? {
        guard let known = self.codexEffortsByModel[modelID] else {
            return observed
        }
        guard let observed, !observed.isEmpty else {
            return observed == nil ? known : []
        }
        var supported = Set(known).union(observed.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        for effort in self.codexEffortOrder where !known.contains(effort) {
            supported.remove(effort)
        }
        let ordered = self.codexEffortOrder.filter { supported.remove($0) != nil }
        return ordered + supported.sorted()
    }

    // MARK: Claude policy (packages/llm-core/src/model-contracts/anthropic.ts)

    private func claudeProfile() -> PluginProfile {
        let identity = ClaudeModelIdentity(modelID: self.modelID)
        let fable = PluginProfile(levels: [.low, .medium, .high, .xhigh, .max], defaultLevel: .medium, preserveWhenCatalogReasoningFalse: true)
        let sonnet5 = PluginProfile(levels: [.off, .minimal, .low, .medium, .high, .xhigh, .adaptive, .max], defaultLevel: .high)
        if identity.isOpus55 || identity.isFable5 {
            return fable
        }
        if identity.isMythos5 {
            var mythos = fable
            mythos.defaultLevel = .high
            return mythos
        }
        if identity.isOpus5 || identity.isSonnet5 {
            return sonnet5
        }
        if identity.requiresMandatoryAdaptiveThinking {
            return PluginProfile(levels: [.minimal, .low, .medium, .high, .adaptive], defaultLevel: .adaptive, preserveWhenCatalogReasoningFalse: true)
        }
        if identity.supportsNativeXhighEffort {
            return PluginProfile(levels: ModelThinkingProfile.baseLevels + [.xhigh, .adaptive, .max], defaultLevel: .off)
        }
        if identity.supportsAdaptiveThinking {
            return PluginProfile(levels: ModelThinkingProfile.baseLevels + [.adaptive, .max], defaultLevel: .adaptive)
        }
        return PluginProfile(levels: ModelThinkingProfile.baseLevels)
    }
}
