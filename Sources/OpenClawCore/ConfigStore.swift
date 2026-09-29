import Foundation
import OpenClawProtocol

/// Actor-backed configuration store with optional in-memory TTL cache.
///
/// Persists the SDK-native ``OpenClawConfig`` file. For the upstream `openclaw.json` that an OpenClaw
/// gateway loads, use ``OpenClawConfigDocumentStore`` (or `config.get`/`config.patch` against a remote
/// gateway) instead; never point an upstream gateway at this file.
public actor ConfigStore {
    private let fileURL: URL
    private let cacheTTLms: Int
    private var cached: (expiresAt: Date, value: OpenClawConfig)?

    /// Creates a configuration store.
    /// - Parameters:
    ///   - fileURL: Config file URL.
    ///   - cacheTTLms: Cache lifetime in milliseconds.
    public init(fileURL: URL, cacheTTLms: Int = 200) {
        self.fileURL = fileURL
        self.cacheTTLms = max(0, cacheTTLms)
    }

    /// Loads configuration from disk and invalidates in-memory cache.
    /// - Returns: Decoded configuration payload.
    public func load() throws -> OpenClawConfig {
        let data = try Data(contentsOf: self.fileURL)
        let config = try JSONDecoder().decode(OpenClawConfig.self, from: data)
        self.cached = nil
        return config
    }

    /// Loads configuration and returns the issues its lenient decoders recorded
    /// (unknown enum values, mistyped leaves, dropped providers).
    /// - Returns: The configuration and its decode issues.
    public func loadWithIssues() throws -> (config: OpenClawConfig, issues: [ConfigDecodeIssue]) {
        let data = try Data(contentsOf: self.fileURL)
        let result = try ConfigDecodeIssueCollector.decode(OpenClawConfig.self, from: data)
        self.cached = nil
        return (result.value, result.issues)
    }

    /// Loads configuration using the cache when still valid.
    /// - Returns: Decoded configuration payload.
    public func loadCached() throws -> OpenClawConfig {
        if let cached, cached.expiresAt > Date() {
            return cached.value
        }

        let loaded = try self.load()
        if self.cacheTTLms > 0 {
            let expiry = Date().addingTimeInterval(Double(self.cacheTTLms) / 1000.0)
            self.cached = (expiresAt: expiry, value: loaded)
        }
        return loaded
    }

    /// Saves configuration atomically and invalidates cache.
    ///
    /// Top-level keys that ``OpenClawConfig`` does not own (for example `meta` or `wizard` written by
    /// another tool) are preserved from the file on disk instead of being dropped. Setting an optional
    /// section (`mcp`, `skills`, `memory`, `plugins`) to `nil` removes it, except that a section on
    /// disk that fails to decode (and therefore loaded as `nil`) is kept as written.
    /// - Parameter config: Configuration payload.
    public func save(_ config: OpenClawConfig) throws {
        var tree = try AnyCodable(encoding: config).dictionaryValue ?? [:]
        if let existing = try? Data(contentsOf: self.fileURL),
           let existingTree = try? JSONDecoder().decode(AnyCodable.self, from: existing).dictionaryValue
        {
            for (key, value) in existingTree where tree[key] == nil {
                if !Self.ownedTopLevelKeys.contains(key) || Self.isUndecodableSection(key, value) {
                    tree[key] = value
                }
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(AnyCodable(.object(tree)))
        try OpenClawFileSystem.ensurePrivateDirectory(self.fileURL.deletingLastPathComponent())
        try data.write(to: self.fileURL, options: [.atomic])
        OpenClawFileSystem.restrictToOwner(self.fileURL)
        self.cached = nil
    }

    /// Clears cached configuration value.
    public func clearCache() {
        self.cached = nil
    }

    /// Top-level keys written by ``OpenClawConfig`` (derived from its coding keys, so new sections are
    /// never mistaken for foreign keys).
    static let ownedTopLevelKeys: Set<String> = Set(OpenClawConfig.CodingKeys.allCases.map(\.stringValue))

    /// Whether an owned optional section on disk is a value lenient decoding drops (so the config
    /// holds `nil` for it without the caller having removed it).
    static func isUndecodableSection(_ key: String, _ value: AnyCodable) -> Bool {
        guard let codingKey = OpenClawConfig.CodingKeys(rawValue: key), value != AnyCodable(.null),
              let data = try? JSONEncoder().encode(AnyCodable(.object([key: value]))),
              let probe = try? JSONDecoder().decode(OpenClawConfig.self, from: data)
        else {
            return false
        }
        switch codingKey {
        case .mcp:
            return probe.mcp == nil
        case .skills:
            return probe.skills == nil
        case .memory:
            return probe.memory == nil
        case .plugins:
            return probe.plugins == nil
        case .secrets, .gateway, .agents, .channels, .routing, .auth, .models, .runtime:
            return false
        }
    }
}
