import Foundation
import OpenClawProtocol

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
///
/// Mirrors upstream `ExecTarget` (`auto | sandbox | gateway | node`). `auto` lets the runtime pick
/// the host.
///
/// - Note: 2026.3.0 added `auto`. Exhaustive `switch` statements over `ExecHost` need the new case.
public enum ExecHost: String, Sendable, Equatable, CaseIterable, Codable {
    /// Run in the agent sandbox.
    case sandbox
    /// Run on the gateway host.
    case gateway
    /// Run on a paired node.
    case node
    /// Let the runtime choose the host.
    case auto
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

/// Security/ask pair (plus auto-review flag) that an ``ExecMode`` expands to.
public struct ExecModePolicy: Sendable, Equatable {
    /// Command security mode.
    public var security: ExecSecurity
    /// Interactive approval behavior.
    public var ask: ExecAsk
    /// Whether approvals are routed through automatic review first.
    public var autoReview: Bool

    /// Creates an exec policy triple.
    /// - Parameters:
    ///   - security: Command security mode.
    ///   - ask: Interactive approval behavior.
    ///   - autoReview: Whether approvals are routed through automatic review first.
    public init(security: ExecSecurity, ask: ExecAsk, autoReview: Bool = false) {
        self.security = security
        self.ask = ask
        self.autoReview = autoReview
    }
}

/// Canonical exec approval mode (upstream `tools.exec.mode`, `src/infra/exec-approvals-core.ts`).
///
/// A mode is a display projection of an ``ExecSecurity``/``ExecAsk`` pair; ``policy`` expands it
/// and ``from(security:ask:)`` / ``exact(security:ask:)`` project a pair back to a mode.
public enum ExecMode: String, Sendable, Equatable, CaseIterable, Codable {
    /// Deny every command.
    case deny
    /// Run allowlisted commands without prompting.
    case allowlist
    /// Run allowlisted commands and ask on a miss.
    case ask
    /// Like `ask`, with automatic review before prompting.
    case auto
    /// Run every command without prompting.
    case full

    /// Decodes a mode, accepting surrounding whitespace and any casing.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let mode = Self.normalize(raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ExecMode value: \(raw)"
            )
        }
        self = mode
    }

    /// Normalizes a raw mode string (upstream `normalizeExecMode`).
    /// - Parameter raw: Raw user or config value.
    /// - Returns: Canonical mode, or `nil` when unknown.
    public static func normalize(_ raw: String?) -> ExecMode? {
        guard let raw else { return nil }
        return ExecMode(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// Projects a security/ask pair onto the closest mode (upstream `resolveExecModeFromPolicy`).
    /// - Parameters:
    ///   - security: Command security mode.
    ///   - ask: Interactive approval behavior.
    /// - Returns: The display mode for the pair.
    public static func from(security: ExecSecurity, ask: ExecAsk) -> ExecMode {
        if security == .deny {
            return .deny
        }
        if security == .allowlist && ask == .off {
            return .allowlist
        }
        if security == .full && ask != .always {
            return .full
        }
        return .ask
    }

    /// Projects a pair onto a mode only when the mode preserves it exactly
    /// (upstream `resolveExactExecModeFromPolicy`).
    ///
    /// Returns `nil` for pairs that no mode expresses: `ask == .always`, and `full` with `on-miss`.
    /// - Parameters:
    ///   - security: Command security mode.
    ///   - ask: Interactive approval behavior.
    /// - Returns: The exact mode, or `nil`.
    public static func exact(security: ExecSecurity, ask: ExecAsk) -> ExecMode? {
        if ask == .always || (security == .full && ask == .onMiss) {
            return nil
        }
        return Self.from(security: security, ask: ask)
    }

    /// Security/ask pair this mode expands to (upstream `resolveExecPolicyForMode`).
    public var policy: ExecModePolicy {
        switch self {
        case .deny:
            return ExecModePolicy(security: .deny, ask: .off)
        case .allowlist:
            return ExecModePolicy(security: .allowlist, ask: .off)
        case .ask:
            return ExecModePolicy(security: .allowlist, ask: .onMiss)
        case .auto:
            return ExecModePolicy(security: .allowlist, ask: .onMiss, autoReview: true)
        case .full:
            return ExecModePolicy(security: .full, ask: .off)
        }
    }
}

/// Trace output level for a session (upstream `TraceLevel`, `src/auto-reply/thinking.shared.ts`).
public enum TraceLevel: String, Sendable, Equatable, CaseIterable, Codable {
    /// Tracing disabled.
    case off
    /// Filtered trace output.
    case on
    /// Unfiltered trace output.
    case raw

    /// Decodes a trace level, accepting every alias handled by ``normalize(_:)``.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let normalized = Self.normalize(raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid TraceLevel value: \(raw)")
        }
        self = normalized
    }

    /// Encodes the canonical raw value.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.rawValue)
    }

    /// Normalizes a raw trace level (upstream `normalizeTraceLevel`).
    /// - Parameter raw: Raw user or wire value.
    /// - Returns: Canonical level, or `nil` when empty or unknown.
    public static func normalize(_ raw: String?) -> TraceLevel? {
        guard let raw else { return nil }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "off", "false", "no", "0":
            return .off
        case "on", "true", "yes", "1":
            return .on
        case "raw", "unfiltered":
            return .raw
        default:
            return nil
        }
    }
}

/// Session permission mode helpers (the enum itself is the generated protocol type
/// `OpenClawProtocol.SessionPermissionMode`, upstream `SessionPermissionModeSchema`; see
/// `docs/gateway/permission-modes.md`).
///
/// A mode sets one session's filesystem boundary and exec escalation reviewer:
/// - `read-only`: reads under the session root; managed mutation tools are omitted; exec is denied.
/// - `guarded`: reads and writes under the session root; a human reviews exec after the allowlist fast path.
/// - `workspace`: reads and writes under the session root; an LLM reviewer answers allow/deny/ask; a
///   reviewer denial goes back to the agent without a human approval card.
/// - `full`: unrestricted; setting it requires `operator.admin` (the other modes need `operator.write`).
///
/// `nil` on a session means "Default": the configured global or per-agent exec policy applies.
///
/// - Note: 2026.3.0 replaces the retired session `execSecurity`/`execAsk` overrides with this mode.
public extension SessionPermissionMode {
    /// Every mode, most restrictive first.
    static let supportedModes: [SessionPermissionMode] = [.readOnly, .guarded, .workspace, .full]

    /// Normalizes a raw mode string.
    /// - Parameter raw: Raw user or wire value.
    /// - Returns: Canonical mode, or `nil` when unknown.
    static func normalize(_ raw: String?) -> SessionPermissionMode? {
        guard let raw else { return nil }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "_", with: "-")
        if key == "readonly" {
            return .readOnly
        }
        return SessionPermissionMode(rawValue: key)
    }

    /// Operator scope required to select this mode (`operator.admin` for `full`, else `operator.write`).
    var requiredScope: String {
        self == .full ? "operator.admin" : "operator.write"
    }

    /// Exec mode this permission mode projects to (upstream `EXEC_MODE_BY_PERMISSION_MODE`).
    var execMode: ExecMode {
        switch self {
        case .readOnly:
            return .deny
        case .guarded:
            return .ask
        case .workspace:
            return .auto
        case .full:
            return .full
        }
    }

    /// Whether file tools are confined to the session root (every mode except `full`).
    var isWorkspaceOnly: Bool {
        self != .full
    }

    /// Whether managed mutation tools (write, edit, apply_patch, exec, process) are omitted.
    var isReadOnly: Bool {
        self == .readOnly
    }

    /// Permission mode for an exec mode (upstream `SESSION_PERMISSION_BY_EXEC_MODE`).
    /// - Parameter mode: Exec mode.
    /// - Returns: The matching permission mode.
    static func from(execMode mode: ExecMode) -> SessionPermissionMode {
        switch mode {
        case .deny:
            return .readOnly
        case .allowlist, .ask:
            return .guarded
        case .auto:
            return .workspace
        case .full:
            return .full
        }
    }

    /// Migrates a retired session `execSecurity`/`execAsk` override (upstream
    /// `repairLegacySessionExecPolicy`).
    ///
    /// Missing values inherit the stricter base (`deny` for sandbox hosts, `full` otherwise, ask `off`).
    /// `ask == always` has no mode equivalent and retires to `read-only`; a full-access policy is
    /// never converted into a `full` grant (returns `nil`, so configuration applies).
    /// - Parameters:
    ///   - security: Legacy session security override.
    ///   - ask: Legacy session ask override.
    ///   - execHost: Session exec host, used to pick the base security.
    /// - Returns: The migrated mode, or `nil` when the configured default should apply.
    static func migratingLegacyExecPolicy(
        security: ExecSecurity?,
        ask: ExecAsk?,
        execHost: ExecHost? = nil
    ) -> SessionPermissionMode? {
        guard security != nil || ask != nil else {
            return nil
        }
        let baseSecurity: ExecSecurity = execHost == .sandbox ? .deny : .full
        let resolvedAsk = ask ?? .off
        if resolvedAsk == .always {
            return .readOnly
        }
        let mode = ExecMode.from(security: security ?? baseSecurity, ask: resolvedAsk)
        return mode == .full ? nil : Self.from(execMode: mode)
    }
}

/// Fast-mode preference for a session: on, off, or provider-chosen `auto` (upstream `FastMode`).
///
/// Wire shape: `true`, `false` or `"auto"`; decoding also accepts the upstream string aliases.
public enum FastModeSetting: String, Sendable, Equatable, CaseIterable, Codable {
    /// Fast mode enabled.
    case on
    /// Fast mode disabled.
    case off
    /// The runtime decides per request.
    case auto

    /// Boolean projection: `true`/`false` for on/off, `nil` for `auto`.
    public var boolValue: Bool? {
        switch self {
        case .on:
            return true
        case .off:
            return false
        case .auto:
            return nil
        }
    }

    /// Creates a setting from a boolean.
    /// - Parameter value: `true` for on, `false` for off.
    public init(_ value: Bool) {
        self = value ? .on : .off
    }

    /// Normalizes a raw string (upstream `normalizeFastMode`).
    /// - Parameter raw: Raw user or wire value.
    /// - Returns: The setting, or `nil` when unknown.
    public static func normalize(_ raw: String?) -> FastModeSetting? {
        guard let raw else { return nil }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "off", "false", "no", "0", "disable", "disabled", "normal":
            return .off
        case "on", "true", "yes", "1", "enable", "enabled", "fast":
            return .on
        case "auto", "automatic":
            return .auto
        default:
            return nil
        }
    }

    /// Decodes a boolean or a string alias.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let flag = try? container.decode(Bool.self) {
            self.init(flag)
            return
        }
        let raw = try container.decode(String.self)
        guard let setting = Self.normalize(raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid fastMode value: \(raw)")
        }
        self = setting
    }

    /// Encodes `true`, `false` or `"auto"`.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .on:
            try container.encode(true)
        case .off:
            try container.encode(false)
        case .auto:
            try container.encode("auto")
        }
    }
}

/// Sparse per-session tool policy overlay (upstream `SessionToolOverridesSchema`).
///
/// Patches replace the overlay atomically; ``normalized()`` sorts and de-duplicates entries, drops
/// empty maps, and keeps `webSearch` only when it disables web search (upstream
/// `normalizeSessionToolOverrides`).
public struct SessionToolOverrides: Codable, Sendable, Equatable, Hashable {
    /// MCP servers enabled (`true`) or disabled (`false`) for the session.
    public var mcpServers: [String: Bool]?
    /// MCP tool names denied per server.
    public var mcpToolsDeny: [String: [String]]?
    /// Skills enabled or disabled for the session.
    public var skills: [String: Bool]?
    /// `false` disables web search for the session.
    public var webSearch: Bool?

    /// Creates a tool overlay.
    /// - Parameters:
    ///   - mcpServers: MCP server toggles.
    ///   - mcpToolsDeny: Denied MCP tools per server.
    ///   - skills: Skill toggles.
    ///   - webSearch: `false` disables web search.
    public init(
        mcpServers: [String: Bool]? = nil,
        mcpToolsDeny: [String: [String]]? = nil,
        skills: [String: Bool]? = nil,
        webSearch: Bool? = nil
    ) {
        self.mcpServers = mcpServers
        self.mcpToolsDeny = mcpToolsDeny
        self.skills = skills
        self.webSearch = webSearch
    }

    /// Whether the overlay changes nothing.
    public var isEmpty: Bool {
        self.normalized() == nil
    }

    /// Canonical stored form, or `nil` when the overlay is empty.
    /// - Returns: The normalized overlay.
    public func normalized() -> SessionToolOverrides? {
        let servers = self.mcpServers.flatMap { $0.isEmpty ? nil : $0 }
        let skills = self.skills.flatMap { $0.isEmpty ? nil : $0 }
        var deny: [String: [String]] = [:]
        for (server, tools) in self.mcpToolsDeny ?? [:] {
            let unique = Array(Set(tools.filter { !$0.isEmpty })).sorted()
            if !server.isEmpty, !unique.isEmpty {
                deny[server] = unique
            }
        }
        let result = SessionToolOverrides(
            mcpServers: servers,
            mcpToolsDeny: deny.isEmpty ? nil : deny,
            skills: skills,
            webSearch: self.webSearch == false ? false : nil
        )
        if result.mcpServers == nil, result.mcpToolsDeny == nil, result.skills == nil, result.webSearch == nil {
            return nil
        }
        return result
    }

    /// Whether the overlay denies an MCP tool (server disabled or tool listed in `mcpToolsDeny`).
    /// - Parameters:
    ///   - server: MCP server name.
    ///   - tool: MCP tool name.
    /// - Returns: `true` when the tool is denied.
    public func deniesMCPTool(server: String, tool: String) -> Bool {
        if self.mcpServers?[server] == false {
            return true
        }
        return self.mcpToolsDeny?[server]?.contains(tool) == true
    }
}

/// Session controls resolved from persisted state and agent defaults.
public struct ResolvedSessionState: Sendable, Equatable {
    public let key: String
    public let agentID: String
    public let updatedAtMs: Int64
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
    /// Session permission mode (`nil` = configured default).
    public var permissionMode: SessionPermissionMode? = nil
    /// Session trace level.
    public var traceLevel: TraceLevel? = nil
    /// Session tool overlay.
    public var toolOverrides: SessionToolOverrides? = nil

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
        // Exec security/ask stay configuration-level policy (see `resolved(using:)`); session
        // records no longer carry them.
        if self.execNode == nil {
            self.execNode = defaults.execNode
        }
    }

    /// Resolves the effective session controls by applying agent defaults.
    public func resolved(using defaults: AgentsConfig) -> ResolvedSessionState {
        var state = ResolvedSessionState(
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
        state.permissionMode = self.permissionMode
        state.traceLevel = self.traceLevel
        state.toolOverrides = self.toolOverrides
        return state
    }
}
