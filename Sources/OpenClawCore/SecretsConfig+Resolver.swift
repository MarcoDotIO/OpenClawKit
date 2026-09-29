import Foundation
import OpenClawProtocol
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// Resolves a ``SecretRef`` to its secret value using a ``SecretsConfig``.
public protocol SecretRefResolver: Sendable {
    /// Resolves one reference.
    /// - Parameters:
    ///   - ref: Secret reference.
    ///   - config: Secrets config (providers and defaults).
    /// - Returns: The secret value.
    /// - Throws: ``OpenClawCoreError`` when the provider is missing, disallowed or fails.
    func resolve(_ ref: SecretRef, config: SecretsConfig) async throws -> String
}

extension SecretRefResolver {
    /// Resolves a ``SecretInput``: plaintext strings pass through, refs are resolved.
    /// - Parameters:
    ///   - input: Secret input.
    ///   - config: Secrets config.
    /// - Returns: The secret value.
    public func resolve(_ input: SecretInput, config: SecretsConfig) async throws -> String {
        switch input {
        case .string(let value):
            return value
        case .ref(let ref):
            return try await self.resolve(ref, config: config)
        }
    }
}

/// Default resolver for the `env`, `file`, `exec` and `store` sources (`src/secrets/resolve.ts`).
///
/// - `env`: reads the process environment, honoring an env provider's `allowlist`.
/// - `file`: reads the provider's file (`singleValue` returns the content for id `value` without its
///   trailing newline; `json` follows the ref id as a JSON pointer), honoring `maxBytes`. The file must
///   pass ``SecretPathSecurity/assertSecureSecretFile(_:label:)``: a regular file (no symlink) with one
///   hard link, `mode & 0o077 == 0`, owned by the current user.
/// - `exec`: macOS and Linux only; the command must pass
///   ``SecretPathSecurity/assertSecureExecCommand(_:label:trustedDirs:environment:)`` (absolute, not a
///   symlink, inside `trustedDirs`, not group/world-writable, owned by the current user). It runs with
///   the JSON request `{protocolVersion: 1, provider, ids}` on stdin and reads
///   `{protocolVersion: 1, values, errors}`. `pluginIntegration` providers need the gateway's plugin
///   runtime and are unavailable here.
/// - `store`: upstream's host secret store (the gateway's shared SQLite store). In-process SDK
///   gateways map it to the platform ``CredentialStore`` (Keychain on Apple platforms, a file on Linux),
///   keyed by the ref id.
public struct DefaultSecretRefResolver: SecretRefResolver {
    /// Environment used for `env` refs and exec `passEnv`.
    public var environment: [String: String]
    /// Credential store backing `store` refs.
    public var credentialStore: (any CredentialStore)?

    /// Creates a resolver.
    /// - Parameters:
    ///   - environment: Process environment.
    ///   - credentialStore: Store for `store` refs.
    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        credentialStore: (any CredentialStore)? = nil
    ) {
        self.environment = environment
        self.credentialStore = credentialStore
    }

    /// Resolves one reference.
    /// - Parameters:
    ///   - ref: Secret reference.
    ///   - config: Secrets config.
    /// - Returns: The secret value.
    public func resolve(_ ref: SecretRef, config: SecretsConfig) async throws -> String {
        if let message = ref.validationError(using: config.defaults) {
            throw OpenClawCoreError.invalidConfiguration(message)
        }
        let alias = config.effectiveProviderAlias(for: ref)
        var provider = config.providers[alias]
        // Upstream `isBuiltInDefaultSecretProviderRef`: only env/store refs on the source's default alias
        // may use the built-in provider.
        let isBuiltInDefault = (ref.source == .env || ref.source == .store) && alias == config.defaults.providerAlias(for: ref.source)
        if let configured = provider, configured.source != ref.source {
            // The built-in default wins even when another source claims that alias.
            if isBuiltInDefault {
                provider = nil
            } else {
                throw OpenClawCoreError.invalidConfiguration(
                    "Secret provider \"\(alias)\" is a \(configured.source.rawValue) provider, not \(ref.source.rawValue)."
                )
            }
        } else if provider == nil, !isBuiltInDefault {
            // Upstream SECRET_PROVIDER_NOT_CONFIGURED: an unknown alias never falls back to the
            // unrestricted built-in provider (which would skip a configured env allowlist).
            throw OpenClawCoreError.invalidConfiguration(
                "Secret provider \"\(alias)\" is not configured (ref: \(ref.source.rawValue):\(alias):\(ref.id))."
            )
        }
        switch ref.source {
        case .env:
            return try self.resolveEnv(ref, provider: provider)
        case .file:
            guard case .file(let file)? = provider else {
                throw OpenClawCoreError.invalidConfiguration("File secret provider \"\(alias)\" is not configured.")
            }
            return try Self.resolveFile(ref, providerName: alias, provider: file, environment: self.environment)
        case .exec:
            guard case .exec(let exec)? = provider else {
                throw OpenClawCoreError.invalidConfiguration("Exec secret provider \"\(alias)\" is not configured.")
            }
            return try await Self.resolveExec(ref, providerName: alias, provider: exec, environment: self.environment)
        case .store:
            guard let credentialStore = self.credentialStore else {
                throw OpenClawCoreError.unavailable("Store secret refs need a CredentialStore.")
            }
            guard let value = try await credentialStore.loadSecret(for: ref.id), !value.isEmpty else {
                throw OpenClawCoreError.unavailable("Secret store has no value for \"\(ref.id)\".")
            }
            return value
        }
    }

    private func resolveEnv(_ ref: SecretRef, provider: SecretProviderConfig?) throws -> String {
        if case .env(let env)? = provider, !env.allowlist.isEmpty, !env.allowlist.contains(ref.id) {
            throw OpenClawCoreError.invalidConfiguration("Environment variable \"\(ref.id)\" is not in the provider allowlist.")
        }
        guard let value = self.environment[ref.id], !value.isEmpty else {
            throw OpenClawCoreError.unavailable("Environment variable \"\(ref.id)\" is not set.")
        }
        return value
    }

    static func resolveFile(
        _ ref: SecretRef,
        providerName: String = "default",
        provider: FileSecretProviderConfig,
        environment: [String: String]
    ) throws -> String {
        let path = OpenClawConfigDocumentStore.expandHome(provider.path, environment: environment)
        let url = URL(fileURLWithPath: path)
        do {
            try SecretPathSecurity.assertSecureSecretFile(url.path, label: "secrets.providers.\(providerName).path")
        } catch let violation as SecretPathSecurity.Violation {
            throw OpenClawCoreError.unavailable(violation.errorDescription ?? "Secret file failed the security check.")
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        if let size = (attributes?[.size] as? NSNumber)?.intValue, size > provider.maxBytes {
            throw OpenClawCoreError.invalidConfiguration("Secret file \(url.path) exceeds maxBytes (\(provider.maxBytes)).")
        }
        let data = try Data(contentsOf: url)
        guard data.count <= provider.maxBytes else {
            throw OpenClawCoreError.invalidConfiguration("Secret file \(url.path) exceeds maxBytes (\(provider.maxBytes)).")
        }
        switch provider.mode {
        case .singleValue:
            guard ref.id == SINGLE_VALUE_FILE_SECRET_REF_ID else {
                throw OpenClawCoreError.invalidConfiguration("singleValue file providers only resolve the id \"value\".")
            }
            // Upstream: strip a UTF-8 BOM and exactly one trailing newline (`\n` or `\r\n`).
            var text = String(decoding: data, as: UTF8.self)
            if text.hasPrefix("\u{FEFF}") {
                text.removeFirst()
            }
            if text.hasSuffix("\r\n") {
                text.removeLast()
            } else if text.hasSuffix("\n") {
                text.removeLast()
            }
            return text
        case .json:
            let tree = try OpenClawJSON5.parse(data, allowJSON5: false)
            guard let value = Self.jsonPointer(ref.id, in: tree) else {
                throw OpenClawCoreError.unavailable("Secret file \(url.path) has no value at \(ref.id).")
            }
            return value
        }
    }

    /// RFC 6901 JSON pointer lookup returning string (or scalar) values.
    static func jsonPointer(_ pointer: String, in tree: AnyCodable) -> String? {
        if pointer == SINGLE_VALUE_FILE_SECRET_REF_ID {
            return tree.stringValue
        }
        guard pointer.hasPrefix("/") else { return nil }
        var current = tree
        for rawSegment in pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
            let segment = rawSegment.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            if let object = current.dictionaryValue, let next = object[segment] {
                current = next
            } else if let array = current.arrayValue, let index = Int(segment), array.indices.contains(index) {
                current = array[index]
            } else {
                return nil
            }
        }
        switch current.value {
        case .string(let string):
            return string
        case .int(let int):
            return String(int)
        case .double(let double):
            return OpenClawJSON5.formatNumber(double)
        case .bool(let flag):
            return flag ? "true" : "false"
        default:
            return nil
        }
    }

    static func resolveExec(
        _ ref: SecretRef,
        providerName: String,
        provider: ExecSecretProviderConfig,
        environment: [String: String]
    ) async throws -> String {
        if provider.pluginIntegration != nil {
            throw OpenClawCoreError.unavailable(
                "Exec secret provider \"\(providerName)\" uses a plugin integration, which needs the gateway plugin runtime."
            )
        }
        #if os(macOS) || os(Linux)
        let errors = provider.validationErrors()
        if let first = errors.first {
            throw OpenClawCoreError.invalidConfiguration(first)
        }
        // Same trust boundary upstream checks before execution; the retired `allowInsecurePath` and
        // `allowSymlinkCommand` opt-outs are ignored (fail closed).
        let commandPath: String
        do {
            commandPath = try SecretPathSecurity.assertSecureExecCommand(
                provider.command,
                label: "secrets.providers.\(providerName).command",
                trustedDirs: provider.trustedDirs,
                environment: environment
            )
        } catch let violation as SecretPathSecurity.Violation {
            throw OpenClawCoreError.invalidConfiguration(violation.errorDescription ?? "Exec secret provider command failed the security check.")
        }
        let request = try JSONSerialization.data(withJSONObject: [
            "protocolVersion": 1, "provider": providerName, "ids": [ref.id],
        ], options: [.sortedKeys])
        var childEnvironment: [String: String] = [:]
        for key in provider.passEnv {
            if let value = environment[key] {
                childEnvironment[key] = value
            }
        }
        for (key, value) in provider.env {
            childEnvironment[key] = value
        }
        let output = try await ExecSecretProcess.run(
            command: commandPath,
            arguments: provider.args,
            environment: childEnvironment,
            input: request,
            limits: ExecSecretProcess.Limits(
                providerName: providerName,
                timeoutMs: provider.timeoutMs,
                noOutputTimeoutMs: provider.noOutputTimeoutMs,
                maxOutputBytes: provider.maxOutputBytes
            )
        )
        return try Self.parseExecResponse(output, id: ref.id, providerName: providerName, jsonOnly: provider.jsonOnly)
        #else
        _ = ref
        _ = environment
        throw OpenClawCoreError.unavailable("Exec secret providers run only on macOS and Linux.")
        #endif
    }

    /// Parses an exec provider response (`src/secrets/resolve.ts` `parseExecValues`).
    static func parseExecResponse(_ stdout: Data, id: String, providerName: String, jsonOnly: Bool) throws -> String {
        let trimmed = String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw OpenClawCoreError.unavailable("Exec provider \"\(providerName)\" returned empty stdout.")
        }
        guard let parsed = try? OpenClawJSON5.parse(trimmed, allowJSON5: false) else {
            if !jsonOnly {
                return trimmed
            }
            throw OpenClawCoreError.unavailable("Exec provider \"\(providerName)\" returned invalid JSON.")
        }
        guard let object = parsed.dictionaryValue else {
            if !jsonOnly, let string = parsed.stringValue {
                return string
            }
            throw OpenClawCoreError.unavailable("Exec provider \"\(providerName)\" response must be an object.")
        }
        guard object["protocolVersion"]?.intValue == 1 else {
            throw OpenClawCoreError.unavailable("Exec provider \"\(providerName)\" protocolVersion must be 1.")
        }
        if object["errors"]?.dictionaryValue?[id] != nil {
            throw OpenClawCoreError.unavailable("Exec provider \"\(providerName)\" failed for id \"\(id)\".")
        }
        guard let values = object["values"]?.dictionaryValue else {
            throw OpenClawCoreError.unavailable("Exec provider \"\(providerName)\" response missing \"values\".")
        }
        guard let value = values[id]?.stringValue else {
            throw OpenClawCoreError.unavailable("Exec provider \"\(providerName)\" response missing id \"\(id)\".")
        }
        return value
    }
}

#if os(macOS) || os(Linux)
/// Runs an exec secret provider (upstream `runCommandWithTimeout` with `killProcessTree`,
/// `noOutputTimeoutMs`, head capture and `terminateOnOutputLimit`).
///
/// The child runs in its own process group (Foundation `Process` makes it the group leader). Stdout
/// is read incrementally: exceeding `maxOutputBytes`, the overall `timeoutMs` deadline or
/// `noOutputTimeoutMs` without output sends `SIGTERM` and then `SIGKILL` to the whole group, and the
/// call fails with a distinct error. After the direct child exits, stdout is drained only briefly,
/// so a backgrounded helper that inherited stdout cannot hold the call open. Writing the request
/// never raises `SIGPIPE`.
enum ExecSecretProcess {
    /// Limits and labels for one run.
    struct Limits: Sendable {
        var providerName: String
        var timeoutMs: Int
        var noOutputTimeoutMs: Int
        var maxOutputBytes: Int
        /// Grace between `SIGTERM` and `SIGKILL`.
        var killGraceMs: Int = 500
        /// How long stdout is drained after the direct child exits.
        var exitDrainMs: Int = 250
    }

    static func run(
        command: String,
        arguments: [String],
        environment: [String: String],
        input: Data,
        limits: Limits
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try self.runBlocking(
                        command: command, arguments: arguments, environment: environment, input: input, limits: limits
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private enum Termination {
        case timeout
        case noOutput
        case outputLimit
    }

    private final class ExitSignal: @unchecked Sendable {
        let semaphore = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var exited = false

        var hasExited: Bool {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.exited
        }

        func markExited() {
            self.lock.lock()
            self.exited = true
            self.lock.unlock()
            self.semaphore.signal()
        }

        /// Waits until the process exits or `deadline` passes.
        func wait(until deadline: UInt64) -> Bool {
            if self.hasExited { return true }
            let now = DispatchTime.now().uptimeNanoseconds
            guard deadline > now else { return false }
            _ = self.semaphore.wait(timeout: .now() + .nanoseconds(Int(min(deadline - now, UInt64(Int.max)))))
            return self.hasExited
        }
    }

    private static func runBlocking(
        command: String,
        arguments: [String],
        environment: [String: String],
        input: Data,
        limits: Limits
    ) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: command).deletingLastPathComponent()
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let exitSignal = ExitSignal()
        process.terminationHandler = { _ in exitSignal.markExited() }

        let start = DispatchTime.now().uptimeNanoseconds
        let deadline = start + UInt64(max(1, limits.timeoutMs)) * 1_000_000
        try process.run()
        try? stdout.fileHandleForWriting.close()
        let pid = process.processIdentifier
        // Foundation makes the child a process-group leader on Darwin and Linux; only signal the
        // group when that holds, never our own group.
        let groupID: pid_t? = (pid > 0 && getpgid(pid) == pid && pid != getpgrp()) ? pid : nil
        func signalTree(_ signal: Int32) {
            if let groupID {
                _ = kill(-groupID, signal)
            } else if pid > 0, !exitSignal.hasExited {
                _ = kill(pid, signal)
            }
        }

        Self.writeRequest(input, to: stdin.fileHandleForWriting.fileDescriptor, deadline: deadline)
        try? stdin.fileHandleForWriting.close()

        let readFD = stdout.fileHandleForReading.fileDescriptor
        let (output, termination) = Self.readOutput(from: readFD, limits: limits, deadline: deadline, exitSignal: exitSignal)
        try? stdout.fileHandleForReading.close()

        var failure = termination
        if failure == nil, !exitSignal.wait(until: deadline) {
            failure = .timeout
        }
        if let failure {
            signalTree(SIGTERM)
            let graceDeadline = DispatchTime.now().uptimeNanoseconds + UInt64(limits.killGraceMs) * 1_000_000
            _ = exitSignal.wait(until: graceDeadline)
            // Stragglers that ignored SIGTERM (or outlived the direct child) are killed too.
            signalTree(SIGKILL)
            _ = exitSignal.wait(until: DispatchTime.now().uptimeNanoseconds + 2_000_000_000)
            switch failure {
            case .timeout:
                throw OpenClawCoreError.unavailable("Exec provider \"\(limits.providerName)\" timed out after \(limits.timeoutMs)ms.")
            case .noOutput:
                throw OpenClawCoreError.unavailable(
                    "Exec provider \"\(limits.providerName)\" produced no output for \(limits.noOutputTimeoutMs)ms."
                )
            case .outputLimit:
                throw OpenClawCoreError.unavailable(
                    "Exec provider \"\(limits.providerName)\" output exceeded maxOutputBytes (\(limits.maxOutputBytes))."
                )
            }
        }
        guard process.terminationReason == .exit else {
            throw OpenClawCoreError.unavailable(
                "Exec provider \"\(limits.providerName)\" was terminated by signal \(process.terminationStatus)."
            )
        }
        guard process.terminationStatus == 0 else {
            throw OpenClawCoreError.unavailable(
                "Exec provider \"\(limits.providerName)\" exited with status \(process.terminationStatus)."
            )
        }
        return output
    }

    /// Reads stdout without blocking past the deadlines, keeping at most `maxOutputBytes`.
    private static func readOutput(
        from fd: Int32,
        limits: Limits,
        deadline: UInt64,
        exitSignal: ExitSignal
    ) -> (Data, Termination?) {
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }
        let noOutputNanos = UInt64(max(1, limits.noOutputTimeoutMs)) * 1_000_000
        var output = Data()
        var lastOutput = DispatchTime.now().uptimeNanoseconds
        var drainDeadline: UInt64?
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            if exitSignal.hasExited, drainDeadline == nil {
                drainDeadline = now + UInt64(limits.exitDrainMs) * 1_000_000
            }
            if let drainDeadline {
                if now >= drainDeadline {
                    // The direct child is gone; a helper that inherited stdout must not hold us open.
                    return (output, nil)
                }
            } else if now >= deadline {
                return (output, .timeout)
            } else if now - lastOutput >= noOutputNanos {
                return (output, .noOutput)
            }
            // While draining, the deadline and no-output timer may already lie in the past.
            let nextEvent = drainDeadline ?? min(deadline, lastOutput + noOutputNanos)
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Self.pollWaitMs(now: now, nextEvent: nextEvent))
            if ready < 0 {
                if errno == EINTR { continue }
                return (output, nil)
            }
            if ready == 0 {
                continue
            }
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                guard output.count + count <= limits.maxOutputBytes else {
                    return (output, .outputLimit)
                }
                output.append(contentsOf: buffer[0..<count])
                lastOutput = DispatchTime.now().uptimeNanoseconds
            } else if count == 0 {
                return (output, nil)
            } else if errno != EAGAIN, errno != EWOULDBLOCK, errno != EINTR {
                return (output, nil)
            }
        }
    }

    /// Milliseconds to wait for the next event: 1…50 (wake at least every 50 ms to notice the child's
    /// exit), and 1 when the event is already due (never underflows).
    static func pollWaitMs(now: UInt64, nextEvent: UInt64) -> Int32 {
        let remainingMs = nextEvent > now ? (nextEvent - now) / 1_000_000 : 0
        return Int32(min(50, max(1, remainingMs)))
    }

    /// Writes the request without raising `SIGPIPE` (the child may exit without reading) and without
    /// blocking past the deadline.
    private static func writeRequest(_ data: Data, to fd: Int32, deadline: UInt64) {
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }
        #if canImport(Darwin)
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        #else
        var pipeSignal = sigset_t()
        sigemptyset(&pipeSignal)
        sigaddset(&pipeSignal, SIGPIPE)
        var previousMask = sigset_t()
        pthread_sigmask(SIG_BLOCK, &pipeSignal, &previousMask)
        defer {
            // Consume a SIGPIPE raised by this thread's write before restoring the mask.
            var pending = sigset_t()
            if sigpending(&pending) == 0, sigismember(&pending, SIGPIPE) == 1 {
                var zero = timespec(tv_sec: 0, tv_nsec: 0)
                _ = sigtimedwait(&pipeSignal, nil, &zero)
            }
            pthread_sigmask(SIG_SETMASK, &previousMask, nil)
        }
        #endif
        data.withUnsafeBytes { raw in
            guard var cursor = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let written = write(fd, cursor, remaining)
                if written > 0 {
                    cursor += written
                    remaining -= written
                    continue
                }
                if written < 0, errno == EINTR {
                    continue
                }
                guard written < 0, errno == EAGAIN || errno == EWOULDBLOCK else {
                    return // EPIPE: the child stopped reading.
                }
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline else { return }
                var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                _ = poll(&descriptor, 1, Int32(min(50, max(1, (deadline - now) / 1_000_000))))
            }
        }
    }
}
#endif

extension ChannelSecretResolver {
    /// A channel secret resolver backed by a ``SecretRefResolver``: plaintext strings pass through and
    /// `env`, `file`, `exec` and `store` refs resolve with the resolver's provider hardening.
    /// - Parameters:
    ///   - resolver: SecretRef resolver (defaults to ``DefaultSecretRefResolver``).
    ///   - secrets: Secrets config with the providers and defaults.
    /// - Returns: A channel secret resolver.
    public static func usingSecretRefResolver(
        _ resolver: any SecretRefResolver = DefaultSecretRefResolver(),
        secrets: SecretsConfig
    ) -> ChannelSecretResolver {
        ChannelSecretResolver { input in
            try await resolver.resolve(input, config: secrets)
        }
    }
}
