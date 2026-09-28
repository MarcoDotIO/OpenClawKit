import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenClawCore
import OpenClawProtocol

/// Canonical provider config and effective transport handed to an HTTP model provider.
///
/// The legacy ``ProviderServiceConfig`` shape only carries the default model. Providers built by
/// ``ModelProviderFactory`` also receive this context so they can read per-model compat flags,
/// thinking-level maps, params, token limits and timeouts for whichever model a request selects.
/// Providers built directly (without a context) fall back to endpoint defaults.
public struct ModelProviderRuntimeContext: Sendable, Equatable {
    /// Canonical provider config (models, compat, params, request overrides).
    public var providerConfig: ModelProviderConfig?
    /// Effective API/transport for this provider instance, when known.
    public var api: ModelAPI?

    /// Context without canonical config.
    public static let empty = ModelProviderRuntimeContext()

    /// Creates a runtime context.
    /// - Parameters:
    ///   - providerConfig: Canonical provider config.
    ///   - api: Effective API/transport.
    public init(providerConfig: ModelProviderConfig? = nil, api: ModelAPI? = nil) {
        self.providerConfig = providerConfig
        self.api = api
    }

    /// Returns the model definition for an id, when the context carries one.
    /// - Parameter modelID: Model identifier.
    public func modelDefinition(for modelID: String) -> ModelDefinitionConfig? {
        self.providerConfig?.model(withID: modelID)
    }
}

/// Endpoint class derived from a provider base URL (upstream `ProviderEndpointClass`, reduced to
/// the classes SDK payload policies need).
public enum ModelProviderEndpointClass: String, Sendable, Equatable, CaseIterable {
    /// No configured base URL: the provider's own default endpoint.
    case `default`
    /// `api.openai.com`.
    case openAIPublic = "openai-public"
    /// `chatgpt.com` (ChatGPT/Codex OAuth backend).
    case openAIChatGPT = "openai"
    /// Azure OpenAI hosts.
    case azureOpenAI = "azure-openai"
    /// `api.x.ai`.
    case xaiNative = "xai-native"
    /// `api.anthropic.com`.
    case anthropicPublic = "anthropic-public"
    /// `openrouter.ai`.
    case openRouter = "openrouter"
    /// `api.moonshot.ai` / `api.moonshot.cn`.
    case moonshotNative = "moonshot-native"
    /// DashScope / Model Studio hosts.
    case modelStudioNative = "modelstudio-native"
    /// `api.z.ai` / `open.bigmodel.cn`.
    case zaiNative = "zai-native"
    /// `api.deepseek.com`.
    case deepseekNative = "deepseek-native"
    /// `api.mistral.ai`.
    case mistralPublic = "mistral-public"
    /// `api.cerebras.ai`.
    case cerebrasNative = "cerebras-native"
    /// `llm.chutes.ai`.
    case chutesNative = "chutes-native"
    /// Xiaomi MiMo hosts.
    case xiaomiNative = "xiaomi-native"
    /// Google Generative Language hosts.
    case googleGenerativeAI = "google-generative-ai"
    /// Google Vertex AI hosts.
    case googleVertex = "google-vertex"
    /// Loopback and `.local` hosts.
    case local
    /// Any other host (proxy-like).
    case custom
    /// Unparseable base URL.
    case invalid

    /// Classifies a base URL.
    /// - Parameter baseURL: Base URL string (empty or `nil` means the provider default).
    public static func resolve(baseURL: String?) -> ModelProviderEndpointClass {
        let trimmed = baseURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            return .default
        }
        guard let host = Self.hostname(of: trimmed) else {
            return .invalid
        }
        switch host {
        case "api.openai.com":
            return .openAIPublic
        case "chatgpt.com":
            return .openAIChatGPT
        case "api.x.ai":
            return .xaiNative
        case "api.anthropic.com":
            return .anthropicPublic
        case "openrouter.ai":
            return .openRouter
        case "api.moonshot.ai", "api.moonshot.cn":
            return .moonshotNative
        case "api.z.ai", "open.bigmodel.cn":
            return .zaiNative
        case "api.deepseek.com":
            return .deepseekNative
        case "api.mistral.ai":
            return .mistralPublic
        case "api.cerebras.ai":
            return .cerebrasNative
        case "llm.chutes.ai":
            return .chutesNative
        case "generativelanguage.googleapis.com":
            return .googleGenerativeAI
        default:
            break
        }
        if [".openai.azure.com", ".cognitiveservices.azure.com", ".services.ai.azure.com", ".api.cognitive.microsoft.com"]
            .contains(where: { host.hasSuffix($0) })
        {
            return .azureOpenAI
        }
        if host.hasSuffix("dashscope.aliyuncs.com") || host.hasSuffix("dashscope-intl.aliyuncs.com") {
            return .modelStudioNative
        }
        if host.hasSuffix("xiaomimimo.com") {
            return .xiaomiNative
        }
        if host == "aiplatform.googleapis.com" || host.hasSuffix("-aiplatform.googleapis.com") {
            return .googleVertex
        }
        if ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
            || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host.hasSuffix(".internal")
        {
            return .local
        }
        return .custom
    }

    /// Lowercased hostname of a URL string (a bare host is accepted).
    /// - Parameter raw: URL string.
    public static func hostname(of raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let host = URLComponents(string: trimmed)?.host, !host.isEmpty {
            return host.lowercased()
        }
        if let host = URLComponents(string: "https://\(trimmed)")?.host, !host.isEmpty {
            return host.lowercased()
        }
        return nil
    }

    /// Whether the class is a known first-party OpenAI endpoint.
    public var isKnownNativeOpenAI: Bool {
        self == .openAIPublic || self == .openAIChatGPT || self == .azureOpenAI
    }

    /// Whether the class is a configured non-native (proxy-like) endpoint.
    public var isProxyLike: Bool {
        self == .custom || self == .openRouter
    }
}

/// Normalized endpoint settings shared by the HTTP provider engines.
struct ProviderEndpointSettings: Sendable {
    /// Provider identifier used for responses, errors and policy decisions.
    var providerID: String
    var enabled: Bool
    var api: ModelAPI
    var baseURL: String
    var authMode: ProviderServiceAuthMode
    var apiKey: String?
    var accessToken: String?
    var headers: [String: String]
    var organizationID: String?
    var apiVersion: String?
    var defaultModelID: String
    var configuredFastMode: Bool?
    var chatCompletionsPath: String
    var messagesPath: String
    var region: String?
    var profile: String?
    var metadata: [String: String]
    var runtime: ModelProviderRuntimeContext

    /// Default request timeout for model calls without an explicit policy or config timeout.
    static let defaultTimeoutInterval: TimeInterval = 120

    init(
        providerID: String,
        service: ProviderServiceConfig,
        api: ModelAPI,
        runtime: ModelProviderRuntimeContext
    ) {
        self.providerID = providerID
        self.enabled = service.enabled
        self.api = runtime.api ?? api
        self.baseURL = service.baseURL
        self.authMode = service.authMode
        self.apiKey = service.apiKey
        self.accessToken = service.accessToken
        self.headers = service.headers
        self.organizationID = service.organizationID
        self.apiVersion = service.apiVersion
        self.defaultModelID = service.modelID
        self.configuredFastMode = service.fastMode
        self.chatCompletionsPath = service.chatCompletionsPath
        self.messagesPath = service.messagesPath
        self.region = service.region
        self.profile = service.profile
        self.metadata = service.metadata
        self.runtime = runtime
    }

    /// Canonical provider id (lowercased; `grok` → `xai`, `openai-codex`/`codex` → `openai`).
    var canonicalProviderID: String {
        ProviderRuntimeIdentity.canonicalProviderID(self.providerID)
    }

    /// Model id for a request (request override, then configured default).
    func resolvedModelID(for request: ModelGenerationRequest) -> String {
        request.resolvedModelID ?? ModelGenerationRequest.normalized(self.defaultModelID) ?? self.defaultModelID
    }

    /// Model definition for the resolved model, when the runtime context carries one.
    func modelDefinition(for modelID: String) -> ModelDefinitionConfig? {
        self.runtime.modelDefinition(for: modelID)
    }

    /// Base URL for a request (request metadata override, then config, then the provider default).
    func resolvedBaseURLString(for request: ModelGenerationRequest, defaultBaseURL: String? = nil) -> String {
        if let override = request.resolvedBaseURL {
            return override
        }
        let configured = self.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty {
            return configured
        }
        return defaultBaseURL ?? ""
    }

    /// Parsed base URL for a request.
    func resolvedBaseURL(for request: ModelGenerationRequest, defaultBaseURL: String? = nil) throws -> URL {
        let raw = self.resolvedBaseURLString(for: request, defaultBaseURL: defaultBaseURL)
        guard !raw.isEmpty, let url = URL(string: raw), url.scheme != nil else {
            throw OpenClawCoreError.invalidConfiguration("\(self.providerID) base URL is invalid")
        }
        return url
    }

    /// Output-token limit: policy override, then model, provider, and metadata defaults.
    func maxTokens(for request: ModelGenerationRequest, model: ModelDefinitionConfig?) -> Int? {
        if let maxTokens = request.policy.maxTokens {
            return maxTokens
        }
        if let paramsMaxTokens = ProviderRuntimeParams.int(model?.params, keys: ["maxTokens", "max_tokens"]) {
            return paramsMaxTokens
        }
        if let model, model.maxTokens > 0 {
            return model.maxTokens
        }
        if let providerMaxTokens = self.runtime.providerConfig?.maxTokens {
            return providerMaxTokens
        }
        if let raw = self.metadata["maxTokens"], let parsed = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)), parsed > 0 {
            return parsed
        }
        return nil
    }

    /// Request timeout: policy override, then provider `timeoutSeconds`, then metadata, then default.
    func timeoutInterval(for request: ModelGenerationRequest) -> TimeInterval {
        if let timeoutMs = request.policy.requestTimeoutMs {
            return TimeInterval(timeoutMs) / 1000
        }
        if let timeoutSeconds = self.runtime.providerConfig?.timeoutSeconds {
            return TimeInterval(timeoutSeconds)
        }
        for key in ["requestTimeoutMs", "openai.requestTimeoutMs"] {
            if let raw = self.metadata[key], let parsed = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)), parsed > 0 {
                return TimeInterval(parsed) / 1000
            }
        }
        return Self.defaultTimeoutInterval
    }

    /// Provider headers, config request headers, model headers and request headers merged in that order.
    func mergedHeaders(for request: ModelGenerationRequest, model: ModelDefinitionConfig?) -> [String: String] {
        var headers = self.headers
        if let requestHeaders = self.runtime.providerConfig?.request?.headers {
            headers.merge(requestHeaders.compactMapValues(\.stringValue)) { _, value in value }
        }
        if let model {
            headers.merge(model.headers) { _, value in value }
        }
        headers.merge(request.resolvedRequestHeaders) { _, value in value }
        return headers
    }

    /// Resolves the bearer credential for the configured auth mode.
    func bearerCredential(for request: ModelGenerationRequest) throws -> String? {
        switch self.authMode {
        case .apiKey:
            return try ProviderRequestResolution.resolveAPIKey(
                configured: self.apiKey,
                request: request,
                providerID: self.providerID
            )
        case .bearerToken, .oauthToken:
            return try ProviderRequestResolution.resolveAccessToken(
                configured: self.accessToken ?? self.apiKey,
                request: request,
                providerID: self.providerID
            )
        case .none:
            return ModelGenerationRequest.normalized(self.apiKey) ?? request.resolvedAPIKey
        case .awsSDK:
            return nil
        }
    }

    /// Applies an upstream `request.auth` override; returns `true` when it replaced default auth.
    func applyRequestAuthOverride(to urlRequest: inout URLRequest) -> Bool {
        guard let auth = self.runtime.providerConfig?.request?.auth else {
            return false
        }
        switch auth {
        case .providerDefault:
            return false
        case .authorizationBearer(let token):
            guard let value = token.stringValue.flatMap(ModelGenerationRequest.normalized) else { return false }
            urlRequest.setValue("Bearer \(value)", forHTTPHeaderField: "Authorization")
            return true
        case .header(let name, let value, let prefix):
            guard let secret = value.stringValue.flatMap(ModelGenerationRequest.normalized) else { return false }
            urlRequest.setValue("\(prefix ?? "")\(secret)", forHTTPHeaderField: name)
            return true
        }
    }

    /// Base JSON POST request with timeout and merged headers applied.
    func makeJSONRequest(
        url: URL,
        request: ModelGenerationRequest,
        model: ModelDefinitionConfig?,
        streaming: Bool
    ) -> URLRequest {
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if streaming {
            urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        }
        urlRequest.timeoutInterval = self.timeoutInterval(for: request)
        return urlRequest
    }

    /// Appends slash-separated path segments to a base URL.
    static func appending(path: String, to baseURL: URL) -> URL {
        var endpoint = baseURL
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        for segment in trimmed.split(separator: "/") {
            endpoint = endpoint.appendingPathComponent(String(segment))
        }
        return endpoint
    }

    /// Base URL string without trailing slashes.
    static func trimmingTrailingSlashes(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }
}

/// Provider identity helpers shared by runtime policies.
enum ProviderRuntimeIdentity {
    /// Canonical provider id for policy decisions.
    static func canonicalProviderID(_ providerID: String) -> String {
        let normalized = providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "grok", "x-ai":
            return "xai"
        case "openai-codex", "codex":
            return "openai"
        case "z.ai", "z-ai":
            return "zai"
        default:
            return normalized
        }
    }
}

/// Typed readers for `params` dictionaries.
enum ProviderRuntimeParams {
    static func value(_ params: [String: AnyCodable]?, keys: [String]) -> AnyCodable? {
        guard let params else { return nil }
        for key in keys {
            if let value = params[key], !value.isNull {
                return value
            }
        }
        return nil
    }

    static func int(_ params: [String: AnyCodable]?, keys: [String]) -> Int? {
        guard let value = self.value(params, keys: keys) else { return nil }
        if let int = value.intValue, int > 0 {
            return int
        }
        if let string = value.stringValue, let parsed = Int(string), parsed > 0 {
            return parsed
        }
        return nil
    }

    static func string(_ params: [String: AnyCodable]?, keys: [String]) -> String? {
        guard let value = self.value(params, keys: keys)?.stringValue else { return nil }
        return ModelGenerationRequest.normalized(value)
    }
}
