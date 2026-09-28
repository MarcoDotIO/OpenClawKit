import Foundation

/// Merge behavior for TS-style provider catalogs.
public enum ModelsConfigMode: String, Codable, Sendable, Equatable, CaseIterable {
    case merge
    case replace
}

/// Canonical model API contract identifiers aligned with upstream `MODEL_DATA_APIS`
/// (`packages/llm-core/src/model-data.ts`).
///
/// Decoding accepts legacy identifiers and maps them to their canonical replacement:
/// `openai-codex-responses` (removed upstream) becomes ``openAIChatGPTResponses`` and `openai`
/// (doctor migration for `models.providers.*.api`) becomes ``openAICompletions``. Encoding always
/// writes the canonical identifier. Config containers decode this field leniently: an unknown
/// identifier yields `nil` plus a ``ConfigDecodeIssue`` instead of failing the whole config.
///
/// - Note: 2026.3.0 added `openai-chatgpt-responses`, `google-vertex`, `pi-messages` and
///   `azure-openai-responses`. Exhaustive `switch` statements over `ModelAPI` need the new cases.
public enum ModelAPI: String, Codable, Sendable, Equatable, CaseIterable {
    /// OpenAI Chat Completions compatible API.
    case openAICompletions = "openai-completions"
    /// OpenAI Responses API.
    case openAIResponses = "openai-responses"
    /// OpenAI Responses API through the ChatGPT (OAuth) route. Replaces `openai-codex-responses`.
    case openAIChatGPTResponses = "openai-chatgpt-responses"
    /// Anthropic Messages API.
    case anthropicMessages = "anthropic-messages"
    /// Google Generative Language (Gemini) API.
    case googleGenerativeAI = "google-generative-ai"
    /// Google Vertex AI API.
    case googleVertex = "google-vertex"
    /// GitHub Copilot API.
    case githubCopilot = "github-copilot"
    /// Amazon Bedrock Converse streaming API.
    case bedrockConverseStream = "bedrock-converse-stream"
    /// Ollama native API.
    case ollama
    /// Pi messages API.
    case piMessages = "pi-messages"
    /// Azure OpenAI Responses API.
    case azureOpenAIResponses = "azure-openai-responses"

    /// Removed `openai-codex-responses` identifier; it now resolves to ``openAIChatGPTResponses``.
    @available(*, deprecated, renamed: "openAIChatGPTResponses")
    public static var openAICodexResponses: ModelAPI {
        .openAIChatGPTResponses
    }

    /// Legacy identifiers accepted while decoding, keyed by the lowercased legacy value.
    public static let legacyAliases: [String: ModelAPI] = [
        "openai-codex-responses": .openAIChatGPTResponses,
        "openai": .openAICompletions,
    ]

    /// Resolves a raw identifier, accepting surrounding whitespace, any casing, and legacy aliases.
    /// - Parameter raw: Raw identifier from config or the wire.
    public init?(normalizing raw: String) {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let api = ModelAPI(rawValue: key) {
            self = api
        } else if let api = Self.legacyAliases[key] {
            self = api
        } else {
            return nil
        }
    }

    /// Returns the upstream validation message for a legacy identifier, or `nil` when the value is
    /// not a legacy identifier.
    /// - Parameter raw: Raw identifier from config.
    /// - Returns: Migration guidance for legacy identifiers.
    public static func legacyValidationMessage(for raw: String) -> String? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let replacement = Self.legacyAliases[key] else { return nil }
        if key == "openai-codex-responses" {
            return "\"openai-codex-responses\" is a removed api id; use \"\(replacement.rawValue)\""
        }
        return "\"\(key)\" is a legacy api id; use \"\(replacement.rawValue)\""
    }

    /// Decodes an identifier, accepting legacy aliases.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let api = ModelAPI(normalizing: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown model api \"\(raw)\""
            )
        }
        self = api
    }

    /// Decodes an optional `api` field leniently, recording unknown and legacy identifiers.
    static func decodeLenient<K: CodingKey>(from container: KeyedDecodingContainer<K>, forKey key: K) -> ModelAPI? {
        guard let raw = container.decodeLenient(String.self, forKey: key) else {
            return nil
        }
        guard let api = ModelAPI(normalizing: raw) else {
            container.recordConfigIssue(
                "Unknown model api \"\(raw)\"; the value is ignored.",
                kind: .unknownEnumValue,
                forKey: key
            )
            return nil
        }
        if let message = Self.legacyValidationMessage(for: raw) {
            container.recordConfigIssue(message, kind: .legacyKey, forKey: key)
        }
        return api
    }
}

/// Authentication modes supported by canonical model-provider configs.
public enum ModelProviderAuthMode: String, Codable, Sendable, Equatable, CaseIterable {
    case apiKey = "api-key"
    case awsSDK = "aws-sdk"
    case oauth
    case token
}

/// Input modality flags declared by model definitions.
///
/// Config decoders drop unknown modality strings instead of failing (see ``ConfigDecodeIssue``).
///
/// - Note: 2026.3.0 added `video`, `audio` and `document`. `document` appears in catalog rows
///   only; runtimes filter it out of provider requests.
public enum ModelInputType: String, Codable, Sendable, Equatable, CaseIterable {
    /// Text input.
    case text
    /// Image input.
    case image
    /// Video input.
    case video
    /// Audio input.
    case audio
    /// Document input (catalog metadata only).
    case document
}

/// Compatibility field used by some providers when specifying max-token limits.
public enum ModelCompatMaxTokensField: String, Codable, Sendable, Equatable, CaseIterable {
    case maxCompletionTokens = "max_completion_tokens"
    case maxTokens = "max_tokens"
}

/// Thinking payload format used by reasoning providers (upstream `MODEL_DATA_THINKING_FORMATS`).
///
/// An unknown value decodes to `nil` plus a ``ConfigDecodeIssue``.
public enum ModelCompatThinkingFormat: String, Codable, Sendable, Equatable, CaseIterable {
    /// OpenAI reasoning payloads.
    case openAI = "openai"
    /// Z.AI thinking payloads.
    case zai
    /// Qwen thinking payloads.
    case qwen
    /// OpenRouter reasoning payloads.
    case openrouter
    /// DeepSeek reasoning payloads.
    case deepseek
    /// Together reasoning payloads.
    case together
    /// Qwen chat-template thinking switch.
    case qwenChatTemplate = "qwen-chat-template"
}

/// Provider-specific compatibility flags carried alongside model definitions.
public struct ModelCompatConfig: Codable, Sendable, Equatable {
    public var supportsStore: Bool?
    public var supportsDeveloperRole: Bool?
    public var supportsReasoningEffort: Bool?
    public var supportsUsageInStreaming: Bool?
    public var supportsTools: Bool?
    public var supportsStrictMode: Bool?
    public var maxTokensField: ModelCompatMaxTokensField?
    public var thinkingFormat: ModelCompatThinkingFormat?
    public var requiresToolResultName: Bool?
    public var requiresAssistantAfterToolResult: Bool?
    public var requiresThinkingAsText: Bool?
    public var requiresMistralToolIDs: Bool?
    public var requiresOpenAIAnthropicToolPayload: Bool?

    public init(
        supportsStore: Bool? = nil,
        supportsDeveloperRole: Bool? = nil,
        supportsReasoningEffort: Bool? = nil,
        supportsUsageInStreaming: Bool? = nil,
        supportsTools: Bool? = nil,
        supportsStrictMode: Bool? = nil,
        maxTokensField: ModelCompatMaxTokensField? = nil,
        thinkingFormat: ModelCompatThinkingFormat? = nil,
        requiresToolResultName: Bool? = nil,
        requiresAssistantAfterToolResult: Bool? = nil,
        requiresThinkingAsText: Bool? = nil,
        requiresMistralToolIDs: Bool? = nil,
        requiresOpenAIAnthropicToolPayload: Bool? = nil
    ) {
        self.supportsStore = supportsStore
        self.supportsDeveloperRole = supportsDeveloperRole
        self.supportsReasoningEffort = supportsReasoningEffort
        self.supportsUsageInStreaming = supportsUsageInStreaming
        self.supportsTools = supportsTools
        self.supportsStrictMode = supportsStrictMode
        self.maxTokensField = maxTokensField
        self.thinkingFormat = thinkingFormat
        self.requiresToolResultName = requiresToolResultName
        self.requiresAssistantAfterToolResult = requiresAssistantAfterToolResult
        self.requiresThinkingAsText = requiresThinkingAsText
        self.requiresMistralToolIDs = requiresMistralToolIDs
        self.requiresOpenAIAnthropicToolPayload = requiresOpenAIAnthropicToolPayload
    }

    private enum CodingKeys: String, CodingKey {
        case supportsStore
        case supportsDeveloperRole
        case supportsReasoningEffort
        case supportsUsageInStreaming
        case supportsTools
        case supportsStrictMode
        case maxTokensField
        case thinkingFormat
        case requiresToolResultName
        case requiresAssistantAfterToolResult
        case requiresThinkingAsText
        case requiresMistralToolIDs
        case requiresOpenAIAnthropicToolPayload
    }

    /// Decodes compat flags; unknown `maxTokensField`/`thinkingFormat` values decode to `nil`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.supportsStore = try container.decodeIfPresent(Bool.self, forKey: .supportsStore)
        self.supportsDeveloperRole = try container.decodeIfPresent(Bool.self, forKey: .supportsDeveloperRole)
        self.supportsReasoningEffort = try container.decodeIfPresent(Bool.self, forKey: .supportsReasoningEffort)
        self.supportsUsageInStreaming = try container.decodeIfPresent(Bool.self, forKey: .supportsUsageInStreaming)
        self.supportsTools = try container.decodeIfPresent(Bool.self, forKey: .supportsTools)
        self.supportsStrictMode = try container.decodeIfPresent(Bool.self, forKey: .supportsStrictMode)
        self.maxTokensField = container.decodeLenient(ModelCompatMaxTokensField.self, forKey: .maxTokensField)
        self.thinkingFormat = container.decodeLenient(ModelCompatThinkingFormat.self, forKey: .thinkingFormat)
        self.requiresToolResultName = try container.decodeIfPresent(Bool.self, forKey: .requiresToolResultName)
        self.requiresAssistantAfterToolResult = try container.decodeIfPresent(Bool.self, forKey: .requiresAssistantAfterToolResult)
        self.requiresThinkingAsText = try container.decodeIfPresent(Bool.self, forKey: .requiresThinkingAsText)
        self.requiresMistralToolIDs = try container.decodeIfPresent(Bool.self, forKey: .requiresMistralToolIDs)
        self.requiresOpenAIAnthropicToolPayload = try container.decodeIfPresent(
            Bool.self,
            forKey: .requiresOpenAIAnthropicToolPayload
        )
    }
}

/// Cost metadata associated with one model definition.
public struct ModelCostConfig: Codable, Sendable, Equatable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheWrite: Double

    public init(
        input: Double = 0,
        output: Double = 0,
        cacheRead: Double = 0,
        cacheWrite: Double = 0
    ) {
        self.input = max(0, input)
        self.output = max(0, output)
        self.cacheRead = max(0, cacheRead)
        self.cacheWrite = max(0, cacheWrite)
    }

    private enum CodingKeys: String, CodingKey {
        case input
        case output
        case cacheRead
        case cacheWrite
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.input = max(0, try container.decodeIfPresent(Double.self, forKey: .input) ?? 0)
        self.output = max(0, try container.decodeIfPresent(Double.self, forKey: .output) ?? 0)
        self.cacheRead = max(0, try container.decodeIfPresent(Double.self, forKey: .cacheRead) ?? 0)
        self.cacheWrite = max(0, try container.decodeIfPresent(Double.self, forKey: .cacheWrite) ?? 0)
    }
}

/// Canonical model definition block aligned with the TS provider catalog.
public struct ModelDefinitionConfig: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var api: ModelAPI?
    public var fastMode: Bool?
    public var reasoning: Bool
    public var input: [ModelInputType]
    public var cost: ModelCostConfig
    public var contextWindow: Int
    public var maxTokens: Int
    public var headers: [String: String]
    public var compat: ModelCompatConfig?

    public init(
        id: String,
        name: String? = nil,
        api: ModelAPI? = nil,
        fastMode: Bool? = nil,
        reasoning: Bool = false,
        input: [ModelInputType] = [.text],
        cost: ModelCostConfig = ModelCostConfig(),
        contextWindow: Int = 0,
        maxTokens: Int = 0,
        headers: [String: String] = [:],
        compat: ModelCompatConfig? = nil
    ) {
        self.id = id
        self.name = name ?? id
        self.api = api
        self.fastMode = fastMode
        self.reasoning = reasoning
        self.input = input.isEmpty ? [.text] : input
        self.cost = cost
        self.contextWindow = max(0, contextWindow)
        self.maxTokens = max(0, maxTokens)
        self.headers = headers
        self.compat = compat
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case api
        case fastMode
        case reasoning
        case input
        case cost
        case contextWindow
        case maxTokens
        case headers
        case compat
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        self.id = id
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? id
        self.api = ModelAPI.decodeLenient(from: container, forKey: .api)
        self.fastMode = try container.decodeIfPresent(Bool.self, forKey: .fastMode)
        self.reasoning = try container.decodeIfPresent(Bool.self, forKey: .reasoning) ?? false
        self.input = container.decodeLossyArrayIfPresent(ModelInputType.self, forKey: .input) ?? [.text]
        self.cost = try container.decodeIfPresent(ModelCostConfig.self, forKey: .cost) ?? ModelCostConfig()
        self.contextWindow = max(0, try container.decodeIfPresent(Int.self, forKey: .contextWindow) ?? 0)
        self.maxTokens = max(0, try container.decodeIfPresent(Int.self, forKey: .maxTokens) ?? 0)
        self.headers = try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        self.compat = container.decodeLenient(ModelCompatConfig.self, forKey: .compat)
    }
}

/// Canonical provider config aligned with the TS SDK provider catalog.
public struct ModelProviderConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var baseURL: String
    public var apiKey: String?
    public var auth: ModelProviderAuthMode?
    public var api: ModelAPI?
    public var injectNumCtxForOpenAICompat: Bool
    public var headers: [String: String]
    public var authHeader: Bool?
    public var models: [ModelDefinitionConfig]
    public var chatCompletionsPath: String
    public var messagesPath: String
    public var apiVersion: String?
    public var organizationID: String?
    public var region: String?
    public var profile: String?
    public var tenantID: String?
    public var scope: String?
    public var metadata: [String: String]

    public init(
        enabled: Bool = false,
        baseURL: String = "https://api.openai.com/v1",
        apiKey: String? = nil,
        auth: ModelProviderAuthMode? = .apiKey,
        api: ModelAPI? = .openAICompletions,
        injectNumCtxForOpenAICompat: Bool = false,
        headers: [String: String] = [:],
        authHeader: Bool? = nil,
        models: [ModelDefinitionConfig] = [],
        chatCompletionsPath: String = "chat/completions",
        messagesPath: String = "messages",
        apiVersion: String? = nil,
        organizationID: String? = nil,
        region: String? = nil,
        profile: String? = nil,
        tenantID: String? = nil,
        scope: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.enabled = enabled
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.auth = auth
        self.api = api
        self.injectNumCtxForOpenAICompat = injectNumCtxForOpenAICompat
        self.headers = headers
        self.authHeader = authHeader
        self.models = models
        self.chatCompletionsPath = chatCompletionsPath
        self.messagesPath = messagesPath
        self.apiVersion = apiVersion
        self.organizationID = organizationID
        self.region = region
        self.profile = profile
        self.tenantID = tenantID
        self.scope = scope
        self.metadata = metadata
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case baseURL
        case apiKey
        case auth
        case api
        case injectNumCtxForOpenAICompat
        case headers
        case authHeader
        case models
        case chatCompletionsPath
        case messagesPath
        case apiVersion
        case organizationID
        case region
        case profile
        case tenantID
        case scope
        case metadata
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case apiStyle
        case authMode
        case modelID
        case accessToken
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let legacyContainer = try decoder.container(keyedBy: LegacyCodingKeys.self)
        let legacyAPIStyle = legacyContainer.decodeLenient(ProviderServiceAPIStyle.self, forKey: .apiStyle)
        let legacyAuthMode = legacyContainer.decodeLenient(ProviderServiceAuthMode.self, forKey: .authMode)
        let legacyModelID = try legacyContainer.decodeIfPresent(String.self, forKey: .modelID)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let legacyAccessToken = try legacyContainer.decodeIfPresent(String.self, forKey: .accessToken)

        let resolvedAPI = ModelAPI.decodeLenient(from: container, forKey: .api)
            ?? legacyAPIStyle.map(ModelAPI.init(legacyStyle:))
        let resolvedAuth = container.decodeLenient(ModelProviderAuthMode.self, forKey: .auth)
            ?? legacyAuthMode.flatMap(ModelProviderAuthMode.init(legacyMode:))
        let resolvedHeaders = try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        let decodedModels = container.decodeLossyArrayIfPresent(ModelDefinitionConfig.self, forKey: .models) ?? []
        let fallbackModelID = legacyModelID.flatMap { $0.isEmpty ? nil : $0 }

        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        self.baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? "https://api.openai.com/v1"
        self.apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? legacyAccessToken
        self.auth = resolvedAuth
        self.api = resolvedAPI
        self.injectNumCtxForOpenAICompat = try container.decodeIfPresent(Bool.self, forKey: .injectNumCtxForOpenAICompat)
            ?? false
        self.headers = resolvedHeaders
        self.authHeader = try container.decodeIfPresent(Bool.self, forKey: .authHeader)
            ?? (legacyAuthMode == ProviderServiceAuthMode.none ? false : nil)
        if !decodedModels.isEmpty {
            self.models = decodedModels
        } else if let fallbackModelID {
            self.models = [
                ModelDefinitionConfig(
                    id: fallbackModelID,
                    api: resolvedAPI,
                    headers: resolvedHeaders
                ),
            ]
        } else {
            self.models = []
        }
        self.chatCompletionsPath = try container.decodeIfPresent(String.self, forKey: .chatCompletionsPath)
            ?? "chat/completions"
        self.messagesPath = try container.decodeIfPresent(String.self, forKey: .messagesPath) ?? "messages"
        self.apiVersion = try container.decodeIfPresent(String.self, forKey: .apiVersion)
        self.organizationID = try container.decodeIfPresent(String.self, forKey: .organizationID)
        self.region = try container.decodeIfPresent(String.self, forKey: .region)
        self.profile = try container.decodeIfPresent(String.self, forKey: .profile)
        self.tenantID = try container.decodeIfPresent(String.self, forKey: .tenantID)
        self.scope = try container.decodeIfPresent(String.self, forKey: .scope)
        self.metadata = try container.decodeIfPresent([String: String].self, forKey: .metadata) ?? [:]
    }

    /// Default model selection used by provider factories.
    public var defaultModel: ModelDefinitionConfig? {
        self.models.first
    }
}

/// Bedrock discovery settings aligned with the TS SDK.
public struct BedrockDiscoveryConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var region: String?
    public var providerFilter: [String]
    public var refreshInterval: Int?
    public var defaultContextWindow: Int?
    public var defaultMaxTokens: Int?

    public init(
        enabled: Bool = false,
        region: String? = nil,
        providerFilter: [String] = [],
        refreshInterval: Int? = nil,
        defaultContextWindow: Int? = nil,
        defaultMaxTokens: Int? = nil
    ) {
        self.enabled = enabled
        self.region = region
        self.providerFilter = providerFilter
        self.refreshInterval = refreshInterval.map { max(1, $0) }
        self.defaultContextWindow = defaultContextWindow.map { max(1, $0) }
        self.defaultMaxTokens = defaultMaxTokens.map { max(1, $0) }
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case region
        case providerFilter
        case refreshInterval
        case defaultContextWindow
        case defaultMaxTokens
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        self.region = try container.decodeIfPresent(String.self, forKey: .region)
        self.providerFilter = try container.decodeIfPresent([String].self, forKey: .providerFilter) ?? []
        self.refreshInterval = try container.decodeIfPresent(Int.self, forKey: .refreshInterval).map { max(1, $0) }
        self.defaultContextWindow = try container.decodeIfPresent(Int.self, forKey: .defaultContextWindow).map { max(1, $0) }
        self.defaultMaxTokens = try container.decodeIfPresent(Int.self, forKey: .defaultMaxTokens).map { max(1, $0) }
    }
}

extension ModelProviderAuthMode {
    init?(legacyMode: ProviderServiceAuthMode) {
        switch legacyMode {
        case .apiKey:
            self = .apiKey
        case .bearerToken:
            self = .token
        case .oauthToken:
            self = .oauth
        case .awsSDK:
            self = .awsSDK
        case .none:
            return nil
        }
    }

    var legacyMode: ProviderServiceAuthMode {
        switch self {
        case .apiKey:
            return .apiKey
        case .awsSDK:
            return .awsSDK
        case .oauth:
            return .oauthToken
        case .token:
            return .bearerToken
        }
    }
}

extension ModelAPI {
    init(legacyStyle: ProviderServiceAPIStyle) {
        switch legacyStyle {
        case .openAICompletions, .custom:
            self = .openAICompletions
        case .anthropicMessages:
            self = .anthropicMessages
        case .bedrockConverse:
            self = .bedrockConverseStream
        case .ollama:
            self = .ollama
        }
    }

    var legacyStyle: ProviderServiceAPIStyle {
        switch self {
        case .openAICompletions, .openAIResponses, .openAIChatGPTResponses, .azureOpenAIResponses, .githubCopilot:
            return .openAICompletions
        case .anthropicMessages:
            return .anthropicMessages
        case .googleGenerativeAI, .googleVertex, .piMessages:
            return .custom
        case .bedrockConverseStream:
            return .bedrockConverse
        case .ollama:
            return .ollama
        }
    }
}

extension ModelProviderConfig {
    /// Creates a canonical provider config from the legacy provider-service shape.
    public init(legacyService: ProviderServiceConfig) {
        let defaultAPI = ModelAPI(legacyStyle: legacyService.apiStyle)
        let defaultModel = ModelDefinitionConfig(
            id: legacyService.modelID,
            api: defaultAPI,
            fastMode: legacyService.fastMode,
            headers: legacyService.headers
        )
        self.init(
            enabled: legacyService.enabled,
            baseURL: legacyService.baseURL,
            apiKey: legacyService.apiKey ?? legacyService.accessToken,
            auth: ModelProviderAuthMode(legacyMode: legacyService.authMode),
            api: defaultAPI,
            headers: legacyService.headers,
            authHeader: legacyService.authMode == .none ? false : nil,
            models: legacyService.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [defaultModel],
            chatCompletionsPath: legacyService.chatCompletionsPath,
            messagesPath: legacyService.messagesPath,
            apiVersion: legacyService.apiVersion,
            organizationID: legacyService.organizationID,
            region: legacyService.region,
            profile: legacyService.profile,
            tenantID: legacyService.tenantID,
            scope: legacyService.scope,
            metadata: legacyService.metadata
        )
    }

    /// Bridges the canonical provider config back into the legacy runtime shape.
    public func legacyServiceConfig(providerID: String) -> ProviderServiceConfig {
        let normalizedProviderID = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = self.defaultModel
        let authMode = self.auth?.legacyMode ?? .none
        let selectedAPI = model?.api ?? self.api ?? .openAICompletions
        let secretValue = self.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let usesAccessToken = authMode == .bearerToken || authMode == .oauthToken
        return ProviderServiceConfig(
            enabled: self.enabled,
            apiStyle: selectedAPI.legacyStyle,
            authMode: authMode,
            modelID: model?.id ?? "gpt-4.1-mini",
            fastMode: model?.fastMode,
            apiKey: usesAccessToken ? nil : secretValue,
            accessToken: usesAccessToken ? secretValue : nil,
            baseURL: self.baseURL,
            chatCompletionsPath: self.chatCompletionsPath,
            messagesPath: self.messagesPath,
            apiVersion: self.apiVersion,
            organizationID: self.organizationID,
            headers: self.mergedHeaders(for: model),
            region: self.region,
            profile: self.profile,
            tenantID: self.tenantID,
            scope: self.scope,
            metadata: self.metadata.merging([
                "providerID": normalizedProviderID,
            ]) { current, _ in current }
        )
    }

    private func mergedHeaders(for model: ModelDefinitionConfig?) -> [String: String] {
        guard let model else {
            return self.headers
        }
        return self.headers.merging(model.headers) { _, modelValue in modelValue }
    }
}
