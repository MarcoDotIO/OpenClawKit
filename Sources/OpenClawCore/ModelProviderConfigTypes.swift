import Foundation

/// Merge behavior for TS-style provider catalogs.
public enum ModelsConfigMode: String, Codable, Sendable, Equatable, CaseIterable {
    case merge
    case replace
}

/// Canonical model API contract identifiers aligned with the TypeScript SDK.
public enum ModelAPI: String, Codable, Sendable, Equatable, CaseIterable {
    case openAICompletions = "openai-completions"
    case openAIResponses = "openai-responses"
    case openAICodexResponses = "openai-codex-responses"
    case anthropicMessages = "anthropic-messages"
    case googleGenerativeAI = "google-generative-ai"
    case githubCopilot = "github-copilot"
    case bedrockConverseStream = "bedrock-converse-stream"
    case ollama
}

/// Authentication modes supported by canonical model-provider configs.
public enum ModelProviderAuthMode: String, Codable, Sendable, Equatable, CaseIterable {
    case apiKey = "api-key"
    case awsSDK = "aws-sdk"
    case oauth
    case token
}

/// Input modality flags declared by model definitions.
public enum ModelInputType: String, Codable, Sendable, Equatable, CaseIterable {
    case text
    case image
}

/// Compatibility field used by some providers when specifying max-token limits.
public enum ModelCompatMaxTokensField: String, Codable, Sendable, Equatable, CaseIterable {
    case maxCompletionTokens = "max_completion_tokens"
    case maxTokens = "max_tokens"
}

/// Thinking payload format used by reasoning providers.
public enum ModelCompatThinkingFormat: String, Codable, Sendable, Equatable, CaseIterable {
    case openAI = "openai"
    case zai
    case qwen
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
        self.api = try container.decodeIfPresent(ModelAPI.self, forKey: .api)
        self.reasoning = try container.decodeIfPresent(Bool.self, forKey: .reasoning) ?? false
        self.input = try container.decodeIfPresent([ModelInputType].self, forKey: .input) ?? [.text]
        self.cost = try container.decodeIfPresent(ModelCostConfig.self, forKey: .cost) ?? ModelCostConfig()
        self.contextWindow = max(0, try container.decodeIfPresent(Int.self, forKey: .contextWindow) ?? 0)
        self.maxTokens = max(0, try container.decodeIfPresent(Int.self, forKey: .maxTokens) ?? 0)
        self.headers = try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        self.compat = try container.decodeIfPresent(ModelCompatConfig.self, forKey: .compat)
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
        let legacyAPIStyle = try legacyContainer.decodeIfPresent(ProviderServiceAPIStyle.self, forKey: .apiStyle)
        let legacyAuthMode = try legacyContainer.decodeIfPresent(ProviderServiceAuthMode.self, forKey: .authMode)
        let legacyModelID = try legacyContainer.decodeIfPresent(String.self, forKey: .modelID)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let legacyAccessToken = try legacyContainer.decodeIfPresent(String.self, forKey: .accessToken)

        let resolvedAPI = try container.decodeIfPresent(ModelAPI.self, forKey: .api)
            ?? legacyAPIStyle.map(ModelAPI.init(legacyStyle:))
        let resolvedAuth = try container.decodeIfPresent(ModelProviderAuthMode.self, forKey: .auth)
            ?? legacyAuthMode.flatMap(ModelProviderAuthMode.init(legacyMode:))
        let resolvedHeaders = try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        let decodedModels = try container.decodeIfPresent([ModelDefinitionConfig].self, forKey: .models) ?? []
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
        case .openAICompletions, .openAIResponses, .openAICodexResponses, .githubCopilot:
            return .openAICompletions
        case .anthropicMessages:
            return .anthropicMessages
        case .googleGenerativeAI:
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
