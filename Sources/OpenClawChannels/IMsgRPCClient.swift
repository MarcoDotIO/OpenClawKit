import Foundation
#if canImport(Glibc)
import Glibc
#endif
import OpenClawCore
import OpenClawProtocol

// Newline-delimited JSON-RPC client for `imsg rpc --json` (port of upstream
// `extensions/imessage/src/client.ts`). The client runs over an ``IMsgRPCPipe``; on macOS and
// Linux ``IMsgProcessPipe`` spawns the `imsg` CLI (on Linux `cliPath` is an SSH wrapper that runs
// `imsg` on the Messages Mac). Other platforms can supply their own pipe.

/// Event produced by an ``IMsgRPCPipe``.
public enum IMsgRPCPipeEvent: Sendable, Equatable {
    /// One stdout line (without the trailing newline).
    case stdout(String)
    /// One stderr line.
    case stderr(String)
    /// The process exited (status `nil` when unknown).
    case exited(status: Int32?)
}

/// Bidirectional line pipe to an `imsg rpc` process.
public protocol IMsgRPCPipe: Sendable {
    /// Starts the process and returns its event stream (finishes after ``IMsgRPCPipeEvent/exited(status:)``).
    /// - Returns: Event stream.
    func open() async throws -> AsyncStream<IMsgRPCPipeEvent>
    /// Writes one line to stdin (a trailing newline is appended).
    /// - Parameter line: JSON line.
    func write(line: String) async throws
    /// Closes stdin and terminates the process after a short grace period.
    func close() async
}

/// JSON-RPC error returned by `imsg`.
public struct IMsgRPCError: Error, LocalizedError, Sendable, Equatable {
    /// Error code.
    public var code: Int?
    /// Error message (including `code=` and data suffixes like upstream).
    public var message: String
    /// Error data.
    public var data: AnyCodable?

    /// Creates an error.
    /// - Parameters:
    ///   - code: Code.
    ///   - message: Message.
    ///   - data: Data.
    public init(code: Int? = nil, message: String, data: AnyCodable? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    /// Error description.
    public var errorDescription: String? {
        self.message
    }
}

/// Notification (a JSON-RPC message without an id) from `imsg`.
public struct IMsgRPCNotification: Sendable, Equatable {
    /// Method (`message`, `error`, ...).
    public var method: String
    /// Parameters.
    public var params: AnyCodable?

    /// Creates a notification.
    /// - Parameters:
    ///   - method: Method.
    ///   - params: Parameters.
    public init(method: String, params: AnyCodable?) {
        self.method = method
        self.params = params
    }
}

/// JSON-RPC client for `imsg rpc --json`.
public actor IMsgRPCClient {
    /// Default request timeout (probe and control calls).
    public static let defaultTimeoutMs = 10_000
    /// Send timeout: imsg waits up to 150 s for a bridge send plus an AppleScript fallback.
    public static let sendTimeoutMs = 180_000
    /// Actionable error when imsg cannot read `chat.db`.
    public static let fullDiskAccessError =
        "imsg cannot access ~/Library/Messages/chat.db. Grant Full Disk Access to the Gateway/launcher process and restart Gateway."
    /// Guidance appended when the private-API bridge stalls.
    public static let bridgeStallGuidance =
        "The imsg private API bridge stopped responding. Run `imsg launch` to re-inject the dylib, "
            + "then probe the channel again to refresh capability detection."

    /// Methods that deliver a message: once the request line was handed to imsg, a timeout or a
    /// process exit means the message may already have been sent.
    static let sendMethods: Set<String> = ["send", "send.attachment"]

    private struct Pending {
        let method: String
        let continuation: CheckedContinuation<AnyCodable, Error>
        let timeout: Task<Void, Never>?
    }

    private let pipe: any IMsgRPCPipe
    private var pending: [Int: Pending] = [:]
    private var nextID = 1
    private var running = false
    private var terminal: Error?
    private var publicProcessError: String?
    private var readerTask: Task<Void, Never>?
    private let notificationContinuation: AsyncStream<IMsgRPCNotification>.Continuation
    private var bridgeStallHandler: (@Sendable () async -> Void)?

    /// Notifications (`message`, `error`) from imsg.
    nonisolated public let notifications: AsyncStream<IMsgRPCNotification>

    /// Creates a client.
    /// - Parameter pipe: Process pipe.
    public init(pipe: any IMsgRPCPipe) {
        self.pipe = pipe
        let (stream, continuation) = AsyncStream<IMsgRPCNotification>.makeStream()
        self.notifications = stream
        self.notificationContinuation = continuation
    }

    /// Whether the process is running.
    public var isRunning: Bool {
        self.running && self.terminal == nil
    }

    /// Terminal transport error, once the process has closed.
    public var terminalError: Error? {
        self.terminal
    }

    /// Registers a callback invoked when imsg reports a private-API bridge stall.
    /// - Parameter handler: Callback (for example to invalidate cached capability status).
    public func setBridgeStallHandler(_ handler: (@Sendable () async -> Void)?) {
        self.bridgeStallHandler = handler
    }

    /// Starts the process.
    public func start() async throws {
        guard !self.running else { return }
        let events = try await self.pipe.open()
        self.running = true
        self.readerTask = Task { [weak self] in
            for await event in events {
                await self?.handle(event)
            }
            await self?.finish(OpenClawCoreError.unavailable("imsg rpc closed"))
        }
    }

    /// Stops the process and fails pending requests.
    public func stop() async {
        guard self.running else { return }
        await self.pipe.close()
        self.finish(OpenClawCoreError.unavailable("imsg rpc stopped"))
        self.readerTask?.cancel()
        self.readerTask = nil
    }

    /// Sends a request and waits for its result.
    /// - Parameters:
    ///   - method: Method.
    ///   - params: Parameters.
    ///   - timeoutMs: Timeout (`0` disables it).
    /// - Returns: Result value.
    public func request(_ method: String, params: [String: AnyCodable] = [:], timeoutMs: Int = IMsgRPCClient.defaultTimeoutMs) async throws -> AnyCodable {
        if let terminal {
            throw terminal
        }
        guard self.running else {
            throw OpenClawCoreError.unavailable("imsg rpc not running")
        }
        let id = self.nextID
        self.nextID += 1
        let payload: [String: AnyCodable] = [
            "jsonrpc": AnyCodable("2.0"),
            "id": AnyCodable(id),
            "method": AnyCodable(method),
            "params": AnyCodable(params),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let line = String(decoding: try encoder.encode(payload), as: UTF8.self)
        do {
            return try await withCheckedThrowingContinuation { continuation in
                let timeout: Task<Void, Never>? = timeoutMs > 0
                    ? Task { [weak self] in
                        try? await Task.sleep(nanoseconds: ChannelAsync.nanoseconds(milliseconds: timeoutMs))
                        guard !Task.isCancelled else { return }
                        await self?.expire(id)
                    }
                    : nil
                self.pending[id] = Pending(method: method, continuation: continuation, timeout: timeout)
                Task { [weak self, pipe] in
                    do {
                        try await pipe.write(line: line)
                    } catch {
                        // A stdin failure (EPIPE) is terminal: fail pending work immediately.
                        await self?.failTransport(error, unwrittenID: id)
                    }
                }
            }
        } catch {
            if error.localizedDescription.contains("Timed out waiting for response") {
                await self.bridgeStallHandler?()
                throw IMsgRPCError(
                    code: (error as? IMsgRPCError)?.code,
                    message: "\(error.localizedDescription) \(Self.bridgeStallGuidance)",
                    data: (error as? IMsgRPCError)?.data
                )
            }
            throw error
        }
    }

    private func expire(_ id: Int) {
        guard let entry = self.pending.removeValue(forKey: id) else { return }
        entry.continuation.resume(throwing: Self.pendingFailure(OpenClawCoreError.unavailable("imsg rpc timeout (\(entry.method))"), method: entry.method))
    }

    /// Error for a request that was handed to imsg and then timed out or lost its process: a
    /// send may already have been delivered (upstream treats `imsg rpc timeout (send)` as possibly
    /// delivered), so it must not be classified as safe to retry.
    static func pendingFailure(_ error: Error, method: String) -> Error {
        guard self.sendMethods.contains(method) else { return error }
        return ChannelSendError.unknownOutcome(underlying: ChannelErrorText.describe(error))
    }

    private func handle(_ event: IMsgRPCPipeEvent) {
        switch event {
        case .stdout(let line):
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            self.handleLine(trimmed)
        case .stderr(let line):
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            self.recordDiagnostic(trimmed)
        case .exited(let status):
            self.finish(self.closeError(status: status))
        }
    }

    private func handleLine(_ line: String) {
        guard let parsed = try? JSONDecoder().decode(AnyCodable.self, from: Data(line.utf8)), let object = parsed.dictionaryValue else {
            self.recordDiagnostic(line)
            return
        }
        if let rawID = object["id"], !rawID.isNull {
            let id = rawID.intValue ?? rawID.stringValue.flatMap { Int($0) }
            guard let id, let entry = self.pending.removeValue(forKey: id) else { return }
            entry.timeout?.cancel()
            if let error = object["error"]?.dictionaryValue {
                let base = error["message"]?.stringValue ?? "imsg rpc error"
                let code = error["code"]?.intValue
                var suffixes: [String] = []
                if let code {
                    suffixes.append("code=\(code)")
                }
                if let data = error["data"] {
                    let text = data.stringValue ?? A2AProtocol.compactJSON(data)
                    if !text.isEmpty {
                        suffixes.append(text)
                    }
                }
                let message = suffixes.isEmpty ? base : "\(base): \(suffixes.joined(separator: " "))"
                entry.continuation.resume(throwing: IMsgRPCError(code: code, message: message, data: error["data"]))
                return
            }
            entry.continuation.resume(returning: object["result"] ?? AnyCodable(AnySendableValue.null))
            return
        }
        if let method = object["method"]?.stringValue {
            self.notificationContinuation.yield(IMsgRPCNotification(method: method, params: object["params"]))
        }
    }

    private func recordDiagnostic(_ line: String) {
        guard self.publicProcessError == nil else { return }
        let lowered = line.lowercased()
        if lowered.contains("full disk access"), lowered.contains("chat.db") {
            self.publicProcessError = Self.fullDiskAccessError
        }
    }

    private func closeError(status: Int32?) -> Error {
        if let publicProcessError {
            return OpenClawCoreError.unavailable(publicProcessError)
        }
        if let status, status != 0 {
            return OpenClawCoreError.unavailable("imsg rpc exited (code \(status))")
        }
        return OpenClawCoreError.unavailable("imsg rpc closed")
    }

    private func failTransport(_ error: Error, unwrittenID: Int) async {
        // The request whose write failed never reached imsg, so it stays safe to retry.
        if let entry = self.pending.removeValue(forKey: unwrittenID) {
            entry.timeout?.cancel()
            entry.continuation.resume(throwing: OpenClawCoreError.unavailable("imsg rpc write failed: \(ChannelErrorText.describe(error))"))
        }
        guard self.terminal == nil else { return }
        self.finish(error)
        await self.pipe.close()
    }

    private func finish(_ error: Error) {
        guard self.terminal == nil else { return }
        self.terminal = error
        let entries = self.pending
        self.pending.removeAll()
        for entry in entries.values {
            entry.timeout?.cancel()
            entry.continuation.resume(throwing: Self.pendingFailure(error, method: entry.method))
        }
        self.notificationContinuation.finish()
    }
}

#if os(macOS) || os(Linux)

/// Spawns `imsg rpc --json [--db <path>]` and exchanges newline-delimited JSON over stdio
/// (macOS and Linux only).
///
/// `cliPath` defaults to `imsg`, resolved through `PATH` with `/usr/bin/env`; a path containing
/// `/` or starting with `~` is executed directly. On Linux point `cliPath` at an SSH wrapper that
/// runs `imsg` on the Messages Mac. The launching process needs Full Disk Access (to read
/// `~/Library/Messages/chat.db`) and Messages Automation; sandboxed App Store apps cannot spawn it.
public final class IMsgProcessPipe: IMsgRPCPipe, @unchecked Sendable {
    private let executableURL: URL
    private let arguments: [String]
    private let lock = NSLock()
    private var process: Process?
    private var stdinHandle: FileHandle?

    /// Creates a process pipe.
    /// - Parameters:
    ///   - cliPath: `imsg` executable or wrapper.
    ///   - dbPath: Messages database path (`--db`).
    public init(cliPath: String = "imsg", dbPath: String? = nil) {
        let configured = cliPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "imsg" : cliPath.trimmingCharacters(in: .whitespacesAndNewlines)
        var arguments = ["rpc", "--json"]
        if let dbPath = dbPath?.trimmingCharacters(in: .whitespacesAndNewlines), !dbPath.isEmpty {
            arguments += ["--db", NSString(string: dbPath).expandingTildeInPath]
        }
        if configured.contains("/") || configured.hasPrefix("~") {
            self.executableURL = URL(fileURLWithPath: NSString(string: configured).expandingTildeInPath)
            self.arguments = arguments
        } else {
            self.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            self.arguments = [configured] + arguments
        }
    }

    /// Launches the process.
    /// - Returns: Event stream.
    public func open() async throws -> AsyncStream<IMsgRPCPipeEvent> {
        let (stream, continuation) = AsyncStream<IMsgRPCPipeEvent>.makeStream()
        let process = Process()
        process.executableURL = self.executableURL
        process.arguments = self.arguments
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        #if os(Linux)
        // Writing to a pipe whose reader exited must fail with EPIPE instead of killing the host.
        signal(SIGPIPE, SIG_IGN)
        #else
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        #endif

        let group = DispatchGroup()
        let status = LockedBox<Int32?>(nil)
        let stdoutFramer = LineFramer { continuation.yield(.stdout($0)) }
        let stderrFramer = LineFramer { continuation.yield(.stderr($0)) }
        for (handle, framer) in [(output.fileHandleForReading, stdoutFramer), (errors.fileHandleForReading, stderrFramer)] {
            group.enter()
            handle.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    framer.flush()
                    group.leave()
                } else {
                    framer.append(data)
                }
            }
        }
        group.enter()
        process.terminationHandler = { process in
            status.set(process.terminationStatus)
            group.leave()
        }
        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            throw OpenClawCoreError.unavailable("imsg rpc could not start (\(self.executableURL.path)): \(error.localizedDescription)")
        }
        group.notify(queue: .global()) {
            continuation.yield(.exited(status: status.get()))
            continuation.finish()
        }
        self.locked {
            self.process = process
            self.stdinHandle = input.fileHandleForWriting
        }
        return stream
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        self.lock.lock()
        defer { self.lock.unlock() }
        return try body()
    }

    /// Writes one line to stdin.
    /// - Parameter line: JSON line.
    public func write(line: String) async throws {
        // Writes are serialized under the lock so concurrent requests never interleave lines.
        try self.locked {
            guard let handle = self.stdinHandle else {
                throw OpenClawCoreError.unavailable("imsg rpc not running")
            }
            try handle.write(contentsOf: Data((line + "\n").utf8))
        }
    }

    /// Closes stdin, then sends SIGTERM after 500 ms if the process is still running.
    public func close() async {
        let (process, handle) = self.locked { () -> (Process?, FileHandle?) in
            let current = (self.process, self.stdinHandle)
            self.stdinHandle = nil
            return current
        }
        try? handle?.close()
        guard let process else { return }
        for _ in 0..<10 where process.isRunning {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if process.isRunning {
            process.terminate()
        }
    }
}

/// Thread-safe value box.
private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func set(_ value: Value) {
        self.lock.lock()
        self.value = value
        self.lock.unlock()
    }

    func get() -> Value {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.value
    }
}

/// Splits a UTF-8 byte stream into LF-terminated lines.
private final class LineFramer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let onLine: @Sendable (String) -> Void

    init(onLine: @escaping @Sendable (String) -> Void) {
        self.onLine = onLine
    }

    func append(_ data: Data) {
        self.lock.lock()
        self.buffer.append(data)
        var lines: [String] = []
        while let newline = self.buffer.firstIndex(of: 0x0A) {
            lines.append(String(decoding: self.buffer[self.buffer.startIndex..<newline], as: UTF8.self))
            self.buffer.removeSubrange(self.buffer.startIndex...newline)
        }
        self.lock.unlock()
        lines.forEach(self.onLine)
    }

    func flush() {
        self.lock.lock()
        let rest = self.buffer
        self.buffer.removeAll()
        self.lock.unlock()
        if !rest.isEmpty {
            self.onLine(String(decoding: rest, as: UTF8.self))
        }
    }
}
#endif
