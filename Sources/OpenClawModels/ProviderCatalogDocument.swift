import Foundation
import OpenClawCore

/// Decoded shape of the generated catalog document embedded in `ProviderCatalogData.swift`.
struct ProviderCatalogDocument: Decodable, Sendable {
    struct Provider: Decodable, Sendable {
        let id: String
        let pluginID: String?
        let displayName: String
        let aliases: [String]
        let capabilities: [String]
        let capabilityProviderIDs: [String: [String]]?
        let auth: String?
        let authHeader: Bool?
        let authMethods: [String]
        let envVars: [String]
        let usageEnvVars: [String]?
        let auxiliaryEnvVars: [String: [String]]?
        let discovery: String?
        let docsPath: String?
        let status: String?
        let statusReason: String?
        let replacedBy: String?
        let distribution: String?
        let sdkLocal: Bool?
        let catalog: ModelCatalogProvider

        private enum CodingKeys: String, CodingKey {
            case id
            case pluginID = "pluginId"
            case displayName
            case aliases
            case capabilities
            case capabilityProviderIDs = "capabilityProviderIds"
            case auth
            case authHeader
            case authMethods
            case envVars
            case usageEnvVars
            case auxiliaryEnvVars
            case discovery
            case docsPath
            case status
            case statusReason
            case replacedBy
            case distribution
            case sdkLocal
            case catalog
        }
    }

    struct MetadataProvider: Decodable, Sendable {
        let id: String
        let pluginID: String?
        let displayName: String
        let aliases: [String]
        let capabilities: [String]
        let authMethods: [String]
        let envVars: [String]
        let docsPath: String?
        let distribution: String?
        let sdkLocal: Bool?
        let nativeRuntimeAvailable: Bool?

        private enum CodingKeys: String, CodingKey {
            case id
            case pluginID = "pluginId"
            case displayName
            case aliases
            case capabilities
            case authMethods
            case envVars
            case docsPath
            case distribution
            case sdkLocal
            case nativeRuntimeAvailable
        }
    }

    struct ModelPrefix: Decodable, Sendable {
        let prefix: String
        let provider: String
    }

    let schemaVersion: Int
    let sourceVersion: String
    let sourceCommit: String
    let sourceCommitFull: String?
    let generatedAt: Int64
    let providers: [Provider]
    let metadataProviders: [MetadataProvider]
    let aliases: [String: ModelCatalogAlias]
    let authAliases: [String: String]
    let suppressions: [ModelCatalogSuppression]
    let modelIdNormalization: [String: ModelIDNormalizationRule]
    let modelPrefixes: [ModelPrefix]
    let capabilityProviders: [String: [String]]
    let mediaUnderstanding: [String: MediaUnderstandingProviderMetadata]
}

/// Lazily decoded, immutable catalog state shared by the `OpenClawReferenceProviderCatalog` APIs.
final class ProviderCatalogStore: Sendable {
    static let shared = ProviderCatalogStore(json: ProviderCatalogGeneratedData.json)

    let entries: [ProviderCatalogEntry]
    let entriesByID: [String: Int]
    let metadataEntries: [ProviderPluginMetadataEntry]
    let aliases: [String: ModelCatalogAlias]
    let authAliases: [String: String]
    let suppressions: [ModelCatalogSuppression]
    let modelIDNormalization: [String: ModelIDNormalizationRule]
    let modelPrefixes: [BareModelPrefixRule]
    let capabilityProviderIDs: [ProviderCapability: [String]]
    let mediaUnderstanding: [String: MediaUnderstandingProviderMetadata]
    let sourceCommit: String?
    let schemaVersion: Int?
    let generatedAt: Int64?
    /// Description of the decoding failure when the embedded document could not be read (tests assert `nil`).
    let decodeError: String?

    init(json: String) {
        do {
            let document = try JSONDecoder().decode(ProviderCatalogDocument.self, from: Data(json.utf8))
            let entries = document.providers.map(Self.makeEntry)
            self.entries = entries
            self.entriesByID = Self.index(entries)
            self.metadataEntries = document.metadataProviders.map(Self.makeMetadataEntry)
            self.aliases = document.aliases
            self.authAliases = document.authAliases
            self.suppressions = document.suppressions
            self.modelIDNormalization = document.modelIdNormalization
            self.modelPrefixes = document.modelPrefixes.map { BareModelPrefixRule(prefix: $0.prefix, providerID: $0.provider) }
            self.capabilityProviderIDs = document.capabilityProviders.reduce(into: [:]) { partial, pair in
                if let capability = ProviderCapability(normalizing: pair.key) {
                    partial[capability] = pair.value
                }
            }
            var media = document.mediaUnderstanding
            for key in media.keys {
                media[key]?.providerID = key
            }
            self.mediaUnderstanding = media
            self.sourceCommit = document.sourceCommit
            self.schemaVersion = document.schemaVersion
            self.generatedAt = document.generatedAt
            self.decodeError = nil
        } catch {
            let fallback = Self.fallbackEntries
            self.entries = fallback
            self.entriesByID = Self.index(fallback)
            self.metadataEntries = []
            self.aliases = ["foundation": ModelCatalogAlias(provider: "apple-fm", legacy: true)]
            self.authAliases = [:]
            self.suppressions = []
            self.modelIDNormalization = [:]
            self.modelPrefixes = []
            self.capabilityProviderIDs = [:]
            self.mediaUnderstanding = [:]
            self.sourceCommit = nil
            self.schemaVersion = nil
            self.generatedAt = nil
            self.decodeError = String(describing: error)
        }
    }

    private static func index(_ entries: [ProviderCatalogEntry]) -> [String: Int] {
        var index: [String: Int] = [:]
        for (offset, entry) in entries.enumerated() where index[entry.providerID] == nil {
            index[entry.providerID] = offset
        }
        return index
    }

    private static func makeEntry(_ provider: ProviderCatalogDocument.Provider) -> ProviderCatalogEntry {
        let catalog = provider.catalog
        var models = catalog.models
        if let defaultID = catalog.defaultModel, let index = models.firstIndex(where: { $0.id == defaultID }), index > 0 {
            let row = models.remove(at: index)
            models.insert(row, at: 0)
        }
        let config = ModelProviderConfig(
            enabled: false,
            baseURL: catalog.baseURL ?? "",
            auth: provider.auth.flatMap(ModelProviderAuthMode.init(rawValue:)),
            api: catalog.api,
            headers: catalog.headers ?? [:],
            authHeader: provider.authHeader,
            models: models.map { $0.definitionConfig() }
        )
        let capabilityProviderIDs: [ProviderCapability: [String]] = (provider.capabilityProviderIDs ?? [:])
            .reduce(into: [:]) { partial, pair in
                if let capability = ProviderCapability(normalizing: pair.key) {
                    partial[capability] = pair.value
                }
            }
        return ProviderCatalogEntry(
            providerID: provider.id,
            displayName: provider.displayName,
            aliases: provider.aliases,
            capabilities: ProviderCapability.lossyList(provider.capabilities),
            config: config,
            pluginID: provider.pluginID,
            capabilityProviderIDs: capabilityProviderIDs,
            authEnvVars: provider.envVars,
            usageAuthEnvVars: provider.usageEnvVars ?? [],
            auxiliaryAuthEnvVars: provider.auxiliaryEnvVars ?? [:],
            authMethods: provider.authMethods,
            discovery: provider.discovery.flatMap(ModelCatalogDiscovery.init(rawValue:)),
            docsPath: provider.docsPath,
            status: provider.status.flatMap(ProviderCatalogStatus.init(rawValue:)) ?? .available,
            statusReason: provider.statusReason,
            replacedBy: provider.replacedBy,
            distribution: provider.distribution.flatMap(ProviderDistribution.init(rawValue:)) ?? .bundled,
            sdkLocal: provider.sdkLocal ?? false,
            catalog: catalog
        )
    }

    private static func makeMetadataEntry(_ provider: ProviderCatalogDocument.MetadataProvider) -> ProviderPluginMetadataEntry {
        ProviderPluginMetadataEntry(
            providerID: provider.id,
            displayName: provider.displayName,
            docsPath: provider.docsPath,
            capabilities: ProviderCapability.lossyList(provider.capabilities),
            nativeRuntimeAvailable: provider.nativeRuntimeAvailable ?? false,
            pluginID: provider.pluginID,
            aliases: provider.aliases,
            authEnvVars: provider.envVars,
            authMethods: provider.authMethods,
            distribution: provider.distribution.flatMap(ProviderDistribution.init(rawValue:)) ?? .bundled,
            sdkLocal: provider.sdkLocal ?? false
        )
    }

    /// SDK-local entries kept compiled in so the SDK stays usable if the embedded document ever fails to decode.
    static let fallbackEntries: [ProviderCatalogEntry] = [
        ProviderCatalogEntry(
            providerID: "openai-compatible",
            displayName: "OpenAI Compatible",
            config: ModelProviderConfig(
                baseURL: "https://api.openai.com/v1",
                auth: .apiKey,
                api: .openAICompletions,
                models: [ModelDefinitionConfig(id: "gpt-5.4-mini", reasoning: true, input: [.text, .image])]
            ),
            authEnvVars: ["OPENAI_API_KEY"],
            authMethods: ["api-key"],
            sdkLocal: true
        ),
        ProviderCatalogEntry(
            providerID: "apple-fm",
            displayName: "Apple Foundation Models",
            aliases: ["foundation"],
            config: ModelProviderConfig(
                baseURL: "http://127.0.0.1",
                auth: nil,
                api: .openAICompletions,
                authHeader: false,
                models: [ModelDefinitionConfig(id: "system", name: "Apple Foundation Models", contextWindow: 4_096, maxTokens: 1_024)]
            ),
            authMethods: ["local"],
            discovery: .runtime
        ),
        ProviderCatalogEntry(
            providerID: "local",
            displayName: "Local",
            config: ModelProviderConfig(
                baseURL: "local://runtime",
                auth: nil,
                api: .ollama,
                models: [ModelDefinitionConfig(id: "local-default", name: "Local")]
            ),
            authMethods: ["local"],
            discovery: .runtime,
            sdkLocal: true
        ),
    ]
}
