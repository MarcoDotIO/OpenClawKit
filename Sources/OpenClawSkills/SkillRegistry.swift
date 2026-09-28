import Foundation
import OpenClawCore
import OpenClawProtocol

/// One skill root with its source bucket.
public struct SkillRoot: Sendable, Equatable {
    /// Source bucket.
    public let source: SkillSource
    /// Root directory.
    public let url: URL

    /// Creates a skill root.
    /// - Parameters:
    ///   - source: Source bucket.
    ///   - url: Root directory.
    public init(source: SkillSource, url: URL) {
        self.source = source
        self.url = url
    }
}

/// Two sources defined the same skill name with different content; the later source won.
public struct SkillCollision: Sendable, Equatable {
    /// Skill name.
    public let name: String
    /// Winning definition's path and source.
    public let winnerPath: String
    /// Winning source.
    public let winnerSource: SkillSource
    /// Shadowed definition's path.
    public let shadowedPath: String
    /// Shadowed source.
    public let shadowedSource: SkillSource

    /// Creates a collision record.
    /// - Parameters:
    ///   - name: Skill name.
    ///   - winnerPath: Winning path.
    ///   - winnerSource: Winning source.
    ///   - shadowedPath: Shadowed path.
    ///   - shadowedSource: Shadowed source.
    public init(name: String, winnerPath: String, winnerSource: SkillSource, shadowedPath: String, shadowedSource: SkillSource) {
        self.name = name
        self.winnerPath = winnerPath
        self.winnerSource = winnerSource
        self.shadowedPath = shadowedPath
        self.shadowedSource = shadowedSource
    }
}

/// Options for ``SkillRegistry/loadPromptSnapshot(options:)``.
public struct SkillPromptOptions: Sendable {
    /// Render mode (defaults to the v6 catalog).
    public var mode: SkillPromptMode
    /// Eligibility context (platform, environment, config, agent filter).
    public var context: SkillEligibilityContext
    /// Model context budget in tokens; the catalog is capped at `budget / 5` characters.
    public var contextTokenBudget: Int?

    /// Creates prompt options.
    /// - Parameters:
    ///   - mode: Render mode.
    ///   - context: Eligibility context.
    ///   - contextTokenBudget: Context budget.
    public init(mode: SkillPromptMode = .catalog, context: SkillEligibilityContext = SkillEligibilityContext(), contextTokenBudget: Int? = nil) {
        self.mode = mode
        self.context = context
        self.contextTokenBudget = contextTokenBudget
    }
}

/// Actor that discovers, parses, and merges skill definitions from every source.
///
/// Roots load in precedence order (see ``SkillSource``); a later source replaces an earlier skill of
/// the same name. Differing duplicates are recorded as ``SkillCollision``s and reported to the
/// diagnostics sink as `skills.collision`.
public actor SkillRegistry {
    private let workspaceRoot: URL
    private let extraSkillDirs: [URL]
    private let managedSkillsRoot: URL
    private let bundledSkillsRoot: URL?
    private let custodianSkillsRoot: URL?
    private let workshopSkillsRoot: URL?
    private let includePersonalAgentsRoot: Bool
    private let diagnostics: RuntimeDiagnosticSink?
    private var configuration: SkillsConfiguration
    private var pluginSkillRoots: [URL] = []
    private var lastCollisions: [SkillCollision] = []
    private var changeHandlers: [@Sendable ([SkillDefinition]) async -> Void] = []

    /// Creates a skill registry.
    /// - Parameters:
    ///   - workspaceRoot: Workspace root URL.
    ///   - extraSkillDirs: Extra search directories (lowest precedence, before `configuration.load.extraDirs`).
    ///   - managedSkillsRoot: Managed skill root override (defaults to ``defaultManagedSkillsRoot()``).
    ///   - bundledSkillsRoot: Skills bundled with the host app.
    ///   - custodianSkillsRoot: Custodian skills (only pass for the configured system agent).
    ///   - workshopSkillsRoot: Per-agent workshop skills.
    ///   - includePersonalAgentsRoot: Whether to read `~/.agents/skills` (default: macOS/Linux only).
    ///   - configuration: Skill settings (extra dirs, allowlist, per-skill entries, limits).
    ///   - diagnostics: Optional diagnostics sink.
    public init(
        workspaceRoot: URL,
        extraSkillDirs: [URL] = [],
        managedSkillsRoot: URL? = nil,
        bundledSkillsRoot: URL? = nil,
        custodianSkillsRoot: URL? = nil,
        workshopSkillsRoot: URL? = nil,
        includePersonalAgentsRoot: Bool = SkillPlatform.canSpawnProcesses,
        configuration: SkillsConfiguration = SkillsConfiguration(),
        diagnostics: RuntimeDiagnosticSink? = nil
    ) {
        self.workspaceRoot = workspaceRoot
        self.extraSkillDirs = extraSkillDirs
        self.managedSkillsRoot = managedSkillsRoot ?? Self.defaultManagedSkillsRoot()
        self.bundledSkillsRoot = bundledSkillsRoot
        self.custodianSkillsRoot = custodianSkillsRoot
        self.workshopSkillsRoot = workshopSkillsRoot
        self.includePersonalAgentsRoot = includePersonalAgentsRoot
        self.configuration = configuration
        self.diagnostics = diagnostics
    }

    /// Default managed skills root: `~/.openclaw/skills` on macOS/Linux, `Application Support/OpenClaw/skills`
    /// on iOS, tvOS, watchOS and visionOS.
    public static func defaultManagedSkillsRoot() -> URL {
        #if os(macOS) || os(Linux)
        return OpenClawFileSystem.resolveHomeDirectory()
            .appendingPathComponent(".openclaw")
            .appendingPathComponent("skills")
        #else
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("OpenClaw").appendingPathComponent("skills")
        #endif
    }

    /// Managed skills root in use.
    public var managedSkillsDirectory: URL {
        self.managedSkillsRoot
    }

    /// Workspace root in use.
    public var workspaceDirectory: URL {
        self.workspaceRoot
    }

    // MARK: - Configuration

    /// Replaces the skill settings.
    /// - Parameter configuration: Skill settings.
    public func setConfiguration(_ configuration: SkillsConfiguration) {
        self.configuration = configuration
    }

    /// Current skill settings.
    public func currentConfiguration() -> SkillsConfiguration {
        self.configuration
    }

    /// Adds a plugin-registered skill root.
    /// - Parameter url: Root directory.
    public func addPluginSkillRoot(_ url: URL) {
        let standardized = url.standardizedFileURL
        if !self.pluginSkillRoots.contains(standardized) {
            self.pluginSkillRoots.append(standardized)
        }
    }

    /// Removes a plugin-registered skill root.
    /// - Parameter url: Root directory.
    public func removePluginSkillRoot(_ url: URL) {
        let standardized = url.standardizedFileURL
        self.pluginSkillRoots.removeAll { $0 == standardized }
    }

    /// Registers a handler invoked with the merged skills after ``reload()``.
    /// - Parameter handler: Change handler (for example, a gateway `skills.changed` emitter).
    public func onChange(_ handler: @escaping @Sendable ([SkillDefinition]) async -> Void) {
        self.changeHandlers.append(handler)
    }

    // MARK: - Loading

    /// Roots in precedence order (lowest first).
    public func orderedRoots() -> [SkillRoot] {
        var roots: [SkillRoot] = []
        roots.append(contentsOf: self.extraSkillDirs.map { SkillRoot(source: .extra, url: $0) })
        roots.append(contentsOf: self.configuration.load.extraDirs.compactMap { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return SkillRoot(source: .extra, url: Self.resolveUserPath(trimmed))
        })
        roots.append(contentsOf: self.pluginSkillRoots.map { SkillRoot(source: .plugin, url: $0) })
        if let bundledSkillsRoot {
            roots.append(SkillRoot(source: .bundled, url: bundledSkillsRoot))
        }
        if let custodianSkillsRoot {
            roots.append(SkillRoot(source: .custodian, url: custodianSkillsRoot))
        }
        if let workshopSkillsRoot {
            roots.append(SkillRoot(source: .workshop, url: workshopSkillsRoot))
        }
        roots.append(SkillRoot(source: .managed, url: self.managedSkillsRoot))
        if self.includePersonalAgentsRoot {
            let home = OpenClawFileSystem.resolveHomeDirectory()
            roots.append(SkillRoot(source: .personalAgents, url: home.appendingPathComponent(".agents").appendingPathComponent("skills")))
        }
        roots.append(SkillRoot(source: .projectAgents, url: self.workspaceRoot.appendingPathComponent(".agents").appendingPathComponent("skills")))
        roots.append(SkillRoot(source: .workspace, url: self.workspaceRoot.appendingPathComponent("skills")))
        return roots
    }

    /// Loads and merges skills according to source precedence rules.
    /// - Returns: Merged skill definitions sorted by name.
    public func loadSkills() throws -> [SkillDefinition] {
        var merged: [String: SkillDefinition] = [:]
        var collisions: [SkillCollision] = []
        let allowSymlinkTargets = self.configuration.load.allowSymlinkTargets.map(Self.resolveUserPath)

        for root in self.orderedRoots() {
            for skillFile in Self.discoverSkillFiles(in: root.url, allowSymlinkTargets: allowSymlinkTargets) {
                guard let definition = try Self.parseSkill(fileURL: skillFile, source: root.source) else {
                    continue
                }
                if let existing = merged[definition.name],
                   existing.filePath != definition.filePath,
                   existing.body != definition.body || existing.frontmatter != definition.frontmatter
                {
                    collisions.append(
                        SkillCollision(
                            name: definition.name,
                            winnerPath: definition.filePath,
                            winnerSource: definition.source,
                            shadowedPath: existing.filePath,
                            shadowedSource: existing.source
                        )
                    )
                }
                merged[definition.name] = definition
            }
        }
        self.lastCollisions = collisions
        return merged.values.sorted { $0.name < $1.name }
    }

    /// Reloads skills, reports collisions, and notifies ``onChange(_:)`` handlers.
    /// - Returns: Merged skill definitions.
    @discardableResult
    public func reload() async throws -> [SkillDefinition] {
        let skills = try self.loadSkills()
        if let diagnostics {
            for collision in self.lastCollisions {
                await diagnostics(
                    RuntimeDiagnosticEvent(
                        subsystem: "skills",
                        name: "skills.collision",
                        metadata: [
                            "name": collision.name,
                            "winner": collision.winnerPath,
                            "shadowed": collision.shadowedPath,
                        ]
                    )
                )
            }
        }
        for handler in self.changeHandlers {
            await handler(skills)
        }
        return skills
    }

    /// Collisions found by the last load.
    public func collisions() -> [SkillCollision] {
        self.lastCollisions
    }

    // MARK: - Eligibility and status

    /// Evaluates a skill's eligibility with the registry's settings.
    /// - Parameters:
    ///   - skill: Skill definition.
    ///   - context: Host context; its `skills` settings are replaced by the registry configuration.
    /// - Returns: Eligibility.
    public func eligibility(for skill: SkillDefinition, context: SkillEligibilityContext = SkillEligibilityContext()) -> SkillEligibility {
        var context = context
        context.skills = self.configuration
        return SkillEligibilityEvaluator.evaluate(skill, context: context)
    }

    /// Skills visible to the model (available to the agent and not `disable-model-invocation`).
    /// - Parameter context: Host context.
    /// - Returns: Prompt-visible skills sorted by name.
    public func promptVisibleSkills(context: SkillEligibilityContext = SkillEligibilityContext()) throws -> [SkillDefinition] {
        try self.loadSkills().filter { skill in
            !skill.invocation.disableModelInvocation && self.eligibility(for: skill, context: context).availableToAgent
        }
    }

    /// Builds the `skills.status` report.
    /// - Parameters:
    ///   - agentID: Agent the report is for.
    ///   - context: Host context (platform, environment, config, agent filter).
    /// - Returns: The report, listing every skill (disabled and ineligible included).
    public func statusReport(agentID: String? = nil, context: SkillEligibilityContext = SkillEligibilityContext()) throws -> SkillStatusReport {
        var context = context
        context.skills = self.configuration
        let entries = try self.loadSkills().map { skill -> SkillStatusEntry in
            let eligibility = SkillEligibilityEvaluator.evaluate(skill, context: context)
            let available = eligibility.availableToAgent
            return SkillStatusEntry(
                name: skill.name,
                description: skill.description,
                source: skill.source.upstreamID,
                bundled: skill.source.isBundled,
                filePath: skill.filePath,
                baseDir: skill.baseDir,
                skillKey: skill.skillKey,
                primaryEnv: skill.metadata.primaryEnv,
                emoji: skill.metadata.emoji,
                homepage: skill.metadata.homepage,
                always: eligibility.always,
                disabled: eligibility.disabled,
                blockedByAllowlist: eligibility.blockedByAllowlist,
                blockedByAgentFilter: eligibility.blockedByAgentFilter,
                eligible: eligibility.eligible,
                platformIncompatible: eligibility.platformIncompatible,
                modelVisible: available && !skill.invocation.disableModelInvocation,
                userInvocable: skill.invocation.userInvocable,
                commandVisible: available && skill.invocation.userInvocable,
                requirements: eligibility.requirements,
                missing: eligibility.missing,
                configChecks: eligibility.configChecks,
                install: SkillEligibilityEvaluator.installOptions(for: skill, context: context)
            )
        }
        return SkillStatusReport(
            workspaceDir: self.workspaceRoot.path,
            managedSkillsDir: self.managedSkillsRoot.path,
            agentId: agentID,
            agentSkillFilter: context.agentSkillFilter,
            skills: entries
        )
    }

    /// Sorted union of every skill's `requires.bins` and `requires.anyBins` (`skills.bins`).
    public func requiredBins() throws -> [String] {
        var bins = Set<String>()
        for skill in try self.loadSkills() {
            bins.formUnion(skill.metadata.requires?.bins ?? [])
            bins.formUnion(skill.metadata.requires?.anyBins ?? [])
        }
        return bins.sorted()
    }

    /// Slash commands for user-invocable skills available to the agent.
    /// - Parameters:
    ///   - reservedNames: Names taken by native commands.
    ///   - context: Host context.
    /// - Returns: Command specs.
    public func commandSpecs(reservedNames: [String] = [], context: SkillEligibilityContext = SkillEligibilityContext()) throws -> [SkillCommandSpec] {
        let skills = try self.loadSkills().filter { self.eligibility(for: $0, context: context).availableToAgent }
        return SkillCommandNaming.commandSpecs(for: skills, reservedNames: reservedNames)
    }

    // MARK: - Prompt

    /// Loads the legacy inline-body prompt snapshot (`## Skills`), filtered by eligibility.
    ///
    /// Kept for runtimes without a file-read tool or tool calling; see ``loadPromptSnapshot(options:)``
    /// for the v6 `<available_skills>` catalog.
    /// - Returns: Prompt snapshot.
    public func loadPromptSnapshot() throws -> SkillPromptSnapshot {
        try self.loadPromptSnapshot(options: SkillPromptOptions(mode: .inlineBodies))
    }

    /// Loads a prompt snapshot in the requested mode.
    /// - Parameter options: Mode, eligibility context and context budget.
    /// - Returns: Prompt snapshot.
    public func loadPromptSnapshot(options: SkillPromptOptions) throws -> SkillPromptSnapshot {
        let skills = try self.loadSkills()
        var context = options.context
        context.skills = self.configuration
        let visible = skills.filter { skill in
            !skill.invocation.disableModelInvocation && SkillEligibilityEvaluator.evaluate(skill, context: context).availableToAgent
        }
        let prompt: String
        let listed: [SkillDefinition]
        let version: Int
        switch options.mode {
        case .catalog:
            let rendered = SkillPromptFormatter.catalog(
                skills: visible,
                maxSkillsInPrompt: self.configuration.limits.maxSkillsInPrompt,
                maxSkillsPromptChars: self.configuration.limits.maxSkillsPromptChars
            )
            prompt = SkillPromptFormatter.compactForContext(rendered.prompt, contextTokenBudget: options.contextTokenBudget)
            listed = rendered.skills
            version = SkillPromptSnapshot.currentPromptFormatVersion
        case .inlineBodies:
            listed = visible
            prompt = SkillPromptFormatter.inlineBodies(skills: visible) { Self.entrypointValue(for: $0) }
            version = 0
        }
        let entries = listed.map { skill in
            let env = skill.metadata.requires?.env ?? []
            return SkillPromptSnapshotEntry(
                name: skill.name,
                skillKey: skill.skillKey,
                primaryEnv: skill.metadata.primaryEnv,
                requiredEnv: env.isEmpty ? nil : env
            )
        }
        return SkillPromptSnapshot(
            prompt: prompt,
            skills: skills,
            entries: entries,
            skillFilter: context.agentSkillFilter,
            promptFormatVersion: version,
            mode: options.mode
        )
    }

    /// Resolves an optional script entrypoint declared in skill frontmatter.
    /// - Parameter skill: Parsed skill definition.
    /// - Returns: Absolute entrypoint URL when configured.
    public func resolveEntrypoint(for skill: SkillDefinition) throws -> URL? {
        guard let rawEntrypoint = Self.entrypointValue(for: skill) else {
            return nil
        }
        let skillDirectory = URL(fileURLWithPath: skill.filePath)
            .deletingLastPathComponent()
            .standardizedFileURL
        let resolved = URL(fileURLWithPath: rawEntrypoint, relativeTo: skillDirectory)
            .standardizedFileURL
        let allowedPrefix = skillDirectory.path.hasSuffix("/")
            ? skillDirectory.path
            : skillDirectory.path + "/"
        guard resolved.path == skillDirectory.path || resolved.path.hasPrefix(allowedPrefix) else {
            throw OpenClawCoreError.invalidConfiguration("Skill entrypoint must stay within skill directory")
        }
        guard FileManager.default.fileExists(atPath: resolved.path) else {
            throw OpenClawCoreError.invalidConfiguration("Skill entrypoint does not exist: \(resolved.path)")
        }
        return resolved
    }

    // MARK: - Parsing

    /// Parses one SKILL.md file.
    /// - Parameters:
    ///   - fileURL: SKILL.md URL.
    ///   - source: Source bucket.
    /// - Returns: The definition, or `nil` when no name can be resolved.
    public static func parseSkill(fileURL: URL, source: SkillSource) throws -> SkillDefinition? {
        let raw = try String(contentsOf: fileURL, encoding: .utf8)
        return self.parseSkill(contents: raw, filePath: fileURL.path, source: source)
    }

    /// Parses SKILL.md contents.
    /// - Parameters:
    ///   - contents: File contents.
    ///   - filePath: SKILL.md path (the directory name is the fallback skill name).
    ///   - source: Source bucket.
    /// - Returns: The definition, or `nil` when no name can be resolved.
    public static func parseSkill(contents: String, filePath: String, source: SkillSource) -> SkillDefinition? {
        let parsed = SkillFrontmatterParser.parseDetailed(contents)
        let name = parsed.frontmatter["name"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fallbackName = URL(fileURLWithPath: filePath).deletingLastPathComponent().lastPathComponent
        let resolvedName = name.isEmpty ? fallbackName : name
        guard !resolvedName.isEmpty else {
            return nil
        }
        let description = parsed.frontmatter["description"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let body = parsed.body.trimmingCharacters(in: .whitespacesAndNewlines)
        return SkillDefinition(
            name: resolvedName,
            description: description,
            body: body,
            filePath: filePath,
            source: source,
            frontmatter: parsed.frontmatter,
            metadata: SkillFrontmatterParser.resolveMetadata(from: parsed.frontmatter),
            invocation: SkillFrontmatterParser.resolveInvocationPolicy(from: parsed.frontmatter),
            displayName: SkillFrontmatterParser.resolveDisplayName(body: body, fallback: resolvedName),
            commandDispatch: SkillFrontmatterParser.resolveCommandDispatch(from: parsed.frontmatter),
            frontmatterIssues: parsed.issues
        )
    }

    static func discoverSkillFiles(in root: URL, allowSymlinkTargets: [URL] = []) -> [URL] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: root.path) else {
            return []
        }

        var files: [URL] = []
        let direct = root.appendingPathComponent("SKILL.md")
        if fileManager.fileExists(atPath: direct.path) {
            files.append(direct)
        }

        guard let entries = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return files
        }

        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath().path
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true {
                // Symlinked skill folders must resolve inside the root or an allowed target.
                let target = entry.resolvingSymlinksInPath().standardizedFileURL.path
                let allowed = ([resolvedRoot] + allowSymlinkTargets.map { $0.standardizedFileURL.resolvingSymlinksInPath().path })
                    .contains { base in target == base || target.hasPrefix(base.hasSuffix("/") ? base : base + "/") }
                guard allowed else { continue }
            } else if values?.isDirectory != true {
                continue
            }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: entry.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                continue
            }
            let skillFile = entry.appendingPathComponent("SKILL.md")
            if fileManager.fileExists(atPath: skillFile.path) {
                files.append(skillFile)
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    static func entrypointValue(for skill: SkillDefinition) -> String? {
        let keys = ["entrypoint", "script", "run"]
        for key in keys {
            if let value = skill.frontmatter[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    static func resolveUserPath(_ raw: String) -> URL {
        if raw == "~" {
            return OpenClawFileSystem.resolveHomeDirectory()
        }
        if raw.hasPrefix("~/") {
            return OpenClawFileSystem.resolveHomeDirectory().appendingPathComponent(String(raw.dropFirst(2)))
        }
        return URL(fileURLWithPath: raw)
    }
}
