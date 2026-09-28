import Foundation
import OpenClawProtocol

// Bridge between the SDK-native OpenClawConfig (ConfigStore file) and the upstream-shaped
// OpenClawConfigDocument (openclaw.json / config.get).
//
// The two files are deliberately separate: upstream validates `openclaw.json` strictly, so SDK-only
// data (routing, runtime, models.openAI/…, agents.skillInvocationTimeoutMs, gateway.host,
// auth.cooldowns, WhatsApp Cloud/WebChat channel shapes) never enters the document projection.

extension OpenClawConfig {
    /// Imports an upstream `openclaw.json` document onto an SDK-native base config.
    ///
    /// Mapping: `secrets`, `gateway` (SDK-local `host`, health and handshake knobs keep the base values),
    /// `auth.profiles`/`order`, `models.mode`/`providers`; `agents.defaultAgentID` ← the resolved default
    /// agent; `agentIDs` ← entry keys; `workspaceRoot`/`modelOverride` and think/verbose/reasoning/elevated
    /// levels ← `agents.defaults`; `responseUsage` ← `messages.responseUsage`; exec host/node/policy ←
    /// `tools.exec`; `routeAgentMap` ← route `bindings`; `routing` ← `session.dmScope`/`mainKey`;
    /// `channels.pluginChannels` ← non-built-in channel blocks. Everything else keeps the base value.
    /// - Parameters:
    ///   - document: Upstream document.
    ///   - base: SDK-native values used where the document has no equivalent.
    ///   - issues: Receives values that could not be mapped.
    public init(document: OpenClawConfigDocument, base: OpenClawConfig = OpenClawConfig(), issues: ConfigDecodeIssueCollector? = nil) {
        var config = base
        func record(_ path: String, _ message: String) {
            issues?.record(ConfigDecodeIssue(path: path, message: message, kind: .invalidValue))
        }
        func decodeSection<T: Decodable>(_ type: T.Type, _ object: [String: AnyCodable]?) -> T? {
            guard let object else { return nil }
            return try? ConfigTreeCoding.decode(type, from: AnyCodable(.object(object)), issues: issues)
        }

        // Secrets (resolution stays SDK-local).
        if let secrets = decodeSection(SecretsConfig.self, document.secrets?.jsonObject) {
            config.secrets = SecretsConfig(
                providers: secrets.providers,
                defaults: secrets.defaults,
                resolution: base.secrets.resolution,
                egressProxy: secrets.egressProxy
            )
        }

        // Gateway (host, health interval and handshake timeout stay SDK-local).
        if let gatewayObject = document.gateway?.jsonObject, var gateway = decodeSection(GatewayConfig.self, gatewayObject) {
            gateway.host = base.gateway.host
            gateway.channelHealthCheckMinutes = base.gateway.channelHealthCheckMinutes
            gateway.handshakeTimeoutMs = base.gateway.handshakeTimeoutMs
            if gatewayObject["bind"] == nil {
                gateway.bind = base.gateway.bind
            }
            if var remote = gateway.remote {
                remote.enabled = remote.enabled ?? base.gateway.remote?.enabled
                gateway.remote = remote
            }
            config.gateway = gateway
        }

        // Auth metadata (cooldowns stay SDK-local).
        if let auth = document.auth {
            var profiles: [String: AuthProfileConfig] = [:]
            for (id, profile) in auth.profiles ?? [:] {
                guard let provider = ConfigValueSupport.nonEmpty(profile.provider),
                      let rawMode = profile.mode?.rawValue, let mode = AuthProfileMode(rawValue: rawMode)
                else {
                    record("auth.profiles.\(id)", "Auth profile needs a provider and a known mode; skipped.")
                    continue
                }
                profiles[id] = AuthProfileConfig(provider: provider, mode: mode, email: profile.email, displayName: profile.displayName)
            }
            config.auth = AuthConfig(profiles: profiles, order: auth.order ?? base.auth.order, cooldowns: base.auth.cooldowns)
        }

        // Models (SDK provider sections stay as they are).
        if let models = document.models {
            if let mode = models.mode.flatMap(ModelsConfigMode.init(rawValue:)) {
                config.models.mode = mode
            }
            if let providers = models.providers {
                var imported: [String: ModelProviderConfig] = [:]
                for (id, provider) in providers {
                    if let converted = Self.importProvider(provider, id: id, record: record) {
                        imported[id] = converted
                    }
                }
                config.models.providers = imported
            }
        }

        config.agents = Self.importAgents(document: document, base: base.agents, record: record)
        if let session = document.session, session.dmScope != nil || session.mainKey != nil {
            config.routing = session.routingConfig
        }
        config.channels = Self.importPluginChannels(document.channels, base: base.channels)
        self = config
    }

    /// Projects this config onto an upstream-shaped document, merged over `original` so passthrough
    /// data survives. Only upstream-valid keys are written; SDK-only data stays out.
    /// - Parameter original: Document to merge into (usually the loaded `openclaw.json`).
    /// - Returns: The projected document.
    public func documentProjection(preserving original: OpenClawConfigDocument? = nil) -> OpenClawConfigDocument {
        var tree = original?.jsonObject ?? [:]
        let defaults = OpenClawConfig()

        func merge(_ key: String, _ value: AnyCodable, onlyIfChangedFrom defaultValue: AnyCodable? = nil) {
            if let defaultValue, value == defaultValue, tree[key] == nil {
                return
            }
            tree[key] = ConfigTree.deepMerge(tree[key], value)
        }

        merge(
            "secrets",
            ConfigTreeCoding.encode(self.secrets, projection: true),
            onlyIfChangedFrom: ConfigTreeCoding.encode(defaults.secrets, projection: true)
        )
        merge(
            "gateway",
            ConfigTreeCoding.encode(self.gateway, projection: true),
            onlyIfChangedFrom: ConfigTreeCoding.encode(defaults.gateway, projection: true)
        )
        if self.auth.profiles != defaults.auth.profiles || self.auth.order != defaults.auth.order || tree["auth"] != nil {
            var auth: [String: AnyCodable] = [:]
            if !self.auth.profiles.isEmpty {
                auth["profiles"] = ConfigTreeCoding.encode(self.auth.profiles)
            }
            if !self.auth.order.isEmpty {
                auth["order"] = ConfigTreeCoding.encode(self.auth.order)
            }
            merge("auth", AnyCodable(.object(auth)))
        }
        if let models = self.projectedModels(original: original) {
            merge("models", models)
        }
        self.projectAgents(into: &tree, original: original)
        self.projectTools(into: &tree)
        self.projectSession(into: &tree)
        self.projectBindings(into: &tree, original: original)
        self.projectPluginChannels(into: &tree)

        OpenClawConfigDocument.stripSDKOnlyKeys(from: &tree)
        var document = (try? OpenClawConfigDocument.decode(jsonObject: tree, migrateLegacyKeys: false)) ?? OpenClawConfigDocument()
        if let order = original?.agents?.entryOrder, !order.isEmpty {
            document.agents?.entryOrder = order
        }
        return document
    }

    // MARK: Import helpers

    private static let sdkOnlyProviderKeys = [
        "enabled", "chatCompletionsPath", "messagesPath", "apiVersion", "organizationID", "profile", "tenantID", "scope", "metadata",
    ]

    private static func importProvider(
        _ provider: OpenClawConfigDocument.ModelProvider,
        id: String,
        record: (String, String) -> Void
    ) -> ModelProviderConfig? {
        var object = provider.jsonObject
        // Current SDK coding keys: `baseURL`; upstream spells it `baseUrl`.
        if let baseUrl = object["baseUrl"], object["baseURL"] == nil {
            object["baseURL"] = baseUrl
        }
        if let apiKey = object["apiKey"], apiKey.stringValue == nil {
            if let ref = provider.apiKey?.ref {
                record("models.providers.\(id).apiKey", "SecretRef apiKey (\(ref.source.rawValue):\(ref.id)) is kept in openclaw.json; resolve it at runtime.")
            }
            object.removeValue(forKey: "apiKey")
        }
        if let headers = object["headers"]?.dictionaryValue {
            object["headers"] = AnyCodable(.object(headers.filter { $0.value.stringValue != nil }))
        }
        if object["enabled"] == nil {
            object["enabled"] = AnyCodable(.bool(true))
        }
        do {
            return try ConfigTreeCoding.decode(ModelProviderConfig.self, from: AnyCodable(.object(object)), issues: nil)
        } catch {
            record("models.providers.\(id)", "Provider could not be represented as ModelProviderConfig: \(error.localizedDescription)")
            return nil
        }
    }

    private static func importAgents(
        document: OpenClawConfigDocument,
        base: AgentsConfig,
        record: (String, String) -> Void
    ) -> AgentsConfig {
        let agents = document.agents
        let defaults = agents?.defaults
        let exec = document.tools?.exec
        let policy = exec?.effectivePolicy
        var routeAgentMap = base.routeAgentMap
        if let bindings = document.bindings {
            var bindingIssues: [ConfigDecodeIssue] = []
            routeAgentMap = OpenClawConfigDocument.routeAgentMap(from: bindings, issues: &bindingIssues)
            for issue in bindingIssues {
                record(issue.path, issue.message)
            }
        }
        let entryIDs = (agents?.entryOrder ?? []).map { OpenClawConfigDocument.normalizeAgentID($0) }
        return AgentsConfig(
            defaultAgentID: agents?.resolvedDefaultAgentID ?? base.defaultAgentID,
            workspaceRoot: ConfigValueSupport.nonEmpty(defaults?.workspace) ?? base.workspaceRoot,
            skillInvocationTimeoutMs: base.skillInvocationTimeoutMs,
            agentIDs: entryIDs.isEmpty ? base.agentIDs : entryIDs,
            routeAgentMap: routeAgentMap,
            thinkingLevel: defaults?.thinkingDefault?.thinkLevel ?? base.thinkingLevel,
            verboseLevel: VerboseLevel.normalize(defaults?.verboseDefault) ?? base.verboseLevel,
            reasoningLevel: ReasoningLevel.normalize(defaults?.reasoningDefault) ?? base.reasoningLevel,
            responseUsage: document.messages?.responseUsageLevel ?? base.responseUsage,
            elevatedLevel: ElevatedLevel.normalize(defaults?.elevatedDefault) ?? base.elevatedLevel,
            groupActivation: base.groupActivation,
            groupActivationNeedsSystemIntro: base.groupActivationNeedsSystemIntro,
            sendPolicy: document.session?.defaultSendPolicy ?? base.sendPolicy,
            modelOverride: defaults?.model?.primary ?? base.modelOverride,
            execHost: exec?.execHost ?? base.execHost,
            execSecurity: policy?.security ?? base.execSecurity,
            execAsk: policy?.ask ?? base.execAsk,
            execNode: ConfigValueSupport.nonEmpty(exec?.node) ?? base.execNode
        )
    }

    private static func importPluginChannels(_ channels: OpenClawConfigDocument.Channels?, base: ChannelsConfig) -> ChannelsConfig {
        guard let channels else { return base }
        var result = base
        for id in channels.pluginChannelIDs {
            guard let block = channels.entries[id] else { continue }
            var config: [String: String] = [:]
            for (key, value) in block.jsonObject where key != "enabled" {
                switch value.value {
                case .string(let string):
                    config[key] = string
                case .int(let int):
                    config[key] = String(int)
                case .double(let double):
                    config[key] = OpenClawJSON5.formatNumber(double)
                case .bool(let flag):
                    config[key] = flag ? "true" : "false"
                default:
                    continue
                }
            }
            let existing = base.pluginChannels[id]
            result.pluginChannels[id] = PluginChannelConfig(
                enabled: block.enabled ?? true,
                packageName: existing?.packageName,
                config: config,
                secrets: existing?.secrets ?? [:]
            )
        }
        return result
    }

    // MARK: Projection helpers

    private func projectedModels(original: OpenClawConfigDocument?) -> AnyCodable? {
        let defaults = ModelsConfig()
        guard self.models.mode != defaults.mode || !self.models.providers.isEmpty || original?.models != nil else {
            return nil
        }
        var models: [String: AnyCodable] = [:]
        if self.models.mode != defaults.mode || original?.models?.mode != nil {
            models["mode"] = AnyCodable(.string(self.models.mode.rawValue))
        }
        if !self.models.providers.isEmpty {
            var providers: [String: AnyCodable] = [:]
            for (id, provider) in self.models.providers {
                var object = ConfigTreeCoding.encodeObject(provider)
                if let baseURL = object.removeValue(forKey: "baseURL") {
                    object["baseUrl"] = baseURL
                }
                for key in Self.sdkOnlyProviderKeys {
                    object.removeValue(forKey: key)
                }
                if (object["headers"]?.dictionaryValue ?? [:]).isEmpty {
                    object.removeValue(forKey: "headers")
                }
                if object["injectNumCtxForOpenAICompat"]?.boolValue == false {
                    object.removeValue(forKey: "injectNumCtxForOpenAICompat")
                }
                providers[id] = AnyCodable(.object(object))
            }
            models["providers"] = AnyCodable(.object(providers))
        }
        return AnyCodable(.object(models))
    }

    private func projectAgents(into tree: inout [String: AnyCodable], original: OpenClawConfigDocument?) {
        let base = AgentsConfig()
        var agents = tree["agents"]?.dictionaryValue ?? [:]
        var defaults = agents["defaults"]?.dictionaryValue ?? [:]
        func setDefault(_ key: String, _ value: String?, unless defaultValue: String?) {
            guard let value, value != defaultValue || defaults[key] != nil else { return }
            defaults[key] = AnyCodable(.string(value))
        }
        setDefault("workspace", self.agents.workspaceRoot, unless: base.workspaceRoot)
        if let modelOverride = ConfigValueSupport.nonEmpty(self.agents.modelOverride) {
            if var selection = defaults["model"]?.dictionaryValue {
                selection["primary"] = AnyCodable(.string(modelOverride))
                defaults["model"] = AnyCodable(.object(selection))
            } else {
                defaults["model"] = AnyCodable(.string(modelOverride))
            }
        }
        setDefault("thinkingDefault", self.agents.thinkingLevel?.rawValue, unless: nil)
        setDefault("verboseDefault", self.agents.verboseLevel?.rawValue, unless: nil)
        setDefault("reasoningDefault", self.agents.reasoningLevel?.rawValue, unless: nil)
        setDefault("elevatedDefault", self.agents.elevatedLevel?.rawValue, unless: nil)
        if !defaults.isEmpty {
            agents["defaults"] = AnyCodable(.object(defaults))
        }

        var entries = agents["entries"]?.dictionaryValue ?? [:]
        let existingIDs = Set(entries.keys.map { OpenClawConfigDocument.normalizeAgentID($0) })
        for id in self.agents.agentIDs where !existingIDs.contains(OpenClawConfigDocument.normalizeAgentID(id)) {
            entries[id] = AnyCodable(.object([:]))
        }
        if !entries.isEmpty {
            agents["entries"] = AnyCodable(.object(entries))
        }
        // A multi-agent roster needs explicit ownership; the SDK default agent owns ambient operations.
        let hasMarker = entries.values.contains { $0.dictionaryValue?["default"]?.boolValue == true }
        if entries.count > 1, agents["ownership"] == nil, !hasMarker {
            agents["ownership"] = AnyCodable(.string("explicit"))
            var systemAgent = defaults["systemAgent"]?.dictionaryValue ?? [:]
            if systemAgent["agentId"] == nil {
                systemAgent["agentId"] = AnyCodable(.string(self.agents.defaultAgentID))
                defaults["systemAgent"] = AnyCodable(.object(systemAgent))
                agents["defaults"] = AnyCodable(.object(defaults))
            }
        }
        if !agents.isEmpty {
            tree["agents"] = AnyCodable(.object(agents))
        }
        if let usage = self.agents.responseUsage {
            var messages = tree["messages"]?.dictionaryValue ?? [:]
            if messages["responseUsage"]?.dictionaryValue == nil {
                messages["responseUsage"] = AnyCodable(.string(usage.rawValue))
                tree["messages"] = AnyCodable(.object(messages))
            }
        }
    }

    private func projectTools(into tree: inout [String: AnyCodable]) {
        let agents = self.agents
        guard agents.execHost != nil || agents.execNode != nil || agents.execSecurity != nil || agents.execAsk != nil else {
            return
        }
        var tools = tree["tools"]?.dictionaryValue ?? [:]
        var exec = tools["exec"]?.dictionaryValue ?? [:]
        if let host = agents.execHost {
            exec["host"] = AnyCodable(.string(host.rawValue))
        }
        if let node = ConfigValueSupport.nonEmpty(agents.execNode) {
            exec["node"] = AnyCodable(.string(node))
        }
        if agents.execSecurity != nil || agents.execAsk != nil {
            let security = agents.execSecurity ?? .allowlist
            let ask = agents.execAsk ?? .onMiss
            exec.removeValue(forKey: "security")
            exec.removeValue(forKey: "ask")
            if let mode = ExecMode.exact(security: security, ask: ask) {
                exec["mode"] = AnyCodable(.string(mode.rawValue))
            } else {
                // No mode expresses this pair; write the legacy pair (never combined with `mode`).
                exec.removeValue(forKey: "mode")
                exec["security"] = AnyCodable(.string(security.rawValue))
                exec["ask"] = AnyCodable(.string(ask.rawValue))
            }
        }
        tools["exec"] = AnyCodable(.object(exec))
        tree["tools"] = AnyCodable(.object(tools))
    }

    private func projectSession(into tree: inout [String: AnyCodable]) {
        let routing = self.routing
        let dmScope: String?
        switch (routing.includeChannelID, routing.includeAccountID, routing.includePeerID) {
        case (false, false, false):
            dmScope = "main"
        case (false, false, true):
            dmScope = "per-peer"
        case (true, false, true):
            dmScope = "per-channel-peer"
        case (true, true, true):
            dmScope = "per-account-channel-peer"
        default:
            // Channel/account-only scoping has no upstream dmScope.
            dmScope = nil
        }
        var session = tree["session"]?.dictionaryValue ?? [:]
        let defaultRouting = RoutingConfig()
        if routing != defaultRouting || session["dmScope"] != nil, let dmScope {
            session["dmScope"] = AnyCodable(.string(dmScope))
        }
        if routing.defaultSessionKey != defaultRouting.defaultSessionKey || session["mainKey"] != nil {
            session["mainKey"] = AnyCodable(.string(routing.defaultSessionKey))
        }
        if let sendPolicy = self.agents.sendPolicy {
            var policy = session["sendPolicy"]?.dictionaryValue ?? [:]
            policy["default"] = AnyCodable(.string(sendPolicy.rawValue))
            session["sendPolicy"] = AnyCodable(.object(policy))
        }
        if !session.isEmpty {
            tree["session"] = AnyCodable(.object(session))
        }
    }

    private func projectBindings(into tree: inout [String: AnyCodable], original: OpenClawConfigDocument?) {
        let originalBindings = original?.bindings ?? []
        var ignored: [ConfigDecodeIssue] = []
        let originalMap = OpenClawConfigDocument.routeAgentMap(from: originalBindings, issues: &ignored)
        guard originalMap != self.agents.routeAgentMap else {
            return
        }
        // Keep bindings the SDK map cannot express; regenerate the expressible route bindings.
        let preserved = originalBindings.filter { binding in
            var issues: [ConfigDecodeIssue] = []
            return OpenClawConfigDocument.routeAgentMap(from: [binding], issues: &issues).isEmpty
        }
        let bindings = OpenClawConfigDocument.bindings(fromRouteAgentMap: self.agents.routeAgentMap) + preserved
        if bindings.isEmpty {
            tree.removeValue(forKey: "bindings")
        } else {
            tree["bindings"] = ConfigTreeCoding.encode(bindings)
        }
    }

    private func projectPluginChannels(into tree: inout [String: AnyCodable]) {
        guard !self.channels.pluginChannels.isEmpty else { return }
        var channels = tree["channels"]?.dictionaryValue ?? [:]
        for (id, plugin) in self.channels.pluginChannels where !OpenClawConfigDocument.Channels.builtInChannelIDs.contains(id) {
            var block = channels[id]?.dictionaryValue ?? [:]
            block["enabled"] = AnyCodable(.bool(plugin.enabled))
            for (key, value) in plugin.config where block[key] == nil {
                block[key] = AnyCodable(.string(value))
            }
            channels[id] = AnyCodable(.object(block))
        }
        tree["channels"] = AnyCodable(.object(channels))
    }
}

/// Tree helpers for config merging.
public enum ConfigTree {
    /// Deep-merges `override` onto `base`: objects merge recursively; other values replace.
    /// - Parameters:
    ///   - base: Existing value.
    ///   - override: New value.
    /// - Returns: Merged value.
    public static func deepMerge(_ base: AnyCodable?, _ override: AnyCodable) -> AnyCodable {
        // Keep an authored `${NAME}` / `$NAME` string when the override is the equivalent SecretRef object.
        if let baseString = base?.stringValue, let overrideObject = override.dictionaryValue,
           let ref = try? ConfigTreeCoding.decode(SecretRef.self, from: AnyCodable(.object(overrideObject)), issues: nil),
           SecretInput.parse(baseString).input == .ref(ref)
        {
            return AnyCodable(.string(baseString))
        }
        guard let overrideObject = override.dictionaryValue, let baseObject = base?.dictionaryValue else {
            return override
        }
        var result = baseObject
        for (key, value) in overrideObject {
            result[key] = self.deepMerge(baseObject[key], value)
        }
        return AnyCodable(.object(result))
    }
}
