import Foundation
import OpenClawCore

/// Runtime contract for loading and querying a local model engine.
public protocol LocalModelEngine: Sendable {
    /// Loads model resources.
    /// - Parameters:
    ///   - path: Model path.
    ///   - configuration: Local model configuration.
    func loadModel(path: String, configuration: LocalModelConfig) async throws
    /// Unloads model resources.
    func unloadModel() async
    /// Returns whether model resources are currently loaded.
    func isModelLoaded() async -> Bool
    /// Generates text output and optionally streams tokens.
    /// - Parameters:
    ///   - prompt: Prompt payload.
    ///   - systemPrompt: Optional system prompt.
    ///   - configuration: Local model configuration.
    ///   - onToken: Optional streaming token callback.
    /// - Returns: Final generated output text.
    func generate(
        prompt: String,
        systemPrompt: String?,
        configuration: LocalModelConfig,
        onToken: (@Sendable (String) -> Bool)?
    ) async throws -> String

    /// Switches active runtime/backend implementation.
    /// - Parameters:
    ///   - from: Previously active runtime identifier.
    ///   - to: Next runtime identifier.
    ///   - configuration: Local model configuration.
    func switchRuntime(from: String?, to: String, configuration: LocalModelConfig) async throws

    /// Requests cancellation for active generation.
    /// - Parameter token: Optional cancellation token identifier.
    func cancelGeneration(token: String?) async

    /// Serializes current local runtime state.
    func saveState() async throws -> Data?

    /// Restores previously serialized runtime state.
    /// - Parameter state: Serialized state payload.
    func restoreState(_ state: Data) async throws
}

public extension LocalModelEngine {
    /// Default no-op runtime switch implementation for engines that expose only one backend.
    func switchRuntime(from _: String?, to _: String, configuration _: LocalModelConfig) async throws {}
    /// Default no-op cancellation implementation.
    func cancelGeneration(token _: String?) async {}
    /// Default no-op state save implementation.
    func saveState() async throws -> Data? { nil }
    /// Default no-op state restore implementation.
    func restoreState(_: Data) async throws {}
}

/// Model provider that routes generation calls to a local model engine.
public actor LocalModelProvider: ModelProvider {
    private final class CancellationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        func cancel() {
            self.lock.lock()
            self.cancelled = true
            self.lock.unlock()
        }

        func isCancelled() -> Bool {
            self.lock.lock()
            let value = self.cancelled
            self.lock.unlock()
            return value
        }
    }

    /// Canonical provider identifier.
    public static let providerID = "local"
    /// Provider identifier.
    public let id: String

    private let engine: any LocalModelEngine
    private let configuration: LocalModelConfig
    private var activeRuntimeID: String?
    private var activeModelPath: String?
    private var cancellationFlags: [String: CancellationFlag] = [:]

    /// Creates a local model provider.
    /// - Parameters:
    ///   - id: Provider identifier.
    ///   - configuration: Local model configuration.
    ///   - engine: Local model engine implementation.
    public init(
        id: String = LocalModelProvider.providerID,
        configuration: LocalModelConfig,
        engine: any LocalModelEngine
    ) {
        self.id = id
        self.configuration = configuration
        self.engine = engine
    }

    /// Generates text using the local model runtime.
    /// - Parameter request: Generation request payload.
    /// - Returns: Generation response payload.
    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        let prepared = try await self.prepareGeneration(request)
        let output = try await self.engine.generate(
            prompt: request.prompt,
            systemPrompt: request.systemPrompt,
            configuration: prepared.configuration,
            onToken: prepared.onToken
        )
        self.clearCancellationToken(prepared.cancellationToken)
        if prepared.cancellationFlag?.isCancelled() == true {
            throw OpenClawCoreError.unavailable("Local generation was cancelled")
        }
        return ModelGenerationResponse(
            text: output,
            providerID: self.id,
            modelID: URL(fileURLWithPath: prepared.modelPath).lastPathComponent
        )
    }

    /// Streams local generation output by forwarding token callbacks.
    /// - Parameter request: Generation request payload.
    /// - Returns: Async stream of generation chunks.
    public func generateStream(_ request: ModelGenerationRequest) async -> AsyncThrowingStream<ModelStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let prepared = try await self.prepareGeneration(request, forceStreaming: true)
                    _ = try await self.engine.generate(
                        prompt: request.prompt,
                        systemPrompt: request.systemPrompt,
                        configuration: prepared.configuration,
                        onToken: { token in
                            continuation.yield(ModelStreamChunk(text: token, isFinal: false))
                            return prepared.onToken?(token) ?? true
                        }
                    )
                    continuation.yield(ModelStreamChunk(text: "", isFinal: true))
                    continuation.finish()
                    await self.clearCancellationTokenAsync(prepared.cancellationToken)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Unloads the underlying model engine.
    public func unload() async {
        await self.engine.unloadModel()
        self.activeModelPath = nil
    }

    /// Requests cancellation for a local generation token.
    /// - Parameter token: Optional cancellation token.
    public func cancelGeneration(token: String?) async {
        let normalized = self.normalizedToken(token)
        if let normalized {
            let flag = self.cancellationFlags[normalized] ?? CancellationFlag()
            flag.cancel()
            self.cancellationFlags[normalized] = flag
        }
        await self.engine.cancelGeneration(token: normalized)
    }

    /// Saves local runtime state from the engine.
    /// - Returns: Optional serialized state payload.
    public func saveRuntimeState() async throws -> Data? {
        try await self.engine.saveState()
    }

    /// Restores local runtime state into the engine.
    /// - Parameter state: Serialized runtime state.
    public func restoreRuntimeState(_ state: Data) async throws {
        try await self.engine.restoreState(state)
    }

    private func normalizedToken(_ token: String?) -> String? {
        guard let token else { return nil }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func resolveRuntime(for request: ModelGenerationRequest) -> String {
        request.policy.localRuntimeHints["runtime"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
            ? request.policy.localRuntimeHints["runtime"]!.trimmingCharacters(in: .whitespacesAndNewlines)
            : self.configuration.runtime
    }

    private func resolveConfiguration(for request: ModelGenerationRequest, runtime: String) -> LocalModelConfig {
        var config = self.configuration
        config.runtime = runtime
        if let maxTokens = request.policy.maxTokens {
            config.maxTokens = maxTokens
        }
        if let temperature = request.policy.temperature {
            config.temperature = temperature
        }
        if let topP = request.policy.topP {
            config.topP = topP
        }
        if let topK = request.policy.topK {
            config.topK = topK
        }
        if let timeout = request.policy.requestTimeoutMs {
            config.requestTimeoutMs = timeout
        }
        if let useMetalRaw = request.policy.localRuntimeHints["useMetal"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           let useMetal = Bool(useMetalRaw)
        {
            config.useMetal = useMetal
        }
        config.streamTokens = request.policy.streamTokens
        config.allowCancellation = request.policy.allowCancellation
        return config
    }

    private func resolveModelPath(configuration: LocalModelConfig) throws -> String {
        var candidates: [String] = []
        if let modelPath = configuration.modelPath {
            candidates.append(modelPath)
        }
        candidates.append(contentsOf: configuration.fallbackModelPaths)
        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        throw OpenClawCoreError.invalidConfiguration("Local model path is required")
    }

    private func ensureRuntimeAndModelLoaded(
        runtime: String,
        modelPath: String,
        configuration: LocalModelConfig
    ) async throws {
        if self.activeRuntimeID != runtime {
            if await self.engine.isModelLoaded() {
                await self.engine.unloadModel()
            }
            try await self.engine.switchRuntime(from: self.activeRuntimeID, to: runtime, configuration: configuration)
            self.activeRuntimeID = runtime
            self.activeModelPath = nil
        }

        if await self.engine.isModelLoaded() == false || self.activeModelPath != modelPath {
            if await self.engine.isModelLoaded(), self.activeModelPath != modelPath {
                await self.engine.unloadModel()
            }
            try await self.engine.loadModel(path: modelPath, configuration: configuration)
            self.activeModelPath = modelPath
        }
    }

    private func resolveCancellationFlag(for token: String?, allowCancellation: Bool) -> CancellationFlag? {
        guard allowCancellation, let token else { return nil }
        if let existing = self.cancellationFlags[token] {
            return existing
        }
        let created = CancellationFlag()
        self.cancellationFlags[token] = created
        return created
    }

    private func clearCancellationToken(_ token: String?) {
        guard let token else { return }
        self.cancellationFlags.removeValue(forKey: token)
    }

    private func clearCancellationTokenAsync(_ token: String?) async {
        self.clearCancellationToken(token)
    }

    private func prepareGeneration(
        _ request: ModelGenerationRequest,
        forceStreaming: Bool = false
    ) async throws -> (
        modelPath: String,
        configuration: LocalModelConfig,
        cancellationToken: String?,
        cancellationFlag: CancellationFlag?,
        onToken: (@Sendable (String) -> Bool)?
    ) {
        guard self.configuration.enabled else {
            throw OpenClawCoreError.unavailable("Local model provider is disabled")
        }

        let runtime = self.resolveRuntime(for: request)
        let configuration = self.resolveConfiguration(for: request, runtime: runtime)
        let modelPath = try self.resolveModelPath(configuration: configuration)
        let cancellationToken = self.normalizedToken(request.policy.cancellationToken)
        let cancellationFlag = self.resolveCancellationFlag(
            for: cancellationToken,
            allowCancellation: configuration.allowCancellation
        )
        if cancellationFlag?.isCancelled() == true {
            throw OpenClawCoreError.unavailable("Local generation was cancelled")
        }

        try await self.ensureRuntimeAndModelLoaded(
            runtime: runtime,
            modelPath: modelPath,
            configuration: configuration
        )

        let streamingEnabled = forceStreaming || configuration.streamTokens
        let onToken: (@Sendable (String) -> Bool)?
        if streamingEnabled {
            onToken = { _ in
                if configuration.allowCancellation, let cancellationFlag {
                    return !cancellationFlag.isCancelled()
                }
                return true
            }
        } else {
            onToken = nil
        }

        return (modelPath, configuration, cancellationToken, cancellationFlag, onToken)
    }
}

/// Test-friendly local model engine that returns deterministic output.
public actor StubLocalModelEngine: LocalModelEngine {
    private var loaded = false
    private var runtimeID: String?
    private let cannedResponse: String

    /// Creates a stub engine.
    /// - Parameter cannedResponse: Response returned for generation calls.
    public init(cannedResponse: String = "local-ok") {
        self.cannedResponse = cannedResponse
    }

    /// Marks model as loaded.
    public func loadModel(path _: String, configuration _: LocalModelConfig) async throws {
        self.loaded = true
    }

    /// Marks model as unloaded.
    public func unloadModel() async {
        self.loaded = false
    }

    /// Returns current loaded state.
    public func isModelLoaded() async -> Bool {
        self.loaded
    }

    /// Returns deterministic output and forwards it to optional token callback.
    public func generate(
        prompt _: String,
        systemPrompt _: String?,
        configuration _: LocalModelConfig,
        onToken: (@Sendable (String) -> Bool)?
    ) async throws -> String {
        if let onToken {
            _ = onToken(self.cannedResponse)
        }
        return self.cannedResponse
    }

    public func switchRuntime(from _: String?, to: String, configuration _: LocalModelConfig) async throws {
        self.runtimeID = to
    }

    public func saveState() async throws -> Data? {
        guard let runtimeID else { return nil }
        return Data(runtimeID.utf8)
    }

    public func restoreState(_ state: Data) async throws {
        self.runtimeID = String(decoding: state, as: UTF8.self)
    }
}
