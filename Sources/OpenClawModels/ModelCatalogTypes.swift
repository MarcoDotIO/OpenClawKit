import Foundation
import OpenClawCore
import OpenClawProtocol

// Swift Codable mirrors of upstream `packages/model-catalog-core/src/model-catalog-types.ts` (OpenClaw 2026.9.6).
// Decoding is lenient like upstream `normalizeModelCatalog*`: unknown enum values and malformed optional fields are
// dropped instead of failing the whole catalog.

/// Discovery lifecycle for a provider catalog (upstream `ModelCatalogDiscovery`).
public enum ModelCatalogDiscovery: String, Codable, Sendable, Equatable, CaseIterable {
    /// Rows ship with the manifest and never change at runtime.
    case `static`
    /// Rows ship with the manifest and may be refreshed from the provider.
    case refreshable
    /// Rows are only known after runtime discovery.
    case runtime
}

/// Availability state for one catalog model (upstream `ModelCatalogStatus`).
public enum ModelCatalogStatus: String, Codable, Sendable, Equatable, CaseIterable {
    /// Generally available.
    case available
    /// Preview or beta access.
    case preview
    /// Still selectable but scheduled for removal; pickers list it last.
    case deprecated
    /// Hidden from pickers.
    case disabled
}

/// Source of a normalized model catalog row (upstream `ModelCatalogSource`).
public enum ModelCatalogSource: String, Codable, Sendable, Equatable, CaseIterable {
    /// Bundled plugin manifest.
    case manifest
    /// Provider index snapshot.
    case providerIndex = "provider-index"
    /// Persisted discovery cache.
    case cache
    /// User configuration.
    case config
    /// Hosted catalog refresh overlay.
    case runtimeRefresh = "runtime-refresh"
}

/// Provider-declared context-window choice for one model (upstream `ModelCatalogContextWindowOption`).
public struct ModelCatalogContextWindowOption: Codable, Sendable, Equatable, Hashable {
    /// Stable option identifier (for example `200k` or `1m`).
    public var id: String
    /// Human-facing option label.
    public var label: String
    /// Context window in tokens.
    public var contextWindow: Int

    /// Creates a context-window option.
    public init(id: String, label: String, contextWindow: Int) {
        self.id = id
        self.label = label
        self.contextWindow = contextWindow
    }

    /// Maximum number of options a model may declare (upstream `MODEL_CATALOG_MAX_CONTEXT_WINDOWS`).
    public static let maximumCount = 16
}

/// One tier of prompt-size dependent pricing (upstream `ModelCatalogTieredCost`).
public struct ModelCatalogPricingTier: Codable, Sendable, Equatable {
    /// Input cost per million tokens.
    public var input: Double
    /// Output cost per million tokens.
    public var output: Double
    /// Cache-read cost per million tokens.
    public var cacheRead: Double
    /// Cache-write cost per million tokens.
    public var cacheWrite: Double
    /// Half-open prompt-token interval; a single element is an open-ended upper tier.
    public var range: [Int]

    /// Creates a pricing tier.
    public init(input: Double, output: Double, cacheRead: Double, cacheWrite: Double, range: [Int]) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.range = range
    }

    /// Returns whether a prompt token count falls inside this tier's half-open range.
    public func contains(promptTokens: Int) -> Bool {
        guard let lower = self.range.first else { return false }
        if self.range.count == 1 {
            return promptTokens >= lower
        }
        return promptTokens >= lower && promptTokens < self.range[1]
    }
}

/// Token cost metadata for one model (upstream `ModelCatalogCost`). Rates are per million tokens.
public struct ModelCatalogCost: Codable, Sendable, Equatable {
    /// Input rate.
    public var input: Double?
    /// Output rate.
    public var output: Double?
    /// Cache-read rate.
    public var cacheRead: Double?
    /// Cache-write rate.
    public var cacheWrite: Double?
    /// Optional prompt-size pricing tiers.
    public var tieredPricing: [ModelCatalogPricingTier]?

    /// Creates cost metadata.
    public init(
        input: Double? = nil,
        output: Double? = nil,
        cacheRead: Double? = nil,
        cacheWrite: Double? = nil,
        tieredPricing: [ModelCatalogPricingTier]? = nil
    ) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.tieredPricing = tieredPricing
    }

    /// Returns the pricing tier that applies to a prompt token count, when tiers are declared.
    public func tier(forPromptTokens promptTokens: Int) -> ModelCatalogPricingTier? {
        self.tieredPricing?.first { $0.contains(promptTokens: promptTokens) }
    }
}

/// Provider-native value for one logical thinking level.
public enum ModelCatalogThinkingLevelValue: Sendable, Equatable {
    /// The level is explicitly unsupported (`null` in the manifest).
    case disabled
    /// The level maps to this provider-native value.
    case mapped(String)
}

/// Model-level thinking level map (upstream `ModelDataThinkingLevelMap`).
///
/// Keys are logical levels (`off`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`). A missing key means the
/// level passes through unchanged; an explicit `null` disables the level. Encoding preserves explicit nulls.
public struct ModelCatalogThinkingLevelMap: Codable, Sendable, Equatable {
    /// Logical levels the map may declare, in upstream order.
    public static let levels = ["off", "minimal", "low", "medium", "high", "xhigh", "max"]

    /// Declared values keyed by logical level.
    public var values: [String: ModelCatalogThinkingLevelValue]

    /// Creates a thinking level map.
    public init(_ values: [String: ModelCatalogThinkingLevelValue] = [:]) {
        self.values = values
    }

    /// Returns the declared value for a logical level, or `nil` when the level is not declared.
    public subscript(level: String) -> ModelCatalogThinkingLevelValue? {
        self.values[level.lowercased()]
    }

    /// Returns the declared value for a thinking level, or `nil` when the level is not declared.
    public subscript(level: ThinkLevel) -> ModelCatalogThinkingLevelValue? {
        self.values[level.rawValue]
    }

    /// Returns whether the map explicitly disables a level.
    public func isDisabled(_ level: ThinkLevel) -> Bool {
        self[level] == .disabled
    }

    /// Returns whether the map declares a non-null provider value for a level.
    public func isMapped(_ level: ThinkLevel) -> Bool {
        if case .mapped = self[level] {
            return true
        }
        return false
    }

    /// Returns the provider-native value for a level: the mapped value, `nil` when disabled, or the level itself.
    public func providerValue(for level: ThinkLevel) -> String? {
        switch self[level] {
        case .disabled:
            return nil
        case .mapped(let value):
            return value
        case nil:
            return level.rawValue
        }
    }

    private struct LevelKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// Decodes a level map, keeping explicit `null` values and dropping unknown levels.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: LevelKey.self)
        var values: [String: ModelCatalogThinkingLevelValue] = [:]
        for key in container.allKeys {
            let level = key.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard Self.levels.contains(level) else { continue }
            if try container.decodeNil(forKey: key) {
                values[level] = .disabled
            } else if let raw = try? container.decode(String.self, forKey: key) {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    values[level] = .mapped(trimmed)
                }
            }
        }
        self.values = values
    }

    /// Encodes the map in upstream level order, writing `null` for disabled levels.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: LevelKey.self)
        for level in Self.levels {
            guard let value = self.values[level] else { continue }
            switch value {
            case .disabled:
                try container.encodeNil(forKey: LevelKey(stringValue: level))
            case .mapped(let mapped):
                try container.encode(mapped, forKey: LevelKey(stringValue: level))
            }
        }
    }
}

/// Image input limits for one model (upstream `ModelDataImageInputConfig`).
public struct ModelCatalogImageInputConfig: Codable, Sendable, Equatable {
    /// Maximum encoded image payload size in bytes.
    public var maxBytes: Int?
    /// Maximum accepted input pixels.
    public var maxPixels: Int?
    /// Maximum accepted width or height in pixels.
    public var maxSidePx: Int?
    /// Preferred resize side for the balanced compression policy.
    public var preferredSidePx: Int?
    /// Token accounting style (`tile`, `detail` or `provider`).
    public var tokenMode: String?

    /// Creates image input limits.
    public init(
        maxBytes: Int? = nil,
        maxPixels: Int? = nil,
        maxSidePx: Int? = nil,
        preferredSidePx: Int? = nil,
        tokenMode: String? = nil
    ) {
        self.maxBytes = maxBytes
        self.maxPixels = maxPixels
        self.maxSidePx = maxSidePx
        self.preferredSidePx = preferredSidePx
        self.tokenMode = tokenMode
    }
}

/// Media input limits for one model (upstream `ModelDataMediaInputConfig`).
public struct ModelCatalogMediaInputConfig: Codable, Sendable, Equatable {
    /// Image input limits.
    public var image: ModelCatalogImageInputConfig?

    /// Creates media input limits.
    public init(image: ModelCatalogImageInputConfig? = nil) {
        self.image = image
    }
}

/// Vercel AI Gateway routing preferences (upstream `ModelCatalogVercelGatewayRouting`).
public struct ModelCatalogVercelGatewayRouting: Codable, Sendable, Equatable {
    /// Restricts routing to these upstream providers.
    public var only: [String]?
    /// Preferred upstream provider order.
    public var order: [String]?

    /// Creates Vercel routing preferences.
    public init(only: [String]? = nil, order: [String]? = nil) {
        self.only = only
        self.order = order
    }
}

/// Compatibility flags and routing metadata for one catalog model (upstream `ModelCatalogCompatConfig`).
///
/// This is the manifest-row shape. Runtime provider config uses `ModelCompatConfig` (OpenClawCore); see
/// ``ModelCatalogModel/definitionConfig()`` for the mapping.
public struct ModelCatalogCompatConfig: Codable, Sendable, Equatable {
    /// Whether the endpoint accepts `store`.
    public var supportsStore: Bool?
    /// Whether the endpoint accepts `prompt_cache_key`.
    public var supportsPromptCacheKey: Bool?
    /// Whether the endpoint accepts the `developer` role.
    public var supportsDeveloperRole: Bool?
    /// Whether the endpoint accepts reasoning effort.
    public var supportsReasoningEffort: Bool?
    /// Whether the model accepts `temperature`.
    public var supportsTemperature: Bool?
    /// Whether the endpoint honors top-level Responses `instructions`.
    public var supportsInstructions: Bool?
    /// Whether usage is reported while streaming.
    public var supportsUsageInStreaming: Bool?
    /// Whether the model supports tools.
    public var supportsTools: Bool?
    /// Whether the endpoint supports strict tool schemas.
    public var supportsStrictMode: Bool?
    /// Whether the endpoint supports JSON-schema response formats.
    public var supportsJsonSchemaResponseFormat: Bool?
    /// Whether message content must be a string.
    public var requiresStringContent: Bool?
    /// Whether unknown message keys are rejected.
    public var strictMessageKeys: Bool?
    /// Whether tool results must carry the tool name.
    public var requiresToolResultName: Bool?
    /// Whether an assistant turn must follow tool results.
    public var requiresAssistantAfterToolResult: Bool?
    /// Whether thinking must be replayed as text.
    public var requiresThinkingAsText: Bool?
    /// Whether assistant messages must carry `reasoning_content`.
    public var requiresReasoningContentOnAssistantMessages: Bool?
    /// Whether Z.AI tool streaming is enabled.
    public var zaiToolStream: Bool?
    /// Whether session affinity headers are sent.
    public var sendSessionAffinityHeaders: Bool?
    /// Whether the session id header is sent.
    public var sendSessionIdHeader: Bool?
    /// Whether eager tool input streaming is supported.
    public var supportsEagerToolInputStreaming: Bool?
    /// Whether long cache retention is supported.
    public var supportsLongCacheRetention: Bool?
    /// Whether Responses continuation is supported on custom endpoints.
    public var supportsResponsesContinuation: Bool?
    /// Whether OpenAI-compatible endpoints need the Anthropic tool payload (`requiresOpenAiAnthropicToolPayload`).
    public var requiresOpenAIAnthropicToolPayload: Bool?
    /// Code-mode tier (`preferred` or `capable`).
    public var codeMode: String?
    /// Max-tokens request field.
    public var maxTokensField: ModelCompatMaxTokensField?
    /// Thinking wire format.
    public var thinkingFormat: ModelCompatThinkingFormat?
    /// Cache-control marker format (`anthropic`).
    public var cacheControlFormat: String?
    /// Tool schema profile identifier.
    public var toolSchemaProfile: String?
    /// Tool-call arguments encoding identifier.
    public var toolCallArgumentsEncoding: String?
    /// JSON-schema keywords the endpoint rejects.
    public var unsupportedToolSchemaKeywords: [String]?
    /// Supported reasoning efforts; an explicit empty list means reasoning effort is unsupported.
    public var supportedReasoningEfforts: [String]?
    /// Provider-native reasoning effort values keyed by logical level.
    public var reasoningEffortMap: [String: String]?
    /// Reasoning detail types that are surfaced to users.
    public var visibleReasoningDetailTypes: [String]?
    /// OpenRouter provider routing preferences, kept verbatim.
    public var openRouterRouting: [String: AnyCodable]?
    /// Vercel AI Gateway routing preferences.
    public var vercelGatewayRouting: ModelCatalogVercelGatewayRouting?

    /// Creates compat metadata with every flag unset.
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case supportsStore
        case supportsPromptCacheKey
        case supportsDeveloperRole
        case supportsReasoningEffort
        case supportsTemperature
        case supportsInstructions
        case supportsUsageInStreaming
        case supportsTools
        case supportsStrictMode
        case supportsJsonSchemaResponseFormat
        case requiresStringContent
        case strictMessageKeys
        case requiresToolResultName
        case requiresAssistantAfterToolResult
        case requiresThinkingAsText
        case requiresReasoningContentOnAssistantMessages
        case zaiToolStream
        case sendSessionAffinityHeaders
        case sendSessionIdHeader
        case supportsEagerToolInputStreaming
        case supportsLongCacheRetention
        case supportsResponsesContinuation
        case requiresOpenAIAnthropicToolPayload = "requiresOpenAiAnthropicToolPayload"
        case codeMode
        case maxTokensField
        case thinkingFormat
        case cacheControlFormat
        case toolSchemaProfile
        case toolCallArgumentsEncoding
        case unsupportedToolSchemaKeywords
        case supportedReasoningEfforts
        case reasoningEffortMap
        case visibleReasoningDetailTypes
        case openRouterRouting
        case vercelGatewayRouting
    }

    /// Decodes compat metadata, dropping malformed or unknown values field by field.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.supportsStore = container.lenient(Bool.self, .supportsStore)
        self.supportsPromptCacheKey = container.lenient(Bool.self, .supportsPromptCacheKey)
        self.supportsDeveloperRole = container.lenient(Bool.self, .supportsDeveloperRole)
        self.supportsReasoningEffort = container.lenient(Bool.self, .supportsReasoningEffort)
        self.supportsTemperature = container.lenient(Bool.self, .supportsTemperature)
        self.supportsInstructions = container.lenient(Bool.self, .supportsInstructions)
        self.supportsUsageInStreaming = container.lenient(Bool.self, .supportsUsageInStreaming)
        self.supportsTools = container.lenient(Bool.self, .supportsTools)
        self.supportsStrictMode = container.lenient(Bool.self, .supportsStrictMode)
        self.supportsJsonSchemaResponseFormat = container.lenient(Bool.self, .supportsJsonSchemaResponseFormat)
        self.requiresStringContent = container.lenient(Bool.self, .requiresStringContent)
        self.strictMessageKeys = container.lenient(Bool.self, .strictMessageKeys)
        self.requiresToolResultName = container.lenient(Bool.self, .requiresToolResultName)
        self.requiresAssistantAfterToolResult = container.lenient(Bool.self, .requiresAssistantAfterToolResult)
        self.requiresThinkingAsText = container.lenient(Bool.self, .requiresThinkingAsText)
        self.requiresReasoningContentOnAssistantMessages = container.lenient(
            Bool.self,
            .requiresReasoningContentOnAssistantMessages
        )
        self.zaiToolStream = container.lenient(Bool.self, .zaiToolStream)
        self.sendSessionAffinityHeaders = container.lenient(Bool.self, .sendSessionAffinityHeaders)
        self.sendSessionIdHeader = container.lenient(Bool.self, .sendSessionIdHeader)
        self.supportsEagerToolInputStreaming = container.lenient(Bool.self, .supportsEagerToolInputStreaming)
        self.supportsLongCacheRetention = container.lenient(Bool.self, .supportsLongCacheRetention)
        self.supportsResponsesContinuation = container.lenient(Bool.self, .supportsResponsesContinuation)
        self.requiresOpenAIAnthropicToolPayload = container.lenient(Bool.self, .requiresOpenAIAnthropicToolPayload)
        self.codeMode = container.lenient(String.self, .codeMode).flatMap { ["preferred", "capable"].contains($0) ? $0 : nil }
        self.maxTokensField = container.lenient(String.self, .maxTokensField).flatMap(ModelCompatMaxTokensField.init(rawValue:))
        self.thinkingFormat = container.lenient(String.self, .thinkingFormat).flatMap(ModelCompatThinkingFormat.init(rawValue:))
        self.cacheControlFormat = container.lenient(String.self, .cacheControlFormat).flatMap { $0 == "anthropic" ? $0 : nil }
        self.toolSchemaProfile = container.lenient(String.self, .toolSchemaProfile)
        self.toolCallArgumentsEncoding = container.lenient(String.self, .toolCallArgumentsEncoding)
        self.unsupportedToolSchemaKeywords = container.lenient([String].self, .unsupportedToolSchemaKeywords)
        self.supportedReasoningEfforts = container.lenient([String].self, .supportedReasoningEfforts)
        self.reasoningEffortMap = container.lenient([String: String].self, .reasoningEffortMap)
        self.visibleReasoningDetailTypes = container.lenient([String].self, .visibleReasoningDetailTypes)
        self.openRouterRouting = container.lenient([String: AnyCodable].self, .openRouterRouting)
        self.vercelGatewayRouting = container.lenient(ModelCatalogVercelGatewayRouting.self, .vercelGatewayRouting)
    }

    /// Returns whether reasoning effort is explicitly unsupported (`supportsReasoningEffort: false` or empty efforts).
    public var disablesReasoningEffort: Bool {
        self.supportsReasoningEffort == false || self.supportedReasoningEfforts?.isEmpty == true
    }

    /// Maps the manifest compat row onto the runtime `ModelCompatConfig` fields OpenClawCore defines today.
    public var runtimeConfig: ModelCompatConfig {
        ModelCompatConfig(
            supportsStore: self.supportsStore,
            supportsDeveloperRole: self.supportsDeveloperRole,
            supportsReasoningEffort: self.supportsReasoningEffort,
            supportsUsageInStreaming: self.supportsUsageInStreaming,
            supportsTools: self.supportsTools,
            supportsStrictMode: self.supportsStrictMode,
            maxTokensField: self.maxTokensField,
            thinkingFormat: self.thinkingFormat,
            requiresToolResultName: self.requiresToolResultName,
            requiresAssistantAfterToolResult: self.requiresAssistantAfterToolResult,
            requiresThinkingAsText: self.requiresThinkingAsText,
            requiresOpenAIAnthropicToolPayload: self.requiresOpenAIAnthropicToolPayload
        )
    }
}

/// One provider manifest model row (upstream `ModelCatalogModel`).
public struct ModelCatalogModel: Codable, Sendable, Equatable, Identifiable {
    /// Provider-local model identifier.
    public var id: String
    /// Human-facing model name.
    public var name: String?
    /// Per-model API override.
    public var api: ModelAPI?
    /// Per-model base URL override (`baseUrl` on the wire).
    public var baseURL: String?
    /// Per-model headers.
    public var headers: [String: String]?
    /// Supported input modalities.
    public var input: [ModelInputType]?
    /// Whether the model reasons.
    public var reasoning: Bool?
    /// Native context window in tokens.
    public var contextWindow: Int?
    /// Selectable context-window options (always paired with ``contextWindowDefault``).
    public var contextWindows: [ModelCatalogContextWindowOption]?
    /// Default context-window option id; references one of ``contextWindows``.
    public var contextWindowDefault: String?
    /// Effective runtime context cap used for compaction and budgeting.
    public var contextTokens: Int?
    /// Maximum output tokens.
    public var maxTokens: Int?
    /// Logical-to-native thinking level map.
    public var thinkingLevelMap: ModelCatalogThinkingLevelMap?
    /// Token cost metadata.
    public var cost: ModelCatalogCost?
    /// Compatibility flags.
    public var compat: ModelCatalogCompatConfig?
    /// Media input limits.
    public var mediaInput: ModelCatalogMediaInputConfig?
    /// Availability state.
    public var status: ModelCatalogStatus?
    /// Reason attached to ``status``.
    public var statusReason: String?
    /// Model ids this row replaces.
    public var replaces: [String]?
    /// Provider-local successor model id.
    public var replacedBy: String?
    /// Free-form tags.
    public var tags: [String]?
    /// Provider request parameters (SDK rows such as Apple Private Cloud Compute's `network: required`).
    public var params: [String: AnyCodable]?

    /// Creates a catalog model row.
    public init(
        id: String,
        name: String? = nil,
        api: ModelAPI? = nil,
        baseURL: String? = nil,
        headers: [String: String]? = nil,
        input: [ModelInputType]? = nil,
        reasoning: Bool? = nil,
        contextWindow: Int? = nil,
        contextWindows: [ModelCatalogContextWindowOption]? = nil,
        contextWindowDefault: String? = nil,
        contextTokens: Int? = nil,
        maxTokens: Int? = nil,
        thinkingLevelMap: ModelCatalogThinkingLevelMap? = nil,
        cost: ModelCatalogCost? = nil,
        compat: ModelCatalogCompatConfig? = nil,
        mediaInput: ModelCatalogMediaInputConfig? = nil,
        status: ModelCatalogStatus? = nil,
        statusReason: String? = nil,
        replaces: [String]? = nil,
        replacedBy: String? = nil,
        tags: [String]? = nil,
        params: [String: AnyCodable]? = nil
    ) {
        self.id = id
        self.name = name
        self.api = api
        self.baseURL = baseURL
        self.headers = headers
        self.input = input
        self.reasoning = reasoning
        self.contextWindow = contextWindow
        let selection = Self.normalizedContextWindowSelection(contextWindows, contextWindowDefault)
        self.contextWindows = selection.options
        self.contextWindowDefault = selection.defaultID
        self.contextTokens = contextTokens
        self.maxTokens = maxTokens
        self.thinkingLevelMap = thinkingLevelMap
        self.cost = cost
        self.compat = compat
        self.mediaInput = mediaInput
        self.status = status
        self.statusReason = statusReason
        self.replaces = replaces
        self.replacedBy = replacedBy
        self.tags = tags
        self.params = params.flatMap { $0.isEmpty ? nil : $0 }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case api
        case baseURL = "baseUrl"
        case headers
        case input
        case reasoning
        case contextWindow
        case contextWindows
        case contextWindowDefault
        case contextTokens
        case maxTokens
        case thinkingLevelMap
        case cost
        case compat
        case mediaInput
        case status
        case statusReason
        case replaces
        case replacedBy
        case tags
        case params
    }

    /// Decodes a row leniently; only `id` is required.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: container, debugDescription: "Model id is empty")
        }
        self.init(
            id: id,
            name: container.lenientNonEmptyString(.name),
            api: container.lenient(String.self, .api).flatMap(ModelAPI.init(normalizing:)),
            baseURL: container.lenientNonEmptyString(.baseURL),
            headers: container.lenient([String: String].self, .headers),
            input: container.lenient([String].self, .input).map { raw in
                raw.compactMap { ModelInputType(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
            }.flatMap { $0.isEmpty ? nil : $0 },
            reasoning: container.lenient(Bool.self, .reasoning),
            contextWindow: container.lenientPositiveInt(.contextWindow),
            contextWindows: container.lenient([LossyContextWindowOption].self, .contextWindows)?.compactMap(\.value),
            contextWindowDefault: container.lenientNonEmptyString(.contextWindowDefault),
            contextTokens: container.lenientPositiveInt(.contextTokens),
            maxTokens: container.lenientPositiveInt(.maxTokens),
            thinkingLevelMap: container.lenient(ModelCatalogThinkingLevelMap.self, .thinkingLevelMap)
                .flatMap { $0.values.isEmpty ? nil : $0 },
            cost: container.lenient(ModelCatalogCost.self, .cost),
            compat: container.lenient(ModelCatalogCompatConfig.self, .compat),
            mediaInput: container.lenient(ModelCatalogMediaInputConfig.self, .mediaInput),
            status: container.lenient(String.self, .status).flatMap(ModelCatalogStatus.init(rawValue:)),
            statusReason: container.lenientNonEmptyString(.statusReason),
            replaces: container.lenient([String].self, .replaces),
            replacedBy: container.lenientNonEmptyString(.replacedBy),
            tags: container.lenient([String].self, .tags),
            params: container.lenient([String: AnyCodable].self, .params)
        )
    }

    /// Encodes the row with upstream wire keys (`baseUrl`, `requiresOpenAiAnthropicToolPayload`), omitting unset fields.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .id)
        try container.encodeIfPresent(self.name, forKey: .name)
        try container.encodeIfPresent(self.api?.rawValue, forKey: .api)
        try container.encodeIfPresent(self.baseURL, forKey: .baseURL)
        try container.encodeIfPresent(self.headers, forKey: .headers)
        try container.encodeIfPresent(self.input, forKey: .input)
        try container.encodeIfPresent(self.reasoning, forKey: .reasoning)
        try container.encodeIfPresent(self.contextWindow, forKey: .contextWindow)
        try container.encodeIfPresent(self.contextWindows, forKey: .contextWindows)
        try container.encodeIfPresent(self.contextWindowDefault, forKey: .contextWindowDefault)
        try container.encodeIfPresent(self.contextTokens, forKey: .contextTokens)
        try container.encodeIfPresent(self.maxTokens, forKey: .maxTokens)
        try container.encodeIfPresent(self.thinkingLevelMap, forKey: .thinkingLevelMap)
        try container.encodeIfPresent(self.cost, forKey: .cost)
        try container.encodeIfPresent(self.compat, forKey: .compat)
        try container.encodeIfPresent(self.mediaInput, forKey: .mediaInput)
        try container.encodeIfPresent(self.status, forKey: .status)
        try container.encodeIfPresent(self.statusReason, forKey: .statusReason)
        try container.encodeIfPresent(self.replaces, forKey: .replaces)
        try container.encodeIfPresent(self.replacedBy, forKey: .replacedBy)
        try container.encodeIfPresent(self.tags, forKey: .tags)
        try container.encodeIfPresent(self.params, forKey: .params)
    }

    /// Effective availability state (`available` when unset).
    public var effectiveStatus: ModelCatalogStatus {
        self.status ?? .available
    }

    /// Effective input modalities (`[.text]` when unset).
    public var effectiveInput: [ModelInputType] {
        self.input ?? [.text]
    }

    /// Effective context budget: selected option, then the default option, then `contextTokens`, then `contextWindow`.
    /// - Parameter selectedContextWindowID: Optional context-window option chosen by the user.
    /// - Returns: The token budget, or `nil` when the row declares none.
    public func effectiveContextBudget(selectedContextWindowID: String? = nil) -> Int? {
        if let selectedContextWindowID,
           let option = self.contextWindows?.first(where: { $0.id == selectedContextWindowID })
        {
            return option.contextWindow
        }
        if let defaultID = self.contextWindowDefault,
           let option = self.contextWindows?.first(where: { $0.id == defaultID })
        {
            return option.contextWindow
        }
        return self.contextTokens ?? self.contextWindow
    }

    /// Converts the row to the runtime `ModelDefinitionConfig`.
    ///
    /// Carries every field the runtime reads: `baseUrl`, `contextTokens`, `thinkingLevelMap` (explicit
    /// `null` entries preserved), `params`, `mediaInput`, cost
    /// including `tieredPricing`, and the full compat row (`supportedReasoningEfforts`,
    /// `reasoningEffortMap`, `supportsTemperature`, `supportsJsonSchemaResponseFormat`, ...).
    /// Context-window options themselves stay available on this row.
    public func definitionConfig() -> ModelDefinitionConfig {
        ModelDefinitionConfig(
            id: self.id,
            name: self.name ?? self.id,
            api: self.api,
            reasoning: self.reasoning ?? false,
            input: self.effectiveInput,
            cost: self.cost.flatMap { ModelCatalogJSONBridge.convert($0, to: ModelCostConfig.self) }
                ?? ModelCostConfig(
                    input: self.cost?.input ?? 0,
                    output: self.cost?.output ?? 0,
                    cacheRead: self.cost?.cacheRead ?? 0,
                    cacheWrite: self.cost?.cacheWrite ?? 0
                ),
            contextWindow: self.contextWindow ?? 0,
            maxTokens: self.maxTokens ?? 0,
            headers: self.headers ?? [:],
            compat: self.compat.map { compat in
                ModelCatalogJSONBridge.convert(compat, to: ModelCompatConfig.self) ?? compat.runtimeConfig
            },
            baseURL: self.baseURL,
            contextTokens: self.contextTokens,
            thinkingLevelMap: self.thinkingLevelMap.flatMap { ModelCatalogJSONBridge.convert($0, to: ModelThinkingLevelMap.self) },
            params: self.params,
            mediaInput: self.mediaInput.flatMap { ModelCatalogJSONBridge.convert($0, to: ModelMediaInputConfig.self) }
        )
    }

    /// Normalizes context-window options: at most 16, unique ids, sorted by size; options and default are atomic.
    static func normalizedContextWindowSelection(
        _ options: [ModelCatalogContextWindowOption]?,
        _ defaultID: String?
    ) -> (options: [ModelCatalogContextWindowOption]?, defaultID: String?) {
        guard let options, let defaultID else { return (nil, nil) }
        var seen: Set<String> = []
        let valid = options.prefix(ModelCatalogContextWindowOption.maximumCount).filter { option in
            !option.id.isEmpty && !option.label.isEmpty && option.contextWindow > 0 && seen.insert(option.id).inserted
        }
        let sorted = valid.sorted { lhs, rhs in
            lhs.contextWindow == rhs.contextWindow ? lhs.id < rhs.id : lhs.contextWindow < rhs.contextWindow
        }
        guard !sorted.isEmpty, sorted.contains(where: { $0.id == defaultID }) else { return (nil, nil) }
        return (sorted, defaultID)
    }
}

private struct LossyContextWindowOption: Decodable {
    let value: ModelCatalogContextWindowOption?

    init(from decoder: Decoder) throws {
        self.value = try? ModelCatalogContextWindowOption(from: decoder)
    }
}

/// One provider's manifest catalog (upstream `ModelCatalogProvider`).
public struct ModelCatalogProvider: Codable, Sendable, Equatable {
    /// Provider base URL (`baseUrl` on the wire).
    public var baseURL: String?
    /// Provider API.
    public var api: ModelAPI?
    /// Provider headers.
    public var headers: [String: String]?
    /// Provider-recommended primary model id.
    public var defaultModel: String?
    /// Provider-recommended small model id for short internal utility tasks.
    public var defaultUtilityModel: String?
    /// Model rows.
    public var models: [ModelCatalogModel]

    /// Creates a provider catalog.
    public init(
        baseURL: String? = nil,
        api: ModelAPI? = nil,
        headers: [String: String]? = nil,
        defaultModel: String? = nil,
        defaultUtilityModel: String? = nil,
        models: [ModelCatalogModel] = []
    ) {
        self.baseURL = baseURL
        self.api = api
        self.headers = headers
        self.defaultModel = defaultModel
        self.defaultUtilityModel = defaultUtilityModel
        self.models = models
    }

    private enum CodingKeys: String, CodingKey {
        case baseURL = "baseUrl"
        case api
        case headers
        case defaultModel
        case defaultUtilityModel
        case models
    }

    /// Decodes a provider catalog, dropping malformed model rows.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.baseURL = container.lenientNonEmptyString(.baseURL)
        self.api = container.lenient(String.self, .api).flatMap(ModelAPI.init(normalizing:))
        self.headers = container.lenient([String: String].self, .headers)
        self.defaultModel = container.lenientNonEmptyString(.defaultModel)
        self.defaultUtilityModel = container.lenientNonEmptyString(.defaultUtilityModel)
        self.models = (container.lenient([LossyModelRow].self, .models) ?? []).compactMap(\.value)
    }

    /// Encodes the catalog with upstream wire keys.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.baseURL, forKey: .baseURL)
        try container.encodeIfPresent(self.api?.rawValue, forKey: .api)
        try container.encodeIfPresent(self.headers, forKey: .headers)
        try container.encodeIfPresent(self.defaultModel, forKey: .defaultModel)
        try container.encodeIfPresent(self.defaultUtilityModel, forKey: .defaultUtilityModel)
        try container.encode(self.models, forKey: .models)
    }

    /// Returns the row for a model id (exact match first, then case-insensitive).
    public func model(id: String) -> ModelCatalogModel? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = self.models.first(where: { $0.id == trimmed }) {
            return exact
        }
        let lowered = trimmed.lowercased()
        return self.models.first { $0.id.lowercased() == lowered }
    }

    /// Returns the default model row: ``defaultModel`` when declared, else the first row.
    public var defaultModelRow: ModelCatalogModel? {
        if let defaultModel, let row = self.model(id: defaultModel) {
            return row
        }
        return self.models.first
    }

    /// Normalizes the catalog into sorted rows (ports upstream `normalizeModelCatalogProviderRows`).
    /// - Parameters:
    ///   - provider: Owning provider id.
    ///   - source: Row source.
    /// - Returns: Rows sorted by model id with provider api/baseUrl/headers applied.
    public func normalizedRows(provider: String, source: ModelCatalogSource = .manifest) -> [NormalizedModelCatalogRow] {
        let providerID = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !providerID.isEmpty else { return [] }
        return self.models
            .map { NormalizedModelCatalogRow(provider: providerID, model: $0, providerCatalog: self, source: source) }
            .sorted { $0.id < $1.id }
    }
}

private struct LossyModelRow: Decodable {
    let value: ModelCatalogModel?

    init(from decoder: Decoder) throws {
        self.value = try? ModelCatalogModel(from: decoder)
    }
}

/// Provider alias entry (upstream `ModelCatalogAlias`, plus SDK routing extensions).
public struct ModelCatalogAlias: Codable, Sendable, Equatable {
    /// Canonical provider id the alias resolves to.
    public var provider: String
    /// API the alias selects on the canonical provider.
    public var api: ModelAPI?
    /// Base URL the alias selects (`baseUrl` on the wire).
    public var baseURL: String?
    /// SDK extension: auth mode the alias implies (for example ChatGPT OAuth for `openai-codex`).
    public var auth: ModelProviderAuthMode?
    /// SDK extension: runtime hint preserved for legacy refs (for example `codex`).
    public var runtimeHint: String?
    /// SDK extension: whether the alias is a legacy id kept only for back-compat.
    public var legacy: Bool

    /// Creates an alias entry.
    public init(
        provider: String,
        api: ModelAPI? = nil,
        baseURL: String? = nil,
        auth: ModelProviderAuthMode? = nil,
        runtimeHint: String? = nil,
        legacy: Bool = false
    ) {
        self.provider = provider
        self.api = api
        self.baseURL = baseURL
        self.auth = auth
        self.runtimeHint = runtimeHint
        self.legacy = legacy
    }

    private enum CodingKeys: String, CodingKey {
        case provider
        case api
        case baseURL = "baseUrl"
        case auth
        case runtimeHint
        case legacy
    }

    /// Decodes an alias leniently.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.provider = try container.decode(String.self, forKey: .provider).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.api = container.lenient(String.self, .api).flatMap(ModelAPI.init(normalizing:))
        self.baseURL = container.lenientNonEmptyString(.baseURL)
        self.auth = container.lenient(String.self, .auth).flatMap(ModelProviderAuthMode.init(rawValue:))
        self.runtimeHint = container.lenientNonEmptyString(.runtimeHint)
        self.legacy = container.lenient(Bool.self, .legacy) ?? false
    }

    /// Encodes the alias, omitting unset SDK extensions.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.provider, forKey: .provider)
        try container.encodeIfPresent(self.api?.rawValue, forKey: .api)
        try container.encodeIfPresent(self.baseURL, forKey: .baseURL)
        try container.encodeIfPresent(self.auth, forKey: .auth)
        try container.encodeIfPresent(self.runtimeHint, forKey: .runtimeHint)
        if self.legacy {
            try container.encode(true, forKey: .legacy)
        }
    }
}

/// Suppression rule hiding a provider/model under matching config (upstream `ModelCatalogSuppression`).
public struct ModelCatalogSuppression: Codable, Sendable, Equatable {
    /// Explicit retirement metadata.
    public struct Retirement: Codable, Sendable, Equatable {
        /// Provider-local successor model id.
        public var replacedBy: String?

        /// Creates retirement metadata.
        public init(replacedBy: String? = nil) {
            self.replacedBy = replacedBy
        }
    }

    /// Conditions under which the rule applies.
    public struct Condition: Codable, Sendable, Equatable {
        /// Base URL hosts (lowercased) the rule applies to.
        public var baseUrlHosts: [String]?
        /// Provider config APIs (lowercased) the rule applies to.
        public var providerConfigApiIn: [String]?

        /// Creates a condition.
        public init(baseUrlHosts: [String]? = nil, providerConfigApiIn: [String]? = nil) {
            self.baseUrlHosts = baseUrlHosts
            self.providerConfigApiIn = providerConfigApiIn
        }
    }

    /// Provider id (lowercased).
    public var provider: String
    /// Model id.
    public var model: String
    /// User-facing reason.
    public var reason: String?
    /// Retirement metadata; present when the model retired rather than being route-restricted.
    public var retirement: Retirement?
    /// Conditions; `nil` means the rule always applies.
    public var when: Condition?
    /// Owning upstream plugin id (SDK extension).
    public var pluginID: String?

    /// Creates a suppression rule.
    public init(
        provider: String,
        model: String,
        reason: String? = nil,
        retirement: Retirement? = nil,
        when: Condition? = nil,
        pluginID: String? = nil
    ) {
        self.provider = provider.lowercased()
        self.model = model
        self.reason = reason
        self.retirement = retirement
        self.when = when
        self.pluginID = pluginID
    }

    private enum CodingKeys: String, CodingKey {
        case provider
        case model
        case reason
        case retirement
        case when
        case pluginID = "pluginId"
    }

    /// Returns whether this rule matches a concrete model route (ports upstream `manifestSuppressionMatchesConditions`).
    ///
    /// Retirement rules scoped to hosts never match when the route's base URL is unknown; route-restriction rules
    /// scoped to hosts match when no base URL is known (the provider default route).
    /// - Parameters:
    ///   - provider: Provider id of the route.
    ///   - model: Model id of the route.
    ///   - baseURL: Route base URL, when known.
    ///   - api: Provider config API, when known.
    /// - Returns: `true` when the model is suppressed on this route.
    public func matches(provider: String, model: String, baseURL: String? = nil, api: ModelAPI? = nil) -> Bool {
        let normalizedProvider = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedProvider == self.provider, normalizedModel == self.model.lowercased() else {
            return false
        }
        guard let when = self.when else { return true }
        let hosts = (when.baseUrlHosts ?? []).map { Self.normalizeHost($0) }.filter { !$0.isEmpty }
        let trimmedBaseURL = baseURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasBaseURL = trimmedBaseURL.map { !$0.isEmpty } ?? false
        if self.retirement != nil, !hosts.isEmpty, !hasBaseURL {
            return false
        }
        let apis = (when.providerConfigApiIn ?? []).map { $0.lowercased() }
        if !apis.isEmpty {
            let effectiveAPI = api?.rawValue ?? normalizedProvider
            guard apis.contains(effectiveAPI) else { return false }
        }
        if !hosts.isEmpty {
            guard hasBaseURL else { return true }
            guard let host = trimmedBaseURL.flatMap({ URL(string: $0)?.host }).map(Self.normalizeHost), !host.isEmpty else {
                return false
            }
            guard hosts.contains(host) else { return false }
        }
        return true
    }

    /// User-facing error for a suppressed selection (ports upstream `buildManifestSuppressionError`).
    /// - Parameters:
    ///   - provider: Provider id shown in the message.
    ///   - model: Model id shown in the message.
    /// - Returns: `Unknown model: provider/model. <reason>` plus the doctor hint for retirements.
    public func errorMessage(provider: String? = nil, model: String? = nil) -> String {
        let ref = "\(provider ?? self.provider)/\(model ?? self.model)"
        let reason: String?
        if let retirement {
            let base = self.reason ?? "This model has retired."
            let action = retirement.replacedBy.map { "replace it with \($0)" }
                ?? "clear the retired override and use the default model"
            reason = "\(base) Run `openclaw doctor --fix` to \(action)."
        } else {
            reason = self.reason
        }
        guard let reason else { return "Unknown model: \(ref)." }
        return "Unknown model: \(ref). \(reason)"
    }

    private static func normalizeHost(_ host: String) -> String {
        var normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while normalized.hasSuffix(".") {
            normalized.removeLast()
        }
        return normalized
    }
}

/// Raw manifest `modelCatalog` block (upstream `ModelCatalog`).
public struct ModelCatalog: Codable, Sendable, Equatable {
    /// Publication-time map of owned provider id to models.dev provider id.
    public var modelsDev: [String: String]?
    /// Provider catalogs keyed by provider id.
    public var providers: [String: ModelCatalogProvider]?
    /// Provider aliases keyed by alias id.
    public var aliases: [String: ModelCatalogAlias]?
    /// Suppression rules.
    public var suppressions: [ModelCatalogSuppression]?
    /// Discovery lifecycle per provider id.
    public var discovery: [String: ModelCatalogDiscovery]?
    /// Whether runtime augmentation is enabled.
    public var runtimeAugment: Bool?

    /// Creates a manifest catalog block.
    public init(
        modelsDev: [String: String]? = nil,
        providers: [String: ModelCatalogProvider]? = nil,
        aliases: [String: ModelCatalogAlias]? = nil,
        suppressions: [ModelCatalogSuppression]? = nil,
        discovery: [String: ModelCatalogDiscovery]? = nil,
        runtimeAugment: Bool? = nil
    ) {
        self.modelsDev = modelsDev
        self.providers = providers
        self.aliases = aliases
        self.suppressions = suppressions
        self.discovery = discovery
        self.runtimeAugment = runtimeAugment
    }

    private enum CodingKeys: String, CodingKey {
        case modelsDev
        case providers
        case aliases
        case suppressions
        case discovery
        case runtimeAugment
    }

    /// Decodes a manifest block leniently: malformed providers, aliases, suppressions and discovery modes are dropped.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.modelsDev = container.lenient([String: String].self, .modelsDev)
        self.providers = container.lenient([String: LossyValue<ModelCatalogProvider>].self, .providers)?
            .compactMapValues(\.value)
            .filter { !$0.value.models.isEmpty }
        self.aliases = container.lenient([String: LossyValue<ModelCatalogAlias>].self, .aliases)?.compactMapValues(\.value)
        self.suppressions = container.lenient([LossyValue<ModelCatalogSuppression>].self, .suppressions)?.compactMap(\.value)
        self.discovery = container.lenient([String: String].self, .discovery)?.compactMapValues(ModelCatalogDiscovery.init(rawValue:))
        self.runtimeAugment = container.lenient(Bool.self, .runtimeAugment)
    }

    /// Normalized rows for every provider, sorted by provider then model id.
    public func normalizedRows(source: ModelCatalogSource = .manifest) -> [NormalizedModelCatalogRow] {
        (self.providers ?? [:])
            .sorted { $0.key < $1.key }
            .flatMap { $0.value.normalizedRows(provider: $0.key, source: source) }
    }
}

struct LossyValue<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        self.value = try? Value(from: decoder)
    }
}

/// Normalized model catalog row used by lookup and picker surfaces (upstream `NormalizedModelCatalogRow`).
public struct NormalizedModelCatalogRow: Codable, Sendable, Equatable, Identifiable {
    /// Provider id.
    public var provider: String
    /// Model id.
    public var id: String
    /// `provider/model` reference.
    public var ref: String
    /// Case-insensitive merge key (`provider::model`).
    public var mergeKey: String
    /// Display name (model id when unset).
    public var name: String
    /// Row source.
    public var source: ModelCatalogSource
    /// Input modalities (`[.text]` when unset).
    public var input: [ModelInputType]
    /// Whether the model reasons (`false` when unset).
    public var reasoning: Bool
    /// Availability state (`available` when unset).
    public var status: ModelCatalogStatus
    /// Effective API (model override, else provider API).
    public var api: ModelAPI?
    /// Effective base URL (model override, else provider base URL).
    public var baseURL: String?
    /// Effective headers (provider headers merged with model headers).
    public var headers: [String: String]?
    /// Full underlying row.
    public var model: ModelCatalogModel

    /// Creates a normalized row from a manifest row and its provider catalog.
    public init(
        provider: String,
        model: ModelCatalogModel,
        providerCatalog: ModelCatalogProvider? = nil,
        source: ModelCatalogSource = .manifest
    ) {
        let providerID = provider.lowercased()
        self.provider = providerID
        self.id = model.id
        self.ref = "\(providerID)/\(model.id)"
        self.mergeKey = "\(providerID)::\(model.id.lowercased())"
        self.name = model.name ?? model.id
        self.source = source
        self.input = model.effectiveInput
        self.reasoning = model.reasoning ?? false
        self.status = model.effectiveStatus
        self.api = model.api ?? providerCatalog?.api
        self.baseURL = model.baseURL ?? providerCatalog?.baseURL
        let providerHeaders = providerCatalog?.headers
        if providerHeaders == nil, model.headers == nil {
            self.headers = nil
        } else {
            self.headers = (providerHeaders ?? [:]).merging(model.headers ?? [:]) { _, modelValue in modelValue }
        }
        self.model = model
    }
}

extension KeyedDecodingContainer {
    fileprivate func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        guard self.contains(key), (try? self.decodeNil(forKey: key)) == false else { return nil }
        return try? self.decode(type, forKey: key)
    }

    fileprivate func lenientNonEmptyString(_ key: Key) -> String? {
        guard let raw = self.lenient(String.self, key) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    fileprivate func lenientPositiveInt(_ key: Key) -> Int? {
        if let value = self.lenient(Int.self, key) {
            return value > 0 ? value : nil
        }
        guard let value = self.lenient(Double.self, key), value.isFinite, value > 0, value < Double(Int.max) else {
            return nil
        }
        return Int(value.rounded(.down))
    }
}

/// Converts catalog value types into the runtime config types that decode the same upstream JSON.
enum ModelCatalogJSONBridge {
    static func convert<Source: Encodable, Target: Decodable>(_ value: Source, to type: Target.Type) -> Target? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
