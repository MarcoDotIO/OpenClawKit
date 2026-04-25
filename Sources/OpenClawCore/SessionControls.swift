import Foundation

/// Thinking budget preference aligned with the OpenClaw session model.
public enum ThinkLevel: String, Sendable, Equatable, CaseIterable, Codable {
    case off
    case minimal
    case low
    case medium
    case high
    case xhigh
    case adaptive

    private static let xhighModelRefs: Set<String> = [
        "openai/gpt-5.5",
        "openai/gpt-5.4",
        "openai/gpt-5.4-pro",
        "openai/gpt-5.2",
        "openai-codex/gpt-5.5",
        "openai-codex/gpt-5.4",
        "openai-codex/gpt-5.3-codex",
        "openai-codex/gpt-5.3-codex-spark",
        "openai-codex/gpt-5.2-codex",
        "openai-codex/gpt-5.1-codex",
        "github-copilot/gpt-5.2-codex",
        "github-copilot/gpt-5.2",
    ]

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

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.rawValue)
    }

    /// Normalizes user-provided thinking strings to the canonical enum.
    public static func normalize(_ raw: String?) -> ThinkLevel? {
        guard let raw else { return nil }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return nil }
        let collapsed = key.replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
        if collapsed == "adaptive" || collapsed == "auto" {
            return .adaptive
        }
        if collapsed == "xhigh" || collapsed == "extrahigh" {
            return .xhigh
        }
        switch key {
        case "off":
            return .off
        case "on", "enable", "enabled":
            return .low
        case "min", "minimal", "think":
            return .minimal
        case "low", "thinkhard", "think-hard", "think_hard":
            return .low
        case "mid", "med", "medium", "thinkharder", "think-harder", "harder":
            return .medium
        case "high", "ultra", "ultrathink", "thinkhardest", "highest", "max":
            return .high
        default:
            return nil
        }
    }

    public static func supportsXHighThinking(providerID: String?, modelID: String?) -> Bool {
        let normalizedModel = modelID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let normalizedModel, !normalizedModel.isEmpty else { return false }
        let normalizedProvider = providerID?.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "z.ai", with: "zai")
            .replacingOccurrences(of: "z-ai", with: "zai")
        if let normalizedProvider, !normalizedProvider.isEmpty {
            return Self.xhighModelRefs.contains("\(normalizedProvider)/\(normalizedModel)")
        }
        return Self.xhighModelRefs.contains { $0.hasSuffix("/\(normalizedModel)") }
    }

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
