import Foundation

/// Result payload returned from process execution.
public struct ProcessResult: Sendable {
    /// Executed command plus arguments.
    public let command: [String]
    /// Process termination status.
    public let exitCode: Int32
    /// Captured standard output.
    public let stdout: String
    /// Captured standard error.
    public let stderr: String

    /// Creates a process result.
    /// - Parameters:
    ///   - command: Executed command.
    ///   - exitCode: Process exit status.
    ///   - stdout: Captured stdout.
    ///   - stderr: Captured stderr.
    public init(command: [String], exitCode: Int32, stdout: String, stderr: String) {
        self.command = command
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

#if os(macOS) || os(Linux)
/// Actor-backed process runner for platforms that support `Process`.
public actor ProcessRunner {
    /// Creates a process runner.
    public init() {}

    /// Executes a command synchronously and captures output streams.
    /// - Parameters:
    ///   - command: Command plus arguments where the first entry is executable path.
    ///   - cwd: Optional working directory.
    ///   - allowlist: Optional executable allowlist enforced before launch.
    /// - Returns: Process execution result.
    public func run(
        _ command: [String],
        cwd: URL? = nil,
        allowlist: ExecCommandAllowlist? = nil
    ) throws -> ProcessResult {
        guard let executable = command.first else {
            throw OpenClawCoreError.invalidConfiguration("Process command cannot be empty")
        }

        let executableURL: URL
        if let allowlist {
            executableURL = try allowlist.authorizedExecutableURL(for: executable, cwd: cwd)
        } else {
            executableURL = try ExecCommandAllowlist.resolveExecutableURL(executable, cwd: cwd)
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = Array(command.dropFirst())
        process.currentDirectoryURL = cwd

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutCapture = PipeCapture(pipe: stdoutPipe)
        let stderrCapture = PipeCapture(pipe: stderrPipe)
        try process.run()
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()
        process.waitUntilExit()
        let outData = stdoutCapture.finish()
        let errData = stderrCapture.finish()
        return ProcessResult(
            command: command,
            exitCode: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }
}
#else
/// Process runner fallback for platforms without `Process` availability.
public actor ProcessRunner {
    /// Creates a process runner placeholder.
    public init() {}

    /// Always throws because process execution is unavailable on this platform.
    /// - Parameters:
    ///   - command: Command plus arguments.
    ///   - cwd: Optional working directory.
    ///   - allowlist: Optional executable allowlist enforced before launch.
    /// - Returns: Never returns successfully.
    public func run(
        _ command: [String],
        cwd: URL? = nil,
        allowlist: ExecCommandAllowlist? = nil
    ) throws -> ProcessResult {
        _ = command
        _ = cwd
        _ = allowlist
        throw OpenClawCoreError.unavailable("Process execution is unavailable on this platform")
    }
}
#endif

private final class LockedDataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ newData: Data) {
        self.lock.lock()
        self.data.append(newData)
        self.lock.unlock()
    }

    func snapshot() -> Data {
        self.lock.lock()
        let data = self.data
        self.lock.unlock()
        return data
    }
}

private final class PipeCapture: @unchecked Sendable {
    private let completion = DispatchGroup()
    private let buffer = LockedDataBuffer()
    private let handle: FileHandle
    private let queue: DispatchQueue

    init(pipe: Pipe) {
        self.handle = pipe.fileHandleForReading
        self.queue = DispatchQueue(label: "io.marcodotio.openclawkit.process-runner.pipe-capture.\(UUID().uuidString)")
        self.completion.enter()
        self.queue.async { [buffer, completion, handle] in
            let chunk = handle.readDataToEndOfFile()
            if !chunk.isEmpty {
                buffer.append(chunk)
            }
            completion.leave()
        }
    }

    func finish() -> Data {
        self.completion.wait()
        try? self.handle.close()
        return self.buffer.snapshot()
    }
}
