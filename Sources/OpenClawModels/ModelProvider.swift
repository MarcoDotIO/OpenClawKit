import Foundation
import OpenClawCore
import OpenClawProtocol

/// Reasoning budget preference for providers that expose explicit reasoning controls.
public enum ModelReasoningEffort: String, Sendable, Equatable, CaseIterable {
    case low
    case medium
    case high
}

/// Service tier preference for providers that expose tiered latency or cost controls.
public enum ModelServiceTier: String, Sendable, Equatable, CaseIterable {
    case auto
    case standard
    case priority
}

/// Transport selection used by Codex-style response APIs.
public enum CodexTransportPreference: String, Sendable, Equatable, CaseIterable {
    case auto
    case sse
    case websocket
}

/// Runtime generation policy used for model-provider selection and behavior controls.
public struct ModelGenerationPolicy: Sendable, Equatable {
    /// Requests token streaming when provider supports it.
    public let streamTokens: Bool
    /// Indicates whether runtime cancellation should be honored.
    public let allowCancellation: Bool
    /// Optional caller-provided cancellation token identifier.
    public let cancellationToken: String?
    /// Optional max token override.
    public let maxTokens: Int?
    /// Optional sampling temperature override.
    public let temperature: Double?
    /// Optional top-p override.
    public let topP: Double?
    /// Optional top-k override.
    public let topK: Int?
    /// Optional request timeout override in milliseconds.
    public let requestTimeoutMs: Int?
    /// Ordered provider fallback identifiers attempted after primary provider.
    public let fallbackProviderIDs: [String]
    /// Optional local-runtime-specific hints (for example hardware/backend toggles).
    public let localRuntimeHints: [String: String]
    /// Optional provider reasoning effort hint.
    public let reasoningEffort: ModelReasoningEffort?
    /// Optional provider service tier hint.
    public let serviceTier: ModelServiceTier?
    /// Optional fast-mode override.
    public let fastMode: Bool?
    /// Requests provider-side response persistence when supported.
    public let storeResponse: Bool?
    /// Preferred transport for Codex response APIs.
    public let codexTransport: CodexTransportPreference
    /// Raw thinking-level override resolved from session state.
    public let thinkingLevel: ThinkLevel?
    /// Raw reasoning visibility override resolved from session state.
    public let reasoningLevel: ReasoningLevel?
    /// Raw verbosity override resolved from session state.
    public let verboseLevel: VerboseLevel?
    /// Raw response-usage override resolved from session state.
    public let responseUsage: UsageDisplayLevel?
    /// Raw elevated-execution override resolved from session state.
    public let elevatedLevel: ElevatedLevel?

    /// Creates generation policy values.
    /// - Parameters:
    ///   - streamTokens: Requests streaming behavior.
    ///   - allowCancellation: Enables cancellation support for this request.
    ///   - cancellationToken: Optional cancellation token.
    ///   - maxTokens: Optional max token override.
    ///   - temperature: Optional temperature override.
    ///   - topP: Optional top-p override.
    ///   - topK: Optional top-k override.
    ///   - requestTimeoutMs: Optional timeout override in milliseconds.
    ///   - fallbackProviderIDs: Ordered provider fallback chain.
    ///   - localRuntimeHints: Optional local runtime hints.
    public init(
        streamTokens: Bool = false,
        allowCancellation: Bool = true,
        cancellationToken: String? = nil,
        maxTokens: Int? = nil,
        temperature: Double? = nil,
        topP: Double? = nil,
        topK: Int? = nil,
        requestTimeoutMs: Int? = nil,
        fallbackProviderIDs: [String] = [],
        localRuntimeHints: [String: String] = [:],
        reasoningEffort: ModelReasoningEffort? = nil,
        serviceTier: ModelServiceTier? = nil,
        fastMode: Bool? = nil,
        storeResponse: Bool? = nil,
        codexTransport: CodexTransportPreference = .auto,
        thinkingLevel: ThinkLevel? = nil,
        reasoningLevel: ReasoningLevel? = nil,
        verboseLevel: VerboseLevel? = nil,
        responseUsage: UsageDisplayLevel? = nil,
        elevatedLevel: ElevatedLevel? = nil
    ) {
        self.streamTokens = streamTokens
        self.allowCancellation = allowCancellation
        self.cancellationToken = cancellationToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.maxTokens = maxTokens.map { max(1, $0) }
        self.temperature = temperature
        self.topP = topP
        self.topK = topK.map { max(1, $0) }
        self.requestTimeoutMs = requestTimeoutMs.map { max(1, $0) }
        self.fallbackProviderIDs = fallbackProviderIDs
        self.localRuntimeHints = localRuntimeHints
        self.reasoningEffort = reasoningEffort
        self.serviceTier = serviceTier
        self.fastMode = fastMode
        self.storeResponse = storeResponse
        self.codexTransport = codexTransport
        self.thinkingLevel = thinkingLevel
        self.reasoningLevel = reasoningLevel
        self.verboseLevel = verboseLevel
        self.responseUsage = responseUsage
        self.elevatedLevel = elevatedLevel
    }
}

/// Input payload passed to model providers.
public struct ModelGenerationRequest: Sendable, Equatable {
    /// Session key associated with generation request.
    public let sessionKey: String
    /// User prompt payload.
    public let prompt: String
    /// Optional system prompt prefix.
    public let systemPrompt: String?
    /// Optional explicit provider override.
    public let providerID: String?
    /// Optional explicit model override.
    public let modelID: String?
    /// Optional preferred auth-profile identifier.
    public let preferredAuthProfileID: String?
    /// Additional provider-specific metadata.
    public let metadata: [String: String]
    /// Additional request headers applied on top of provider config.
    public let headers: [String: String]
    /// Runtime generation policy controls.
    public let policy: ModelGenerationPolicy
    /// Optional multimodal attachments for providers that support rich input.
    public let attachments: [MediaAttachment]

    /// Creates a model generation request.
    /// - Parameters:
    ///   - sessionKey: Session key.
    ///   - prompt: Prompt payload.
    ///   - systemPrompt: Optional system prompt.
    ///   - providerID: Optional provider override.
    ///   - metadata: Additional metadata.
    ///   - policy: Runtime generation policy controls.
    ///   - attachments: Optional multimodal attachments.
    public init(
        sessionKey: String,
        prompt: String,
        systemPrompt: String? = nil,
        providerID: String? = nil,
        modelID: String? = nil,
        preferredAuthProfileID: String? = nil,
        metadata: [String: String] = [:],
        headers: [String: String] = [:],
        policy: ModelGenerationPolicy = ModelGenerationPolicy(),
        attachments: [MediaAttachment] = []
    ) {
        self.sessionKey = sessionKey
        self.prompt = prompt
        self.systemPrompt = systemPrompt
        self.providerID = providerID
        self.modelID = modelID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.preferredAuthProfileID = preferredAuthProfileID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.metadata = metadata
        self.headers = headers
        self.policy = policy
        self.attachments = attachments
    }
}

/// Output payload returned from model providers.
public struct ModelGenerationResponse: Sendable, Equatable {
    /// Generated text output.
    public let text: String
    /// Provider identifier that generated the output.
    public let providerID: String
    /// Optional concrete model identifier.
    public let modelID: String?

    /// Creates a model generation response.
    /// - Parameters:
    ///   - text: Generated text output.
    ///   - providerID: Provider identifier.
    ///   - modelID: Optional concrete model identifier.
    public init(text: String, providerID: String, modelID: String? = nil) {
        self.text = text
        self.providerID = providerID
        self.modelID = modelID
    }
}

/// Streaming chunk payload emitted by providers that support token streaming.
public struct ModelStreamChunk: Sendable, Equatable {
    /// Token/text fragment.
    public let text: String
    /// Indicates whether this chunk marks end-of-stream payload.
    public let isFinal: Bool

    /// Creates a streaming chunk.
    /// - Parameters:
    ///   - text: Token/text fragment.
    ///   - isFinal: End-of-stream marker.
    public init(text: String, isFinal: Bool = false) {
        self.text = text
        self.isFinal = isFinal
    }
}

/// Request throttling controls applied per model provider.
public struct ModelProviderThrottlePolicy: Sendable, Equatable {
    /// Strategy used when provider rate exceeds configured window.
    public enum Strategy: String, Sendable, Equatable {
        case delay
        case drop
    }

    public let maxRequestsPerWindow: Int
    public let windowMs: Int
    public let strategy: Strategy

    /// Creates provider throttle policy values.
    /// - Parameters:
    ///   - maxRequestsPerWindow: Maximum requests allowed in one rolling window per provider.
    ///   - windowMs: Rolling window duration in milliseconds.
    ///   - strategy: Strategy applied when limit is exceeded.
    public init(
        maxRequestsPerWindow: Int = 0,
        windowMs: Int = 1_000,
        strategy: Strategy = .delay
    ) {
        self.maxRequestsPerWindow = max(0, maxRequestsPerWindow)
        self.windowMs = max(1, windowMs)
        self.strategy = strategy
    }

    var isEnabled: Bool {
        self.maxRequestsPerWindow > 0
    }
}

/// Interface implemented by model backends.
public protocol ModelProvider: Sendable {
    /// Stable provider identifier.
    var id: String { get }
    /// Executes generation request.
    /// - Parameter request: Generation request payload.
    /// - Returns: Generation response payload.
    func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse

    /// Returns a token stream for providers that support streaming generation.
    /// - Parameter request: Generation request payload.
    /// - Returns: Async throwing stream of model chunks.
    func generateStream(_ request: ModelGenerationRequest) async -> AsyncThrowingStream<ModelStreamChunk, Error>

    /// Requests cancellation for an in-flight generation token when supported.
    /// - Parameter token: Stable cancellation token.
    func cancelGeneration(token: String?) async
}

public extension ModelProvider {
    /// Default streaming implementation for non-streaming providers.
    /// - Parameter request: Generation request payload.
    /// - Returns: Stream with a single final chunk containing full generated text.
    func generateStream(_ request: ModelGenerationRequest) async -> AsyncThrowingStream<ModelStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let response = try await self.generate(request)
                    continuation.yield(ModelStreamChunk(text: response.text, isFinal: true))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func cancelGeneration(token _: String?) async {}
}

/// Default fallback provider returning deterministic placeholder output.
public struct EchoModelProvider: ModelProvider {
    /// Default echo provider identifier.
    public static let defaultID = "echo"
    /// Provider identifier.
    public let id: String

    /// Creates an echo provider.
    /// - Parameter id: Provider identifier.
    public init(id: String = EchoModelProvider.defaultID) {
        self.id = id
    }

    /// Returns a deterministic echo response.
    /// - Parameter request: Generation request payload.
    /// - Returns: Echo response.
    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        _ = request
        return ModelGenerationResponse(text: "OK", providerID: self.id, modelID: "echo-1")
    }
}

/// Actor that resolves providers and routes generation requests.
public actor ModelRouter {
    private var providers: [String: any ModelProvider]
    private var defaultProviderID: String
    private var throttlePolicy: ModelProviderThrottlePolicy
    private var requestTimestampsByProvider: [String: [Date]] = [:]
    private let diagnosticsSink: RuntimeDiagnosticSink?
    private let runtimeAuthResolver: any ProviderRuntimeAuthResolving
    private var adaptivePolicy: AdaptiveRoutingPolicy?
    private var authConfig: AuthConfig?
    private var authProfileStore: AuthProfileStore?

    /// Creates a model router.
    /// - Parameters:
    ///   - defaultProviderID: Default provider identifier.
    ///   - providers: Initial provider list.
    public init(
        defaultProviderID: String = EchoModelProvider.defaultID,
        providers: [any ModelProvider] = [EchoModelProvider()],
        throttlePolicy: ModelProviderThrottlePolicy = ModelProviderThrottlePolicy(),
        diagnosticsSink: RuntimeDiagnosticSink? = nil,
        adaptiveRoutingConfig: AdaptiveRoutingConfig? = nil,
        authConfig: AuthConfig? = nil,
        authProfileStore: AuthProfileStore? = nil,
        runtimeAuthResolver: any ProviderRuntimeAuthResolving = RuntimeProviderAuthResolver.shared
    ) {
        var map: [String: any ModelProvider] = [:]
        for provider in providers {
            map[provider.id] = provider
        }
        if map[defaultProviderID] == nil {
            map[EchoModelProvider.defaultID] = EchoModelProvider()
            self.defaultProviderID = EchoModelProvider.defaultID
        } else {
            self.defaultProviderID = defaultProviderID
        }
        self.providers = map
        self.throttlePolicy = throttlePolicy
        self.diagnosticsSink = diagnosticsSink
        self.runtimeAuthResolver = runtimeAuthResolver
        self.authConfig = authConfig
        self.authProfileStore = authProfileStore
        if let adaptiveRoutingConfig, adaptiveRoutingConfig.enabled {
            self.adaptivePolicy = AdaptiveRoutingPolicy(config: adaptiveRoutingConfig)
        } else {
            self.adaptivePolicy = nil
        }
    }

    /// Registers or replaces a provider.
    /// - Parameter provider: Provider implementation.
    public func register(_ provider: any ModelProvider) {
        self.providers[provider.id] = provider
    }

    /// Sets default provider by identifier.
    /// - Parameter id: Provider identifier.
    public func setDefaultProviderID(_ id: String) throws {
        guard self.providers[id] != nil else {
            throw OpenClawCoreError.invalidConfiguration("Unknown model provider: \(id)")
        }
        self.defaultProviderID = id
    }

    /// Sets per-provider throttle policy.
    /// - Parameter policy: Provider throttling policy.
    public func setThrottlePolicy(_ policy: ModelProviderThrottlePolicy) {
        self.throttlePolicy = policy
    }

    /// Enables or disables adaptive routing policy.
    /// - Parameter config: Adaptive routing configuration.
    public func setAdaptiveRoutingConfig(_ config: AdaptiveRoutingConfig?) {
        guard let config, config.enabled else {
            self.adaptivePolicy = nil
            return
        }
        self.adaptivePolicy = AdaptiveRoutingPolicy(config: config)
    }

    /// Updates auth config used for profile ordering and cooldowns.
    public func setAuthConfig(_ config: AuthConfig?) {
        self.authConfig = config
    }

    /// Updates the auth profile store used for request credential resolution.
    public func setAuthProfileStore(_ store: AuthProfileStore?) {
        self.authProfileStore = store
    }

    /// Returns a snapshot of adaptive routing scores.
    /// - Parameter candidateProviderIDs: Optional subset of providers for ranking.
    public func adaptiveRoutingSnapshot(candidateProviderIDs: [String]? = nil) -> AdaptiveRoutingSnapshot? {
        guard let adaptivePolicy else {
            return nil
        }
        let candidates = (candidateProviderIDs ?? self.providers.keys.sorted()).filter { !$0.isEmpty }
        return adaptivePolicy.snapshot(for: candidates)
    }

    /// Updates adaptive routing state using aggregate diagnostics telemetry.
    /// - Parameters:
    ///   - diagnostics: Runtime diagnostics snapshot.
    ///   - decayFactor: Historical retention factor (`0...1`).
    /// - Returns: Updated adaptive snapshot.
    public func optimizeRouting(
        using diagnostics: RuntimeUsageSnapshot,
        decayFactor: Double = 0.85
    ) -> AdaptiveRoutingSnapshot? {
        guard self.adaptivePolicy != nil else {
            return nil
        }
        self.adaptivePolicy?.ingest(
            modelMetrics: diagnostics.models,
            decayFactor: decayFactor
        )
        return self.adaptivePolicy?.snapshot(for: self.providers.keys.sorted())
    }

    /// Updates adaptive routing state using a diagnostics pipeline.
    /// - Parameters:
    ///   - diagnosticsPipeline: Runtime diagnostics pipeline.
    ///   - decayFactor: Historical retention factor (`0...1`).
    /// - Returns: Updated adaptive snapshot.
    public func optimizeRouting(
        using diagnosticsPipeline: RuntimeDiagnosticsPipeline,
        decayFactor: Double = 0.85
    ) async -> AdaptiveRoutingSnapshot? {
        guard self.adaptivePolicy != nil else {
            return nil
        }
        let modelMetrics = await diagnosticsPipeline.modelTelemetry()
        self.adaptivePolicy?.ingest(
            modelMetrics: modelMetrics,
            decayFactor: decayFactor
        )
        return self.adaptivePolicy?.snapshot(for: self.providers.keys.sorted())
    }

    /// Returns configured provider identifiers sorted alphabetically.
    public func configuredProviderIDs() -> [String] {
        self.providers.keys.sorted()
    }

    /// Routes generation request to requested/default provider.
    /// - Parameter request: Generation request payload.
    /// - Returns: Provider response.
    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        let orderedProviderIDs = self.resolveProviderOrder(for: request)
        var lastError: Error?
        for (index, providerID) in orderedProviderIDs.enumerated() {
            guard let provider = self.providers[providerID] else {
                continue
            }
            let candidateProfileIDs = await self.resolveAuthProfileOrder(for: providerID, request: request)
            let candidateSet: [String?] = candidateProfileIDs.isEmpty ? [nil] : candidateProfileIDs.map(Optional.some)
            for profileID in candidateSet {
                let startedAt = Date()
                do {
                    try await self.applyThrottleIfNeeded(providerID: providerID)
                    let resolvedRequest = try await self.requestWithResolvedAuth(
                        request,
                        providerID: providerID,
                        profileID: profileID
                    )
                    let response = try await provider.generate(resolvedRequest)
                    let latencyMs = max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
                    self.recordAdaptiveObservation(
                        providerID: providerID,
                        succeeded: true,
                        latencyMs: latencyMs,
                        metadata: resolvedRequest.metadata
                    )
                    if let profileID, let authProfileStore {
                        try? await authProfileStore.recordSuccess(profileID: profileID, provider: providerID)
                    }
                    return response
                } catch {
                    let latencyMs = max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
                    self.recordAdaptiveObservation(
                        providerID: providerID,
                        succeeded: false,
                        latencyMs: latencyMs,
                        metadata: request.metadata
                    )
                    if let profileID, let authProfileStore {
                        try? await authProfileStore.recordFailure(
                            profileID: profileID,
                            provider: providerID,
                            reason: Self.failureReason(for: error),
                            cooldowns: self.authConfig?.cooldowns ?? AuthCooldownConfig()
                        )
                    }
                    lastError = error
                    if let nextProviderID = self.nextAvailableProviderID(after: index, in: orderedProviderIDs) {
                        await self.emitDiagnostic(
                            name: "model.request.retry",
                            metadata: [
                                "fromProviderID": providerID,
                                "profileID": profileID ?? "",
                                "nextProviderID": nextProviderID,
                                "error": String(describing: error),
                            ]
                        )
                    }
                }
            }
        }
        if let lastError {
            throw lastError
        }
        throw OpenClawCoreError.invalidConfiguration(
            "No registered model providers available for request and fallback chain"
        )
    }

    /// Returns a token stream from the first available provider in fallback order.
    /// - Parameter request: Generation request payload.
    /// - Returns: Async throwing stream of model chunks.
    public func generateStream(_ request: ModelGenerationRequest) async -> AsyncThrowingStream<ModelStreamChunk, Error> {
        let orderedProviderIDs = self.resolveProviderOrder(for: request)
        var lastError: Error?
        for (index, providerID) in orderedProviderIDs.enumerated() {
            guard let provider = self.providers[providerID] else {
                continue
            }
            let candidateProfileIDs = await self.resolveAuthProfileOrder(for: providerID, request: request)
            let candidateSet: [String?] = candidateProfileIDs.isEmpty ? [nil] : candidateProfileIDs.map(Optional.some)
            for profileID in candidateSet {
                let startedAt = Date()
                do {
                    try await self.applyThrottleIfNeeded(providerID: providerID)
                    let resolvedRequest = try await self.requestWithResolvedAuth(
                        request,
                        providerID: providerID,
                        profileID: profileID
                    )
                    let stream = await provider.generateStream(resolvedRequest)
                    let latencyMs = max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
                    self.recordAdaptiveObservation(
                        providerID: providerID,
                        succeeded: true,
                        latencyMs: latencyMs,
                        metadata: resolvedRequest.metadata
                    )
                    if let profileID, let authProfileStore {
                        try? await authProfileStore.recordSuccess(profileID: profileID, provider: providerID)
                    }
                    return stream
                } catch {
                    let latencyMs = max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
                    self.recordAdaptiveObservation(
                        providerID: providerID,
                        succeeded: false,
                        latencyMs: latencyMs,
                        metadata: request.metadata
                    )
                    if let profileID, let authProfileStore {
                        try? await authProfileStore.recordFailure(
                            profileID: profileID,
                            provider: providerID,
                            reason: Self.failureReason(for: error),
                            cooldowns: self.authConfig?.cooldowns ?? AuthCooldownConfig()
                        )
                    }
                    lastError = error
                    if let nextProviderID = self.nextAvailableProviderID(after: index, in: orderedProviderIDs) {
                        await self.emitDiagnostic(
                            name: "model.request.retry",
                            metadata: [
                                "fromProviderID": providerID,
                                "profileID": profileID ?? "",
                                "nextProviderID": nextProviderID,
                                "error": String(describing: error),
                                "streaming": "true",
                            ]
                        )
                    }
                }
            }
        }
        return AsyncThrowingStream { continuation in
            continuation.finish(
                throwing: lastError ?? OpenClawCoreError.invalidConfiguration(
                    "No registered model providers available for streaming request"
                )
            )
        }
    }

    /// Broadcasts a cancellation request to registered providers.
    /// - Parameter token: Stable cancellation token.
    public func cancelGeneration(token: String?) async {
        let normalized = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized?.isEmpty == false else {
            return
        }
        let providers = Array(self.providers.values)
        for provider in providers {
            await provider.cancelGeneration(token: normalized)
        }
        await self.emitDiagnostic(
            name: "model.request.cancel",
            metadata: [
                "cancellationToken": normalized ?? "",
            ]
        )
    }

    private func applyThrottleIfNeeded(providerID: String) async throws {
        guard self.throttlePolicy.isEnabled else {
            return
        }
        let now = Date()
        let windowStart = now.addingTimeInterval(-Double(self.throttlePolicy.windowMs) / 1000.0)
        var timestamps = (self.requestTimestampsByProvider[providerID] ?? []).filter { $0 >= windowStart }

        if timestamps.count < self.throttlePolicy.maxRequestsPerWindow {
            timestamps.append(now)
            self.requestTimestampsByProvider[providerID] = timestamps
            return
        }

        switch self.throttlePolicy.strategy {
        case .drop:
            await self.emitDiagnostic(
                name: "model.throttle.drop",
                metadata: [
                    "providerID": providerID,
                    "windowMs": String(self.throttlePolicy.windowMs),
                    "maxRequestsPerWindow": String(self.throttlePolicy.maxRequestsPerWindow),
                ]
            )
            throw OpenClawCoreError.unavailable("Model provider '\(providerID)' is throttled by policy")
        case .delay:
            let earliest = timestamps.first ?? now
            let releaseAt = earliest.addingTimeInterval(Double(self.throttlePolicy.windowMs) / 1000.0)
            let delayMs = max(1, Int(releaseAt.timeIntervalSince(now) * 1000))
            await self.emitDiagnostic(
                name: "model.throttle.delay",
                metadata: [
                    "providerID": providerID,
                    "delayMs": String(delayMs),
                    "windowMs": String(self.throttlePolicy.windowMs),
                    "maxRequestsPerWindow": String(self.throttlePolicy.maxRequestsPerWindow),
                ]
            )
            let sleepNs = UInt64(delayMs) * 1_000_000
            try await Task.sleep(nanoseconds: sleepNs)

            let delayedNow = Date()
            let delayedWindowStart = delayedNow.addingTimeInterval(-Double(self.throttlePolicy.windowMs) / 1000.0)
            timestamps = (self.requestTimestampsByProvider[providerID] ?? []).filter { $0 >= delayedWindowStart }
            timestamps.append(delayedNow)
            self.requestTimestampsByProvider[providerID] = timestamps
        }
    }

    private func nextAvailableProviderID(after index: Int, in orderedProviderIDs: [String]) -> String? {
        guard index + 1 < orderedProviderIDs.count else {
            return nil
        }
        for nextIndex in (index + 1)..<orderedProviderIDs.count {
            let nextProviderID = orderedProviderIDs[nextIndex]
            if self.providers[nextProviderID] != nil {
                return nextProviderID
            }
        }
        return nil
    }

    private func emitDiagnostic(name: String, metadata: [String: String]) async {
        guard let diagnosticsSink else { return }
        await diagnosticsSink(
            RuntimeDiagnosticEvent(
                subsystem: "model",
                name: name,
                metadata: metadata
            )
        )
    }

    private func resolveProviderOrder(for request: ModelGenerationRequest) -> [String] {
        var orderedIDs: [String] = []
        var seen: Set<String> = []

        func appendProviderID(_ rawID: String?) {
            guard let rawID else { return }
            let normalized = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { return }
            if seen.insert(normalized).inserted {
                orderedIDs.append(normalized)
            }
        }

        func appendProviderList(_ rawList: String?) {
            guard let rawList else { return }
            let components = rawList.split { character in
                character == "," || character == ";"
            }
            for component in components {
                appendProviderID(String(component))
            }
        }

        appendProviderID(request.providerID)
        for fallbackID in request.policy.fallbackProviderIDs {
            appendProviderID(fallbackID)
        }
        appendProviderList(request.metadata["fallbackProviderID"])
        appendProviderList(request.metadata["fallbackProviderIDs"])
        appendProviderID(self.defaultProviderID)

        guard let adaptivePolicy else {
            return orderedIDs
        }

        let explicitProvider = request.providerID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let explicitProvider, !explicitProvider.isEmpty {
            let tail = orderedIDs.filter { $0 != explicitProvider }
            let rankedTail = adaptivePolicy.rankedProviderIDs(from: tail)
            return [explicitProvider] + rankedTail
        }
        return adaptivePolicy.rankedProviderIDs(from: orderedIDs)
    }

    private func recordAdaptiveObservation(
        providerID: String,
        succeeded: Bool,
        latencyMs: Int,
        metadata: [String: String]
    ) {
        guard self.adaptivePolicy != nil else {
            return
        }
        let normalizedProvider = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        let cost = Self.metadataDouble(
            metadata,
            keys: ["costUSD:\(normalizedProvider)", "estimatedCostUSD:\(normalizedProvider)", "costUSD", "estimatedCostUSD"]
        )
        let quality = Self.metadataDouble(
            metadata,
            keys: ["qualityScore:\(normalizedProvider)", "qualityScore"]
        )
        self.adaptivePolicy?.record(
            providerID: normalizedProvider,
            succeeded: succeeded,
            latencyMs: latencyMs,
            costUSD: cost,
            qualityScore: quality
        )
    }

    private static func metadataDouble(_ metadata: [String: String], keys: [String]) -> Double? {
        for key in keys {
            guard let raw = metadata[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty,
                  let value = Double(raw)
            else {
                continue
            }
            return value
        }
        return nil
    }

    private func resolveAuthProfileOrder(for providerID: String, request: ModelGenerationRequest) async -> [String] {
        guard let authProfileStore else {
            return []
        }
        let snapshot = await authProfileStore.snapshot()
        return AuthProfileResolver.resolveProfileOrder(
            provider: providerID,
            preferredProfileID: request.preferredAuthProfileID,
            config: self.authConfig,
            snapshot: snapshot
        )
    }

    private func requestWithResolvedAuth(
        _ request: ModelGenerationRequest,
        providerID: String,
        profileID: String?
    ) async throws -> ModelGenerationRequest {
        guard let profileID, let authProfileStore, let credential = try await authProfileStore.resolvedCredential(for: profileID) else {
            return request
        }
        let runtimeResolution = try await self.runtimeAuthResolver.resolve(
            providerID: providerID,
            credential: credential
        )
        if runtimeResolution.persistCredential, runtimeResolution.credential != credential {
            try await authProfileStore.setCredential(runtimeResolution.credential, for: profileID)
        }
        var metadata = request.metadata
        metadata["auth.profileID"] = profileID
        metadata["auth.providerID"] = providerID
        for (key, value) in runtimeResolution.metadata {
            let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedKey.isEmpty, !normalizedValue.isEmpty else { continue }
            metadata[normalizedKey] = normalizedValue
        }
        switch runtimeResolution.credential {
        case .apiKey(let value):
            if let key = value.key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
                metadata["auth.apiKey"] = key
            }
        case .token(let value):
            if let token = value.token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
                metadata["auth.accessToken"] = token
            }
            if let expires = value.expires {
                metadata["auth.expires"] = String(expires)
            }
        case .oauth(let value):
            if let accessToken = value.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines), !accessToken.isEmpty {
                metadata["auth.accessToken"] = accessToken
            }
            if let refreshToken = value.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines), !refreshToken.isEmpty {
                metadata["auth.refreshToken"] = refreshToken
            }
            if let clientID = value.clientID?.trimmingCharacters(in: .whitespacesAndNewlines), !clientID.isEmpty {
                metadata["auth.clientID"] = clientID
            }
            if let expires = value.expires {
                metadata["auth.expires"] = String(expires)
            }
        }
        return ModelGenerationRequest(
            sessionKey: request.sessionKey,
            prompt: request.prompt,
            systemPrompt: request.systemPrompt,
            providerID: request.providerID,
            modelID: request.modelID,
            preferredAuthProfileID: request.preferredAuthProfileID,
            metadata: metadata,
            headers: request.headers,
            policy: request.policy,
            attachments: request.attachments
        )
    }

    private static func failureReason(for error: Error) -> AuthProfileFailureReason {
        let description = String(describing: error).lowercased()
        if description.contains("rate") || description.contains("429") {
            return .rateLimit
        }
        if description.contains("billing") || description.contains("quota") {
            return .billing
        }
        if description.contains("timeout") {
            return .timeout
        }
        if description.contains("expired") || description.contains("session") {
            return .sessionExpired
        }
        if description.contains("model") && description.contains("not found") {
            return .modelNotFound
        }
        if description.contains("auth") || description.contains("token") || description.contains("unauthorized") {
            return .auth
        }
        return .unknown
    }
}
