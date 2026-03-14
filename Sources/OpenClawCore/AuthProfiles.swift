import Foundation

/// Credential mode declared by config for one auth profile.
public enum AuthProfileMode: String, Codable, Sendable, Equatable, CaseIterable {
    case apiKey = "api_key"
    case oauth
    case token
}

/// Config-declared auth profile metadata aligned with the TS SDK.
public struct AuthProfileConfig: Codable, Sendable, Equatable {
    public var provider: String
    public var mode: AuthProfileMode
    public var email: String?

    public init(provider: String, mode: AuthProfileMode, email: String? = nil) {
        self.provider = provider
        self.mode = mode
        self.email = email
    }
}

/// Cooldown settings used when rotating auth profiles after failures.
public struct AuthCooldownConfig: Codable, Sendable, Equatable {
    public var billingBackoffHours: Int
    public var billingBackoffHoursByProvider: [String: Int]
    public var billingMaxHours: Int
    public var failureWindowHours: Int

    public init(
        billingBackoffHours: Int = 5,
        billingBackoffHoursByProvider: [String: Int] = [:],
        billingMaxHours: Int = 24,
        failureWindowHours: Int = 24
    ) {
        self.billingBackoffHours = max(1, billingBackoffHours)
        self.billingBackoffHoursByProvider = billingBackoffHoursByProvider
        self.billingMaxHours = max(1, billingMaxHours)
        self.failureWindowHours = max(1, failureWindowHours)
    }

    private enum CodingKeys: String, CodingKey {
        case billingBackoffHours
        case billingBackoffHoursByProvider
        case billingMaxHours
        case failureWindowHours
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.billingBackoffHours = max(1, try container.decodeIfPresent(Int.self, forKey: .billingBackoffHours) ?? 5)
        self.billingBackoffHoursByProvider = try container.decodeIfPresent([String: Int].self, forKey: .billingBackoffHoursByProvider) ?? [:]
        self.billingMaxHours = max(1, try container.decodeIfPresent(Int.self, forKey: .billingMaxHours) ?? 24)
        self.failureWindowHours = max(1, try container.decodeIfPresent(Int.self, forKey: .failureWindowHours) ?? 24)
    }
}

/// Canonical auth config aligned with the TS SDK.
public struct AuthConfig: Codable, Sendable, Equatable {
    public var profiles: [String: AuthProfileConfig]
    public var order: [String: [String]]
    public var cooldowns: AuthCooldownConfig

    public init(
        profiles: [String: AuthProfileConfig] = [:],
        order: [String: [String]] = [:],
        cooldowns: AuthCooldownConfig = AuthCooldownConfig()
    ) {
        self.profiles = profiles
        self.order = order
        self.cooldowns = cooldowns
    }

    private enum CodingKeys: String, CodingKey {
        case profiles
        case order
        case cooldowns
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.profiles = try container.decodeIfPresent([String: AuthProfileConfig].self, forKey: .profiles) ?? [:]
        self.order = try container.decodeIfPresent([String: [String]].self, forKey: .order) ?? [:]
        self.cooldowns = try container.decodeIfPresent(AuthCooldownConfig.self, forKey: .cooldowns) ?? AuthCooldownConfig()
    }
}

/// Failure reasons tracked for auth-profile cooldowns.
public enum AuthProfileFailureReason: String, Codable, Sendable, Equatable, CaseIterable {
    case auth
    case authPermanent = "auth_permanent"
    case format
    case overloaded
    case rateLimit = "rate_limit"
    case billing
    case timeout
    case modelNotFound = "model_not_found"
    case sessionExpired = "session_expired"
    case unknown
}

/// Per-profile usage statistics used for rotation and cooldowns.
public struct AuthProfileUsageStats: Codable, Sendable, Equatable {
    public var lastUsed: Int?
    public var cooldownUntil: Int?
    public var disabledUntil: Int?
    public var disabledReason: AuthProfileFailureReason?
    public var errorCount: Int
    public var failureCounts: [AuthProfileFailureReason: Int]
    public var lastFailureAt: Int?

    public init(
        lastUsed: Int? = nil,
        cooldownUntil: Int? = nil,
        disabledUntil: Int? = nil,
        disabledReason: AuthProfileFailureReason? = nil,
        errorCount: Int = 0,
        failureCounts: [AuthProfileFailureReason: Int] = [:],
        lastFailureAt: Int? = nil
    ) {
        self.lastUsed = lastUsed
        self.cooldownUntil = cooldownUntil
        self.disabledUntil = disabledUntil
        self.disabledReason = disabledReason
        self.errorCount = max(0, errorCount)
        self.failureCounts = failureCounts
        self.lastFailureAt = lastFailureAt
    }

    private enum CodingKeys: String, CodingKey {
        case lastUsed
        case cooldownUntil
        case disabledUntil
        case disabledReason
        case errorCount
        case failureCounts
        case lastFailureAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.lastUsed = try container.decodeIfPresent(Int.self, forKey: .lastUsed)
        self.cooldownUntil = try container.decodeIfPresent(Int.self, forKey: .cooldownUntil)
        self.disabledUntil = try container.decodeIfPresent(Int.self, forKey: .disabledUntil)
        self.disabledReason = try container.decodeIfPresent(AuthProfileFailureReason.self, forKey: .disabledReason)
        self.errorCount = max(0, try container.decodeIfPresent(Int.self, forKey: .errorCount) ?? 0)
        self.failureCounts = try container.decodeIfPresent([AuthProfileFailureReason: Int].self, forKey: .failureCounts) ?? [:]
        self.lastFailureAt = try container.decodeIfPresent(Int.self, forKey: .lastFailureAt)
    }
}

/// API-key credential stored in the auth profile store.
public struct APIKeyAuthProfileCredential: Sendable, Equatable {
    public var provider: String
    public var key: String?
    public var keyRef: SecretRef?
    public var email: String?
    public var metadata: [String: String]

    public init(
        provider: String,
        key: String? = nil,
        keyRef: SecretRef? = nil,
        email: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.provider = provider
        self.key = key
        self.keyRef = keyRef
        self.email = email
        self.metadata = metadata
    }
}

/// Static bearer token credential stored in the auth profile store.
public struct TokenAuthProfileCredential: Sendable, Equatable {
    public var provider: String
    public var token: String?
    public var tokenRef: SecretRef?
    public var expires: Int?
    public var email: String?

    public init(
        provider: String,
        token: String? = nil,
        tokenRef: SecretRef? = nil,
        expires: Int? = nil,
        email: String? = nil
    ) {
        self.provider = provider
        self.token = token
        self.tokenRef = tokenRef
        self.expires = expires
        self.email = email
    }
}

/// OAuth credential stored in the auth profile store.
public struct OAuthAuthProfileCredential: Sendable, Equatable {
    public var provider: String
    public var accessToken: String?
    public var refreshToken: String?
    public var expires: Int?
    public var clientID: String?
    public var email: String?
    public var metadata: [String: String]

    public init(
        provider: String,
        accessToken: String? = nil,
        refreshToken: String? = nil,
        expires: Int? = nil,
        clientID: String? = nil,
        email: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.provider = provider
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expires = expires
        self.clientID = clientID
        self.email = email
        self.metadata = metadata
    }
}

/// Runtime auth credential union aligned with the TS auth store.
public enum AuthProfileCredential: Sendable, Equatable {
    case apiKey(APIKeyAuthProfileCredential)
    case token(TokenAuthProfileCredential)
    case oauth(OAuthAuthProfileCredential)

    public var provider: String {
        switch self {
        case .apiKey(let credential):
            return credential.provider
        case .token(let credential):
            return credential.provider
        case .oauth(let credential):
            return credential.provider
        }
    }

    public var mode: AuthProfileMode {
        switch self {
        case .apiKey:
            return .apiKey
        case .token:
            return .token
        case .oauth:
            return .oauth
        }
    }

    public var expires: Int? {
        switch self {
        case .apiKey:
            return nil
        case .token(let credential):
            return credential.expires
        case .oauth(let credential):
            return credential.expires
        }
    }
}

/// Snapshot returned from the auth profile store without loading secrets.
public struct AuthProfileStoreSnapshot: Sendable, Equatable {
    public struct ProfileMetadata: Sendable, Equatable {
        public var provider: String
        public var mode: AuthProfileMode
        public var email: String?
        public var expires: Int?
        public var clientID: String?
        public var metadata: [String: String]
        public var keyRef: SecretRef?
        public var tokenRef: SecretRef?

        public init(
            provider: String,
            mode: AuthProfileMode,
            email: String? = nil,
            expires: Int? = nil,
            clientID: String? = nil,
            metadata: [String: String] = [:],
            keyRef: SecretRef? = nil,
            tokenRef: SecretRef? = nil
        ) {
            self.provider = provider
            self.mode = mode
            self.email = email
            self.expires = expires
            self.clientID = clientID
            self.metadata = metadata
            self.keyRef = keyRef
            self.tokenRef = tokenRef
        }
    }

    public var version: Int
    public var profiles: [String: ProfileMetadata]
    public var order: [String: [String]]
    public var lastGood: [String: String]
    public var usageStats: [String: AuthProfileUsageStats]

    public init(
        version: Int = 1,
        profiles: [String: ProfileMetadata] = [:],
        order: [String: [String]] = [:],
        lastGood: [String: String] = [:],
        usageStats: [String: AuthProfileUsageStats] = [:]
    ) {
        self.version = version
        self.profiles = profiles
        self.order = order
        self.lastGood = lastGood
        self.usageStats = usageStats
    }
}

private struct PersistedAuthProfileRecord: Codable, Sendable {
    var provider: String
    var mode: AuthProfileMode
    var email: String?
    var expires: Int?
    var clientID: String?
    var metadata: [String: String]
    var keyRef: SecretRef?
    var tokenRef: SecretRef?
    var legacyAPIKey: String?
    var legacyToken: String?
    var legacyAccessToken: String?
    var legacyRefreshToken: String?

    init(
        provider: String,
        mode: AuthProfileMode,
        email: String? = nil,
        expires: Int? = nil,
        clientID: String? = nil,
        metadata: [String: String] = [:],
        keyRef: SecretRef? = nil,
        tokenRef: SecretRef? = nil,
        legacyAPIKey: String? = nil,
        legacyToken: String? = nil,
        legacyAccessToken: String? = nil,
        legacyRefreshToken: String? = nil
    ) {
        self.provider = provider
        self.mode = mode
        self.email = email
        self.expires = expires
        self.clientID = clientID
        self.metadata = metadata
        self.keyRef = keyRef
        self.tokenRef = tokenRef
        self.legacyAPIKey = legacyAPIKey
        self.legacyToken = legacyToken
        self.legacyAccessToken = legacyAccessToken
        self.legacyRefreshToken = legacyRefreshToken
    }

    private enum CodingKeys: String, CodingKey {
        case provider
        case mode
        case email
        case expires
        case clientID
        case metadata
        case keyRef
        case tokenRef
        case key
        case token
        case accessToken
        case refreshToken
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.provider = try container.decode(String.self, forKey: .provider)
        self.mode = try container.decode(AuthProfileMode.self, forKey: .mode)
        self.email = try container.decodeIfPresent(String.self, forKey: .email)
        self.expires = try container.decodeIfPresent(Int.self, forKey: .expires)
        self.clientID = try container.decodeIfPresent(String.self, forKey: .clientID)
        self.metadata = try container.decodeIfPresent([String: String].self, forKey: .metadata) ?? [:]
        self.keyRef = try container.decodeIfPresent(SecretRef.self, forKey: .keyRef)
        self.tokenRef = try container.decodeIfPresent(SecretRef.self, forKey: .tokenRef)
        self.legacyAPIKey = try container.decodeIfPresent(String.self, forKey: .key)
        self.legacyToken = try container.decodeIfPresent(String.self, forKey: .token)
        self.legacyAccessToken = try container.decodeIfPresent(String.self, forKey: .accessToken)
        self.legacyRefreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.provider, forKey: .provider)
        try container.encode(self.mode, forKey: .mode)
        try container.encodeIfPresent(self.email, forKey: .email)
        try container.encodeIfPresent(self.expires, forKey: .expires)
        try container.encodeIfPresent(self.clientID, forKey: .clientID)
        try container.encode(self.metadata, forKey: .metadata)
        try container.encodeIfPresent(self.keyRef, forKey: .keyRef)
        try container.encodeIfPresent(self.tokenRef, forKey: .tokenRef)
    }
}

private struct PersistedAuthProfileStoreState: Codable, Sendable {
    var version: Int
    var profiles: [String: PersistedAuthProfileRecord]
    var order: [String: [String]]
    var lastGood: [String: String]
    var usageStats: [String: AuthProfileUsageStats]
}

/// File-backed auth profile store that persists secrets through `CredentialStore`.
public actor AuthProfileStore {
    private let fileURL: URL
    private let credentialStore: any CredentialStore
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var state: PersistedAuthProfileStoreState

    /// Creates a file-backed auth profile store.
    public init(
        fileURL: URL,
        credentialStore: any CredentialStore
    ) {
        self.fileURL = fileURL
        self.credentialStore = credentialStore
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.decoder = JSONDecoder()
        self.state = PersistedAuthProfileStoreState(
            version: 1,
            profiles: [:],
            order: [:],
            lastGood: [:],
            usageStats: [:]
        )
    }

    /// Loads persisted profile metadata from disk when present.
    public func load() throws {
        guard OpenClawFileSystem.fileExists(self.fileURL) else {
            self.state = PersistedAuthProfileStoreState(version: 1, profiles: [:], order: [:], lastGood: [:], usageStats: [:])
            return
        }
        let data = try OpenClawFileSystem.readData(self.fileURL)
        self.state = try self.decoder.decode(PersistedAuthProfileStoreState.self, from: data)
    }

    /// Persists current profile metadata to disk.
    public func save() throws {
        try OpenClawFileSystem.ensureDirectory(self.fileURL.deletingLastPathComponent())
        let data = try self.encoder.encode(self.state)
        try OpenClawFileSystem.writeData(data, to: self.fileURL)
    }

    /// Returns a metadata snapshot without loading any credential secret values.
    public func snapshot() -> AuthProfileStoreSnapshot {
        AuthProfileStoreSnapshot(
            version: self.state.version,
            profiles: self.state.profiles.mapValues { record in
                AuthProfileStoreSnapshot.ProfileMetadata(
                    provider: record.provider,
                    mode: record.mode,
                    email: record.email,
                    expires: record.expires,
                    clientID: record.clientID,
                    metadata: record.metadata,
                    keyRef: record.keyRef,
                    tokenRef: record.tokenRef
                )
            },
            order: self.state.order,
            lastGood: self.state.lastGood,
            usageStats: self.state.usageStats
        )
    }

    /// Returns profile IDs stored for one provider.
    public func listProfiles(for provider: String) -> [String] {
        let normalizedProvider = Self.normalizeProviderID(provider)
        return self.state.profiles.compactMap { profileID, record in
            Self.normalizeProviderID(record.provider) == normalizedProvider ? profileID : nil
        }.sorted()
    }

    /// Stores or replaces one profile credential.
    public func setCredential(_ credential: AuthProfileCredential, for profileID: String) async throws {
        let normalizedProfileID = try Self.normalizeProfileID(profileID)
        try await self.persistCredentialSecrets(credential, for: normalizedProfileID)
        let record = PersistedAuthProfileRecord(
            provider: credential.provider,
            mode: credential.mode,
            email: Self.credentialEmail(credential),
            expires: credential.expires,
            clientID: Self.credentialClientID(credential),
            metadata: Self.credentialMetadata(credential),
            keyRef: Self.credentialKeyRef(credential),
            tokenRef: Self.credentialTokenRef(credential)
        )
        self.state.profiles[normalizedProfileID] = record
        try self.save()
    }

    /// Removes one profile and all stored secret values.
    public func removeProfile(_ profileID: String) async throws {
        let normalizedProfileID = try Self.normalizeProfileID(profileID)
        self.state.profiles.removeValue(forKey: normalizedProfileID)
        self.state.usageStats.removeValue(forKey: normalizedProfileID)
        for provider in self.state.order.keys {
            self.state.order[provider] = self.state.order[provider]?.filter { $0 != normalizedProfileID }
        }
        self.state.lastGood = self.state.lastGood.filter { $0.value != normalizedProfileID }
        for suffix in ["apiKey", "token", "accessToken", "refreshToken"] {
            try? await self.credentialStore.deleteSecret(for: Self.secretStoreKey(profileID: normalizedProfileID, field: suffix))
        }
        try self.save()
    }

    /// Loads one resolved credential by combining metadata with secure-store values.
    public func resolvedCredential(for profileID: String) async throws -> AuthProfileCredential? {
        let normalizedProfileID = try Self.normalizeProfileID(profileID)
        guard let existingRecord = self.state.profiles[normalizedProfileID] else {
            return nil
        }
        let record = try await self.bridgeLegacySecretsIfNeeded(
            profileID: normalizedProfileID,
            record: existingRecord
        )
        switch record.mode {
        case .apiKey:
            return .apiKey(
                APIKeyAuthProfileCredential(
                    provider: record.provider,
                    key: try await self.credentialStore.loadSecret(for: Self.secretStoreKey(profileID: normalizedProfileID, field: "apiKey")),
                    keyRef: record.keyRef,
                    email: record.email,
                    metadata: record.metadata
                )
            )
        case .token:
            return .token(
                TokenAuthProfileCredential(
                    provider: record.provider,
                    token: try await self.credentialStore.loadSecret(for: Self.secretStoreKey(profileID: normalizedProfileID, field: "token")),
                    tokenRef: record.tokenRef,
                    expires: record.expires,
                    email: record.email
                )
            )
        case .oauth:
            return .oauth(
                OAuthAuthProfileCredential(
                    provider: record.provider,
                    accessToken: try await self.credentialStore.loadSecret(for: Self.secretStoreKey(profileID: normalizedProfileID, field: "accessToken")),
                    refreshToken: try await self.credentialStore.loadSecret(for: Self.secretStoreKey(profileID: normalizedProfileID, field: "refreshToken")),
                    expires: record.expires,
                    clientID: record.clientID,
                    email: record.email,
                    metadata: record.metadata
                )
            )
        }
    }

    /// Updates persisted order overrides.
    public func setOrder(_ order: [String: [String]]) throws {
        self.state.order = order
        try self.save()
    }

    /// Records successful usage for one profile.
    public func recordSuccess(profileID: String, provider: String) throws {
        let normalizedProfileID = try Self.normalizeProfileID(profileID)
        let normalizedProvider = Self.normalizeProviderID(provider)
        let now = Self.currentTimestampMs()
        var stats = self.state.usageStats[normalizedProfileID] ?? AuthProfileUsageStats()
        stats.lastUsed = now
        stats.cooldownUntil = nil
        stats.disabledUntil = nil
        stats.disabledReason = nil
        stats.errorCount = 0
        stats.lastFailureAt = nil
        self.state.usageStats[normalizedProfileID] = stats
        self.state.lastGood[normalizedProvider] = normalizedProfileID
        try self.save()
    }

    /// Records a transient or permanent failure for one profile.
    public func recordFailure(
        profileID: String,
        provider: String,
        reason: AuthProfileFailureReason,
        cooldowns: AuthCooldownConfig = AuthCooldownConfig()
    ) throws {
        let normalizedProfileID = try Self.normalizeProfileID(profileID)
        let normalizedProvider = Self.normalizeProviderID(provider)
        let now = Self.currentTimestampMs()
        var stats = self.state.usageStats[normalizedProfileID] ?? AuthProfileUsageStats()
        if let lastFailureAt = stats.lastFailureAt,
           now - lastFailureAt > cooldowns.failureWindowHours * 3_600_000
        {
            stats.errorCount = 0
            stats.failureCounts = [:]
        }
        stats.errorCount += 1
        stats.failureCounts[reason, default: 0] += 1
        stats.lastFailureAt = now
        if reason == .authPermanent {
            stats.disabledReason = reason
            stats.disabledUntil = now + cooldowns.billingMaxHours * 3_600_000
        } else {
            let providerHours = cooldowns.billingBackoffHoursByProvider[normalizedProvider] ?? cooldowns.billingBackoffHours
            let cappedHours = min(cooldowns.billingMaxHours, max(1, providerHours) * max(1, stats.errorCount))
            stats.cooldownUntil = now + cappedHours * 3_600_000
        }
        self.state.usageStats[normalizedProfileID] = stats
        try self.save()
    }

    private func persistCredentialSecrets(_ credential: AuthProfileCredential, for profileID: String) async throws {
        switch credential {
        case .apiKey(let value):
            try await self.writeSecret(value.key, for: Self.secretStoreKey(profileID: profileID, field: "apiKey"))
            try? await self.credentialStore.deleteSecret(for: Self.secretStoreKey(profileID: profileID, field: "token"))
            try? await self.credentialStore.deleteSecret(for: Self.secretStoreKey(profileID: profileID, field: "accessToken"))
            try? await self.credentialStore.deleteSecret(for: Self.secretStoreKey(profileID: profileID, field: "refreshToken"))
        case .token(let value):
            try await self.writeSecret(value.token, for: Self.secretStoreKey(profileID: profileID, field: "token"))
            try? await self.credentialStore.deleteSecret(for: Self.secretStoreKey(profileID: profileID, field: "apiKey"))
            try? await self.credentialStore.deleteSecret(for: Self.secretStoreKey(profileID: profileID, field: "accessToken"))
            try? await self.credentialStore.deleteSecret(for: Self.secretStoreKey(profileID: profileID, field: "refreshToken"))
        case .oauth(let value):
            try await self.writeSecret(value.accessToken, for: Self.secretStoreKey(profileID: profileID, field: "accessToken"))
            try await self.writeSecret(value.refreshToken, for: Self.secretStoreKey(profileID: profileID, field: "refreshToken"))
            try? await self.credentialStore.deleteSecret(for: Self.secretStoreKey(profileID: profileID, field: "apiKey"))
            try? await self.credentialStore.deleteSecret(for: Self.secretStoreKey(profileID: profileID, field: "token"))
        }
    }

    private func bridgeLegacySecretsIfNeeded(
        profileID: String,
        record: PersistedAuthProfileRecord
    ) async throws -> PersistedAuthProfileRecord {
        var updated = record
        var mutated = false

        if let migrated = try await self.bridgeLegacySecret(
            currentValue: updated.legacyAPIKey,
            secureStoreKey: Self.secretStoreKey(profileID: profileID, field: "apiKey")
        ) {
            updated.legacyAPIKey = migrated
            mutated = true
        }
        if let migrated = try await self.bridgeLegacySecret(
            currentValue: updated.legacyToken,
            secureStoreKey: Self.secretStoreKey(profileID: profileID, field: "token")
        ) {
            updated.legacyToken = migrated
            mutated = true
        }
        if let migrated = try await self.bridgeLegacySecret(
            currentValue: updated.legacyAccessToken,
            secureStoreKey: Self.secretStoreKey(profileID: profileID, field: "accessToken")
        ) {
            updated.legacyAccessToken = migrated
            mutated = true
        }
        if let migrated = try await self.bridgeLegacySecret(
            currentValue: updated.legacyRefreshToken,
            secureStoreKey: Self.secretStoreKey(profileID: profileID, field: "refreshToken")
        ) {
            updated.legacyRefreshToken = migrated
            mutated = true
        }

        if mutated {
            self.state.profiles[profileID] = updated
            try self.save()
        }
        return updated
    }

    private func bridgeLegacySecret(
        currentValue: String?,
        secureStoreKey: String
    ) async throws -> String?? {
        guard let currentValue else {
            return nil
        }
        let normalized = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = try await self.credentialStore.loadSecret(for: secureStoreKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if existing == nil, !normalized.isEmpty {
            try await self.credentialStore.saveSecret(normalized, for: secureStoreKey)
        }
        return .some(nil)
    }

    private func writeSecret(_ value: String?, for key: String) async throws {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if normalized.isEmpty {
            try await self.credentialStore.deleteSecret(for: key)
        } else {
            try await self.credentialStore.saveSecret(normalized, for: key)
        }
    }

    private static func normalizeProviderID(_ providerID: String) -> String {
        providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func normalizeProfileID(_ profileID: String) throws -> String {
        let normalized = profileID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw OpenClawCoreError.invalidConfiguration("Auth profile ID must not be empty")
        }
        return normalized
    }

    private static func credentialEmail(_ credential: AuthProfileCredential) -> String? {
        switch credential {
        case .apiKey(let value):
            return value.email
        case .token(let value):
            return value.email
        case .oauth(let value):
            return value.email
        }
    }

    private static func credentialClientID(_ credential: AuthProfileCredential) -> String? {
        if case .oauth(let value) = credential {
            return value.clientID
        }
        return nil
    }

    private static func credentialMetadata(_ credential: AuthProfileCredential) -> [String: String] {
        switch credential {
        case .apiKey(let value):
            return value.metadata
        case .token:
            return [:]
        case .oauth(let value):
            return value.metadata
        }
    }

    private static func credentialKeyRef(_ credential: AuthProfileCredential) -> SecretRef? {
        if case .apiKey(let value) = credential {
            return value.keyRef
        }
        return nil
    }

    private static func credentialTokenRef(_ credential: AuthProfileCredential) -> SecretRef? {
        if case .token(let value) = credential {
            return value.tokenRef
        }
        return nil
    }

    private static func secretStoreKey(profileID: String, field: String) -> String {
        "auth.profiles.\(profileID).\(field)"
    }

    private static func currentTimestampMs() -> Int {
        Int(Date().timeIntervalSince1970 * 1000)
    }
}

/// Resolver that orders auth profiles using config, cooldowns, and round-robin rules.
public enum AuthProfileResolver {
    /// Resolves the effective auth-profile order for a provider request.
    public static func resolveProfileOrder(
        provider: String,
        preferredProfileID: String? = nil,
        config: AuthConfig? = nil,
        snapshot: AuthProfileStoreSnapshot
    ) -> [String] {
        let normalizedProvider = normalizeProviderID(provider)
        let now = currentTimestampMs()
        let storedOrder = snapshot.order[normalizedProvider]
        let configuredOrder = config?.order[normalizedProvider]
        let explicitOrder = storedOrder ?? configuredOrder
        let configuredProfiles = config?.profiles.compactMap { profileID, profile in
            normalizeProviderID(profile.provider) == normalizedProvider ? profileID : nil
        } ?? []
        let baseOrder = explicitOrder ?? (!configuredProfiles.isEmpty ? configuredProfiles : snapshot.profiles.compactMap {
            normalizeProviderID($0.value.provider) == normalizedProvider ? $0.key : nil
        })
        let eligible = dedupe(baseOrder).filter { isEligible(profileID: $0, provider: normalizedProvider, config: config, snapshot: snapshot, now: now) }

        if let explicitOrder, !explicitOrder.isEmpty {
            let ordered = moveCooldownEntriesToEnd(eligible, snapshot: snapshot, now: now)
            if let preferredProfileID, ordered.contains(preferredProfileID) {
                return [preferredProfileID] + ordered.filter { $0 != preferredProfileID }
            }
            return ordered
        }

        let sorted = moveCooldownEntriesToEnd(
            eligible.sorted { lhs, rhs in
                let lhsMetadata = snapshot.profiles[lhs]
                let rhsMetadata = snapshot.profiles[rhs]
                let lhsRank = modeRank(lhsMetadata?.mode)
                let rhsRank = modeRank(rhsMetadata?.mode)
                if lhsRank != rhsRank {
                    return lhsRank < rhsRank
                }
                let lhsLastUsed = snapshot.usageStats[lhs]?.lastUsed ?? 0
                let rhsLastUsed = snapshot.usageStats[rhs]?.lastUsed ?? 0
                return lhsLastUsed < rhsLastUsed
            },
            snapshot: snapshot,
            now: now
        )
        if let preferredProfileID, sorted.contains(preferredProfileID) {
            return [preferredProfileID] + sorted.filter { $0 != preferredProfileID }
        }
        return sorted
    }

    private static func isEligible(
        profileID: String,
        provider: String,
        config: AuthConfig?,
        snapshot: AuthProfileStoreSnapshot,
        now: Int
    ) -> Bool {
        guard let metadata = snapshot.profiles[profileID] else {
            return false
        }
        guard normalizeProviderID(metadata.provider) == provider else {
            return false
        }
        if let configured = config?.profiles[profileID] {
            guard normalizeProviderID(configured.provider) == provider else {
                return false
            }
            if configured.mode != metadata.mode && !(configured.mode == .oauth && metadata.mode == .token) {
                return false
            }
        }
        if let expires = metadata.expires,
           expires > 0,
           expires <= now,
           metadata.mode != .oauth
        {
            return false
        }
        if let disabledUntil = snapshot.usageStats[profileID]?.disabledUntil, disabledUntil > now {
            return false
        }
        return true
    }

    private static func moveCooldownEntriesToEnd(
        _ profileIDs: [String],
        snapshot: AuthProfileStoreSnapshot,
        now: Int
    ) -> [String] {
        var available: [String] = []
        var cooldown: [(profileID: String, until: Int)] = []
        for profileID in profileIDs {
            if let cooldownUntil = snapshot.usageStats[profileID]?.cooldownUntil, cooldownUntil > now {
                cooldown.append((profileID, cooldownUntil))
            } else {
                available.append(profileID)
            }
        }
        let cooldownOrdered = cooldown.sorted { $0.until < $1.until }.map(\.profileID)
        return available + cooldownOrdered
    }

    private static func modeRank(_ mode: AuthProfileMode?) -> Int {
        switch mode {
        case .oauth:
            return 0
        case .token:
            return 1
        case .apiKey:
            return 2
        case nil:
            return 3
        }
    }

    private static func dedupe(_ profileIDs: [String]) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        for profileID in profileIDs {
            if seen.insert(profileID).inserted {
                ordered.append(profileID)
            }
        }
        return ordered
    }

    private static func normalizeProviderID(_ providerID: String) -> String {
        providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func currentTimestampMs() -> Int {
        Int(Date().timeIntervalSince1970 * 1000)
    }
}
