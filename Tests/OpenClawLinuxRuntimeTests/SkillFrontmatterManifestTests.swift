import Foundation
import Testing
import OpenClawProtocol
@testable import OpenClawSkills

@Suite("Skill frontmatter and manifest")
struct SkillFrontmatterManifestTests {
    private func definition(_ path: String) throws -> SkillDefinition {
        let entry = try #require(UpstreamRuntimeExtFixtures.skillCorpus.first { $0.path == path })
        return try #require(SkillRegistry.parseSkill(contents: entry.contents, filePath: "/fixtures/\(entry.path)", source: .bundled))
    }

    @Test
    func upstreamCorpusParsesWithoutIssues() throws {
        #expect(UpstreamRuntimeExtFixtures.skillCorpus.count >= 50)
        for entry in UpstreamRuntimeExtFixtures.skillCorpus {
            let parsed = SkillFrontmatter.parse(entry.contents)
            #expect(parsed.issues.isEmpty, "\(entry.path): \(parsed.issues)")
            let directory = URL(fileURLWithPath: entry.path).deletingLastPathComponent().lastPathComponent
            #expect(parsed.frontmatter["name"] == directory, "\(entry.path)")
            #expect(parsed.frontmatter["description"]?.isEmpty == false, "\(entry.path)")
            if let metadata = parsed.frontmatter["metadata"] {
                #expect(SkillManifestParser.manifestBlock(metadata: metadata) != nil, "\(entry.path) metadata did not parse")
            }
        }
    }

    @Test
    func appleRemindersManifest() throws {
        let skill = try self.definition("skills/apple-reminders/SKILL.md")
        #expect(skill.metadata.os == ["darwin"])
        #expect(skill.metadata.requires?.bins == ["remindctl"])
        #expect(skill.metadata.emoji == "⏰")
        #expect(skill.metadata.homepage == "https://github.com/steipete/remindctl")
        let brew = try #require(skill.metadata.install.first)
        #expect(brew.kind == .brew)
        #expect(brew.formula == "steipete/tap/remindctl")
        #expect(brew.bins == ["remindctl"])
        #expect(brew.id == "brew")
        #expect(skill.displayName == "Apple Reminders CLI (remindctl)")
        #expect(skill.description.hasPrefix("List, add, edit"))
    }

    @Test
    func downloadSpecsKeepDigestsAndOptions() throws {
        let skill = try self.definition("skills/sherpa-onnx-tts/SKILL.md")
        #expect(skill.metadata.os == ["darwin", "linux", "win32"])
        #expect(skill.metadata.requires?.env == ["SHERPA_ONNX_RUNTIME_DIR", "SHERPA_ONNX_MODEL_DIR"])
        let mac = try #require(skill.metadata.install.first { $0.id == "download-runtime-macos" })
        #expect(mac.kind == .download)
        #expect(mac.sha256 == "05ed5839bbdfb2da36bb9095961e6b4cfa470d55e29a9795100627dbc36df2ba")
        #expect(mac.os == ["darwin"])
        #expect(mac.stripComponents == 1)
        #expect(mac.extract == true)
        #expect(mac.archive == "tar.bz2")
        #expect(mac.targetDir == "runtime")
    }

    @Test
    func anyBinsAndConfigRequirements() throws {
        let skill = try self.definition("skills/coding-agent/SKILL.md")
        #expect(skill.metadata.requires?.anyBins == ["claude", "codex", "opencode"])
        #expect(skill.metadata.requires?.config == ["skills.entries.coding-agent.enabled"])
        #expect(skill.metadata.install.map(\.package) == ["@anthropic-ai/claude-code", "@openai/codex"])
    }

    @Test
    func json5ManifestFeatures() throws {
        let manifest = try #require(SkillManifestParser.parse(metadata: """
        {
          // comment
          openclaw: {
            emoji: 'x',
            always: true,
            skillKey: "custom-key",
            os: "darwin, linux",
            requires: { bins: ["a",], env: 'TOKEN' }, /* block */
            install: [
              { kind: "brew", formula: "good/tap/tool" },
              { kind: "brew", formula: "../escape" },
              { kind: "brew", formula: "-flag" },
              { kind: "download", url: "ftp://example.com/x" },
              { kind: "download", url: "https://example.com/x.tgz", sha256: "abc" },
              { kind: "download", url: "https://example.com/y.tgz", sha256: "\(String(repeating: "A", count: 64))" },
              { kind: "go", module: "example.com/tool@v1.2.3" },
              { kind: "uv", package: "tool==1.0" },
              { type: "node", package: "left-pad" },
              { kind: "brew", cask: "some-cask" },
              { kind: "unknown", formula: "x" },
            ],
            stripComponents: 0x10,
          },
        }
        """))
        #expect(manifest.emoji == "x")
        #expect(manifest.always == true)
        #expect(manifest.skillKey == "custom-key")
        #expect(manifest.os == ["darwin", "linux"])
        #expect(manifest.requires?.bins == ["a"])
        #expect(manifest.requires?.env == ["TOKEN"])
        #expect(manifest.install.map(\.kind) == [.brew, .download, .go, .uv, .node, .brew])
        #expect(manifest.install[1].sha256 == String(repeating: "a", count: 64))
        #expect(manifest.install[5].formula == "some-cask")
    }

    @Test
    func legacyManifestKeyIsRead() {
        let manifest = SkillManifestParser.parse(metadata: #"{"clawdbot": {"emoji": "🦞"}}"#)
        #expect(manifest?.emoji == "🦞")
        #expect(SkillManifestParser.parse(metadata: #"{"other": {}}"#) == nil)
        #expect(SkillManifestParser.parse(metadata: "not json") == nil)
    }

    @Test
    func yamlSubsetScalarsAndBlocks() {
        let parsed = SkillFrontmatter.parse("""
        \u{FEFF}---\r
        name: "quoted \\"name\\""\r
        description: >\r
          folded\r
          text\r
        notes: |\r
          line one\r
          line two\r
        single: 'it''s'\r
        flag: TRUE\r
        count: 1.0\r
        nothing: null\r
        list:\r
          - a\r
          - "b"\r
        nested:\r
          openclaw:\r
            emoji: "🧪"\r
            os: [darwin]\r
        colon: value: with colon\r
        ---   \r
        # Title\r
        Body\r
        """)
        #expect(parsed.issues.isEmpty)
        #expect(parsed.frontmatter["name"] == "quoted \"name\"")
        #expect(parsed.frontmatter["description"] == "folded text")
        #expect(parsed.frontmatter["notes"] == "line one\nline two")
        #expect(parsed.frontmatter["single"] == "it's")
        #expect(parsed.frontmatter["flag"] == "true")
        #expect(parsed.frontmatter["count"] == "1")
        // Upstream drops YAML nulls, then backfills the raw line-parser value for missing keys.
        #expect(parsed.frontmatter["nothing"] == "null")
        #expect(parsed.frontmatter["list"] == #"["a","b"]"#)
        #expect(parsed.frontmatter["nested"] == #"{"openclaw":{"emoji":"🧪","os":["darwin"]}}"#)
        #expect(parsed.frontmatter["colon"] == "value: with colon")
        #expect(parsed.body.hasPrefix("# Title\nBody"))
        let manifest = SkillManifestParser.parse(metadata: parsed.frontmatter["nested"])
        #expect(manifest?.os == ["darwin"])
    }

    @Test
    func inlineJSONMetadataKeepsRawText() {
        let parsed = SkillFrontmatter.parse("""
        ---
        name: inline
        metadata: {"openclaw": {"emoji": "⚡", "requires": {"bins": ["jq"]}}}
        ---
        """)
        #expect(parsed.frontmatter["metadata"] == #"{"openclaw": {"emoji": "⚡", "requires": {"bins": ["jq"]}}}"#)
        let manifest = SkillManifestParser.parse(metadata: parsed.frontmatter["metadata"])
        #expect(manifest?.requires?.bins == ["jq"])
    }

    @Test
    func unterminatedFrontmatterIsAnIssue() {
        let parsed = SkillFrontmatter.parse("---\nname: broken\n")
        #expect(parsed.frontmatter.isEmpty)
        #expect(parsed.issues.map(\.code) == ["UNTERMINATED_FRONTMATTER"])
        #expect(SkillFrontmatter.parse("no frontmatter").frontmatter.isEmpty)
    }

    @Test
    func malformedYAMLFallsBackToLineParser() {
        let parsed = SkillFrontmatter.parse("""
        ---
        name: lenient
        timeout-ms:500
          weird indentation
        ---
        """)
        #expect(!parsed.issues.isEmpty)
        #expect(parsed.frontmatter["name"] == "lenient")
    }

    @Test
    func invocationPolicyAndCommandDispatch() throws {
        let skill = try #require(SkillRegistry.parseSkill(contents: """
        ---
        name: Deploy Now!
        description: Deploys.
        user-invocable: false
        disable-model-invocation: yes
        command-dispatch: tool
        command-tool: exec
        command-arg-mode: fancy
        ---
        Body without heading.
        """, filePath: "/tmp/deploy/SKILL.md", source: .workspace))
        #expect(skill.invocation.userInvocable == false)
        #expect(skill.invocation.disableModelInvocation == true)
        #expect(skill.commandDispatch == SkillCommandDispatch(toolName: "exec", argMode: .raw))
        #expect(skill.displayName == "Deploy Now!")

        let defaults = try #require(SkillRegistry.parseSkill(contents: "---\nname: plain\ncommand_dispatch: tool\n---\n", filePath: "/tmp/p/SKILL.md", source: .workspace))
        #expect(defaults.invocation.userInvocable)
        #expect(!defaults.invocation.disableModelInvocation)
        #expect(defaults.commandDispatch == nil)
    }
}
