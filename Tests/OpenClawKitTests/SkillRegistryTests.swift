import Foundation
import Testing
@testable import OpenClawKit

@Suite("Skill registry")
struct SkillRegistryTests {
    struct PromptEchoProvider: ModelProvider {
        let id = "prompt-echo"

        func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
            ModelGenerationResponse(text: request.prompt, providerID: self.id, modelID: "prompt-echo")
        }
    }

    @Test
    func workspaceSkillsOverrideProjectSkillsAndPromptFiltersDisabledSkills() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let projectSkill = root
            .appendingPathComponent(".agents")
            .appendingPathComponent("skills")
            .appendingPathComponent("my-skill")
            .appendingPathComponent("SKILL.md")
        try FileManager.default.createDirectory(
            at: projectSkill.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        ---
        name: my-skill
        description: project skill
        ---

        Project instructions.
        """.write(to: projectSkill, atomically: true, encoding: .utf8)

        let workspaceSkill = root
            .appendingPathComponent("skills")
            .appendingPathComponent("my-skill")
            .appendingPathComponent("SKILL.md")
        try FileManager.default.createDirectory(
            at: workspaceSkill.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        ---
        name: my-skill
        description: workspace skill
        ---

        Workspace instructions.
        """.write(to: workspaceSkill, atomically: true, encoding: .utf8)

        let hiddenSkill = root
            .appendingPathComponent("skills")
            .appendingPathComponent("hidden")
            .appendingPathComponent("SKILL.md")
        try FileManager.default.createDirectory(
            at: hiddenSkill.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        ---
        name: hidden
        description: hidden skill
        disable-model-invocation: true
        ---

        Do not expose to prompt.
        """.write(to: hiddenSkill, atomically: true, encoding: .utf8)

        let registry = SkillRegistry(workspaceRoot: root)
        let skills = try await registry.loadSkills()
        let snapshot = try await registry.loadPromptSnapshot()

        let resolved = skills.first { $0.name == "my-skill" }
        #expect(resolved?.description == "workspace skill")
        #expect(snapshot.prompt.contains("Workspace instructions."))
        #expect(!snapshot.prompt.contains("Do not expose to prompt."))
    }

    @Test
    func runtimeInjectsSkillPromptIntoModelPrompt() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let workspaceSkill = root
            .appendingPathComponent("skills")
            .appendingPathComponent("weather")
            .appendingPathComponent("SKILL.md")
        try FileManager.default.createDirectory(
            at: workspaceSkill.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        ---
        name: weather
        description: Weather helper
        ---

        Always include WEATHER_MODE in your reasoning.
        """.write(to: workspaceSkill, atomically: true, encoding: .utf8)

        try """
        You are a calm assistant and should keep responses concise.
        """.write(
            to: root.appendingPathComponent("SOUL.md"),
            atomically: true,
            encoding: .utf8
        )

        let router = ModelRouter()
        await router.register(PromptEchoProvider())
        let runtime = EmbeddedAgentRuntime(modelRouter: router)

        let result = try await runtime.run(
            AgentRunRequest(
                sessionKey: "main",
                prompt: "Forecast for today?",
                modelProviderID: "prompt-echo",
                workspaceRootPath: root.path
            )
        )

        #expect(result.output.contains("## Skills"))
        #expect(result.output.contains("## Workspace Bootstrap Context"))
        #expect(result.output.contains("You are a calm assistant"))
        #expect(result.output.contains("Always include WEATHER_MODE in your reasoning."))
        #expect(result.output.contains("## User Request"))
        #expect(result.output.contains("Forecast for today?"))
    }

    @Test
    func resolvesSkillEntrypointWhenDefinedInFrontmatter() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let skillRoot = root.appendingPathComponent("skills").appendingPathComponent("weather")
        let skillFile = skillRoot.appendingPathComponent("SKILL.md")
        let scriptFile = skillRoot.appendingPathComponent("scripts").appendingPathComponent("weather.py")
        try FileManager.default.createDirectory(at: scriptFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        # weather helper
        """.write(to: scriptFile, atomically: true, encoding: .utf8)
        try """
        ---
        name: weather
        description: Weather utility
        entrypoint: scripts/weather.py
        ---

        Use this skill for forecasts.
        """.write(to: skillFile, atomically: true, encoding: .utf8)

        let registry = SkillRegistry(workspaceRoot: root)
        let skills = try await registry.loadSkills()
        let weather = try #require(skills.first(where: { $0.name == "weather" }))
        let entrypoint = try await registry.resolveEntrypoint(for: weather)

        #expect(entrypoint?.path == scriptFile.path)
    }

    @Test
    func rejectsEntrypointTraversalOutsideSkillDirectory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let skillRoot = root.appendingPathComponent("skills").appendingPathComponent("weather")
        let skillFile = skillRoot.appendingPathComponent("SKILL.md")
        try FileManager.default.createDirectory(at: skillRoot, withIntermediateDirectories: true)
        try """
        ---
        name: weather
        description: Weather utility
        entrypoint: ../outside.py
        ---

        Use this skill for forecasts.
        """.write(to: skillFile, atomically: true, encoding: .utf8)

        let registry = SkillRegistry(workspaceRoot: root)
        let skills = try await registry.loadSkills()
        let weather = try #require(skills.first(where: { $0.name == "weather" }))

        do {
            _ = try await registry.resolveEntrypoint(for: weather)
            Issue.record("Expected path traversal rejection")
        } catch {
            #expect(String(describing: error).lowercased().contains("skill directory"))
        }
    }

    @Test
    func loadsWeatherSkillFromIOSExampleProjectDirectory() async throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let exampleSkillsRoot = repoRoot
            .appendingPathComponent("Examples")
            .appendingPathComponent("iOS")
            .appendingPathComponent("OpenClawiOS")
            .appendingPathComponent("skills")
        #expect(FileManager.default.fileExists(atPath: exampleSkillsRoot.path))

        let workspaceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspaceRoot) }

        let registry = SkillRegistry(workspaceRoot: workspaceRoot, extraSkillDirs: [exampleSkillsRoot])
        let skills = try await registry.loadSkills()
        let names = Set(skills.map(\.name))
        #expect(names.contains("weather"))
        #expect(names.contains("calculator"))
        #expect(names.contains("slugify"))
        #expect(names.contains("json-pretty"))

        let weather = try #require(skills.first(where: { $0.name == "weather" }))
        let calculator = try #require(skills.first(where: { $0.name == "calculator" }))
        let weatherEntrypoint = try await registry.resolveEntrypoint(for: weather)
        let calculatorEntrypoint = try await registry.resolveEntrypoint(for: calculator)

        #expect(weatherEntrypoint?.lastPathComponent == "weather.js")
        #expect(weatherEntrypoint?.path.contains("/OpenClawiOS/skills/weather/scripts/") == true)
        #expect(calculatorEntrypoint?.lastPathComponent == "calculator.js")
        #expect(calculatorEntrypoint?.path.contains("/OpenClawiOS/skills/calculator/scripts/") == true)
    }
}
