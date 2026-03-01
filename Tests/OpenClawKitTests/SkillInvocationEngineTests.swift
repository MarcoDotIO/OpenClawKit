import Foundation
import Testing
@testable import OpenClawKit

@Suite("Skill invocation engine")
struct SkillInvocationEngineTests {
    struct ExtensionExecutor: SkillExecutor {
        let id: String
        let handledExtension: String
        let delayNs: UInt64
        let outputPrefix: String

        init(
            id: String = "extension-executor",
            handledExtension: String = "exec",
            delayNs: UInt64 = 0,
            outputPrefix: String = "exec"
        ) {
            self.id = id
            self.handledExtension = handledExtension
            self.delayNs = delayNs
            self.outputPrefix = outputPrefix
        }

        func canExecute(skill _: SkillDefinition, entrypoint: URL) -> Bool {
            entrypoint.pathExtension.lowercased() == self.handledExtension
        }

        func execute(skill _: SkillDefinition, entrypoint _: URL, input: String) async throws -> String {
            if self.delayNs > 0 {
                try await Task.sleep(nanoseconds: self.delayNs)
            }
            return "\(self.outputPrefix):\(input)"
        }
    }

    @Test
    func supportsCustomExecutorBackends() async throws {
        let root = try self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try self.writeSkill(
            root: root,
            name: "custom-skill",
            entrypoint: "scripts/run.exec"
        )

        let engine = SkillInvocationEngine(
            workspaceRoot: root,
            invocationTimeoutMs: 2_000,
            executors: [ExtensionExecutor(id: "mock-exec")]
        )
        let result = try await engine.invokeIfRequested(message: "/custom-skill hello world")
        let invocation = try #require(result)

        #expect(invocation.output == "exec:hello world")
        #expect(invocation.executorID == "mock-exec")
        #expect((invocation.durationMs ?? 0) >= 0)
    }

    @Test
    func timesOutExecutorUsingDefaultPolicy() async throws {
        let root = try self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try self.writeSkill(
            root: root,
            name: "slow-skill",
            entrypoint: "scripts/run.exec"
        )

        let engine = SkillInvocationEngine(
            workspaceRoot: root,
            invocationTimeoutMs: 10,
            executors: [ExtensionExecutor(delayNs: 60_000_000)]
        )

        do {
            _ = try await engine.invokeIfRequested(message: "/slow-skill test")
            Issue.record("Expected timeout error")
        } catch {
            #expect(String(describing: error).contains("timed out"))
        }
    }

    @Test
    func supportsExplicitOnlyAndPerSkillTimeoutOverride() async throws {
        let root = try self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try self.writeSkill(
            root: root,
            name: "explicit-skill",
            entrypoint: "scripts/run.exec",
            extraFrontmatter: [
                "requires-explicit-invocation": "true",
                "timeoutMs": "120",
            ]
        )

        let engine = SkillInvocationEngine(
            workspaceRoot: root,
            invocationTimeoutMs: 10,
            executors: [ExtensionExecutor(delayNs: 50_000_000, outputPrefix: "explicit")]
        )

        let inferred = try await engine.invokeIfRequested(message: "please run explicit skill now")
        #expect(inferred == nil)

        let explicit = try await engine.invokeIfRequested(message: "/explicit-skill now")
        #expect(explicit?.output == "explicit:now")
        #expect(explicit?.executorID == "extension-executor")
    }

    @Test
    func supportsExplicitInvocationForHyphenatedSkillNames() async throws {
        let root = try self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try self.writeSkill(
            root: root,
            name: "json-pretty",
            entrypoint: "scripts/run.exec"
        )

        let engine = SkillInvocationEngine(
            workspaceRoot: root,
            invocationTimeoutMs: 500,
            executors: [ExtensionExecutor(outputPrefix: "hyphen")]
        )
        let result = try await engine.invokeIfRequested(message: "/json-pretty {\"z\":1,\"a\":2}")

        #expect(result?.output == "hyphen:{\"z\":1,\"a\":2}")
        #expect(result?.skillName == "json-pretty")
    }

    private func makeWorkspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclawkit-skill-invocation-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @discardableResult
    private func writeSkill(
        root: URL,
        name: String,
        entrypoint: String,
        extraFrontmatter: [String: String] = [:]
    ) throws -> URL {
        let skillRoot = root.appendingPathComponent("skills", isDirectory: true).appendingPathComponent(name, isDirectory: true)
        let entrypointFile = skillRoot.appendingPathComponent(entrypoint, isDirectory: false)
        try FileManager.default.createDirectory(at: entrypointFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/usr/bin/env bash\n".write(to: entrypointFile, atomically: true, encoding: .utf8)

        var frontmatterLines: [String] = [
            "---",
            "name: \(name)",
            "description: test skill",
            "entrypoint: \(entrypoint)",
        ]
        for key in extraFrontmatter.keys.sorted() {
            if let value = extraFrontmatter[key] {
                frontmatterLines.append("\(key): \(value)")
            }
        }
        frontmatterLines.append("---")
        frontmatterLines.append("")
        frontmatterLines.append("Skill body.")
        let skillFile = skillRoot.appendingPathComponent("SKILL.md", isDirectory: false)
        try frontmatterLines.joined(separator: "\n").write(to: skillFile, atomically: true, encoding: .utf8)
        return skillFile
    }
}

