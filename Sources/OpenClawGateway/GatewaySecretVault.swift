import Foundation
import OpenClawCore
import OpenClawProtocol

/// Disclosure behavior of a vault entry, mirroring upstream `secrets.store` entry kinds.
public enum GatewaySecretKind: String, Codable, Sendable, CaseIterable {
    /// Credential whose value is never listed.
    case secret
    /// Environment value that is intentionally visible in listings.
    case env
}

/// Metadata tracked for one vault entry (never includes the secret value).
public struct GatewaySecretMetadata: Codable, Sendable, Equatable {
    /// Entry name (the credential-store key).
    public let name: String
    /// Disclosure behavior.
    public var kind: GatewaySecretKind
    /// Creation time in milliseconds since 1970 (`0` for entries migrated from the v1 index).
    public var createdAtMs: Int64
    /// Last update time in milliseconds since 1970.
    public var updatedAtMs: Int64
    /// Identity of the last writer, when known.
    public var updatedBy: String?
    /// Hosts allowed to receive a `secret` entry, when restricted.
    public var allowedHosts: [String]?

    /// Creates entry metadata.
    /// - Parameters:
    ///   - name: Entry name.
    ///   - kind: Disclosure behavior.
    ///   - createdAtMs: Creation time in milliseconds.
    ///   - updatedAtMs: Last update time in milliseconds.
    ///   - updatedBy: Identity of the last writer.
    ///   - allowedHosts: Hosts allowed to receive the secret.
    public init(
        name: String,
        kind: GatewaySecretKind = .secret,
        createdAtMs: Int64,
        updatedAtMs: Int64,
        updatedBy: String? = nil,
        allowedHosts: [String]? = nil
    ) {
        self.name = name
        self.kind = kind
        self.createdAtMs = createdAtMs
        self.updatedAtMs = updatedAtMs
        self.updatedBy = updatedBy
        self.allowedHosts = allowedHosts
    }
}

private struct GatewaySecretIndex: Codable, Sendable {
    let version: Int
    var keys: [String]
    var entries: [GatewaySecretMetadata]?
}

/// Small metadata wrapper that adds list semantics on top of `CredentialStore`.
public actor GatewaySecretVault {
    private let credentialStore: any CredentialStore
    private let indexURL: URL?
    private var entries: [String: GatewaySecretMetadata]

    /// Creates a metadata-aware secret vault backed by a credential store.
    /// - Parameters:
    ///   - credentialStore: Store holding the secret values.
    ///   - indexURL: Optional file persisting key and metadata inventory (v1 indexes are migrated on write).
    public init(credentialStore: any CredentialStore, indexURL: URL? = nil) {
        self.credentialStore = credentialStore
        self.indexURL = indexURL
        self.entries = [:]
        if let indexURL, FileManager.default.fileExists(atPath: indexURL.path),
           let data = try? Data(contentsOf: indexURL),
           let payload = try? JSONDecoder().decode(GatewaySecretIndex.self, from: data)
        {
            var loaded: [String: GatewaySecretMetadata] = [:]
            for key in payload.keys {
                loaded[key] = GatewaySecretMetadata(name: key, createdAtMs: 0, updatedAtMs: 0)
            }
            for entry in payload.entries ?? [] where loaded[entry.name] != nil {
                loaded[entry.name] = entry
            }
            self.entries = loaded
        }
    }

    /// Returns the sorted list of secret keys tracked by the vault.
    public func listSecretKeys() -> [String] {
        self.entries.keys.sorted()
    }

    /// Returns metadata for every tracked entry, sorted by name.
    public func listMetadata() -> [GatewaySecretMetadata] {
        self.entries.values.sorted { $0.name < $1.name }
    }

    /// Returns metadata for one entry.
    /// - Parameter key: Entry name.
    /// - Returns: Metadata when the entry is tracked.
    public func metadata(for key: String) -> GatewaySecretMetadata? {
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return self.entries[normalized]
    }

    /// Loads a tracked secret value.
    /// - Parameter key: Entry name.
    /// - Returns: The stored value, or `nil` when missing.
    public func loadSecret(for key: String) async throws -> String? {
        let normalizedKey = try Self.normalizedKey(key)
        return try await self.credentialStore.loadSecret(for: normalizedKey)
    }

    /// Stores or replaces a secret value.
    /// - Parameters:
    ///   - value: Secret value.
    ///   - key: Entry name.
    public func setSecret(_ value: String, for key: String) async throws {
        try await self.setSecret(value, for: key, kind: nil, allowedHosts: nil, updatedBy: nil)
    }

    /// Stores or replaces a secret value together with its metadata.
    /// - Parameters:
    ///   - value: Secret value.
    ///   - key: Entry name.
    ///   - kind: Disclosure behavior (`nil` keeps the existing kind, defaulting to `.secret`).
    ///   - allowedHosts: Hosts allowed to receive the secret (`nil` keeps the existing list).
    ///   - updatedBy: Identity of the writer.
    public func setSecret(
        _ value: String,
        for key: String,
        kind: GatewaySecretKind?,
        allowedHosts: [String]?,
        updatedBy: String?
    ) async throws {
        let normalizedKey = try Self.normalizedKey(key)
        try await self.credentialStore.saveSecret(value, for: normalizedKey)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var entry = self.entries[normalizedKey] ?? GatewaySecretMetadata(name: normalizedKey, createdAtMs: now, updatedAtMs: now)
        entry.updatedAtMs = now
        if let kind {
            entry.kind = kind
        }
        if let allowedHosts {
            entry.allowedHosts = allowedHosts
        }
        if entry.kind == .env {
            entry.allowedHosts = nil
        }
        if let updatedBy {
            entry.updatedBy = updatedBy
        }
        self.entries[normalizedKey] = entry
        try self.persistIndexIfNeeded()
    }

    /// Deletes a secret value and returns whether it existed before removal.
    /// - Parameter key: Entry name.
    /// - Returns: `true` when the entry was tracked.
    public func deleteSecret(for key: String) async throws -> Bool {
        let normalizedKey = try Self.normalizedKey(key)
        let existed = self.entries[normalizedKey] != nil
        try await self.credentialStore.deleteSecret(for: normalizedKey)
        self.entries.removeValue(forKey: normalizedKey)
        try self.persistIndexIfNeeded()
        return existed
    }

    private func persistIndexIfNeeded() throws {
        guard let indexURL else {
            return
        }
        try FileManager.default.createDirectory(
            at: indexURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let sorted = self.listMetadata()
        let payload = GatewaySecretIndex(version: 2, keys: sorted.map(\.name), entries: sorted)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        try data.write(to: indexURL, options: [.atomic])
    }

    private static func normalizedKey(_ key: String) throws -> String {
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw OpenClawCoreError.invalidConfiguration("Secret key must not be empty")
        }
        return normalized
    }
}
