import Foundation
import OpenClawCore
#if canImport(SystemPackage)
import SystemPackage
#endif
#if canImport(WasmKit)
import WasmKit
#endif
#if canImport(WasmKitWASI)
import WasmKitWASI
#endif

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
    private let allowEnvironmentRuntimeOverride: Bool
    private let execAllowlist: ExecCommandAllowlist
    private let environmentProvider: @Sendable () -> [String: String]

    /// Creates a WASM skill executor.
    /// - Parameters:
    ///   - processRunner: Process execution runtime.
    ///   - runtimeCandidates: Ordered runtime binaries to probe.
    ///   - allowEnvironmentRuntimeOverride: Whether `OPENCLAW_WASM_RUNTIME` overrides runtime selection.
    public init(
        processRunner: ProcessRunner = ProcessRunner(),
        runtimeCandidates: [String] = ["wasmtime", "wasmer"],
        allowEnvironmentRuntimeOverride: Bool = true,
        execAllowlist: ExecCommandAllowlist = WASMSkillExecutor.defaultExecAllowlist(),
        environmentProvider: @escaping @Sendable () -> [String: String] = { ProcessInfo.processInfo.environment }
    ) {
        self.processRunner = processRunner
        self.runtimeCandidates = runtimeCandidates
        self.allowEnvironmentRuntimeOverride = allowEnvironmentRuntimeOverride
        self.execAllowlist = execAllowlist
        self.environmentProvider = environmentProvider
    }

    /// Executes a WASM module.
    /// - Parameters:
    ///   - modulePath: Absolute path to `.wasm` module.
    ///   - input: Optional user input forwarded as trailing argument.
    /// - Returns: Captured execution result.
    public func executeModule(modulePath: URL, input: String = "") async throws -> WASMSkillExecutionResult {
        if let runtimeBinary = self.resolveProcessRuntimeBinary() {
            return try await self.executeModuleWithProcessRuntime(
                runtimeBinary: runtimeBinary,
                modulePath: modulePath,
                input: input
            )
        }
        return try self.executeModuleWithEmbeddedRuntime(modulePath: modulePath, input: input)
    }

    private func executeModuleWithProcessRuntime(
        runtimeBinary: String,
        modulePath: URL,
        input: String
    ) async throws -> WASMSkillExecutionResult {
        var command = [runtimeBinary, modulePath.path]
        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedInput.isEmpty {
            command.append(trimmedInput)
        }
        let result = try await self.processRunner.run(
            command,
            cwd: modulePath.deletingLastPathComponent(),
            allowlist: self.execAllowlist
        )
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

    private func resolveProcessRuntimeBinary() -> String? {
        let environment = self.environmentProvider()
        if self.allowEnvironmentRuntimeOverride,
           let configured = environment["OPENCLAW_WASM_RUNTIME"]?
           .trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty
        {
            let normalized = configured.lowercased()
            if normalized == "wasmkit" || normalized == "embedded" || normalized == "wasi" {
                return nil
            }
            if configured.contains("/") {
                return configured
            }
            if let resolved = try? BinaryUtils.ensureBinary(configured, pathEnv: environment["PATH"]) {
                return resolved
            }
            return configured
        }
        for runtime in self.runtimeCandidates {
            if let resolved = try? BinaryUtils.ensureBinary(runtime, pathEnv: environment["PATH"]) {
                return resolved
            }
        }
        return nil
    }

    /// Default exec allowlist for process-backed WASM runtimes.
    public static func defaultExecAllowlist() -> ExecCommandAllowlist {
        ExecCommandAllowlist(
            patterns: [
                "/bin/*",
                "/usr/bin/*",
                "/usr/local/bin/*",
                "/opt/homebrew/bin/*",
                "/usr/local/Cellar/**/bin/*",
                "/opt/homebrew/Cellar/**/bin/*",
            ]
        )
    }

    private func executeModuleWithEmbeddedRuntime(
        modulePath: URL,
        input: String
    ) throws -> WASMSkillExecutionResult {
#if canImport(SystemPackage) && canImport(WasmKit) && canImport(WasmKitWASI)
        let stdinPipe = try FileDescriptor.pipe()
        let stdoutPipe = try FileDescriptor.pipe()
        let stderrPipe = try FileDescriptor.pipe()
        // Close each descriptor exactly once. A second close(2) of an already-closed descriptor can
        // close an unrelated file that another thread opened with the reused descriptor number.
        var openDescriptors: [FileDescriptor] = [
            stdinPipe.readEnd, stdinPipe.writeEnd,
            stdoutPipe.readEnd, stdoutPipe.writeEnd,
            stderrPipe.readEnd, stderrPipe.writeEnd,
        ]
        defer {
            for descriptor in openDescriptors {
                try? descriptor.close()
            }
        }
        func closeDescriptor(_ descriptor: FileDescriptor) throws {
            openDescriptors.removeAll { $0 == descriptor }
            try descriptor.close()
        }

        var wasiArgs = ["openclaw-skill"]
        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedInput.isEmpty {
            wasiArgs.append(trimmedInput)
        }

        // Use an isolated EOF-only stdin so the WASI bridge never mutates the process-wide stdin descriptor.
        try closeDescriptor(stdinPipe.writeEnd)
        let wasi = try WASIBridgeToHost(
            args: wasiArgs,
            environment: [:],
            preopens: [],
            stdin: stdinPipe.readEnd,
            stdout: stdoutPipe.writeEnd,
            stderr: stderrPipe.writeEnd
        )

        let module = try parseWasm(filePath: FilePath(modulePath.path))
        let engine = Engine()
        let store = Store(engine: engine)
        var imports = Imports()
        wasi.link(to: &imports, store: store)
        let instance = try module.instantiate(store: store, imports: imports)
        let exitCode = try wasi.start(instance)

        try closeDescriptor(stdoutPipe.writeEnd)
        try closeDescriptor(stderrPipe.writeEnd)

        let stdoutBytes = try Self.readAll(from: stdoutPipe.readEnd)
        let stderrBytes = try Self.readAll(from: stderrPipe.readEnd)
        let stdout = String(decoding: stdoutBytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let stderr = String(decoding: stderrBytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if exitCode != 0 {
            let detail = stderr.isEmpty ? stdout : stderr
            throw OpenClawCoreError.unavailable(
                "WASM skill execution failed with exit code \(exitCode): \(detail)"
            )
        }

        let output = stdout.isEmpty ? stderr : stdout
        return WASMSkillExecutionResult(runtime: "wasmkit-wasi", output: output)
#else
        _ = modulePath
        _ = input
        throw OpenClawCoreError.unavailable(
            "No WASM runtime available. Set OPENCLAW_WASM_RUNTIME or install wasmtime/wasmer."
        )
#endif
    }

    #if canImport(SystemPackage)
    private static func readAll(from descriptor: FileDescriptor) throws -> [UInt8] {
        var allBytes: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let bytesRead = try buffer.withUnsafeMutableBytes { rawBuffer in
                try descriptor.read(into: rawBuffer)
            }
            if bytesRead == 0 {
                break
            }
            allBytes.append(contentsOf: buffer.prefix(bytesRead))
        }
        return allBytes
    }
    #endif
}
