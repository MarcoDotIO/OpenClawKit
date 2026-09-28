import Foundation
import OpenClawProtocol

// Gateway, MCP, models, code-mode, cron, diagnostics, TTS, session and skills migrations.

extension ConfigMigrationRules {
    // MARK: Code mode, cron, diagnostics

    static func removeCodeModeLanguages(_ root: MigrationObject, _ changes: inout [String]) {
        func remove(_ tools: MigrationObject?, _ path: String) {
            guard let codeMode = tools?.object("codeMode"), codeMode.has("languages") else { return }
            codeMode.remove("languages")
            changes.append("Removed \(path).codeMode.languages; Code Mode now runs JavaScript only.")
        }
        remove(root.object("tools"), "tools")
        MigrationSupport.visitAgentEntries(root) { agent, path in remove(agent.object("tools"), "\(path).tools") }
    }

    static func migrateCodeModeRuntime(_ root: MigrationObject, _ changes: inout [String]) {
        func migrate(_ tools: MigrationObject?, _ path: String) {
            guard let codeMode = tools?.object("codeMode"), codeMode.string("runtime") == "quickjs-wasi" else { return }
            if codeMode.has("executor") {
                changes.append("Removed \(path).codeMode.runtime; kept explicit \(path).codeMode.executor.")
            } else {
                codeMode["executor"] = .string("quickjs")
                changes.append("Moved \(path).codeMode.runtime to \(path).codeMode.executor (quickjs).")
            }
            codeMode.remove("runtime")
        }
        migrate(root.object("tools"), "tools")
        MigrationSupport.visitAgentEntries(root) { agent, path in migrate(agent.object("tools"), "\(path).tools") }
    }

    static func removeCronWebhook(_ root: MigrationObject, _ changes: inout [String]) {
        guard let cron = root.object("cron"), cron.has("webhook") else { return }
        cron.remove("webhook")
        changes.append("Removed retired cron.webhook after stored jobs migrated to per-job delivery.")
    }

    static func removeCronRunLog(_ root: MigrationObject, _ changes: inout [String]) {
        guard let cron = root.object("cron"), cron.has("runLog") else { return }
        cron.remove("runLog")
        if cron.isEmpty {
            root.remove("cron")
        }
        changes.append("Removed retired cron.runLog config; cron history now keeps 2000 runs per job.")
    }

    static func migrateOtelGrpcProtocol(_ root: MigrationObject, _ changes: inout [String]) {
        guard let otel = root.object("diagnostics")?.object("otel"), otel.string("protocol") == "grpc" else { return }
        otel.remove("protocol")
        changes.append("Removed unsupported diagnostics.otel.protocol \"grpc\"; use \"http/protobuf\" with an OTLP/HTTP collector.")
        let logsExporter = otel.string("logsExporter")
        let hasSignals = otel.bool("traces") != false || otel.bool("metrics") != false
            || (otel.bool("logs") == true && logsExporter != "stdout")
        if otel.bool("enabled") == true, hasSignals {
            otel["enabled"] = .bool(false)
            changes.append(
                "Disabled diagnostics.otel.enabled because legacy grpc configs with OTLP signals cannot export telemetry; re-enable it after choosing an OTLP/HTTP collector."
            )
        }
    }

    // MARK: Gateway

    static func removeControlUIToolTitles(_ root: MigrationObject, _ changes: inout [String]) {
        guard let controlUI = root.object("gateway")?.object("controlUi"), controlUI.has("toolTitles") else { return }
        controlUI.remove("toolTitles")
        changes.append(
            "Removed retired gateway.controlUi.toolTitles; tool activity descriptions are automatic and make no utility-model calls."
        )
    }

    static func removeTailscaleServiceName(_ root: MigrationObject, _ changes: inout [String]) {
        guard let tailscale = root.object("gateway")?.object("tailscale"), tailscale.has("serviceName") else { return }
        let wasManagedService = tailscale.string("mode") == "serve"
        tailscale.remove("serviceName")
        if wasManagedService {
            tailscale["mode"] = .string("off")
        }
        changes.append(
            wasManagedService
                ? "Removed gateway.tailscale.serviceName and set gateway.tailscale.mode=off because named Services cannot use lifecycle-owned routes."
                : "Removed retired gateway.tailscale.serviceName; the current Tailscale mode is unchanged because named Services applied only to Serve."
        )
    }

    static func removeTailscaleResetOnExit(_ root: MigrationObject, _ changes: inout [String]) {
        guard let tailscale = root.object("gateway")?.object("tailscale"), tailscale.has("resetOnExit") else { return }
        let cleanupWasEnabled = tailscale.bool("resetOnExit") == true
        tailscale.remove("resetOnExit")
        changes.append(
            cleanupWasEnabled
                ? "Removed gateway.tailscale.resetOnExit; managed Tailscale routes now end automatically with the Gateway lifecycle."
                : "Removed retired gateway.tailscale.resetOnExit config."
        )
    }

    static func removeControlUIDeviceAuthBypass(_ root: MigrationObject, _ changes: inout [String]) {
        guard let controlUI = root.object("gateway")?.object("controlUi"), controlUI.has("dangerouslyDisableDeviceAuth") else { return }
        controlUI.remove("dangerouslyDisableDeviceAuth")
        changes.append("Removed retired gateway.controlUi.dangerouslyDisableDeviceAuth legacy config.")
    }

    static func removeGatewayWebchat(_ root: MigrationObject, _ changes: inout [String]) {
        guard let gateway = root.object("gateway"), gateway.has("webchat") else { return }
        gateway.remove("webchat")
        if gateway.isEmpty {
            root.remove("gateway")
        }
        changes.append("Removed retired gateway.webchat config.")
    }

    static func repairGatewayPort(_ root: MigrationObject, _ changes: inout [String]) {
        guard let gateway = root.object("gateway"), let port = gateway["port"]?.numberValue, port < 1 || port > 65_535 else { return }
        gateway.remove("port")
        if gateway.isEmpty {
            root.remove("gateway")
        }
        changes.append(
            "Removed out-of-range gateway.port (\(OpenClawJSON5.formatNumber(port))). Valid TCP ports are 1–65535; the gateway will use the default port 18789."
        )
    }

    static func normalizeGatewayBind(_ root: MigrationObject, _ changes: inout [String]) {
        guard let gateway = root.object("gateway"), let raw = gateway.string("bind") else { return }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let aliases = ["0.0.0.0": "lan", "::": "lan", "[::]": "lan", "*": "lan",
                       "127.0.0.1": "loopback", "localhost": "loopback", "::1": "loopback", "[::1]": "loopback"]
        guard !normalized.isEmpty, let mapped = aliases[normalized], normalized != mapped else { return }
        gateway["bind"] = .string(mapped)
        changes.append("Normalized gateway.bind \"\(raw)\" → \"\(mapped)\".")
    }

    // MARK: MCP

    static func canonicalizeMCPServers(_ root: MigrationObject, _ changes: inout [String]) {
        let mcpServers = root.object("mcp")?.object("servers")
        let nodeHostServers = root.object("nodeHost")?.object("mcp")?.object("servers")
        for (servers, prefix) in [(mcpServers, "mcp.servers"), (nodeHostServers, "nodeHost.mcp.servers")] {
            guard let servers else { continue }
            Self.migrateMCPDisabledFlags(servers, prefix, &changes)
            Self.migrateMCPTimeoutAliases(servers, prefix, &changes)
            Self.migrateMCPAliases(servers, prefix, &changes)
        }
        guard let servers = mcpServers else { return }
        for (name, value) in servers.entries {
            guard let server = value.object, let type = server["type"], Self.isKnownCLIMCPTypeAlias(type.stringValue) else { continue }
            let rawType = type.stringValue ?? ""
            let alias = Self.mcpTransportAlias(rawType)
            if server.string("transport") == nil, let alias {
                server["transport"] = .string(alias)
                changes.append("Moved mcp.servers.\(name).type \"\(rawType)\" → transport \"\(alias)\".")
            } else if let transport = server.string("transport") {
                changes.append("Removed mcp.servers.\(name).type (transport \"\(transport)\" already set).")
            } else {
                changes.append("Removed mcp.servers.\(name).type \"\(rawType)\".")
            }
            server.remove("type")
        }
    }

    /// CLI-native MCP `type` aliases (upstream `CLI_MCP_TYPE_TO_OPENCLAW_TRANSPORT`).
    static let cliMCPTypeToTransport: [String: String] = [
        "http": "streamable-http", "streamable-http": "streamable-http", "sse": "sse", "stdio": "stdio",
    ]

    static func isKnownCLIMCPTypeAlias(_ value: String?) -> Bool {
        guard let value else { return false }
        return self.cliMCPTypeToTransport[value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] != nil
    }

    /// HTTP transport for a CLI alias (`stdio` has no transport name; stdio is implied by `command`).
    static func mcpTransportAlias(_ value: String?) -> String? {
        guard let value, let mapped = self.cliMCPTypeToTransport[value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()],
              mapped != "stdio"
        else { return nil }
        return mapped
    }

    static func migrateMCPDisabledFlags(_ servers: MigrationObject, _ prefix: String, _ changes: inout [String]) {
        for (name, value) in servers.entries {
            guard let server = value.object, let disabled = server.bool("disabled") else { continue }
            if let enabled = server.bool("enabled") {
                changes.append("Removed \(prefix).\(name).disabled \(disabled) because enabled is already set to \(enabled).")
            } else {
                server["enabled"] = .bool(!disabled)
                changes.append("Moved \(prefix).\(name).disabled \(disabled) → enabled \(!disabled).")
            }
            server.remove("disabled")
        }
    }

    static func migrateMCPTimeoutAliases(_ servers: MigrationObject, _ prefix: String, _ changes: inout [String]) {
        for (name, value) in servers.entries {
            guard let server = value.object else { continue }
            for (alias, canonical) in [("connectTimeout", "connectionTimeoutMs"), ("connect_timeout", "connectionTimeoutMs"),
                                       ("timeout", "requestTimeoutMs")] {
                guard server.has(alias) else { continue }
                let seconds = server[alias]?.numberValue
                if !server.isSet(canonical), let seconds, seconds > 0, (seconds * 1_000).isFinite {
                    let milliseconds = seconds * 1_000
                    if let exact = Int(exactly: milliseconds) {
                        server[canonical] = .int(exact)
                    } else {
                        server[canonical] = .double(milliseconds)
                    }
                    changes.append("Moved \(prefix).\(name).\(alias) → \(canonical) (\(OpenClawJSON5.formatNumber(milliseconds)) ms).")
                } else {
                    changes.append("Removed \(prefix).\(name).\(alias) (\(canonical) already set or alias invalid).")
                }
                server.remove(alias)
            }
        }
    }

    static func migrateMCPAliases(_ servers: MigrationObject, _ prefix: String, _ changes: inout [String]) {
        for (name, value) in servers.entries {
            guard let server = value.object else { continue }
            let codex = server.object("codex")
            let hasAliases = server.has("workingDirectory")
                || ["supports_parallel_tool_calls", "ssl_verify", "client_cert", "client_key"].contains(where: server.has)
                || codex?.has("default_tools_approval_mode") == true
            guard hasAliases else { continue }
            let before = Self.signature(value)
            if let alias = Self.mcpTransportAlias(server.string("type")), server.string("transport") == nil {
                server["transport"] = .string(alias)
            }
            if Self.isKnownCLIMCPTypeAlias(server.string("type")) {
                server.remove("type")
            }
            if server.string("cwd") == nil, let workingDirectory = server.string("workingDirectory") {
                server["cwd"] = .string(workingDirectory)
            }
            server.remove("workingDirectory")
            for (snake, camel, isBool) in [("supports_parallel_tool_calls", "supportsParallelToolCalls", true),
                                           ("ssl_verify", "sslVerify", true), ("client_cert", "clientCert", false),
                                           ("client_key", "clientKey", false)] {
                if isBool {
                    if let flag = server.bool(snake), server.bool(camel) == nil {
                        server[camel] = .bool(flag)
                    }
                } else if let text = server.string(snake), server.string(camel) == nil {
                    server[camel] = .string(text)
                }
                server.remove(snake)
            }
            if let codex {
                if codex.string("defaultToolsApprovalMode") == nil, let mode = codex.string("default_tools_approval_mode") {
                    codex["defaultToolsApprovalMode"] = .string(mode)
                }
                codex.remove("default_tools_approval_mode")
            }
            if Self.signature(value) != before {
                changes.append("Canonicalized legacy aliases in \(prefix).\(name).")
            }
        }
    }

    // MARK: Models

    static func migrateRootDefaultModel(_ root: MigrationObject, _ changes: inout [String]) {
        guard root.has("defaultModel") else { return }
        let legacy = root["defaultModel"]
        let defaults = root.object("agents")?.object("defaults")
        if defaults?.isSet("model") != true, let model = legacy?.stringValue {
            root.ensureObject("agents").ensureObject("defaults")["model"] = .string(model)
            changes.append("Moved defaultModel → agents.defaults.model.")
        } else {
            changes.append("Removed defaultModel (agents.defaults.model already set or value invalid).")
        }
        root.remove("defaultModel")
    }

    static func removeModelsPricing(_ root: MigrationObject, _ changes: inout [String]) {
        guard let models = root.object("models"), models.has("pricing") else { return }
        models.remove("pricing")
        changes.append("Removed models.pricing (pricing now ships with the hosted model catalog).")
    }

    // MARK: TTS

    /// TTS blocks visited by the speaker-key and enabled migrations (upstream `visitKnownTtsConfigLocations`).
    static func knownTTSLocations(_ root: MigrationObject, includeAgentsAndChannels: Bool = true) -> [(MigrationObject?, String)] {
        var locations: [(MigrationObject?, String)] = [(root.object("tts"), "tts")]
        if includeAgentsAndChannels {
            MigrationSupport.visitAgentEntries(root) { entry, path in locations.append((entry.object("tts"), "\(path).tts")) }
            if let channels = root.object("channels") {
                for (channelID, value) in channels.entries where !MigrationSupport.isBlockedKey(channelID) {
                    let channel = value.object
                    let rootTTS = channelID.lowercased() != "discord"
                    if rootTTS {
                        locations.append((channel?.object("tts"), "channels.\(channelID).tts"))
                    }
                    locations.append((channel?.object("voice")?.object("tts"), "channels.\(channelID).voice.tts"))
                    for (accountID, account) in channel?.object("accounts")?.entries ?? [] where !MigrationSupport.isBlockedKey(accountID) {
                        if rootTTS {
                            locations.append((account.object?.object("tts"), "channels.\(channelID).accounts.\(accountID).tts"))
                        }
                        locations.append((account.object?.object("voice")?.object("tts"), "channels.\(channelID).accounts.\(accountID).voice.tts"))
                    }
                }
            }
        }
        if let voiceCall = root.object("plugins")?.object("entries")?.object("voice-call") {
            locations.append((voiceCall.object("config")?.object("tts"), "plugins.entries.voice-call.config.tts"))
        }
        return locations
    }

    static func migrateMessagesTTS(_ root: MigrationObject, _ changes: inout [String]) {
        guard let messages = root.object("messages"), messages.has("tts") else { return }
        guard let legacy = messages.object("tts") else {
            messages.remove("tts")
            changes.append("Removed messages.tts (invalid value).")
            return
        }
        if let legacyRealtime = legacy.object("realtime") {
            let legacyVoice = legacyRealtime["speakerVoice"] ?? legacyRealtime["voice"]
            let talk = root.object("talk") ?? MigrationObject()
            let talkRealtime = talk.object("realtime") ?? MigrationObject()
            if let legacyVoice, !talkRealtime.isSet("speakerVoice") {
                talkRealtime["speakerVoice"] = legacyVoice
                talk["realtime"] = .object(talkRealtime)
                root["talk"] = .object(talk)
                changes.append("Moved messages.tts.realtime voice → talk.realtime.speakerVoice.")
            } else {
                changes.append("Removed messages.tts.realtime (talk.realtime already configured).")
            }
            legacy.remove("realtime")
        }
        let canonical = root.object("tts") ?? MigrationObject()
        MigrationSupport.mergeMissing(canonical, legacy)
        root["tts"] = .object(canonical)
        messages.remove("tts")
        changes.append("Moved messages.tts to top-level tts.")
    }

    static func migrateTTSProviderKeys(_ root: MigrationObject, _ changes: inout [String]) {
        for (tts, path) in Self.knownTTSLocations(root, includeAgentsAndChannels: false) {
            guard let tts else { continue }
            if tts.string("provider")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "edge" {
                tts["provider"] = .string("microsoft")
                changes.append("Moved \(path).provider \"edge\" → \"microsoft\".")
            }
            for (legacyKey, providerID, fromProviders) in [("openai", "openai", false), ("elevenlabs", "elevenlabs", false),
                                                           ("microsoft", "microsoft", false), ("edge", "microsoft", true),
                                                           ("edge", "microsoft", false)] {
                let owner = fromProviders ? tts.object("providers") : tts
                guard let owner, let legacyValue = owner.object(legacyKey) else { continue }
                let providers = fromProviders ? owner : tts.ensureObject("providers")
                let merged = providers.object(providerID)?.deepCopy() ?? MigrationObject()
                MigrationSupport.mergeMissing(merged, legacyValue)
                providers[providerID] = .object(merged)
                owner.remove(legacyKey)
                let source = fromProviders ? "\(path).providers.\(legacyKey)" : "\(path).\(legacyKey)"
                changes.append("Moved \(source) → \(path).providers.\(providerID).")
            }
        }
    }

    static func migrateTTSSpeakerKeys(_ root: MigrationObject, _ changes: inout [String]) {
        func migrateScope(_ scope: MigrationObject?, _ path: String) {
            guard let scope else { return }
            var configs: [(MigrationObject, String)] = []
            for (providerID, value) in scope.object("providers")?.entries ?? [] where !MigrationSupport.isBlockedKey(providerID) {
                if let config = value.object {
                    configs.append((config, "\(path).providers.\(providerID)"))
                }
            }
            for providerID in ["openai", "elevenlabs", "microsoft", "edge"] {
                if let config = scope.object(providerID) {
                    configs.append((config, "\(path).\(providerID)"))
                }
            }
            for (config, configPath) in configs {
                for (legacyKey, canonicalKey) in [("voice", "speakerVoice"), ("voiceName", "speakerVoice"), ("voiceId", "speakerVoiceId")] {
                    guard config.has(legacyKey) else { continue }
                    if config.isSet(canonicalKey) {
                        changes.append("Removed \(configPath).\(legacyKey) because \(configPath).\(canonicalKey) is already set.")
                    } else {
                        config[canonicalKey] = config[legacyKey]
                        changes.append("Moved \(configPath).\(legacyKey) → \(configPath).\(canonicalKey).")
                    }
                    config.remove(legacyKey)
                }
            }
        }
        for (tts, path) in Self.knownTTSLocations(root) {
            migrateScope(tts, path)
            for (personaID, persona) in tts?.object("personas")?.entries ?? [] where !MigrationSupport.isBlockedKey(personaID) {
                migrateScope(persona.object, "\(path).personas.\(personaID)")
            }
        }
    }

    static func migrateTTSEnabled(_ root: MigrationObject, _ changes: inout [String]) {
        for (tts, path) in Self.knownTTSLocations(root) {
            guard let tts, let enabled = tts.bool("enabled") else { continue }
            let nextAuto = enabled ? "always" : "off"
            tts.remove("enabled")
            if let auto = tts.string("auto"), !auto.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                changes.append("Removed \(path).enabled because \(path).auto is already set.")
                continue
            }
            tts["auto"] = .string(nextAuto)
            changes.append("Moved \(path).enabled → \(path).auto \"\(nextAuto)\".")
        }
    }

    // MARK: Session and skills

    static func migrateSessionAliases(_ root: MigrationObject, _ changes: inout [String]) {
        let session = root.object("session")
        if let maintenance = session?.object("maintenance"), maintenance.has("pruneDays") {
            if maintenance.isSet("pruneAfter") {
                changes.append("Removed session.maintenance.pruneDays (pruneAfter already set).")
            } else {
                maintenance["pruneAfter"] = maintenance["pruneDays"]
                changes.append("Moved session.maintenance.pruneDays → session.maintenance.pruneAfter.")
            }
            maintenance.remove("pruneDays")
        }
        if let resetByType = session?.object("resetByType"), resetByType.has("dm") {
            if resetByType.isSet("direct") {
                changes.append("Removed session.resetByType.dm (direct already set).")
            } else {
                resetByType["direct"] = resetByType["dm"]
                changes.append("Moved session.resetByType.dm → session.resetByType.direct.")
            }
            resetByType.remove("dm")
        }
    }

    static func removeRotateBytes(_ root: MigrationObject, _ changes: inout [String]) {
        guard let maintenance = root.object("session")?.object("maintenance"), maintenance.has("rotateBytes") else { return }
        maintenance.remove("rotateBytes")
        changes.append("Removed deprecated session.maintenance.rotateBytes.")
    }

    static func removeParentForkMaxTokens(_ root: MigrationObject, _ changes: inout [String]) {
        guard let session = root.object("session"), session.has("parentForkMaxTokens") else { return }
        session.remove("parentForkMaxTokens")
        changes.append("Removed session.parentForkMaxTokens; parent fork sizing is automatic.")
    }

    static func removeZeroDurationRetention(_ root: MigrationObject, _ changes: inout [String]) {
        guard let maintenance = root.object("session")?.object("maintenance") else { return }
        for key in ["resetArchiveRetention", "pruneAfter"] {
            guard let value = maintenance[key], value.boolValue != false else { continue }
            let text: String
            if let string = value.stringValue {
                text = string
            } else if let number = value.numberValue {
                text = OpenClawJSON5.formatNumber(number)
            } else {
                continue
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let milliseconds = ConfigDuration.parseMilliseconds(text, defaultUnit: .days), milliseconds <= 0
            else { continue }
            maintenance.remove(key)
            let outcome = key == "resetArchiveRetention" ? "keep-by-default archive retention applies" : "30d session-pruning default applies"
            changes.append("Removed session.maintenance.\(key) \"\(text)\" (zero duration); \(outcome).")
        }
    }

    static func migrateWorkshopAutonomy(_ root: MigrationObject, _ changes: inout [String]) {
        guard let autonomous = root.object("skills")?.object("workshop")?.object("autonomous"), autonomous.has("enabled") else { return }
        if autonomous.isSet("mode") {
            changes.append("Removed skills.workshop.autonomous.enabled because autonomous.mode is already set.")
        } else {
            let mode = autonomous.bool("enabled") == false ? "off" : "propose"
            autonomous["mode"] = .string(mode)
            changes.append("Mapped skills.workshop.autonomous.enabled to mode: \"\(mode)\".")
        }
        autonomous.remove("enabled")
    }

    static func removeWorkshopSymlinkWrites(_ root: MigrationObject, _ changes: inout [String]) {
        if MigrationSupport.deleteRetiredPath(root, ["skills", "workshop", "allowSymlinkTargetWrites"]) {
            changes.append(
                "Removed retired skills.workshop.allowSymlinkTargetWrites; Skill Workshop writes only inside its own directory."
            )
        }
    }
}
