import Foundation
import OpenClawProtocol

// Registry of ported doctor migrations, in upstream application order:
// config normalization (check 1), channels, audio, runtime (agents, code mode, cron, diagnostics,
// gateway, MCP, models, TTS, retired, secrets egress, session, skills, roster entries, system agent).
// Each rule keeps the upstream migration id so later syncs can diff this table against
// `docs/gateway/doctor/config-migrations.md`.

enum ConfigMigrationRules {
    static var all: [ConfigMigrationRule] {
        [
            // Check 1: config normalization.
            .init(id: "models.providers.api-openai->openai-completions", summary: "Rename the legacy \"openai\" API id",
                  apply: Self.normalizeLegacyOpenAIModelProviderAPI),
            .init(id: "talk.legacy-provider-shape", summary: "Move legacy talk voice fields into talk.providers and talk.realtime",
                  apply: Self.normalizeLegacyTalkConfig),
            .init(id: "browser.legacy-config", summary: "Normalize legacy browser relay and SSRF keys",
                  apply: Self.normalizeLegacyBrowserConfig),
            // Channels.
            .init(id: "channels.webchat-remove", summary: "Remove retired WebChat channel config", apply: Self.removeChannelsWebchat),
            .init(id: "legacy-group-routing->channel-groups", summary: "Move legacy routing group chat settings to channel groups and messages",
                  apply: Self.migrateLegacyGroupRouting),
            .init(id: "feishu.accounts.botName->name", summary: "Move legacy Feishu account botName to name",
                  apply: Self.migrateFeishuAccountBotName),
            .init(id: "thread-bindings.ttlHours->idleHours", summary: "Rename threadBindings.ttlHours",
                  apply: Self.migrateThreadBindingTTL),
            // Audio.
            .init(id: "audio.transcription-v2", summary: "Move audio.transcription to tools.media.models",
                  apply: Self.migrateAudioTranscription),
            // Runtime: agents.
            .init(id: "bindings.match.peer.kind.dm-to-direct", summary: "Rename binding peer kind dm to direct",
                  apply: Self.migrateBindingPeerKind),
            .init(id: "silentReplyRewrite-removed", summary: "Remove silent reply rewrite config", apply: Self.removeSilentReplyConfig),
            .init(id: "agents.systemPromptOverride-removed", summary: "Remove agent system prompt overrides",
                  apply: Self.removeSystemPromptOverride),
            .init(id: "agents.defaults.llm->models.providers.timeoutSeconds", summary: "Remove agents.defaults.llm",
                  apply: Self.removeAgentDefaultsLLM),
            .init(id: "agents.model.timeoutMs-ignored", summary: "Remove ignored model timeoutMs", apply: Self.removeAgentModelTimeouts),
            .init(id: "agents.embeddedPi->embeddedAgent", summary: "Rename embeddedPi", apply: Self.migrateEmbeddedPi),
            .init(id: "agents.agentRuntime-ignored", summary: "Remove agent-wide runtime policy", apply: Self.removeAgentRuntimePolicy),
            .init(id: "agents.sandbox.perSession->scope", summary: "Move sandbox.perSession to sandbox.scope",
                  apply: Self.migrateSandboxPerSession),
            .init(id: "agents.sandbox.browser.network-none", summary: "Disable sandbox browsers using network none",
                  apply: Self.migrateSandboxBrowserNetworkNone),
            .init(id: "memorySearch->memory.search", summary: "Move memorySearch to memory.search", apply: Self.migrateMemorySearchOwner),
            .init(id: "memorySearch.flat-fields->nested-fields", summary: "Nest legacy flat memory search fields",
                  apply: { root, changes in Self.visitCanonicalMemorySearches(root, &changes, Self.migrateMemorySearchFlatKeys) }),
            .init(id: "memorySearch.provider-auto->openai", summary: "Rewrite memory search provider auto",
                  apply: { root, changes in Self.visitCanonicalMemorySearches(root, &changes, Self.rewriteMemorySearchAutoProvider) }),
            .init(id: "memorySearch.store.path->agent-database", summary: "Remove memory search store paths",
                  apply: { root, changes in Self.visitCanonicalMemorySearches(root, &changes, Self.removeMemorySearchStorePath) }),
            .init(id: "session.typingMode->agents.defaults.typingMode", summary: "Move session.typingMode",
                  apply: Self.migrateSessionTypingMode),
            .init(id: "heartbeat->agents.defaults.heartbeat", summary: "Move top-level heartbeat", apply: Self.migrateRootHeartbeat),
            // Runtime: code mode, cron, diagnostics.
            .init(id: "tools.codeMode.javascript-only", summary: "Remove tools.codeMode.languages", apply: Self.removeCodeModeLanguages),
            .init(id: "tools.codeMode.executor", summary: "Move tools.codeMode.runtime to executor", apply: Self.migrateCodeModeRuntime),
            .init(id: "cron.webhook-remove", summary: "Remove cron.webhook", apply: Self.removeCronWebhook),
            .init(id: "cron.runLog-remove", summary: "Remove cron.runLog", apply: Self.removeCronRunLog),
            .init(id: "diagnostics.otel.grpc-protocol", summary: "Remove the unsupported otel grpc protocol",
                  apply: Self.migrateOtelGrpcProtocol),
            // Runtime: gateway.
            .init(id: "gateway.control-ui-tool-titles-remove", summary: "Remove controlUi.toolTitles",
                  apply: Self.removeControlUIToolTitles),
            .init(id: "gateway.tailscale.service-name-remove", summary: "Remove tailscale.serviceName",
                  apply: Self.removeTailscaleServiceName),
            .init(id: "gateway.tailscale.reset-on-exit-remove", summary: "Remove tailscale.resetOnExit",
                  apply: Self.removeTailscaleResetOnExit),
            .init(id: "gateway.control-ui-device-auth-bypass->pairing-migration", summary: "Remove controlUi.dangerouslyDisableDeviceAuth",
                  apply: Self.removeControlUIDeviceAuthBypass),
            .init(id: "gateway.webchat-remove", summary: "Remove gateway.webchat", apply: Self.removeGatewayWebchat),
            .init(id: "gateway.port-oob-repair", summary: "Remove out-of-range gateway.port", apply: Self.repairGatewayPort),
            .init(id: "gateway.bind.host-alias->bind-mode", summary: "Normalize gateway.bind host aliases",
                  apply: Self.normalizeGatewayBind),
            // Runtime: MCP and models.
            .init(id: "mcp.servers.canonicalize", summary: "Normalize legacy MCP server keys", apply: Self.canonicalizeMCPServers),
            .init(id: "defaultModel->agents.defaults.model", summary: "Move the root defaultModel", apply: Self.migrateRootDefaultModel),
            .init(id: "models.pricing-retired", summary: "Remove models.pricing", apply: Self.removeModelsPricing),
            // Runtime: TTS.
            .init(id: "tts.top-level-owner", summary: "Move messages.tts to top-level tts", apply: Self.migrateMessagesTTS),
            .init(id: "tts.providers-generic-shape", summary: "Move bundled TTS provider keys into tts.providers",
                  apply: Self.migrateTTSProviderKeys),
            .init(id: "tts.speaker-selection-keys", summary: "Rename TTS voice keys", apply: Self.migrateTTSSpeakerKeys),
            .init(id: "tts.enabled-auto-mode", summary: "Move tts.enabled to tts.auto", apply: Self.migrateTTSEnabled),
            // Runtime: retired keys.
            .init(id: "runtime.memory-qmd-retired", summary: "Remove memory.backend", apply: Self.removeMemoryBackend),
            .init(id: "runtime.automatic-local-model-lean", summary: "Remove wizard.localModelLeanAutoModel",
                  apply: Self.removeLocalModelLeanMarker),
            .init(id: "runtime.messages-suppress-tool-errors", summary: "Remove messages.suppressToolErrors",
                  apply: Self.removeSuppressToolErrors),
            .init(id: "runtime.retired-internal-hook-handlers", summary: "Remove hooks.internal.handlers",
                  apply: Self.removeInternalHookHandlers),
            .init(id: "runtime.doctor-tier-eval-tranche", summary: "Consolidate tier-eval surfaces", apply: Self.migrateTierEvalTranche),
            .init(id: "runtime.final-layout-polish", summary: "Normalize final layout names", apply: Self.migrateFinalLayoutRenames),
            .init(id: "runtime.final-layout-kills", summary: "Remove final layout knobs", apply: Self.migrateFinalLayoutKills),
            .init(id: "runtime.media-models-consolidation", summary: "Consolidate media model config", apply: Self.migrateMediaModels),
            .init(id: "runtime.config-tranche", summary: "Remove presentation-only and duplicate options",
                  apply: Self.migrateConfigTranche),
            .init(id: "runtime.tuning-knobs-purge", summary: "Remove retired tuning knobs", apply: Self.stripRetiredTuningKnobs),
            .init(id: "runtime.ui-assistant-identity", summary: "Remove ui.assistant", apply: Self.removeUIAssistant),
            .init(id: "runtime.retired-config-keys", summary: "Migrate retired root and tool keys", apply: Self.migrateRetiredConfigKeys),
            .init(id: "canvasHost->plugins.entries.canvas.config.host", summary: "Move canvasHost to the canvas plugin",
                  apply: Self.migrateCanvasHost),
            .init(id: "runtime.secrets-egress-proxy-hosts", summary: "Drop unusable egress proxy hosts",
                  apply: Self.migrateSecretsEgressHosts),
            // Runtime: session and skills.
            .init(id: "session.canonical-aliases", summary: "Rename session aliases", apply: Self.migrateSessionAliases),
            .init(id: "session.maintenance.rotateBytes", summary: "Remove maintenance.rotateBytes", apply: Self.removeRotateBytes),
            .init(id: "session.parentForkMaxTokens", summary: "Remove session.parentForkMaxTokens", apply: Self.removeParentForkMaxTokens),
            .init(id: "session.maintenance.zero-duration-retention", summary: "Remove zero-duration retention",
                  apply: Self.removeZeroDurationRetention),
            .init(id: "skills.workshop.autonomous.enabled->mode", summary: "Map workshop autonomy to mode",
                  apply: Self.migrateWorkshopAutonomy),
            .init(id: "skills.workshop.allowSymlinkTargetWrites-retired", summary: "Remove allowSymlinkTargetWrites",
                  apply: Self.removeWorkshopSymlinkWrites),
            // Runtime: roster and root containers.
            .init(id: "runtime.agents-entries", summary: "Move agents.list to keyed agents.entries", apply: Self.migrateAgentEntries),
            .init(id: "runtime.agents-explicit-ownership", summary: "Stamp explicit ownership on markerless rosters",
                  apply: Self.stampExplicitOwnership),
            .init(id: "crestodian-retired", summary: "Remove crestodian", apply: Self.removeRootKey("crestodian",
                  message: "Removed retired crestodian config; system-agent rescue uses built-in policy.")),
            .init(id: "runtime.retired-root-keys", summary: "Remove retired root containers", apply: Self.removeRetiredRootContainers),
        ]
    }

    // MARK: Helpers

    static func removeRootKey(_ key: String, message: String) -> (MigrationObject, inout [String]) -> Void {
        { root, changes in
            guard root.has(key) else { return }
            root.remove(key)
            changes.append(message)
        }
    }

    static func isSafeExecutable(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\0") else {
            return false
        }
        if trimmed.contains(where: { $0 == "\r" || $0 == "\n" }) {
            return false
        }
        if trimmed.contains(where: { ";&|`$<>\"'".contains($0) }) {
            return false
        }
        let isLikelyPath = trimmed.hasPrefix(".") || trimmed.hasPrefix("~") || trimmed.contains("/") || trimmed.contains("\\")
        if isLikelyPath {
            return true
        }
        if trimmed.hasPrefix("-") {
            return false
        }
        return trimmed.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._+-".contains($0)) }
    }

    /// Stable JSON signature (sorted keys) of a migration value.
    static func signature(_ value: MigrationValue) -> String {
        OpenClawJSON5.serialize(value.anyCodable, sortedKeys: true, prettyPrinted: false)
    }

    // MARK: Check 1 normalizers

    static func normalizeLegacyOpenAIModelProviderAPI(_ root: MigrationObject, _ changes: inout [String]) {
        guard let providers = root.object("models")?.object("providers") else { return }
        for (providerID, value) in providers.entries {
            guard let provider = value.object else { continue }
            if provider.string("api") == "openai" {
                provider["api"] = .string("openai-completions")
                changes.append("Moved models.providers.\(providerID).api \"openai\" → \"openai-completions\".")
            }
            if let models = provider["models"]?.array {
                for (index, model) in models.items.enumerated() {
                    guard let object = model.object, object.string("api") == "openai" else { continue }
                    object["api"] = .string("openai-completions")
                    changes.append("Moved models.providers.\(providerID).models[\(index)].api \"openai\" → \"openai-completions\".")
                }
            }
        }
    }

    static func normalizeLegacyTalkConfig(_ root: MigrationObject, _ changes: inout [String]) {
        guard let talk = root.object("talk") else { return }
        let legacySpeechKeys = ["voiceId", "voiceAliases", "modelId", "outputFormat", "apiKey"]
        let presentSpeech = legacySpeechKeys.filter { talk.has($0) }
        if !presentSpeech.isEmpty {
            let providers = talk.ensureObject("providers")
            let providerID = ConfigValueSupport.nonEmpty(talk.string("provider"))?.lowercased()
                ?? (providers.count == 1 ? providers.keys[0] : "elevenlabs")
            let target = providers.ensureObject(providerID)
            for key in presentSpeech {
                if !target.isSet(key) {
                    target[key] = talk[key]
                }
                talk.remove(key)
            }
            if !talk.has("provider") {
                talk["provider"] = .string(providerID)
            }
            changes.append("Moved legacy talk.\(presentSpeech.joined(separator: "/")) → talk.providers.\(providerID).")
        }
        let legacyRealtimeKeys = ["model", "mode", "transport", "brain", "voice"]
        let presentRealtime = legacyRealtimeKeys.filter { talk.has($0) }
        guard !presentRealtime.isEmpty else { return }
        if talk.has("realtime") {
            for key in presentRealtime {
                talk.remove(key)
            }
            changes.append("Removed legacy talk.\(presentRealtime.joined(separator: "/")) (talk.realtime already set).")
            return
        }
        let realtime = MigrationObject()
        for key in ["model", "mode", "transport", "brain"] where talk.has(key) {
            realtime[key] = talk[key]
        }
        if let voice = talk["voice"] {
            realtime["speakerVoice"] = voice
        }
        for key in presentRealtime {
            talk.remove(key)
        }
        talk["realtime"] = .object(realtime)
        changes.append("Moved legacy realtime Talk provider/model fields into talk.realtime.")
    }

    static func normalizeLegacyBrowserConfig(_ root: MigrationObject, _ changes: inout [String]) {
        guard let browser = root.object("browser") else { return }
        if browser.has("relayBindHost") {
            browser.remove("relayBindHost")
            changes.append("Removed browser.relayBindHost (legacy Chrome extension relay setting).")
        }
        if let profiles = browser.object("profiles") {
            for (name, value) in profiles.entries {
                guard let profile = value.object,
                      ConfigValueSupport.nonEmpty(profile.string("driver")) == "extension",
                      ConfigValueSupport.nonEmpty(profile.string("cdpUrl")) != nil
                else { continue }
                profile.remove("cdpUrl")
                changes.append("Removed browser.profiles.\(name).cdpUrl (extension driver profiles own their relay endpoint).")
            }
        }
        if let ssrf = browser.object("ssrfPolicy"), ssrf.has("allowPrivateNetwork") {
            let legacy = ssrf["allowPrivateNetwork"]
            let current = ssrf["dangerouslyAllowPrivateNetwork"]
            var resolved = current
            if legacy?.boolValue != nil || current?.boolValue != nil {
                resolved = .bool(legacy?.boolValue == true || current?.boolValue == true)
            } else if current == nil {
                resolved = legacy
            }
            ssrf.remove("allowPrivateNetwork")
            if let resolved {
                ssrf["dangerouslyAllowPrivateNetwork"] = resolved
            }
            changes.append("Moved browser.ssrfPolicy.allowPrivateNetwork → browser.ssrfPolicy.dangerouslyAllowPrivateNetwork.")
        }
    }

    // MARK: Channels and audio

    static func removeChannelsWebchat(_ root: MigrationObject, _ changes: inout [String]) {
        guard let channels = root.object("channels"), channels.has("webchat") else { return }
        channels.remove("webchat")
        changes.append("Removed retired channels.webchat config (WebChat is retired).")
    }

    // MARK: legacy-group-routing->channel-groups

    static func migrateLegacyGroupRouting(_ root: MigrationObject, _ changes: inout [String]) {
        Self.migrateRoutingAllowFrom(root, &changes)
        Self.migrateRoutingGroupChat(root, &changes)
        Self.migrateTelegramRequireMention(root, &changes)
    }

    private static func removeEmptyObject(_ owner: MigrationObject, _ key: String) {
        if owner.object(key)?.isEmpty == true {
            owner.remove(key)
        }
    }

    /// Upstream `resolveCompatibleDefaultGroupEntry` + `migrateChannelDefaultRequireMention`.
    private static func migrateDefaultGroupRequireMention(
        _ section: MigrationObject,
        channelID: String,
        legacyPath: String,
        requireMention: MigrationValue,
        _ changes: inout [String]
    ) {
        if section.has("groups"), section.object("groups") == nil {
            changes.append("Removed \(legacyPath) (channels.\(channelID).groups has an incompatible shape; fix remaining issues manually).")
            return
        }
        let groups = section.object("groups") ?? MigrationObject()
        if groups.has("*"), groups.object("*") == nil {
            changes.append("Removed \(legacyPath) (channels.\(channelID).groups has an incompatible shape; fix remaining issues manually).")
            return
        }
        let entry = groups.object("*") ?? MigrationObject()
        guard !entry.isSet("requireMention") else {
            changes.append("Removed \(legacyPath) (channels.\(channelID).groups.\"*\" already set).")
            return
        }
        entry["requireMention"] = requireMention
        groups["*"] = .object(entry)
        section["groups"] = .object(groups)
        changes.append("Moved \(legacyPath) → channels.\(channelID).groups.\"*\".requireMention.")
    }

    private static func migrateRoutingAllowFrom(_ root: MigrationObject, _ changes: inout [String]) {
        guard let routing = root.object("routing"), let allowFrom = routing["allowFrom"] else { return }
        if let whatsapp = root.object("channels")?.object("whatsapp") {
            if whatsapp.isSet("allowFrom") {
                changes.append("Removed routing.allowFrom (channels.whatsapp.allowFrom already set).")
            } else {
                whatsapp["allowFrom"] = allowFrom
                changes.append("Moved routing.allowFrom → channels.whatsapp.allowFrom.")
            }
        } else {
            changes.append("Removed routing.allowFrom (channels.whatsapp not configured).")
        }
        routing.remove("allowFrom")
        Self.removeEmptyObject(root, "routing")
    }

    private static func migrateRoutingGroupChat(_ root: MigrationObject, _ changes: inout [String]) {
        guard let routing = root.object("routing"), let groupChat = routing.object("groupChat") else { return }
        if let requireMention = groupChat["requireMention"] {
            var matchedChannel = false
            if let channels = root.object("channels") {
                for channelID in ["whatsapp", "telegram", "imessage"] {
                    guard let section = channels.object(channelID) else { continue }
                    matchedChannel = true
                    Self.migrateDefaultGroupRequireMention(
                        section,
                        channelID: channelID,
                        legacyPath: "routing.groupChat.requireMention",
                        requireMention: requireMention,
                        &changes
                    )
                }
            }
            if !matchedChannel {
                changes.append("Removed routing.groupChat.requireMention (no configured WhatsApp, Telegram, or iMessage channel found).")
            }
            groupChat.remove("requireMention")
        }
        for field in ["historyLimit", "mentionPatterns"] {
            guard let value = groupChat[field] else { continue }
            let messagesGroup = root.ensureObject("messages").ensureObject("groupChat")
            if messagesGroup.isSet(field) {
                changes.append("Removed routing.groupChat.\(field) (messages.groupChat.\(field) already set).")
            } else {
                messagesGroup[field] = value
                changes.append("Moved routing.groupChat.\(field) → messages.groupChat.\(field).")
            }
            groupChat.remove(field)
        }
        Self.removeEmptyObject(routing, "groupChat")
        Self.removeEmptyObject(root, "routing")
    }

    private static func migrateTelegramRequireMention(_ root: MigrationObject, _ changes: inout [String]) {
        guard let telegram = root.object("channels")?.object("telegram"), let requireMention = telegram["requireMention"] else { return }
        Self.migrateDefaultGroupRequireMention(
            telegram,
            channelID: "telegram",
            legacyPath: "channels.telegram.requireMention",
            requireMention: requireMention,
            &changes
        )
        telegram.remove("requireMention")
    }

    static func migrateFeishuAccountBotName(_ root: MigrationObject, _ changes: inout [String]) {
        guard let accounts = root.object("channels")?.object("feishu")?.object("accounts") else { return }
        for (accountID, value) in accounts.entries {
            guard let account = value.object, account.has("botName") else { continue }
            let legacyPath = "channels.feishu.accounts.\(accountID).botName"
            let currentPath = "channels.feishu.accounts.\(accountID).name"
            if account.isSet("name") {
                changes.append("Removed \(legacyPath) (\(currentPath) already set).")
            } else {
                account["name"] = account["botName"]
                changes.append("Moved \(legacyPath) → \(currentPath).")
            }
            account.remove("botName")
        }
    }

    static func migrateThreadBindingTTL(_ root: MigrationObject, _ changes: inout [String]) {
        func migrate(_ owner: MigrationObject?, _ path: String) {
            guard let bindings = owner?.object("threadBindings"), bindings.has("ttlHours") else { return }
            if bindings.isSet("idleHours") {
                changes.append("Removed \(path).threadBindings.ttlHours (\(path).threadBindings.idleHours already set).")
            } else {
                bindings["idleHours"] = bindings["ttlHours"]
                changes.append("Moved \(path).threadBindings.ttlHours → \(path).threadBindings.idleHours.")
            }
            bindings.remove("ttlHours")
        }
        migrate(root.object("session"), "session")
        guard let channels = root.object("channels") else { return }
        for (channelID, _) in channels.entries where channelID != "defaults" {
            MigrationSupport.visitChannelEntries(root, channelID) { entry, path in
                migrate(entry, path)
            }
        }
    }

    static func migrateAudioTranscription(_ root: MigrationObject, _ changes: inout [String]) {
        guard let audio = root.object("audio"), let transcription = audio["transcription"] else { return }
        if let mapped = Self.mapLegacyAudioTranscription(transcription) {
            let media = root.ensureObject("tools").ensureObject("media")
            let mediaAudio = media.ensureObject("audio")
            let models = media["models"]?.array ?? MigrationArray()
            func isAudioCompatible(_ value: MigrationValue) -> Bool {
                guard let model = value.object else { return false }
                guard let capabilities = model["capabilities"]?.array else { return true }
                return capabilities.items.contains { $0.stringValue == "audio" }
            }
            let hasAudioModel = (mediaAudio["models"]?.array?.items.contains(where: isAudioCompatible) ?? false)
                || models.items.contains(where: isAudioCompatible)
            if !hasAudioModel {
                mediaAudio["enabled"] = .bool(true)
                if let command = mapped.string("command") {
                    mediaAudio["preferredModel"] = .string("cli:\(command)")
                }
                mapped["capabilities"] = .array(MigrationArray([.string("audio")]))
                models.items.append(.object(mapped))
                media["models"] = .array(models)
                changes.append("Moved audio.transcription → tools.media.models.")
            } else {
                changes.append("Removed audio.transcription (tools.media.models already set).")
            }
        } else {
            changes.append("Removed audio.transcription (invalid or empty command).")
        }
        audio.remove("transcription")
        if audio.isEmpty {
            root.remove("audio")
        }
    }

    static func mapLegacyAudioTranscription(_ value: MigrationValue) -> MigrationObject? {
        guard let transcriber = value.object,
              let command = transcriber["command"]?.array,
              !command.items.isEmpty
        else { return nil }
        let parts = command.items.compactMap(\.stringValue)
        guard parts.count == command.items.count, let executable = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines),
              !executable.isEmpty, Self.isSafeExecutable(executable)
        else { return nil }
        let result = MigrationObject()
        result["command"] = .string(executable)
        result["type"] = .string("cli")
        let args = parts.dropFirst().map { $0.replacingOccurrences(of: "{input}", with: "{{AttachmentPath}}") }
        if !args.isEmpty {
            result["args"] = .array(MigrationArray(args.map { .string($0) }))
        }
        if let timeout = transcriber["timeoutSeconds"], timeout.isNumber {
            result["timeoutSeconds"] = timeout
        }
        return result
    }
}
