import Foundation

/// How the Swift embedded runtime supports a core tool id.
public enum CoreToolAvailability: String, Codable, Sendable, Equatable, CaseIterable {
    /// The SDK can register a native implementation on every platform.
    case provided
    /// Native implementation on macOS and Linux only (process spawning).
    case providedDesktopOnly = "provided-desktop-only"
    /// Recognized for policy and catalog purposes only; implementations may arrive through MCP or client tools.
    case recognizedOnly = "recognized-only"
}

/// One core tool catalog section (upstream `CORE_TOOL_SECTION_ORDER`).
public struct CoreToolSection: Codable, Sendable, Equatable, Hashable {
    /// Section identifier (`fs`, `runtime`, …).
    public let id: String
    /// Display label.
    public let label: String

    /// Creates a section.
    /// - Parameters:
    ///   - id: Section identifier.
    ///   - label: Display label.
    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

/// One core tool definition (upstream `CORE_TOOL_DEFINITIONS`).
public struct CoreToolDefinition: Codable, Sendable, Equatable, Hashable {
    /// Tool identifier.
    public let id: String
    /// Short description.
    public let description: String
    /// Section identifier.
    public let sectionID: String
    /// Profiles that include the tool.
    public let profiles: [ToolProfileID]
    /// Whether the tool belongs to `group:openclaw`.
    public let includeInOpenClawGroup: Bool
    /// How the Swift runtime supports the tool.
    public let availability: CoreToolAvailability

    /// Creates a definition.
    public init(
        id: String,
        description: String,
        sectionID: String,
        profiles: [ToolProfileID],
        includeInOpenClawGroup: Bool,
        availability: CoreToolAvailability
    ) {
        self.id = id
        self.description = description
        self.sectionID = sectionID
        self.profiles = profiles
        self.includeInOpenClawGroup = includeInOpenClawGroup
        self.availability = availability
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case description
        case sectionID = "sectionId"
        case profiles
        case includeInOpenClawGroup
        case availability
    }
}

/// Static port of upstream `src/agents/tool-catalog.ts` (OpenClaw 2026.9.6): core tool ids,
/// sections, profiles and groups.
///
/// The catalog is pure data used by ``ToolPolicy``, UI inventories and the `tools.catalog` RPC. The
/// ``CoreToolDefinition/availability`` column documents which ids the Swift embedded runtime can
/// implement natively; every other id is recognized only (it may still arrive as an MCP or client tool).
public enum CoreToolCatalog {
    /// Name of the scheduler tool (`cron` is a permanent alias).
    public static let automationsToolName = "automations"
    /// Allow-list token that admits every bundled MCP tool.
    public static let bundleMCPToken = "bundle-mcp"
    /// Group token covering plugin and MCP tools.
    public static let pluginsGroupToken = "group:plugins"
    /// MCP tool-name separator (`server__tool`).
    public static let mcpToolNameSeparator = "__"

    /// Sections in display order.
    public static let sections: [CoreToolSection] = [
        CoreToolSection(id: "fs", label: "Files"),
        CoreToolSection(id: "runtime", label: "Runtime"),
        CoreToolSection(id: "web", label: "Web"),
        CoreToolSection(id: "memory", label: "Memory"),
        CoreToolSection(id: "sessions", label: "Sessions"),
        CoreToolSection(id: "ui", label: "UI"),
        CoreToolSection(id: "messaging", label: "Messaging"),
        CoreToolSection(id: "automation", label: "Automation"),
        CoreToolSection(id: "nodes", label: "Nodes"),
        CoreToolSection(id: "agents", label: "Agents"),
        CoreToolSection(id: "media", label: "Media"),
    ]

    private static let coding: ToolProfileID = .coding
    private static let messaging: ToolProfileID = .messaging
    private static let minimal: ToolProfileID = .minimal

    // swiftlint:disable line_length
    /// Every core tool, in upstream order.
    public static let definitions: [CoreToolDefinition] = [
        Self.tool("ls", "List directory entries", "fs", [coding], group: false, .provided),
        Self.tool("read", "Read file contents", "fs", [coding], group: false, .provided),
        Self.tool("write", "Create or overwrite files", "fs", [coding], group: false, .provided),
        Self.tool("edit", "Make precise edits", "fs", [coding], group: false, .provided),
        Self.tool("apply_patch", "Patch files", "fs", [coding], group: false, .provided),
        Self.tool("exec", "Run shell now.", "runtime", [coding], group: false, .providedDesktopOnly),
        Self.tool("process", "Inspect/control exec sessions.", "runtime", [coding], group: false, .providedDesktopOnly),
        Self.tool("code_execution", "Run sandboxed remote analysis", "runtime", [coding], group: true, .recognizedOnly),
        Self.tool("secrets", "Request and manage write-only credentials", "runtime", [coding, messaging], group: true, .recognizedOnly),
        Self.tool("web_search", "Search the web", "web", [coding], group: true, .recognizedOnly),
        Self.tool("web_fetch", "Fetch web content", "web", [coding], group: true, .provided),
        Self.tool("x_search", "Search X posts", "web", [coding], group: true, .recognizedOnly),
        Self.tool("memory_search", "Semantic search", "memory", [coding], group: true, .provided),
        Self.tool("memory_get", "Read memory files", "memory", [coding], group: true, .provided),
        Self.tool("sessions", "Session settings: label, pin, archive, groups", "sessions", [coding, messaging], group: true, .provided),
        Self.tool("sessions_list", "List visible sessions; filters/previews.", "sessions", [coding, messaging], group: true, .provided),
        Self.tool("sessions_history", "Read sanitized session history.", "sessions", [coding, messaging], group: true, .provided),
        Self.tool("sessions_search", "Search past session transcripts.", "sessions", [coding, messaging], group: true, .provided),
        Self.tool("conversations_list", "List exact external conversation addresses", "sessions", [coding, messaging], group: true, .recognizedOnly),
        Self.tool("conversations_send", "Send to an exact external conversation", "sessions", [coding, messaging], group: true, .recognizedOnly),
        Self.tool("conversations_turn", "Send and wait for a correlated external reply", "sessions", [coding, messaging], group: true, .recognizedOnly),
        Self.tool("sessions_send", "Run same-Gateway session/agent.", "sessions", [coding, messaging], group: true, .provided),
        Self.tool("sessions_spawn", "Spawn hidden subagent (ephemeral) or visible work session (durable).", "sessions", [coding, messaging], group: true, .provided),
        Self.tool("github_identity_status", "Inspect the effective GitHub identity and credential health", "sessions", [coding], group: true, .recognizedOnly),
        Self.tool("github_publish", "Publish the reconciled session worktree as a draft GitHub pull request", "sessions", [coding], group: true, .recognizedOnly),
        Self.tool("agents_wait", "Wait for collector subagents.", "sessions", [coding], group: true, .recognizedOnly),
        Self.tool("sessions_yield", "End turn to receive sub-agent results", "sessions", [coding, messaging], group: true, .provided),
        Self.tool("subagents", "Background work: subagents, media gen, automation runs. list/cancel.", "sessions", [coding, messaging], group: true, .provided),
        Self.tool("session_status", "Show session status/model/usage.", "sessions", [minimal, coding, messaging], group: true, .provided),
        Self.tool("suggest_task", "Suggest follow-up work for operator approval.", "sessions", [coding], group: true, .recognizedOnly),
        Self.tool("dismiss_task", "Withdraw a pending task suggestion.", "sessions", [coding], group: true, .recognizedOnly),
        Self.tool("browser", "Control web browser", "ui", [], group: true, .recognizedOnly),
        Self.tool("screen", "Drive operator web UI", "ui", [coding], group: true, .recognizedOnly),
        Self.tool("theme", "List, select, and create appearance themes", "ui", [coding, messaging], group: true, .recognizedOnly),
        Self.tool("dashboard", "Read and arrange the session dashboard", "ui", [coding], group: true, .recognizedOnly),
        Self.tool("terminal", "Use shared operator terminals with policy-governed input", "ui", [coding], group: true, .recognizedOnly),
        Self.tool("portal", "Expose local web apps through the gateway", "ui", [coding], group: true, .recognizedOnly),
        Self.tool("canvas", "Control node Canvas surfaces when the Canvas plugin is enabled", "ui", [], group: false, .recognizedOnly),
        Self.tool("show_widget", "Show an interactive widget on chat or an auto-fitting dashboard", "ui", [], group: true, .recognizedOnly),
        Self.tool("message", "Send messages", "messaging", [messaging], group: true, .recognizedOnly),
        Self.tool("heartbeat_respond", "Accept heartbeat outcomes for post-turn handling", "automation", [], group: true, .recognizedOnly),
        Self.tool("automations", "Schedule reminders, automations, wake events.", "automation", [coding], group: true, .provided),
        Self.tool("gateway", "Update OpenClaw; read Gateway config/schema when permitted", "automation", [minimal, coding, messaging], group: true, .recognizedOnly),
        Self.tool("plugins", "Manage and reload plugins", "automation", [coding], group: true, .recognizedOnly),
        Self.tool("openclaw", "Delegate OpenClaw setup and repair", "automation", [], group: true, .recognizedOnly),
        Self.tool("nodes", "Nodes + devices", "nodes", [], group: true, .recognizedOnly),
        Self.tool("computer", "Control the Gateway desktop or a paired computer", "nodes", [], group: true, .recognizedOnly),
        Self.tool("mobile_ui", "Observe and control a paired Android app", "nodes", [], group: true, .recognizedOnly),
        Self.tool("agents_list", "List agents", "agents", [], group: true, .provided),
        Self.tool("get_goal", "Get current thread goal", "agents", [coding], group: true, .provided),
        Self.tool("create_goal", "Create a thread goal", "agents", [coding], group: true, .provided),
        Self.tool("update_goal", "Complete or block a thread goal", "agents", [coding], group: true, .provided),
        Self.tool("progress_card", "Maintain the session progress card", "agents", [coding], group: true, .recognizedOnly),
        Self.tool("ask_user", "Ask the user and wait for an answer.", "agents", [coding, messaging], group: true, .provided),
        Self.tool("skill_workshop", "Author reusable skills under the available tool's publication and review policy. Read one complete artifact when it fits the model budget.", "agents", [coding], group: true, .recognizedOnly),
        Self.tool("view_image", "Image understanding", "media", [coding], group: true, .provided),
        Self.tool("image_generate", "Image generation", "media", [coding], group: true, .recognizedOnly),
        Self.tool("music_generate", "Music generation", "media", [coding], group: true, .recognizedOnly),
        Self.tool("video_generate", "Video generation", "media", [coding], group: true, .recognizedOnly),
        Self.tool("tts", "Text-to-speech conversion", "media", [], group: true, .recognizedOnly),
        Self.tool("pdf", "PDF reading and extraction", "media", [], group: true, .recognizedOnly),
    ]
    // swiftlint:enable line_length

    /// Legacy ids rewritten when reading persisted allow/deny lists (upstream doctor migrations).
    ///
    /// `image` became `view_image`; `update_plan` has no replacement and is treated as unknown.
    public static let legacyPolicyAliases: [String: String] = ["image": "view_image"]

    private static let byID: [String: CoreToolDefinition] = Dictionary(
        uniqueKeysWithValues: Self.definitions.map { ($0.id, $0) }
    )

    /// Core tool groups keyed by group id: `group:openclaw` plus `group:<section>` for every section.
    public static let groups: [String: [String]] = {
        var groups: [String: [String]] = ["group:openclaw": Self.definitions.filter(\.includeInOpenClawGroup).map(\.id)]
        for definition in Self.definitions {
            groups["group:\(definition.sectionID)", default: []].append(definition.id)
        }
        return groups
    }()

    /// Built-in profile ids in display order.
    public static let profiles: [ToolProfileID] = [.minimal, .coding, .messaging, .full]

    /// Definition for a core tool id.
    /// - Parameter id: Tool id (aliases resolve).
    /// - Returns: The definition, if the id is a core tool.
    public static func definition(for id: String) -> CoreToolDefinition? {
        Self.byID[AgentToolRegistry.canonicalName(id)]
    }

    /// Whether an id names a core tool.
    /// - Parameter id: Tool id.
    /// - Returns: `true` for known core ids.
    public static func isKnownCoreTool(_ id: String) -> Bool {
        Self.definition(for: id) != nil
    }

    /// Allow list of a built-in profile (upstream `resolveCoreToolProfilePolicy`).
    ///
    /// `minimal` lists its tools; `coding` and `messaging` add `bundle-mcp`; `full` is `*`. Unknown
    /// profiles return `nil`.
    /// - Parameter profile: Profile id.
    /// - Returns: The profile allow list.
    public static func profileAllowList(_ profile: ToolProfileID) -> [String]? {
        switch profile.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "minimal":
            return Self.tools(in: .minimal)
        case "coding":
            return Self.tools(in: .coding) + [Self.bundleMCPToken]
        case "messaging":
            return Self.tools(in: .messaging) + [Self.bundleMCPToken]
        case "full":
            return ["*"]
        default:
            return nil
        }
    }

    /// Core tool ids included by a profile.
    /// - Parameter profile: Profile id.
    /// - Returns: Tool ids in catalog order.
    public static func tools(in profile: ToolProfileID) -> [String] {
        Self.definitions.filter { $0.profiles.contains(profile) }.map(\.id)
    }

    /// Profiles that include a core tool (upstream `resolveCoreToolProfiles`).
    /// - Parameter id: Tool id.
    /// - Returns: Profiles, empty for unknown ids.
    public static func profiles(for id: String) -> [ToolProfileID] {
        Self.definition(for: id)?.profiles ?? []
    }

    /// Sections with their visible tools (upstream `listCoreToolSections`).
    ///
    /// `agents_wait` appears only with swarm enabled; `github_identity_status` only when GitHub
    /// publication availability is known; `github_publish` only when it is available.
    /// - Parameters:
    ///   - swarmEnabled: Whether swarm collectors are enabled.
    ///   - githubPublicationAvailable: GitHub publication availability (`nil` = unknown).
    /// - Returns: Non-empty sections with their tools.
    public static func visibleSections(
        swarmEnabled: Bool = false,
        githubPublicationAvailable: Bool? = nil
    ) -> [(section: CoreToolSection, tools: [CoreToolDefinition])] {
        Self.sections.compactMap { section in
            let tools = Self.definitions.filter { tool in
                guard tool.sectionID == section.id else { return false }
                if tool.id == "agents_wait", !swarmEnabled { return false }
                if tool.id == "github_identity_status", githubPublicationAvailable == nil { return false }
                if tool.id == "github_publish", githubPublicationAvailable != true { return false }
                return true
            }
            return tools.isEmpty ? nil : (section, tools)
        }
    }

    /// Expands group tokens in a policy list and normalizes entries (upstream `expandToolGroups`).
    /// - Parameter list: Raw allow/deny entries.
    /// - Returns: Normalized, de-duplicated entries with groups expanded.
    public static func expandGroups(_ list: [String]) -> [String] {
        var expanded: [String] = []
        var seen: Set<String> = []
        for raw in list {
            let normalized = Self.normalizePolicyEntry(raw)
            guard !normalized.isEmpty else { continue }
            let values = Self.groups[normalized] ?? [normalized]
            for value in values where seen.insert(value).inserted {
                expanded.append(value)
            }
        }
        return expanded
    }

    /// Normalizes one allow/deny entry: trim, lowercase, tool aliases, and legacy policy aliases.
    /// - Parameter entry: Raw entry.
    /// - Returns: Normalized entry.
    public static func normalizePolicyEntry(_ entry: String) -> String {
        let canonical = AgentToolRegistry.canonicalName(entry)
        return Self.legacyPolicyAliases[canonical] ?? canonical
    }

    private static func tool(
        _ id: String,
        _ description: String,
        _ section: String,
        _ profiles: [ToolProfileID],
        group: Bool,
        _ availability: CoreToolAvailability
    ) -> CoreToolDefinition {
        CoreToolDefinition(
            id: id,
            description: description,
            sectionID: section,
            profiles: profiles,
            includeInOpenClawGroup: group,
            availability: availability
        )
    }
}
