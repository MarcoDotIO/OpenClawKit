import Foundation

/// Thinking budget preference aligned with the OpenClaw session model.
///
/// Values and aliases follow upstream `ALL_THINKING_LEVELS` / `normalizeThinkLevel`
/// (`src/auto-reply/thinking.shared.ts`). `max` is a provider-native level; `ultra` is OpenClaw
/// runtime orchestration on top of `max` and is never sent to a provider transport (see
/// ``providerTransportLevel``).
///
/// - Note: 2026.3.0 added `max` and `ultra`. Exhaustive `switch` statements over `ThinkLevel`
///   in client code need the new cases (or an `@unknown default`-style fallback `default:`).
public enum ThinkLevel: String, Sendable, Equatable, CaseIterable, Codable {
    /// Thinking disabled. `none` normalizes here.
    case off
    /// Minimal thinking budget.
    case minimal
    /// Low thinking budget.
    case low
    /// Medium thinking budget.
    case medium
    /// High thinking budget.
    case high
    /// Extra-high thinking budget for models that declare it.
    case xhigh
    /// Provider-chosen adaptive thinking.
    case adaptive
    /// Maximum provider-native thinking budget for models that declare it.
    case max
    /// OpenClaw runtime orchestration above `max`; provider transports receive `max`.
    case ultra

    private static let xhighModelRefs: Set<String> = [
        "openai/gpt-6-astra",
        "openai/gpt-6-sol",
        "openai/gpt-6-luna",
        "openai/gpt-5.6-sol",
        "openai/gpt-5.6-terra",
        "openai/gpt-5.6-luna",
        "openai/gpt-5.5",
        "openai/gpt-5.4",
        "openai/gpt-5.4-pro",
        "openai/gpt-5.3-codex",
        "openai/gpt-5.3-codex-spark",
        "openai/gpt-5.2",
        "openai/gpt-5.2-codex",
        "openai/gpt-5.1-codex",
        "github-copilot/gpt-5.2-codex",
        "github-copilot/gpt-5.2",
    ]

    /// Legacy provider identifiers that resolve to a canonical provider for thinking support.
    private static let providerAliases: [String: String] = [
        "openai-codex": "openai",
    ]

    /// Decodes a thinking level, accepting every alias handled by ``normalize(_:)``.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let normalized = Self.normalize(raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ThinkLevel value: \(raw)"
            )
        }
        self = normalized
    }

    /// Encodes the canonical raw value.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.rawValue)
    }

    /// Ordering rank used to compare and clamp levels (upstream `THINKING_LEVEL_RANKS`).
    ///
    /// `adaptive` shares the `medium` rank.
    public var rank: Int {
        switch self {
        case .off:
            return 0
        case .minimal:
            return 10
        case .low:
            return 20
        case .medium, .adaptive:
            return 30
        case .high:
            return 40
        case .xhigh:
            return 60
        case .max:
            return 70
        case .ultra:
            return 80
        }
    }

    /// Level forwarded to provider transports.
    ///
    /// `ultra` is runtime orchestration only, so providers receive `max`; every other level is
    /// forwarded unchanged.
    public var providerTransportLevel: ThinkLevel {
        self == .ultra ? .max : self
    }

    /// Clamps this level to the closest level a model supports.
    ///
    /// Ports upstream `resolveSupportedThinkingLevelFromProfile`: a supported level is returned as-is;
    /// `adaptive` falls back to a non-off `defaultLevel`; otherwise the highest supported non-off level
    /// ranked at or below this level wins, then the lowest supported non-off level, then `off`.
    /// - Parameters:
    ///   - supported: Levels the model supports.
    ///   - defaultLevel: Optional model default used when `adaptive` is not supported.
    /// - Returns: The supported level to use.
    public func clamped(toSupported supported: [ThinkLevel], defaultLevel: ThinkLevel? = nil) -> ThinkLevel {
        if supported.contains(self) {
            return self
        }
        if self == .adaptive, let defaultLevel, defaultLevel != .off {
            return defaultLevel
        }
        let ranked = supported.enumerated()
            .sorted { lhs, rhs in
                lhs.element.rank == rhs.element.rank ? lhs.offset < rhs.offset : lhs.element.rank > rhs.element.rank
            }
            .map(\.element)
        if let match = ranked.first(where: { $0 != .off && $0.rank <= self.rank }) {
            return match
        }
        return ranked.last(where: { $0 != .off }) ?? .off
    }

    /// Normalizes user-provided thinking strings to the canonical enum.
    ///
    /// Mirrors upstream `normalizeThinkLevel`: whitespace, `_` and `-` are collapsed for the
    /// `adaptive`/`auto`, `max`, `ultra` and `xhigh`/`extrahigh` checks; the remaining aliases match
    /// the trimmed, lowercased value. `none` maps to `off`.
    /// - Parameter raw: Raw user or wire value.
    /// - Returns: Canonical level, or `nil` when the value is empty or unknown.
    public static func normalize(_ raw: String?) -> ThinkLevel? {
        guard let raw else { return nil }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return nil }
        let collapsed = String(
            String.UnicodeScalarView(
                key.unicodeScalars.filter { scalar in
                    scalar != "_" && scalar != "-" && !CharacterSet.whitespacesAndNewlines.contains(scalar)
                }
            )
        )
        switch collapsed {
        case "adaptive", "auto":
            return .adaptive
        case "max":
            return .max
        case "ultra":
            return .ultra
        case "xhigh", "extrahigh":
            return .xhigh
        default:
            break
        }
        switch key {
        case "off", "none":
            return .off
        case "on", "enable", "enabled":
            return .low
        case "min", "minimal":
            return .minimal
        case "low", "thinkhard", "think-hard", "think_hard":
            return .low
        case "mid", "med", "medium", "thinkharder", "think-harder", "harder":
            return .medium
        case "high", "ultrathink", "thinkhardest", "highest":
            return .high
        case "think":
            return .minimal
        default:
            return nil
        }
    }

    /// Returns whether a provider/model pair is known to support `xhigh` thinking.
    ///
    /// This is the static fallback used when no catalog thinking profile is available. The legacy
    /// `openai-codex` provider id resolves to `openai`.
    /// - Parameters:
    ///   - providerID: Optional provider identifier. When omitted, any provider with the model matches.
    ///   - modelID: Model identifier.
    /// - Returns: `true` when the model is known to support `xhigh`.
    public static func supportsXHighThinking(providerID: String?, modelID: String?) -> Bool {
        let normalizedModel = modelID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let normalizedModel, !normalizedModel.isEmpty else { return false }
        let normalizedProvider = providerID?.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "z.ai", with: "zai")
            .replacingOccurrences(of: "z-ai", with: "zai")
        if let normalizedProvider, !normalizedProvider.isEmpty {
            let canonicalProvider = Self.providerAliases[normalizedProvider] ?? normalizedProvider
            return Self.xhighModelRefs.contains("\(canonicalProvider)/\(normalizedModel)")
        }
        return Self.xhighModelRefs.contains { $0.hasSuffix("/\(normalizedModel)") }
    }

    /// Returns the static fallback list of levels offered for a provider/model pair.
    ///
    /// `max` and `ultra` are never included here: they are only offered when a catalog thinking
    /// profile declares them for the model.
    /// - Parameters:
    ///   - providerID: Optional provider identifier.
    ///   - modelID: Model identifier.
    /// - Returns: Supported levels in display order.
    public static func supportedLevels(providerID: String?, modelID: String?) -> [ThinkLevel] {
        var levels: [ThinkLevel] = [.off, .minimal, .low, .medium, .high]
        if Self.supportsXHighThinking(providerID: providerID, modelID: modelID) {
            levels.append(.xhigh)
        }
        levels.append(.adaptive)
        return levels
    }
}

/// Verbosity level used for session-oriented runtime output controls.
public enum VerboseLevel: String, Sendable, Equatable, CaseIterable, Codable {
    case off
    case on
    case full

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let normalized = Self.normalize(raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid VerboseLevel value: \(raw)"
            )
        }
        self = normalized
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.rawValue)
    }

    public static func normalize(_ raw: String?) -> VerboseLevel? {
        guard let raw else { return nil }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "off", "false", "no", "0":
            return .off
        case "full", "all", "everything":
            return .full
        case "on", "true", "yes", "1", "minimal":
            return .on
        default:
            return nil
        }
    }
}

/// Controls whether provider reasoning is hidden, included, or streamed.
public enum ReasoningLevel: String, Sendable, Equatable, CaseIterable, Codable {
    case off
    case on
    case stream

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let normalized = Self.normalize(raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ReasoningLevel value: \(raw)"
            )
        }
        self = normalized
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.rawValue)
    }

    public static func normalize(_ raw: String?) -> ReasoningLevel? {
        guard let raw else { return nil }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "off", "false", "no", "0", "hide", "hidden", "disable", "disabled":
            return .off
        case "on", "true", "yes", "1", "show", "visible", "enable", "enabled":
            return .on
        case "stream", "streaming", "draft", "live":
            return .stream
        default:
            return nil
        }
    }
}

/// Controls per-response usage display semantics.
public enum UsageDisplayLevel: String, Sendable, Equatable, CaseIterable, Codable {
    case off
    case tokens
    case full

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let normalized = Self.normalize(raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid UsageDisplayLevel value: \(raw)"
            )
        }
        self = normalized
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.rawValue)
    }

    public static func normalize(_ raw: String?) -> UsageDisplayLevel? {
        guard let raw else { return nil }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "off", "false", "no", "0", "disable", "disabled":
            return .off
        case "on", "true", "yes", "1", "tokens", "token", "tok", "minimal", "min":
            return .tokens
        case "full", "session":
            return .full
        default:
            return nil
        }
    }
}

/// Controls whether elevated execution is disabled, allowed, or auto-approved.
public enum ElevatedLevel: String, Sendable, Equatable, CaseIterable, Codable {
    case off
    case on
    case ask
    case full

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let normalized = Self.normalize(raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ElevatedLevel value: \(raw)"
            )
        }
        self = normalized
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.rawValue)
    }

    public static func normalize(_ raw: String?) -> ElevatedLevel? {
        guard let raw else { return nil }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "off", "false", "no", "0":
            return .off
        case "full", "auto", "auto-approve", "autoapprove":
            return .full
        case "ask", "prompt", "approval", "approve":
            return .ask
        case "on", "true", "yes", "1":
            return .on
        default:
            return nil
        }
    }
}

/// Controls whether automatic outbound sends are allowed for the session.
public enum SendPolicy: String, Sendable, Equatable, CaseIterable, Codable {
    case allow
    case deny
}

/// Controls group-trigger activation rules.
public enum GroupActivation: String, Sendable, Equatable, CaseIterable, Codable {
    case mention
    case always
}

/// Preferred execution host for shell/process work.
public enum ExecHost: String, Sendable, Equatable, CaseIterable, Codable {
    case sandbox
    case gateway
    case node
}

/// Execution security mode for command dispatch.
public enum ExecSecurity: String, Sendable, Equatable, CaseIterable, Codable {
    case deny
    case allowlist
    case full
}

/// Interactive approval behavior for command dispatch.
public enum ExecAsk: String, Sendable, Equatable, CaseIterable, Codable {
    case off = "off"
    case onMiss = "on-miss"
    case always = "always"
}

/// Session controls resolved from persisted state and agent defaults.
public struct ResolvedSessionState: Sendable, Equatable {
    public let key: String
    public let agentID: String
    public let updatedAtMs: Int
    public let lastRoute: SessionRoute?
    public let label: String?
    public let modelOverride: String?
    public let thinkingLevel: ThinkLevel?
    public let verboseLevel: VerboseLevel?
    public let reasoningLevel: ReasoningLevel?
    public let responseUsage: UsageDisplayLevel?
    public let elevatedLevel: ElevatedLevel?
    public let groupActivation: GroupActivation?
    public let groupActivationNeedsSystemIntro: Bool
    public let sendPolicy: SendPolicy?
    public let execHost: ExecHost?
    public let execSecurity: ExecSecurity?
    public let execAsk: ExecAsk?
    public let execNode: String?

    public var providerOverrideID: String? {
        guard let modelOverride else { return nil }
        let components = modelOverride.split(separator: "/", maxSplits: 1).map(String.init)
        guard components.count == 2 else { return nil }
        let providerID = components[0].trimmingCharacters(in: .whitespacesAndNewlines)
        return providerID.isEmpty ? nil : providerID
    }

    public var modelOverrideID: String? {
        guard let modelOverride else { return nil }
        let components = modelOverride.split(separator: "/", maxSplits: 1).map(String.init)
        if components.count == 2 {
            let modelID = components[1].trimmingCharacters(in: .whitespacesAndNewlines)
            return modelID.isEmpty ? nil : modelID
        }
        let trimmed = modelOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension SessionRecord {
    mutating func applyDefaults(from defaults: AgentsConfig) {
        if self.thinkingLevel == nil {
            self.thinkingLevel = defaults.thinkingLevel
        }
        if self.verboseLevel == nil {
            self.verboseLevel = defaults.verboseLevel
        }
        if self.reasoningLevel == nil {
            self.reasoningLevel = defaults.reasoningLevel
        }
        if self.responseUsage == nil {
            self.responseUsage = defaults.responseUsage
        }
        if self.elevatedLevel == nil {
            self.elevatedLevel = defaults.elevatedLevel
        }
        if self.groupActivation == nil {
            self.groupActivation = defaults.groupActivation
        }
        if self.sendPolicy == nil {
            self.sendPolicy = defaults.sendPolicy
        }
        if self.modelOverride == nil {
            self.modelOverride = defaults.modelOverride
        }
        if self.execHost == nil {
            self.execHost = defaults.execHost
        }
        if self.execSecurity == nil {
            self.execSecurity = defaults.execSecurity
        }
        if self.execAsk == nil {
            self.execAsk = defaults.execAsk
        }
        if self.execNode == nil {
            self.execNode = defaults.execNode
        }
    }

    /// Resolves the effective session controls by applying agent defaults.
    public func resolved(using defaults: AgentsConfig) -> ResolvedSessionState {
        ResolvedSessionState(
            key: self.key,
            agentID: self.agentID,
            updatedAtMs: self.updatedAtMs,
            lastRoute: self.lastRoute,
            label: self.label,
            modelOverride: self.modelOverride ?? defaults.modelOverride,
            thinkingLevel: self.thinkingLevel ?? defaults.thinkingLevel,
            verboseLevel: self.verboseLevel ?? defaults.verboseLevel,
            reasoningLevel: self.reasoningLevel ?? defaults.reasoningLevel,
            responseUsage: self.responseUsage ?? defaults.responseUsage,
            elevatedLevel: self.elevatedLevel ?? defaults.elevatedLevel,
            groupActivation: self.groupActivation ?? defaults.groupActivation,
            groupActivationNeedsSystemIntro: defaults.groupActivationNeedsSystemIntro,
            sendPolicy: self.sendPolicy ?? defaults.sendPolicy,
            execHost: self.execHost ?? defaults.execHost,
            execSecurity: self.execSecurity ?? defaults.execSecurity,
            execAsk: self.execAsk ?? defaults.execAsk,
            execNode: self.execNode ?? defaults.execNode
        )
    }
}
