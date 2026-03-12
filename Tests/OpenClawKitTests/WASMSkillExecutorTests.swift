import Foundation
import Testing
@testable import OpenClawKit
@testable import OpenClawCore

#if canImport(WasmKit) && canImport(WasmKitWASI)
@Suite("WASM skill executor")
struct WASMSkillExecutorTests {
    @Test
    func embeddedRuntimeExecutesBundledHelloModule() async throws {
        let moduleURL = Self.fixtureModuleURL()
        #expect(FileManager.default.fileExists(atPath: moduleURL.path))

        let executor = WASMSkillExecutor(
            runtimeCandidates: [],
            allowEnvironmentRuntimeOverride: false
        )
        let result = try await executor.executeModule(modulePath: moduleURL, input: "smoke-test")

        #expect(result.runtime == "wasmkit-wasi")
        #expect(!result.output.isEmpty)
        #expect(result.output.contains("Hello"))
    }

    @Test
    func processRuntimeRejectsExecutablesOutsideAllowlist() async throws {
        let executor = WASMSkillExecutor(
            runtimeCandidates: ["sh"],
            allowEnvironmentRuntimeOverride: false,
            execAllowlist: ExecCommandAllowlist(patterns: ["/usr/local/bin/*"])
        )

        do {
            _ = try await executor.executeModule(modulePath: Self.fixtureModuleURL(), input: "smoke-test")
            Issue.record("Expected exec allowlist denial")
        } catch {
            #expect(String(describing: error).contains("exec allowlist"))
        }
    }

    @Test
    func processRuntimeUsesAbsoluteEnvironmentOverride() async throws {
        let root = try self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let runtime = root.appendingPathComponent("fake-wasm-runtime", isDirectory: false)
        try self.writeExecutable(
            """
            #!/bin/sh
            printf 'runtime:%s' "$2"
            """,
            to: runtime
        )

        let executor = WASMSkillExecutor(
            runtimeCandidates: [],
            allowEnvironmentRuntimeOverride: true,
            execAllowlist: .exact(runtime),
            environmentProvider: { ["OPENCLAW_WASM_RUNTIME": runtime.path] }
        )
        let result = try await executor.executeModule(modulePath: Self.fixtureModuleURL(), input: "override")

        #expect(result.runtime == runtime.path)
        #expect(result.output == "runtime:override")
    }

    @Test
    func processRuntimeEnvironmentOverrideSupportsEmbeddedAlias() async throws {
        let executor = WASMSkillExecutor(
            runtimeCandidates: [],
            allowEnvironmentRuntimeOverride: true,
            environmentProvider: { ["OPENCLAW_WASM_RUNTIME": "embedded"] }
        )
        let result = try await executor.executeModule(modulePath: Self.fixtureModuleURL(), input: "alias")

        #expect(result.runtime == "wasmkit-wasi")
        #expect(result.output.contains("Hello"))
    }

    @Test
    func processRuntimeEnvironmentOverrideResolvesNamedBinaryFromPath() async throws {
        let root = try self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let runtime = root.appendingPathComponent("fake-wasm-runtime", isDirectory: false)
        try self.writeExecutable(
            """
            #!/bin/sh
            printf 'path:%s' "$2"
            """,
            to: runtime
        )

        let pathValue = root.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "")
        let executor = WASMSkillExecutor(
            runtimeCandidates: [],
            allowEnvironmentRuntimeOverride: true,
            execAllowlist: .exact(runtime),
            environmentProvider: {
                [
                    "OPENCLAW_WASM_RUNTIME": "fake-wasm-runtime",
                    "PATH": pathValue,
                ]
            }
        )
        let result = try await executor.executeModule(modulePath: Self.fixtureModuleURL(), input: "named")

        #expect(result.runtime == runtime.path)
        #expect(result.output == "path:named")
    }

    @Test
    func processRuntimeSurfacesNonZeroExitCodes() async throws {
        let root = try self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let runtime = root.appendingPathComponent("failing-wasm-runtime", isDirectory: false)
        try self.writeExecutable(
            """
            #!/bin/sh
            echo 'process failure' 1>&2
            exit 7
            """,
            to: runtime
        )

        let executor = WASMSkillExecutor(
            runtimeCandidates: [],
            allowEnvironmentRuntimeOverride: true,
            execAllowlist: .exact(runtime),
            environmentProvider: { ["OPENCLAW_WASM_RUNTIME": runtime.path] }
        )

        do {
            _ = try await executor.executeModule(modulePath: Self.fixtureModuleURL(), input: "boom")
            Issue.record("Expected failing process runtime to throw")
        } catch {
            #expect(String(describing: error).contains("exit code 7"))
            #expect(String(describing: error).contains("process failure"))
        }
    }

    @Test
    func processRuntimeEnvironmentOverrideSurfacesMissingBinaryError() async throws {
        let executor = WASMSkillExecutor(
            runtimeCandidates: [],
            allowEnvironmentRuntimeOverride: true,
            execAllowlist: ExecCommandAllowlist(patterns: ["/bin/*", "/usr/bin/*"]),
            environmentProvider: { ["OPENCLAW_WASM_RUNTIME": "missing-openclaw-runtime"] }
        )

        do {
            _ = try await executor.executeModule(modulePath: Self.fixtureModuleURL(), input: "missing")
            Issue.record("Expected missing runtime failure")
        } catch {
            #expect(String(describing: error).contains("Binary not found on PATH"))
        }
    }

    private static func fixtureModuleURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Examples/iOS/OpenClawiOS/skills/wasm-hello/module/hello.wasm")
    }

    private func makeTempDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclawkit-wasm-executor-tests", isDirectory: true)
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
#endif
