import Foundation
import Testing
import OpenClawCore
import OpenClawGateway
import OpenClawProtocol
@testable import OpenClawSkills

@Suite("Skill sources, eligibility, prompt v6 and status RPCs")
struct SkillRegistryEligibilityTests {
    private func skill(_ name: String, description: String = "Does things.", manifest: String? = nil, extra: String = "") -> String {
        var lines = ["---", "name: \(name)", "description: \(description)"]
        if let manifest {
            lines.append("metadata: \(manifest)")
        }
        if !extra.isEmpty {
            lines.append(extra)
        }
        lines.append("---")
        lines.append("# \(name.capitalized)")
        lines.append("Instructions for \(name).")
        return lines.joined(separator: "\n")
    }

    @Test
    func precedenceFollowsUpstreamOrderAndRecordsCollisions() async throws {
        let root = try RuntimeExtTestSupport.temporaryDirectory("skills-precedence")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("ws")
        let extra = root.appendingPathComponent("extra")
        let bundled = root.appendingPathComponent("bundled")
        let managed = root.appendingPathComponent("managed")
        try RuntimeExtTestSupport.writeSkill(root: extra, directory: "shared", contents: self.skill("shared", description: "extra"))
        try RuntimeExtTestSupport.writeSkill(root: bundled, directory: "shared", contents: self.skill("shared", description: "bundled"))
        try RuntimeExtTestSupport.writeSkill(root: managed, directory: "shared", contents: self.skill("shared", description: "managed"))
        try RuntimeExtTestSupport.writeSkill(
            root: workspace.appendingPathComponent(".agents/skills"),
            directory: "shared",
            contents: self.skill("shared", description: "project")
        )
        try RuntimeExtTestSupport.writeSkill(root: bundled, directory: "only-bundled", contents: self.skill("only-bundled"))

        let registry = SkillRegistry(
            workspaceRoot: workspace,
            extraSkillDirs: [extra],
            managedSkillsRoot: managed,
            bundledSkillsRoot: bundled,
            includePersonalAgentsRoot: false
        )
        await registry.addPluginSkillRoot(root.appendingPathComponent("plugin"))
        let sources = await registry.orderedRoots().map(\.source)
        #expect(sources == [.extra, .plugin, .bundled, .managed, .projectAgents, .workspace])

        let skills = try await registry.loadSkills()
        let shared = try #require(skills.first { $0.name == "shared" })
        #expect(shared.description == "project")
        #expect(shared.source == .projectAgents)
        #expect(await registry.collisions().count == 3)

        try RuntimeExtTestSupport.writeSkill(
            root: workspace.appendingPathComponent("skills"),
            directory: "shared",
            contents: self.skill("shared", description: "workspace")
        )
        let reloaded = try await registry.loadSkills()
        #expect(reloaded.first { $0.name == "shared" }?.source == .workspace)
        #expect(SkillSource.projectAgents.upstreamID == "agents-skills-project")
        #expect(SkillSource.plugin.upstreamID == "openclaw-extra")
    }

    @Test
    func eligibilityMatrixAcrossPlatforms() throws {
        let darwinOnly = try #require(SkillRegistry.parseSkill(
            contents: self.skill("mac", manifest: #"{"openclaw": {"os": ["darwin"], "requires": {"bins": ["remindctl"]}}}"#),
            filePath: "/s/mac/SKILL.md",
            source: .workspace
        ))
        let onMac = SkillEligibilityEvaluator.evaluate(
            darwinOnly,
            context: SkillEligibilityContext(platform: "darwin", environment: [:], hasBinary: { $0 == "remindctl" })
        )
        #expect(onMac.eligible)
        #expect(!onMac.platformIncompatible)
        let onIOS = SkillEligibilityEvaluator.evaluate(
            darwinOnly,
            context: SkillEligibilityContext(platform: "ios", environment: [:], hasBinary: { _ in false })
        )
        #expect(onIOS.platformIncompatible)
        #expect(!onIOS.eligible)
        #expect(onIOS.missing.bins == ["remindctl"])
        let macMissingBin = SkillEligibilityEvaluator.evaluate(
            darwinOnly,
            context: SkillEligibilityContext(platform: "macos", environment: [:], hasBinary: { _ in false })
        )
        #expect(!macMissingBin.platformIncompatible)
        #expect(macMissingBin.missing.bins == ["remindctl"])

        let needsEnv = try #require(SkillRegistry.parseSkill(
            contents: self.skill(
                "envy",
                manifest: #"{"openclaw": {"primaryEnv": "API_KEY", "requires": {"env": ["API_KEY", "REGION"], "anyBins": ["a", "b"], "#
                    + #""config": ["browser.enabled", "tools.web.enabled"]}}}"#
            ),
            filePath: "/s/envy/SKILL.md",
            source: .workspace
        ))
        var skills = SkillsConfiguration()
        skills.entries["envy"] = SkillsConfiguration.Entry(env: ["REGION": "eu"], apiKey: AnyCodable("secret"))
        let config = AnyCodable(["tools": AnyCodable(["web": AnyCodable(["enabled": AnyCodable(true)])])])
        let satisfied = SkillEligibilityEvaluator.evaluate(
            needsEnv,
            context: SkillEligibilityContext(platform: "linux", environment: [:], config: config, skills: skills, hasBinary: { $0 == "b" })
        )
        #expect(satisfied.missing.isEmpty, "\(satisfied.missing)")
        #expect(satisfied.configChecks.map(\.satisfied) == [true, true])
        let unsatisfied = SkillEligibilityEvaluator.evaluate(
            needsEnv,
            context: SkillEligibilityContext(platform: "linux", environment: [:], hasBinary: { _ in false })
        )
        #expect(unsatisfied.missing.env == ["API_KEY", "REGION"])
        #expect(unsatisfied.missing.anyBins == ["a", "b"])
        #expect(unsatisfied.missing.config == ["tools.web.enabled"])

        let always = try #require(SkillRegistry.parseSkill(
            contents: self.skill("always", manifest: #"{"openclaw": {"always": true, "os": ["linux"], "requires": {"bins": ["nope"]}}}"#),
            filePath: "/s/always/SKILL.md",
            source: .bundled
        ))
        #expect(SkillEligibilityEvaluator.evaluate(always, context: SkillEligibilityContext(platform: "linux", hasBinary: { _ in false })).eligible)
        #expect(!SkillEligibilityEvaluator.evaluate(always, context: SkillEligibilityContext(platform: "darwin", hasBinary: { _ in false })).eligible)

        var gated = SkillsConfiguration(allowBundled: ["other"])
        gated.entries["envy"] = SkillsConfiguration.Entry(enabled: false)
        #expect(SkillEligibilityEvaluator.evaluate(always, context: SkillEligibilityContext(platform: "linux", skills: gated)).blockedByAllowlist)
        #expect(SkillEligibilityEvaluator.evaluate(needsEnv, context: SkillEligibilityContext(platform: "linux", skills: gated)).disabled)
        let filtered = SkillEligibilityEvaluator.evaluate(always, context: SkillEligibilityContext(platform: "linux", agentSkillFilter: ["envy"]))
        #expect(filtered.blockedByAgentFilter)
        #expect(filtered.eligible)
        #expect(!filtered.availableToAgent)
    }

    @Test
    func catalogPromptGoldenAndEscaping() throws {
        let alpha = try #require(SkillRegistry.parseSkill(
            contents: self.skill("alpha", description: "Uses <tags> & \"quotes\" 'here'"),
            filePath: "/skills/alpha/SKILL.md",
            source: .workspace
        ))
        let beta = try #require(SkillRegistry.parseSkill(contents: self.skill("Beta"), filePath: "/skills/beta/SKILL.md", source: .workspace))
        let rendered = SkillPromptFormatter.catalog(skills: [beta, alpha])
        let expected = """


        The following skills provide specialized instructions for specific tasks.
        Read a skill's file at its listed location when the task matches its description.
        When a skill file references a relative path, resolve it against the skill directory (parent of SKILL.md / dirname of the path) \
        and use that absolute path in tool commands.

        <available_skills>
          <skill>
            <name>alpha</name>
            <description>Uses &lt;tags&gt; &amp; &quot;quotes&quot; &apos;here&apos;</description>
            <location>/skills/alpha/SKILL.md</location>
          </skill>
          <skill>
            <name>Beta</name>
            <description>Does things.</description>
            <location>/skills/beta/SKILL.md</location>
          </skill>
        </available_skills>
        """
        #expect(rendered.prompt == expected)
        #expect(rendered.skills.map(\.name) == ["alpha", "Beta"])
    }

    @Test
    func catalogFallsBackToCompactFormAndTruncates() throws {
        let long = String(repeating: "word ", count: 120)
        let skills = try (0..<40).map { index in
            try #require(SkillRegistry.parseSkill(
                contents: self.skill("skill-\(index)", description: long),
                filePath: "/s/\(index)/SKILL.md",
                source: .workspace
            ))
        }
        let compact = SkillPromptFormatter.catalog(skills: skills, maxSkillsPromptChars: 12_000)
        #expect(compact.prompt.utf16.count <= 12_000)
        #expect(compact.prompt.contains("⚠️ Skills catalog using compact format (descriptions shortened)."))
        #expect(compact.prompt.contains("..."))
        #expect(compact.skills.count == 40)

        let truncated = SkillPromptFormatter.catalog(skills: skills, maxSkillsInPrompt: 10)
        #expect(truncated.skills.count == 10)
        #expect(truncated.prompt.hasPrefix("⚠️ Skills truncated: included 10 of 40"))

        let budgeted = SkillPromptFormatter.compactForContext(SkillPromptFormatter.catalog(skills: Array(skills.prefix(5))).prompt, contextTokenBudget: 15_000)
        #expect(budgeted.utf16.count <= 3_000 + 1_500)
        #expect(budgeted.contains("<name>skill-0</name>"))
    }

    @Test
    func promptSnapshotModesAndStatusReport() async throws {
        let root = try RuntimeExtTestSupport.temporaryDirectory("skills-status")
        defer { try? FileManager.default.removeItem(at: root) }
        let skillsDir = root.appendingPathComponent("skills")
        try RuntimeExtTestSupport.writeSkill(root: skillsDir, directory: "mac-only", contents: self.skill(
            "mac-only",
            manifest: #"{"openclaw": {"os": ["darwin"], "emoji": "🍎", "install": [{"kind": "brew", "formula": "tool", "bins": ["tool"]}]}}"#
        ))
        try RuntimeExtTestSupport.writeSkill(root: skillsDir, directory: "hidden", contents: self.skill("hidden", extra: "disable-model-invocation: true"))
        try RuntimeExtTestSupport.writeSkill(
            root: skillsDir,
            directory: "portable",
            contents: self.skill("portable", manifest: #"{"openclaw": {"requires": {"anyBins": ["zz1"]}}}"#)
        )
        let registry = SkillRegistry(workspaceRoot: root, managedSkillsRoot: root.appendingPathComponent("managed"), includePersonalAgentsRoot: false)

        let macContext = SkillEligibilityContext(platform: "darwin", environment: [:], hasBinary: { $0 == "zz1" || $0 == "brew" })
        let catalog = try await registry.loadPromptSnapshot(options: SkillPromptOptions(mode: .catalog, context: macContext))
        #expect(catalog.promptFormatVersion == 6)
        #expect(catalog.prompt.contains("<name>mac-only</name>"))
        #expect(catalog.prompt.contains("<name>portable</name>"))
        #expect(!catalog.prompt.contains("hidden"))
        #expect(catalog.entries.map(\.name) == ["mac-only", "portable"])

        let iosContext = SkillEligibilityContext(platform: "ios", environment: [:], hasBinary: { _ in false })
        let inline = try await registry.loadPromptSnapshot(options: SkillPromptOptions(mode: .inlineBodies, context: iosContext))
        #expect(inline.prompt.isEmpty)
        #expect(SkillPromptMode.resolve(supportsToolCalling: false, hasReadTool: true) == .inlineBodies)
        #expect(SkillPromptMode.resolve(supportsToolCalling: true, hasReadTool: true) == .catalog)

        let macReport = try await registry.statusReport(agentID: "main", context: macContext)
        let macEntry = try #require(macReport.skills.first { $0.name == "mac-only" })
        #expect(macEntry.eligible && macEntry.modelVisible && macEntry.commandVisible)
        #expect(macEntry.source == "openclaw-workspace")
        #expect(macEntry.emoji == "🍎")
        #expect(macEntry.install.map(\.label) == ["Install tool (brew)"])
        #expect(macReport.skills.first { $0.name == "hidden" }?.modelVisible == false)

        let iosReport = try await registry.statusReport(context: iosContext)
        let iosEntry = try #require(iosReport.skills.first { $0.name == "mac-only" })
        #expect(iosEntry.platformIncompatible)
        #expect(!iosEntry.eligible)
        #expect(iosEntry.install.isEmpty)
        #expect(iosReport.skills.first { $0.name == "portable" }?.missing.anyBins == ["zz1"])

        let data = try JSONEncoder().encode(macReport)
        let decoded = try JSONDecoder().decode(SkillStatusReport.self, from: data)
        #expect(decoded == macReport)
        #expect(try await registry.requiredBins() == ["zz1"])
    }

    @Test
    func commandNamesSanitizeAndDedupe() throws {
        #expect(SkillCommandNaming.sanitize("Deploy Now!") == "deploy_now")
        #expect(SkillCommandNaming.sanitize("__weird--Name__") == "weird_name")
        #expect(SkillCommandNaming.sanitize("!!!") == "skill")
        #expect(SkillCommandNaming.sanitize(String(repeating: "a", count: 40)).count == 32)
        let skills = try ["gh-issues", "GH Issues", "gh_issues", "reset"].enumerated().map { index, name in
            try #require(SkillRegistry.parseSkill(contents: self.skill(name), filePath: "/s/\(index)/SKILL.md", source: .workspace))
        }
        let specs = SkillCommandNaming.commandSpecs(for: skills, reservedNames: ["reset"])
        #expect(specs.map(\.name) == ["gh_issues", "gh_issues_2", "gh_issues_3", "reset_2"])
        #expect(SkillCommandNaming.unique(
            String(repeating: "b", count: 32),
            used: [String(repeating: "b", count: 32)]
        ) == String(repeating: "b", count: 30) + "_2")
    }

    @Test
    func gatewayHandlersServeStatusBinsAndCommands() async throws {
        let root = try RuntimeExtTestSupport.temporaryDirectory("skills-gateway")
        defer { try? FileManager.default.removeItem(at: root) }
        try RuntimeExtTestSupport.writeSkill(root: root.appendingPathComponent("skills"), directory: "weather", contents: self.skill(
            "weather",
            manifest: #"{"openclaw": {"requires": {"bins": ["curl"], "anyBins": ["jq", "yq"]}}}"#
        ))
        let registry = SkillRegistry(workspaceRoot: root, managedSkillsRoot: root.appendingPathComponent("managed"), includePersonalAgentsRoot: false)
        let server = RuntimeExtTestSupport.makeGatewayServer(root: root)
        await registerSkillsGatewayMethods(
            on: server,
            configuration: SkillsGatewayConfiguration(
                registry: registry,
                contextProvider: { _ in SkillEligibilityContext(platform: "linux", environment: [:], hasBinary: { _ in true }) },
                knownAgentIDs: ["main"]
            )
        )

        let status = await RuntimeExtTestSupport.call(server, "skills.status", params: ["agentId": AnyCodable("main")])
        #expect(status.ok)
        let report = try RuntimeExtTestSupport.decode(SkillStatusReport.self, from: status.payload)
        #expect(report.agentId == "main")
        #expect(report.skills.map(\.name) == ["weather"])

        let unknown = await RuntimeExtTestSupport.call(server, "skills.status", params: ["agentId": AnyCodable("ghost")])
        #expect(unknown.ok == false)
        #expect(unknown.error?.code == ErrorCode.invalidRequest.rawValue)

        let operatorBins = await RuntimeExtTestSupport.call(server, "skills.bins", params: [:])
        #expect(operatorBins.ok == false)
        let bins = await RuntimeExtTestSupport.call(server, "skills.bins", params: [:], connection: RuntimeExtTestSupport.nodeConnection)
        #expect(bins.ok)
        #expect(try RuntimeExtTestSupport.decode(SkillsBinsResult.self, from: bins.payload).bins == ["curl", "jq", "yq"])

        let commands = await RuntimeExtTestSupport.call(server, "commands.list", params: [:])
        #expect(commands.ok)
        let result = try RuntimeExtTestSupport.decode(CommandsListResult.self, from: commands.payload)
        #expect(result.commands.map(\.name) == ["reset", "compact", "think", "verbose", "weather"])
        let weather = try #require(result.commands.last)
        #expect(weather.source.stringValue == "skill")
        #expect(weather.skilldisplayname == "Weather")
        #expect(weather.skillmodelvisible == true)
        #expect(weather.textaliases == ["/weather"])
    }

    @Test
    func invocationEngineDispatchesToolCommandsBySanitizedName() async throws {
        let root = try RuntimeExtTestSupport.temporaryDirectory("skills-dispatch")
        defer { try? FileManager.default.removeItem(at: root) }
        try RuntimeExtTestSupport.writeSkill(root: root.appendingPathComponent("skills"), directory: "deploy", contents: self.skill(
            "Deploy Now",
            extra: "command-dispatch: tool\ncommand-tool: exec"
        ))
        let engine = SkillInvocationEngine(
            workspaceRoot: root,
            commandToolDispatcher: { tool, arguments in
                "\(tool):\(arguments["command"]?.stringValue ?? "")"
            }
        )
        let result = try await engine.invokeIfRequested(message: "/deploy_now  --prod   now")
        #expect(result?.output == "exec:--prod   now")
        #expect(result?.executorID == "tool:exec")
    }
}
