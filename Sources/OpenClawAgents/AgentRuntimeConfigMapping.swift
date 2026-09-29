import Foundation
import OpenClawCore
import OpenClawModels
import OpenClawProtocol

// Config → runtime mapping for the embedded agent runtime. The helpers read the upstream JSON shape of
// an `OpenClawConfigDocument` (through its encoded form, so sections that are typed later keep
// working) and produce the runtime types this module owns. `OpenClawConfig` callers go through
// `documentProjection()`.

/// JSON view of an encoded config document with dotted-path lookups.
struct ConfigDocumentJSON: Sendable {
    let root: [String: AnyCodable]

    init(_ document: OpenClawConfigDocument) {
        self.root = (try? AnyCodable(encoding: document))?.dictionaryValue ?? [:]
    }

    /// Value at a path of object keys.
    func value(_ path: [String]) -> AnyCodable? {
        var current: AnyCodable? = AnyCodable(self.root)
        for key in path {
            guard let object = current?.dictionaryValue else { return nil }
            current = object[key]
        }
        guard let current, !current.isNull else { return nil }
        return current
    }

    /// Object at a path.
    func object(_ path: [String]) -> [String: AnyCodable]? {
        self.value(path)?.dictionaryValue
    }

    /// Decodes a value at a path.
    func decode<Value: Decodable>(_ type: Value.Type, at path: [String]) -> Value? {
        guard let value = self.value(path), let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// `agents.entries.<agentID>` path prefix (case-insensitive id match).
    func agentPath(_ agentID: String?) -> [String]? {
        guard let agentID = agentID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !agentID.isEmpty,
              let entries = self.object(["agents", "entries"])
        else {
            return nil
        }
        guard let key = entries.keys.first(where: { $0.lowercased() == agentID }) else { return nil }
        return ["agents", "entries", key]
    }

    /// Agent override first, then the root/defaults value.
    func layered(_ agentID: String?, agentPath suffix: [String], rootPath: [String]) -> AnyCodable? {
        if let prefix = self.agentPath(agentID), let value = self.value(prefix + suffix) {
            return value
        }
        return self.value(rootPath)
    }
}

public extension ToolPolicy {
    /// Tool policy from `tools.profile/allow/alsoAllow/deny`, with `agents.entries.<id>.tools` fields
    /// overriding the root fields they set.
    /// - Parameters:
    ///   - document: Config document.
    ///   - agentID: Agent whose overrides apply.
    /// - Returns: The policy (``allowAll`` when nothing is configured).
    static func resolve(from document: OpenClawConfigDocument, agentID: String? = nil) -> ToolPolicy {
        Self.resolve(from: ConfigDocumentJSON(document), agentID: agentID)
    }

    internal static func resolve(from json: ConfigDocumentJSON, agentID: String?) -> ToolPolicy {
        var raw: [String: AnyCodable] = [:]
        for key in ["profile", "allow", "alsoAllow", "deny"] {
            if let value = json.layered(agentID, agentPath: ["tools", key], rootPath: ["tools", key]) {
                raw[key] = value
            }
        }
        guard !raw.isEmpty, let data = try? JSONEncoder().encode(AnyCodable(raw)) else { return .allowAll }
        return (try? JSONDecoder().decode(ToolPolicy.self, from: data)) ?? .allowAll
    }
}

public extension AgentLoopDetectionConfiguration {
    /// Loop detection from `tools.loopDetection` (upstream only defines `enabled`; SDK `threshold` and
    /// `window` keys are honored when present), agent override first.
    /// - Parameters:
    ///   - document: Config document.
    ///   - agentID: Agent whose overrides apply.
    /// - Returns: The configuration.
    static func resolve(from document: OpenClawConfigDocument, agentID: String? = nil) -> AgentLoopDetectionConfiguration {
        Self.resolve(from: ConfigDocumentJSON(document), agentID: agentID)
    }

    internal static func resolve(from json: ConfigDocumentJSON, agentID: String?) -> AgentLoopDetectionConfiguration {
        guard let object = json.layered(agentID, agentPath: ["tools", "loopDetection"], rootPath: ["tools", "loopDetection"])?.dictionaryValue else {
            return AgentLoopDetectionConfiguration()
        }
        let defaults = AgentLoopDetectionConfiguration()
        return AgentLoopDetectionConfiguration(
            enabled: object["enabled"]?.boolValue ?? false,
            threshold: object["threshold"]?.intValue ?? defaults.threshold,
            window: object["window"]?.intValue ?? defaults.window
        )
    }
}

public extension ToolSearchConfiguration {
    /// Tool Search from `tools.toolSearch` (`true`, `false` or an object), agent override first; unset
    /// keeps the embedded default.
    /// - Parameters:
    ///   - document: Config document.
    ///   - agentID: Agent whose overrides apply.
    /// - Returns: The configuration.
    static func resolve(from document: OpenClawConfigDocument, agentID: String? = nil) -> ToolSearchConfiguration {
        Self.resolve(json: ConfigDocumentJSON(document), agentID: agentID)
    }

    internal static func resolve(json: ConfigDocumentJSON, agentID: String?) -> ToolSearchConfiguration {
        Self.resolve(json.layered(agentID, agentPath: ["tools", "toolSearch"], rootPath: ["tools", "toolSearch"]))
    }
}

public extension ContextCompactionSettings {
    /// Compaction settings from `agents.defaults.compaction` (`enabled`, `keepRecentTokens`, `model`;
    /// the SDK `reserveTokens` key is honored when present).
    /// - Parameter document: Config document.
    /// - Returns: The settings.
    static func resolve(from document: OpenClawConfigDocument) -> ContextCompactionSettings {
        Self.resolve(from: ConfigDocumentJSON(document))
    }

    internal static func resolve(from json: ConfigDocumentJSON) -> ContextCompactionSettings {
        let defaults = ContextCompactionSettings()
        guard let object = json.object(["agents", "defaults", "compaction"]) else { return defaults }
        let model = object["model"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ContextCompactionSettings(
            enabled: object["enabled"]?.boolValue ?? defaults.enabled,
            reserveTokens: object["reserveTokens"]?.intValue.map { max(0, $0) } ?? defaults.reserveTokens,
            keepRecentTokens: object["keepRecentTokens"]?.intValue.map { max(1, $0) } ?? defaults.keepRecentTokens,
            model: model?.isEmpty == false ? model : defaults.model
        )
    }
}

public extension SubagentConfiguration {
    /// Sub-agent settings from `agents.defaults.subagents`, with `agents.entries.<id>.subagents`
    /// overriding: `maxSpawnDepth` → ``maxDepth``, `maxConcurrent`, `runTimeoutSeconds` →
    /// ``defaultRunTimeoutSeconds``.
    /// - Parameters:
    ///   - document: Config document.
    ///   - agentID: Agent whose overrides apply.
    /// - Returns: The settings.
    static func resolve(from document: OpenClawConfigDocument, agentID: String? = nil) -> SubagentConfiguration {
        Self.resolve(from: ConfigDocumentJSON(document), agentID: agentID)
    }

    internal static func resolve(from json: ConfigDocumentJSON, agentID: String?) -> SubagentConfiguration {
        let defaults = SubagentConfiguration()
        func int(_ key: String) -> Int? {
            json.layered(agentID, agentPath: ["subagents", key], rootPath: ["agents", "defaults", "subagents", key])?.intValue
        }
        return SubagentConfiguration(
            maxDepth: int("maxSpawnDepth") ?? defaults.maxDepth,
            maxConcurrent: int("maxConcurrent") ?? defaults.maxConcurrent,
            defaultRunTimeoutSeconds: int("runTimeoutSeconds") ?? defaults.defaultRunTimeoutSeconds,
            forkMaxTokens: defaults.forkMaxTokens,
            childToolDeny: defaults.childToolDeny
        )
    }
}

public extension SessionKeyFormat {
    /// Session key format from `routing.sessionKeyFormat` (`legacy` or `canonical`); unset or unknown
    /// values keep ``legacy``.
    /// - Parameter document: Config document.
    /// - Returns: The format.
    static func resolve(from document: OpenClawConfigDocument) -> SessionKeyFormat {
        let raw = ConfigDocumentJSON(document).value(["routing", "sessionKeyFormat"])?.stringValue?.lowercased()
        return raw.flatMap(SessionKeyFormat.init(rawValue:)) ?? .legacy
    }
}

public extension ContextEngineRegistry {
    /// Context engine id configured in `plugins.slots.contextEngine`, if any.
    /// - Parameter document: Config document.
    /// - Returns: The engine id.
    static func configuredEngineID(in document: OpenClawConfigDocument) -> String? {
        let id = ConfigDocumentJSON(document).value(["plugins", "slots", "contextEngine"])?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return id?.isEmpty == false ? id : nil
    }

    /// Selects the engine named in `plugins.slots.contextEngine` when one is configured.
    /// - Parameter document: Config document.
    /// - Returns: The selected engine id, or `nil` when the slot is unset.
    /// - Throws: ``OpenClawCoreError/invalidConfiguration(_:)`` when the engine is not registered.
    @discardableResult
    func select(from document: OpenClawConfigDocument) throws -> String? {
        guard let id = Self.configuredEngineID(in: document) else { return nil }
        try self.select(id)
        return id
    }
}

/// Embedded-runtime settings resolved from an upstream-shaped config document.
public struct AgentRuntimeSettings: Sendable, Equatable {
    /// Tool policy, loop detection and Tool Search (`tools.*`, agent overrides first).
    public var tools: AgentToolsConfiguration
    /// Compaction settings (`agents.defaults.compaction`).
    public var compaction: ContextCompactionSettings
    /// Sub-agent settings (`agents.defaults.subagents`, agent overrides first).
    public var subagents: SubagentConfiguration
    /// Context engine slot (`plugins.slots.contextEngine`).
    public var contextEngineID: String?
    /// Session key format (`routing.sessionKeyFormat`).
    public var sessionKeyFormat: SessionKeyFormat
    /// Agent fast-mode default (`agents.entries.<id>.fastModeDefault`, then `agents.defaults`).
    public var fastModeDefault: FastMode?
    /// Agent thinking default (`agents.entries.<id>.thinkingDefault`, then `agents.defaults`).
    public var thinkingDefault: ThinkLevel?
    /// Provider configurations (`models.providers`); entries that fail to decode are skipped.
    public var providerConfigs: [String: ModelProviderConfig]

    /// Resolves settings from a config document.
    /// - Parameters:
    ///   - document: Config document.
    ///   - agentID: Agent whose overrides apply.
    public init(document: OpenClawConfigDocument, agentID: String? = nil) {
        let json = ConfigDocumentJSON(document)
        self.tools = AgentToolsConfiguration(
            policy: ToolPolicy.resolve(from: json, agentID: agentID),
            loopDetection: AgentLoopDetectionConfiguration.resolve(from: json, agentID: agentID),
            toolSearch: json.layered(agentID, agentPath: ["tools", "toolSearch"], rootPath: ["tools", "toolSearch"]) == nil
                ? nil
                : ToolSearchConfiguration.resolve(json: json, agentID: agentID)
        )
        self.compaction = ContextCompactionSettings.resolve(from: json)
        self.subagents = SubagentConfiguration.resolve(from: json, agentID: agentID)
        self.contextEngineID = ContextEngineRegistry.configuredEngineID(in: document)
        self.sessionKeyFormat = SessionKeyFormat.resolve(from: document)
        let fast = json.layered(agentID, agentPath: ["fastModeDefault"], rootPath: ["agents", "defaults", "fastModeDefault"])
        self.fastModeDefault = FastMode(jsonValue: fast)
        let thinking = json.layered(agentID, agentPath: ["thinkingDefault"], rootPath: ["agents", "defaults", "thinkingDefault"])
        self.thinkingDefault = ThinkLevel.normalize(thinking?.stringValue)
        var providers: [String: ModelProviderConfig] = [:]
        for (id, raw) in json.object(["models", "providers"]) ?? [:] {
            guard let data = try? JSONEncoder().encode(raw), let config = try? JSONDecoder().decode(ModelProviderConfig.self, from: data) else {
                continue
            }
            providers[id] = config
        }
        self.providerConfigs = providers
    }

    /// Resolves settings from the SDK config through its document projection.
    /// - Parameters:
    ///   - config: SDK config.
    ///   - agentID: Agent whose overrides apply (defaults to `agents.defaultAgentID`).
    public init(config: OpenClawConfig, agentID: String? = nil) {
        self.init(document: config.documentProjection(), agentID: agentID ?? config.agents.defaultAgentID)
    }

    /// Loop configuration with these settings applied (compaction, fast-mode default, provider configs).
    /// - Parameter base: Base loop configuration.
    /// - Returns: The updated configuration.
    public func applying(to base: AgentLoopConfiguration) -> AgentLoopConfiguration {
        var loop = base
        loop.compaction = self.compaction
        loop.fastModeDefault = self.fastModeDefault ?? base.fastModeDefault
        loop.providerConfigs = base.providerConfigs.merging(self.providerConfigs) { current, _ in current }
        return loop
    }
}

public extension EmbeddedAgentRuntime {
    /// Applies config-derived settings: tools configuration, loop settings and the context engine slot.
    /// - Parameter settings: Resolved settings.
    /// - Throws: ``OpenClawCoreError/invalidConfiguration(_:)`` when the configured context engine is not registered.
    func apply(_ settings: AgentRuntimeSettings) async throws {
        self.setToolsConfiguration(settings.tools)
        self.setLoopConfiguration(settings.applying(to: self.currentLoopConfiguration()))
        if let engineID = settings.contextEngineID {
            try await self.contextEngines.select(engineID)
        }
    }
}
