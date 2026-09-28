import Foundation
import OpenClawProtocol

// Agent, roster and memory-search migrations
// (`legacy-config-migrations.runtime.agents.ts`, `.runtime.entries.ts`, `legacy.roster.ts`).

extension ConfigMigrationRules {
    static func migrateBindingPeerKind(_ root: MigrationObject, _ changes: inout [String]) {
        guard let bindings = root["bindings"]?.array else { return }
        var migrated = 0
        for binding in bindings.items {
            guard let peer = binding.object?.object("match")?.object("peer"), peer.string("kind") == "dm" else { continue }
            peer["kind"] = .string("direct")
            migrated += 1
        }
        if migrated > 0 {
            changes.append(
                "Moved deprecated bindings[].match.peer.kind \"dm\" → \"direct\" for \(migrated) binding\(migrated == 1 ? "" : "s")."
            )
        }
    }

    static func removeSilentReplyConfig(_ root: MigrationObject, _ changes: inout [String]) {
        if let defaults = root.object("agents")?.object("defaults") {
            if let silentReply = defaults.object("silentReply"), silentReply.has("direct") {
                silentReply.remove("direct")
                changes.append("Removed agents.defaults.silentReply.direct; direct chats never use NO_REPLY.")
            }
            if defaults.has("silentReplyRewrite") {
                defaults.remove("silentReplyRewrite")
                changes.append("Removed agents.defaults.silentReplyRewrite.")
            }
        }
        MigrationSupport.visitAgentEntries(root) { entry, path in
            if entry.has("silentReplyRewrite") {
                entry.remove("silentReplyRewrite")
                changes.append("Removed \(path).silentReplyRewrite.")
            }
        }
        guard let surfaces = root.object("surfaces") else { return }
        for (surfaceID, value) in surfaces.entries where !MigrationSupport.isBlockedKey(surfaceID) {
            guard let surface = value.object else { continue }
            if let silentReply = surface.object("silentReply"), silentReply.has("direct") {
                silentReply.remove("direct")
                changes.append("Removed surfaces.\(surfaceID).silentReply.direct; direct chats never use NO_REPLY.")
            }
            if surface.has("silentReplyRewrite") {
                surface.remove("silentReplyRewrite")
                changes.append("Removed surfaces.\(surfaceID).silentReplyRewrite.")
            }
        }
    }

    static func removeSystemPromptOverride(_ root: MigrationObject, _ changes: inout [String]) {
        MigrationSupport.visitAgentConfigScopes(root) { scope, path in
            if scope.has("systemPromptOverride") {
                scope.remove("systemPromptOverride")
                changes.append("Removed \(path).systemPromptOverride.")
            }
        }
    }

    static func removeAgentDefaultsLLM(_ root: MigrationObject, _ changes: inout [String]) {
        guard let defaults = root.object("agents")?.object("defaults"), defaults.object("llm") != nil else { return }
        defaults.remove("llm")
        changes.append(
            "Removed agents.defaults.llm; model idle timeout now follows models.providers.<id>.timeoutSeconds within the agent/run timeout ceiling."
        )
    }

    static func removeAgentModelTimeouts(_ root: MigrationObject, _ changes: inout [String]) {
        MigrationSupport.visitAgentConfigScopes(root) { agent, path in
            for (suffix, model) in [("model", agent.object("model")), ("subagents.model", agent.object("subagents")?.object("model"))] {
                guard let model, model.has("timeoutMs") else { continue }
                model.remove("timeoutMs")
                changes.append("Removed \(path).\(suffix).timeoutMs; agent model config only selects models.")
            }
        }
    }

    static func migrateEmbeddedPi(_ root: MigrationObject, _ changes: inout [String]) {
        MigrationSupport.visitAgentConfigScopes(root) { container, path in
            guard let legacy = container.object("embeddedPi") else { return }
            if let existing = container.object("embeddedAgent") {
                MigrationSupport.mergeMissing(existing, legacy)
                changes.append(
                    "Merged \(path).embeddedPi → \(path).embeddedAgent (filled missing fields from legacy; kept explicit embeddedAgent values)."
                )
            } else {
                container["embeddedAgent"] = .object(legacy)
                changes.append("Moved \(path).embeddedPi → \(path).embeddedAgent.")
            }
            container.remove("embeddedPi")
        }
    }

    static func removeAgentRuntimePolicy(_ root: MigrationObject, _ changes: inout [String]) {
        MigrationSupport.visitAgentConfigScopes(root) { container, path in
            if container.object("embeddedHarness") != nil {
                container.remove("embeddedHarness")
                changes.append("Removed \(path).embeddedHarness; runtime is now provider/model scoped.")
            }
            if container.object("agentRuntime") != nil {
                container.remove("agentRuntime")
                changes.append("Removed \(path).agentRuntime; runtime is now provider/model scoped.")
            }
        }
    }

    static func migrateSandboxPerSession(_ root: MigrationObject, _ changes: inout [String]) {
        MigrationSupport.visitAgentConfigScopes(root) { agent, path in
            guard let sandbox = agent.object("sandbox"), sandbox.has("perSession"),
                  let perSession = sandbox.bool("perSession")
            else { return }
            let label = "\(path).sandbox"
            if sandbox.isSet("scope") {
                changes.append("Removed \(label).perSession (\(label).scope already set).")
            } else {
                let scope = perSession ? "session" : "shared"
                sandbox["scope"] = .string(scope)
                changes.append("Moved \(label).perSession → \(label).scope (\(scope)).")
            }
            sandbox.remove("perSession")
        }
    }

    static func migrateSandboxBrowserNetworkNone(_ root: MigrationObject, _ changes: inout [String]) {
        let defaultNetwork = "openclaw-sandbox-browser"
        func isNone(_ value: MigrationValue?) -> Bool {
            value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "none"
        }
        func migrateExplicit(_ browser: MigrationObject, _ label: String) {
            guard isNone(browser["network"]) else { return }
            browser["enabled"] = .bool(false)
            browser["network"] = .string(defaultNetwork)
            changes.append("Disabled \(label) and moved its unsupported network \"none\" → \"\(defaultNetwork)\".")
        }
        let defaultBrowser = root.object("agents")?.object("defaults")?.object("sandbox")?.object("browser")
        let defaultUnsupported = isNone(defaultBrowser?["network"])
        let defaultEnabled = defaultBrowser?.bool("enabled") == true
        MigrationSupport.visitAgentEntries(root) { agent, path in
            let label = "\(path).sandbox.browser"
            guard let browser = agent.object("sandbox")?.object("browser") else { return }
            if defaultUnsupported {
                let hasExplicitNetwork = browser.string("network") != nil
                if isNone(browser["network"]) {
                    migrateExplicit(browser, label)
                } else if !hasExplicitNetwork, browser.bool("enabled") == true {
                    browser["enabled"] = .bool(false)
                    changes.append("Disabled \(label) because it inherited unsupported browser network \"none\".")
                } else if hasExplicitNetwork, !browser.has("enabled"), defaultEnabled {
                    browser["enabled"] = .bool(true)
                    changes.append(
                        "Set \(label).enabled to true to preserve its explicit supported network while disabling the unsupported default browser network."
                    )
                }
                return
            }
            migrateExplicit(browser, label)
        }
        if let defaultBrowser {
            migrateExplicit(defaultBrowser, "agents.defaults.sandbox.browser")
        }
    }

    static func migrateMemorySearchOwner(_ root: MigrationObject, _ changes: inout [String]) {
        let defaults = root.object("agents")?.object("defaults")
        let legacyDefaults = defaults?.object("memorySearch")
        let legacyTopLevel = root.object("memorySearch")
        if legacyDefaults != nil || legacyTopLevel != nil {
            let canonical = root.object("memory")?.object("search")
            let target = canonical?.deepCopy() ?? MigrationObject()
            if let legacyDefaults {
                MigrationSupport.mergeMissing(target, legacyDefaults)
                defaults?.remove("memorySearch")
            }
            if let legacyTopLevel {
                MigrationSupport.mergeMissing(target, legacyTopLevel)
                root.remove("memorySearch")
            }
            root.ensureObject("memory")["search"] = .object(target)
            changes.append(
                canonical != nil
                    ? "Merged legacy memorySearch defaults → memory.search (kept explicit memory.search values)."
                    : "Moved legacy memorySearch defaults → memory.search."
            )
        }
        MigrationSupport.visitAgentEntries(root) { agent, path in
            guard let legacy = agent.object("memorySearch") else { return }
            let memory = agent.ensureObject("memory")
            let existing = memory.object("search")
            let target = existing?.deepCopy() ?? MigrationObject()
            MigrationSupport.mergeMissing(target, legacy)
            memory["search"] = .object(target)
            agent.remove("memorySearch")
            changes.append(
                existing != nil
                    ? "Merged \(path).memorySearch → \(path).memory.search (kept explicit memory.search values)."
                    : "Moved \(path).memorySearch → \(path).memory.search."
            )
        }
    }

    static func visitCanonicalMemorySearches(
        _ root: MigrationObject,
        _ changes: inout [String],
        _ migrate: (MigrationObject?, String, inout [String]) -> Void
    ) {
        migrate(root.object("memory")?.object("search"), "memory.search", &changes)
        MigrationSupport.visitAgentEntries(root) { agent, path in
            migrate(agent.object("memory")?.object("search"), "\(path).memory.search", &changes)
        }
    }

    static func migrateMemorySearchFlatKeys(_ search: MigrationObject?, _ path: String, _ changes: inout [String]) {
        guard let search else { return }
        for (legacyKey, parentKey, canonicalKey) in [
            ("chunkSize", "chunking", "tokens"), ("chunkOverlap", "chunking", "overlap"), ("maxResults", "query", "maxResults"),
        ] {
            guard search.has(legacyKey) else { continue }
            let legacyValue = search[legacyKey]
            if !search.isSet(parentKey) {
                let parent = MigrationObject()
                parent[canonicalKey] = legacyValue
                search[parentKey] = .object(parent)
                changes.append("Moved \(path).\(legacyKey) → \(path).\(parentKey).\(canonicalKey).")
                search.remove(legacyKey)
                continue
            }
            if let parent = search.object(parentKey) {
                if !parent.isSet(canonicalKey) {
                    parent[canonicalKey] = legacyValue
                    changes.append("Moved \(path).\(legacyKey) → \(path).\(parentKey).\(canonicalKey).")
                } else {
                    changes.append("Removed \(path).\(legacyKey) (\(path).\(parentKey).\(canonicalKey) already set).")
                }
            } else {
                changes.append("Removed \(path).\(legacyKey) (\(path).\(parentKey) already set).")
            }
            search.remove(legacyKey)
        }
    }

    static func rewriteMemorySearchAutoProvider(_ search: MigrationObject?, _ path: String, _ changes: inout [String]) {
        guard let search, search.string("provider")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "auto" else {
            return
        }
        search["provider"] = .string("openai")
        changes.append("Moved \(path).provider from legacy \"auto\" to \"openai\".")
    }

    static func removeMemorySearchStorePath(_ search: MigrationObject?, _ path: String, _ changes: inout [String]) {
        guard let store = search?.object("store"), store.string("path") != nil else { return }
        store.remove("path")
        changes.append("Removed \(path).store.path; memory indexes now use each agent database.")
    }

    static func migrateSessionTypingMode(_ root: MigrationObject, _ changes: inout [String]) {
        guard let session = root.object("session"), session.has("typingMode") else { return }
        let defaults = root.ensureObject("agents").ensureObject("defaults")
        let replaced = defaults.isSet("typingMode")
        defaults["typingMode"] = session["typingMode"]
        changes.append(
            replaced
                ? "Moved session.typingMode → agents.defaults.typingMode (replaced the previously shadowed agent default)."
                : "Moved session.typingMode → agents.defaults.typingMode."
        )
        session.remove("typingMode")
    }

    static func migrateRootHeartbeat(_ root: MigrationObject, _ changes: inout [String]) {
        guard let legacy = root.object("heartbeat") else { return }
        let channelKeys: Set<String> = ["showOk", "showAlerts", "useIndicator"]
        let agentHeartbeat = MigrationObject()
        let channelHeartbeat = MigrationObject()
        for (key, value) in legacy.entries where !MigrationSupport.isBlockedKey(key) {
            if channelKeys.contains(key) {
                channelHeartbeat[key] = value
            } else {
                agentHeartbeat[key] = value
            }
        }
        func merge(_ rootKey: String, _ value: MigrationObject, moved: String, merged: String) {
            let defaults = root.ensureObject(rootKey).ensureObject("defaults")
            if let existing = defaults.object("heartbeat") {
                let copy = existing.deepCopy()
                MigrationSupport.mergeMissing(copy, value)
                defaults["heartbeat"] = .object(copy)
                changes.append(merged)
            } else {
                defaults["heartbeat"] = .object(value)
                changes.append(moved)
            }
        }
        if !agentHeartbeat.isEmpty {
            merge(
                "agents", agentHeartbeat,
                moved: "Moved heartbeat → agents.defaults.heartbeat.",
                merged: "Merged heartbeat → agents.defaults.heartbeat (filled missing fields from legacy; kept explicit agents.defaults values)."
            )
        }
        if !channelHeartbeat.isEmpty {
            merge(
                "channels", channelHeartbeat,
                moved: "Moved heartbeat visibility → channels.defaults.heartbeat.",
                merged: "Merged heartbeat visibility → channels.defaults.heartbeat (filled missing fields from legacy; kept explicit channels.defaults values)."
            )
        }
        if agentHeartbeat.isEmpty, channelHeartbeat.isEmpty {
            changes.append("Removed empty top-level heartbeat.")
        }
        root.remove("heartbeat")
    }

    // MARK: Roster

    static func migrateAgentEntries(_ root: MigrationObject, _ changes: inout [String]) {
        guard let agents = root.object("agents"), let list = agents["list"]?.array else { return }
        if agents.object("entries") != nil {
            agents.remove("list")
            changes.append("Removed agents.list because canonical agents.entries is already set.")
            return
        }
        let entries = MigrationObject()
        var ids: Set<String> = []
        for (sourceIndex, value) in list.items.enumerated() {
            guard let entry = value.object else {
                changes.append("Removed malformed agents.list[\(sourceIndex)] entry.")
                continue
            }
            let rawID = ConfigValueSupport.nonEmpty(entry.string("id")) ?? "agent"
            let requestedID = MigrationSupport.normalizeAgentID(rawID)
            if requestedID != rawID {
                changes.append("Normalized agents.list id \"\(rawID)\" → agents.entries.\(requestedID).")
            }
            var id = requestedID
            var suffix = 2
            while ids.contains(id) {
                id = "\(requestedID)-\(suffix)"
                suffix += 1
            }
            let config = entry.deepCopy()
            config.remove("id")
            entries[id] = .object(config)
            ids.insert(id)
            if id != requestedID {
                changes.append("Moved duplicate agents.list id \"\(requestedID)\" to agents.entries.\(id).")
            }
        }
        agents["entries"] = .object(entries)
        agents.remove("list")
        changes.append("Moved agents.list → keyed agents.entries.")
    }

    static func stampExplicitOwnership(_ root: MigrationObject, _ changes: inout [String]) {
        guard let agents = root.object("agents"), !agents.has("ownership"), let entries = agents.object("entries") else { return }
        let roster = entries.entries.map(\.value)
        guard roster.count >= 2, !roster.contains(where: { $0.object?.bool("default") == true }) else { return }
        agents["ownership"] = .string("explicit")
        changes.append("Stamped the multi-agent roster for explicit per-surface ownership.")
    }
}
