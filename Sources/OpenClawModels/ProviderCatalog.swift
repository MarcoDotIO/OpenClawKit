import Foundation
import OpenClawCore

/// Capability bucket advertised by an upstream provider or provider-like plugin.
///
/// Raw values follow upstream capability kinds (`src/plugins/inspect-shape.ts`) with two SDK spellings kept for
/// compatibility: `text` (upstream `text-inference`) and `tool` (upstream `tools` contracts). Decoding accepts the
/// upstream spellings and the legacy `memory-embedding` value.
///
/// - Note: 2026.3.0 renamed the `memoryEmbedding` case to ``embedding`` (raw value `embedding`); `.memoryEmbedding`
///   remains as a deprecated alias. Exhaustive `switch` statements need the new cases.
public enum ProviderCapability: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    /// Text inference (upstream `text-inference`).
    case text
    /// Image generation.
    case imageGeneration = "image-generation"
    /// Video generation.
    case videoGeneration = "video-generation"
    /// Music generation.
    case musicGeneration = "music-generation"
    /// Text-to-speech.
    case speech
    /// Realtime voice sessions.
    case realtimeVoice = "realtime-voice"
    /// Realtime transcription.
    case realtimeTranscription = "realtime-transcription"
    /// Image, audio or video understanding.
    case mediaUnderstanding = "media-understanding"
    /// Embeddings (upstream `embeddingProviders`, formerly `memoryEmbeddingProviders`).
    case embedding
    /// Web search.
    case webSearch = "web-search"
    /// Web page fetching.
    case webFetch = "web-fetch"
    /// Document extraction (for example PDF text extraction).
    case documentExtraction = "document-extractors"
    /// Web content extraction (for example Readability).
    case webContentExtraction = "web-content-extractors"
    /// Transcript sources (meeting or voice-channel transcripts).
    case transcriptSource = "transcript-source"
    /// Usage and quota reporting.
    case usage
    /// Provider-specific agent tools.
    case tool

    /// Deprecated spelling of ``embedding``.
    @available(*, deprecated, renamed: "embedding")
    public static var memoryEmbedding: ProviderCapability {
        .embedding
    }

    /// Accepted legacy and upstream spellings, keyed by lowercased value.
    public static let legacyAliases: [String: ProviderCapability] = [
        "memory-embedding": .embedding,
        "memory-embeddings": .embedding,
        "text-inference": .text,
        "tools": .tool,
    ]

    /// Resolves a raw capability identifier, accepting any casing and the legacy/upstream spellings.
    /// - Parameter raw: Raw identifier.
    public init?(normalizing raw: String) {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let capability = ProviderCapability(rawValue: key) {
            self = capability
        } else if let capability = Self.legacyAliases[key] {
            self = capability
        } else {
            return nil
        }
    }

    /// Decodes a capability, accepting legacy and upstream spellings.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let capability = ProviderCapability(normalizing: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown provider capability \(raw)")
        }
        self = capability
    }

    /// Decodes a capability list, dropping unknown values instead of failing.
    /// - Parameter raw: Raw identifiers.
    /// - Returns: Known capabilities in input order, without duplicates.
    public static func lossyList(_ raw: [String]) -> [ProviderCapability] {
        var seen: Set<ProviderCapability> = []
        return raw.compactMap(ProviderCapability.init(normalizing:)).filter { seen.insert($0).inserted }
    }
}

/// Lifecycle status of a provider catalog entry.
public enum ProviderCatalogStatus: String, Codable, Sendable, Equatable, CaseIterable {
    /// Supported provider.
    case available
    /// Kept for back-compat; see ``ProviderCatalogEntry/replacedBy``.
    case deprecated
}

/// How upstream distributes the plugin that owns a provider.
public enum ProviderDistribution: String, Codable, Sendable, Equatable, CaseIterable {
    /// Bundled with OpenClaw.
    case bundled
    /// Official plugin published as a separate package (npm/ClawHub) since OpenClaw 2026.8.1.
    case officialExternal = "official-external"
}

/// Canonical provider entry derived from the pinned OpenClaw reference snapshot.
public struct ProviderCatalogEntry: Sendable, Equatable {
    /// Stable provider identifier.
    public var providerID: String
    /// User-facing provider display name.
    public var displayName: String
    /// Additional provider aliases accepted by config and routing helpers.
    public var aliases: [String]
    /// Capability groups advertised for this provider entry.
    public var capabilities: [ProviderCapability]
    /// Default provider configuration used when synthesizing built-in providers.
    ///
    /// `config.models` lists every catalog row with the default model first.
    public var config: ModelProviderConfig
    /// Owning upstream plugin id (`nil` for SDK-local entries).
    public var pluginID: String?
    /// Capability-provider ids registered for capabilities whose id differs from ``providerID``
    /// (for example Google's `gemini` embedding id or xAI's `grok` web-search id).
    public var capabilityProviderIDs: [ProviderCapability: [String]]
    /// Environment variables that carry the provider credential, in lookup order.
    public var authEnvVars: [String]
    /// Environment variables used only for usage/billing APIs (for example `OPENAI_ADMIN_KEY`).
    public var usageAuthEnvVars: [String]
    /// Environment variables for plugin-owned auxiliary surfaces, keyed by setup id (for example `volcengine-tts`).
    public var auxiliaryAuthEnvVars: [String: [String]]
    /// Upstream auth method ids (`api-key`, `oauth`, `device-code`, `local`, `setup-token`, region variants, …).
    public var authMethods: [String]
    /// Upstream catalog discovery lifecycle.
    public var discovery: ModelCatalogDiscovery?
    /// Upstream documentation path (for example `/providers/openai`).
    public var docsPath: String?
    /// Provider lifecycle status.
    public var status: ProviderCatalogStatus
    /// Reason attached to a deprecated status.
    public var statusReason: String?
    /// Replacement provider id for deprecated entries.
    public var replacedBy: String?
    /// Upstream distribution of the owning plugin.
    public var distribution: ProviderDistribution
    /// Whether the entry is defined by OpenClawKit rather than an upstream plugin manifest.
    public var sdkLocal: Bool
    /// Full manifest catalog (every model row with context windows, thinking maps, compat and pricing).
    public var catalog: ModelCatalogProvider

    /// Creates one canonical provider catalog entry.
    public init(
        providerID: String,
        displayName: String,
        aliases: [String] = [],
        capabilities: [ProviderCapability] = [.text],
        config: ModelProviderConfig,
        pluginID: String? = nil,
        capabilityProviderIDs: [ProviderCapability: [String]] = [:],
        authEnvVars: [String] = [],
        usageAuthEnvVars: [String] = [],
        auxiliaryAuthEnvVars: [String: [String]] = [:],
        authMethods: [String] = [],
        discovery: ModelCatalogDiscovery? = nil,
        docsPath: String? = nil,
        status: ProviderCatalogStatus = .available,
        statusReason: String? = nil,
        replacedBy: String? = nil,
        distribution: ProviderDistribution = .bundled,
        sdkLocal: Bool = false,
        catalog: ModelCatalogProvider? = nil
    ) {
        self.providerID = providerID
        self.displayName = displayName
        self.aliases = aliases
        self.capabilities = capabilities.isEmpty ? [.text] : capabilities
        self.config = config
        self.pluginID = pluginID
        self.capabilityProviderIDs = capabilityProviderIDs
        self.authEnvVars = authEnvVars
        self.usageAuthEnvVars = usageAuthEnvVars
        self.auxiliaryAuthEnvVars = auxiliaryAuthEnvVars
        self.authMethods = authMethods
        self.discovery = discovery
        self.docsPath = docsPath
        self.status = status
        self.statusReason = statusReason
        self.replacedBy = replacedBy
        self.distribution = distribution
        self.sdkLocal = sdkLocal
        self.catalog = catalog ?? ModelCatalogProvider(
            baseURL: config.baseURL,
            api: config.api,
            headers: config.headers.isEmpty ? nil : config.headers,
            defaultModel: config.defaultModel?.id,
            models: config.models.map { ModelCatalogModel(definition: $0) }
        )
    }

    /// Provider-recommended primary model id.
    public var defaultModelID: String? {
        self.catalog.defaultModel ?? self.config.defaultModel?.id
    }

    /// Provider-recommended small model id for short internal utility tasks.
    public var defaultUtilityModelID: String? {
        self.catalog.defaultUtilityModel
    }

    /// Manifest model rows.
    public var models: [ModelCatalogModel] {
        self.catalog.models
    }

    /// Whether the provider only learns its models at runtime (no static rows).
    public var requiresDiscovery: Bool {
        self.catalog.models.isEmpty
    }

    /// Returns whether the entry advertises a capability.
    public func supports(_ capability: ProviderCapability) -> Bool {
        self.capabilities.contains(capability)
    }
}

/// Metadata for upstream provider plugins that are represented without native Swift runtime wiring.
public struct ProviderPluginMetadataEntry: Sendable, Equatable {
    /// Stable upstream provider or plugin identifier.
    public var providerID: String
    /// Human-facing label from the upstream plugin catalog.
    public var displayName: String
    /// Optional upstream documentation path.
    public var docsPath: String?
    /// Capability groups covered by this metadata entry.
    public var capabilities: [ProviderCapability]
    /// Whether OpenClawKit currently has a native runtime adapter for this provider.
    public var nativeRuntimeAvailable: Bool
    /// Owning upstream plugin id (`nil` for SDK-local entries).
    public var pluginID: String?
    /// Additional capability-provider ids registered by the plugin (for example `edge` for `microsoft`).
    public var aliases: [String]
    /// Environment variables that carry the credential, in lookup order.
    public var authEnvVars: [String]
    /// Upstream auth method ids.
    public var authMethods: [String]
    /// Upstream distribution of the owning plugin.
    public var distribution: ProviderDistribution
    /// Whether the entry is defined by OpenClawKit rather than an upstream plugin manifest.
    public var sdkLocal: Bool

    /// Creates one metadata entry for a provider-like upstream plugin.
    public init(
        providerID: String,
        displayName: String,
        docsPath: String? = nil,
        capabilities: [ProviderCapability],
        nativeRuntimeAvailable: Bool = false,
        pluginID: String? = nil,
        aliases: [String] = [],
        authEnvVars: [String] = [],
        authMethods: [String] = [],
        distribution: ProviderDistribution = .bundled,
        sdkLocal: Bool = false
    ) {
        self.providerID = providerID
        self.displayName = displayName
        self.docsPath = docsPath
        self.capabilities = capabilities
        self.nativeRuntimeAvailable = nativeRuntimeAvailable
        self.pluginID = pluginID
        self.aliases = aliases
        self.authEnvVars = authEnvVars
        self.authMethods = authMethods
        self.distribution = distribution
        self.sdkLocal = sdkLocal
    }
}

/// Shared provider catalog aligned with the pinned OpenClaw reference.
///
/// Entries are generated from upstream plugin manifests by `Scripts/provider-catalog-gen.mjs` (embedded in
/// `ProviderCatalogData.swift`) and decoded lazily on first access.
public enum OpenClawReferenceProviderCatalog {
    /// Upstream OpenClaw commit used to derive the built-in provider list.
    public static let referenceCommit = "eb377ac59e"
    /// Upstream OpenClaw release train of ``referenceCommit``.
    public static let referenceVersion = "2026.9.6"
    /// Upstream commit time of ``referenceCommit`` in milliseconds since the Unix epoch.
    public static let referenceGeneratedAt: Int64 = ProviderCatalogGeneratedData.generatedAt

    /// Canonical built-in provider entries exposed by the SDK.
    public static var entries: [ProviderCatalogEntry] {
        ProviderCatalogStore.shared.entries
    }

    /// Upstream provider-plugin metadata that is config-visible but not a native Swift text provider.
    public static var providerMetadataEntries: [ProviderPluginMetadataEntry] {
        ProviderCatalogStore.shared.metadataEntries
    }

    /// Normalizes a provider identifier or alias into the canonical built-in provider ID.
    ///
    /// Canonical ids win over aliases; unknown ids are returned trimmed and lowercased (upstream
    /// `normalizeProviderId`).
    public static func normalize(providerID: String) -> String {
        let normalized = providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let store = ProviderCatalogStore.shared
        if store.entriesByID[normalized] != nil {
            return normalized
        }
        if let alias = store.aliases[normalized] {
            return alias.provider
        }
        return normalized
    }

    /// Returns the built-in catalog entry for a provider identifier or alias.
    public static func entry(for providerID: String) -> ProviderCatalogEntry? {
        let normalized = normalize(providerID: providerID)
        guard let index = ProviderCatalogStore.shared.entriesByID[normalized] else { return nil }
        return ProviderCatalogStore.shared.entries[index]
    }

    /// Returns the metadata entry for a capability-provider id or one of its aliases.
    public static func metadataEntry(for providerID: String) -> ProviderPluginMetadataEntry? {
        let normalized = providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ProviderCatalogStore.shared.metadataEntries.first { entry in
            entry.providerID == normalized || entry.aliases.contains(normalized)
        }
    }

    /// Returns built-in provider configs keyed by their canonical identifier.
    public static func providerConfigsByID() -> [String: ModelProviderConfig] {
        entries.reduce(into: [:]) { partial, entry in
            partial[entry.providerID] = entry.config
        }
    }
}

extension ModelCatalogModel {
    /// Creates a catalog row from a runtime model definition.
    /// - Parameter definition: Runtime model definition.
    public init(definition: ModelDefinitionConfig) {
        self.init(
            id: definition.id,
            name: definition.name,
            api: definition.api,
            headers: definition.headers.isEmpty ? nil : definition.headers,
            input: definition.input,
            reasoning: definition.reasoning,
            contextWindow: definition.contextWindow > 0 ? definition.contextWindow : nil,
            maxTokens: definition.maxTokens > 0 ? definition.maxTokens : nil,
            cost: ModelCatalogCost(
                input: definition.cost.input,
                output: definition.cost.output,
                cacheRead: definition.cost.cacheRead,
                cacheWrite: definition.cost.cacheWrite
            )
        )
    }
}

/// Factory for constructing runtime providers from canonical provider catalog configs.
public enum ModelProviderFactory {
    /// Instantiates a model provider implementation for the given provider ID and config.
    public static func makeProvider(
        providerID: String,
        config: ModelProviderConfig
    ) throws -> any ModelProvider {
        let normalizedProviderID = OpenClawReferenceProviderCatalog.normalize(providerID: providerID)
        let legacy = config.legacyServiceConfig(providerID: normalizedProviderID)
        switch normalizedProviderID {
        case OpenAIModelProvider.providerID:
            return OpenAIModelProvider(
                configuration: OpenAIModelConfig(
                    enabled: config.enabled,
                    modelID: config.defaultModel?.id ?? "gpt-6-astra",
                    apiKey: config.apiKey,
                    baseURL: config.baseURL
                )
            )
        case OpenAICompatibleModelProvider.providerID:
            return OpenAICompatibleModelProvider(
                configuration: OpenAICompatibleModelConfig(
                    enabled: config.enabled,
                    modelID: config.defaultModel?.id ?? "gpt-4.1-mini",
                    apiKey: config.apiKey,
                    baseURL: config.baseURL,
                    chatCompletionsPath: config.chatCompletionsPath
                )
            )
        case AnthropicModelProvider.providerID:
            return AnthropicModelProvider(
                configuration: AnthropicModelConfig(
                    enabled: config.enabled,
                    modelID: config.defaultModel?.id ?? "claude-3-5-haiku-latest",
                    apiKey: config.apiKey,
                    baseURL: config.baseURL,
                    apiVersion: config.apiVersion ?? "2023-06-01",
                    maxTokens: config.defaultModel?.maxTokens ?? 8_192
                )
            )
        case GeminiModelProvider.providerID, "google", "google-vertex", "google-antigravity", "google-gemini-cli":
            return GoogleGenerativeAIModelProvider(id: normalizedProviderID, configuration: legacy)
        case FoundationModelsProvider.providerID, "apple-fm":
            return FoundationModelsProvider()
        case LocalModelProvider.providerID:
            return LocalModelProvider(
                configuration: LocalModelConfig(
                    enabled: config.enabled,
                    runtime: "llmfarm",
                    modelPath: nil
                ),
                engine: StubLocalModelEngine()
            )
        case XAIModelProvider.providerID, XAIModelProvider.grokAliasProviderID:
            return XAIModelProvider(id: normalizedProviderID, configuration: legacy)
        case MinimaxModelProvider.providerID:
            return MinimaxModelProvider(configuration: legacy)
        case MinimaxPortalModelProvider.providerID:
            return MinimaxPortalModelProvider(configuration: legacy)
        case SyntheticModelProvider.providerID:
            return SyntheticModelProvider(configuration: legacy)
        case XiaomiModelProvider.providerID where (config.defaultModel?.api ?? config.api) == .anthropicMessages:
            return XiaomiModelProvider(configuration: legacy)
        case CloudflareAIGatewayModelProvider.providerID:
            return CloudflareAIGatewayModelProvider(configuration: legacy)
        case VercelAIGatewayModelProvider.providerID:
            return VercelAIGatewayModelProvider(configuration: legacy)
        case BedrockConverseModelProvider.providerID:
            return BedrockConverseModelProvider(configuration: legacy)
        case GitHubCopilotModelProvider.providerID:
            return GitHubCopilotModelProvider(configuration: legacy)
        case OllamaModelProvider.providerID:
            return OllamaModelProvider(configuration: legacy)
        case VLLMModelProvider.providerID:
            return VLLMModelProvider(configuration: legacy)
        case QwenPortalModelProvider.providerID:
            return QwenPortalModelProvider(configuration: legacy)
        case OpenRouterModelProvider.providerID:
            return OpenRouterModelProvider(configuration: legacy)
        case GroqModelProvider.providerID:
            return GroqModelProvider(configuration: legacy)
        case MistralModelProvider.providerID:
            return MistralModelProvider(configuration: legacy)
        case CerebrasModelProvider.providerID:
            return CerebrasModelProvider(configuration: legacy)
        case MoonshotModelProvider.providerID:
            return MoonshotModelProvider(configuration: legacy)
        case LiteLLMModelProvider.providerID:
            return LiteLLMModelProvider(configuration: legacy)
        case TogetherModelProvider.providerID:
            return TogetherModelProvider(configuration: legacy)
        case HuggingFaceModelProvider.providerID:
            return HuggingFaceModelProvider(configuration: legacy)
        case QianfanModelProvider.providerID:
            return QianfanModelProvider(configuration: legacy)
        case NVIDIAModelProvider.providerID:
            return NVIDIAModelProvider(configuration: legacy)
        case ZAIModelProvider.providerID:
            return ZAIModelProvider(configuration: legacy)
        default:
            switch config.api ?? .openAICompletions {
            case .anthropicMessages:
                return ProviderServiceAnthropicModelProvider(id: normalizedProviderID, configuration: legacy)
            case .bedrockConverseStream:
                return BedrockConverseModelProvider(id: normalizedProviderID, configuration: legacy)
            case .githubCopilot:
                return GitHubCopilotModelProvider(id: normalizedProviderID, configuration: legacy)
            case .googleGenerativeAI, .googleVertex:
                return GoogleGenerativeAIModelProvider(id: normalizedProviderID, configuration: legacy)
            case .openAIResponses, .openAIChatGPTResponses, .azureOpenAIResponses:
                return OpenAIResponsesModelProvider(id: normalizedProviderID, configuration: legacy)
            case .piMessages:
                throw OpenClawCoreError.unavailable(
                    "The pi-messages transport is not implemented in OpenClawKit (provider \(normalizedProviderID))"
                )
            case .ollama:
                return OllamaModelProvider(id: normalizedProviderID, configuration: legacy)
            case .openAICompletions:
                return ProviderServiceOpenAIModelProvider(id: normalizedProviderID, configuration: legacy)
            }
        }
    }
}
