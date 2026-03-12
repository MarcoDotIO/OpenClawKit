import Foundation
import Testing
@testable import OpenClawKit

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

    private static func fixtureModuleURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Examples/iOS/OpenClawiOS/skills/wasm-hello/module/hello.wasm")
    }
}
#endif
