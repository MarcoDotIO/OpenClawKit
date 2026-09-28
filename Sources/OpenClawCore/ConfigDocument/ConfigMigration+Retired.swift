import Foundation
import OpenClawProtocol

// Retired-key migrations (`legacy-config-migrations.runtime.retired*.ts`, `.tier-eval.ts`,
// `.config-tranche.ts`, `.secrets-egress.ts`) and the table of unported migrations.

extension ConfigMigrationRules {
    static func removeMemoryBackend(_ root: MigrationObject, _ changes: inout [String]) {
        guard let memory = root.object("memory"), memory.has("backend") else { return }
        memory.remove("backend")
        changes.append("Removed retired memory.backend; builtin memory is now the only memory engine.")
    }

    static func removeLocalModelLeanMarker(_ root: MigrationObject, _ changes: inout [String]) {
        guard let wizard = root.object("wizard"), wizard.has("localModelLeanAutoModel") else { return }
        let autoModel = wizard.string("localModelLeanAutoModel")
        let defaults = root.object("agents")?.object("defaults")
        let primary = defaults?["model"]?.stringValue ?? defaults?.object("model")?.string("primary")
        if let experimental = defaults?.object("experimental"), experimental.bool("localModelLean") == true {
            if let autoModel, autoModel == primary {
                experimental.remove("localModelLean")
                changes.append("Removed onboarding-owned agents.defaults.experimental.localModelLean.")
            } else {
                changes.append(
                    "Retained explicit or unowned agents.defaults.experimental.localModelLean=true; "
                        + "remove it or set it to false to restore the full tool capabilities through Tool Search."
                )
            }
        }
        wizard.remove("localModelLeanAutoModel")
        changes.append("Removed retired wizard.localModelLeanAutoModel.")
    }

    static func removeSuppressToolErrors(_ root: MigrationObject, _ changes: inout [String]) {
        guard let messages = root.object("messages"), messages.has("suppressToolErrors") else { return }
        messages.remove("suppressToolErrors")
        changes.append("Removed messages.suppressToolErrors (tool failure warnings now appear only when a run ends without a reply).")
    }

    static func removeInternalHookHandlers(_ root: MigrationObject, _ changes: inout [String]) {
        guard let internalHooks = root.object("hooks")?.object("internal"), internalHooks.has("handlers") else { return }
        internalHooks.remove("handlers")
        changes.append("Removed retired hooks.internal.handlers registrations; hook files must be migrated separately.")
        let hasNamedEntries = !(internalHooks.object("entries")?.isEmpty ?? true)
        let hasExtraDirs = internalHooks.object("load")?["extraDirs"]?.array?.items.contains {
            !($0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        } ?? false
        if internalHooks.bool("enabled") == true, !hasNamedEntries, !hasExtraDirs {
            internalHooks.remove("enabled")
            changes.append("Removed legacy-only hooks.internal.enabled to avoid enabling broad hook discovery.")
        }
    }

    // MARK: Tier-eval tranche

    private static let tierEvalRetiredRootPaths: [[String]] = [
        ["cloudWorkers", "profiles", "*", "lifetime"], ["meta", "lastTouchedAt"], ["hooks", "internal", "installs"],
        ["cron", "store"], ["plugins", "bundledDiscovery"], ["tts", "prefsPath"], ["logging", "redactSensitive"],
        ["commands", "useAccessGroups"], ["gateway", "controlUi", "allowInsecureAuth"],
        ["memory", "search", "remote", "nonBatchConcurrency"], ["memory", "search", "remote", "batch", "wait"],
        ["memory", "search", "remote", "batch", "concurrency"], ["memory", "search", "remote", "batch", "pollIntervalMs"],
        ["memory", "search", "remote", "batch", "timeoutMinutes"], ["memory", "search", "local", "contextSize"],
        ["memory", "search", "local", "modelCacheDir"], ["memory", "search", "store", "driver"], ["memory", "search", "sync"],
        ["memory", "search", "query", "hybrid"],
    ]

    private static let tierEvalRetiredAgentPaths: [[String]] = [
        ["groupChat", "visibleReplies"], ["memory", "search", "remote", "nonBatchConcurrency"],
        ["memory", "search", "remote", "batch", "wait"], ["memory", "search", "remote", "batch", "concurrency"],
        ["memory", "search", "remote", "batch", "pollIntervalMs"], ["memory", "search", "remote", "batch", "timeoutMinutes"],
        ["memory", "search", "local", "contextSize"], ["memory", "search", "local", "modelCacheDir"],
        ["memory", "search", "store", "driver"], ["memory", "search", "sync"], ["memory", "search", "query", "hybrid"],
        ["heartbeat", "ackMaxChars"], ["heartbeat", "includeReasoning"], ["heartbeat", "includeSystemPromptSection"],
        ["heartbeat", "skipWhenBusy"], ["heartbeat", "suppressToolErrorWarnings"],
    ]

    private static let responsePrefixChannels: Set<String> = [
        "buzz", "clickclack", "discord", "feishu", "googlechat", "imessage", "irc", "matrix", "mattermost", "msteams",
        "nextcloud-talk", "qa-channel", "signal", "slack", "telegram", "tlon", "twitch", "whatsapp", "zalo", "zalouser", "line",
    ]

    private struct LegacyExecPolicy {
        var security: ExecSecurity
        var ask: ExecAsk
    }

    private static func configuredExecPolicy(_ scope: MigrationObject) -> LegacyExecPolicy? {
        guard let exec = scope.object("tools")?.object("exec") else { return nil }
        switch exec.string("mode") {
        case "deny":
            return LegacyExecPolicy(security: .deny, ask: .off)
        case "allowlist":
            return LegacyExecPolicy(security: .allowlist, ask: .off)
        case "ask", "auto":
            return LegacyExecPolicy(security: .allowlist, ask: .onMiss)
        case "full":
            return LegacyExecPolicy(security: .full, ask: .off)
        default:
            break
        }
        guard let security = exec.string("security").flatMap(ExecSecurity.init(rawValue:)),
              let ask = exec.string("ask").flatMap(ExecAsk.init(rawValue:))
        else { return nil }
        return LegacyExecPolicy(security: security, ask: ask)
    }

    private static func migrateExecMode(_ scope: MigrationObject, _ path: String, _ changes: inout [String], inherited: LegacyExecPolicy?) {
        guard let exec = scope.object("tools")?.object("exec"), exec.has("security") || exec.has("ask") else { return }
        if exec.isSet("mode") {
            changes.append("Removed \(path).tools.exec.security/ask (\(path).tools.exec.mode already set).")
            exec.remove("security")
            exec.remove("ask")
            return
        }
        let ownSecurity = exec.string("security").flatMap(ExecSecurity.init(rawValue:))
        let ownAsk = exec.string("ask").flatMap(ExecAsk.init(rawValue:))
        if (exec.has("security") && ownSecurity == nil) || (exec.has("ask") && ownAsk == nil) {
            return
        }
        guard let security = ownSecurity ?? inherited?.security, let ask = ownAsk ?? inherited?.ask,
              let mode = ExecMode.exact(security: security, ask: ask)
        else { return }
        exec["mode"] = .string(mode.rawValue)
        changes.append("Moved \(path).tools.exec.security/ask → \(path).tools.exec.mode.")
        exec.remove("security")
        exec.remove("ask")
    }

    static func migrateTierEvalTranche(_ root: MigrationObject, _ changes: inout [String]) {
        let initialCount = changes.count
        var stripped = false
        // TTS persona prompts.
        func stripPrompts(_ tts: MigrationObject?, _ path: String) {
            for (personaID, persona) in tts?.object("personas")?.entries ?? [] {
                guard let object = persona.object, object.has("prompt") else { continue }
                object.remove("prompt")
                changes.append(
                    "Removed \(path).personas.\(personaID).prompt; move custom shaping into a speech provider prepareSynthesis implementation."
                )
            }
        }
        stripPrompts(root.object("tts"), "tts")
        MigrationSupport.visitAgentConfigScopes(root) { scope, path in stripPrompts(scope.object("tts"), "\(path).tts") }
        for (channelID, _) in root.object("channels")?.entries ?? [] {
            MigrationSupport.visitChannelEntries(root, channelID) { entry, path in
                stripPrompts(entry.object("tts"), "\(path).tts")
                stripPrompts(entry.object("voice")?.object("tts"), "\(path).voice.tts")
            }
        }
        // discovery.wideArea.enabled.
        if let wideArea = root.object("discovery")?.object("wideArea"), wideArea.has("enabled") {
            if wideArea.bool("enabled") == false, let domain = wideArea.string("domain"),
               !domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                wideArea.remove("enabled")
                wideArea.remove("domain")
                changes.append("Removed disabled discovery.wideArea activation fields; domain presence now enables wide-area discovery.")
            } else {
                wideArea.remove("enabled")
            }
            stripped = true
        }
        Self.migrateTierEvalChannelAliases(root, &changes)
        // session.idleMinutes.
        if let session = root.object("session"), session.has("idleMinutes") {
            let reset = session.object("reset") ?? {
                let created = MigrationObject()
                created["mode"] = .string("idle")
                return created
            }()
            if !reset.isSet("idleMinutes") {
                reset["idleMinutes"] = session["idleMinutes"]
                session["reset"] = .object(reset)
                changes.append("Moved session.idleMinutes → session.reset.idleMinutes.")
            }
            session.remove("idleMinutes")
            stripped = true
        }
        // tools.exec security/ask → mode.
        let inherited = Self.configuredExecPolicy(root)
        Self.migrateExecMode(root, "root", &changes, inherited: nil)
        MigrationSupport.visitAgentConfigScopes(root) { scope, path in
            Self.stripCompactionInstructions(scope, path, &changes)
            if path != "agents.defaults" {
                Self.migrateExecMode(scope, path, &changes, inherited: inherited)
            }
            Self.migrateCLIBackendSessionArgs(scope, path, &changes)
            for retired in Self.tierEvalRetiredAgentPaths {
                stripped = MigrationSupport.deleteRetiredPath(scope, retired) || stripped
            }
        }
        // web.enabled → channels.whatsapp.enabled.
        if let web = root.object("web") {
            if web.has("enabled") {
                let whatsapp = root.ensureObject("channels").ensureObject("whatsapp")
                if web.bool("enabled") == false, whatsapp.bool("enabled") == true {
                    changes.append("Removed web.enabled=false (channels.whatsapp.enabled already set).")
                }
                if !whatsapp.isSet("enabled") {
                    whatsapp["enabled"] = web["enabled"]
                    changes.append("Moved web.enabled → channels.whatsapp.enabled.")
                }
            }
            root.remove("web")
            stripped = true
        }
        Self.migrateMessagesResponsePrefix(root, &changes)
        for retired in Self.tierEvalRetiredRootPaths {
            stripped = MigrationSupport.deleteRetiredPath(root, retired) || stripped
        }
        for (_, provider) in root.object("secrets")?.object("providers")?.entries ?? [] {
            guard let entry = provider.object else { continue }
            stripped = entry.has("allowInsecurePath") || entry.has("allowSymlinkCommand") || stripped
            entry.remove("allowInsecurePath")
            entry.remove("allowSymlinkCommand")
        }
        if let installExec = root.object("security")?.object("installPolicy")?.object("exec") {
            stripped = installExec.has("allowInsecurePath") || installExec.has("allowSymlinkCommand") || stripped
            installExec.remove("allowInsecurePath")
            installExec.remove("allowSymlinkCommand")
        }
        if stripped || changes.count > initialCount {
            changes.append("Applied tier-eval tranche retirements; canonical settings and built-in defaults now apply.")
        }
    }

    private static func migrateTierEvalChannelAliases(_ root: MigrationObject, _ changes: inout [String]) {
        if let signal = root.object("channels")?.object("signal") {
            let inheritedURL = signal.string("httpUrl")
            let inheritedHost = signal["httpHost"]
            let inheritedPort = signal["httpPort"]
            Self.migrateSignalEndpoint(signal, "channels.signal", &changes, inheritedURL: nil, inheritedHost: nil, inheritedPort: nil)
            for (accountID, account) in signal.object("accounts")?.entries ?? [] {
                guard let object = account.object else { continue }
                Self.migrateSignalEndpoint(
                    object, "channels.signal.accounts.\(accountID)", &changes,
                    inheritedURL: inheritedURL, inheritedHost: inheritedHost, inheritedPort: inheritedPort
                )
            }
        }
        MigrationSupport.visitChannelEntries(root, "googlechat") { entry, path in
            guard entry.has("serviceAccountRef") else { return }
            let hadServiceAccount = entry.isSet("serviceAccount")
            entry["serviceAccount"] = entry["serviceAccountRef"]
            entry.remove("serviceAccountRef")
            changes.append(
                hadServiceAccount
                    ? "Moved \(path).serviceAccountRef → \(path).serviceAccount (SecretRef precedence preserved)."
                    : "Moved \(path).serviceAccountRef → \(path).serviceAccount."
            )
        }
    }

    private static func migrateSignalEndpoint(
        _ entry: MigrationObject,
        _ path: String,
        _ changes: inout [String],
        inheritedURL: String?,
        inheritedHost: MigrationValue?,
        inheritedPort: MigrationValue?
    ) {
        guard entry.has("httpHost") || entry.has("httpPort") else { return }
        if !entry.isSet("httpUrl"), inheritedURL != nil {
            entry.remove("httpHost")
            entry.remove("httpPort")
            changes.append("Removed \(path).httpHost/httpPort (inherited httpUrl already set).")
            return
        }
        if !entry.isSet("httpUrl") {
            let hostValue = (entry["httpHost"] ?? inheritedHost)?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            let rawHost = (hostValue?.isEmpty == false) ? hostValue! : "127.0.0.1"
            let host = rawHost.contains(":") && !rawHost.hasPrefix("[") ? "[\(rawHost)]" : rawHost
            let portNumber = (entry["httpPort"] ?? inheritedPort)?.numberValue
            let port = portNumber.map(OpenClawJSON5.formatNumber) ?? "8080"
            entry["httpUrl"] = .string("http://\(host):\(port)")
            if !entry.isSet("autoStart") {
                entry["autoStart"] = .bool(true)
            }
            changes.append("Moved \(path).httpHost/httpPort → \(path).httpUrl.")
        } else {
            changes.append("Removed \(path).httpHost/httpPort (\(path).httpUrl already set).")
        }
        entry.remove("httpHost")
        entry.remove("httpPort")
    }

    private static func migrateMessagesResponsePrefix(_ root: MigrationObject, _ changes: inout [String]) {
        guard let messages = root.object("messages"), let prefix = messages["responsePrefix"] else { return }
        let configured = (root.object("channels")?.entries ?? []).filter { $0.key != "defaults" && $0.value.object != nil }
        let unsupported = configured.map(\.key).filter { !Self.responsePrefixChannels.contains($0) }
        var copied = false
        for (channelID, value) in configured where Self.responsePrefixChannels.contains(channelID) {
            guard let channel = value.object, !channel.isSet("responsePrefix") else { continue }
            channel["responsePrefix"] = prefix
            copied = true
        }
        if copied {
            let suffix = unsupported.isEmpty ? "" : " for: \(unsupported.joined(separator: ", "))"
            changes.append(
                "Copied messages.responsePrefix to supported channel blocks while retaining the implicit/custom fallback\(suffix)."
            )
        }
    }

    private static func stripCompactionInstructions(_ scope: MigrationObject, _ path: String, _ changes: inout [String]) {
        guard let compaction = scope.object("compaction") else { return }
        var stripped = false
        for key in ["customInstructions", "identifierInstructions"] where compaction.has(key) {
            compaction.remove(key)
            stripped = true
        }
        if let memoryFlush = compaction.object("memoryFlush") {
            for key in ["prompt", "systemPrompt"] where memoryFlush.has(key) {
                memoryFlush.remove(key)
                stripped = true
            }
        }
        if compaction.string("identifierPolicy") == "custom" {
            compaction["identifierPolicy"] = .string("strict")
            stripped = true
        }
        if stripped {
            changes.append(
                "Removed \(path).compaction custom prompt instructions; use a compaction provider summarize() implementation and before_prompt_build hooks."
            )
        }
    }

    private static func migrateCLIBackendSessionArgs(_ scope: MigrationObject, _ path: String, _ changes: inout [String]) {
        for (backendID, value) in scope.object("cliBackends")?.entries ?? [] {
            guard let backend = value.object, backend.has("sessionArg") else { continue }
            if !backend.isSet("sessionArgs"), let sessionArg = backend.string("sessionArg") {
                backend["sessionArgs"] = .array(MigrationArray([.string(sessionArg), .string("{sessionId}")]))
                changes.append("Moved \(path).cliBackends.\(backendID).sessionArg → \(path).cliBackends.\(backendID).sessionArgs.")
            } else {
                changes.append("Removed \(path).cliBackends.\(backendID).sessionArg (sessionArgs already set).")
            }
            backend.remove("sessionArg")
        }
    }

    // MARK: Final layout

    static func migrateFinalLayoutRenames(_ root: MigrationObject, _ changes: inout [String]) {
        let defaults = root.object("agents")?.object("defaults")
        MigrationSupport.moveKey(defaults, "pdfMaxBytesMb", "pdfMaxMb", path: "agents.defaults", changes: &changes)
        if let defaults {
            let mediaModels = defaults.object("mediaModels") ?? MigrationObject()
            for (legacyKey, canonicalKey) in [("imageGenerationModel", "image"), ("videoGenerationModel", "video"),
                                              ("musicGenerationModel", "music")] where defaults.has(legacyKey) {
                if !mediaModels.isSet(canonicalKey) {
                    mediaModels[canonicalKey] = defaults[legacyKey]
                    changes.append("Moved agents.defaults.\(legacyKey) → agents.defaults.mediaModels.\(canonicalKey).")
                } else {
                    changes.append("Removed agents.defaults.\(legacyKey) (agents.defaults.mediaModels.\(canonicalKey) already set).")
                }
                defaults.remove(legacyKey)
            }
            if !mediaModels.isEmpty {
                defaults["mediaModels"] = .object(mediaModels)
            }
        }
        MigrationSupport.visitAgentConfigScopes(root) { scope, path in
            MigrationSupport.moveKey(scope.object("tools")?.object("exec"), "timeoutSec", "timeoutSeconds",
                                     path: "\(path).tools.exec", changes: &changes)
            MigrationSupport.moveKey(scope.object("sandbox")?.object("browser"), "enableNoVnc", "noVncEnabled",
                                     path: "\(path).sandbox.browser", changes: &changes)
        }
        MigrationSupport.moveKey(root.object("tools")?.object("exec"), "timeoutSec", "timeoutSeconds", path: "tools.exec", changes: &changes)
        if let env = root.object("env") {
            let vars = env.object("vars") ?? MigrationObject()
            var moved = false
            for (key, value) in env.entries where key != "vars" && key != "shellEnv" && value.stringValue != nil {
                if !vars.isSet(key) {
                    vars[key] = value
                    changes.append("Moved env.\(key) → env.vars.\(key).")
                } else {
                    changes.append("Removed env.\(key) (env.vars.\(key) already set).")
                }
                env.remove(key)
                moved = true
            }
            if moved {
                env["vars"] = .object(vars)
            }
        }
        if let ssrf = root.object("browser")?.object("ssrfPolicy"), let legacy = ssrf["hostnameAllowlist"]?.array {
            var seen: Set<String> = []
            var merged: [MigrationValue] = []
            for value in (ssrf["allowedHostnames"]?.array?.items ?? []) + legacy.items {
                guard let host = value.stringValue, seen.insert(host).inserted else { continue }
                merged.append(.string(host))
            }
            ssrf["allowedHostnames"] = .array(MigrationArray(merged))
            ssrf.remove("hostnameAllowlist")
            changes.append("Merged browser.ssrfPolicy.hostnameAllowlist → allowedHostnames.")
        }
        if let legacyMedia = root.object("media") {
            MigrationSupport.mergeMissing(root.ensureObject("attachments"), legacyMedia)
            root.remove("media")
            changes.append("Moved media → attachments.")
        }
        if let audit = root.object("audit") {
            let logging = root.ensureObject("logging")
            let canonical = logging.object("audit") ?? MigrationObject()
            MigrationSupport.mergeMissing(canonical, audit)
            logging["audit"] = .object(canonical)
            root.remove("audit")
            changes.append("Moved audit → logging.audit.")
        }
        if let nodes = root.object("gateway")?.object("nodes") {
            if let skills = nodes.object("skills"), skills.has("enabled") {
                if !nodes.isSet("allowSkills") {
                    nodes["allowSkills"] = skills["enabled"]
                }
                nodes.remove("skills")
                changes.append("Moved gateway.nodes.skills.enabled → gateway.nodes.allowSkills.")
            }
            let commands = nodes.object("commands") ?? MigrationObject()
            if nodes.has("allowCommands") {
                if !commands.isSet("allow") {
                    commands["allow"] = nodes["allowCommands"]
                }
                nodes.remove("allowCommands")
                changes.append("Moved gateway.nodes.allowCommands → gateway.nodes.commands.allow.")
            }
            if nodes.has("denyCommands") {
                if !commands.isSet("deny") {
                    commands["deny"] = nodes["denyCommands"]
                }
                nodes.remove("denyCommands")
                changes.append("Moved gateway.nodes.denyCommands → gateway.nodes.commands.deny.")
            }
            if !commands.isEmpty {
                nodes["commands"] = .object(commands)
            }
        }
        MigrationSupport.visitChannelEntries(root, "slack") { entry, path in
            MigrationSupport.moveKey(entry, "identity", "postAs", path: path, changes: &changes)
        }
    }

    static func migrateFinalLayoutKills(_ root: MigrationObject, _ changes: inout [String]) {
        let defaults = root.object("agents")?.object("defaults")
        if let defaults, defaults.has("promptOverlays") {
            if let personality = defaults.object("promptOverlays")?.object("gpt5")?["personality"] {
                let openAIConfig = root.ensureObject("plugins").ensureObject("entries").ensureObject("openai").ensureObject("config")
                if !openAIConfig.isSet("personality") {
                    openAIConfig["personality"] = personality
                    changes.append(
                        "Moved agents.defaults.promptOverlays.gpt5.personality → plugins.entries.openai.config.personality."
                    )
                } else {
                    changes.append(
                        "Removed agents.defaults.promptOverlays.gpt5.personality (plugins.entries.openai.config.personality already set)."
                    )
                }
            } else {
                changes.append("Removed agents.defaults.promptOverlays; built-in behavior now applies.")
            }
            defaults.remove("promptOverlays")
        }
        for key in ["envelopeTimestamp", "envelopeElapsed", "envelopeTimezone", "timeFormat", "bootstrapPromptTruncationWarning",
                    "mediaGenerationAutoProviderFallback"] where defaults?.has(key) == true {
            defaults?.remove(key)
            changes.append("Removed agents.defaults.\(key); built-in behavior now applies.")
        }
        let diagnostics = root.object("diagnostics")
        if let otel = diagnostics?.object("otel"), let captureContent = otel.object("captureContent") {
            let collapsed = captureContent.bool("enabled")
                ?? captureContent.entries.contains { $0.key != "enabled" && $0.value.boolValue == true }
            otel["captureContent"] = .bool(collapsed)
            changes.append("Collapsed diagnostics.otel.captureContent to a boolean.")
        }
        if let cacheTrace = diagnostics?.object("cacheTrace"),
           cacheTrace.keys.contains(where: { $0 != "enabled" }) || (cacheTrace.has("enabled") && cacheTrace.bool("enabled") == nil)
        {
            let replacement = MigrationObject()
            replacement["enabled"] = .bool(cacheTrace.bool("enabled") == true)
            diagnostics?["cacheTrace"] = .object(replacement)
            changes.append("Removed diagnostics.cacheTrace detail fields; only enabled remains.")
        }
        if let attachments = root.object("attachments"), attachments.has("preserveFilenames") {
            attachments.remove("preserveFilenames")
            changes.append("Removed attachments.preserveFilenames; temp-safe names now always apply.")
        }
        let browser = root.object("browser")
        if let browser, browser.has("color") {
            browser.remove("color")
            changes.append("Removed browser.color; the built-in color now applies.")
        }
        for (profileID, profile) in browser?.object("profiles")?.entries ?? [] {
            guard let object = profile.object, object.has("color") else { continue }
            object.remove("color")
            changes.append("Removed browser.profiles.\(profileID).color.")
        }
        Self.migrateFinalLayoutChannelKills(root, &changes)
        let messages = root.object("messages")
        if let statusReactions = messages?.object("statusReactions"), statusReactions.has("emojis") {
            statusReactions.remove("emojis")
            changes.append("Removed messages.statusReactions.emojis; curated defaults now apply.")
        }
        if let messages, messages.has("removeAckAfterReply") {
            messages.remove("removeAckAfterReply")
            changes.append("Removed messages.removeAckAfterReply; acknowledgements are retained.")
        }
        for key in ["ownerDisplay", "ownerDisplaySecret"] {
            guard let commands = root.object("commands"), commands.has(key) else { continue }
            commands.remove(key)
            changes.append("Removed commands.\(key); owner ids now render raw.")
        }
        if let cron = root.object("cron"), let failureDestination = cron.object("failureDestination") {
            let failureAlert = cron.object("failureAlert") ?? MigrationObject()
            MigrationSupport.mergeMissing(failureAlert, failureDestination)
            cron["failureAlert"] = .object(failureAlert)
            cron.remove("failureDestination")
            changes.append("Merged cron.failureDestination → cron.failureAlert.")
        }
        let gateway = root.object("gateway")
        if let reload = gateway?.object("reload"), reload.string("mode") == "restart" || reload.string("mode") == "hot" {
            reload["mode"] = .string("hybrid")
            changes.append("Mapped gateway.reload.mode to hybrid.")
        }
        if let logging = root.object("logging"), logging.string("consoleStyle") == "compact" {
            logging["consoleStyle"] = .string("pretty")
            changes.append("Mapped logging.consoleStyle compact → pretty.")
        }
        if let controlUI = gateway?.object("controlUi"), controlUI.has("chatMessageMaxWidth") {
            controlUI.remove("chatMessageMaxWidth")
            changes.append("Removed gateway.controlUi.chatMessageMaxWidth; chat width is now browser-local.")
        }
    }

    private static func migrateFinalLayoutChannelKills(_ root: MigrationObject, _ changes: inout [String]) {
        MigrationSupport.visitChannelEntries(root, "discord") { entry, path in
            if let autoPresence = entry.object("autoPresence") {
                for key in ["healthyText", "degradedText", "exhaustedText"] where autoPresence.has(key) {
                    autoPresence.remove(key)
                    changes.append("Removed \(path).autoPresence.\(key).")
                }
            }
            if let ui = entry.object("ui"), let components = ui.object("components"), components.has("accentColor") {
                components.remove("accentColor")
                changes.append("Removed \(path).ui.components.accentColor.")
                if components.isEmpty {
                    ui.remove("components")
                }
                if ui.isEmpty {
                    entry.remove("ui")
                }
            }
        }
        MigrationSupport.visitChannelEntries(root, "whatsapp") { entry, path in
            MigrationSupport.moveKey(entry, "messagePrefix", "responsePrefix", path: path, changes: &changes)
        }
        MigrationSupport.visitChannelEntries(root, "slack") { entry, path in
            guard let socketMode = entry.object("socketMode") else { return }
            for key in ["clientPingTimeout", "serverPingTimeout", "pingPongLoggingEnabled"] where socketMode.has(key) {
                socketMode.remove(key)
                changes.append("Removed \(path).socketMode.\(key).")
            }
            if socketMode.isEmpty {
                entry.remove("socketMode")
            }
        }
        MigrationSupport.visitChannelEntries(root, "imessage") { entry, path in
            if entry.has("coalesceSameSenderDms") {
                entry.remove("coalesceSameSenderDms")
                changes.append("Removed \(path).coalesceSameSenderDms.")
            }
        }
    }

    // MARK: Media models

    static func migrateMediaModels(_ root: MigrationObject, _ changes: inout [String]) {
        Self.migrateMediaDeepgram(root, &changes)
        guard let media = root.object("tools")?.object("media") else { return }
        let shared = media["models"]?.array?.items.filter { $0.object != nil } ?? []
        var migrated: [MigrationValue] = []
        var changed = false
        for capability in ["image", "audio", "video"] {
            guard let config = media.object(capability) else { continue }
            let legacy = config["models"]?.array?.items.filter { $0.object != nil } ?? []
            var signatures: Set<String> = []
            for model in legacy {
                guard let object = model.object else { continue }
                if let capabilities = object["capabilities"]?.array,
                   !capabilities.items.contains(where: { $0.stringValue == capability })
                {
                    continue
                }
                let scoped = object.deepCopy()
                scoped["capabilities"] = .array(MigrationArray([.string(capability)]))
                let signatureSource = scoped.deepCopy()
                signatureSource.remove("capabilities")
                guard signatures.insert(Self.signature(.object(signatureSource))).inserted else { continue }
                migrated.append(.object(scoped))
            }
            if config.has("models") {
                config.remove("models")
                changed = true
            }
            if config.isEmpty {
                media.remove(capability)
            }
            changed = changed || !legacy.isEmpty
        }
        let canonical = migrated + shared
        if !canonical.isEmpty {
            media["models"] = .array(MigrationArray(canonical))
        }
        if changed {
            changes.append("Consolidated tools.media image/audio/video model settings into capability-tagged tools.media.models entries.")
        }
    }

    static func migrateMediaDeepgram(_ root: MigrationObject, _ changes: inout [String]) {
        guard let media = root.object("tools")?.object("media") else { return }
        func migrateOwner(_ owner: MigrationObject, _ path: String) {
            guard let legacy = owner.object("deepgram") else { return }
            let providerOptions = owner.object("providerOptions") ?? MigrationObject()
            let canonical = providerOptions.object("deepgram") ?? MigrationObject()
            let mapped = MigrationObject()
            for (legacyKey, canonicalKey) in [("detectLanguage", "detect_language"), ("punctuate", "punctuate"),
                                              ("smartFormat", "smart_format")] {
                if let flag = legacy.bool(legacyKey) {
                    mapped[canonicalKey] = .bool(flag)
                }
            }
            for (key, value) in canonical.entries {
                mapped[key] = value
            }
            providerOptions["deepgram"] = .object(mapped)
            owner["providerOptions"] = .object(providerOptions)
            owner.remove("deepgram")
            changes.append("Moved \(path).deepgram → \(path).providerOptions.deepgram.")
        }
        func migrateModels(_ models: MigrationArray?, _ path: String) {
            for (index, model) in (models?.items ?? []).enumerated() {
                if let object = model.object {
                    migrateOwner(object, "\(path)[\(index)]")
                }
            }
        }
        migrateModels(media["models"]?.array, "tools.media.models")
        for capability in ["audio", "image", "video"] {
            guard let entry = media.object(capability) else { continue }
            migrateOwner(entry, "tools.media.\(capability)")
            migrateModels(entry["models"]?.array, "tools.media.\(capability).models")
        }
    }

    // MARK: Config tranche and tuning knobs

    static func migrateConfigTranche(_ root: MigrationObject, _ changes: inout [String]) {
        if let prefs = root.object("ui")?.object("prefs") {
            let removed = ["chatMessageMaxWidth", "textScale", "sidebarLiveActivity", "showAdvancedSettings"].filter { key in
                guard prefs.has(key) else { return false }
                prefs.remove(key)
                return true
            }
            if !removed.isEmpty {
                changes.append("Removed browser-local ui.prefs keys: \(removed.map { "ui.prefs.\($0)" }.joined(separator: ", ")).")
            }
            let ui = root.object("ui")
            if prefs.isEmpty {
                ui?.remove("prefs")
            }
            if ui?.isEmpty == true {
                root.remove("ui")
            }
        }
        var removedContextLimits = false
        func stripContextLimits(_ owner: MigrationObject) {
            for key in ["memoryGetDefaultLines", "toolResultMaxChars"] {
                removedContextLimits = MigrationSupport.deleteRetiredPath(owner, ["contextLimits", key]) || removedContextLimits
            }
        }
        if let defaults = root.object("agents")?.object("defaults") {
            stripContextLimits(defaults)
        }
        var removedTypingOverride = false
        MigrationSupport.visitAgentEntries(root) { entry, _ in
            if entry.has("typingIntervalSeconds") {
                entry.remove("typingIntervalSeconds")
                removedTypingOverride = true
            }
            stripContextLimits(entry)
        }
        if removedTypingOverride {
            changes.append(
                "Removed per-agent typingIntervalSeconds overrides; agents.defaults.typingIntervalSeconds now applies to every agent."
            )
        }
        if removedContextLimits {
            changes.append(
                "Removed contextLimits.memoryGetDefaultLines/toolResultMaxChars overrides; canonical memory and context-window caps now apply."
            )
        }
    }

    private static let retiredTuningPaths: [[String]] = [
        ["systemAgent"], ["marketplaces"], ["cli", "banner", "taglineMode"], ["commitments"], ["auth", "cooldowns"],
        ["secrets", "resolution"], ["browser", "remoteCdpTimeoutMs"], ["browser", "remoteCdpHandshakeTimeoutMs"],
        ["browser", "localLaunchTimeoutMs"], ["browser", "localCdpReadyTimeoutMs"], ["browser", "actionTimeoutMs"],
        ["browser", "cdpPortRangeStart"], ["browser", "tabCleanup", "idleMinutes"], ["browser", "tabCleanup", "maxTabsPerSession"],
        ["browser", "tabCleanup", "sweepMinutes"], ["tools", "loopDetection", "genericRepeat"],
        ["tools", "loopDetection", "knownPollNoProgress"], ["tools", "loopDetection", "pingPong"],
        ["tools", "loopDetection", "windowSize"], ["tools", "loopDetection", "historySize"],
        ["tools", "loopDetection", "warningThreshold"], ["tools", "loopDetection", "unknownToolThreshold"],
        ["tools", "loopDetection", "criticalThreshold"], ["tools", "loopDetection", "globalCircuitBreakerThreshold"],
        ["tools", "loopDetection", "detectors"], ["tools", "loopDetection", "postCompactionGuard"],
        ["gateway", "handshakeTimeoutMs"], ["gateway", "channelHealthCheckMinutes"], ["gateway", "channelStaleEventThresholdMinutes"],
        ["gateway", "channelMaxRestartsPerHour"], ["gateway", "reload", "debounceMs"], ["gateway", "reload", "deferralTimeoutMs"],
        ["gateway", "http", "endpoints", "chatCompletions", "maxBodyBytes"],
        ["gateway", "http", "endpoints", "chatCompletions", "maxImageParts"],
        ["gateway", "http", "endpoints", "chatCompletions", "maxTotalImageBytes"],
        ["gateway", "http", "endpoints", "responses", "maxBodyBytes"], ["session", "typingIntervalSeconds"],
        ["session", "writeLock"], ["session", "agentToAgent", "maxPingPongTurns"], ["cron", "maxConcurrentRuns"],
        ["cron", "triggers", "minIntervalMs"], ["cron", "retry"], ["diagnostics", "stuckSessionWarnMs"],
        ["diagnostics", "stuckSessionAbortMs"], ["diagnostics", "memoryPressureSnapshot"], ["diagnostics", "memoryPressureBundle"],
        ["web", "heartbeatSeconds"], ["web", "reconnect"], ["web", "whatsapp"], ["messages", "queue", "debounceMs"],
        ["messages", "statusReactions", "timing"], ["acp", "stream", "coalesceIdleMs"], ["acp", "stream", "maxChunkChars"],
        ["acp", "stream", "maxOutputChars"], ["acp", "stream", "maxSessionUpdateChars"], ["acp", "stream", "hiddenBoundarySeparator"],
        ["acp", "maxConcurrentSessions"], ["acp", "runtime", "ttlMinutes"], ["worktrees"], ["transcripts", "maxUtterances"],
        ["hooks", "maxBodyBytes"], ["update", "auto", "stableDelayHours"], ["update", "auto", "stableJitterHours"],
        ["update", "auto", "betaCheckIntervalHours"], ["memory", "search", "chunking"], ["memory", "search", "sync", "watchDebounceMs"],
        ["memory", "search", "sync", "intervalMinutes"], ["memory", "search", "query", "hybrid", "vectorWeight"],
        ["memory", "search", "query", "hybrid", "textWeight"], ["memory", "search", "query", "hybrid", "candidateMultiplier"],
        ["memory", "search", "query", "hybrid", "mmr", "lambda"], ["memory", "search", "query", "hybrid", "temporalDecay", "halfLifeDays"],
        ["memory", "search", "cache", "maxEntries"], ["channels", "*", "streaming", "progress", "render"],
        ["channels", "*", "accounts", "*", "streaming", "progress", "render"],
    ]

    private static let retiredAgentTuningPaths: [[String]] = [
        ["compaction", "reserveTokens"], ["compaction", "reserveTokensFloor"], ["compaction", "maxHistoryShare"],
        ["contextPruning", "keepLastAssistants"], ["contextPruning", "softTrimRatio"], ["contextPruning", "hardClearRatio"],
        ["contextPruning", "minPrunableToolChars"], ["contextPruning", "softTrim"], ["memory", "search", "chunking"],
        ["memory", "search", "sync", "watchDebounceMs"], ["memory", "search", "sync", "intervalMinutes"],
        ["memory", "search", "query", "hybrid", "vectorWeight"], ["memory", "search", "query", "hybrid", "textWeight"],
        ["memory", "search", "query", "hybrid", "candidateMultiplier"], ["memory", "search", "query", "hybrid", "mmr", "lambda"],
        ["memory", "search", "query", "hybrid", "temporalDecay", "halfLifeDays"], ["memory", "search", "cache", "maxEntries"],
        ["cliBackends", "*", "reliability", "outputLimits"],
        ["cliBackends", "*", "reliability", "watchdog", "fresh", "noOutputTimeoutMs"],
        ["cliBackends", "*", "reliability", "watchdog", "resume", "noOutputTimeoutMs"], ["runRetries"],
        ["tools", "loopDetection", "genericRepeat"], ["tools", "loopDetection", "knownPollNoProgress"],
        ["tools", "loopDetection", "pingPong"], ["tools", "loopDetection", "windowSize"], ["tools", "loopDetection", "historySize"],
        ["tools", "loopDetection", "warningThreshold"], ["tools", "loopDetection", "unknownToolThreshold"],
        ["tools", "loopDetection", "criticalThreshold"], ["tools", "loopDetection", "globalCircuitBreakerThreshold"],
        ["tools", "loopDetection", "detectors"], ["tools", "loopDetection", "postCompactionGuard"],
    ]

    static func stripRetiredTuningKnobs(_ root: MigrationObject, _ changes: inout [String]) {
        var removed: [String] = []
        for path in Self.retiredTuningPaths {
            MigrationSupport.deleteRetiredPath(root, path[...], removed: &removed)
        }
        MigrationSupport.visitAgentConfigScopes(root) { agent, prefix in
            for path in Self.retiredAgentTuningPaths {
                MigrationSupport.deleteRetiredPath(agent, path[...], removed: &removed, prefix: "\(prefix).")
            }
        }
        if !removed.isEmpty {
            changes.append("Removed retired runtime tuning knobs: \(removed.joined(separator: ", ")); built-in defaults now apply.")
        }
    }

    static func removeUIAssistant(_ root: MigrationObject, _ changes: inout [String]) {
        guard let ui = root.object("ui"), ui.has("assistant") else { return }
        ui.remove("assistant")
        if ui.isEmpty {
            root.remove("ui")
        }
        changes.append("Removed retired ui.assistant; configure agents.entries.*.identity instead.")
    }

    static func migrateRetiredConfigKeys(_ root: MigrationObject, _ changes: inout [String]) {
        if let compaction = root.object("agents")?.object("defaults")?.object("compaction"), compaction.has("truncateAfterCompaction") {
            if compaction.bool("truncateAfterCompaction") == false, compaction.has("maxActiveTranscriptBytes") {
                compaction.remove("maxActiveTranscriptBytes")
                changes.append("Removed maxActiveTranscriptBytes to preserve truncateAfterCompaction: false.")
            }
            compaction.remove("truncateAfterCompaction")
            changes.append("Removed retired agents.defaults.compaction.truncateAfterCompaction.")
        }
        if root.has("tui") {
            root.remove("tui")
            changes.append("Removed retired tui config; the footer uses the default compact display.")
        }
        if let commands = root.object("commands"), commands.has("modelsWrite") {
            commands.remove("modelsWrite")
            changes.append("Removed retired commands.modelsWrite.")
        }
        if let messages = root.object("messages"), messages.has("messagePrefix") {
            let whatsapp = root.ensureObject("channels").ensureObject("whatsapp")
            if !whatsapp.isSet("responsePrefix") {
                whatsapp["responsePrefix"] = messages["messagePrefix"]
                changes.append("Moved messages.messagePrefix → channels.whatsapp.responsePrefix.")
            } else {
                changes.append("Removed messages.messagePrefix (channels.whatsapp.responsePrefix already set).")
            }
            messages.remove("messagePrefix")
        }
        if let media = root.object("tools")?.object("media"), media.has("asyncCompletion") {
            media.remove("asyncCompletion")
            changes.append("Removed retired tools.media.asyncCompletion.directSend.")
        }
        Self.migrateMessageCrossContext(root, &changes)
        if let tools = root.object("tools"), let experimental = tools.object("experimental") {
            if experimental.has("planTool"), !tools.isSet("updatePlan") {
                tools["updatePlan"] = experimental["planTool"]
                changes.append("Moved tools.experimental.planTool → tools.updatePlan.")
            } else {
                changes.append("Removed tools.experimental; tools.updatePlan now owns the switch.")
            }
            tools.remove("experimental")
        }
        if let realtime = root.object("talk")?.object("realtime"), realtime.has("voice") {
            if !realtime.isSet("speakerVoice") {
                realtime["speakerVoice"] = realtime["voice"]
                changes.append("Moved talk.realtime.voice → talk.realtime.speakerVoice.")
            } else {
                changes.append("Removed talk.realtime.voice (talk.realtime.speakerVoice already set).")
            }
            realtime.remove("voice")
        }
        Self.migrateDiscordRealtimeVoice(root, &changes)
        Self.migrateMediaDeepgram(root, &changes)
    }

    private static func migrateDiscordRealtimeVoice(_ root: MigrationObject, _ changes: inout [String]) {
        MigrationSupport.visitChannelEntries(root, "discord") { entry, path in
            guard let realtime = entry.object("voice")?.object("realtime"), realtime.has("voice") else { return }
            if !realtime.isSet("speakerVoice") {
                realtime["speakerVoice"] = realtime["voice"]
                changes.append("Moved \(path).voice.realtime.voice → \(path).voice.realtime.speakerVoice.")
            } else {
                changes.append("Removed \(path).voice.realtime.voice (\(path).voice.realtime.speakerVoice already set).")
            }
            realtime.remove("voice")
        }
    }

    private static func migrateMessageCrossContext(_ root: MigrationObject, _ changes: inout [String]) {
        let globalMessage = root.object("tools")?.object("message")
        let globalBypass = globalMessage?.bool("allowCrossContextSend")
        let globalCrossContext = globalMessage?.object("crossContext")
        func migrate(_ message: MigrationObject?, _ path: String, agent: Bool) {
            guard let message else { return }
            let legacy = message["allowCrossContextSend"]
            let inheritedBypass = agent && globalBypass == true
            guard legacy != nil || inheritedBypass else { return }
            let crossContext = message.object("crossContext")?.deepCopy() ?? MigrationObject()
            let effectiveLegacy = legacy?.boolValue ?? (agent ? globalBypass : nil)
            if effectiveLegacy == true {
                crossContext["allowWithinProvider"] = .bool(true)
                crossContext["allowAcrossProviders"] = .bool(true)
                message["crossContext"] = .object(crossContext)
            } else if inheritedBypass {
                let within = crossContext.bool("allowWithinProvider") ?? globalCrossContext?.bool("allowWithinProvider")
                let across = crossContext.bool("allowAcrossProviders") ?? globalCrossContext?.bool("allowAcrossProviders")
                crossContext["allowWithinProvider"] = .bool(within != false)
                crossContext["allowAcrossProviders"] = .bool(across == true)
                message["crossContext"] = .object(crossContext)
            }
            message.remove("allowCrossContextSend")
            changes.append("Moved \(path).allowCrossContextSend → \(path).crossContext.")
        }
        MigrationSupport.visitAgentConfigScopes(root) { scope, path in
            if path != "agents.defaults" {
                migrate(scope.object("tools")?.object("message"), "\(path).tools.message", agent: true)
            }
        }
        migrate(globalMessage, "tools.message", agent: false)
    }

    // MARK: Plugins, secrets and root containers

    static func migrateCanvasHost(_ root: MigrationObject, _ changes: inout [String]) {
        guard root.has("canvasHost") else { return }
        let legacy = root.object("canvasHost")
        if let enabled = legacy?["enabled"] {
            let host = root.ensureObject("plugins").ensureObject("entries").ensureObject("canvas").ensureObject("config").ensureObject("host")
            if !host.isSet("enabled") {
                host["enabled"] = enabled
                changes.append("Moved canvasHost.enabled → plugins.entries.canvas.config.host.enabled.")
            }
        }
        root.remove("canvasHost")
        changes.append("Removed retired canvasHost; only plugins.entries.canvas.config.host.enabled remains.")
    }

    static func migrateSecretsEgressHosts(_ root: MigrationObject, _ changes: inout [String]) {
        guard let egressProxy = root.object("secrets")?.object("egressProxy") else { return }
        for key in ["bypassHosts", "allowedHosts"] {
            guard let hosts = egressProxy[key]?.array else { continue }
            let valid = hosts.items.filter { $0.stringValue.map(Self.isValidExactHostname) ?? false }
            guard valid.count != hosts.items.count else { continue }
            let invalid = hosts.items.filter { !($0.stringValue.map(Self.isValidExactHostname) ?? false) }
            if valid.isEmpty {
                egressProxy.remove(key)
            } else {
                egressProxy[key] = .array(MigrationArray(valid))
            }
            let rendered = invalid.map { OpenClawJSON5.serialize($0.anyCodable, prettyPrinted: false) }.joined(separator: ", ")
            changes.append("Removed unusable secrets.egressProxy.\(key) entries: \(rendered).")
        }
    }

    /// Port of `normalizeExactAllowedHost` validation (exact hostname or IP, no scheme/port/wildcard).
    static func isValidExactHostname(_ raw: String) -> Bool {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while trimmed.hasSuffix(".") {
            trimmed.removeLast()
        }
        guard !trimmed.contains("*") else { return false }
        let unbracketed = trimmed.hasPrefix("[") && trimmed.hasSuffix("]") ? String(trimmed.dropFirst().dropLast()) : trimmed
        if Self.isIPAddress(unbracketed) {
            return true
        }
        guard !unbracketed.isEmpty, !unbracketed.contains(":"),
              !unbracketed.contains(where: { $0.isWhitespace || "/?#@".contains($0) }),
              unbracketed.count <= 253
        else { return false }
        return unbracketed.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }

    static func isIPAddress(_ value: String) -> Bool {
        let octets = value.split(separator: ".", omittingEmptySubsequences: false)
        if octets.count == 4, octets.allSatisfy({ UInt8($0) != nil && !$0.isEmpty }) {
            return true
        }
        guard value.contains(":") else { return false }
        return value.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." } && value.split(separator: ":", omittingEmptySubsequences: false).count <= 8
    }

    static func removeRetiredRootContainers(_ root: MigrationObject, _ changes: inout [String]) {
        for key in ["cli", "audio"] where root.has(key) {
            root.remove(key)
            changes.append("Removed retired root \(key) config; upstream no longer accepts it.")
        }
    }

    // MARK: Unported migrations

    private static func issue(_ path: String, _ message: String, _ kind: ConfigDecodeIssue.Kind) -> ConfigDecodeIssue {
        ConfigDecodeIssue(path: path, message: message, kind: kind)
    }

    static var unported: [ConfigUnportedMigration] {
        [
            .init(id: "legacy.pre-multi-agent-root", summary: "routing/agent/identity root keys have no migration path") { root in
                ["routing", "agent", "identity"].filter(root.has).map {
                    Self.issue(
                        $0,
                        "Top-level \($0) is a pre-multi-agent key without a migration path; "
                            + "fix it by hand against the current configuration reference.",
                        .invalidValue
                    )
                }
            },
            .init(id: "runtime.memory-qmd-retired", summary: "memory.qmd paths need openclaw doctor") { root in
                guard root.object("memory")?.has("qmd") == true else { return [] }
                return [Self.issue(
                    "memory.qmd",
                    "memory.qmd is retired; run openclaw doctor --fix to import its paths into memory.search.extraPaths.",
                    .retiredKey
                )]
            },
            .init(id: "plugins.installs-state-import", summary: "plugins.installs records move to the shared state database") { root in
                guard root.object("plugins")?.has("installs") == true else { return [] }
                return [Self.issue(
                    "plugins.installs",
                    "plugins.installs moved to shared SQLite state; the gateway imports it on startup (left in place).",
                    .retiredKey
                )]
            },
            .init(id: "tools.allow-also-allow-conflict", summary: "allow and alsoAllow in the same scope need a permission-preserving merge") { root in
                var issues: [ConfigDecodeIssue] = []
                func check(_ tools: MigrationObject?, _ path: String) {
                    guard let tools, !(tools["allow"]?.array?.items.isEmpty ?? true), !(tools["alsoAllow"]?.array?.items.isEmpty ?? true) else {
                        return
                    }
                    issues.append(Self.issue(
                        path,
                        "\(path) sets both allow and alsoAllow; upstream rejects this until openclaw doctor --fix merges them.",
                        .invalidValue
                    ))
                }
                check(root.object("tools"), "tools")
                MigrationSupport.visitAgentEntries(root) { agent, path in check(agent.object("tools"), "\(path).tools") }
                return issues
            },
            .init(id: "runtime.legacy-system-agent-owner", summary: "System-agent/heartbeat owner seeding needs the original roster") { _ in [] },
            .init(id: "channels.account-binding-repair", summary: "Unbound channel accounts need an explicit binding") { _ in [] },
            .init(id: "gateway.controlUi.allowedOrigins-seed-for-non-loopback", summary: "Seeding Control UI origins needs host context") { _ in [] },
            .init(id: "runtime.utility-model-separation", summary: "Utility model separation needs the previous config") { _ in [] },
            .init(id: "plugins.voice-call", summary: "Voice-call plugin migrations are plugin-owned") { root in
                guard root.object("plugins")?.object("entries")?.object("voice-call") != nil else { return [] }
                return [Self.issue(
                    "plugins.entries.voice-call",
                    "Voice-call plugin config migrations are plugin-owned; run openclaw doctor --fix.",
                    .legacyKey
                )]
            },
        ]
    }
}
