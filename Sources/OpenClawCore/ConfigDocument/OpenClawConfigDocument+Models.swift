import Foundation
import OpenClawProtocol

extension OpenClawConfigDocument {
    /// `models`: provider catalog overlays (upstream `ModelsConfigSchema`).
    ///
    /// SDK-only provider keys (`enabled`, `chatCompletionsPath`, `organizationID`, …) and the SDK
    /// sections `models.openAI`/`anthropic`/… never appear here.
    public struct Models: ConfigDocumentObject {
        /// `merge` or `replace`.
        public var mode: String?
        /// Providers keyed by provider id.
        public var providers: [String: ModelProvider]?
        /// Hosted catalog refresh (`enabled`, `url`).
        public var catalogRefresh: AnyCodable?
        /// Passthrough keys (the retired `pricing` until migrated).
        public var additionalProperties: [String: AnyCodable] = [:]
        /// Creates an empty section.
        public init() {}
        /// Typed fields.
        public static var configFields: [ConfigField<Self>] {
            [.init("mode", \.mode), .init("providers", \.providers), .init("catalogRefresh", \.catalogRefresh)]
        }
    }

    /// One `models.providers.<id>` entry.
    public struct ModelProvider: ConfigDocumentObject {
        /// Base URL (optional for bundled provider overlays).
        public var baseUrl: String?
        /// API key (secret).
        public var apiKey: ConfigSecretValue?
        /// `api-key`, `aws-sdk`, `oauth` or `token`.
        public var auth: String?
        /// Default API adapter (legacy `openai` is migrated to `openai-completions`).
        public var api: String?
        /// Default max output tokens.
        public var maxTokens: Double?
        /// Request timeout in seconds.
        public var timeoutSeconds: Int?
        /// Region.
        public var region: String?
        /// Inject `num_ctx` for OpenAI-compatible Ollama.
        public var injectNumCtxForOpenAICompat: Bool?
        /// Provider parameters.
        public var params: [String: AnyCodable]?
        /// Default agent runtime (`{id}`).
        public var agentRuntime: AgentReferenceID?
        /// Local service started before requests (server-only).
        public var localService: AnyCodable?
        /// Secret-bearing headers.
        public var headers: [String: ConfigSecretValue]?
        /// Inject the default `Authorization` header.
        public var authHeader: Bool?
        /// Request transport overrides (auth, proxy, TLS).
        public var request: AnyCodable?
        /// Model definitions.
        public var models: [ModelDefinition]?
        /// Passthrough keys.
        public var additionalProperties: [String: AnyCodable] = [:]
        /// Creates an empty provider.
        public init() {}
        /// Typed fields.
        public static var configFields: [ConfigField<Self>] {
            [
                .init("baseUrl", \.baseUrl), .init("apiKey", \.apiKey), .init("auth", \.auth), .init("api", \.api),
                .init("maxTokens", \.maxTokens), .init("timeoutSeconds", \.timeoutSeconds), .init("region", \.region),
                .init("injectNumCtxForOpenAICompat", \.injectNumCtxForOpenAICompat), .init("params", \.params),
                .init("agentRuntime", \.agentRuntime), .init("localService", \.localService), .init("headers", \.headers),
                .init("authHeader", \.authHeader), .init("request", \.request), .init("models", \.models),
            ]
        }

        /// The API adapter as the SDK ``ModelAPI`` (legacy aliases resolve; unknown values are `nil`).
        public var modelAPI: ModelAPI? {
            self.api.flatMap(ModelAPI.init(normalizing:))
        }
    }

    /// One `models.providers.<id>.models[]` definition (typed subset; cost, compat and media limits pass through).
    public struct ModelDefinition: ConfigDocumentObject {
        /// Provider-facing model id (required).
        public var id: String?
        /// Display name (required upstream; defaults to ``id``).
        public var name: String?
        /// API adapter override.
        public var api: String?
        /// Base URL override.
        public var baseUrl: String?
        /// Supports reasoning.
        public var reasoning: Bool?
        /// `text`, `image`, `video` and/or `audio`.
        public var input: [String]?
        /// Cost metadata.
        public var cost: AnyCodable?
        /// Context window in tokens.
        public var contextWindow: Double?
        /// Effective runtime context cap.
        public var contextTokens: Int?
        /// Max output tokens.
        public var maxTokens: Double?
        /// Think-level map (`null` means unsupported).
        public var thinkingLevelMap: AnyCodable?
        /// Provider parameters.
        public var params: [String: AnyCodable]?
        /// Agent runtime (`{id}`).
        public var agentRuntime: AgentReferenceID?
        /// Static headers.
        public var headers: [String: String]?
        /// Compatibility flags.
        public var compat: AnyCodable?
        /// Media input limits.
        public var mediaInput: AnyCodable?
        /// `models-add` marker.
        public var metadataSource: String?
        /// Passthrough keys.
        public var additionalProperties: [String: AnyCodable] = [:]
        /// Creates an empty definition.
        public init() {}
        /// Typed fields.
        public static var configFields: [ConfigField<Self>] {
            [
                .init("id", \.id), .init("name", \.name), .init("api", \.api), .init("baseUrl", \.baseUrl),
                .init("reasoning", \.reasoning), .init("input", \.input), .init("cost", \.cost),
                .init("contextWindow", \.contextWindow), .init("contextTokens", \.contextTokens), .init("maxTokens", \.maxTokens),
                .init("thinkingLevelMap", \.thinkingLevelMap), .init("params", \.params), .init("agentRuntime", \.agentRuntime),
                .init("headers", \.headers), .init("compat", \.compat), .init("mediaInput", \.mediaInput),
                .init("metadataSource", \.metadataSource),
            ]
        }
    }
}
