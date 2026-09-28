import Foundation
import OpenClawProtocol

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
        if let configured = provider, configured.source != ref.source {
            // Upstream `isBuiltInDefaultSecretProviderRef`: env/store refs on the source's default alias
            // use the built-in provider even when another source claims that alias.
            if (ref.source == .env || ref.source == .store), alias == config.defaults.providerAlias(for: ref.source) {
                provider = nil
            } else {
                throw OpenClawCoreError.invalidConfiguration(
                    "Secret provider \"\(alias)\" is a \(configured.source.rawValue) provider, not \(ref.source.rawValue)."
                )
            }
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
            timeoutMs: provider.timeoutMs,
            maxOutputBytes: provider.maxOutputBytes
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
/// Runs an exec secret provider with stdin input, a timeout and an output cap.
enum ExecSecretProcess {
    static func run(
        command: String,
        arguments: [String],
        environment: [String: String],
        input: Data,
        timeoutMs: Int,
        maxOutputBytes: Int
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try self.runBlocking(
                        command: command, arguments: arguments, environment: environment, input: input,
                        timeoutMs: timeoutMs, maxOutputBytes: maxOutputBytes
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func runBlocking(
        command: String,
        arguments: [String],
        environment: [String: String],
        input: Data,
        timeoutMs: Int,
        maxOutputBytes: Int
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
        try process.run()
        stdin.fileHandleForWriting.write(input)
        try? stdin.fileHandleForWriting.close()
        let timeout = DispatchWorkItem { [process] in
            if process.isRunning {
                process.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(max(1, timeoutMs)), execute: timeout)
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        guard process.terminationReason == .exit else {
            throw OpenClawCoreError.unavailable("Exec secret provider timed out or was terminated.")
        }
        guard process.terminationStatus == 0 else {
            throw OpenClawCoreError.unavailable("Exec secret provider exited with status \(process.terminationStatus).")
        }
        guard data.count <= maxOutputBytes else {
            throw OpenClawCoreError.unavailable("Exec secret provider output exceeded maxOutputBytes (\(maxOutputBytes)).")
        }
        return data
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
