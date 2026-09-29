import Foundation
import Testing
import OpenClawAgents
@testable import OpenClawMemory
@testable import OpenClawSkills

@Suite("Skill read jail and tool registration helpers")
struct SkillReadAccessTests {
    @Test
    func readJailAllowsWorkspaceAndSkillRootsOnly() async throws {
        let root = try RuntimeExtTestSupport.temporaryDirectory("skill-read")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("ws")
        let bundled = root.appendingPathComponent("bundled")
        try RuntimeExtTestSupport.writeSkill(root: bundled, directory: "tool", contents: "---\nname: tool\n---\n")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let registry = SkillRegistry(
            workspaceRoot: workspace,
            managedSkillsRoot: root.appendingPathComponent("managed"),
            bundledSkillsRoot: bundled,
            includePersonalAgentsRoot: false
        )
        let access = await registry.readAccess()
        #expect(access.allows(bundled.appendingPathComponent("tool/SKILL.md").path))
        #expect(access.allows("notes.md"))
        #expect(!access.allows("../bundled/../../etc/passwd"))
        #expect(!access.allows(root.appendingPathComponent("other.txt").path))
        #expect(throws: WorkspaceGuardError.self) { _ = try access.resolve("") }
    }

    @Test
    func memoryToolRegistrationHelpers() async throws {
        let root = try RuntimeExtTestSupport.temporaryDirectory("memory-tools")
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = AgentToolRegistry()
        await MemoryToolRegistration.registerMemoryTools(into: registry, engine: MemoryEngine(workspaceRoot: root))
        #expect(await registry.hasTool(named: "memory_search"))
        #expect(await registry.hasTool(named: "memory_get"))
        let registered = await MemoryToolRegistration.registerSpotlightSearch(into: registry)
        #expect(await registry.hasTool(named: "spotlight_search") == registered)
    }
}
