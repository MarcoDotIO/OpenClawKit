import Foundation

#if canImport(Security)
import Security
#endif

/// Storage contract for runtime secrets such as API tokens.
public protocol CredentialStore: Sendable {
    /// Persists a secret value for a key.
    /// - Parameters:
    ///   - value: Secret value to persist.
    ///   - key: Logical secret key.
    func saveSecret(_ value: String, for key: String) async throws

    /// Loads a secret value for a key.
    /// - Parameter key: Logical secret key.
    /// - Returns: Stored secret when present.
    func loadSecret(for key: String) async throws -> String?

    /// Deletes the secret value for a key.
    /// - Parameter key: Logical secret key.
    func deleteSecret(for key: String) async throws
}

/// Result payload from resolving secure-store values against legacy plaintext values.
public struct CredentialSecretMigrationResult: Sendable, Equatable {
    /// Final values that should be used by the host application.
    public let resolvedSecrets: [String: String]
    /// Values that should be persisted into secure storage as migration backfill.
    public let valuesToPersist: [String: String]

    /// Creates a migration result.
    /// - Parameters:
    ///   - resolvedSecrets: Effective merged secret values.
    ///   - valuesToPersist: Values that must be written to secure storage.
    public init(resolvedSecrets: [String: String], valuesToPersist: [String: String]) {
        self.resolvedSecrets = resolvedSecrets
        self.valuesToPersist = valuesToPersist
    }
}

/// Utility for merging legacy plaintext secrets with secure-store values.
public enum CredentialSecretMigration {
    /// Resolves effective secrets from existing secure-store and legacy plaintext values.
    ///
    /// For each key:
    /// - secure-store value wins when present and non-empty
    /// - otherwise non-empty legacy value is selected and marked for secure-store persistence
    /// - empty values are omitted from the result
    ///
    /// - Parameters:
    ///   - secureStoreSecrets: Secrets currently available from secure storage.
    ///   - legacySecrets: Legacy plaintext secrets from old settings payloads.
    /// - Returns: Migration result containing effective values and backfill set.
    public static func resolve(
        secureStoreSecrets: [String: String],
        legacySecrets: [String: String]
    ) -> CredentialSecretMigrationResult {
        let allKeys = Set(secureStoreSecrets.keys).union(legacySecrets.keys)
        var resolved: [String: String] = [:]
        var toPersist: [String: String] = [:]

        for key in allKeys {
            let secureValue = secureStoreSecrets[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let legacyValue = legacySecrets[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !secureValue.isEmpty {
                resolved[key] = secureValue
                continue
            }
            if !legacyValue.isEmpty {
                resolved[key] = legacyValue
                toPersist[key] = legacyValue
            }
        }
        return CredentialSecretMigrationResult(resolvedSecrets: resolved, valuesToPersist: toPersist)
    }
}

private struct CredentialFilePayload: Codable, Sendable {
    let version: Int
    var secrets: [String: String]
}

/// File-backed credential store for non-Apple or fallback environments.
public actor FileCredentialStore: CredentialStore {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// Creates a file-backed credential store.
    /// - Parameter fileURL: Path of the credentials file.
    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.decoder = JSONDecoder()
    }

    public func saveSecret(_ value: String, for key: String) async throws {
        let normalizedKey = try Self.normalizedKey(key)
        var payload = try self.loadPayload()
        payload.secrets[normalizedKey] = value
        try self.persist(payload)
    }

    public func loadSecret(for key: String) async throws -> String? {
        let normalizedKey = try Self.normalizedKey(key)
        let payload = try self.loadPayload()
        return payload.secrets[normalizedKey]
    }

    public func deleteSecret(for key: String) async throws {
        let normalizedKey = try Self.normalizedKey(key)
        var payload = try self.loadPayload()
        payload.secrets.removeValue(forKey: normalizedKey)
        try self.persist(payload)
    }

    private func loadPayload() throws -> CredentialFilePayload {
        guard OpenClawFileSystem.fileExists(self.fileURL) else {
            return CredentialFilePayload(version: 1, secrets: [:])
        }
        do {
            let data = try OpenClawFileSystem.readData(self.fileURL)
            return try self.decoder.decode(CredentialFilePayload.self, from: data)
        } catch {
            throw OpenClawCoreError.unavailable("Credential file is unreadable: \(error)")
        }
    }

    private func persist(_ payload: CredentialFilePayload) throws {
        let directory = self.fileURL.deletingLastPathComponent()
        try OpenClawFileSystem.ensureDirectory(directory)
        let data = try self.encoder.encode(payload)
        try OpenClawFileSystem.writeData(data, to: self.fileURL)
        #if !os(Windows)
        try? FileManager().setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.fileURL.path)
        #endif
    }

    private static func normalizedKey(_ key: String) throws -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw OpenClawCoreError.invalidConfiguration("Credential key must not be empty")
        }
        return trimmed
    }
}

#if canImport(Security)
/// Keychain-backed credential store for Apple platforms.
public actor KeychainCredentialStore: CredentialStore {
    private let service: String
    private let accessGroup: String?
    private let accessibility: CFString

    /// Creates a keychain-backed credential store.
    /// - Parameters:
    ///   - service: Keychain service namespace.
    ///   - accessGroup: Optional keychain access group.
    ///   - accessibility: Keychain item accessibility applied to saved secrets.
    public init(
        service: String = "io.marcodotio.openclawkit.credentials",
        accessGroup: String? = nil,
        accessibility: CFString = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    ) {
        self.service = service
        self.accessGroup = accessGroup
        self.accessibility = accessibility
    }

    public func saveSecret(_ value: String, for key: String) async throws {
        let normalizedKey = try Self.normalizedKey(key)
        let data = Data(value.utf8)
        var createQuery = self.baseQuery(for: normalizedKey)
        createQuery[kSecValueData as String] = data

        let createStatus = SecItemAdd(createQuery as CFDictionary, nil)
        if createStatus == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(
                self.baseQuery(for: normalizedKey) as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw Self.keychainError(status: updateStatus, operation: "update", key: normalizedKey)
            }
            return
        }
        guard createStatus == errSecSuccess else {
            throw Self.keychainError(status: createStatus, operation: "save", key: normalizedKey)
        }
    }

    public func loadSecret(for key: String) async throws -> String? {
        let normalizedKey = try Self.normalizedKey(key)
        var query = self.baseQuery(for: normalizedKey)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw Self.keychainError(status: status, operation: "load", key: normalizedKey)
        }
        guard let data = item as? Data else {
            throw OpenClawCoreError.unavailable("Keychain returned an unexpected payload type")
        }
        guard let value = String(data: data, encoding: .utf8) else {
            throw OpenClawCoreError.unavailable("Keychain value is not valid UTF-8")
        }
        return value
    }

    public func deleteSecret(for key: String) async throws {
        let normalizedKey = try Self.normalizedKey(key)
        let status = SecItemDelete(self.baseQuery(for: normalizedKey) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Self.keychainError(status: status, operation: "delete", key: normalizedKey)
        }
    }

    internal func itemQuery(for key: String) throws -> [String: Any] {
        self.baseQuery(for: try Self.normalizedKey(key))
    }

    internal func itemQueryAccessibility(for key: String) throws -> String? {
        self.baseQuery(for: try Self.normalizedKey(key))[kSecAttrAccessible as String] as? String
    }

    private func baseQuery(for key: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecAttrAccount as String: key,
            kSecAttrAccessible as String: self.accessibility,
        ]
        if let accessGroup, !accessGroup.isEmpty {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    private static func normalizedKey(_ key: String) throws -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw OpenClawCoreError.invalidConfiguration("Credential key must not be empty")
        }
        return trimmed
    }

    private static func keychainError(status: OSStatus, operation: String, key: String) -> OpenClawCoreError {
        let description = (SecCopyErrorMessageString(status, nil) as String?) ?? "status \(status)"
        return OpenClawCoreError.unavailable("Keychain \(operation) failed for '\(key)': \(description)")
    }
}
#else
/// Non-Apple placeholder that preserves API shape when Security is unavailable.
public actor KeychainCredentialStore: CredentialStore {
    /// Creates a placeholder keychain store.
    /// - Parameters:
    ///   - service: Ignored.
    ///   - accessGroup: Ignored.
    ///   - accessibility: Ignored.
    public init(
        service _: String = "io.marcodotio.openclawkit.credentials",
        accessGroup _: String? = nil,
        accessibility _: CFString = "kSecAttrAccessibleWhenUnlockedThisDeviceOnly" as CFString
    ) {}

    public func saveSecret(_: String, for _: String) async throws {
        throw OpenClawCoreError.unavailable("Keychain is not available on this platform")
    }

    public func loadSecret(for _: String) async throws -> String? {
        throw OpenClawCoreError.unavailable("Keychain is not available on this platform")
    }

    public func deleteSecret(for _: String) async throws {
        throw OpenClawCoreError.unavailable("Keychain is not available on this platform")
    }
}
#endif

/// Factory helper for selecting the most secure credential store for the runtime platform.
public enum CredentialStoreFactory {
    /// Creates the default credential store for the current platform.
    /// - Parameters:
    ///   - fallbackFileURL: File URL used when keychain is unavailable.
    ///   - keychainService: Keychain service namespace.
    ///   - keychainAccessGroup: Optional keychain access group.
    /// - Returns: Credential store implementation.
    public static func makeDefault(
        fallbackFileURL: URL,
        keychainService: String = "io.marcodotio.openclawkit.credentials",
        keychainAccessGroup: String? = nil
    ) -> any CredentialStore {
        #if canImport(Security)
        return KeychainCredentialStore(service: keychainService, accessGroup: keychainAccessGroup)
        #else
        return FileCredentialStore(fileURL: fallbackFileURL)
        #endif
    }
}
