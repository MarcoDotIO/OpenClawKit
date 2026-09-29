import Foundation
import Testing
import OpenClawProtocol
@testable import OpenClawSkills

@Suite("Skill frontmatter hardening")
struct SkillFrontmatterHardeningTests {
    /// Parses on a detached task (a cooperative-pool thread with a small stack), like registry scans.
    private static func parseOnPool(_ contents: String) async -> ParsedSkillFrontmatter {
        await Task.detached { SkillFrontmatterParser.parseDetailed(contents) }.value
    }

    @Test
    func deeplyNestedFlowValuesReportTooDeepInsteadOfOverflowingTheStack() async {
        let nested = String(repeating: "[", count: 5_000) + String(repeating: "]", count: 5_000)
        let parsed = await Self.parseOnPool("---\nname: evil\nmetadata: \(nested)\n---\nbody")
        #expect(parsed.issues.map(\.code) == ["TOO_DEEP"])
        #expect(parsed.frontmatter["name"] == "evil", "the line parser fallback still reads the other keys")
        #expect(SkillManifestParser.manifestBlock(metadata: nested) == nil)
        let objects = String(repeating: "{a:", count: 3_000) + "1" + String(repeating: "}", count: 3_000)
        #expect(throws: FrontmatterSyntaxError.self) { _ = try FlowValueParser.parseDocument(objects) }
    }

    @Test
    func reasonableNestingStillParses() throws {
        let depth = FlowValueParser.maxDepth
        let nested = String(repeating: "[", count: depth) + "1" + String(repeating: "]", count: depth)
        _ = try FlowValueParser.parseDocument(nested)
        let tooDeep = "[" + nested + "]"
        #expect(throws: FrontmatterSyntaxError(code: "TOO_DEEP", message: "flow collection nesting exceeds \(depth)")) {
            _ = try FlowValueParser.parseDocument(tooDeep)
        }
    }

    @Test
    func deeplyIndentedYAMLReportsTooDeep() async {
        var block = "name: deep\nmetadata:\n"
        for level in 1...200 {
            block += String(repeating: " ", count: level) + "k\(level):\n"
        }
        block += String(repeating: " ", count: 201) + "leaf: 1\n"
        let parsed = await Self.parseOnPool("---\n\(block)---\nbody")
        #expect(parsed.issues.map(\.code) == ["TOO_DEEP"])
        #expect(parsed.frontmatter["name"] == "deep")
    }

    @Test
    func oversizedSkillFilesAreSkipped() throws {
        let root = try RuntimeExtTestSupport.temporaryDirectory("skill-size")
        defer { try? FileManager.default.removeItem(at: root) }
        let small = try RuntimeExtTestSupport.writeSkill(root: root, directory: "small", contents: "---\nname: small\ndescription: ok\n---\nbody")
        let big = try RuntimeExtTestSupport.writeSkill(
            root: root,
            directory: "big",
            contents: "---\nname: big\ndescription: huge\n---\n" + String(repeating: "x", count: SkillRegistry.maxSkillFileBytes)
        )
        #expect(try SkillRegistry.parseSkill(fileURL: small, source: .workspace)?.name == "small")
        #expect(try SkillRegistry.parseSkill(fileURL: big, source: .workspace) == nil)
    }
}
