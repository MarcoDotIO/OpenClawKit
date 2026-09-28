import Foundation
import OpenClawCore
import OpenClawProtocol

// Apple Foundation Models provider (`apple-fm`), in-process parity with upstream extensions/apple-fm.
//
// Platform matrix:
// - iOS/macOS/visionOS 26+: on-device `SystemLanguageModel` (`apple-fm/system`).
// - iOS/macOS/visionOS/watchOS 27+: `PrivateCloudComputeLanguageModel` (`apple-fm/private-cloud-compute`)
//   and the FoundationModels 27 surface (context options, tool-calling modes, images, usage).
// - watchOS 27: Private Cloud Compute only; `SystemLanguageModel` is unavailable there.
// - tvOS: the 27 SDK ships the module but every declaration is unavailable, so nothing runs.
// - Linux: identity, facts, config builders, schema conversion and validation only.
//
// The SystemLanguageModel code below is limited to iOS, macOS and visionOS (`!os(tvOS) && !os(watchOS)`).
#if canImport(FoundationModels) && !os(tvOS) && (!os(watchOS) || compiler(>=6.4))
import FoundationModels
#endif

/// Runtime availability for Apple Foundation Models.
public enum FoundationModelsRuntimeAvailability: Sendable, Equatable {
    /// Foundation Models can be used for requests.
    case available
    /// Foundation Models are unavailable, with a concrete reason when known.
    case unavailable(Reason)

    /// Unavailability reasons surfaced by the framework or host platform.
    public enum Reason: Sendable, Equatable {
        /// The FoundationModels framework is missing or unusable on this platform (tvOS, Linux).
        case frameworkUnavailable
        /// The OS is older than the framework (26 for the system model, 27 for Private Cloud Compute).
        case unsupportedOS
        /// The simulator or a sandboxed runtime cannot run Apple Intelligence.
        case restrictedEnvironment
        /// The device is not eligible for Apple Intelligence.
        case deviceNotEligible
        /// Apple Intelligence is turned off.
        case appleIntelligenceNotEnabled
        /// The on-device model is still downloading or preparing.
        case modelNotReady
        /// The on-device system model does not exist on this platform (watchOS); Private Cloud
        /// Compute may still be available.
        case systemModelUnsupportedOnPlatform
        /// The model's context window is below the utility-role minimum (8,192 tokens).
        case contextWindowTooSmall(Int)
        /// Model assets are missing.
        case assetsUnavailable
        /// The device is not eligible for Private Cloud Compute.
        case privateCloudDeviceNotEligible
        /// Private Cloud Compute is not ready (for example Apple Intelligence off or offline).
        case privateCloudSystemNotReady
        /// The framework reported a reason this SDK does not know.
        case unknown

        /// Stable reason code (for logs and wire payloads).
        public var code: String {
            switch self {
            case .frameworkUnavailable: return "framework_unavailable"
            case .unsupportedOS: return "unsupported_os"
            case .restrictedEnvironment: return "restricted_environment"
            case .deviceNotEligible: return "device_not_eligible"
            case .appleIntelligenceNotEnabled: return "apple_intelligence_not_enabled"
            case .modelNotReady: return "model_not_ready"
            case .systemModelUnsupportedOnPlatform: return "system_model_unsupported_on_platform"
            case .contextWindowTooSmall: return "context_window_too_small"
            case .assetsUnavailable: return "assets_unavailable"
            case .privateCloudDeviceNotEligible: return "private_cloud_device_not_eligible"
            case .privateCloudSystemNotReady: return "private_cloud_system_not_ready"
            case .unknown: return "unknown"
            }
        }
    }

    /// Convenience Boolean for simple gating.
    public var isAvailable: Bool {
        if case .available = self {
            return true
        }
        return false
    }

    /// User-facing explanation (upstream apple-fm setup copy, made platform neutral).
    public var message: String {
        switch self {
        case .available:
            return "Foundation Models are available."
        case .unavailable(let reason):
            switch reason {
            case .frameworkUnavailable:
                return "Foundation Models are unavailable on this platform."
            case .unsupportedOS:
                return "Foundation Models require Apple OS 26 or later."
            case .restrictedEnvironment:
                return "Foundation Models are unavailable in the current simulator or sandboxed runtime environment."
            case .deviceNotEligible:
                return "This device is not eligible for Apple Intelligence. Choose another model."
            case .appleIntelligenceNotEnabled:
                return "Enable Apple Intelligence in System Settings, then retry setup."
            case .modelNotReady:
                return "Wait for Apple Intelligence to finish downloading its model, then retry setup."
            case .systemModelUnsupportedOnPlatform:
                return "The on-device Apple Foundation Models system model is unavailable on this platform. "
                    + "Use \(FoundationModelsProvider.privateCloudComputeModelRef) where Private Cloud Compute is supported."
            case .contextWindowTooSmall(let tokens):
                return "\(FoundationModelsProvider.displayName) provides \(tokens) context tokens. "
                    + "OpenClaw's Apple setup option requires at least \(FoundationModelsProvider.minimumUtilityContextWindow). "
                    + "Choose another local or cloud model on this device."
            case .assetsUnavailable:
                return "Apple Foundation Models assets are unavailable. Wait for Apple Intelligence to finish downloading its model, then retry."
            case .privateCloudDeviceNotEligible:
                return "This device is not eligible for Private Cloud Compute. Choose another model."
            case .privateCloudSystemNotReady:
                return "Private Cloud Compute is not ready. Check that Apple Intelligence is enabled and the device is online, then retry."
            case .unknown:
                return "Apple Intelligence is unavailable. Check System Settings, then retry setup."
            }
        }
    }
}

/// Model provider backed by Apple Foundation Models (`apple-fm`).
///
/// In-process port of upstream OpenClaw's `apple-fm` provider:
/// - Transcript replay: ``ModelGenerationRequest/messages`` (instructions, prompts, responses,
///   reasoning, tool calls and tool outputs) become a Foundation Models `Transcript`; the last user
///   message is the prompt, and an empty prompt resumes after tool output.
/// - Host-owned tool calling: ``ModelGenerationRequest/tools`` are converted from JSON Schema with
///   ``FoundationModelsSchemaConverter``. By default the first call stops generation and is returned
///   as a proposed ``ModelToolCall`` (stop reason ``ModelStopReason/toolUse``); the agent loop owns
///   approval and execution. ``FoundationModelsToolExecutionMode/executeInProcess(_:)`` runs tools
///   inside the session instead.
/// - Structured output: `jsonSchema` response formats use guided generation and the text is
///   re-validated against the caller's schema (lengths and patterns are host-enforced).
/// - Streaming, usage, reasoning levels, sampling, tool-calling modes, images (models with vision)
///   and Private Cloud Compute on OS 27.
///
/// Requests stay on device for `apple-fm/system`. `apple-fm/private-cloud-compute` (alias
/// `apple-fm/pcc`) runs on Apple's Private Cloud Compute and requires the app to hold Apple's
/// managed PCC entitlement (<https://developer.apple.com/private-cloud-compute/>); without it
/// requests fail. With ``FoundationModelsProviderOptions/fallbackToOnDevice`` a failed or
/// quota-limited PCC request retries on the on-device model.
public struct FoundationModelsProvider: ModelProvider {
    /// Provider identifier.
    public let id: String
    /// Provider configuration.
    public let options: FoundationModelsProviderOptions
    let cancellations = FoundationModelsCancellationRegistry()

    /// Creates a Foundation Models provider.
    /// - Parameters:
    ///   - id: Provider identifier (defaults to ``providerID``).
    ///   - options: Provider configuration.
    public init(id: String = FoundationModelsProvider.providerID, options: FoundationModelsProviderOptions = FoundationModelsProviderOptions()) {
        self.id = id
        self.options = options
        if options.prewarm {
            let provider = self
            Task {
                provider.prewarm()
            }
        }
    }

    /// Contract v2 capabilities: streaming, tools, JSON Schema output and transcripts everywhere the
    /// framework runs; images when the default model has vision; reasoning for Private Cloud Compute.
    public var capabilities: ModelProviderCapabilities {
        let facts = self.options.defaultTarget == .system ? Self.systemModelFacts() : nil
        let privateCloud = self.options.defaultTarget == .privateCloudCompute
        return ModelProviderCapabilities(
            supportsStreaming: true,
            supportsTools: true,
            supportsParallelToolCalls: false,
            supportsJSONSchema: true,
            supportsImages: facts?.supportsVision ?? privateCloud,
            supportsReasoning: privateCloud,
            supportsTranscript: true
        )
    }

    // MARK: Generation

    /// Generates a response.
    /// - Parameter request: Generation request payload.
    /// - Returns: Generation response payload (model ID `system` or `private-cloud-compute`).
    /// - Throws: ``OpenClawCoreError/unavailable(_:)`` when the model is unavailable,
    ///   ``FoundationModelsError`` for framework and validation failures, `CancellationError` when
    ///   cancelled (a cancelled request never returns tool calls).
    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        try await self.generateDetailed(request).response
    }

    /// Generates a response and reports the backend used and any in-process tool executions.
    /// - Parameter request: Generation request payload.
    /// - Returns: Detailed result.
    public func generateDetailed(_ request: ModelGenerationRequest) async throws -> FoundationModelsGenerationResult {
        let token = request.policy.allowCancellation ? request.policy.cancellationToken : nil
        let task = Task {
            try await self.execute(request, sink: nil)
        }
        let registration = self.cancellations.register(token: token) {
            task.cancel()
        }
        defer {
            self.cancellations.unregister(registration)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Streams a response.
    ///
    /// Plain text requests stream deltas from `streamResponse` snapshots. Requests with tools or a
    /// JSON Schema publish only after the response completes and validates (upstream event order:
    /// text, then tool calls, then the final chunk with stop reason `toolUse` or `stop`).
    /// - Parameter request: Generation request payload.
    /// - Returns: Chunk stream ending with a `.final` chunk.
    public func generateStream(_ request: ModelGenerationRequest) async -> AsyncThrowingStream<ModelStreamChunk, Error> {
        let token = request.policy.allowCancellation ? request.policy.cancellationToken : nil
        return AsyncThrowingStream { continuation in
            let sink = FoundationModelsTextSink { chunk in
                continuation.yield(chunk)
            }
            let task = Task {
                do {
                    let response = try await self.execute(request, sink: sink).response
                    try Task.checkCancellation()
                    if let reasoning = response.reasoningText, !reasoning.isEmpty {
                        continuation.yield(.reasoningDelta(reasoning))
                    }
                    if !sink.didEmit, !response.text.isEmpty {
                        continuation.yield(ModelStreamChunk(kind: .text, text: response.text))
                    }
                    for (index, call) in response.toolCalls.enumerated() {
                        continuation.yield(
                            .toolCallUpdate(ModelToolCallDelta(index: index, id: call.id, name: call.name, argumentsDelta: call.argumentsJSON))
                        )
                    }
                    continuation.yield(.completed(response: response))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            let registration = self.cancellations.register(token: token) {
                task.cancel()
            }
            continuation.onTermination = { _ in
                task.cancel()
                self.cancellations.unregister(registration)
            }
        }
    }

    /// Cancels in-flight requests started with the given ``ModelGenerationPolicy/cancellationToken``.
    /// - Parameter token: Cancellation token.
    public func cancelGeneration(token: String?) async {
        guard let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            return
        }
        self.cancellations.cancel(token: token)
    }

    func execute(_ request: ModelGenerationRequest, sink: FoundationModelsTextSink?) async throws -> FoundationModelsGenerationResult {
        let target = Self.resolveTarget(modelID: request.modelID, defaultTarget: self.options.defaultTarget)
        #if canImport(FoundationModels) && !os(tvOS) && (!os(watchOS) || compiler(>=6.4))
        return try await AppleFoundationModelsEngine(providerID: self.id, options: self.options).run(request, target: target, sink: sink)
        #else
        _ = sink
        throw OpenClawCoreError.unavailable(Self.runtimeAvailability(target: target).message)
        #endif
    }

    /// Resolves the backend for a request model identifier.
    ///
    /// Known identifiers and aliases select their backend; `nil`, empty or unknown identifiers (for
    /// example another provider's model ID during fallback) use `defaultTarget`.
    /// - Parameters:
    ///   - modelID: Request model identifier.
    ///   - defaultTarget: Backend for unspecified or unknown identifiers.
    /// - Returns: The backend.
    public static func resolveTarget(modelID: String?, defaultTarget: AppleFoundationModelTarget = .system) -> AppleFoundationModelTarget {
        guard let modelID, let target = AppleFoundationModelTarget(modelID: modelID) else {
            return defaultTarget
        }
        return target
    }

    // MARK: Availability

    /// Probes runtime availability for the on-device system language model.
    ///
    /// The simulator reports ``FoundationModelsRuntimeAvailability/Reason/restrictedEnvironment``; use
    /// ``runtimeAvailability(target:treatSimulatorAsUnavailable:)`` to probe it anyway.
    /// - Returns: Structured availability state for the current environment.
    public static func runtimeAvailability() -> FoundationModelsRuntimeAvailability {
        self.runtimeAvailability(target: .system)
    }

    /// Probes runtime availability for a model identifier (`system`, `private-cloud-compute`, `pcc`).
    /// - Parameter modelID: Model identifier; `nil` or unknown identifiers probe the system model.
    /// - Returns: Availability.
    public static func runtimeAvailability(modelID: String?) -> FoundationModelsRuntimeAvailability {
        self.runtimeAvailability(target: self.resolveTarget(modelID: modelID))
    }

    /// Probes runtime availability for a backend.
    /// - Parameters:
    ///   - target: Backend to probe.
    ///   - treatSimulatorAsUnavailable: Report the simulator as a restricted environment without probing.
    /// - Returns: Availability.
    public static func runtimeAvailability(
        target: AppleFoundationModelTarget,
        treatSimulatorAsUnavailable: Bool = true
    ) -> FoundationModelsRuntimeAvailability {
        #if targetEnvironment(simulator)
        if treatSimulatorAsUnavailable {
            return .unavailable(.restrictedEnvironment)
        }
        #endif
        switch target {
        case .system:
            return self.systemAvailability()
        case .privateCloudCompute:
            return self.privateCloudAvailability()
        }
    }

    private static func systemAvailability() -> FoundationModelsRuntimeAvailability {
        #if canImport(FoundationModels) && !os(tvOS) && !os(watchOS)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible:
                    return .unavailable(.deviceNotEligible)
                case .appleIntelligenceNotEnabled:
                    return .unavailable(.appleIntelligenceNotEnabled)
                case .modelNotReady:
                    return .unavailable(.modelNotReady)
                @unknown default:
                    return .unavailable(.unknown)
                }
            }
        }
        return .unavailable(.unsupportedOS)
        #elseif os(watchOS)
        return .unavailable(.systemModelUnsupportedOnPlatform)
        #else
        return .unavailable(.frameworkUnavailable)
        #endif
    }

    private static func privateCloudAvailability() -> FoundationModelsRuntimeAvailability {
        #if compiler(>=6.4) && canImport(FoundationModels) && !os(tvOS)
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *) {
            switch PrivateCloudComputeLanguageModel().availability {
            case .available:
                return .available
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible:
                    return .unavailable(.privateCloudDeviceNotEligible)
                case .systemNotReady:
                    return .unavailable(.privateCloudSystemNotReady)
                @unknown default:
                    return .unavailable(.unknown)
                }
            }
        }
        return .unavailable(.unsupportedOS)
        #else
        return .unavailable(.frameworkUnavailable)
        #endif
    }

    // MARK: Facts

    /// Facts for the on-device system model (upstream helper `info`).
    ///
    /// OS 27: `SystemLanguageModel.default.variant.displayName`, `contextSize` and capabilities.
    /// OS 26.x: name `Apple Foundation Models` and the back-deployed `contextSize` (4096 before 27),
    /// which is below the utility-role minimum, matching upstream.
    /// - Returns: Facts; unavailable facts carry the availability message as `reason`.
    public static func systemModelFacts() -> AppleFoundationModelFacts {
        let availability = self.runtimeAvailability(target: .system)
        guard availability.isAvailable else {
            return .unavailable(target: .system, reason: availability.message)
        }
        #if canImport(FoundationModels) && !os(tvOS) && !os(watchOS)
        #if compiler(>=6.4)
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
            let model = SystemLanguageModel.default
            let capabilities = model.capabilities
            let variantID: String
            if model.variant == .coreAdvanced3 {
                variantID = "coreAdvanced3"
            } else if model.variant == .core3 {
                variantID = "core3"
            } else {
                variantID = "unknown"
            }
            return AppleFoundationModelFacts(
                target: .system,
                available: true,
                modelName: model.variant.displayName,
                contextWindow: model.contextSize,
                variantID: variantID,
                supportsVision: capabilities.contains(.vision),
                supportsReasoning: capabilities.contains(.reasoning),
                supportsToolCalling: capabilities.contains(.toolCalling),
                supportsGuidedGeneration: capabilities.contains(.guidedGeneration)
            )
        }
        #endif
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            #if compiler(>=6.4)
            let contextWindow = SystemLanguageModel.default.contextSize
            #else
            let contextWindow = 4_096
            #endif
            return AppleFoundationModelFacts(target: .system, available: true, modelName: self.displayName, contextWindow: contextWindow)
        }
        #endif
        return .unavailable(target: .system, reason: FoundationModelsRuntimeAvailability.unavailable(.unsupportedOS).message)
    }

    /// Facts for a backend. Private Cloud Compute reads its context size asynchronously (OS 27).
    /// - Parameter target: Backend.
    /// - Returns: Facts.
    public static func facts(target: AppleFoundationModelTarget) async -> AppleFoundationModelFacts {
        switch target {
        case .system:
            return self.systemModelFacts()
        case .privateCloudCompute:
            let availability = self.runtimeAvailability(target: .privateCloudCompute)
            guard availability.isAvailable else {
                return .unavailable(target: .privateCloudCompute, reason: availability.message)
            }
            #if compiler(>=6.4) && canImport(FoundationModels) && !os(tvOS)
            if #available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *) {
                let model = PrivateCloudComputeLanguageModel()
                let capabilities = model.capabilities
                return AppleFoundationModelFacts(
                    target: .privateCloudCompute,
                    available: true,
                    modelName: self.privateCloudComputeDisplayName,
                    contextWindow: (try? await model.contextSize) ?? 0,
                    supportsVision: capabilities.contains(.vision),
                    supportsReasoning: capabilities.contains(.reasoning),
                    supportsToolCalling: capabilities.contains(.toolCalling),
                    supportsGuidedGeneration: capabilities.contains(.guidedGeneration)
                )
            }
            #endif
            return .unavailable(target: .privateCloudCompute, reason: availability.message)
        }
    }

    /// Whether a backend supports a locale, so hosts can route unsupported languages elsewhere
    /// before sending a request (system model: OS 26+; Private Cloud Compute: OS 27+).
    /// - Parameters:
    ///   - locale: Locale to check.
    ///   - target: Backend.
    /// - Returns: `false` where the backend does not exist.
    public static func supportsLocale(_ locale: Locale = .current, target: AppleFoundationModelTarget = .system) async -> Bool {
        switch target {
        case .system:
            #if canImport(FoundationModels) && !os(tvOS) && !os(watchOS)
            if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
                return SystemLanguageModel.default.supportsLocale(locale)
            }
            #endif
            return false
        case .privateCloudCompute:
            #if compiler(>=6.4) && canImport(FoundationModels) && !os(tvOS)
            if #available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *) {
                return (try? await PrivateCloudComputeLanguageModel().supportsLocale(locale)) ?? false
            }
            #endif
            _ = locale
            return false
        }
    }

    // MARK: Private Cloud Compute quota

    /// Current Private Cloud Compute quota (OS 27), or `nil` where PCC does not exist.
    /// - Returns: Quota snapshot.
    public static func privateCloudQuota() -> FoundationModelsQuotaSnapshot? {
        #if compiler(>=6.4) && canImport(FoundationModels) && !os(tvOS)
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *) {
            let usage = PrivateCloudComputeLanguageModel().quotaUsage
            var approaching = false
            if case .belowLimit(let below) = usage.status {
                approaching = below.isApproachingLimit
            }
            return FoundationModelsQuotaSnapshot(
                limitReached: usage.isLimitReached,
                approachingLimit: approaching,
                resetDate: usage.resetDate,
                canRequestIncrease: usage.limitIncreaseSuggestion != nil
            )
        }
        #endif
        return nil
    }

    /// Presents the system's Private Cloud Compute limit-increase offer when one is available.
    /// - Returns: `true` when an offer was shown.
    @MainActor
    @discardableResult
    public static func presentPrivateCloudQuotaIncreaseSuggestion() -> Bool {
        #if compiler(>=6.4) && canImport(FoundationModels) && !os(tvOS)
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *) {
            guard let suggestion = PrivateCloudComputeLanguageModel().quotaUsage.limitIncreaseSuggestion else {
                return false
            }
            suggestion.show()
            return true
        }
        #endif
        return false
    }

    // MARK: Token counting and prewarming

    /// Counts tokens of a prompt (and optional instructions) with the on-device model (OS 26.4+),
    /// for context budgeting and compaction.
    /// - Parameters:
    ///   - prompt: Prompt text.
    ///   - systemPrompt: Optional instructions.
    /// - Returns: Token count.
    /// - Throws: ``OpenClawCoreError/unavailable(_:)`` where token counting is unavailable.
    public func tokenCount(prompt: String, systemPrompt: String? = nil) async throws -> Int {
        #if canImport(FoundationModels) && !os(tvOS) && !os(watchOS) && compiler(>=6.4)
        if #available(iOS 26.4, macOS 26.4, visionOS 26.4, *), Self.runtimeAvailability(
            target: .system,
            treatSimulatorAsUnavailable: self.options.treatSimulatorAsUnavailable
        ).isAvailable {
            let model = AppleFMSystemModel.make(self.options)
            var total = try await model.tokenCount(for: prompt)
            if let systemPrompt, !systemPrompt.isEmpty {
                total += try await model.tokenCount(for: Instructions(systemPrompt))
            }
            return total
        }
        #endif
        throw OpenClawCoreError.unavailable("Token counting requires the on-device Apple Foundation Models system model on Apple OS 26.4 or later.")
    }

    /// Loads the on-device model ahead of the first request (`LanguageModelSession.prewarm(promptPrefix:)`).
    /// - Parameters:
    ///   - systemPrompt: Instructions of the upcoming session.
    ///   - promptPrefix: Known prefix of the upcoming prompt.
    public func prewarm(systemPrompt: String? = nil, promptPrefix: String? = nil) {
        #if canImport(FoundationModels) && !os(tvOS) && !os(watchOS)
        guard Self.runtimeAvailability(
            target: .system,
            treatSimulatorAsUnavailable: self.options.treatSimulatorAsUnavailable
        ).isAvailable else {
            return
        }
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            let session = LanguageModelSession(model: AppleFMSystemModel.make(self.options), instructions: systemPrompt)
            session.prewarm(promptPrefix: promptPrefix.map { Prompt($0) })
        }
        #else
        _ = (systemPrompt, promptPrefix)
        #endif
    }
}

// MARK: - Cancellation and streaming support

/// Token-keyed cancellation handlers for in-flight requests.
final class FoundationModelsCancellationRegistry: @unchecked Sendable {
    struct Registration: Sendable {
        let token: String?
        let id: UUID
    }

    private let lock = NSLock()
    private var handlers: [String: [UUID: @Sendable () -> Void]] = [:]

    func register(token: String?, cancel: @escaping @Sendable () -> Void) -> Registration {
        let registration = Registration(token: token, id: UUID())
        guard let token, !token.isEmpty else {
            return registration
        }
        self.lock.lock()
        self.handlers[token, default: [:]][registration.id] = cancel
        self.lock.unlock()
        return registration
    }

    func unregister(_ registration: Registration) {
        guard let token = registration.token else { return }
        self.lock.lock()
        self.handlers[token]?[registration.id] = nil
        if self.handlers[token]?.isEmpty == true {
            self.handlers[token] = nil
        }
        self.lock.unlock()
    }

    @discardableResult
    func cancel(token: String) -> Int {
        self.lock.lock()
        let cancels = self.handlers.removeValue(forKey: token).map { Array($0.values) } ?? []
        self.lock.unlock()
        cancels.forEach { $0() }
        return cancels.count
    }
}

/// Streams visible text deltas out of an engine run and remembers whether any were sent.
final class FoundationModelsTextSink: @unchecked Sendable {
    private let lock = NSLock()
    private var emitted = false
    private let yield: @Sendable (ModelStreamChunk) -> Void

    init(_ yield: @escaping @Sendable (ModelStreamChunk) -> Void) {
        self.yield = yield
    }

    /// Whether any text was streamed.
    var didEmit: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.emitted
    }

    func send(text delta: String) {
        guard !delta.isEmpty else { return }
        self.lock.lock()
        self.emitted = true
        self.lock.unlock()
        self.yield(ModelStreamChunk(kind: .text, text: delta))
    }
}
