import Foundation
import OpenClawCore

/// Reasoning effort value that is either a canonical ``ModelReasoningEffort`` or a provider-native
/// label kept verbatim (from `compat.reasoningEffortMap`, whose values are case-sensitive).
public enum ModelReasoningEffortValue: Sendable, Equatable, Hashable {
    /// Canonical effort.
    case standard(ModelReasoningEffort)
    /// Provider-native effort label.
    case custom(String)

    /// Creates a value, folding canonical names (`High` → `.high`) and keeping others verbatim.
    /// - Parameter rawValue: Raw effort label.
    public init(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let standard = ModelReasoningEffort(rawValue: trimmed.lowercased()) {
            self = .standard(standard)
        } else if trimmed.lowercased() == "off" {
            self = .standard(.none)
        } else {
            self = .custom(trimmed)
        }
    }

    /// Wire label.
    public var rawValue: String {
        switch self {
        case .standard(let effort):
            return effort.rawValue
        case .custom(let value):
            return value
        }
    }
}

/// Per-model reasoning effort resolution and clamping (upstream
/// `packages/ai/src/providers/openai-reasoning-effort.ts` and `openai-request-reasoning.ts`).
///
/// Resolution order: clamp the thinking level against `thinkingLevelMap` nulls, base-map the level
/// (off → none, adaptive → medium, max/ultra → xhigh, or max on native-max OpenAI models), apply
/// `compat.reasoningEffortMap` then `thinkingLevelMap` values, then clamp to the model's supported
/// set (`compat.supportedReasoningEfforts`, empty when `supportsReasoningEffort == false`, else the
/// known GPT families).
public enum ReasoningEffortResolver {
    /// Enabled efforts in rank order (upstream `ENABLED_REASONING_EFFORTS`).
    public static let enabledEfforts = ["minimal", "low", "medium", "high", "xhigh", "max"]

    private static let canonicalEfforts: Set<String> = ["none", "off", "minimal", "low", "medium", "high", "xhigh", "max"]
    private static let gpt5 = ["minimal", "low", "medium", "high"]
    private static let gpt51 = ["none", "low", "medium", "high"]
    private static let gpt52 = ["none", "low", "medium", "high", "xhigh"]
    private static let gpt56 = ["none", "low", "medium", "high", "xhigh", "max"]
    private static let gpt6Astra = ["low", "medium", "high", "xhigh", "max"]
    private static let gptCodex = ["low", "medium", "high", "xhigh"]
    private static let gptPro = ["medium", "high", "xhigh"]
    private static let gpt5Pro = ["high"]
    private static let gpt51CodexMax = ["none", "medium", "high", "xhigh"]
    private static let gpt51CodexMini = ["medium"]
    private static let generic = ["low", "medium", "high"]

    /// Resolves the provider effort for a thinking level.
    /// - Parameters:
    ///   - thinkingLevel: Requested thinking level.
    ///   - model: Model definition (`nil` when the provider has no catalog row; `reasoning` is then assumed).
    ///   - modelID: Model identifier (used for family detection when `model` is `nil`).
    ///   - providerID: Provider identifier.
    ///   - api: Effective transport API.
    /// - Returns: Provider effort label, or `nil` to omit the field.
    public static func resolve(
        thinkingLevel: ThinkLevel,
        model: ModelDefinitionConfig?,
        modelID: String,
        providerID: String,
        api: ModelAPI?
    ) -> String? {
        if let model, !model.reasoning {
            return nil
        }
        let level = self.clampedLevel(thinkingLevel, map: model?.thinkingLevelMap)
        guard let level else {
            return nil
        }
        if model == nil, level == .off {
            // Without a catalog row the route's disabled-effort contract is unknown; omit it.
            return nil
        }
        let provider = ProviderRuntimeIdentity.canonicalProviderID(providerID)
        let id = model?.id ?? modelID
        let supported = self.modelSupportedEfforts(modelID: id, compat: model?.compat, api: api)
        let requested: String
        switch level {
        case .off:
            requested = "off"
        case .adaptive:
            requested = "medium"
        case .max, .ultra:
            let nativeMax = provider == "openai" && (supported ?? self.generic).contains("max")
            requested = nativeMax ? "max" : "xhigh"
        default:
            requested = level.rawValue
        }
        return self.resolveEffort(
            requested: requested,
            levelKey: level.providerTransportLevel.rawValue,
            model: model,
            modelID: id,
            api: api,
            supported: supported
        )
    }

    /// Clamps an explicit effort request (for example ``ModelGenerationPolicy/reasoningEffort``).
    /// - Parameters:
    ///   - effort: Requested effort label.
    ///   - model: Optional model definition.
    ///   - modelID: Model identifier.
    ///   - api: Effective transport API.
    /// - Returns: Supported effort label, or `nil` to omit the field.
    public static func clamp(
        effort: String,
        model: ModelDefinitionConfig?,
        modelID: String,
        api: ModelAPI?
    ) -> String? {
        if let model, !model.reasoning {
            return nil
        }
        let id = model?.id ?? modelID
        let supported = self.modelSupportedEfforts(modelID: id, compat: model?.compat, api: api)
        return self.resolveEffort(
            requested: self.normalize(effort),
            levelKey: self.normalize(effort),
            model: model,
            modelID: id,
            api: api,
            supported: supported
        )
    }

    /// Supported efforts for a model: compat declaration, known GPT family, or `nil` when unknown.
    /// - Parameters:
    ///   - modelID: Model identifier (a trailing `-YYYY-MM-DD` date suffix is ignored).
    ///   - compat: Optional compat flags.
    ///   - api: Effective transport API.
    public static func modelSupportedEfforts(modelID: String, compat: ModelCompatConfig?, api: ModelAPI?) -> [String]? {
        if compat?.supportsReasoningEffort == false {
            return []
        }
        if let declared = compat?.supportedReasoningEfforts {
            var seen = Set<String>()
            return declared.compactMap { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
                return trimmed
            }
        }
        let id = self.normalizedModelID(modelID)
        let supportsMax = api != .openAICompletions
        if self.isGPT6(id), api != .azureOpenAIResponses {
            if id == "gpt-6-astra" {
                return supportsMax ? self.gpt6Astra : self.gptCodex
            }
            return supportsMax ? self.gpt56 : self.gpt52
        }
        if self.matches(id, prefix: "gpt-5.6") {
            return supportsMax ? self.gpt56 : self.gpt52
        }
        if id == "gpt-5.1-codex-mini" {
            return self.gpt51CodexMini
        }
        if id == "gpt-5.1-codex-max" {
            return self.gpt51CodexMax
        }
        if self.isCodexFamily(id) {
            return self.gptCodex
        }
        if id == "gpt-5-pro" {
            return self.gpt5Pro
        }
        if self.isMinorFamily(id, minors: "23456789", suffix: "-pro") {
            return self.gptPro
        }
        if self.isMinorFamily(id, minors: "23456789", suffix: nil) {
            return self.gpt52
        }
        if self.matches(id, prefix: "gpt-5.1") {
            return self.gpt51
        }
        if self.matches(id, prefix: "gpt-5") {
            return self.gpt5
        }
        return nil
    }

    /// Supported efforts with the generic fallback (`[low, medium, high]`) for unknown models.
    public static func supportedEfforts(modelID: String, compat: ModelCompatConfig?, api: ModelAPI?) -> [String] {
        self.modelSupportedEfforts(modelID: modelID, compat: compat, api: api) ?? self.generic
    }

    /// Whether the model accepts `temperature`: compat when declared, otherwise `false` for GPT-5.6
    /// and GPT-6 (except on Azure).
    public static func supportsTemperature(modelID: String, compat: ModelCompatConfig?, api: ModelAPI?) -> Bool {
        if let declared = compat?.supportsTemperature {
            return declared
        }
        let id = self.normalizedModelID(modelID)
        if self.isGPT6(id) {
            return api == .azureOpenAIResponses
        }
        return !self.matches(id, prefix: "gpt-5.6")
    }

    /// Whether the model id is a GPT-5.6 family id.
    static func isGPT56(_ modelID: String) -> Bool {
        self.matches(self.normalizedModelID(modelID), prefix: "gpt-5.6")
    }

    /// Whether the model id is a GPT-5.5 family id.
    static func isGPT55(_ modelID: String) -> Bool {
        self.matches(self.normalizedModelID(modelID), prefix: "gpt-5.5")
    }

    /// Whether the model id is a GPT-5.4 mini family id.
    static func isGPT54Mini(_ modelID: String) -> Bool {
        self.matches(self.normalizedModelID(modelID), prefix: "gpt-5.4-mini")
    }

    // MARK: - Internals

    private static func resolveEffort(
        requested: String,
        levelKey: String,
        model: ModelDefinitionConfig?,
        modelID: String,
        api: ModelAPI?,
        supported: [String]?
    ) -> String? {
        let levelMapping = model?.thinkingLevelMap?.mapping(for: levelKey) ?? .identity
        let effortMapped = self.mapping(requested, in: model?.compat?.reasoningEffortMap)
        let mapped: String?
        switch levelMapping {
        case .unsupported:
            return nil
        case .value(let value):
            mapped = effortMapped ?? value
        case .identity:
            mapped = effortMapped
        }
        let intent = mapped?.trimmingCharacters(in: .whitespacesAndNewlines) ?? requested
        guard let supported else {
            if mapped != nil {
                return intent
            }
            return requested == "off" ? "none" : requested
        }
        guard !supported.isEmpty else {
            return nil
        }
        let effort = self.clampToSupported(requested: requested, normalized: intent, supported: supported)
        if effort == "none", api == .openAIChatGPTResponses {
            let id = self.normalizedModelID(modelID)
            let routeSupportsNone = (id == "gpt-6-sol" || id == "gpt-6-luna")
                ? supported.contains("none")
                : (model?.compat?.supportedReasoningEfforts?.contains("none") ?? false)
            return routeSupportsNone ? effort : nil
        }
        return effort
    }

    private static func clampToSupported(requested: String, normalized: String, supported: [String]) -> String? {
        if supported.contains(normalized) {
            return normalized
        }
        if requested == "off", supported.contains("none") {
            return "none"
        }
        if self.isDisabled(requested) || self.isDisabled(normalized) {
            return nil
        }
        let ranked = self.enabledEfforts.filter { supported.contains($0) }
        if let requestedRank = self.enabledEfforts.firstIndex(of: normalized) {
            if let lower = ranked.last(where: { (self.enabledEfforts.firstIndex(of: $0) ?? 0) <= requestedRank }) {
                return lower
            }
            if let first = ranked.first {
                return first
            }
        }
        return supported.first(where: { !self.isDisabled(self.normalize($0)) })
    }

    private static func clampedLevel(_ level: ThinkLevel, map: ModelThinkingLevelMap?) -> ThinkLevel? {
        guard let map else { return level }
        let transport = level.providerTransportLevel
        guard map.mapping(for: transport) == .unsupported else {
            return level
        }
        let candidates: [ThinkLevel] = [.off, .minimal, .low, .medium, .high, .xhigh, .max]
        let allowed = candidates.filter { map.mapping(for: $0) != .unsupported }
        guard !allowed.isEmpty else { return nil }
        let rank = transport.rank
        if let lower = allowed.filter({ $0 != .off && $0.rank <= rank }).last {
            return lower
        }
        if let lowest = allowed.first(where: { $0 != .off }) {
            return lowest
        }
        return allowed.first
    }

    private static func mapping(_ effort: String, in map: [String: String]?) -> String? {
        guard let map else { return nil }
        if let direct = map[effort] {
            return direct
        }
        guard self.canonicalEfforts.contains(effort) else { return nil }
        return map.first(where: { self.normalize($0.key) == effort })?.value
    }

    private static func normalize(_ effort: String) -> String {
        let trimmed = effort.trimmingCharacters(in: .whitespacesAndNewlines)
        let folded = trimmed.lowercased()
        return self.canonicalEfforts.contains(folded) ? folded : trimmed
    }

    private static func isDisabled(_ effort: String) -> Bool {
        effort == "none" || effort == "off"
    }

    static func normalizedModelID(_ modelID: String) -> String {
        var id = modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let slash = id.lastIndex(of: "/") {
            id = String(id[id.index(after: slash)...])
        }
        // Strip a trailing -YYYY-MM-DD snapshot date.
        let scalars = Array(id)
        if scalars.count > 11 {
            let suffix = scalars.suffix(11)
            let pattern = Array(suffix)
            let isDate = pattern[0] == "-" && pattern[5] == "-" && pattern[8] == "-"
                && [1, 2, 3, 4, 6, 7, 9, 10].allSatisfy { pattern[$0].isNumber }
            if isDate {
                id = String(scalars.dropLast(11))
            }
        }
        return id
    }

    private static func matches(_ id: String, prefix: String) -> Bool {
        id == prefix || id.hasPrefix(prefix + "-")
    }

    private static func isGPT6(_ id: String) -> Bool {
        id == "gpt-6-astra" || id == "gpt-6-sol" || id == "gpt-6-luna"
    }

    /// `^gpt-5(\.\d+)?-codex(-|$)`.
    private static func isCodexFamily(_ id: String) -> Bool {
        guard id.hasPrefix("gpt-5") else { return false }
        var rest = id.dropFirst("gpt-5".count)
        if rest.first == "." {
            rest = rest.dropFirst()
            let digits = rest.prefix(while: \.isNumber)
            guard !digits.isEmpty else { return false }
            rest = rest.dropFirst(digits.count)
        }
        guard rest.hasPrefix("-codex") else { return false }
        let tail = rest.dropFirst("-codex".count)
        return tail.isEmpty || tail.first == "-"
    }

    /// `^gpt-5\.[minors](\.\d+)?<suffix>(-|$)`.
    private static func isMinorFamily(_ id: String, minors: String, suffix: String?) -> Bool {
        guard id.hasPrefix("gpt-5.") else { return false }
        var rest = id.dropFirst("gpt-5.".count)
        guard let minor = rest.first, minors.contains(minor) else { return false }
        rest = rest.dropFirst()
        if rest.first?.isNumber == true {
            return false
        }
        if rest.first == ".", rest.dropFirst().first?.isNumber == true {
            rest = rest.dropFirst()
            rest = rest.drop(while: \.isNumber)
        }
        if let suffix {
            guard rest.hasPrefix(suffix) else { return false }
            rest = rest.dropFirst(suffix.count)
        }
        return rest.isEmpty || rest.first == "-"
    }
}
