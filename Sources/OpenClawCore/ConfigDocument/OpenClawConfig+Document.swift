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
    /// `channels` ← ``ChannelsConfigDocument/channelsConfig`` (typed sections present in the document
    /// replace the base section, other blocks land in ``ChannelsConfig/extensionChannels``; SDK-only
    /// sections keep the base values) with `session.legacyChannelAccountKeys` →
    /// ``ChannelsCompatibilityConfig/legacySessionAccountKeys``; `models.catalogRefresh`; and the
    /// upstream-shaped `mcp`, `skills`, `memory` and `plugins` sections. Everything else keeps the base value.
    /// - Parameters:
    ///   - document: Upstream document.
    ///   - base: SDK-native values used where the document has no equivalent.
    ///   - issues: Receives values that could not be mapped.
    public init(document: OpenClawConfigDocument, base: OpenClawConfig = OpenClawConfig(), issues: ConfigDecodeIssueCollector? = nil) {
        var config = base
        func record(_ path: String, _ message: String) {
            issues?.record(ConfigDecodeIssue(path: path, message: message, kind: .invalidValue))
        }
        func decodeSection<T: Decodable>(_ type: T.Type, _ path: String, _ object: [String: AnyCodable]?) -> T? {
            guard let object else { return nil }
            do {
                return try ConfigTreeCoding.decode(type, from: AnyCodable(.object(object)), issues: issues)
            } catch {
                record(path, "The \(path) section could not be imported; kept the base value: \(error)")
                return nil
            }
        }

        // Secrets (resolution stays SDK-local).
        if let secrets = decodeSection(SecretsConfig.self, "secrets", document.secrets?.jsonObject) {
            config.secrets = SecretsConfig(
                providers: secrets.providers,
                defaults: secrets.defaults,
                resolution: base.secrets.resolution,
                egressProxy: secrets.egressProxy
            )
        }

        // Gateway (host, health interval and handshake timeout stay SDK-local).
        if let gatewayObject = document.gateway?.jsonObject, var gateway = decodeSection(GatewayConfig.self, "gateway", gatewayObject) {
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
                      let rawMode = ConfigValueSupport.nonEmpty(profile.mode?.rawValue)
                else {
                    record("auth.profiles.\(id)", "Auth profile needs a provider and a mode; skipped.")
                    continue
                }
                let imported = AuthProfileConfig(provider: provider, rawMode: rawMode, email: profile.email, displayName: profile.displayName)
                if let unknown = imported.unrecognizedMode {
                    record("auth.profiles.\(id)", "Unknown auth profile mode \"\(unknown)\" is kept but the profile is never selected.")
                }
                profiles[id] = imported
            }
            config.auth = AuthConfig(profiles: profiles, order: auth.order ?? base.auth.order, cooldowns: base.auth.cooldowns)
        }

        // Models (SDK provider sections stay as they are).
        if let models = document.models {
            if let mode = models.mode.flatMap(ModelsConfigMode.init(rawValue:)) {
                config.models.mode = mode
            }
            if models.catalogRefresh != nil {
                if let refresh = models.catalogRefreshConfig {
                    config.models.catalogRefresh = refresh
                } else {
                    record("models.catalogRefresh", "catalogRefresh could not be represented as ModelCatalogRefreshConfig; kept the base value.")
                }
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
        config.channels = Self.importChannels(document.channels, session: document.session, base: base.channels)
        config.mcp = document.mcp ?? base.mcp
        config.skills = document.skills ?? base.skills
        config.memory = document.memory ?? base.memory
        config.plugins = document.plugins ?? base.plugins
        self = config
    }

    /// Projects this config onto an upstream-shaped document, merged over `original` so passthrough
    /// data survives. Only upstream-valid keys are written; SDK-only data stays out.
    ///
    /// For `secrets` and `gateway` authored in `original`, only the values that differ from what
    /// `original` itself imports as are written (and values this config removed are deleted), so a
    /// no-change round trip keeps the authored section byte-for-byte and SDK defaults never replace
    /// authored or omitted values.
    /// - Parameter original: Document to merge into (usually the loaded `openclaw.json`).
    /// - Returns: The projected document.
    public func documentProjection(preserving original: OpenClawConfigDocument? = nil) -> OpenClawConfigDocument {
        var tree = original?.jsonObject ?? [:]
        let defaults = OpenClawConfig()
        let reimported = original.map { OpenClawConfig(document: $0) }

        func merge(_ key: String, _ value: AnyCodable, onlyIfChangedFrom defaultValue: AnyCodable? = nil) {
            if let defaultValue, value == defaultValue, tree[key] == nil {
                return
            }
            tree[key] = ConfigTree.deepMerge(tree[key], value)
        }
        func mergeChanges(_ key: String, _ value: AnyCodable, imported: AnyCodable?, defaultValue: AnyCodable) {
            guard let imported, tree[key] != nil else {
                merge(key, value, onlyIfChangedFrom: defaultValue)
                return
            }
            tree[key] = ConfigTree.applyingChanges(from: imported, to: value, onto: tree[key])
        }

        mergeChanges(
            "secrets",
            ConfigTreeCoding.encode(self.secrets, projection: true),
            imported: reimported.map { ConfigTreeCoding.encode($0.secrets, projection: true) },
            defaultValue: ConfigTreeCoding.encode(defaults.secrets, projection: true)
        )
        mergeChanges(
            "gateway",
            ConfigTreeCoding.encode(self.gateway, projection: true),
            imported: reimported.map { ConfigTreeCoding.encode($0.gateway, projection: true) },
            defaultValue: ConfigTreeCoding.encode(defaults.gateway, projection: true)
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
        self.projectChannels(into: &tree, original: original)
        for (key, section) in [
            ("mcp", self.mcp?.jsonObject), ("skills", self.skills?.jsonObject),
            ("memory", self.memory?.jsonObject), ("plugins", self.plugins?.jsonObject),
        ] {
            if let section {
                merge(key, AnyCodable(.object(section)))
            }
        }

        OpenClawConfigDocument.stripSDKOnlyKeys(from: &tree)
        var document = (try? OpenClawConfigDocument.decode(jsonObject: tree, migrateLegacyKeys: false)) ?? OpenClawConfigDocument()
        if let order = original?.agents?.entryOrder, !order.isEmpty {
            document.agents?.entryOrder = order
        }
        return document
    }

    /// A document holding only this config's upstream-shaped runtime sections (`mcp`, `skills`,
    /// `memory`, `plugins`), so runtime bridges written against ``OpenClawConfigDocument`` (for example
    /// `MCPConfig.resolve(from:)`) also accept SDK-native configs.
    public var runtimeSectionsDocument: OpenClawConfigDocument {
        var document = OpenClawConfigDocument()
        document.mcp = self.mcp
        document.skills = self.skills
        document.memory = self.memory
        document.plugins = self.plugins
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

    private static func importChannels(
        _ channels: OpenClawConfigDocument.Channels?,
        session: OpenClawConfigDocument.Session?,
        base: ChannelsConfig
    ) -> ChannelsConfig {
        var result = base
        if let channels {
            let imported = channels.channelsConfig
            let present = Set(channels.channels.keys.map { $0.lowercased() })
            // Typed sections present in the document replace the base section; absent ones keep it.
            if present.contains("discord") { result.discord = imported.discord }
            if present.contains("telegram") { result.telegram = imported.telegram }
            if present.contains("slack") { result.slack = imported.slack }
            if present.contains("googlechat") { result.googleChat = imported.googleChat }
            if present.contains("signal") { result.signal = imported.signal }
            if present.contains("imessage") { result.imessage = imported.imessage }
            if present.contains("msteams") { result.msteams = imported.msteams }
            if present.contains("bluebubbles") { result.bluebubbles = imported.bluebubbles }
            // Plugin-owned and untyped upstream blocks (for example `whatsapp` and `matrix`).
            for (id, value) in imported.extensionChannels {
                result.extensionChannels[id] = value
            }
            if channels.defaults != nil {
                result.defaults = imported.defaults
            }
            if channels.modelByChannel != nil {
                result.modelByChannel = imported.modelByChannel
            }
            // `whatsappCloud`, `webchat`, `pluginChannels` and `compatibility` are SDK-only and keep the base values.
        }
        if let legacyKeys = session?.legacyChannelAccountKeys {
            result.compatibility.legacySessionAccountKeys = legacyKeys
        }
        return result
    }

    // MARK: Projection helpers

    private func projectedModels(original: OpenClawConfigDocument?) -> AnyCodable? {
        let defaults = ModelsConfig()
        guard self.models.mode != defaults.mode || !self.models.providers.isEmpty || original?.models != nil
            || self.models.catalogRefresh != nil
        else {
            return nil
        }
        var models: [String: AnyCodable] = [:]
        if self.models.mode != defaults.mode || original?.models?.mode != nil {
            models["mode"] = AnyCodable(.string(self.models.mode.rawValue))
        }
        if let catalogRefresh = self.models.catalogRefresh {
            models["catalogRefresh"] = ConfigTreeCoding.encode(catalogRefresh)
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

    private func projectChannels(into tree: inout [String: AnyCodable], original: OpenClawConfigDocument?) {
        let originalChannels = tree["channels"]?.dictionaryValue.flatMap { object in
            try? ConfigTreeCoding.decode(ChannelsConfigDocument.self, from: AnyCodable(.object(object)), issues: nil)
        } ?? original?.channels
        var channels = ChannelsConfigDocument(exporting: self.channels, preserving: originalChannels).jsonObject
        // Legacy SDK plugin wrappers without a raw block keep their flattened settings as a channel block.
        for (id, plugin) in self.channels.pluginChannels
        where !OpenClawConfigDocument.builtInChannelIDs.contains(id) && plugin.raw.isEmpty {
            var block = channels[id]?.dictionaryValue ?? [:]
            block["enabled"] = AnyCodable(.bool(plugin.enabled))
            for (key, value) in plugin.config where block[key] == nil {
                block[key] = AnyCodable(.string(value))
            }
            channels[id] = AnyCodable(.object(block))
        }
        if channels.isEmpty, tree["channels"] == nil {
            return
        }
        tree["channels"] = ConfigTree.preservingAuthoredSecretTemplates(AnyCodable(.object(channels)), original: tree["channels"])
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

    /// Applies the difference between two projections of the same section onto its authored value.
    ///
    /// Keys whose value is the same in `imported` and `projected` keep the authored value (or stay
    /// absent); keys `projected` removed are deleted; changed and added keys are deep-merged. Keys in
    /// neither projection (passthrough data) are untouched.
    /// - Parameters:
    ///   - imported: Projection of what `authored` imports as.
    ///   - projected: Projection of the current value.
    ///   - authored: Authored value at the same path.
    /// - Returns: The authored value with the changes applied.
    public static func applyingChanges(from imported: AnyCodable, to projected: AnyCodable, onto authored: AnyCodable?) -> AnyCodable {
        if imported == projected, let authored {
            return authored
        }
        guard let importedObject = imported.dictionaryValue, let projectedObject = projected.dictionaryValue,
              authored == nil || authored?.dictionaryValue != nil
        else {
            return self.deepMerge(authored, projected)
        }
        var result = authored?.dictionaryValue ?? [:]
        for key in Set(importedObject.keys).union(projectedObject.keys) {
            let before = importedObject[key]
            let after = projectedObject[key]
            if before == after {
                continue
            }
            guard let after else {
                result.removeValue(forKey: key)
                continue
            }
            if let before {
                result[key] = self.applyingChanges(from: before, to: after, onto: result[key])
            } else {
                result[key] = self.deepMerge(result[key], after)
            }
        }
        return AnyCodable(.object(result))
    }

    /// Returns `projected` with authored `${NAME}` / `$NAME` strings from `original` restored where the
    /// projection wrote the equivalent SecretRef object. Unlike ``deepMerge(_:_:)`` it never re-adds
    /// keys the projection removed.
    /// - Parameters:
    ///   - projected: Newly projected value.
    ///   - original: Authored value at the same path.
    /// - Returns: The projection with authored secret templates kept.
    public static func preservingAuthoredSecretTemplates(_ projected: AnyCodable, original: AnyCodable?) -> AnyCodable {
        if let originalString = original?.stringValue, let object = projected.dictionaryValue,
           let ref = try? ConfigTreeCoding.decode(SecretRef.self, from: AnyCodable(.object(object)), issues: nil),
           SecretInput.parse(originalString).input == .ref(ref)
        {
            return AnyCodable(.string(originalString))
        }
        if let object = projected.dictionaryValue, let originalObject = original?.dictionaryValue {
            return AnyCodable(.object(object.reduce(into: [:]) { result, entry in
                result[entry.key] = self.preservingAuthoredSecretTemplates(entry.value, original: originalObject[entry.key])
            }))
        }
        return projected
    }
}
