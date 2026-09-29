import Foundation
import OpenClawCore
import OpenClawProtocol

/// Providers built from a provider map, plus the ids that were skipped and why.
public struct ModelProviderFactoryResult: Sendable {
    /// Providers built successfully.
    public var providers: [any ModelProvider]
    /// Skipped provider ids mapped to the reason (for example an unknown `api`).
    public var skipped: [String: String]

    /// Creates a result.
    /// - Parameters:
    ///   - providers: Built providers.
    ///   - skipped: Skipped provider ids and reasons.
    public init(providers: [any ModelProvider], skipped: [String: String]) {
        self.providers = providers
        self.skipped = skipped
    }
}

extension ModelProviderFactory {
    /// Builds providers for every entry of a `models.providers` map, skipping entries that cannot be
    /// routed (unknown `api`, unimplemented transports) instead of treating them as
    /// openai-completions.
    ///
    /// Keys that normalize to the same provider id (`openai` / `openai-codex`, `google` / `gemini`,
    /// `xai` / `grok`, …) never produce two providers with one id, which the router would silently
    /// collapse. The canonical key wins; a legacy `openai-codex` / `codex` entry is merged into
    /// `openai` as ChatGPT-route models when upstream's doctor migration would merge it (neither
    /// provider sets provider-level credentials, headers or transport overrides), and every other
    /// alias is reported in ``ModelProviderFactoryResult/skipped``.
    /// - Parameter configs: Provider configs keyed by provider id.
    /// - Returns: Built providers and skipped ids.
    public static func makeProviders(from configs: [String: ModelProviderConfig]) -> ModelProviderFactoryResult {
        var providers: [any ModelProvider] = []
        var skipped: [String: String] = [:]
        var groups: [String: [String]] = [:]
        for providerID in configs.keys {
            groups[OpenClawReferenceProviderCatalog.normalize(providerID: providerID), default: []].append(providerID)
        }
        var builtIDs: Set<String> = []
        for normalizedID in groups.keys.sorted() {
            let keys = (groups[normalizedID] ?? []).sorted()
            guard let primaryKey = keys.first(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedID })
                ?? keys.first,
                var config = configs[primaryKey]
            else {
                continue
            }
            for alias in keys where alias != primaryKey {
                guard let aliasConfig = configs[alias] else { continue }
                if let merged = self.mergeLegacyCodexConfig(aliasConfig, aliasID: alias, into: config, canonicalID: primaryKey) {
                    config = merged
                } else {
                    skipped[alias] = "duplicate of normalized provider \"\(normalizedID)\" (models.providers.\(primaryKey)); "
                        + "reconcile models.providers.\(alias) manually"
                }
            }
            do {
                let provider = try self.makeProvider(providerID: primaryKey, config: config)
                guard builtIDs.insert(provider.id).inserted else {
                    skipped[primaryKey] = "duplicate provider id \"\(provider.id)\"; reconcile models.providers.\(primaryKey) manually"
                    continue
                }
                providers.append(provider)
            } catch {
                skipped[primaryKey] = String(describing: error)
            }
        }
        return ModelProviderFactoryResult(providers: providers, skipped: skipped)
    }

    /// Merges a legacy `openai-codex` / `codex` config into the canonical `openai` config (upstream
    /// `legacy-config-migrations.runtime.models.codex.ts`): legacy models move onto the ChatGPT route
    /// (`openai-chatgpt-responses`, ChatGPT base URL) per model and are appended when their id is new.
    ///
    /// Returns `nil` (merge blocked) unless the canonical key is `openai`, the alias is a legacy codex
    /// id, the legacy provider sets no provider-level defaults its models would lose (`apiKey`, `auth`,
    /// `headers`, `authHeader`, `request`, `timeoutSeconds`, `region`, …) and the canonical provider
    /// sets none its new models would wrongly inherit.
    static func mergeLegacyCodexConfig(
        _ legacy: ModelProviderConfig,
        aliasID: String,
        into canonical: ModelProviderConfig,
        canonicalID: String
    ) -> ModelProviderConfig? {
        guard canonicalID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == OpenAIModelProvider.providerID,
              OpenAIRouteResolution.isLegacyCodexProviderID(aliasID)
        else {
            return nil
        }
        let legacyBlocked = legacy.apiKeyInput != nil || legacy.auth != nil || legacy.request != nil
            || legacy.timeoutSeconds != nil || legacy.region != nil || legacy.injectNumCtxForOpenAICompat
            || legacy.localService != nil || !legacy.headerInputs.isEmpty || legacy.authHeader != nil
        let canonicalBlocked = canonical.apiKeyInput != nil || canonical.auth != nil || canonical.request != nil
            || canonical.timeoutSeconds != nil || canonical.region != nil || canonical.injectNumCtxForOpenAICompat
            || canonical.localService != nil || !canonical.headerInputs.isEmpty || canonical.authHeader != nil
            || canonical.maxTokens != nil || canonical.params != nil || canonical.agentRuntime != nil
        guard !legacyBlocked, !canonicalBlocked else {
            return nil
        }
        let migrated = OpenAIRouteResolution.migrateLegacyCodexConfig(legacy)
        var merged = canonical
        let existingIDs = Set(canonical.models.map(\.id))
        for var model in migrated.models where !existingIDs.contains(model.id) {
            model.api = model.api ?? .openAIChatGPTResponses
            if model.baseURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                model.baseURL = migrated.baseURL
            }
            merged.models.append(model)
        }
        return merged
    }

    /// Runtime factory behind ``makeProvider(providerID:config:)``.
    ///
    /// - Legacy `openai-codex` / `codex` configs move onto the `openai` ChatGPT route
    ///   (`openai-chatgpt-responses`, `https://chatgpt.com/backend-api/codex`, OAuth).
    /// - A config whose `api` was unrecognized is refused (callers skip it).
    /// - An empty `baseUrl` uses the catalog default for the provider id.
    /// - When models carry their own `api` or `baseUrl`, a ``RoutingModelProvider`` picks the
    ///   transport per request.
    static func makeRuntimeProvider(providerID: String, config: ModelProviderConfig) throws -> any ModelProvider {
        let normalizedProviderID = OpenClawReferenceProviderCatalog.normalize(providerID: providerID)
        // Apple Foundation Models runs natively: every alias routes here whatever the placeholder `api`.
        if FoundationModelsProvider.handles(providerID: providerID) || FoundationModelsProvider.handles(providerID: normalizedProviderID) {
            return FoundationModelsProvider()
        }
        var config = config
        if OpenAIRouteResolution.isLegacyCodexProviderID(providerID) || OpenAIRouteResolution.isLegacyCodexProviderID(normalizedProviderID) {
            config = OpenAIRouteResolution.migrateLegacyCodexConfig(config)
        } else if normalizedProviderID == OpenAIModelProvider.providerID, config.api == nil, config.auth == .oauth,
                  [.unresolved, .platform, .chatGPT].contains(OpenAIRouteResolution.classify(baseURL: config.baseURL))
        {
            // ChatGPT sign-in credentials only work on the ChatGPT route.
            config = OpenAIRouteResolution.migrateLegacyCodexConfig(config)
        }
        if config.api == nil, let unrecognized = config.unrecognizedAPI {
            throw OpenClawCoreError.unavailable(
                "Model provider \(normalizedProviderID) uses unknown api \"\(unrecognized)\" and was skipped"
            )
        }
        if config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let entry = OpenClawReferenceProviderCatalog.entry(for: normalizedProviderID)
        {
            config.baseURL = entry.config.baseURL
        }
        if config.api == nil {
            config.api = OpenClawReferenceProviderCatalog.entry(for: normalizedProviderID)?.config.api
                ?? (normalizedProviderID == "azure-openai-responses" ? .azureOpenAIResponses : nil)
        }
        if RoutingModelProvider.needsRouting(config) {
            return RoutingModelProvider(providerID: normalizedProviderID, config: config)
        }
        return try self.makeRoutedProvider(providerID: normalizedProviderID, config: config)
    }

    /// Builds one concrete provider for a config whose default model decides the transport.
    static func makeRoutedProvider(providerID normalizedProviderID: String, config: ModelProviderConfig) throws -> any ModelProvider {
        let model = config.defaultModel
        if model?.api == nil, let unrecognized = model?.unrecognizedAPI {
            throw OpenClawCoreError.unavailable(
                "Model \(model?.id ?? "") of provider \(normalizedProviderID) uses unknown api \"\(unrecognized)\""
            )
        }
        let api = model?.api ?? config.api
        let legacy = config.legacyServiceConfig(providerID: normalizedProviderID)
        func runtime(_ effective: ModelAPI?) -> ModelProviderRuntimeContext {
            ModelProviderRuntimeContext(providerConfig: config, api: effective)
        }
        switch normalizedProviderID {
        case OpenAIModelProvider.providerID:
            switch api ?? .openAIResponses {
            case .openAICompletions:
                return OpenAIModelProvider(
                    configuration: OpenAIModelConfig(
                        enabled: config.enabled,
                        modelID: model?.id ?? "gpt-6-astra",
                        fastMode: model?.fastMode,
                        apiKey: config.apiKey,
                        baseURL: config.baseURL
                    ),
                    transport: ModelStreamingHTTPClient(),
                    runtime: runtime(.openAICompletions)
                )
            case .openAIResponses, .openAIChatGPTResponses, .azureOpenAIResponses:
                return OpenAIResponsesModelProvider(id: normalizedProviderID, configuration: legacy, runtime: runtime(api ?? .openAIResponses))
            default:
                return try self.makeByAPI(providerID: normalizedProviderID, api: api, legacy: legacy, runtime: runtime(api))
            }
        case OpenAICompatibleModelProvider.providerID:
            return OpenAICompatibleModelProvider(
                configuration: OpenAICompatibleModelConfig(
                    enabled: config.enabled,
                    modelID: model?.id ?? "gpt-4.1-mini",
                    apiKey: config.apiKey,
                    baseURL: config.baseURL,
                    chatCompletionsPath: config.chatCompletionsPath
                ),
                runtime: runtime(.openAICompletions)
            )
        case AnthropicModelProvider.providerID:
            if api == nil || api == .anthropicMessages {
                if config.auth == .oauth || config.auth == .token {
                    return ProviderServiceAnthropicModelProvider(id: normalizedProviderID, configuration: legacy, runtime: runtime(.anthropicMessages))
                }
                return AnthropicModelProvider(
                    configuration: AnthropicModelConfig(
                        enabled: config.enabled,
                        modelID: model?.id ?? "claude-3-5-haiku-latest",
                        fastMode: model?.fastMode,
                        apiKey: config.apiKey,
                        baseURL: config.baseURL,
                        apiVersion: config.apiVersion ?? "2023-06-01",
                        maxTokens: model.flatMap { $0.maxTokens > 0 ? $0.maxTokens : nil } ?? config.maxTokens ?? 8_192
                    ),
                    runtime: runtime(.anthropicMessages)
                )
            }
            return try self.makeByAPI(providerID: normalizedProviderID, api: api, legacy: legacy, runtime: runtime(api))
        case GeminiModelProvider.providerID, "google", "google-vertex", "google-antigravity", "google-gemini-cli":
            let googleAPI: ModelAPI = api == .googleVertex || normalizedProviderID == "google-vertex" ? .googleVertex : .googleGenerativeAI
            return GoogleGenerativeAIModelProvider(id: normalizedProviderID, configuration: legacy, runtime: runtime(googleAPI))
        case let id where FoundationModelsProvider.handles(providerID: id):
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
            return XAIModelProvider(id: normalizedProviderID, configuration: legacy, runtime: runtime(api ?? .openAICompletions))
        case MinimaxModelProvider.providerID:
            return MinimaxModelProvider(configuration: legacy, runtime: runtime(.anthropicMessages))
        case MinimaxPortalModelProvider.providerID:
            return MinimaxPortalModelProvider(configuration: legacy, runtime: runtime(.anthropicMessages))
        case SyntheticModelProvider.providerID:
            return SyntheticModelProvider(configuration: legacy, runtime: runtime(.anthropicMessages))
        case CloudflareAIGatewayModelProvider.providerID:
            return CloudflareAIGatewayModelProvider(configuration: legacy, runtime: runtime(.anthropicMessages))
        case VercelAIGatewayModelProvider.providerID:
            return VercelAIGatewayModelProvider(configuration: legacy, runtime: runtime(.anthropicMessages))
        case BedrockConverseModelProvider.providerID:
            return BedrockConverseModelProvider(configuration: legacy, runtime: runtime(.bedrockConverseStream))
        case OllamaModelProvider.providerID:
            return OllamaModelProvider(configuration: legacy, runtime: runtime(api ?? .ollama))
        default:
            return try self.makeByAPI(providerID: normalizedProviderID, api: api, legacy: legacy, runtime: runtime(api))
        }
    }

    private static func makeByAPI(
        providerID: String,
        api: ModelAPI?,
        legacy: ProviderServiceConfig,
        runtime: ModelProviderRuntimeContext
    ) throws -> any ModelProvider {
        let effective = api ?? .openAICompletions
        var context = runtime
        context.api = effective
        switch effective {
        case .anthropicMessages:
            return ProviderServiceAnthropicModelProvider(id: providerID, configuration: legacy, runtime: context)
        case .bedrockConverseStream:
            return BedrockConverseModelProvider(id: providerID, configuration: legacy, runtime: context)
        case .githubCopilot:
            return GitHubCopilotModelProvider(id: providerID, configuration: legacy, runtime: context)
        case .googleGenerativeAI, .googleVertex:
            return GoogleGenerativeAIModelProvider(id: providerID, configuration: legacy, runtime: context)
        case .openAIResponses, .openAIChatGPTResponses, .azureOpenAIResponses:
            return OpenAIResponsesModelProvider(id: providerID, configuration: legacy, runtime: context)
        case .piMessages:
            throw OpenClawCoreError.unavailable(
                "The pi-messages transport is not implemented in OpenClawKit (provider \(providerID))"
            )
        case .ollama:
            return OllamaModelProvider(id: providerID, configuration: legacy, runtime: context)
        case .openAICompletions:
            return ProviderServiceOpenAIModelProvider(id: providerID, configuration: legacy, runtime: context)
        }
    }
}

/// Provider that routes each request to a transport chosen by the requested model.
///
/// Upstream providers mix transports per model (for example `github-copilot` serves Claude models
/// over anthropic-messages and Gemini over openai-completions; `opencode` routes some models to
/// other base URLs). For each request the effective API is `model.api ?? provider.api`, the base URL
/// `model.baseUrl ?? provider.baseUrl`, and headers are provider headers merged with model headers.
/// Concrete providers are built lazily and cached per (api, baseUrl).
public struct RoutingModelProvider: ModelProvider {
    /// Provider identifier.
    public let id: String
    /// Canonical provider config.
    public let config: ModelProviderConfig
    private let cache = RoutingProviderCache()

    /// Creates a routing provider.
    /// - Parameters:
    ///   - providerID: Provider identifier.
    ///   - config: Canonical provider config with per-model `api`/`baseUrl`.
    public init(providerID: String, config: ModelProviderConfig) {
        self.id = providerID
        self.config = config
    }

    /// Whether any model carries an `api` or `baseUrl` that differs from the provider's.
    /// - Parameter config: Provider config.
    public static func needsRouting(_ config: ModelProviderConfig) -> Bool {
        let base = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return config.models.contains { model in
            if let api = model.api, api != config.api {
                return true
            }
            if let modelBase = model.baseURL?.trimmingCharacters(in: .whitespacesAndNewlines), !modelBase.isEmpty, modelBase != base {
                return true
            }
            return false
        }
    }

    /// Capabilities of the default model's route.
    public var capabilities: ModelProviderCapabilities {
        let modelID = self.config.defaultModel?.id ?? ""
        return (try? self.provider(forModelID: modelID).capabilities) ?? .legacy
    }

    /// Generates a response through the route of the requested model.
    /// - Parameter request: Generation request.
    /// - Returns: Generation response payload.
    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        try await self.provider(for: request).generate(self.wireRequest(for: request))
    }

    /// Streams chunks through the route of the requested model.
    /// - Parameter request: Generation request.
    /// - Returns: Chunk stream.
    public func generateStream(_ request: ModelGenerationRequest) async -> AsyncThrowingStream<ModelStreamChunk, Error> {
        let provider: any ModelProvider
        do {
            provider = try self.provider(for: request)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        return await provider.generateStream(self.wireRequest(for: request))
    }

    /// Rewrites the model id to a row's ClawRouter upstream model (native routes send the upstream id).
    private func wireRequest(for request: ModelGenerationRequest) -> ModelGenerationRequest {
        let modelID = request.resolvedModelID ?? self.config.defaultModel?.id ?? ""
        guard let upstream = ClawRouterRoute.upstreamModelID(for: self.config.model(withID: modelID)) else {
            return request
        }
        return request.replacingModelID(upstream)
    }

    /// Forwards cancellation to every cached route.
    /// - Parameter token: Cancellation token.
    public func cancelGeneration(token: String?) async {
        for provider in self.cache.all() {
            await provider.cancelGeneration(token: token)
        }
    }

    /// Effective (api, baseUrl) route for a model id.
    /// - Parameter modelID: Model identifier.
    /// - Returns: Effective API (when known) and base URL.
    public func route(forModelID modelID: String) -> (api: ModelAPI?, baseURL: String) {
        let model = self.config.model(withID: modelID)
        let api = model?.api ?? self.config.api
        let modelBase = model?.baseURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (api, modelBase.isEmpty ? self.config.baseURL : modelBase)
    }

    private func provider(for request: ModelGenerationRequest) throws -> any ModelProvider {
        let modelID = request.resolvedModelID ?? self.config.defaultModel?.id ?? ""
        return try self.provider(forModelID: modelID)
    }

    private func provider(forModelID modelID: String) throws -> any ModelProvider {
        let model = self.config.model(withID: modelID)
        if let model, model.api == nil, let unrecognized = model.unrecognizedAPI {
            throw OpenClawCoreError.unavailable("Model \(model.id) of provider \(self.id) uses unknown api \"\(unrecognized)\"")
        }
        let route = self.route(forModelID: modelID)
        let key = "\(route.api?.rawValue ?? "default")|\(route.baseURL)"
        if let cached = self.cache.provider(for: key) {
            return cached
        }
        var routed = self.config
        routed.api = route.api
        routed.baseURL = route.baseURL
        if let model, let index = routed.models.firstIndex(where: { $0.id == model.id }) {
            routed.models.remove(at: index)
            routed.models.insert(model, at: 0)
        }
        // Native ClawRouter rows are requested by their upstream id; add wire rows under that id so the
        // engine still finds the row's limits, reasoning flags and compat.
        for row in routed.models {
            if let prepared = ClawRouterRoute.requestModel(for: row), !routed.models.contains(where: { $0.id == prepared.id }) {
                routed.models.append(prepared)
            }
        }
        let provider = try ModelProviderFactory.makeRoutedProvider(providerID: self.id, config: routed)
        self.cache.store(provider, for: key)
        return provider
    }
}

/// Lock-protected cache of routed providers.
private final class RoutingProviderCache: @unchecked Sendable {
    private let lock = NSLock()
    private var providers: [String: any ModelProvider] = [:]

    func provider(for key: String) -> (any ModelProvider)? {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.providers[key]
    }

    func store(_ provider: any ModelProvider, for key: String) {
        self.lock.lock()
        self.providers[key] = provider
        self.lock.unlock()
    }

    func all() -> [any ModelProvider] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return Array(self.providers.values)
    }
}
