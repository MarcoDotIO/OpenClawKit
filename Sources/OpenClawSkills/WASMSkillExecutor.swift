import Foundation
import OpenClawCore

/// Result payload from WebAssembly skill execution.
public struct WASMSkillExecutionResult: Sendable, Equatable {
    /// Runtime identifier used for execution.
    public let runtime: String
    /// Captured output from runtime execution.
    public let output: String

    /// Creates a WASM skill execution result.
    public init(runtime: String, output: String) {
        self.runtime = runtime
        self.output = output
    }
}

/// Process-backed executor for WASM/WASI skill modules.
public actor WASMSkillExecutor {
    private let processRunner: ProcessRunner
    private let runtimeCandidates: [String]

    /// Creates a WASM skill executor.
    /// - Parameters:
    ///   - processRunner: Process execution runtime.
    ///   - runtimeCandidates: Ordered runtime binaries to probe.
    public init(
        processRunner: ProcessRunner = ProcessRunner(),
        runtimeCandidates: [String] = ["wasmtime", "wasmer"]
    ) {
        self.processRunner = processRunner
        self.runtimeCandidates = runtimeCandidates
    }

    /// Executes a WASM module.
    /// - Parameters:
    ///   - modulePath: Absolute path to `.wasm` module.
    ///   - input: Optional user input forwarded as trailing argument.
    /// - Returns: Captured execution result.
    public func executeModule(modulePath: URL, input: String = "") async throws -> WASMSkillExecutionResult {
        let runtimeBinary = try self.resolveRuntimeBinary()
        var command = [runtimeBinary, modulePath.path]
        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedInput.isEmpty {
            command.append(trimmedInput)
        }
        let result = try await self.processRunner.run(command, cwd: modulePath.deletingLastPathComponent())
        if result.exitCode != 0 {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw OpenClawCoreError.unavailable(
                "WASM skill execution failed with exit code \(result.exitCode): \(detail)"
            )
        }
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let output = stdout.isEmpty ? result.stderr.trimmingCharacters(in: .whitespacesAndNewlines) : stdout
        return WASMSkillExecutionResult(runtime: runtimeBinary, output: output)
    }

    private func resolveRuntimeBinary() throws -> String {
        if let configured = ProcessInfo.processInfo.environment["OPENCLAW_WASM_RUNTIME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty
        {
            return configured
        }
        for runtime in self.runtimeCandidates {
            if let resolved = try? BinaryUtils.ensureBinary(runtime) {
                return resolved
            }
        }
        throw OpenClawCoreError.unavailable(
            "No WASM runtime available. Set OPENCLAW_WASM_RUNTIME or install wasmtime/wasmer."
        )
    }
}
