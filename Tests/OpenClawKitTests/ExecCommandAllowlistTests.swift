import Foundation
import Testing
@testable import OpenClawCore

@Suite("Exec command allowlist")
struct ExecCommandAllowlistTests {
    @Test
    func matchesWildcardPatternsAndNormalizesRelativePaths() throws {
        let root = try self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let executable = root
            .appendingPathComponent("tools", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("helper", isDirectory: false)
        try self.writeExecutable("echo helper\n", to: executable)

        let allowlist = ExecCommandAllowlist(
            patterns: [
                "  \(root.path)/tools/**  ",
                "/bin/e?ho",
                "/usr/bin/e?ho",
                "",
            ]
        )

        #expect(allowlist.matches(path: "./tools/bin/../bin/helper", cwd: root))
        #expect(allowlist.matches(path: "echo"))
        #expect(allowlist.patterns.count == 3)
    }

    @Test
    func exactAndWorkspaceFactoriesRespectRealpaths() throws {
        let root = try self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let inside = root.appendingPathComponent("bin", isDirectory: true).appendingPathComponent("tool", isDirectory: false)
        try self.writeExecutable("echo ok\n", to: inside)

        let exact = ExecCommandAllowlist.exact(inside)
        #expect(exact.matches(url: inside))

        let workspace = ExecCommandAllowlist.workspace(root)
        #expect(workspace.matches(url: inside))
    }

    @Test
    func rejectsSymlinkEscapesAfterCanonicalization() throws {
        let root = try self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let outside = try self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: outside) }

        let externalExecutable = outside.appendingPathComponent("tool", isDirectory: false)
        try self.writeExecutable("echo escape\n", to: externalExecutable)

        let symlink = root.appendingPathComponent("bin", isDirectory: true).appendingPathComponent("tool", isDirectory: false)
        try FileManager.default.createDirectory(at: symlink.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: externalExecutable)

        let allowlist = ExecCommandAllowlist.workspace(root)
        #expect(allowlist.matches(url: symlink) == false)
    }

    @Test
    func processRunnerAllowsMatchingExecutableAndRejectsDeniedOnes() async throws {
        let runner = ProcessRunner()

        let allowed = try await runner.run(["echo", "ok"], allowlist: ExecCommandAllowlist(patterns: ["/bin/e*", "/usr/bin/e*"]))
        #expect(allowed.exitCode == 0)
        #expect(allowed.stdout.contains("ok"))

        let root = try self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("tool", isDirectory: false)
        try self.writeExecutable("#!/bin/sh\necho denied\n", to: executable)

        do {
            _ = try await runner.run([executable.path], allowlist: ExecCommandAllowlist(patterns: ["/bin/*"]))
            Issue.record("Expected exec allowlist denial")
        } catch {
            #expect(String(describing: error).contains("exec allowlist"))
        }
    }

    @Test
    func processRunnerRejectsEmptyCommands() async throws {
        let runner = ProcessRunner()

        do {
            _ = try await runner.run([])
            Issue.record("Expected empty process command rejection")
        } catch {
            #expect(String(describing: error).contains("cannot be empty"))
        }
    }

    @Test
    func rejectsInvalidCandidatesAndEmptyExecutables() throws {
        let allowlist = ExecCommandAllowlist(patterns: ["/bin/*"])
        #expect(allowlist.matches(path: "") == false)

        do {
            _ = try allowlist.authorizedExecutableURL(for: "   ")
            Issue.record("Expected empty executable rejection")
        } catch {
            #expect(String(describing: error).contains("cannot be empty"))
        }
    }

    @Test
    func normalizesRelativeGlobPatternsAndCurrentDirectoryRelativePaths() throws {
        let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let root = currentDirectory
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("exec-allowlist-fixtures", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let executable = root
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("tool", isDirectory: false)
        try self.writeExecutable("#!/bin/sh\necho fixture\n", to: executable)

        let relativePattern = ".build/exec-allowlist-fixtures/*/bin/./../bin/*"
        let allowlist = ExecCommandAllowlist(patterns: [relativePattern])
        #expect(allowlist.patterns[0].contains("exec-allowlist-fixtures"))
        #expect(allowlist.patterns[0].hasSuffix("/bin/*"))

        let relativeExecutablePath = executable.path.replacingOccurrences(of: currentDirectory.path + "/", with: "")
        let resolved = try ExecCommandAllowlist.resolveExecutableURL(relativeExecutablePath)
        #expect(allowlist.matches(url: resolved))
    }

    private func makeTempDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclawkit-exec-allowlist-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeExecutable(_ body: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
