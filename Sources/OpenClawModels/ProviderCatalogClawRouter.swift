import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenClawCore
import OpenClawProtocol

/// HTTP transport used by catalog discovery and refresh clients.
public protocol ProviderCatalogHTTPTransport: Sendable {
    /// Executes an HTTP request and returns normalized response data.
    /// - Parameter request: Configured URL request.
    /// - Returns: Response payload.
    func data(for request: URLRequest) async throws -> HTTPResponseData
}

extension HTTPClient: ProviderCatalogHTTPTransport {}

/// Transport route ClawRouter assigns to one discovered model (upstream `params.clawrouterRoute`).
public struct ClawRouterRoute: Codable, Sendable, Equatable {
    /// Transport API for the model.
    public var api: ModelAPI
    /// Base URL requests are sent to.
    public var baseURL: String
    /// Upstream model id sent on native routes (Anthropic Messages, Google generateContent).
    public var upstreamModel: String?

    /// Creates a route.
    public init(api: ModelAPI, baseURL: String, upstreamModel: String? = nil) {
        self.api = api
        self.baseURL = baseURL
        self.upstreamModel = upstreamModel
    }

    private enum CodingKeys: String, CodingKey {
        case api
        case baseURL = "baseUrl"
        case upstreamModel
    }

    /// Key of the route metadata stored on each discovered row's `params` (upstream `ROUTE_METADATA_KEY`).
    public static let paramsKey = "clawrouterRoute"

    /// Route metadata as a `params` value (`{api, baseUrl, upstreamModel?}`).
    public var paramsValue: AnyCodable {
        var object: [String: AnyCodable] = [
            "api": AnyCodable(self.api.rawValue),
            "baseUrl": AnyCodable(self.baseURL),
        ]
        if let upstreamModel {
            object["upstreamModel"] = AnyCodable(upstreamModel)
        }
        return AnyCodable(object)
    }

    /// Upstream model id to send for a model row, read from its `params.clawrouterRoute`; `nil` when the
    /// row has no route metadata or the upstream id equals the row id.
    /// - Parameter model: Model row.
    /// - Returns: Wire model id for native ClawRouter routes.
    public static func upstreamModelID(for model: ModelDefinitionConfig?) -> String? {
        guard let model,
              let route = model.params?[self.paramsKey]?.dictionaryValue,
              let upstream = route["upstreamModel"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !upstream.isEmpty,
              upstream != model.id
        else {
            return nil
        }
        return upstream
    }

    /// Row prepared for the wire (upstream `prepareClawRouterRequestModel`): id rewritten to the
    /// upstream model and route metadata stripped from `params`.
    /// - Parameter model: Model row carrying route metadata.
    /// - Returns: The wire row, or `nil` when no rewrite applies.
    public static func requestModel(for model: ModelDefinitionConfig) -> ModelDefinitionConfig? {
        guard let upstream = self.upstreamModelID(for: model) else { return nil }
        var prepared = model
        prepared.id = upstream
        var params = model.params ?? [:]
        params.removeValue(forKey: self.paramsKey)
        prepared.params = params.isEmpty ? nil : params
        return prepared
    }
}

/// One model discovered from the ClawRouter catalog.
public struct ClawRouterDiscoveredModel: Sendable, Equatable {
    /// Catalog row (id, name, api, per-model base URL, reasoning, thinking map, cost, limits).
    public var model: ModelCatalogModel
    /// Transport route for the model.
    public var route: ClawRouterRoute
    /// ClawRouter provider id that serves the model.
    public var routerProviderID: String

    /// Creates a discovered model.
    public init(model: ModelCatalogModel, route: ClawRouterRoute, routerProviderID: String) {
        self.model = model
        self.route = route
        self.routerProviderID = routerProviderID
    }
}

/// Result of ClawRouter live catalog discovery.
public struct ClawRouterCatalog: Sendable, Equatable {
    /// Normalized ClawRouter root URL (no trailing `/v1`).
    public var rootURL: String
    /// Discovered models sorted by id.
    public var models: [ClawRouterDiscoveredModel]

    /// Creates a catalog result.
    public init(rootURL: String, models: [ClawRouterDiscoveredModel]) {
        self.rootURL = rootURL
        self.models = models
    }

    /// OpenAI-compatible API base URL (`<root>/v1`).
    public var apiBaseURL: String {
        "\(self.rootURL)/v1"
    }

    /// Provider catalog with every discovered row (provider API `openai-responses`).
    public var catalogProvider: ModelCatalogProvider {
        ModelCatalogProvider(
            baseURL: self.apiBaseURL,
            api: .openAIResponses,
            defaultModel: self.models.first?.model.id,
            models: self.models.map(\.model)
        )
    }

    /// Runtime provider config for the discovered rows.
    ///
    /// Each row keeps its routed `api` and `baseUrl`, so ``ModelProviderFactory`` builds a
    /// ``RoutingModelProvider`` that sends every request to its route. Rows on native routes
    /// (Anthropic Messages, Google generateContent) carry `params.clawrouterRoute.upstreamModel`, and
    /// the routing provider sends that upstream id on the wire (upstream `prepareClawRouterRequestModel`).
    /// - Parameter apiKey: ClawRouter API key.
    public func providerConfig(apiKey: String?) -> ModelProviderConfig {
        ModelProviderConfig(
            enabled: true,
            baseURL: self.apiBaseURL,
            apiKey: apiKey,
            auth: .apiKey,
            api: .openAIResponses,
            models: self.models.map { $0.model.definitionConfig() }
        )
    }

    /// Returns the route for a model id.
    public func route(forModelID modelID: String) -> ClawRouterRoute? {
        self.models.first { $0.model.id == modelID }?.route
    }
}

/// ClawRouter live catalog discovery (ports `extensions/clawrouter/provider-catalog.ts`).
///
/// Fetches `GET <root>/v1/catalog` with the API key, maps each model to its routed transport, and caches non-empty
/// results for 60 seconds per root URL and key.
public actor ClawRouterCatalogDiscovery {
    /// Default ClawRouter root URL.
    public static let defaultRootURL = "https://clawrouter.openclaw.ai"
    /// Cache lifetime for non-empty discovery results.
    public static let cacheTTL: TimeInterval = 60
    /// Context window used when the catalog omits `maxInputTokens`.
    public static let defaultContextWindow = 200_000
    /// Max output tokens used when the catalog omits `defaultMaxOutputTokens`.
    public static let defaultMaxTokens = 32_768

    /// ClawRouter reasoning efforts mapped to logical thinking levels, in upstream order.
    public static let reasoningEffortLevels: [(effort: String, level: String)] = [
        ("none", "off"),
        ("minimal", "minimal"),
        ("low", "low"),
        ("medium", "medium"),
        ("high", "high"),
        ("xhigh", "xhigh"),
        ("max", "max"),
    ]

    private struct CacheEntry {
        let catalog: ClawRouterCatalog
        let storedAt: Date
    }

    private let transport: any ProviderCatalogHTTPTransport
    private let now: @Sendable () -> Date
    private var cache: [String: CacheEntry] = [:]

    /// Creates a discovery client.
    /// - Parameters:
    ///   - transport: HTTP transport.
    ///   - now: Clock used for cache expiry.
    public init(
        transport: any ProviderCatalogHTTPTransport = HTTPClient(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.now = now
    }

    /// Discovers the models available to an API key.
    /// - Parameters:
    ///   - apiKey: ClawRouter API key (sent as a bearer token).
    ///   - baseURL: Optional root or `/v1` base URL; defaults to ``defaultRootURL``.
    /// - Returns: The discovered catalog.
    public func discover(apiKey: String, baseURL: String? = nil) async throws -> ClawRouterCatalog {
        let rootURL = Self.normalizeRootURL(baseURL)
        let cacheKey = "\(rootURL)\n\(apiKey)"
        if let cached = self.cache[cacheKey], self.now().timeIntervalSince(cached.storedAt) < Self.cacheTTL {
            return cached.catalog
        }
        guard let endpoint = URL(string: "\(rootURL)/v1/catalog") else {
            throw OpenClawCoreError.invalidConfiguration("ClawRouter base URL is invalid: \(rootURL)")
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let response = try await self.transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw OpenClawCoreError.unavailable("ClawRouter catalog request failed: HTTP \(response.statusCode)")
        }
        let catalog = try Self.parseCatalog(response.body, rootURL: rootURL)
        if !catalog.models.isEmpty {
            self.cache[cacheKey] = CacheEntry(catalog: catalog, storedAt: self.now())
        }
        return catalog
    }

    /// Drops cached discovery results.
    public func invalidateCache() {
        self.cache.removeAll()
    }

    /// Normalizes a configured base URL to the ClawRouter root (trailing slashes and `/v1` removed).
    public static func normalizeRootURL(_ baseURL: String?) -> String {
        var normalized = baseURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if normalized.isEmpty {
            normalized = self.defaultRootURL
        }
        while normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        if normalized.hasSuffix("/v1") {
            normalized.removeLast(3)
        }
        return normalized
    }

    /// Parses a catalog response body.
    /// - Parameters:
    ///   - data: JSON body (`{providers: [...]}`).
    ///   - rootURL: Normalized root URL used to build routed base URLs.
    /// - Returns: Routed models sorted by id; duplicates keep the first provider.
    public static func parseCatalog(_ data: Data, rootURL: String) throws -> ClawRouterCatalog {
        let body: CatalogBody
        do {
            body = try JSONDecoder().decode(CatalogBody.self, from: data)
        } catch {
            throw OpenClawCoreError.invalidConfiguration("ClawRouter catalog response must contain providers[]")
        }
        var models: [String: ClawRouterDiscoveredModel] = [:]
        for provider in body.providers.compactMap(\.value) {
            for model in provider.models where models[model.id] == nil {
                if let routed = self.routedModel(rootURL: rootURL, provider: provider, model: model) {
                    models[model.id] = routed
                }
            }
        }
        let sorted = models.keys.sorted().compactMap { models[$0] }
        return ClawRouterCatalog(rootURL: rootURL, models: sorted)
    }

    /// Normalizes advertised reasoning efforts (unknown or oversized lists yield `nil`).
    public static func normalizeReasoningEfforts(_ raw: [String]?) -> [String]? {
        guard let raw, raw.count <= self.reasoningEffortLevels.count else { return nil }
        let advertised = Set(raw)
        let efforts = self.reasoningEffortLevels.map(\.effort).filter { advertised.contains($0) }
        return efforts.isEmpty ? nil : efforts
    }

    // MARK: Parsing

    private struct CatalogBody: Decodable {
        let providers: [LossyValue<CatalogProvider>]
    }

    private struct CatalogRoute: Decodable {
        let path: String
        let requestFormat: String
        let methods: [String]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.path = try ClawRouterCatalogDiscovery.requiredString(container, .path)
            self.requestFormat = try ClawRouterCatalogDiscovery.requiredString(container, .requestFormat)
            self.methods = ((try? container.decodeIfPresent([String].self, forKey: .methods)) ?? []).map { $0.uppercased() }
        }

        private enum CodingKeys: String, CodingKey {
            case path
            case requestFormat
            case methods
        }
    }

    private struct CatalogPricing: Decodable {
        let inputMicrosPerMillion: Double?
        let outputMicrosPerMillion: Double?
        let cachedInputMicrosPerMillion: Double?
        let cacheWrite5mInputMicrosPerMillion: Double?
        let cacheWrite1hInputMicrosPerMillion: Double?
        let maxInputTokens: Int?
        let defaultMaxOutputTokens: Int?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            func rate(_ key: CodingKeys) -> Double? {
                guard let value = try? container.decodeIfPresent(Double.self, forKey: key), value.isFinite, value >= 0 else {
                    return nil
                }
                return value
            }
            func tokens(_ key: CodingKeys) -> Int? {
                guard let value = try? container.decodeIfPresent(Int.self, forKey: key), value > 0 else { return nil }
                return value
            }
            self.inputMicrosPerMillion = rate(.inputMicrosPerMillion)
            self.outputMicrosPerMillion = rate(.outputMicrosPerMillion)
            self.cachedInputMicrosPerMillion = rate(.cachedInputMicrosPerMillion)
            self.cacheWrite5mInputMicrosPerMillion = rate(.cacheWrite5mInputMicrosPerMillion)
            self.cacheWrite1hInputMicrosPerMillion = rate(.cacheWrite1hInputMicrosPerMillion)
            self.maxInputTokens = tokens(.maxInputTokens)
            self.defaultMaxOutputTokens = tokens(.defaultMaxOutputTokens)
        }

        private enum CodingKeys: String, CodingKey {
            case inputMicrosPerMillion
            case outputMicrosPerMillion
            case cachedInputMicrosPerMillion
            case cacheWrite5mInputMicrosPerMillion
            case cacheWrite1hInputMicrosPerMillion
            case maxInputTokens
            case defaultMaxOutputTokens
        }
    }

    private struct CatalogModel: Decodable {
        let id: String
        let displayName: String?
        let upstream: String
        let capabilities: [String]
        let supportedReasoningEfforts: [String]?
        let pricing: CatalogPricing?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try ClawRouterCatalogDiscovery.requiredString(container, .id)
            self.upstream = try ClawRouterCatalogDiscovery.requiredString(container, .upstream)
            self.displayName = ClawRouterCatalogDiscovery.optionalString(container, .displayName)
            self.capabilities = ((try? container.decodeIfPresent([String].self, forKey: .capabilities)) ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            self.supportedReasoningEfforts = ClawRouterCatalogDiscovery.normalizeReasoningEfforts(
                (try? container.decodeIfPresent([String].self, forKey: .supportedReasoningEfforts))
            )
            self.pricing = (try? container.decodeIfPresent(CatalogPricing.self, forKey: .pricing))
        }

        private enum CodingKeys: String, CodingKey {
            case id
            case displayName
            case upstream
            case capabilities
            case supportedReasoningEfforts
            case pricing
        }
    }

    private struct CatalogProvider: Decodable {
        let id: String
        let displayName: String
        let openaiCompatible: Bool
        let nativeBaseURL: String
        let routes: [CatalogRoute]
        let models: [CatalogModel]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try ClawRouterCatalogDiscovery.requiredString(container, .id)
            let nativeBaseURL = try ClawRouterCatalogDiscovery.requiredString(container, .nativeBaseURL)
            guard nativeBaseURL.hasPrefix("/v1/native/") else {
                throw DecodingError.dataCorruptedError(forKey: .nativeBaseURL, in: container, debugDescription: "nativeBaseUrl must start with /v1/native/")
            }
            self.nativeBaseURL = nativeBaseURL
            self.displayName = ClawRouterCatalogDiscovery.optionalString(container, .displayName) ?? self.id
            self.openaiCompatible = ((try? container.decodeIfPresent(Bool.self, forKey: .openaiCompatible))) == true
            self.routes = ((try? container.decodeIfPresent([LossyValue<CatalogRoute>].self, forKey: .routes)) ?? [])
                .compactMap(\.value)
            self.models = ((try? container.decodeIfPresent([LossyValue<CatalogModel>].self, forKey: .models)) ?? [])
                .compactMap(\.value)
        }

        private enum CodingKeys: String, CodingKey {
            case id
            case displayName
            case openaiCompatible
            case nativeBaseURL = "nativeBaseUrl"
            case routes
            case models
        }
    }

    private static func requiredString<Key: CodingKey>(_ container: KeyedDecodingContainer<Key>, _ key: Key) throws -> String {
        guard let value = self.optionalString(container, key) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "Missing \(key.stringValue)")
        }
        return value
    }

    private static func optionalString<Key: CodingKey>(_ container: KeyedDecodingContainer<Key>, _ key: Key) -> String? {
        guard let raw = (try? container.decodeIfPresent(String.self, forKey: key)) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func routedModel(rootURL: String, provider: CatalogProvider, model: CatalogModel) -> ClawRouterDiscoveredModel? {
        let capabilities = Set(model.capabilities)
        let route: ClawRouterRoute
        if provider.openaiCompatible, capabilities.contains("llm.responses") {
            route = ClawRouterRoute(api: .openAIResponses, baseURL: "\(rootURL)/v1")
        } else if provider.openaiCompatible, capabilities.contains("llm.chat") {
            route = ClawRouterRoute(api: .openAICompletions, baseURL: "\(rootURL)/v1")
        } else if capabilities.contains("llm.messages"),
                  provider.routes.contains(where: { $0.methods.contains("POST") && $0.requestFormat == "anthropic.messages" })
        {
            route = ClawRouterRoute(api: .anthropicMessages, baseURL: "\(rootURL)\(provider.nativeBaseURL)", upstreamModel: model.upstream)
        } else if capabilities.contains("llm.stream"),
                  let googleRoute = provider.routes.first(where: {
                      $0.methods.contains("POST") && $0.requestFormat == "google.generate_content"
                          && $0.path.contains(":streamGenerateContent")
                  }),
                  let modelPath = googleRoute.path.range(of: "/models/${model}"),
                  modelPath.lowerBound > googleRoute.path.startIndex
        {
            let prefix = googleRoute.path[..<modelPath.lowerBound]
            route = ClawRouterRoute(
                api: .googleGenerativeAI,
                baseURL: "\(rootURL)\(provider.nativeBaseURL)\(prefix)",
                upstreamModel: model.upstream
            )
        } else {
            return nil
        }

        let providerPrefix = "\(provider.id)/"
        let label = model.id.hasPrefix(providerPrefix) ? String(model.id.dropFirst(providerPrefix.count)) : model.id
        var compat: ModelCatalogCompatConfig?
        var thinkingLevelMap: ModelCatalogThinkingLevelMap?
        if let efforts = model.supportedReasoningEfforts {
            var reasoningCompat = ModelCatalogCompatConfig()
            reasoningCompat.supportsReasoningEffort = true
            reasoningCompat.supportedReasoningEfforts = efforts
            compat = reasoningCompat
            let supported = Set(efforts)
            thinkingLevelMap = ModelCatalogThinkingLevelMap(
                Dictionary(uniqueKeysWithValues: self.reasoningEffortLevels.map { pair in
                    (pair.level, supported.contains(pair.effort) ? ModelCatalogThinkingLevelValue.mapped(pair.effort) : .disabled)
                })
            )
        }
        let pricing = model.pricing
        let row = ModelCatalogModel(
            id: model.id,
            name: model.displayName ?? "\(provider.displayName) · \(label)",
            api: route.api,
            baseURL: route.baseURL,
            input: self.inferInput(providerID: provider.id, modelID: model.id),
            reasoning: model.supportedReasoningEfforts != nil || self.inferReasoning(providerID: provider.id, modelID: model.id),
            contextWindow: pricing?.maxInputTokens ?? self.defaultContextWindow,
            maxTokens: pricing?.defaultMaxOutputTokens ?? self.defaultMaxTokens,
            thinkingLevelMap: thinkingLevelMap,
            cost: ModelCatalogCost(
                input: (pricing?.inputMicrosPerMillion ?? 0) / 1_000_000,
                output: (pricing?.outputMicrosPerMillion ?? 0) / 1_000_000,
                cacheRead: (pricing?.cachedInputMicrosPerMillion ?? 0) / 1_000_000,
                cacheWrite: (pricing?.cacheWrite5mInputMicrosPerMillion ?? pricing?.cacheWrite1hInputMicrosPerMillion ?? 0) / 1_000_000
            ),
            compat: compat,
            params: [ClawRouterRoute.paramsKey: route.paramsValue]
        )
        return ClawRouterDiscoveredModel(model: row, route: route, routerProviderID: provider.id)
    }

    private static func inferReasoning(providerID: String, modelID: String) -> Bool {
        let id = "\(providerID)/\(modelID)".lowercased()
        return ["claude-", "gemini-", "gpt-5", "gpt-oss", "deepseek-v", "reasoner", "glm-5", "grok-4", "minimax-m"]
            .contains { id.contains($0) }
    }

    private static func inferInput(providerID: String, modelID: String) -> [ModelInputType] {
        let id = "\(providerID)/\(modelID)".lowercased()
        return ["claude-", "gemini-", "gpt-4o", "gpt-5"].contains { id.contains($0) } ? [.text, .image] : [.text]
    }
}
