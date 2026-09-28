#if os(macOS) || os(Linux)
import Foundation
import OpenClawCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// MCP stdio transport: launches the server as a child process speaking newline-delimited JSON-RPC.
///
/// Available on macOS and Linux only (iOS-family platforms cannot spawn processes; Mac App Store
/// sandboxed apps can only launch executables embedded in their bundle). The command must be
/// permitted by the exec allowlist unless `allowUnlistedCommands` is set. The child inherits only
/// `PATH`, `HOME`, `LANG`, `TMPDIR` (plus `LC_*`, `USER`, `LOGNAME`, `SHELL`) and the server's `env`.
///
/// stderr lines are reported to the diagnostics sink as `mcp.stderr` with the upstream
/// `bundle-mcp:<name>:` prefix; a partial line is flushed after 250 ms and each line keeps at most an
/// 8 KiB tail (`[stderr line truncated]`). Closing the transport closes stdin, then sends SIGTERM and
/// finally SIGKILL after the grace period.
public actor MCPStdioTransport: MCPTransport {
    /// Messages and close events from the server.
    nonisolated public let events: AsyncStream<MCPTransportEvent>
    private let continuation: AsyncStream<MCPTransportEvent>.Continuation
    private let process: Process
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let serverName: String
    private let stdoutDecoder: LineDecoder
    private let stderrCollector: StderrCollector
    private let shutdownGraceSeconds: Double
    private var started = false
    private var closed = false

    /// Environment variables inherited from the host process.
    public static let inheritedEnvironmentKeys: Set<String> = ["PATH", "HOME", "LANG", "TMPDIR", "USER", "LOGNAME", "SHELL"]

    /// Creates a stdio transport.
    /// - Parameters:
    ///   - serverName: Declared server name.
    ///   - config: Server definition (`command`, `args`, `env`, `cwd`).
    ///   - allowlist: Executables the transport may launch.
    ///   - allowUnlistedCommands: Launch commands outside the allowlist.
    ///   - diagnostics: Diagnostics sink for stderr.
    ///   - maxLineBytes: Maximum stdout line size (default 10 MiB).
    ///   - shutdownGraceSeconds: Wait between closing stdin, SIGTERM and SIGKILL (default 2 s).
    /// - Throws: When the command is missing, cannot be resolved, or is not permitted.
    public init(
        serverName: String,
        config: MCPServerConfig,
        allowlist: ExecCommandAllowlist,
        allowUnlistedCommands: Bool = false,
        diagnostics: RuntimeDiagnosticSink? = nil,
        maxLineBytes: Int = OpenClawMCP.defaultMaxMessageBytes,
        shutdownGraceSeconds: Double = 2
    ) throws {
        guard let command = config.command?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty else {
            throw OpenClawCoreError.invalidConfiguration("stdio MCP server \(serverName) requires a non-empty command")
        }
        let cwd = config.cwd.map { URL(fileURLWithPath: $0) }
        let executable = try ExecCommandAllowlist.resolveExecutableURL(command, cwd: cwd)
        guard allowUnlistedCommands || allowlist.matches(url: executable) else {
            throw OpenClawCoreError.invalidConfiguration(
                "stdio MCP server \(serverName): \(executable.path) is not permitted by the exec allowlist"
            )
        }
        self.serverName = serverName
        self.shutdownGraceSeconds = max(0, shutdownGraceSeconds)
        (self.events, self.continuation) = AsyncStream<MCPTransportEvent>.makeStream()
        let process = Process()
        process.executableURL = executable
        process.arguments = config.args ?? []
        var environment: [String: String] = [:]
        for (key, value) in ProcessInfo.processInfo.environment where Self.inheritedEnvironmentKeys.contains(key) || key.hasPrefix("LC_") {
            environment[key] = value
        }
        for (key, value) in config.env ?? [:] {
            environment[key] = value
        }
        process.environment = environment
        if let cwd { process.currentDirectoryURL = cwd }
        self.process = process
        self.stdoutDecoder = LineDecoder(maxLineBytes: maxLineBytes)
        self.stderrCollector = StderrCollector(serverName: serverName, diagnostics: diagnostics)
    }

    /// Process identifier once started.
    public var processIdentifier: Int32? {
        self.started ? self.process.processIdentifier : nil
    }

    /// Launches the process and starts reading stdout/stderr.
    public func start() async throws {
        guard !self.started else { return }
        self.started = true
        self.process.standardInput = self.stdinPipe
        self.process.standardOutput = self.stdoutPipe
        self.process.standardError = self.stderrPipe
        let continuation = self.continuation
        let decoder = self.stdoutDecoder
        self.stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            do {
                for line in try decoder.feed(chunk) {
                    guard !line.isEmpty else { continue }
                    for message in (try? MCPJSONRPCMessage.decode(line)) ?? [] {
                        continuation.yield(.message(message))
                    }
                }
            } catch let error as MCPTransportError {
                handle.readabilityHandler = nil
                continuation.yield(.closed(error))
            } catch {}
        }
        let collector = self.stderrCollector
        self.stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                collector.finish()
                return
            }
            collector.feed(chunk)
        }
        self.process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            Task { await self?.processExited(status: status) }
        }
        do {
            try self.process.run()
        } catch {
            self.closed = true
            throw MCPTransportError.closed("failed to launch \(self.serverName): \(error.localizedDescription)")
        }
    }

    /// Writes one message followed by a newline to stdin.
    public func send(_ message: MCPJSONRPCMessage) async throws {
        guard self.started, !self.closed else { throw MCPTransportError.closed("stdio transport is not running") }
        var data = try message.encoded()
        data.append(0x0A)
        do {
            try self.stdinPipe.fileHandleForWriting.write(contentsOf: data)
        } catch {
            throw MCPTransportError.closed("failed to write to \(self.serverName): \(error.localizedDescription)")
        }
    }

    /// Closes stdin, then escalates to SIGTERM and SIGKILL if the process keeps running.
    public func close() async {
        guard !self.closed else { return }
        self.closed = true
        try? self.stdinPipe.fileHandleForWriting.close()
        if self.started, self.process.isRunning {
            if !(await self.waitForExit(seconds: self.shutdownGraceSeconds)) {
                self.process.terminate()
                if !(await self.waitForExit(seconds: self.shutdownGraceSeconds)) {
                    _ = kill(self.process.processIdentifier, SIGKILL)
                    _ = await self.waitForExit(seconds: 1)
                }
            }
        }
        self.stdoutPipe.fileHandleForReading.readabilityHandler = nil
        self.stderrPipe.fileHandleForReading.readabilityHandler = nil
        self.stderrCollector.finish()
        self.continuation.yield(.closed(nil))
        self.continuation.finish()
    }

    private func waitForExit(seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while self.process.isRunning {
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }

    private func processExited(status: Int32) {
        self.stderrCollector.finish()
        guard !self.closed else { return }
        self.closed = true
        let error: MCPTransportError? = status == 0 ? nil : .closed("\(self.serverName) exited with status \(status)")
        self.continuation.yield(.closed(error ?? .closed("\(self.serverName) exited")))
        self.continuation.finish()
    }
}

/// Thread-safe newline framing with a per-line size cap (tolerates `\r\n`).
final class LineDecoder: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let maxLineBytes: Int

    init(maxLineBytes: Int) {
        self.maxLineBytes = maxLineBytes
    }

    func feed(_ chunk: Data) throws -> [Data] {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.buffer.append(chunk)
        var lines: [Data] = []
        while let newline = self.buffer.firstIndex(of: 0x0A) {
            var line = Data(self.buffer[self.buffer.startIndex..<newline])
            if line.last == 0x0D { line.removeLast() }
            lines.append(line)
            self.buffer.removeSubrange(self.buffer.startIndex...newline)
        }
        if self.buffer.count > self.maxLineBytes {
            self.buffer.removeAll()
            throw MCPTransportError.eventTooLarge(limit: self.maxLineBytes)
        }
        return lines
    }
}

/// Collects child stderr into prefixed diagnostic lines (upstream `bundle-mcp:<name>:`).
final class StderrCollector: @unchecked Sendable {
    /// Maximum bytes kept per line.
    static let tailLimit = 8 * 1_024
    /// Partial-line flush delay.
    static let partialFlushDelay: TimeInterval = 0.25

    private let lock = NSLock()
    private var buffer = Data()
    private var truncated = false
    private var flushGeneration = 0
    private let serverName: String
    private let diagnostics: RuntimeDiagnosticSink?
    private(set) var recentLines: [String] = []

    init(serverName: String, diagnostics: RuntimeDiagnosticSink?) {
        self.serverName = serverName
        self.diagnostics = diagnostics
    }

    /// Lines emitted so far (most recent last, at most 50).
    func snapshot() -> [String] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.recentLines
    }

    func feed(_ chunk: Data) {
        var emit: [(String, Bool)] = []
        self.lock.lock()
        self.buffer.append(chunk)
        while let newline = self.buffer.firstIndex(of: 0x0A) {
            var line = Data(self.buffer[self.buffer.startIndex..<newline])
            if line.last == 0x0D { line.removeLast() }
            self.buffer.removeSubrange(self.buffer.startIndex...newline)
            emit.append((self.render(line), false))
            self.truncated = false
        }
        if self.buffer.count > Self.tailLimit {
            self.buffer = Data(self.buffer.suffix(Self.tailLimit))
            self.truncated = true
        }
        self.flushGeneration += 1
        let generation = self.flushGeneration
        let hasPartial = !self.buffer.isEmpty
        self.lock.unlock()
        for (line, partial) in emit {
            self.report(line, partial: partial)
        }
        if hasPartial {
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.partialFlushDelay) { [weak self] in
                self?.flushPartial(generation: generation)
            }
        }
    }

    func finish() {
        self.lock.lock()
        let remaining = self.buffer
        self.buffer.removeAll()
        self.flushGeneration += 1
        let line = remaining.isEmpty ? nil : self.render(remaining)
        self.lock.unlock()
        if let line { self.report(line, partial: false) }
    }

    private func flushPartial(generation: Int) {
        self.lock.lock()
        guard generation == self.flushGeneration, !self.buffer.isEmpty else {
            self.lock.unlock()
            return
        }
        // Only flush complete UTF-8 sequences; an incomplete trailing sequence waits for more bytes.
        let complete = Self.completeUTF8Prefix(self.buffer)
        guard complete > 0 else {
            self.lock.unlock()
            return
        }
        let head = Data(self.buffer.prefix(complete))
        self.buffer.removeFirst(complete)
        let line = self.render(head)
        self.lock.unlock()
        self.report(line, partial: true)
    }

    private func render(_ data: Data) -> String {
        let text = String(decoding: data, as: UTF8.self)
        return self.truncated ? "[stderr line truncated] " + text : text
    }

    private func report(_ line: String, partial: Bool) {
        let prefixed = "bundle-mcp:\(self.serverName): \(line)"
        self.lock.lock()
        self.recentLines.append(prefixed)
        if self.recentLines.count > 50 { self.recentLines.removeFirst(self.recentLines.count - 50) }
        self.lock.unlock()
        guard let diagnostics else { return }
        let event = RuntimeDiagnosticEvent(
            subsystem: "mcp",
            name: "mcp.stderr",
            metadata: ["server": self.serverName, "line": prefixed, "partial": partial ? "true" : "false"]
        )
        Task { await diagnostics(event) }
    }

    /// Length of the longest prefix that does not end in the middle of a UTF-8 sequence.
    static func completeUTF8Prefix(_ data: Data) -> Int {
        let bytes = [UInt8](data)
        var index = bytes.count - 1
        var continuation = 0
        while index >= 0, bytes[index] & 0xC0 == 0x80, continuation < 3 {
            continuation += 1
            index -= 1
        }
        guard index >= 0 else { return 0 }
        let lead = bytes[index]
        let expected: Int
        if lead & 0xE0 == 0xC0 {
            expected = 2
        } else if lead & 0xF0 == 0xE0 {
            expected = 3
        } else if lead & 0xF8 == 0xF0 {
            expected = 4
        } else {
            expected = 1
        }
        return continuation + 1 >= expected ? bytes.count : index
    }
}
#endif
