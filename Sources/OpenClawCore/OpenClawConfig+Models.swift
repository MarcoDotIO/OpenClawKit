import Foundation

/// Model routing and provider settings.
public struct ModelsConfig: Codable, Sendable, Equatable {
    public var defaultProviderID: String
    public var systemPrompt: String?
    public var mode: ModelsConfigMode
    public var openAI: OpenAIModelConfig
    public var openAICompatible: OpenAICompatibleModelConfig
    public var anthropic: AnthropicModelConfig
    public var gemini: GeminiModelConfig
    public var foundation: FoundationModelConfig
    public var local: LocalModelConfig
    public var providers: [String: ModelProviderConfig]
    public var bedrockDiscovery: BedrockDiscoveryConfig

    /// Creates model settings.
    /// - Parameters:
    ///   - defaultProviderID: Default provider ID when none is specified.
    ///   - systemPrompt: Optional system prompt prefix.
    ///   - openAI: OpenAI provider settings.
    ///   - openAICompatible: Generic OpenAI-compatible provider settings.
    ///   - anthropic: Anthropic provider settings.
    ///   - gemini: Gemini provider settings.
    ///   - foundation: Foundation Models settings.
    ///   - local: Local model settings.
    ///   - providers: Extended provider service matrix keyed by provider ID.
    public init(
        defaultProviderID: String = "echo",
        systemPrompt: String? = nil,
        mode: ModelsConfigMode = .merge,
        openAI: OpenAIModelConfig = OpenAIModelConfig(),
        openAICompatible: OpenAICompatibleModelConfig = OpenAICompatibleModelConfig(),
        anthropic: AnthropicModelConfig = AnthropicModelConfig(),
        gemini: GeminiModelConfig = GeminiModelConfig(),
        foundation: FoundationModelConfig = FoundationModelConfig(),
        local: LocalModelConfig = LocalModelConfig(),
        providers: [String: ModelProviderConfig] = [:],
        bedrockDiscovery: BedrockDiscoveryConfig = BedrockDiscoveryConfig()
    ) {
        self.defaultProviderID = defaultProviderID
        self.systemPrompt = systemPrompt
        self.mode = mode
        self.openAI = openAI
        self.openAICompatible = openAICompatible
        self.anthropic = anthropic
        self.gemini = gemini
        self.foundation = foundation
        self.local = local
        self.providers = providers
        self.bedrockDiscovery = bedrockDiscovery
    }

    @available(*, deprecated, message: "Use ModelProviderConfig-based providers instead")
    public init(
        defaultProviderID: String = "echo",
        systemPrompt: String? = nil,
        mode: ModelsConfigMode = .merge,
        openAI: OpenAIModelConfig = OpenAIModelConfig(),
        openAICompatible: OpenAICompatibleModelConfig = OpenAICompatibleModelConfig(),
        anthropic: AnthropicModelConfig = AnthropicModelConfig(),
        gemini: GeminiModelConfig = GeminiModelConfig(),
        foundation: FoundationModelConfig = FoundationModelConfig(),
        local: LocalModelConfig = LocalModelConfig(),
        providers legacyProviders: [String: ProviderServiceConfig],
        bedrockDiscovery: BedrockDiscoveryConfig = BedrockDiscoveryConfig()
    ) {
        self.init(
            defaultProviderID: defaultProviderID,
            systemPrompt: systemPrompt,
            mode: mode,
            openAI: openAI,
            openAICompatible: openAICompatible,
            anthropic: anthropic,
            gemini: gemini,
            foundation: foundation,
            local: local,
            providers: legacyProviders.mapValues { ModelProviderConfig(legacyService: $0) },
            bedrockDiscovery: bedrockDiscovery
        )
    }

    private enum CodingKeys: String, CodingKey {
        case defaultProviderID
        case systemPrompt
        case mode
        case openAI
        case openAICompatible
        case anthropic
        case gemini
        case foundation
        case local
        case providers
        case bedrockDiscovery
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.defaultProviderID = try container.decodeIfPresent(String.self, forKey: .defaultProviderID) ?? "echo"
        self.systemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt)
        self.mode = container.decodeLenient(ModelsConfigMode.self, forKey: .mode) ?? .merge
        self.openAI = try container.decodeIfPresent(OpenAIModelConfig.self, forKey: .openAI) ?? OpenAIModelConfig()
        self.openAICompatible = try container.decodeIfPresent(OpenAICompatibleModelConfig.self, forKey: .openAICompatible) ?? OpenAICompatibleModelConfig()
        self.anthropic = try container.decodeIfPresent(AnthropicModelConfig.self, forKey: .anthropic) ?? AnthropicModelConfig()
        self.gemini = try container.decodeIfPresent(GeminiModelConfig.self, forKey: .gemini) ?? GeminiModelConfig()
        self.foundation = try container.decodeIfPresent(FoundationModelConfig.self, forKey: .foundation) ?? FoundationModelConfig()
        self.local = try container.decodeIfPresent(LocalModelConfig.self, forKey: .local) ?? LocalModelConfig()
        do {
            self.providers = try container.decodeIfPresent([String: ModelProviderConfig].self, forKey: .providers) ?? [:]
        } catch {
            let legacyProviders = try container.decodeIfPresent([String: ProviderServiceConfig].self, forKey: .providers) ?? [:]
            self.providers = legacyProviders.mapValues { ModelProviderConfig(legacyService: $0) }
        }
        self.bedrockDiscovery = try container.decodeIfPresent(BedrockDiscoveryConfig.self, forKey: .bedrockDiscovery)
            ?? BedrockDiscoveryConfig()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.defaultProviderID, forKey: .defaultProviderID)
        try container.encodeIfPresent(self.systemPrompt, forKey: .systemPrompt)
        try container.encode(self.mode, forKey: .mode)
        try container.encode(self.openAI, forKey: .openAI)
        try container.encode(self.openAICompatible, forKey: .openAICompatible)
        try container.encode(self.anthropic, forKey: .anthropic)
        try container.encode(self.gemini, forKey: .gemini)
        try container.encode(self.foundation, forKey: .foundation)
        try container.encode(self.local, forKey: .local)
        try container.encode(self.providers, forKey: .providers)
        try container.encode(self.bedrockDiscovery, forKey: .bedrockDiscovery)
    }

    @available(*, deprecated, message: "Use providers instead")
    public var providerServices: [String: ProviderServiceConfig] {
        self.providers.reduce(into: [:]) { partial, entry in
            partial[entry.key] = entry.value.legacyServiceConfig(providerID: entry.key)
        }
    }

    public func legacyProviderServiceConfig(for providerID: String) -> ProviderServiceConfig? {
        self.providers[providerID]?.legacyServiceConfig(providerID: providerID)
    }
}

/// API contract style used by an extended provider service.
public enum ProviderServiceAPIStyle: String, Codable, Sendable, Equatable, CaseIterable {
    case openAICompletions
    case anthropicMessages
    case bedrockConverse
    case ollama
    case custom
}

/// Authentication mode used by an extended provider service.
public enum ProviderServiceAuthMode: String, Codable, Sendable, Equatable, CaseIterable {
    case apiKey
    case bearerToken
    case oauthToken
    case awsSDK
    case none
}

/// Extended provider service configuration used for parity provider matrices.
public struct ProviderServiceConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var apiStyle: ProviderServiceAPIStyle
    public var authMode: ProviderServiceAuthMode
    public var modelID: String
    public var fastMode: Bool?
    public var apiKey: String?
    public var accessToken: String?
    public var baseURL: String
    public var chatCompletionsPath: String
    public var messagesPath: String
    public var apiVersion: String?
    public var organizationID: String?
    public var headers: [String: String]
    public var region: String?
    public var profile: String?
    public var tenantID: String?
    public var scope: String?
    public var metadata: [String: String]

    /// Creates a provider service configuration block.
    /// - Parameters:
    ///   - enabled: Enables this provider service.
    ///   - apiStyle: API style contract for this provider service.
    ///   - authMode: Authentication mode for this provider.
    ///   - modelID: Default model identifier.
    ///   - apiKey: Optional API key secret.
    ///   - accessToken: Optional bearer/OAuth access token.
    ///   - baseURL: API base URL.
    ///   - chatCompletionsPath: Relative OpenAI-style chat completions path.
    ///   - messagesPath: Relative Anthropic-style messages path.
    ///   - apiVersion: Optional provider API version.
    ///   - organizationID: Optional organization or project identifier.
    ///   - headers: Additional static headers.
    ///   - region: Optional region identifier.
    ///   - profile: Optional profile identifier.
    ///   - tenantID: Optional tenant identifier.
    ///   - scope: Optional OAuth scope identifier.
    ///   - metadata: Additional provider metadata.
    public init(
        enabled: Bool = false,
        apiStyle: ProviderServiceAPIStyle = .openAICompletions,
        authMode: ProviderServiceAuthMode = .apiKey,
        modelID: String = "gpt-4.1-mini",
        fastMode: Bool? = nil,
        apiKey: String? = nil,
        accessToken: String? = nil,
        baseURL: String = "https://api.openai.com/v1",
        chatCompletionsPath: String = "chat/completions",
        messagesPath: String = "messages",
        apiVersion: String? = nil,
        organizationID: String? = nil,
        headers: [String: String] = [:],
        region: String? = nil,
        profile: String? = nil,
        tenantID: String? = nil,
        scope: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.enabled = enabled
        self.apiStyle = apiStyle
        self.authMode = authMode
        self.modelID = modelID
        self.fastMode = fastMode
        self.apiKey = apiKey
        self.accessToken = accessToken
        self.baseURL = baseURL
        self.chatCompletionsPath = chatCompletionsPath
        self.messagesPath = messagesPath
        self.apiVersion = apiVersion
        self.organizationID = organizationID
        self.headers = headers
        self.region = region
        self.profile = profile
        self.tenantID = tenantID
        self.scope = scope
        self.metadata = metadata
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case apiStyle
        case authMode
        case modelID
        case fastMode
        case apiKey
        case accessToken
        case baseURL
        case chatCompletionsPath
        case messagesPath
        case apiVersion
        case organizationID
        case headers
        case region
        case profile
        case tenantID
        case scope
        case metadata
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        self.apiStyle = container.decodeLenient(ProviderServiceAPIStyle.self, forKey: .apiStyle) ?? .openAICompletions
        self.authMode = container.decodeLenient(ProviderServiceAuthMode.self, forKey: .authMode) ?? .apiKey
        self.modelID = try container.decodeIfPresent(String.self, forKey: .modelID) ?? "gpt-4.1-mini"
        self.fastMode = try container.decodeIfPresent(Bool.self, forKey: .fastMode)
        self.apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey)
        self.accessToken = try container.decodeIfPresent(String.self, forKey: .accessToken)
        self.baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? "https://api.openai.com/v1"
        self.chatCompletionsPath = try container.decodeIfPresent(String.self, forKey: .chatCompletionsPath) ?? "chat/completions"
        self.messagesPath = try container.decodeIfPresent(String.self, forKey: .messagesPath) ?? "messages"
        self.apiVersion = try container.decodeIfPresent(String.self, forKey: .apiVersion)
        self.organizationID = try container.decodeIfPresent(String.self, forKey: .organizationID)
        self.headers = try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        self.region = try container.decodeIfPresent(String.self, forKey: .region)
        self.profile = try container.decodeIfPresent(String.self, forKey: .profile)
        self.tenantID = try container.decodeIfPresent(String.self, forKey: .tenantID)
        self.scope = try container.decodeIfPresent(String.self, forKey: .scope)
        self.metadata = try container.decodeIfPresent([String: String].self, forKey: .metadata) ?? [:]
    }
}

/// OpenAI provider-specific configuration.
public struct OpenAIModelConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var modelID: String
    public var fastMode: Bool?
    public var apiKey: String?
    public var baseURL: String

    /// Creates OpenAI provider settings.
    /// - Parameters:
    ///   - enabled: Enables OpenAI provider routing.
    ///   - modelID: OpenAI model identifier.
    ///   - apiKey: OpenAI API key.
    ///   - baseURL: OpenAI-compatible API base URL.
    public init(
        enabled: Bool = false,
        modelID: String = "gpt-4.1-mini",
        fastMode: Bool? = nil,
        apiKey: String? = nil,
        baseURL: String = "https://api.openai.com/v1"
    ) {
        self.enabled = enabled
        self.modelID = modelID
        self.fastMode = fastMode
        self.apiKey = apiKey
        self.baseURL = baseURL
    }
}

/// Generic OpenAI-compatible provider settings.
public struct OpenAICompatibleModelConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var modelID: String
    public var apiKey: String?
    public var baseURL: String
    public var chatCompletionsPath: String

    /// Creates OpenAI-compatible provider settings.
    /// - Parameters:
    ///   - enabled: Enables the provider.
    ///   - modelID: Model identifier.
    ///   - apiKey: API key or bearer token.
    ///   - baseURL: API base URL.
    ///   - chatCompletionsPath: Relative chat completions endpoint path.
    public init(
        enabled: Bool = false,
        modelID: String = "gpt-4.1-mini",
        apiKey: String? = nil,
        baseURL: String = "https://api.openai.com/v1",
        chatCompletionsPath: String = "chat/completions"
    ) {
        self.enabled = enabled
        self.modelID = modelID
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.chatCompletionsPath = chatCompletionsPath
    }
}

/// Anthropic provider settings.
public struct AnthropicModelConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var modelID: String
    public var fastMode: Bool?
    public var apiKey: String?
    public var baseURL: String
    public var apiVersion: String
    public var maxTokens: Int

    /// Creates Anthropic provider settings.
    /// - Parameters:
    ///   - enabled: Enables the provider.
    ///   - modelID: Anthropic model identifier.
    ///   - apiKey: Anthropic API key.
    ///   - baseURL: Anthropic API base URL.
    ///   - apiVersion: Anthropic API version header.
    ///   - maxTokens: Maximum output tokens.
    public init(
        enabled: Bool = false,
        modelID: String = "claude-3-5-haiku-latest",
        fastMode: Bool? = nil,
        apiKey: String? = nil,
        baseURL: String = "https://api.anthropic.com/v1",
        apiVersion: String = "2023-06-01",
        maxTokens: Int = 512
    ) {
        self.enabled = enabled
        self.modelID = modelID
        self.fastMode = fastMode
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.apiVersion = apiVersion
        self.maxTokens = max(1, maxTokens)
    }
}

/// Gemini provider settings.
public struct GeminiModelConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var modelID: String
    public var apiKey: String?
    public var baseURL: String

    /// Creates Gemini provider settings.
    /// - Parameters:
    ///   - enabled: Enables the provider.
    ///   - modelID: Gemini model identifier.
    ///   - apiKey: Gemini API key.
    ///   - baseURL: Gemini API base URL.
    public init(
        enabled: Bool = false,
        modelID: String = "gemini-2.0-flash",
        apiKey: String? = nil,
        baseURL: String = "https://generativelanguage.googleapis.com/v1beta"
    ) {
        self.enabled = enabled
        self.modelID = modelID
        self.apiKey = apiKey
        self.baseURL = baseURL
    }
}

/// Apple Foundation Models provider settings.
public struct FoundationModelConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var preferredModelID: String?

    /// Creates Foundation Models settings.
    /// - Parameters:
    ///   - enabled: Enables provider selection.
    ///   - preferredModelID: Optional preferred model name.
    public init(enabled: Bool = false, preferredModelID: String? = nil) {
        self.enabled = enabled
        self.preferredModelID = preferredModelID
    }
}

/// Local inference runtime/provider settings.
public struct LocalModelConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var runtime: String
    public var modelPath: String?
    public var contextWindow: Int
    public var temperature: Double
    public var topP: Double
    public var topK: Int
    public var useMetal: Bool
    public var streamTokens: Bool
    public var allowCancellation: Bool
    public var requestTimeoutMs: Int
    public var fallbackModelPaths: [String]
    public var runtimeOptions: [String: String]
    public var maxTokens: Int

    /// Creates local model settings.
    /// - Parameters:
    ///   - enabled: Enables local provider selection.
    ///   - runtime: Runtime identifier (for example, `llmfarm`).
    ///   - modelPath: Model artifact path.
    ///   - contextWindow: Token context window size.
    ///   - temperature: Sampling temperature.
    ///   - topP: Top-p sampling value.
    ///   - topK: Top-k sampling value.
    ///   - useMetal: Enables Metal acceleration where available.
    ///   - streamTokens: Enables token streaming requests.
    ///   - allowCancellation: Enables cancellation-aware generation requests.
    ///   - requestTimeoutMs: Default local request timeout in milliseconds.
    ///   - fallbackModelPaths: Ordered local model fallback paths.
    ///   - runtimeOptions: Additional runtime-specific option key/value pairs.
    ///   - maxTokens: Maximum generated token count.
    public init(
        enabled: Bool = false,
        runtime: String = "llmfarm",
        modelPath: String? = nil,
        contextWindow: Int = 4096,
        temperature: Double = 0.7,
        topP: Double = 0.95,
        topK: Int = 40,
        useMetal: Bool = true,
        streamTokens: Bool = true,
        allowCancellation: Bool = true,
        requestTimeoutMs: Int = 60_000,
        fallbackModelPaths: [String] = [],
        runtimeOptions: [String: String] = [:],
        maxTokens: Int = 512
    ) {
        self.enabled = enabled
        self.runtime = runtime
        self.modelPath = modelPath
        self.contextWindow = contextWindow
        self.temperature = temperature
        self.topP = topP
        self.topK = max(1, topK)
        self.useMetal = useMetal
        self.streamTokens = streamTokens
        self.allowCancellation = allowCancellation
        self.requestTimeoutMs = max(1, requestTimeoutMs)
        self.fallbackModelPaths = fallbackModelPaths
        self.runtimeOptions = runtimeOptions
        self.maxTokens = max(1, maxTokens)
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case runtime
        case modelPath
        case contextWindow
        case temperature
        case topP
        case topK
        case useMetal
        case streamTokens
        case allowCancellation
        case requestTimeoutMs
        case fallbackModelPaths
        case runtimeOptions
        case maxTokens
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        self.runtime = try container.decodeIfPresent(String.self, forKey: .runtime) ?? "llmfarm"
        self.modelPath = try container.decodeIfPresent(String.self, forKey: .modelPath)
        self.contextWindow = try container.decodeIfPresent(Int.self, forKey: .contextWindow) ?? 4096
        self.temperature = try container.decodeIfPresent(Double.self, forKey: .temperature) ?? 0.7
        self.topP = try container.decodeIfPresent(Double.self, forKey: .topP) ?? 0.95
        self.topK = max(1, try container.decodeIfPresent(Int.self, forKey: .topK) ?? 40)
        self.useMetal = try container.decodeIfPresent(Bool.self, forKey: .useMetal) ?? true
        self.streamTokens = try container.decodeIfPresent(Bool.self, forKey: .streamTokens) ?? true
        self.allowCancellation = try container.decodeIfPresent(Bool.self, forKey: .allowCancellation) ?? true
        self.requestTimeoutMs = max(
            1,
            try container.decodeIfPresent(Int.self, forKey: .requestTimeoutMs) ?? 60_000
        )
        self.fallbackModelPaths = try container.decodeIfPresent([String].self, forKey: .fallbackModelPaths) ?? []
        self.runtimeOptions = try container.decodeIfPresent([String: String].self, forKey: .runtimeOptions) ?? [:]
        self.maxTokens = max(1, try container.decodeIfPresent(Int.self, forKey: .maxTokens) ?? 512)
    }
}
