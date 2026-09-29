import Foundation
import OpenClawCore

/// Configuration for ``FoundationModelsProvider``.
public struct FoundationModelsProviderOptions: Sendable {
    /// On-device model use case (the framework's system-model `UseCase`).
    public enum UseCase: String, Sendable, Equatable, CaseIterable, Codable {
        /// General-purpose prompting (default).
        case general
        /// Content tagging (topic and entity extraction).
        case contentTagging
    }

    /// On-device guardrail configuration (the framework's system-model `Guardrails`).
    public enum Guardrails: String, Sendable, Equatable, CaseIterable, Codable {
        /// Default guardrails.
        case standard = "default"
        /// Permissive guardrails for content transformations (for example summarizing user text).
        case permissiveContentTransformations
    }

    /// Backend used when a request carries no model identifier.
    public var defaultTarget: AppleFoundationModelTarget
    /// When a Private Cloud Compute request cannot run (unavailable, quota reached, network or
    /// service failure), retry on the on-device system model when it is available.
    public var fallbackToOnDevice: Bool
    /// On-device model use case.
    public var useCase: UseCase
    /// On-device guardrails.
    public var guardrails: Guardrails
    /// Report the simulator as ``FoundationModelsRuntimeAvailability/Reason/restrictedEnvironment``
    /// instead of probing the framework (the simulator cannot run Apple Intelligence).
    public var treatSimulatorAsUnavailable: Bool
    /// Include the response schema in the prompt for structured output (`includeSchemaInPrompt`).
    public var includeSchemaInPrompt: Bool
    /// Maximum response tokens when the request policy sets none (upstream default 1024).
    public var defaultMaxTokens: Int
    /// Call `LanguageModelSession.prewarm(promptPrefix:)` before each request's response.
    public var prewarm: Bool
    /// Host tool execution and native Apple tools.
    public var tools: FoundationModelsToolOptions

    /// Creates provider options.
    /// - Parameters:
    ///   - defaultTarget: Backend for requests without a model identifier.
    ///   - fallbackToOnDevice: Retry failed Private Cloud Compute requests on device.
    ///   - useCase: On-device model use case.
    ///   - guardrails: On-device guardrails.
    ///   - treatSimulatorAsUnavailable: Short-circuit availability in the simulator.
    ///   - includeSchemaInPrompt: Include response schemas in the prompt.
    ///   - defaultMaxTokens: Default maximum response tokens.
    ///   - prewarm: Prewarm sessions before responding.
    ///   - tools: Tool options.
    public init(
        defaultTarget: AppleFoundationModelTarget = .system,
        fallbackToOnDevice: Bool = true,
        useCase: UseCase = .general,
        guardrails: Guardrails = .standard,
        treatSimulatorAsUnavailable: Bool = true,
        includeSchemaInPrompt: Bool = true,
        defaultMaxTokens: Int = FoundationModelsProvider.defaultMaxTokens,
        prewarm: Bool = false,
        tools: FoundationModelsToolOptions = FoundationModelsToolOptions()
    ) {
        self.defaultTarget = defaultTarget
        self.fallbackToOnDevice = fallbackToOnDevice
        self.useCase = useCase
        self.guardrails = guardrails
        self.treatSimulatorAsUnavailable = treatSimulatorAsUnavailable
        self.includeSchemaInPrompt = includeSchemaInPrompt
        self.defaultMaxTokens = Swift.max(1, defaultMaxTokens)
        self.prewarm = prewarm
        self.tools = tools
    }
}

/// Output an in-process tool executor returns to the Foundation Models session.
public struct FoundationModelsToolOutput: Sendable, Equatable {
    /// Text handed back to the model.
    public var text: String
    /// Whether the tool failed (the text then describes the failure).
    public var isError: Bool

    /// Creates a tool output.
    /// - Parameters:
    ///   - text: Text for the model.
    ///   - isError: Whether the tool failed.
    public init(text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }
}

/// Executes host tool calls inside a Foundation Models session (in-process mode).
///
/// Only for embedded apps without an approval loop: the framework runs the tool while it is still
/// generating, so approval and policy must happen inside ``executeTool(_:)``. OpenClawAgents
/// provides `FoundationModelsAgentToolExecutor`, which routes calls through an `AgentToolRegistry`.
public protocol FoundationModelsToolExecuting: Sendable {
    /// Runs one tool call.
    /// - Parameter call: Tool call proposed by the model (`argumentsJSON` is a JSON object).
    /// - Returns: Output for the model.
    func executeTool(_ call: ModelToolCall) async throws -> FoundationModelsToolOutput
}

/// How ``FoundationModelsProvider`` treats ``ModelGenerationRequest/tools``.
public enum FoundationModelsToolExecutionMode: Sendable {
    /// Upstream parity (default): the first tool call stops generation and is returned as a
    /// proposed ``ModelToolCall`` with stop reason ``ModelStopReason/toolUse``; the host or agent loop
    /// approves and executes it and replays the result on the next request.
    case proposeOnly
    /// The framework executes tools through the executor while generating and the response carries
    /// the final text (see ``FoundationModelsProvider/generateDetailed(_:)`` for executed calls).
    case executeInProcess(any FoundationModelsToolExecuting)

    /// Whether this is ``proposeOnly``.
    public var isProposeOnly: Bool {
        if case .proposeOnly = self { return true }
        return false
    }
}

/// A tool call the framework executed in-process, with its output.
public struct FoundationModelsExecutedToolCall: Sendable, Equatable {
    /// The executed call.
    public var call: ModelToolCall
    /// Output returned to the model.
    public var output: FoundationModelsToolOutput

    /// Creates an executed-call record.
    /// - Parameters:
    ///   - call: The executed call.
    ///   - output: Output returned to the model.
    public init(call: ModelToolCall, output: FoundationModelsToolOutput) {
        self.call = call
        self.output = output
    }

    /// Transcript tool result for this call.
    public var modelToolResult: ModelToolResult {
        ModelToolResult(
            toolCallID: self.call.id,
            toolName: self.call.name,
            content: [.text(self.output.text)],
            isError: self.output.isError
        )
    }
}

/// Configuration for offering Core Spotlight search (the OS 27 Spotlight search tool) to Apple FM sessions.
///
/// The tool's description is roughly 5,000 characters of query-construction guidance, a large share
/// of the on-device model's 8,192-token window, so it is enabled for Private Cloud Compute sessions
/// and only offered to the on-device model when ``allowOnSystemModel`` is set.
public struct FoundationModelsSpotlightSearchOptions: Sendable {
    /// Maximum results per search (`CoreSpotlightSource.maximumResultCount`).
    public var maximumResultCount: Int
    /// Maximum tool response size in characters (the tool configuration's `maximumResponseSize`).
    public var maximumResponseSize: Int
    /// Also search files in these folders (`FileSource.scopes`; useful on macOS).
    public var fileScopes: [URL]
    /// Offer the tool to the on-device system model too (explicit opt-in because of its context cost).
    public var allowOnSystemModel: Bool
    /// Optional `CSSearchableIndexDelegate` that hydrates app-indexed items (for example the
    /// OpenClawMemory Spotlight index delegate). Must conform to `CSSearchableIndexDelegate`;
    /// other objects are ignored.
    public var searchableIndexDelegate: (any AnyObject & Sendable)?

    /// Creates Spotlight search options.
    /// - Parameters:
    ///   - maximumResultCount: Maximum results per search.
    ///   - maximumResponseSize: Maximum response size in characters.
    ///   - fileScopes: Folders to search in addition to Core Spotlight.
    ///   - allowOnSystemModel: Offer the tool to the on-device model.
    ///   - searchableIndexDelegate: Optional index delegate.
    public init(
        maximumResultCount: Int = 20,
        maximumResponseSize: Int = 8_000,
        fileScopes: [URL] = [],
        allowOnSystemModel: Bool = false,
        searchableIndexDelegate: (any AnyObject & Sendable)? = nil
    ) {
        self.maximumResultCount = Swift.max(1, maximumResultCount)
        self.maximumResponseSize = Swift.max(256, maximumResponseSize)
        self.fileScopes = fileScopes
        self.allowOnSystemModel = allowOnSystemModel
        self.searchableIndexDelegate = searchableIndexDelegate
    }
}

/// Tool configuration for ``FoundationModelsProvider``.
public struct FoundationModelsToolOptions: Sendable {
    /// How host tools from ``ModelGenerationRequest/tools`` run.
    public var execution: FoundationModelsToolExecutionMode
    /// Offer Vision's barcode-reader and OCR tools (OS 27) when the request carries images and
    /// the model can call tools. They run inside the session and never reach the host, and are only
    /// offered with `toolChoice: .auto` (a forced tool choice must be satisfied by a host tool).
    public var visionTools: Bool
    /// Offer the Spotlight search tool (OS 27, iOS/macOS/visionOS) when set; like the Vision tools it
    /// is only offered with `toolChoice: .auto`.
    public var spotlightSearch: FoundationModelsSpotlightSearchOptions?

    /// Creates tool options.
    /// - Parameters:
    ///   - execution: Host tool execution mode.
    ///   - visionTools: Offer Vision tools for image requests.
    ///   - spotlightSearch: Spotlight search configuration.
    public init(
        execution: FoundationModelsToolExecutionMode = .proposeOnly,
        visionTools: Bool = true,
        spotlightSearch: FoundationModelsSpotlightSearchOptions? = nil
    ) {
        self.execution = execution
        self.visionTools = visionTools
        self.spotlightSearch = spotlightSearch
    }
}

/// Detailed result of ``FoundationModelsProvider/generateDetailed(_:)``.
public struct FoundationModelsGenerationResult: Sendable, Equatable {
    /// The provider response.
    public var response: ModelGenerationResponse
    /// Backend that produced the response (after any on-device fallback).
    public var target: AppleFoundationModelTarget
    /// Tool calls the framework executed in-process (in-process mode only), in order.
    public var executedToolCalls: [FoundationModelsExecutedToolCall]
    /// Whether a Private Cloud Compute request fell back to the on-device model.
    public var fellBackToOnDevice: Bool

    /// Creates a detailed result.
    /// - Parameters:
    ///   - response: Provider response.
    ///   - target: Backend used.
    ///   - executedToolCalls: Executed in-process tool calls.
    ///   - fellBackToOnDevice: Whether the on-device fallback ran.
    public init(
        response: ModelGenerationResponse,
        target: AppleFoundationModelTarget,
        executedToolCalls: [FoundationModelsExecutedToolCall] = [],
        fellBackToOnDevice: Bool = false
    ) {
        self.response = response
        self.target = target
        self.executedToolCalls = executedToolCalls
        self.fellBackToOnDevice = fellBackToOnDevice
    }

    /// Transcript messages recording the executed calls (an assistant tool-call message followed by
    /// their results), so a loop can store the pairs without re-executing them.
    public var executedToolMessages: [ModelMessage] {
        guard !self.executedToolCalls.isEmpty else { return [] }
        return [.assistant(content: self.executedToolCalls.map { .toolCall($0.call) })]
            + self.executedToolCalls.map { .toolResult($0.modelToolResult) }
    }
}
