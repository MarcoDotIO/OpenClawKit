import Foundation
import OpenClawMCP
import OpenClawProtocol

/// Plugin package metadata (`openclaw.plugin.json`), readable without executing plugin code.
///
/// Mirrors upstream `docs/plugins/manifest.md`: identity, categories, activation, contract
/// declarations, a JSON Schema for `plugins.entries.<id>.config`, static MCP servers, and skill
/// directories. Unknown keys are preserved in ``extra``.
public struct PluginManifest: Codable, Sendable, Equatable {
    /// Activation settings.
    public struct Activation: Codable, Sendable, Equatable {
        /// Load when the gateway starts.
        public var onStartup: Bool?

        /// Creates activation settings.
        /// - Parameter onStartup: Load at startup.
        public init(onStartup: Bool? = nil) {
            self.onStartup = onStartup
        }
    }

    /// Plugin identifier.
    public var id: String
    /// Display name.
    public var name: String?
    /// Description.
    public var description: String?
    /// Version.
    public var version: String?
    /// Catalog categories.
    public var categories: [String]?
    /// Activation settings.
    public var activation: Activation?
    /// Declared contracts (`tools`, `channels`, `providers`, `codeModeExecutors`, …).
    public var contracts: [String: [String]]?
    /// JSON Schema for the plugin config.
    public var configSchema: AnyCodable?
    /// Static MCP servers the plugin provides.
    public var mcpServers: [String: MCPServerConfig]?
    /// Skill directories relative to the plugin root.
    public var skills: [String]?
    /// Unknown keys.
    public var extra: [String: AnyCodable]

    /// Creates a manifest.
    /// - Parameters:
    ///   - id: Identifier.
    ///   - name: Name.
    ///   - description: Description.
    ///   - version: Version.
    ///   - categories: Categories.
    ///   - activation: Activation.
    ///   - contracts: Contracts.
    ///   - configSchema: Config schema.
    ///   - mcpServers: MCP servers.
    ///   - skills: Skill directories.
    ///   - extra: Unknown keys.
    public init(
        id: String,
        name: String? = nil,
        description: String? = nil,
        version: String? = nil,
        categories: [String]? = nil,
        activation: Activation? = nil,
        contracts: [String: [String]]? = nil,
        configSchema: AnyCodable? = nil,
        mcpServers: [String: MCPServerConfig]? = nil,
        skills: [String]? = nil,
        extra: [String: AnyCodable] = [:]
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.version = version
        self.categories = categories
        self.activation = activation
        self.contracts = contracts
        self.configSchema = configSchema
        self.mcpServers = mcpServers
        self.skills = skills
        self.extra = extra
    }

    /// Loads `openclaw.plugin.json`.
    /// - Parameter url: Manifest file URL.
    /// - Returns: The manifest.
    public static func load(from url: URL) throws -> PluginManifest {
        try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: url))
    }

    /// Validates a plugin config against ``configSchema`` (no schema accepts anything).
    /// - Parameter config: `plugins.entries.<id>.config` value.
    /// - Throws: ``MCPJSONSchemaValidator/Failure`` when invalid.
    public func validateConfig(_ config: AnyCodable?) throws {
        guard let schema = self.configSchema?.dictionaryValue else { return }
        try MCPJSONSchemaValidator.validate(config ?? AnyCodable([String: AnyCodable]()), against: schema)
    }

    private static let knownKeys: Set<String> = [
        "id", "name", "description", "version", "categories", "activation", "contracts", "configSchema", "mcpServers", "skills",
    ]

    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { self.stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue _: Int) { nil }
    }

    /// Decodes a manifest; only `id` is required.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        self.id = try container.decode(String.self, forKey: AnyKey("id"))
        self.name = try container.decodeIfPresent(String.self, forKey: AnyKey("name"))
        self.description = try container.decodeIfPresent(String.self, forKey: AnyKey("description"))
        self.version = try container.decodeIfPresent(String.self, forKey: AnyKey("version"))
        self.categories = try container.decodeIfPresent([String].self, forKey: AnyKey("categories"))
        self.activation = try container.decodeIfPresent(Activation.self, forKey: AnyKey("activation"))
        self.contracts = try container.decodeIfPresent([String: [String]].self, forKey: AnyKey("contracts"))
        self.configSchema = try container.decodeIfPresent(AnyCodable.self, forKey: AnyKey("configSchema"))
        self.mcpServers = try container.decodeIfPresent([String: MCPServerConfig].self, forKey: AnyKey("mcpServers"))
        self.skills = try container.decodeIfPresent([String].self, forKey: AnyKey("skills"))
        var extra: [String: AnyCodable] = [:]
        for key in container.allKeys where !Self.knownKeys.contains(key.stringValue) {
            extra[key.stringValue] = try container.decode(AnyCodable.self, forKey: key)
        }
        self.extra = extra
    }

    /// Encodes the manifest including unknown keys.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyKey.self)
        for (key, value) in self.extra where !Self.knownKeys.contains(key) {
            try container.encode(value, forKey: AnyKey(key))
        }
        try container.encode(self.id, forKey: AnyKey("id"))
        try container.encodeIfPresent(self.name, forKey: AnyKey("name"))
        try container.encodeIfPresent(self.description, forKey: AnyKey("description"))
        try container.encodeIfPresent(self.version, forKey: AnyKey("version"))
        try container.encodeIfPresent(self.categories, forKey: AnyKey("categories"))
        try container.encodeIfPresent(self.activation, forKey: AnyKey("activation"))
        try container.encodeIfPresent(self.contracts, forKey: AnyKey("contracts"))
        try container.encodeIfPresent(self.configSchema, forKey: AnyKey("configSchema"))
        try container.encodeIfPresent(self.mcpServers, forKey: AnyKey("mcpServers"))
        try container.encodeIfPresent(self.skills, forKey: AnyKey("skills"))
    }
}
