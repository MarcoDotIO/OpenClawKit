import Foundation
import OpenClawCore
import OpenClawProtocol

/// Claude model identity and capability contract (upstream
/// `packages/llm-core/src/model-contracts/anthropic.ts`).
///
/// The identity lowercases the id, strips an `anthropic/` prefix, replaces `.`, `_` and whitespace
/// with `-`, and keeps the last `claude-…` path component, so direct ids, Bedrock/Vertex profile ids
/// and gateway ids resolve to the same model. `params.canonicalModelId` overrides the id.
public struct ClaudeModelIdentity: Sendable, Equatable {
    /// Normalized identity (for example `claude-opus-5-5`).
    public let normalizedID: String

    /// Resolves the identity of a model reference.
    /// - Parameters:
    ///   - modelID: Model identifier.
    ///   - params: Optional model params (`canonicalModelId` overrides the id).
    public init(modelID: String, params: [String: AnyCodable]? = nil) {
        let configured = params?["canonicalModelId"]?.stringValue
        let normalized = Self.normalize(configured ?? modelID)
        self.normalizedID = Self.lastClaudeComponent(in: normalized) ?? normalized
    }

    /// Whether the id is Opus 5.5 (`claude-opus-5-5…` or alias `opus-5-5`).
    public var isOpus55: Bool {
        self.normalizedID == "opus-5-5" || Self.hasPrefixToken(self.normalizedID, "claude-opus-5-5")
    }

    /// Whether the id belongs to the Opus 5 family (Opus 5, Opus 5.5, aliases `opus` / `opus-5`).
    public var isOpus5: Bool {
        if self.isOpus55 {
            return true
        }
        if self.normalizedID == "opus" || self.normalizedID == "opus-5" {
            return true
        }
        return Self.containsToken(self.normalizedID, "claude-opus-5")
    }

    /// Whether the id is Sonnet 5.
    public var isSonnet5: Bool {
        Self.containsToken(self.normalizedID, "claude-sonnet-5")
    }

    /// Whether the id is Fable 5 (including 5.1).
    public var isFable5: Bool {
        Self.containsToken(self.normalizedID, "claude-fable-5")
    }

    /// Whether the id is Mythos 5.
    public var isMythos5: Bool {
        Self.containsToken(self.normalizedID, "claude-mythos-5")
    }

    /// Whether the model requires adaptive thinking (Opus 5.5, Fable 5, Mythos 5, Mythos preview).
    public var requiresMandatoryAdaptiveThinking: Bool {
        self.isOpus55 || self.isFable5 || self.isMythos5 || Self.containsToken(self.normalizedID, "claude-mythos-preview")
    }

    /// Whether the model supports adaptive thinking.
    public var supportsAdaptiveThinking: Bool {
        self.isOpus5 || self.matchesAny(["claude-fable-5", "claude-mythos-5", "claude-mythos-preview", "claude-opus-4-6",
                                         "claude-opus-4-7", "claude-opus-4-8", "claude-sonnet-5", "claude-sonnet-4-6"])
    }

    /// Whether the model has a native 1M-token context window.
    public var supports1MContext: Bool {
        self.supportsAdaptiveThinking
    }

    /// Whether the model supports Anthropic native fast mode (Opus 5 family, Opus 4.8).
    public var supportsFastMode: Bool {
        self.isOpus5 || Self.containsToken(self.normalizedID, "claude-opus-4-8")
    }

    /// Whether the legacy priority tier applies (every model except Opus 5 and Sonnet 5).
    public var supportsPriorityTier: Bool {
        !self.isOpus5 && !self.isSonnet5
    }

    /// Whether the model supports native `max` effort.
    public var supportsNativeMaxEffort: Bool {
        self.isOpus5 || self.matchesAny(["claude-fable-5", "claude-mythos-5", "claude-opus-4-6", "claude-opus-4-7",
                                         "claude-opus-4-8", "claude-sonnet-5", "claude-sonnet-4-6"])
    }

    /// Whether the model supports native `xhigh` effort.
    public var supportsNativeXhighEffort: Bool {
        self.isOpus5 || self.matchesAny(["claude-fable-5", "claude-mythos-5", "claude-opus-4-7", "claude-opus-4-8", "claude-sonnet-5"])
    }

    /// Whether the model rejects caller-selected sampling parameters (temperature, top_p, top_k).
    public var requiresDefaultSampling: Bool {
        self.supportsNativeXhighEffort || Self.containsToken(self.normalizedID, "claude-mythos-preview")
    }

    /// Default thinking level for models whose thinking is always on.
    public var defaultThinkingLevel: ThinkLevel? {
        if self.isOpus55 || self.isFable5 {
            return .medium
        }
        return nil
    }

    /// Native effort for a thinking level (upstream `resolveAnthropicThinkingEffort`).
    /// - Parameters:
    ///   - level: Thinking level (`nil` uses the model default).
    ///   - thinkingLevelMap: Optional per-model map.
    /// - Returns: Effort label (`low`, `medium`, `high`, `xhigh`, `max` or a provider-native value).
    public func effort(for level: ThinkLevel?, thinkingLevelMap: ModelThinkingLevelMap?) -> String {
        let requested = level ?? self.defaultThinkingLevel
        let map = thinkingLevelMap ?? self.nativeThinkingLevelMap
        var resolved = requested?.providerTransportLevel
        if let current = resolved, let map, map.mapping(for: current) == .unsupported {
            let order: [ThinkLevel] = [.minimal, .low, .medium, .high, .xhigh, .max]
            resolved = order.filter { $0.rank <= current.rank && map.mapping(for: $0) != .unsupported }.last ?? .high
        }
        if let resolved, let map, case .value(let mapped) = map.mapping(for: resolved) {
            return mapped
        }
        switch resolved {
        case .off?, .minimal?, .low?:
            return "low"
        case .medium?, .adaptive?:
            return "medium"
        case .xhigh?:
            return self.supportsNativeXhighEffort ? "xhigh" : "high"
        case .max?, .ultra?:
            return self.supportsNativeMaxEffort ? "max" : "high"
        case .high?, nil:
            return "high"
        }
    }

    /// Native map when the catalog does not publish one (`xhigh` null when unsupported, `max`).
    var nativeThinkingLevelMap: ModelThinkingLevelMap? {
        guard self.supportsNativeMaxEffort else { return nil }
        return ModelThinkingLevelMap([
            "xhigh": self.supportsNativeXhighEffort ? "xhigh" : nil,
            "max": "max",
        ])
    }

    private func matchesAny(_ tokens: [String]) -> Bool {
        tokens.contains { Self.containsToken(self.normalizedID, $0) }
    }

    static func normalize(_ modelID: String) -> String {
        var value = modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("anthropic/") {
            value.removeFirst("anthropic/".count)
        }
        var result = ""
        var previousWasSeparator = false
        for character in value {
            if character == "." || character == "_" || character.isWhitespace {
                if !previousWasSeparator {
                    result.append("-")
                }
                previousWasSeparator = true
            } else {
                result.append(character)
                previousWasSeparator = false
            }
        }
        return result
    }

    /// `(?:^|[-/])(claude-[^/]+)$`.
    private static func lastClaudeComponent(in normalized: String) -> String? {
        let lastComponent = normalized.split(separator: "/").last.map(String.init) ?? normalized
        guard let range = lastComponent.range(of: "claude-") else { return nil }
        // The match must start at the beginning or right after a dash.
        var searchStart = lastComponent.startIndex
        var candidate: Range<String.Index>? = range
        while let current = candidate {
            if current.lowerBound == lastComponent.startIndex || lastComponent[lastComponent.index(before: current.lowerBound)] == "-" {
                return String(lastComponent[current.lowerBound...])
            }
            searchStart = current.upperBound
            candidate = lastComponent.range(of: "claude-", range: searchStart..<lastComponent.endIndex)
        }
        return nil
    }

    /// `(?:^|-)token(?=$|[^a-z0-9])`.
    static func containsToken(_ normalized: String, _ token: String) -> Bool {
        var searchRange = normalized.startIndex..<normalized.endIndex
        while let range = normalized.range(of: token, range: searchRange) {
            let startsCleanly = range.lowerBound == normalized.startIndex
                || normalized[normalized.index(before: range.lowerBound)] == "-"
            let endsCleanly = range.upperBound == normalized.endIndex
                || !Self.isAlphanumeric(normalized[range.upperBound])
            if startsCleanly && endsCleanly {
                return true
            }
            searchRange = normalized.index(after: range.lowerBound)..<normalized.endIndex
        }
        return false
    }

    /// `^token(?=$|[^a-z0-9])`.
    private static func hasPrefixToken(_ normalized: String, _ token: String) -> Bool {
        guard normalized.hasPrefix(token) else { return false }
        let rest = normalized.dropFirst(token.count)
        guard let next = rest.first else { return true }
        return !Self.isAlphanumeric(next)
    }

    private static func isAlphanumeric(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber)
    }
}

/// Bedrock sampling contract: Opus 5, 4.8 and 4.7 (including region-prefixed profile ids) reject
/// `temperature`.
enum BedrockClaudeSamplingContract {
    private static let regionPrefixes = ["us.", "eu.", "ap.", "apac.", "au.", "jp.", "global."]

    static func rejectsTemperature(modelID: String) -> Bool {
        var id = modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in self.regionPrefixes where id.hasPrefix(prefix) {
            id.removeFirst(prefix.count)
            break
        }
        let identity = ClaudeModelIdentity(modelID: id)
        return identity.isOpus5
            || ClaudeModelIdentity.containsToken(identity.normalizedID, "claude-opus-4-8")
            || ClaudeModelIdentity.containsToken(identity.normalizedID, "claude-opus-4-7")
            || identity.requiresDefaultSampling
    }
}
