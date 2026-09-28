import Foundation
import OpenClawProtocol

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
        self.decodeLenientPreservingRaw(from: container, forKey: key).api
    }

    /// Decodes an optional `api` field leniently and also returns an unrecognized raw identifier so
    /// callers can round-trip it and refuse to route it.
    static func decodeLenientPreservingRaw<K: CodingKey>(
        from container: KeyedDecodingContainer<K>,
        forKey key: K
    ) -> (api: ModelAPI?, unrecognized: String?) {
        guard let raw = container.decodeLenient(String.self, forKey: key) else {
            return (nil, nil)
        }
        guard let api = ModelAPI(normalizing: raw) else {
            container.recordConfigIssue(
                "Unknown model api \"\(raw)\"; the value is ignored.",
                kind: .unknownEnumValue,
                forKey: key
            )
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return (nil, trimmed.isEmpty ? nil : trimmed)
        }
        if let message = Self.legacyValidationMessage(for: raw) {
            container.recordConfigIssue(message, kind: .legacyKey, forKey: key)
        }
        return (api, nil)
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

/// Code-mode tier declared by model compat (upstream `compat.codeMode`).
public enum ModelCompatCodeMode: String, Codable, Sendable, Equatable, CaseIterable {
    /// Code mode is the preferred tool surface for this model.
    case preferred
    /// Code mode is available but not preferred (upstream default when absent).
    case capable
}

/// Prompt-cache marker convention (upstream `compat.cacheControlFormat`).
public enum ModelCompatCacheControlFormat: String, Codable, Sendable, Equatable, CaseIterable {
    /// Anthropic-style `cache_control: {type: "ephemeral"}` markers.
    case anthropic
}

/// Fast-mode setting (upstream `FastMode`: `true | false | "auto"`).
///
/// ``auto`` keeps fast mode on for the first seconds of a run (default 60) and then turns it off.
/// Wire values decode from booleans or strings; ``init(normalizing:)`` accepts the upstream aliases.
public enum FastMode: String, Codable, Sendable, Equatable, CaseIterable {
    /// Fast mode disabled.
    case off
    /// Fast mode enabled.
    case on
    /// Fast mode enabled only at the start of a run.
    case auto

    /// Default seconds `auto` keeps fast mode on (upstream `DEFAULT_FAST_MODE_AUTO_ON_SECONDS`).
    public static let defaultAutoOnSeconds = 60

    /// Normalizes upstream aliases: off/false/no/0/disable/disabled/normal, on/true/yes/1/enable/
    /// enabled/fast and auto/automatic.
    /// - Parameter raw: Raw setting.
    public init?(normalizing raw: String) {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "off", "false", "no", "0", "disable", "disabled", "normal":
            self = .off
        case "on", "true", "yes", "1", "enable", "enabled", "fast":
            self = .on
        case "auto", "automatic":
            self = .auto
        default:
            return nil
        }
    }

    /// Normalizes a JSON value (boolean or string) into a setting.
    /// - Parameter value: JSON value from config params.
    public init?(jsonValue value: AnyCodable?) {
        guard let value else { return nil }
        if let bool = value.boolValue {
            self = bool ? .on : .off
        } else if let string = value.stringValue, let mode = FastMode(normalizing: string) {
            self = mode
        } else if let number = value.intValue, number == 0 || number == 1 {
            self = number == 1 ? .on : .off
        } else {
            return nil
        }
    }

    /// Creates a setting from the legacy boolean flag.
    /// - Parameter enabled: Legacy fast-mode flag.
    public init(enabled: Bool) {
        self = enabled ? .on : .off
    }

    /// Legacy boolean view: `.on` is `true`, `.off` is `false`, `.auto` is `nil` (time dependent).
    public var legacyBoolValue: Bool? {
        switch self {
        case .off:
            return false
        case .on:
            return true
        case .auto:
            return nil
        }
    }

    /// Decodes a setting from a boolean or string.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let bool = try? container.decode(Bool.self) {
            self = bool ? .on : .off
            return
        }
        let raw = try container.decode(String.self)
        guard let mode = FastMode(normalizing: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown fast mode \(raw)")
        }
        self = mode
    }

    /// Encodes `.on`/`.off` as booleans and `.auto` as `"auto"` (upstream wire shape).
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .off:
            try container.encode(false)
        case .on:
            try container.encode(true)
        case .auto:
            try container.encode("auto")
        }
    }
}

/// Provider-specific compatibility flags carried alongside model definitions (upstream
/// `ModelCompatSchema`).
///
/// Wire keys follow upstream: `requiresOpenAIAnthropicToolPayload` encodes as
/// `requiresOpenAiAnthropicToolPayload` (both spellings decode) and `supportsJSONSchemaResponseFormat`
/// as `supportsJsonSchemaResponseFormat`. The retired `requiresMistralToolIDs` flag still decodes
/// but is never encoded.
public struct ModelCompatConfig: Codable, Sendable, Equatable {
    /// Whether the provider accepts the `store` field.
    public var supportsStore: Bool?
    /// Whether the provider accepts prompt-cache/session affinity keys.
    public var supportsPromptCacheKey: Bool?
    /// Opts the model into stored HTTP continuation on a verified compatible endpoint.
    public var supportsResponsesContinuation: Bool?
    /// Whether the provider accepts the `developer` role.
    public var supportsDeveloperRole: Bool?
    /// Whether the provider accepts a reasoning effort field.
    public var supportsReasoningEffort: Bool?
    /// Whether the model accepts `temperature`.
    public var supportsTemperature: Bool?
    /// Whether the provider honors the Responses top-level `instructions` field.
    public var supportsInstructions: Bool?
    /// Whether the provider reports usage in streaming responses (`stream_options.include_usage`).
    public var supportsUsageInStreaming: Bool?
    /// Whether the model supports tool calling.
    public var supportsTools: Bool?
    /// Code-mode tier.
    public var codeMode: ModelCompatCodeMode?
    /// Whether the provider accepts the `strict` field on tool definitions.
    public var supportsStrictMode: Bool?
    /// Whether the provider supports JSON-schema `response_format`.
    public var supportsJSONSchemaResponseFormat: Bool?
    /// Whether every message part must be flattened to plain strings.
    public var requiresStringContent: Bool?
    /// Whether unknown message keys must be stripped before requests.
    public var strictMessageKeys: Bool?
    /// Reasoning detail block types safe to expose in visible transcripts.
    public var visibleReasoningDetailTypes: [String]?
    /// Provider-accepted reasoning effort labels.
    public var supportedReasoningEfforts: [String]?
    /// Per-level reasoning effort overrides; values are provider-native and keep their case.
    public var reasoningEffortMap: [String: String]?
    /// Max-token field name.
    public var maxTokensField: ModelCompatMaxTokensField?
    /// Reasoning payload dialect.
    public var thinkingFormat: ModelCompatThinkingFormat?
    /// Whether tool results require a `name` field.
    public var requiresToolResultName: Bool?
    /// Whether a user message after tool results requires an assistant message in between.
    public var requiresAssistantAfterToolResult: Bool?
    /// Whether thinking blocks must be converted to text.
    public var requiresThinkingAsText: Bool?
    /// Whether replayed assistant messages need an empty `reasoning_content` when reasoning is on.
    public var requiresReasoningContentOnAssistantMessages: Bool?
    /// Named tool-schema profile.
    public var toolSchemaProfile: String?
    /// JSON Schema keywords rejected by the provider's tool validator.
    public var unsupportedToolSchemaKeywords: [String]?
    /// Encoding expected for tool-call arguments.
    public var toolCallArgumentsEncoding: String?
    /// Whether OpenAI-style calls must be reshaped to Anthropic-compatible tool payloads.
    public var requiresOpenAIAnthropicToolPayload: Bool?
    /// OpenRouter provider-routing preferences (upstream `OpenRouterRoutingSchema`), kept verbatim.
    public var openRouterRouting: [String: AnyCodable]?
    /// Vercel AI Gateway routing preferences (`{only, order}`), kept verbatim.
    public var vercelGatewayRouting: [String: AnyCodable]?
    /// Whether z.ai accepts top-level `tool_stream: true`.
    public var zaiToolStream: Bool?
    /// Prompt-cache marker convention.
    public var cacheControlFormat: ModelCompatCacheControlFormat?
    /// Whether to send session-affinity headers (`session_id`, `x-client-request-id`, `x-session-affinity`).
    public var sendSessionAffinityHeaders: Bool?
    /// Whether to send the OpenAI `session_id` cache-affinity header (default `true`).
    public var sendSessionIdHeader: Bool?
    /// Whether the provider accepts per-tool `eager_input_streaming`.
    public var supportsEagerToolInputStreaming: Bool?
    /// Whether the provider supports long prompt-cache retention.
    public var supportsLongCacheRetention: Bool?

    private var retiredRequiresMistralToolIDs: Bool?

    /// Retired upstream ("nativeWebSearchTool and requiresMistralToolIds are unused and retired").
    /// Decoded for back-compat; never encoded.
    @available(*, deprecated, message: "Retired upstream; the value is decoded but never encoded.")
    public var requiresMistralToolIDs: Bool? {
        get { self.retiredRequiresMistralToolIDs }
        set { self.retiredRequiresMistralToolIDs = newValue }
    }

    /// Creates compat flags; every flag defaults to `nil` (provider/endpoint default).
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
        requiresOpenAIAnthropicToolPayload: Bool? = nil,
        supportsPromptCacheKey: Bool? = nil,
        supportsResponsesContinuation: Bool? = nil,
        supportsTemperature: Bool? = nil,
        supportsInstructions: Bool? = nil,
        codeMode: ModelCompatCodeMode? = nil,
        supportsJSONSchemaResponseFormat: Bool? = nil,
        requiresStringContent: Bool? = nil,
        strictMessageKeys: Bool? = nil,
        visibleReasoningDetailTypes: [String]? = nil,
        supportedReasoningEfforts: [String]? = nil,
        reasoningEffortMap: [String: String]? = nil,
        requiresReasoningContentOnAssistantMessages: Bool? = nil,
        toolSchemaProfile: String? = nil,
        unsupportedToolSchemaKeywords: [String]? = nil,
        toolCallArgumentsEncoding: String? = nil,
        openRouterRouting: [String: AnyCodable]? = nil,
        vercelGatewayRouting: [String: AnyCodable]? = nil,
        zaiToolStream: Bool? = nil,
        cacheControlFormat: ModelCompatCacheControlFormat? = nil,
        sendSessionAffinityHeaders: Bool? = nil,
        sendSessionIdHeader: Bool? = nil,
        supportsEagerToolInputStreaming: Bool? = nil,
        supportsLongCacheRetention: Bool? = nil
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
        self.retiredRequiresMistralToolIDs = requiresMistralToolIDs
        self.requiresOpenAIAnthropicToolPayload = requiresOpenAIAnthropicToolPayload
        self.supportsPromptCacheKey = supportsPromptCacheKey
        self.supportsResponsesContinuation = supportsResponsesContinuation
        self.supportsTemperature = supportsTemperature
        self.supportsInstructions = supportsInstructions
        self.codeMode = codeMode
        self.supportsJSONSchemaResponseFormat = supportsJSONSchemaResponseFormat
        self.requiresStringContent = requiresStringContent
        self.strictMessageKeys = strictMessageKeys
        self.visibleReasoningDetailTypes = visibleReasoningDetailTypes
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.reasoningEffortMap = reasoningEffortMap
        self.requiresReasoningContentOnAssistantMessages = requiresReasoningContentOnAssistantMessages
        self.toolSchemaProfile = toolSchemaProfile
        self.unsupportedToolSchemaKeywords = unsupportedToolSchemaKeywords
        self.toolCallArgumentsEncoding = toolCallArgumentsEncoding
        self.openRouterRouting = openRouterRouting
        self.vercelGatewayRouting = vercelGatewayRouting
        self.zaiToolStream = zaiToolStream
        self.cacheControlFormat = cacheControlFormat
        self.sendSessionAffinityHeaders = sendSessionAffinityHeaders
        self.sendSessionIdHeader = sendSessionIdHeader
        self.supportsEagerToolInputStreaming = supportsEagerToolInputStreaming
        self.supportsLongCacheRetention = supportsLongCacheRetention
    }

    /// Vercel AI Gateway `only` provider list, when configured.
    public var vercelGatewayOnly: [String]? {
        self.vercelGatewayRouting?["only"]?.arrayValue?.compactMap(\.stringValue)
    }

    /// Vercel AI Gateway `order` provider list, when configured.
    public var vercelGatewayOrder: [String]? {
        self.vercelGatewayRouting?["order"]?.arrayValue?.compactMap(\.stringValue)
    }

    private enum CodingKeys: String, CodingKey {
        case supportsStore
        case supportsPromptCacheKey
        case supportsResponsesContinuation
        case supportsDeveloperRole
        case supportsReasoningEffort
        case supportsTemperature
        case supportsInstructions
        case supportsUsageInStreaming
        case supportsTools
        case codeMode
        case supportsStrictMode
        case supportsJSONSchemaResponseFormat = "supportsJsonSchemaResponseFormat"
        case requiresStringContent
        case strictMessageKeys
        case visibleReasoningDetailTypes
        case supportedReasoningEfforts
        case reasoningEffortMap
        case maxTokensField
        case thinkingFormat
        case requiresToolResultName
        case requiresAssistantAfterToolResult
        case requiresThinkingAsText
        case requiresReasoningContentOnAssistantMessages
        case toolSchemaProfile
        case unsupportedToolSchemaKeywords
        case toolCallArgumentsEncoding
        case requiresOpenAIAnthropicToolPayload = "requiresOpenAiAnthropicToolPayload"
        case openRouterRouting
        case vercelGatewayRouting
        case zaiToolStream
        case cacheControlFormat
        case sendSessionAffinityHeaders
        case sendSessionIdHeader
        case supportsEagerToolInputStreaming
        case supportsLongCacheRetention
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case requiresOpenAIAnthropicToolPayload
        case supportsJSONSchemaResponseFormat
        case requiresMistralToolIDs
        case requiresMistralToolIds
    }

    /// Decodes compat flags leniently; unknown enum values and mistyped leaves decode to `nil`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
        self.supportsStore = container.decodeLenient(Bool.self, forKey: .supportsStore)
        self.supportsPromptCacheKey = container.decodeLenient(Bool.self, forKey: .supportsPromptCacheKey)
        self.supportsResponsesContinuation = container.decodeLenient(Bool.self, forKey: .supportsResponsesContinuation)
        self.supportsDeveloperRole = container.decodeLenient(Bool.self, forKey: .supportsDeveloperRole)
        self.supportsReasoningEffort = container.decodeLenient(Bool.self, forKey: .supportsReasoningEffort)
        self.supportsTemperature = container.decodeLenient(Bool.self, forKey: .supportsTemperature)
        self.supportsInstructions = container.decodeLenient(Bool.self, forKey: .supportsInstructions)
        self.supportsUsageInStreaming = container.decodeLenient(Bool.self, forKey: .supportsUsageInStreaming)
        self.supportsTools = container.decodeLenient(Bool.self, forKey: .supportsTools)
        self.codeMode = container.decodeLenient(ModelCompatCodeMode.self, forKey: .codeMode)
        self.supportsStrictMode = container.decodeLenient(Bool.self, forKey: .supportsStrictMode)
        self.supportsJSONSchemaResponseFormat = container.decodeLenient(Bool.self, forKey: .supportsJSONSchemaResponseFormat)
            ?? legacy.decodeLenient(Bool.self, forKey: .supportsJSONSchemaResponseFormat)
        self.requiresStringContent = container.decodeLenient(Bool.self, forKey: .requiresStringContent)
        self.strictMessageKeys = container.decodeLenient(Bool.self, forKey: .strictMessageKeys)
        self.visibleReasoningDetailTypes = container.decodeLossyArrayIfPresent(String.self, forKey: .visibleReasoningDetailTypes)
        self.supportedReasoningEfforts = container.decodeLossyArrayIfPresent(String.self, forKey: .supportedReasoningEfforts)
        self.reasoningEffortMap = container.decodeLossyDictionaryIfPresent(String.self, forKey: .reasoningEffortMap)
        self.maxTokensField = container.decodeLenient(ModelCompatMaxTokensField.self, forKey: .maxTokensField)
        self.thinkingFormat = container.decodeLenient(ModelCompatThinkingFormat.self, forKey: .thinkingFormat)
        self.requiresToolResultName = container.decodeLenient(Bool.self, forKey: .requiresToolResultName)
        self.requiresAssistantAfterToolResult = container.decodeLenient(Bool.self, forKey: .requiresAssistantAfterToolResult)
        self.requiresThinkingAsText = container.decodeLenient(Bool.self, forKey: .requiresThinkingAsText)
        self.requiresReasoningContentOnAssistantMessages = container.decodeLenient(
            Bool.self,
            forKey: .requiresReasoningContentOnAssistantMessages
        )
        self.toolSchemaProfile = container.decodeLenient(String.self, forKey: .toolSchemaProfile)
        self.unsupportedToolSchemaKeywords = container.decodeLossyArrayIfPresent(String.self, forKey: .unsupportedToolSchemaKeywords)
        self.toolCallArgumentsEncoding = container.decodeLenient(String.self, forKey: .toolCallArgumentsEncoding)
        if let value = container.decodeLenient(Bool.self, forKey: .requiresOpenAIAnthropicToolPayload) {
            self.requiresOpenAIAnthropicToolPayload = value
        } else if let legacyValue = legacy.decodeLenient(Bool.self, forKey: .requiresOpenAIAnthropicToolPayload) {
            legacy.recordConfigIssue(
                "\"requiresOpenAIAnthropicToolPayload\" is a legacy key; use \"requiresOpenAiAnthropicToolPayload\"",
                kind: .legacyKey,
                forKey: .requiresOpenAIAnthropicToolPayload
            )
            self.requiresOpenAIAnthropicToolPayload = legacyValue
        } else {
            self.requiresOpenAIAnthropicToolPayload = nil
        }
        self.openRouterRouting = container.decodeLenient([String: AnyCodable].self, forKey: .openRouterRouting)
        self.vercelGatewayRouting = container.decodeLenient([String: AnyCodable].self, forKey: .vercelGatewayRouting)
        self.zaiToolStream = container.decodeLenient(Bool.self, forKey: .zaiToolStream)
        self.cacheControlFormat = container.decodeLenient(ModelCompatCacheControlFormat.self, forKey: .cacheControlFormat)
        self.sendSessionAffinityHeaders = container.decodeLenient(Bool.self, forKey: .sendSessionAffinityHeaders)
        self.sendSessionIdHeader = container.decodeLenient(Bool.self, forKey: .sendSessionIdHeader)
        self.supportsEagerToolInputStreaming = container.decodeLenient(Bool.self, forKey: .supportsEagerToolInputStreaming)
        self.supportsLongCacheRetention = container.decodeLenient(Bool.self, forKey: .supportsLongCacheRetention)

        let mistralKey: LegacyCodingKeys = legacy.contains(.requiresMistralToolIds) ? .requiresMistralToolIds : .requiresMistralToolIDs
        self.retiredRequiresMistralToolIDs = legacy.decodeLenient(Bool.self, forKey: mistralKey)
        if legacy.contains(mistralKey) {
            legacy.recordConfigIssue(
                "requiresMistralToolIds is retired upstream; the value is ignored when encoding.",
                kind: .retiredKey,
                forKey: mistralKey
            )
        }
    }

    /// Encodes compat flags with upstream keys, omitting unset flags and the retired Mistral flag.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.supportsStore, forKey: .supportsStore)
        try container.encodeIfPresent(self.supportsPromptCacheKey, forKey: .supportsPromptCacheKey)
        try container.encodeIfPresent(self.supportsResponsesContinuation, forKey: .supportsResponsesContinuation)
        try container.encodeIfPresent(self.supportsDeveloperRole, forKey: .supportsDeveloperRole)
        try container.encodeIfPresent(self.supportsReasoningEffort, forKey: .supportsReasoningEffort)
        try container.encodeIfPresent(self.supportsTemperature, forKey: .supportsTemperature)
        try container.encodeIfPresent(self.supportsInstructions, forKey: .supportsInstructions)
        try container.encodeIfPresent(self.supportsUsageInStreaming, forKey: .supportsUsageInStreaming)
        try container.encodeIfPresent(self.supportsTools, forKey: .supportsTools)
        try container.encodeIfPresent(self.codeMode, forKey: .codeMode)
        try container.encodeIfPresent(self.supportsStrictMode, forKey: .supportsStrictMode)
        try container.encodeIfPresent(self.supportsJSONSchemaResponseFormat, forKey: .supportsJSONSchemaResponseFormat)
        try container.encodeIfPresent(self.requiresStringContent, forKey: .requiresStringContent)
        try container.encodeIfPresent(self.strictMessageKeys, forKey: .strictMessageKeys)
        try container.encodeIfPresent(self.visibleReasoningDetailTypes, forKey: .visibleReasoningDetailTypes)
        try container.encodeIfPresent(self.supportedReasoningEfforts, forKey: .supportedReasoningEfforts)
        try container.encodeIfPresent(self.reasoningEffortMap, forKey: .reasoningEffortMap)
        try container.encodeIfPresent(self.maxTokensField, forKey: .maxTokensField)
        try container.encodeIfPresent(self.thinkingFormat, forKey: .thinkingFormat)
        try container.encodeIfPresent(self.requiresToolResultName, forKey: .requiresToolResultName)
        try container.encodeIfPresent(self.requiresAssistantAfterToolResult, forKey: .requiresAssistantAfterToolResult)
        try container.encodeIfPresent(self.requiresThinkingAsText, forKey: .requiresThinkingAsText)
        try container.encodeIfPresent(
            self.requiresReasoningContentOnAssistantMessages,
            forKey: .requiresReasoningContentOnAssistantMessages
        )
        try container.encodeIfPresent(self.toolSchemaProfile, forKey: .toolSchemaProfile)
        try container.encodeIfPresent(self.unsupportedToolSchemaKeywords, forKey: .unsupportedToolSchemaKeywords)
        try container.encodeIfPresent(self.toolCallArgumentsEncoding, forKey: .toolCallArgumentsEncoding)
        try container.encodeIfPresent(self.requiresOpenAIAnthropicToolPayload, forKey: .requiresOpenAIAnthropicToolPayload)
        try container.encodeIfPresent(self.openRouterRouting, forKey: .openRouterRouting)
        try container.encodeIfPresent(self.vercelGatewayRouting, forKey: .vercelGatewayRouting)
        try container.encodeIfPresent(self.zaiToolStream, forKey: .zaiToolStream)
        try container.encodeIfPresent(self.cacheControlFormat, forKey: .cacheControlFormat)
        try container.encodeIfPresent(self.sendSessionAffinityHeaders, forKey: .sendSessionAffinityHeaders)
        try container.encodeIfPresent(self.sendSessionIdHeader, forKey: .sendSessionIdHeader)
        try container.encodeIfPresent(self.supportsEagerToolInputStreaming, forKey: .supportsEagerToolInputStreaming)
        try container.encodeIfPresent(self.supportsLongCacheRetention, forKey: .supportsLongCacheRetention)
    }
}

/// One price tier of a model (upstream `cost.tieredPricing[]`).
///
/// `range` is half-open over prompt tokens: `[start, end)`, or `[start]` for an open upper tier.
public struct ModelTieredPricing: Codable, Sendable, Equatable {
    /// Input price per million tokens.
    public var input: Double
    /// Output price per million tokens.
    public var output: Double
    /// Cache-read price per million tokens.
    public var cacheRead: Double
    /// Cache-write price per million tokens.
    public var cacheWrite: Double
    /// Half-open prompt-token range: one element (open upper bound) or two elements.
    public var range: [Double]

    /// Creates one price tier.
    /// - Parameters:
    ///   - input: Input price per million tokens.
    ///   - output: Output price per million tokens.
    ///   - cacheRead: Cache-read price per million tokens.
    ///   - cacheWrite: Cache-write price per million tokens.
    ///   - range: `[start]` or `[start, end)`.
    public init(input: Double, output: Double, cacheRead: Double, cacheWrite: Double, range: [Double]) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.range = range
    }

    /// Returns whether `promptTokens` falls inside this tier's half-open range.
    /// - Parameter promptTokens: Prompt tokens of the request.
    public func contains(promptTokens: Int) -> Bool {
        guard let start = self.range.first else { return false }
        let tokens = Double(promptTokens)
        guard tokens >= start else { return false }
        if self.range.count >= 2 {
            return tokens < self.range[1]
        }
        return true
    }
}

/// Cost metadata associated with one model definition (prices per million tokens).
public struct ModelCostConfig: Codable, Sendable, Equatable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheWrite: Double
    /// Optional prompt-size price tiers; when present they override the flat prices.
    public var tieredPricing: [ModelTieredPricing]?

    public init(
        input: Double = 0,
        output: Double = 0,
        cacheRead: Double = 0,
        cacheWrite: Double = 0,
        tieredPricing: [ModelTieredPricing]? = nil
    ) {
        self.input = max(0, input)
        self.output = max(0, output)
        self.cacheRead = max(0, cacheRead)
        self.cacheWrite = max(0, cacheWrite)
        self.tieredPricing = tieredPricing
    }

    /// Whether every price is zero and no tiers are configured.
    public var isEmpty: Bool {
        self.input == 0 && self.output == 0 && self.cacheRead == 0 && self.cacheWrite == 0
            && (self.tieredPricing?.isEmpty ?? true)
    }

    private enum CodingKeys: String, CodingKey {
        case input
        case output
        case cacheRead
        case cacheWrite
        case tieredPricing
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.input = max(0, container.decodeLenient(Double.self, forKey: .input) ?? 0)
        self.output = max(0, container.decodeLenient(Double.self, forKey: .output) ?? 0)
        self.cacheRead = max(0, container.decodeLenient(Double.self, forKey: .cacheRead) ?? 0)
        self.cacheWrite = max(0, container.decodeLenient(Double.self, forKey: .cacheWrite) ?? 0)
        self.tieredPricing = container.decodeLossyArrayIfPresent(ModelTieredPricing.self, forKey: .tieredPricing)
    }

    /// Encodes prices; `tieredPricing` only when present.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.input, forKey: .input)
        try container.encode(self.output, forKey: .output)
        try container.encode(self.cacheRead, forKey: .cacheRead)
        try container.encode(self.cacheWrite, forKey: .cacheWrite)
        try container.encodeIfPresent(self.tieredPricing, forKey: .tieredPricing)
    }
}

/// Per-model thinking-level mapping (upstream `thinkingLevelMap`).
///
/// Keys are thinking levels (`off`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`). A missing
/// key means identity (send the level as-is); an explicit JSON `null` means the level is
/// unsupported and must be clamped. The distinction survives decoding and encoding.
public struct ModelThinkingLevelMap: Codable, Sendable, Equatable {
    /// Resolved mapping for one level.
    public enum Mapping: Sendable, Equatable {
        /// No entry: the level maps to itself.
        case identity
        /// Explicit `null`: the level is unsupported.
        case unsupported
        /// Provider-native value.
        case value(String)
    }

    /// Raw entries; a `nil` value records an explicit `null`.
    public var entries: [String: String?]

    /// Creates a thinking-level map.
    /// - Parameter entries: Level to provider value; `nil` marks the level unsupported.
    public init(_ entries: [String: String?] = [:]) {
        self.entries = entries
    }

    /// Returns the mapping for a level key.
    /// - Parameter level: Thinking-level raw value.
    public func mapping(for level: String) -> Mapping {
        let key = level.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let entry = self.entries[key] else {
            return .identity
        }
        guard let value = entry else {
            return .unsupported
        }
        return .value(value)
    }

    /// Returns the mapping for a thinking level.
    /// - Parameter level: Thinking level.
    public func mapping(for level: ThinkLevel) -> Mapping {
        self.mapping(for: level.rawValue)
    }

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }

        init(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            nil
        }
    }

    /// Decodes a map, preserving explicit `null` values.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        var entries: [String: String?] = [:]
        for key in container.allKeys {
            if try container.decodeNil(forKey: key) {
                entries[key.stringValue] = .some(nil)
            } else if let value = try? container.decode(String.self, forKey: key) {
                entries[key.stringValue] = .some(value)
            }
        }
        self.entries = entries
    }

    /// Encodes the map, writing explicit `null` for unsupported levels.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        for key in self.entries.keys.sorted() {
            if let value = self.entries[key] ?? nil {
                try container.encode(value, forKey: Key(stringValue: key))
            } else {
                try container.encodeNil(forKey: Key(stringValue: key))
            }
        }
    }
}

/// Agent runtime override for a provider or model (upstream `agentRuntime`).
public struct ModelAgentRuntimeConfig: Codable, Sendable, Equatable {
    /// Runtime identifier (for example `auto` or `openclaw`).
    public var id: String?

    /// Creates a runtime override.
    /// - Parameter id: Runtime identifier.
    public init(id: String? = nil) {
        self.id = id
    }
}

/// Image token accounting mode (upstream `mediaInput.image.tokenMode`).
public enum ModelImageTokenMode: String, Codable, Sendable, Equatable, CaseIterable {
    /// Tile-based accounting.
    case tile
    /// Detail-level accounting.
    case detail
    /// Provider-defined accounting.
    case provider
}

/// Image input limits for one model (upstream `mediaInput.image`).
public struct ModelImageInputLimits: Codable, Sendable, Equatable {
    /// Maximum encoded bytes per image.
    public var maxBytes: Int?
    /// Maximum pixel count per image.
    public var maxPixels: Int?
    /// Hard cap for the longest image side.
    public var maxSidePx: Int?
    /// Preferred longest side used when resizing.
    public var preferredSidePx: Int?
    /// Token accounting mode.
    public var tokenMode: ModelImageTokenMode?

    /// Creates image limits.
    public init(
        maxBytes: Int? = nil,
        maxPixels: Int? = nil,
        maxSidePx: Int? = nil,
        preferredSidePx: Int? = nil,
        tokenMode: ModelImageTokenMode? = nil
    ) {
        self.maxBytes = maxBytes
        self.maxPixels = maxPixels
        self.maxSidePx = maxSidePx
        self.preferredSidePx = preferredSidePx
        self.tokenMode = tokenMode
    }

    private enum CodingKeys: String, CodingKey {
        case maxBytes
        case maxPixels
        case maxSidePx
        case preferredSidePx
        case tokenMode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.maxBytes = container.decodeLenient(Int.self, forKey: .maxBytes)
        self.maxPixels = container.decodeLenient(Int.self, forKey: .maxPixels)
        self.maxSidePx = container.decodeLenient(Int.self, forKey: .maxSidePx)
        self.preferredSidePx = container.decodeLenient(Int.self, forKey: .preferredSidePx)
        self.tokenMode = container.decodeLenient(ModelImageTokenMode.self, forKey: .tokenMode)
    }
}

/// Media input limits for one model (upstream `mediaInput`).
public struct ModelMediaInputConfig: Codable, Sendable, Equatable {
    /// Image limits.
    public var image: ModelImageInputLimits?

    /// Creates media input limits.
    /// - Parameter image: Image limits.
    public init(image: ModelImageInputLimits? = nil) {
        self.image = image
    }
}

/// Canonical model definition block aligned with upstream `ModelDefinitionSchema`.
///
/// Encoding writes upstream keys only and omits defaults (zero context window/max tokens, empty
/// headers, zero cost) so strict upstream validation accepts the output. The SDK-only `fastMode`
/// flag lives in `params["fastMode"]` on the wire; decoding also accepts the legacy top-level key.
public struct ModelDefinitionConfig: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var api: ModelAPI?
    /// Unrecognized `api` identifier kept for round-tripping; routing refuses such models.
    public var unrecognizedAPI: String?
    /// Per-model base URL override (upstream `baseUrl`).
    public var baseURL: String?
    public var reasoning: Bool
    public var input: [ModelInputType]
    public var cost: ModelCostConfig
    public var contextWindow: Int
    /// Effective runtime context cap used for compaction and budgeting (upstream `contextTokens`).
    public var contextTokens: Int?
    public var maxTokens: Int
    /// Thinking-level mapping (missing = identity, `null` = unsupported).
    public var thinkingLevelMap: ModelThinkingLevelMap?
    /// Provider-specific request/runtime parameters.
    public var params: [String: AnyCodable]?
    /// Agent runtime override.
    public var agentRuntime: ModelAgentRuntimeConfig?
    public var headers: [String: String]
    public var compat: ModelCompatConfig?
    /// Media input limits.
    public var mediaInput: ModelMediaInputConfig?
    /// Metadata source marker (upstream only accepts `models-add`).
    public var metadataSource: String?

    /// Fast-mode setting read from `params.fastMode` / `params.fast_mode`.
    public var fastModeSetting: FastMode? {
        get {
            FastMode(jsonValue: self.params?["fastMode"]) ?? FastMode(jsonValue: self.params?["fast_mode"])
        }
        set {
            var params = self.params ?? [:]
            params.removeValue(forKey: "fast_mode")
            if let newValue {
                switch newValue {
                case .on:
                    params["fastMode"] = AnyCodable(true)
                case .off:
                    params["fastMode"] = AnyCodable(false)
                case .auto:
                    params["fastMode"] = AnyCodable("auto")
                }
            } else {
                params.removeValue(forKey: "fastMode")
            }
            self.params = params.isEmpty ? nil : params
        }
    }

    /// Legacy boolean fast-mode flag, stored in `params["fastMode"]`. `auto` reads as `true`.
    public var fastMode: Bool? {
        get {
            self.fastModeSetting.map { $0 != .off }
        }
        set {
            self.fastModeSetting = newValue.map(FastMode.init(enabled:))
        }
    }

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
        compat: ModelCompatConfig? = nil,
        baseURL: String? = nil,
        contextTokens: Int? = nil,
        thinkingLevelMap: ModelThinkingLevelMap? = nil,
        params: [String: AnyCodable]? = nil,
        agentRuntime: ModelAgentRuntimeConfig? = nil,
        mediaInput: ModelMediaInputConfig? = nil,
        metadataSource: String? = nil
    ) {
        self.id = id
        self.name = name ?? id
        self.api = api
        self.unrecognizedAPI = nil
        self.baseURL = baseURL
        self.reasoning = reasoning
        self.input = input.isEmpty ? [.text] : input
        self.cost = cost
        self.contextWindow = max(0, contextWindow)
        self.contextTokens = contextTokens.map { max(1, $0) }
        self.maxTokens = max(0, maxTokens)
        self.thinkingLevelMap = thinkingLevelMap
        self.params = params
        self.agentRuntime = agentRuntime
        self.headers = headers
        self.compat = compat
        self.mediaInput = mediaInput
        self.metadataSource = metadataSource
        if let fastMode {
            self.fastMode = fastMode
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case api
        case baseURL = "baseUrl"
        case reasoning
        case input
        case cost
        case contextWindow
        case contextTokens
        case maxTokens
        case thinkingLevelMap
        case params
        case agentRuntime
        case headers
        case compat
        case mediaInput
        case metadataSource
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case baseURL
        case fastMode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        self.id = id
        self.name = container.decodeLenient(String.self, forKey: .name) ?? id
        let api = ModelAPI.decodeLenientPreservingRaw(from: container, forKey: .api)
        self.api = api.api
        self.unrecognizedAPI = api.unrecognized
        self.baseURL = container.decodeLenient(String.self, forKey: .baseURL)
            ?? legacy.decodeLenient(String.self, forKey: .baseURL)
        self.reasoning = container.decodeLenient(Bool.self, forKey: .reasoning) ?? false
        self.input = container.decodeLossyArrayIfPresent(ModelInputType.self, forKey: .input) ?? [.text]
        if self.input.isEmpty {
            self.input = [.text]
        }
        self.cost = container.decodeLenient(ModelCostConfig.self, forKey: .cost) ?? ModelCostConfig()
        self.contextWindow = max(0, container.decodeLenient(Int.self, forKey: .contextWindow) ?? 0)
        self.contextTokens = container.decodeLenient(Int.self, forKey: .contextTokens).map { max(1, $0) }
        self.maxTokens = max(0, container.decodeLenient(Int.self, forKey: .maxTokens) ?? 0)
        self.thinkingLevelMap = container.decodeLenient(ModelThinkingLevelMap.self, forKey: .thinkingLevelMap)
        self.params = container.decodeLenient([String: AnyCodable].self, forKey: .params)
        self.agentRuntime = container.decodeLenient(ModelAgentRuntimeConfig.self, forKey: .agentRuntime)
        self.headers = container.decodeLossyDictionaryIfPresent(String.self, forKey: .headers) ?? [:]
        self.compat = container.decodeLenient(ModelCompatConfig.self, forKey: .compat)
        self.mediaInput = container.decodeLenient(ModelMediaInputConfig.self, forKey: .mediaInput)
        self.metadataSource = container.decodeLenient(String.self, forKey: .metadataSource)
        if self.fastModeSetting == nil,
           let legacyFastMode = legacy.decodeLenient(AnyCodable.self, forKey: .fastMode),
           let mode = FastMode(jsonValue: legacyFastMode)
        {
            legacy.recordConfigIssue(
                "Model \"fastMode\" is not an upstream model field; it is stored in params.fastMode.",
                kind: .legacyKey,
                forKey: .fastMode
            )
            self.fastModeSetting = mode
        }
    }

    /// Encodes the definition with upstream keys, omitting default-valued optional fields.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .id)
        try container.encode(self.name, forKey: .name)
        if let api = self.api {
            try container.encode(api, forKey: .api)
        } else if let unrecognizedAPI = self.unrecognizedAPI {
            try container.encode(unrecognizedAPI, forKey: .api)
        }
        try container.encodeIfPresent(self.baseURL, forKey: .baseURL)
        if self.reasoning {
            try container.encode(self.reasoning, forKey: .reasoning)
        }
        if self.input != [.text] {
            try container.encode(self.input.filter { $0 != .document }, forKey: .input)
        }
        if !self.cost.isEmpty {
            try container.encode(self.cost, forKey: .cost)
        }
        if self.contextWindow > 0 {
            try container.encode(self.contextWindow, forKey: .contextWindow)
        }
        try container.encodeIfPresent(self.contextTokens, forKey: .contextTokens)
        if self.maxTokens > 0 {
            try container.encode(self.maxTokens, forKey: .maxTokens)
        }
        try container.encodeIfPresent(self.thinkingLevelMap, forKey: .thinkingLevelMap)
        if let params = self.params, !params.isEmpty {
            try container.encode(params, forKey: .params)
        }
        try container.encodeIfPresent(self.agentRuntime, forKey: .agentRuntime)
        if !self.headers.isEmpty {
            try container.encode(self.headers, forKey: .headers)
        }
        try container.encodeIfPresent(self.compat, forKey: .compat)
        try container.encodeIfPresent(self.mediaInput, forKey: .mediaInput)
        try container.encodeIfPresent(self.metadataSource, forKey: .metadataSource)
    }
}

/// Local service started before calling a provider (upstream `localService`; server-side metadata).
public struct ModelProviderLocalServiceConfig: Codable, Sendable, Equatable {
    /// Executable started before model requests are sent.
    public var command: String
    /// Arguments passed without shell expansion.
    public var args: [String]?
    /// Working directory.
    public var cwd: String?
    /// Environment variables added to the process.
    public var env: [String: String]?
    /// Optional health endpoint polled before the provider is ready.
    public var healthURL: String?
    /// Startup readiness timeout in milliseconds.
    public var readyTimeoutMs: Int?
    /// Idle timeout in milliseconds before stopping the service.
    public var idleStopMs: Int?

    /// Creates a local service declaration.
    public init(
        command: String,
        args: [String]? = nil,
        cwd: String? = nil,
        env: [String: String]? = nil,
        healthURL: String? = nil,
        readyTimeoutMs: Int? = nil,
        idleStopMs: Int? = nil
    ) {
        self.command = command
        self.args = args
        self.cwd = cwd
        self.env = env
        self.healthURL = healthURL
        self.readyTimeoutMs = readyTimeoutMs
        self.idleStopMs = idleStopMs
    }

    private enum CodingKeys: String, CodingKey {
        case command
        case args
        case cwd
        case env
        case healthURL = "healthUrl"
        case readyTimeoutMs
        case idleStopMs
    }
}

/// Provider request authentication override (upstream `request.auth`).
public enum ModelProviderRequestAuth: Codable, Sendable, Equatable {
    /// Use the provider's default authentication.
    case providerDefault
    /// Send `Authorization: Bearer <token>`.
    case authorizationBearer(token: SecretInput)
    /// Send a custom header `<headerName>: <prefix><value>`.
    case header(name: String, value: SecretInput, prefix: String?)

    private enum CodingKeys: String, CodingKey {
        case mode
        case token
        case headerName
        case value
        case prefix
    }

    /// Decodes an auth override by `mode`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let mode = try container.decode(String.self, forKey: .mode)
        switch mode {
        case "provider-default":
            self = .providerDefault
        case "authorization-bearer":
            self = .authorizationBearer(token: try container.decode(SecretInput.self, forKey: .token))
        case "header":
            self = .header(
                name: try container.decode(String.self, forKey: .headerName),
                value: try container.decode(SecretInput.self, forKey: .value),
                prefix: try container.decodeIfPresent(String.self, forKey: .prefix)
            )
        default:
            throw DecodingError.dataCorruptedError(forKey: .mode, in: container, debugDescription: "Unknown request auth mode \(mode)")
        }
    }

    /// Encodes an auth override with its `mode`.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .providerDefault:
            try container.encode("provider-default", forKey: .mode)
        case .authorizationBearer(let token):
            try container.encode("authorization-bearer", forKey: .mode)
            try container.encode(token, forKey: .token)
        case .header(let name, let value, let prefix):
            try container.encode("header", forKey: .mode)
            try container.encode(name, forKey: .headerName)
            try container.encode(value, forKey: .value)
            try container.encodeIfPresent(prefix, forKey: .prefix)
        }
    }
}

/// Provider request transport overrides (upstream `models.providers.*.request`).
///
/// `headers` and `auth` are applied by the SDK HTTP providers when they hold plaintext secrets.
/// `proxy` and `tls` are kept verbatim for round-tripping; the SDK does not configure them.
public struct ModelProviderRequestConfig: Codable, Sendable, Equatable {
    /// Extra request headers (plaintext or SecretRef).
    public var headers: [String: SecretInput]?
    /// Authentication override.
    public var auth: ModelProviderRequestAuth?
    /// Proxy settings, kept verbatim.
    public var proxy: [String: AnyCodable]?
    /// TLS settings, kept verbatim.
    public var tls: [String: AnyCodable]?
    /// Whether requests may target private-network hosts.
    public var allowPrivateNetwork: Bool?

    /// Creates request overrides.
    public init(
        headers: [String: SecretInput]? = nil,
        auth: ModelProviderRequestAuth? = nil,
        proxy: [String: AnyCodable]? = nil,
        tls: [String: AnyCodable]? = nil,
        allowPrivateNetwork: Bool? = nil
    ) {
        self.headers = headers
        self.auth = auth
        self.proxy = proxy
        self.tls = tls
        self.allowPrivateNetwork = allowPrivateNetwork
    }

    private enum CodingKeys: String, CodingKey {
        case headers
        case auth
        case proxy
        case tls
        case allowPrivateNetwork
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.headers = container.decodeLossyDictionaryIfPresent(SecretInput.self, forKey: .headers)
        self.auth = container.decodeLenient(ModelProviderRequestAuth.self, forKey: .auth)
        self.proxy = container.decodeLenient([String: AnyCodable].self, forKey: .proxy)
        self.tls = container.decodeLenient([String: AnyCodable].self, forKey: .tls)
        self.allowPrivateNetwork = container.decodeLenient(Bool.self, forKey: .allowPrivateNetwork)
    }
}

/// Hosted model-catalog refresh settings (upstream `models.catalogRefresh`).
public struct ModelCatalogRefreshConfig: Codable, Sendable, Equatable {
    /// Whether hosted catalog refresh is enabled (SDK default: off).
    public var enabled: Bool?
    /// Catalog URL override; must be https, or http on localhost.
    public var url: String?

    /// Creates refresh settings.
    /// - Parameters:
    ///   - enabled: Whether refresh is enabled.
    ///   - url: Catalog URL override.
    public init(enabled: Bool? = nil, url: String? = nil) {
        self.enabled = enabled
        self.url = url
    }

    /// Whether ``url`` is acceptable: https, or http on `localhost`, `127.0.0.1` or `[::1]`.
    public var hasValidURL: Bool {
        guard let url else { return true }
        return Self.isValidCatalogURL(url)
    }

    /// Validates a catalog URL (https, or http on localhost/127.0.0.1/[::1]).
    /// - Parameter raw: URL string.
    public static func isValidCatalogURL(_ raw: String) -> Bool {
        guard let components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty
        else {
            return false
        }
        if scheme == "https" {
            return true
        }
        return scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
    }
}

/// Canonical provider config aligned with upstream `ModelProviderSchema`.
///
/// Wire keys: `baseUrl` is encoded (the legacy `baseURL` key still decodes); `apiKey` and provider
/// `headers` accept SecretInput values (plaintext strings, `${ENV}` templates, or SecretRef objects).
/// SDK-only keys (`enabled`, `chatCompletionsPath`, `messagesPath`, `apiVersion`, `organizationID`,
/// `profile`, `tenantID`, `scope`, `metadata`) are encoded only when they differ from their defaults.
/// A missing `baseUrl` decodes as an empty string; runtimes then use the catalog default for the
/// provider id.
public struct ModelProviderConfig: Codable, Sendable, Equatable {
    /// Bundled provider overlay ids that may omit `baseUrl` and `models`
    /// (upstream `src/config/model-provider-overlay-ids.ts`).
    public static let builtInOverlayProviderIDs: Set<String> = [
        "amazon-bedrock", "amazon-bedrock-mantle", "anthropic", "anthropic-vertex", "arcee",
        "azure-openai-responses", "byteplus", "byteplus-plan", "cerebras", "chutes", "claude-cli",
        "clawrouter", "cloudflare-ai-gateway", "codex", "comfy", "copilot-proxy", "dashscope",
        "deepinfra", "deepseek", "fal", "fireworks", "github-copilot", "gmi", "gmi-cloud", "gmicloud",
        "google", "google-antigravity", "google-gemini-cli", "google-vertex", "groq", "huggingface",
        "kilocode", "kimi", "kimi-coding", "litellm", "lmstudio", "meta", "microsoft-foundry", "minimax",
        "minimax-portal", "mistral", "modelstudio", "moonshot", "moonshot-ai", "moonshotai", "nvidia",
        "novita", "novita-ai", "novitaai", "ollama", "ollama-cloud", "openai", "opencode", "opencode-go",
        "openrouter", "qianfan", "qwen", "qwen-token-plan", "qwencloud", "sglang", "stepfun",
        "stepfun-plan", "synthetic", "tencent-tokenhub", "tencent-tokenplan", "together", "venice",
        "vercel-ai-gateway", "vllm", "volcengine", "volcengine-plan", "vydra", "x-ai", "xai", "xiaomi",
        "xiaomi-token-plan", "z.ai", "z-ai", "zai",
    ]

    /// Returns whether a provider id is a bundled overlay id (case-insensitive).
    /// - Parameter providerID: Provider identifier.
    public static func isBuiltInOverlayProviderID(_ providerID: String) -> Bool {
        Self.builtInOverlayProviderIDs.contains(providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    public var enabled: Bool
    public var baseURL: String
    /// API key or secret reference (plaintext, `${ENV}` template, or SecretRef object).
    public var apiKeyInput: SecretInput?
    public var auth: ModelProviderAuthMode?
    public var api: ModelAPI?
    /// Unrecognized `api` identifier kept for round-tripping; factories skip such providers.
    public var unrecognizedAPI: String?
    public var injectNumCtxForOpenAICompat: Bool
    /// Provider headers (plaintext or SecretRef).
    public var headerInputs: [String: SecretInput]
    public var authHeader: Bool?
    public var models: [ModelDefinitionConfig]
    /// Provider-level default max output tokens.
    public var maxTokens: Int?
    /// Provider request timeout in seconds.
    public var timeoutSeconds: Int?
    /// Provider-specific runtime parameters.
    public var params: [String: AnyCodable]?
    /// Default agent runtime for models under this provider.
    public var agentRuntime: ModelAgentRuntimeConfig?
    /// Local service declaration (server-side metadata; not started by the SDK).
    public var localService: ModelProviderLocalServiceConfig?
    /// Request transport overrides.
    public var request: ModelProviderRequestConfig?
    public var chatCompletionsPath: String
    public var messagesPath: String
    public var apiVersion: String?
    public var organizationID: String?
    public var region: String?
    public var profile: String?
    public var tenantID: String?
    public var scope: String?
    public var metadata: [String: String]

    /// Plaintext API key view of ``apiKeyInput`` (`nil` for SecretRef inputs).
    public var apiKey: String? {
        get { self.apiKeyInput?.stringValue }
        set { self.apiKeyInput = newValue.map(SecretInput.string) }
    }

    /// Plaintext header view of ``headerInputs`` (SecretRef entries are omitted).
    public var headers: [String: String] {
        get { self.headerInputs.compactMapValues(\.stringValue) }
        set { self.headerInputs = newValue.mapValues(SecretInput.string) }
    }

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
        metadata: [String: String] = [:],
        apiKeyInput: SecretInput? = nil,
        headerInputs: [String: SecretInput]? = nil,
        maxTokens: Int? = nil,
        timeoutSeconds: Int? = nil,
        params: [String: AnyCodable]? = nil,
        agentRuntime: ModelAgentRuntimeConfig? = nil,
        localService: ModelProviderLocalServiceConfig? = nil,
        request: ModelProviderRequestConfig? = nil
    ) {
        self.enabled = enabled
        self.baseURL = baseURL
        self.apiKeyInput = apiKeyInput ?? apiKey.map(SecretInput.string)
        self.auth = auth
        self.api = api
        self.unrecognizedAPI = nil
        self.injectNumCtxForOpenAICompat = injectNumCtxForOpenAICompat
        self.headerInputs = headerInputs ?? headers.mapValues(SecretInput.string)
        self.authHeader = authHeader
        self.models = models
        self.maxTokens = maxTokens.map { max(1, $0) }
        self.timeoutSeconds = timeoutSeconds.map { max(1, $0) }
        self.params = params
        self.agentRuntime = agentRuntime
        self.localService = localService
        self.request = request
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
        case baseURL = "baseUrl"
        case apiKey
        case auth
        case api
        case maxTokens
        case timeoutSeconds
        case region
        case injectNumCtxForOpenAICompat
        case params
        case agentRuntime
        case localService
        case headers
        case authHeader
        case request
        case models
        case chatCompletionsPath
        case messagesPath
        case apiVersion
        case organizationID
        case profile
        case tenantID
        case scope
        case metadata
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case baseURL
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
        let legacyModelID = legacyContainer.decodeLenient(String.self, forKey: .modelID)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let legacyAccessToken = legacyContainer.decodeLenient(String.self, forKey: .accessToken)

        let decodedAPI = ModelAPI.decodeLenientPreservingRaw(from: container, forKey: .api)
        let resolvedAPI = decodedAPI.api ?? legacyAPIStyle.map(ModelAPI.init(legacyStyle:))
        let resolvedAuth = container.decodeLenient(ModelProviderAuthMode.self, forKey: .auth)
            ?? legacyAuthMode.flatMap(ModelProviderAuthMode.init(legacyMode:))
        let resolvedHeaders = container.decodeLossyDictionaryIfPresent(SecretInput.self, forKey: .headers) ?? [:]
        let decodedModels = container.decodeLossyArrayIfPresent(ModelDefinitionConfig.self, forKey: .models) ?? []
        let fallbackModelID = legacyModelID.flatMap { $0.isEmpty ? nil : $0 }

        self.enabled = container.decodeLenient(Bool.self, forKey: .enabled) ?? false
        if let baseURL = container.decodeLenient(String.self, forKey: .baseURL) {
            self.baseURL = baseURL
        } else if let legacyBaseURL = legacyContainer.decodeLenient(String.self, forKey: .baseURL) {
            legacyContainer.recordConfigIssue(
                "\"baseURL\" is a legacy key; use \"baseUrl\"",
                kind: .legacyKey,
                forKey: .baseURL
            )
            self.baseURL = legacyBaseURL
        } else {
            self.baseURL = ""
        }
        self.apiKeyInput = container.decodeLenient(SecretInput.self, forKey: .apiKey)
            ?? legacyAccessToken.map(SecretInput.string)
        self.auth = resolvedAuth
        self.api = resolvedAPI
        self.unrecognizedAPI = decodedAPI.unrecognized
        self.maxTokens = container.decodeLenient(Int.self, forKey: .maxTokens).map { max(1, $0) }
        self.timeoutSeconds = container.decodeLenient(Int.self, forKey: .timeoutSeconds).map { max(1, $0) }
        self.injectNumCtxForOpenAICompat = container.decodeLenient(Bool.self, forKey: .injectNumCtxForOpenAICompat) ?? false
        self.params = container.decodeLenient([String: AnyCodable].self, forKey: .params)
        self.agentRuntime = container.decodeLenient(ModelAgentRuntimeConfig.self, forKey: .agentRuntime)
        self.localService = container.decodeLenient(ModelProviderLocalServiceConfig.self, forKey: .localService)
        self.headerInputs = resolvedHeaders
        self.authHeader = container.decodeLenient(Bool.self, forKey: .authHeader)
            ?? (legacyAuthMode == ProviderServiceAuthMode.none ? false : nil)
        self.request = container.decodeLenient(ModelProviderRequestConfig.self, forKey: .request)
        if !decodedModels.isEmpty {
            self.models = decodedModels
        } else if let fallbackModelID {
            self.models = [
                ModelDefinitionConfig(
                    id: fallbackModelID,
                    api: resolvedAPI,
                    headers: resolvedHeaders.compactMapValues(\.stringValue)
                ),
            ]
        } else {
            self.models = []
        }
        self.chatCompletionsPath = container.decodeLenient(String.self, forKey: .chatCompletionsPath) ?? "chat/completions"
        self.messagesPath = container.decodeLenient(String.self, forKey: .messagesPath) ?? "messages"
        self.apiVersion = container.decodeLenient(String.self, forKey: .apiVersion)
        self.organizationID = container.decodeLenient(String.self, forKey: .organizationID)
        self.region = container.decodeLenient(String.self, forKey: .region)
        self.profile = container.decodeLenient(String.self, forKey: .profile)
        self.tenantID = container.decodeLenient(String.self, forKey: .tenantID)
        self.scope = container.decodeLenient(String.self, forKey: .scope)
        self.metadata = container.decodeLossyDictionaryIfPresent(String.self, forKey: .metadata) ?? [:]
    }

    /// Encodes upstream keys (`baseUrl`, SecretInput `apiKey`/`headers`) and SDK-only keys only when
    /// they differ from their defaults.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if self.enabled {
            try container.encode(self.enabled, forKey: .enabled)
        }
        if !self.baseURL.isEmpty {
            try container.encode(self.baseURL, forKey: .baseURL)
        }
        try container.encodeIfPresent(self.apiKeyInput, forKey: .apiKey)
        try container.encodeIfPresent(self.auth, forKey: .auth)
        if let api = self.api {
            try container.encode(api, forKey: .api)
        } else if let unrecognizedAPI = self.unrecognizedAPI {
            try container.encode(unrecognizedAPI, forKey: .api)
        }
        try container.encodeIfPresent(self.maxTokens, forKey: .maxTokens)
        try container.encodeIfPresent(self.timeoutSeconds, forKey: .timeoutSeconds)
        try container.encodeIfPresent(self.region, forKey: .region)
        if self.injectNumCtxForOpenAICompat {
            try container.encode(self.injectNumCtxForOpenAICompat, forKey: .injectNumCtxForOpenAICompat)
        }
        if let params = self.params, !params.isEmpty {
            try container.encode(params, forKey: .params)
        }
        try container.encodeIfPresent(self.agentRuntime, forKey: .agentRuntime)
        try container.encodeIfPresent(self.localService, forKey: .localService)
        if !self.headerInputs.isEmpty {
            try container.encode(self.headerInputs, forKey: .headers)
        }
        try container.encodeIfPresent(self.authHeader, forKey: .authHeader)
        try container.encodeIfPresent(self.request, forKey: .request)
        try container.encode(self.models, forKey: .models)
        if self.chatCompletionsPath != "chat/completions" {
            try container.encode(self.chatCompletionsPath, forKey: .chatCompletionsPath)
        }
        if self.messagesPath != "messages" {
            try container.encode(self.messagesPath, forKey: .messagesPath)
        }
        try container.encodeIfPresent(self.apiVersion, forKey: .apiVersion)
        try container.encodeIfPresent(self.organizationID, forKey: .organizationID)
        try container.encodeIfPresent(self.profile, forKey: .profile)
        try container.encodeIfPresent(self.tenantID, forKey: .tenantID)
        try container.encodeIfPresent(self.scope, forKey: .scope)
        if !self.metadata.isEmpty {
            try container.encode(self.metadata, forKey: .metadata)
        }
    }

    /// Default model selection used by provider factories.
    public var defaultModel: ModelDefinitionConfig? {
        self.models.first
    }

    /// Returns the model definition for an id (exact match first, then case-insensitive).
    /// - Parameter modelID: Model identifier.
    public func model(withID modelID: String) -> ModelDefinitionConfig? {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = self.models.first(where: { $0.id == trimmed }) {
            return exact
        }
        let lowered = trimmed.lowercased()
        return self.models.first(where: { $0.id.lowercased() == lowered })
    }

    /// Upstream validation issues for a provider entry: custom (non-overlay) providers must declare
    /// `baseUrl` and `models`.
    /// - Parameter providerID: Provider identifier the config is keyed by.
    /// - Returns: Validation issues (empty when valid).
    public func validationIssues(providerID: String) -> [ConfigDecodeIssue] {
        guard !Self.isBuiltInOverlayProviderID(providerID) else { return [] }
        var issues: [ConfigDecodeIssue] = []
        if self.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(
                ConfigDecodeIssue(
                    path: "models.providers.\(providerID).baseUrl",
                    message: "custom model providers must declare baseUrl; provider overlays without baseUrl are only supported for bundled providers",
                    kind: .invalidValue
                )
            )
        }
        if self.models.isEmpty {
            issues.append(
                ConfigDecodeIssue(
                    path: "models.providers.\(providerID).models",
                    message: "custom model providers must declare models; provider overlays without models are only supported for bundled providers",
                    kind: .invalidValue
                )
            )
        }
        if let unrecognizedAPI {
            issues.append(
                ConfigDecodeIssue(
                    path: "models.providers.\(providerID).api",
                    message: "Unknown model api \"\(unrecognizedAPI)\"; the provider is skipped at runtime.",
                    kind: .unknownEnumValue
                )
            )
        }
        return issues
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
    ///
    /// The legacy shape carries only the default model; SDK providers receive the full canonical
    /// config separately for per-model compat, params and routing.
    public func legacyServiceConfig(providerID: String) -> ProviderServiceConfig {
        let normalizedProviderID = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = self.defaultModel
        let selectedAPI = model?.api ?? self.api ?? .openAICompletions
        let secretValue = self.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Upstream configs usually omit `auth`; a configured key then means API-key auth unless the
        // provider disables the Authorization header.
        let inferredAuth: ProviderServiceAuthMode = (secretValue?.isEmpty == false && self.authHeader != false) ? .apiKey : .none
        let authMode = self.auth?.legacyMode ?? inferredAuth
        let usesAccessToken = authMode == .bearerToken || authMode == .oauthToken
        var metadata = self.metadata.merging([
            "providerID": normalizedProviderID,
        ]) { current, _ in current }
        if metadata["maxTokens"] == nil, let maxTokens = model.flatMap({ $0.maxTokens > 0 ? $0.maxTokens : nil }) ?? self.maxTokens {
            metadata["maxTokens"] = String(maxTokens)
        }
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
            metadata: metadata
        )
    }

    /// Provider headers merged with a model's headers (model wins), plaintext values only.
    /// - Parameter model: Optional model definition.
    public func mergedHeaders(for model: ModelDefinitionConfig?) -> [String: String] {
        var headers = self.headers
        if let requestHeaders = self.request?.headers {
            headers.merge(requestHeaders.compactMapValues(\.stringValue)) { _, requestValue in requestValue }
        }
        guard let model else {
            return headers
        }
        return headers.merging(model.headers) { _, modelValue in modelValue }
    }
}
