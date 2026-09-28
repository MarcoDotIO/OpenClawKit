import Foundation
import OpenClawProtocol

/// Resolves channel secrets (plaintext strings, env templates and SecretRef objects) to values.
///
/// Channel configs keep secrets as ``SecretInput`` so upstream SecretRef objects decode. Resolve
/// them with ``ChannelsConfig/resolvingSecrets(using:)`` before constructing adapters; the
/// resolver is injectable so hosts can plug in Keychain-backed or exec-backed providers.
public struct ChannelSecretResolver: Sendable {
    /// Resolution closure.
    public typealias Resolve = @Sendable (SecretInput) async throws -> String

    private let resolveInput: Resolve

    /// Creates a resolver from a closure.
    /// - Parameter resolve: Resolves one secret input or throws.
    public init(_ resolve: @escaping Resolve) {
        self.resolveInput = resolve
    }

    /// Resolves one secret input.
    /// - Parameter input: Secret input.
    /// - Returns: The secret value.
    /// - Throws: ``OpenClawCoreError/unavailable(_:)`` when the secret cannot be resolved.
    public func resolve(_ input: SecretInput) async throws -> String {
        try await self.resolveInput(input)
    }

    /// Default resolver: plaintext strings, `env` refs (process environment, honoring provider
    /// allowlists) and `file` refs (through `secrets.providers`). Other sources throw.
    /// - Parameters:
    ///   - secrets: Secrets config used to look up file providers and env allowlists.
    ///   - environment: Environment used for `env` refs.
    /// - Returns: A resolver.
    public static func standard(
        secrets: SecretsConfig = SecretsConfig(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ChannelSecretResolver {
        ChannelSecretResolver { input in
            switch input {
            case .string(let value):
                return value
            case .ref(let ref):
                return try ChannelSecretResolution.resolve(ref, secrets: secrets, environment: environment)
            }
        }
    }
}

enum ChannelSecretResolution {
    static func resolve(_ ref: SecretRef, secrets: SecretsConfig, environment: [String: String]) throws -> String {
        let normalized = ref.normalized(using: secrets.defaults)
        let provider = secrets.providers[normalized.provider]
        switch normalized.source {
        case .env:
            if case .env(let config) = provider, !config.allowlist.isEmpty, !config.allowlist.contains(normalized.id) {
                throw OpenClawCoreError.unavailable("Environment secret \(normalized.id) is not in provider \(normalized.provider)'s allowlist")
            }
            guard let value = environment[normalized.id], !value.isEmpty else {
                throw OpenClawCoreError.unavailable("Environment secret \(normalized.id) is not set")
            }
            return value
        case .file:
            guard case .file(let config) = provider else {
                throw OpenClawCoreError.unavailable("No file secret provider named \(normalized.provider)")
            }
            return try self.readFileSecret(config: config, id: normalized.id)
        case .exec, .store:
            throw OpenClawCoreError.unavailable(
                "Secret source \(normalized.source.rawValue) needs a host-provided ChannelSecretResolver"
            )
        }
    }

    static func readFileSecret(config: FileSecretProviderConfig, id: String) throws -> String {
        let path = (config.path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        guard data.count <= config.maxBytes else {
            throw OpenClawCoreError.unavailable("Secret file \(path) exceeds \(config.maxBytes) bytes")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw OpenClawCoreError.unavailable("Secret file \(path) is not UTF-8")
        }
        if config.mode == .singleValue || id == SINGLE_VALUE_FILE_SECRET_REF_ID {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let root = try? JSONDecoder().decode(AnyCodable.self, from: data) else {
            throw OpenClawCoreError.unavailable("Secret file \(path) is not JSON")
        }
        var current = root
        for rawSegment in id.split(separator: "/", omittingEmptySubsequences: true) {
            let segment = rawSegment.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            if let object = current.dictionaryValue, let next = object[segment] {
                current = next
            } else if let array = current.arrayValue, let index = Int(segment), array.indices.contains(index) {
                current = array[index]
            } else {
                throw OpenClawCoreError.unavailable("Secret \(id) not found in \(path)")
            }
        }
        guard let value = current.stringValue else {
            throw OpenClawCoreError.unavailable("Secret \(id) in \(path) is not a string")
        }
        return value
    }

    /// Reads a token file (upstream `tokenFile`; symlinks are rejected).
    static func readTokenFile(_ path: String) throws -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let attributes = try FileManager.default.attributesOfItem(atPath: expanded)
        if (attributes[.type] as? FileAttributeType) == .typeSymbolicLink {
            throw OpenClawCoreError.invalidConfiguration("tokenFile \(path) must be a regular file, not a symlink")
        }
        let text = try String(contentsOfFile: expanded, encoding: .utf8)
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw OpenClawCoreError.invalidConfiguration("tokenFile \(path) is empty")
        }
        return token
    }
}

public extension ChannelsConfig {
    /// Returns a copy with every channel SecretRef/env-template secret replaced by its value.
    ///
    /// Telegram `tokenFile` is read when no bot token is set. Plaintext values are kept as-is.
    /// - Parameter resolver: Secret resolver (defaults to ``ChannelSecretResolver/standard(secrets:environment:)``).
    /// - Returns: The resolved config.
    /// - Throws: The first resolution error, annotated with the upstream config path.
    func resolvingSecrets(using resolver: ChannelSecretResolver = .standard()) async throws -> ChannelsConfig {
        var copy = self
        func resolved(_ input: SecretInput?, path: String) async throws -> SecretInput? {
            guard let input else { return nil }
            guard case .ref = input else { return input }
            do {
                return .string(try await resolver.resolve(input))
            } catch {
                throw OpenClawCoreError.unavailable("\(path): \(error.localizedDescription)")
            }
        }
        copy.discord.botTokenInput = try await resolved(copy.discord.botTokenInput, path: "channels.discord.token")
        copy.telegram.botTokenInput = try await resolved(copy.telegram.botTokenInput, path: "channels.telegram.botToken")
        if copy.telegram.botTokenInput == nil, let tokenFile = copy.telegram.tokenFile {
            copy.telegram.botTokenInput = .string(try ChannelSecretResolution.readTokenFile(tokenFile))
        }
        copy.telegram.webhookSecretInput = try await resolved(copy.telegram.webhookSecretInput, path: "channels.telegram.webhookSecret")
        copy.whatsappCloud.accessTokenInput = try await resolved(
            copy.whatsappCloud.accessTokenInput,
            path: "channels.whatsappCloud.accessToken"
        )
        copy.whatsappCloud.webhookVerifyTokenInput = try await resolved(
            copy.whatsappCloud.webhookVerifyTokenInput,
            path: "channels.whatsappCloud.webhookVerifyToken"
        )
        copy.slack.botTokenInput = try await resolved(copy.slack.botTokenInput, path: "channels.slack.botToken")
        copy.slack.appTokenInput = try await resolved(copy.slack.appTokenInput, path: "channels.slack.appToken")
        copy.slack.signingSecretInput = try await resolved(copy.slack.signingSecretInput, path: "channels.slack.signingSecret")
        copy.slack.userTokenInput = try await resolved(copy.slack.userTokenInput, path: "channels.slack.userToken")
        if var relay = copy.slack.relay {
            relay.authTokenInput = try await resolved(relay.authTokenInput, path: "channels.slack.relay.authToken")
            copy.slack.relay = relay
        }
        copy.googleChat.bearerTokenInput = try await resolved(copy.googleChat.bearerTokenInput, path: "channels.googlechat.bearerToken")
        copy.googleChat.verificationTokenInput = try await resolved(
            copy.googleChat.verificationTokenInput,
            path: "channels.googlechat.verificationToken"
        )
        if let secret = copy.googleChat.serviceAccountSecret, case .ref = secret {
            let value = try await resolved(secret, path: "channels.googlechat.serviceAccount")
            copy.googleChat.serviceAccount = value?.stringValue.map { AnyCodable($0) }
        }
        copy.signal.authTokenInput = try await resolved(copy.signal.authTokenInput, path: "channels.signal.authToken")
        copy.bluebubbles.passwordInput = try await resolved(copy.bluebubbles.passwordInput, path: "channels.bluebubbles.password")
        copy.msteams.botAppPasswordInput = try await resolved(copy.msteams.botAppPasswordInput, path: "channels.msteams.appPassword")
        copy.webchat.sharedSecretInput = try await resolved(copy.webchat.sharedSecretInput, path: "channels.webchat.sharedSecret")
        return copy
    }
}
