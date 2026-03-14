import Foundation
import OpenClawCore
import OpenClawGateway
import OpenClawMedia
import OpenClawModels
import OpenClawProtocol
import OpenClawSkills

/// Errors surfaced by the embedded agent runtime.
public enum AgentRuntimeError: Error, LocalizedError, Sendable {
    /// A requested tool name is not registered.
    case toolNotFound(String)
    /// A run exceeded the configured timeout window.
    case timedOut(runID: String)

    public var errorDescription: String? {
        switch self {
        case .toolNotFound(let name):
            return "Tool not found: \(name)"
        case .timedOut(let runID):
            return "Agent run timed out: \(runID)"
        }
    }
}

/// Timeline event emitted during agent run execution.
public struct AgentRunEvent: Sendable, Equatable {
    /// Event kinds emitted by a run.
    public enum Kind: String, Sendable {
        case runStarted
        case toolStarted
        case toolCompleted
        case runCompleted
    }

    public let runID: String
    public let kind: Kind
    public let toolName: String?

    /// Creates a run lifecycle event.
    /// - Parameters:
    ///   - runID: Correlated run identifier.
    ///   - kind: Event type.
    ///   - toolName: Optional tool associated with event.
    public init(runID: String, kind: Kind, toolName: String? = nil) {
        self.runID = runID
        self.kind = kind
        self.toolName = toolName
    }
}

/// Input payload for a single agent run.
public struct AgentRunRequest: Sendable {
    public let runID: String
    public let sessionKey: String
    public let prompt: String
    public let toolCalls: [AgentToolCall]
    public let modelProviderID: String?
    public let modelID: String?
    public let thinkingLevel: ThinkLevel?
    public let reasoningLevel: ReasoningLevel?
    public let verboseLevel: VerboseLevel?
    public let responseUsage: UsageDisplayLevel?
    public let elevatedLevel: ElevatedLevel?
    public let fastMode: Bool?
    public let workspaceRootPath: String?
    public let attachments: [MediaAttachment]

    /// Creates a run request.
    /// - Parameters:
    ///   - runID: Optional external run identifier.
    ///   - sessionKey: Session key used for routing/memory.
    ///   - prompt: User prompt payload.
    ///   - toolCalls: Ordered tool calls to execute before model generation.
    ///   - modelProviderID: Optional provider override.
    ///   - workspaceRootPath: Optional workspace root for skill/bootstrap prompt injection.
    ///   - attachments: Optional multimodal attachments to normalize and reference in prompt context.
    public init(
        runID: String = UUID().uuidString,
        sessionKey: String,
        prompt: String,
        toolCalls: [AgentToolCall] = [],
        modelProviderID: String? = nil,
        modelID: String? = nil,
        thinkingLevel: ThinkLevel? = nil,
        reasoningLevel: ReasoningLevel? = nil,
        verboseLevel: VerboseLevel? = nil,
        responseUsage: UsageDisplayLevel? = nil,
        elevatedLevel: ElevatedLevel? = nil,
        fastMode: Bool? = nil,
        workspaceRootPath: String? = nil,
        attachments: [MediaAttachment] = []
    ) {
        self.runID = runID
        self.sessionKey = sessionKey
        self.prompt = prompt
        self.toolCalls = toolCalls
        self.modelProviderID = modelProviderID
        self.modelID = modelID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.thinkingLevel = thinkingLevel
        self.reasoningLevel = reasoningLevel
        self.verboseLevel = verboseLevel
        self.responseUsage = responseUsage
        self.elevatedLevel = elevatedLevel
        self.fastMode = fastMode
        self.workspaceRootPath = workspaceRootPath
        self.attachments = attachments
    }
}

/// Output payload for a completed agent run.
public struct AgentRunResult: Sendable {
    public let runID: String
    public let sessionKey: String
    public let output: String
    public let toolResults: [AgentToolResult]
    public let events: [AgentRunEvent]
    public let attachments: [MediaAttachment]

    /// Creates a run result.
    /// - Parameters:
    ///   - runID: Run identifier.
    ///   - sessionKey: Session key resolved for the run.
    ///   - output: Model output text.
    ///   - toolResults: Tool execution outputs.
    ///   - events: Lifecycle events emitted during run.
    ///   - attachments: Normalized multimodal attachments used during prompt generation.
    public init(
        runID: String,
        sessionKey: String,
        output: String,
        toolResults: [AgentToolResult],
        events: [AgentRunEvent],
        attachments: [MediaAttachment] = []
    ) {
        self.runID = runID
        self.sessionKey = sessionKey
        self.output = output
        self.toolResults = toolResults
        self.events = events
        self.attachments = attachments
    }
}

/// Output payload for runs executed with an intent graph.
public struct IntentGraphRunResult: Sendable {
    /// Intent graph used to represent this run plan.
    public let graph: IntentGraph
    /// Completed run payload.
    public let result: AgentRunResult

    /// Creates an intent-graph run result.
    /// - Parameters:
    ///   - graph: Intent graph generated for the run.
    ///   - result: Completed run payload.
    public init(graph: IntentGraph, result: AgentRunResult) {
        self.graph = graph
        self.result = result
    }
}

/// Stream chunk emitted during a streaming agent run.
public struct AgentRunStreamChunk: Sendable, Equatable {
    /// Correlated run identifier.
    public let runID: String
    /// Session key for this run.
    public let sessionKey: String
    /// Incremental text payload.
    public let text: String
    /// Indicates whether this is the terminal stream chunk.
    public let isFinal: Bool

    /// Creates a stream chunk payload.
    /// - Parameters:
    ///   - runID: Correlated run identifier.
    ///   - sessionKey: Session key.
    ///   - text: Incremental text.
    ///   - isFinal: Terminal marker.
    public init(runID: String, sessionKey: String, text: String, isFinal: Bool) {
        self.runID = runID
        self.sessionKey = sessionKey
        self.text = text
        self.isFinal = isFinal
    }
}

/// Actor that orchestrates tool execution, gateway lifecycle, and model generation.
public actor EmbeddedAgentRuntime {
    private let gatewayClient: GatewayClient
    private let toolRegistry: AgentToolRegistry
    private let modelRouter: ModelRouter
    private let mediaPipeline: MediaPipeline
    private let diagnosticsSink: RuntimeDiagnosticSink?

    /// Creates an embedded runtime.
    /// - Parameters:
    ///   - gatewayClient: Gateway transport client.
    ///   - toolRegistry: Registry used to resolve tool calls.
    ///   - modelRouter: Router for model provider selection.
    ///   - mediaPipeline: Media pipeline used to normalize multimodal attachments.
    ///   - diagnosticsSink: Optional diagnostics event sink.
    public init(
        gatewayClient: GatewayClient = GatewayClient(),
        toolRegistry: AgentToolRegistry? = nil,
        modelRouter: ModelRouter = ModelRouter(),
        mediaPipeline: MediaPipeline = MediaPipeline(),
        diagnosticsSink: RuntimeDiagnosticSink? = nil
    ) {
        self.gatewayClient = gatewayClient
        self.modelRouter = modelRouter
        self.mediaPipeline = mediaPipeline
        self.diagnosticsSink = diagnosticsSink
        self.toolRegistry = toolRegistry ?? AgentToolRegistry(
            tools: [LLMTaskTool(modelRouter: modelRouter)]
        )
    }

    /// Registers a tool implementation for runtime use.
    /// - Parameter tool: Tool instance to register.
    public func registerTool(_ tool: any AgentTool) async {
        await self.toolRegistry.register(tool)
    }

    /// Registers a model provider for runtime routing.
    /// - Parameter provider: Provider implementation.
    public func registerModelProvider(_ provider: any ModelProvider) async {
        await self.modelRouter.register(provider)
    }

    /// Updates default model provider used when request does not specify one.
    /// - Parameter id: Registered provider identifier.
    public func setDefaultModelProviderID(_ id: String) async throws {
        try await self.modelRouter.setDefaultProviderID(id)
    }

    /// Executes an agent run with optional timeout protection.
    /// - Parameters:
    ///   - request: Run request payload.
    ///   - timeoutMs: Timeout in milliseconds.
    /// - Returns: Run result containing output, tool results, and lifecycle events.
    public func run(_ request: AgentRunRequest, timeoutMs: Int = 30_000) async throws -> AgentRunResult {
        struct RunExecution: Sendable {
            let result: AgentRunResult
            let providerID: String
            let modelID: String?
            let modelLatencyMs: Int
        }

        let runID = request.runID
        let timeoutNs = UInt64(max(0, timeoutMs)) * 1_000_000
        let runStartedAt = Date()

        await self.emitDiagnostic(
            name: "run.started",
            runID: runID,
            sessionKey: request.sessionKey,
            metadata: [
                "providerID": request.modelProviderID ?? "",
                "requestedProviderID": request.modelProviderID ?? "",
                "toolCallCount": String(request.toolCalls.count),
                "attachmentCount": String(request.attachments.count),
            ]
        )
        await self.emitDiagnostic(
            name: "model.call.started",
            runID: runID,
            sessionKey: request.sessionKey,
            metadata: [
                "providerID": request.modelProviderID ?? "",
                "requestedProviderID": request.modelProviderID ?? "",
                "attachmentCount": String(request.attachments.count),
            ]
        )

        do {
            let execution = try await withThrowingTaskGroup(of: RunExecution.self) { group in
                group.addTask { [gatewayClient, toolRegistry, modelRouter, mediaPipeline] in
                    var events: [AgentRunEvent] = [AgentRunEvent(runID: runID, kind: .runStarted)]
                    var toolResults: [AgentToolResult] = []
                    let normalizedAttachments = try await Self.normalizeAttachments(
                        request.attachments,
                        using: mediaPipeline
                    )
                    let composedPrompt = try await Self.composePrompt(
                        basePrompt: request.prompt,
                        workspaceRootPath: request.workspaceRootPath,
                        attachments: normalizedAttachments
                    )

                    if await gatewayClient.isConnected() == false {
                        try await gatewayClient.connect(
                            to: GatewayEndpoint(url: URL(string: "ws://127.0.0.1:18789")!)
                        )
                    }

                    for call in request.toolCalls {
                        events.append(AgentRunEvent(runID: runID, kind: .toolStarted, toolName: call.name))
                        let toolResult = try await toolRegistry.execute(call)
                        toolResults.append(toolResult)
                        events.append(AgentRunEvent(runID: runID, kind: .toolCompleted, toolName: call.name))
                    }

                    _ = try await gatewayClient.send(method: "agent.run", params: [
                        "sessionKey": AnyCodable(request.sessionKey),
                        "prompt": AnyCodable(composedPrompt),
                    ])

                    let modelStartedAt = Date()
                    let modelResponse = try await modelRouter.generate(
                        Self.makeModelGenerationRequest(
                            from: request,
                            prompt: composedPrompt
                        )
                    )
                    let modelLatencyMs = max(0, Int(Date().timeIntervalSince(modelStartedAt) * 1000))

                    events.append(AgentRunEvent(runID: runID, kind: .runCompleted))
                    let sanitizedOutput = ProviderVisibleTextSanitizer.sanitizeVisibleText(modelResponse.text)
                    let result = AgentRunResult(
                        runID: runID,
                        sessionKey: request.sessionKey,
                        output: sanitizedOutput,
                        toolResults: toolResults,
                        events: events,
                        attachments: normalizedAttachments
                    )
                    return RunExecution(
                        result: result,
                        providerID: modelResponse.providerID,
                        modelID: modelResponse.modelID,
                        modelLatencyMs: modelLatencyMs
                    )
                }

                group.addTask {
                    try await Task.sleep(nanoseconds: timeoutNs)
                    throw AgentRuntimeError.timedOut(runID: runID)
                }

                guard let result = try await group.next() else {
                    throw AgentRuntimeError.timedOut(runID: runID)
                }
                group.cancelAll()
                return result
            }

            await self.emitDiagnostic(
                name: "model.call.completed",
                runID: runID,
                sessionKey: request.sessionKey,
                metadata: [
                    "providerID": execution.providerID,
                    "modelID": execution.modelID ?? "",
                    "latencyMs": String(execution.modelLatencyMs),
                    "attachmentCount": String(execution.result.attachments.count),
                ]
            )
            let runLatencyMs = max(0, Int(Date().timeIntervalSince(runStartedAt) * 1000))
            await self.emitDiagnostic(
                name: "run.completed",
                runID: runID,
                sessionKey: request.sessionKey,
                metadata: [
                    "latencyMs": String(runLatencyMs),
                    "providerID": execution.providerID,
                    "modelID": execution.modelID ?? "",
                    "outputLength": String(execution.result.output.count),
                    "attachmentCount": String(execution.result.attachments.count),
                ]
            )
            return execution.result
        } catch {
            let timedOut: Bool
            if case AgentRuntimeError.timedOut = error {
                timedOut = true
            } else {
                timedOut = false
            }
            let runLatencyMs = max(0, Int(Date().timeIntervalSince(runStartedAt) * 1000))
            await self.emitDiagnostic(
                name: "model.call.failed",
                runID: runID,
                sessionKey: request.sessionKey,
                metadata: [
                    "providerID": request.modelProviderID ?? "",
                    "requestedProviderID": request.modelProviderID ?? "",
                    "error": String(describing: error),
                    "timedOut": String(timedOut),
                    "attachmentCount": String(request.attachments.count),
                ]
            )
            await self.emitDiagnostic(
                name: "run.failed",
                runID: runID,
                sessionKey: request.sessionKey,
                metadata: [
                    "latencyMs": String(runLatencyMs),
                    "providerID": request.modelProviderID ?? "",
                    "requestedProviderID": request.modelProviderID ?? "",
                    "timedOut": String(timedOut),
                    "error": String(describing: error),
                    "attachmentCount": String(request.attachments.count),
                ]
            )
            throw error
        }
    }

    /// Builds an intent graph for a run request without executing the run.
    /// - Parameter request: Run request payload.
    /// - Returns: Deterministic intent graph representation.
    public func makeIntentGraph(for request: AgentRunRequest) -> IntentGraph {
        var nodes: [IntentGraphNode] = []
        var edges: [IntentGraphEdge] = []

        let runNodeID = "run:\(request.runID)"
        let promptNodeID = "prompt:\(request.runID)"
        let modelNodeID = "model:\(request.runID)"
        let outputNodeID = "output:\(request.runID)"

        nodes.append(
            IntentGraphNode(
                id: runNodeID,
                kind: .run,
                title: "Agent Run",
                metadata: [
                    "runID": request.runID,
                    "sessionKey": request.sessionKey,
                    "requestedProviderID": request.modelProviderID ?? "",
                ]
            )
        )
        nodes.append(
            IntentGraphNode(
                id: promptNodeID,
                kind: .prompt,
                title: "Prompt",
                metadata: [
                    "length": String(request.prompt.count),
                    "hasWorkspaceRoot": String(request.workspaceRootPath != nil),
                    "attachmentCount": String(request.attachments.count),
                ]
            )
        )
        nodes.append(
            IntentGraphNode(
                id: modelNodeID,
                kind: .model,
                title: "Model Route",
                metadata: [
                    "requestedProviderID": request.modelProviderID ?? "",
                ]
            )
        )
        nodes.append(
            IntentGraphNode(
                id: outputNodeID,
                kind: .output,
                title: "Output",
                metadata: [
                    "toolCallCount": String(request.toolCalls.count),
                ]
            )
        )

        edges.append(IntentGraphEdge(sourceID: runNodeID, targetID: promptNodeID, kind: .initiates))
        edges.append(IntentGraphEdge(sourceID: promptNodeID, targetID: modelNodeID, kind: .feeds))
        edges.append(IntentGraphEdge(sourceID: modelNodeID, targetID: outputNodeID, kind: .produces))

        if let workspaceRootPath = request.workspaceRootPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !workspaceRootPath.isEmpty
        {
            let skillNodeID = "skill:\(request.runID)"
            nodes.append(
                IntentGraphNode(
                    id: skillNodeID,
                    kind: .skill,
                    title: "Workspace Skills",
                    metadata: ["workspaceRootPath": workspaceRootPath]
                )
            )
            edges.append(IntentGraphEdge(sourceID: runNodeID, targetID: skillNodeID, kind: .reads))
            edges.append(IntentGraphEdge(sourceID: skillNodeID, targetID: modelNodeID, kind: .feeds))
        }

        for (index, call) in request.toolCalls.enumerated() {
            let toolNodeID = "tool:\(request.runID):\(index)"
            nodes.append(
                IntentGraphNode(
                    id: toolNodeID,
                    kind: .tool,
                    title: call.name,
                    metadata: [
                        "order": String(index),
                        "argumentCount": String(call.arguments.count),
                    ]
                )
            )
            edges.append(IntentGraphEdge(sourceID: runNodeID, targetID: toolNodeID, kind: .invokes))
            edges.append(IntentGraphEdge(sourceID: toolNodeID, targetID: modelNodeID, kind: .feeds))
        }

        let sortedNodes = nodes.sorted(by: { $0.id < $1.id })
        let sortedEdges = edges.sorted {
            if $0.sourceID != $1.sourceID {
                return $0.sourceID < $1.sourceID
            }
            if $0.targetID != $1.targetID {
                return $0.targetID < $1.targetID
            }
            return $0.kind.rawValue < $1.kind.rawValue
        }
        return IntentGraph(
            runID: request.runID,
            sessionKey: request.sessionKey,
            nodes: sortedNodes,
            edges: sortedEdges
        )
    }

    /// Executes a run request and returns both execution result and intent graph.
    /// - Parameters:
    ///   - request: Run request payload.
    ///   - timeoutMs: Timeout in milliseconds.
    /// - Returns: Combined graph + run result payload.
    public func runIntentGraph(
        _ request: AgentRunRequest,
        timeoutMs: Int = 30_000
    ) async throws -> IntentGraphRunResult {
        let graph = self.makeIntentGraph(for: request)
        let result = try await self.run(request, timeoutMs: timeoutMs)
        return IntentGraphRunResult(graph: graph, result: result)
    }

    /// Executes an agent run and streams incremental model output chunks.
    /// - Parameters:
    ///   - request: Run request payload.
    ///   - timeoutMs: Timeout hint propagated to model providers.
    /// - Returns: Stream of output chunks for progressive rendering.
    public func runStream(
        _ request: AgentRunRequest,
        timeoutMs: Int = 30_000
    ) -> AsyncThrowingStream<AgentRunStreamChunk, Error> {
        let timeoutMs = max(1, timeoutMs)
        return AsyncThrowingStream { continuation in
            Task {
                let runID = request.runID
                let runStartedAt = Date()
                do {
                    await self.emitDiagnostic(
                        name: "run.started",
                        runID: runID,
                        sessionKey: request.sessionKey,
                        metadata: [
                            "providerID": request.modelProviderID ?? "",
                            "requestedProviderID": request.modelProviderID ?? "",
                            "toolCallCount": String(request.toolCalls.count),
                            "attachmentCount": String(request.attachments.count),
                            "streaming": "true",
                        ]
                    )
                    await self.emitDiagnostic(
                        name: "model.call.started",
                        runID: runID,
                        sessionKey: request.sessionKey,
                        metadata: [
                            "providerID": request.modelProviderID ?? "",
                            "requestedProviderID": request.modelProviderID ?? "",
                            "attachmentCount": String(request.attachments.count),
                            "streaming": "true",
                        ]
                    )

                    let normalizedAttachments = try await Self.normalizeAttachments(
                        request.attachments,
                        using: self.mediaPipeline
                    )
                    let composedPrompt = try await Self.composePrompt(
                        basePrompt: request.prompt,
                        workspaceRootPath: request.workspaceRootPath,
                        attachments: normalizedAttachments
                    )

                    if await self.gatewayClient.isConnected() == false {
                        try await self.gatewayClient.connect(
                            to: GatewayEndpoint(url: URL(string: "ws://127.0.0.1:18789")!)
                        )
                    }

                    for call in request.toolCalls {
                        _ = try await self.toolRegistry.execute(call)
                    }

                    _ = try await self.gatewayClient.send(method: "agent.run", params: [
                        "sessionKey": AnyCodable(request.sessionKey),
                        "prompt": AnyCodable(composedPrompt),
                    ])

                    let modelStartedAt = Date()
                    let modelStream = await self.modelRouter.generateStream(
                        Self.makeModelGenerationRequest(
                            from: request,
                            prompt: composedPrompt,
                            streamTokens: true,
                            timeoutMs: timeoutMs
                        )
                    )

                    var output = ""
                    var sanitizedOutput = ""
                    var sawFinal = false
                    for try await chunk in modelStream {
                        if Task.isCancelled {
                            throw CancellationError()
                        }
                        output += chunk.text
                        if chunk.isFinal {
                            sawFinal = true
                        }
                        let sanitizedCandidate = ProviderVisibleTextSanitizer.sanitizeVisibleText(output)
                        let delta = Self.visibleStreamDelta(previous: sanitizedOutput, current: sanitizedCandidate)
                        sanitizedOutput = sanitizedCandidate
                        if delta.isEmpty, chunk.isFinal == false {
                            continue
                        }
                        continuation.yield(
                            AgentRunStreamChunk(
                                runID: runID,
                                sessionKey: request.sessionKey,
                                text: delta,
                                isFinal: chunk.isFinal
                            )
                        )
                    }
                    if !sawFinal {
                        continuation.yield(
                            AgentRunStreamChunk(
                                runID: runID,
                                sessionKey: request.sessionKey,
                                text: "",
                                isFinal: true
                            )
                        )
                    }

                    let modelLatencyMs = max(0, Int(Date().timeIntervalSince(modelStartedAt) * 1000))
                    await self.emitDiagnostic(
                        name: "model.call.completed",
                        runID: runID,
                        sessionKey: request.sessionKey,
                        metadata: [
                            "providerID": request.modelProviderID ?? "",
                            "modelID": "",
                            "latencyMs": String(modelLatencyMs),
                            "attachmentCount": String(normalizedAttachments.count),
                            "streaming": "true",
                        ]
                    )
                    let runLatencyMs = max(0, Int(Date().timeIntervalSince(runStartedAt) * 1000))
                    await self.emitDiagnostic(
                        name: "run.completed",
                        runID: runID,
                        sessionKey: request.sessionKey,
                        metadata: [
                            "latencyMs": String(runLatencyMs),
                            "providerID": request.modelProviderID ?? "",
                            "modelID": "",
                            "outputLength": String(output.count),
                            "attachmentCount": String(normalizedAttachments.count),
                            "streaming": "true",
                        ]
                    )
                    continuation.finish()
                } catch {
                    let timedOut = String(describing: error).lowercased().contains("timed out")
                    let runLatencyMs = max(0, Int(Date().timeIntervalSince(runStartedAt) * 1000))
                    await self.emitDiagnostic(
                        name: "model.call.failed",
                        runID: runID,
                        sessionKey: request.sessionKey,
                        metadata: [
                            "providerID": request.modelProviderID ?? "",
                            "requestedProviderID": request.modelProviderID ?? "",
                            "error": String(describing: error),
                            "timedOut": String(timedOut),
                            "attachmentCount": String(request.attachments.count),
                            "streaming": "true",
                        ]
                    )
                    await self.emitDiagnostic(
                        name: "run.failed",
                        runID: runID,
                        sessionKey: request.sessionKey,
                        metadata: [
                            "latencyMs": String(runLatencyMs),
                            "providerID": request.modelProviderID ?? "",
                            "requestedProviderID": request.modelProviderID ?? "",
                            "timedOut": String(timedOut),
                            "error": String(describing: error),
                            "attachmentCount": String(request.attachments.count),
                            "streaming": "true",
                        ]
                    )
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private static func visibleStreamDelta(previous: String, current: String) -> String {
        let sharedPrefixLength = zip(previous, current)
            .prefix { lhs, rhs in lhs == rhs }
            .count
        return String(current.dropFirst(sharedPrefixLength))
    }

    /// Builds the final prompt by combining bootstrap context, skills, and user text.
    /// - Parameters:
    ///   - basePrompt: Original user prompt.
    ///   - workspaceRootPath: Optional workspace path containing bootstrap/skills.
    ///   - attachments: Optional normalized multimodal attachments.
    /// - Returns: Prompt sent to model provider.
    private static func composePrompt(
        basePrompt: String,
        workspaceRootPath: String?,
        attachments: [MediaAttachment] = []
    ) async throws -> String {
        var sections: [String] = []
        if let workspaceRootPath {
            let trimmed = workspaceRootPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let registry = SkillRegistry(workspaceRoot: URL(fileURLWithPath: trimmed))
                let snapshot = try await registry.loadPromptSnapshot()
                let bootstrap = try await BootstrapContextLoader(
                    workspaceRoot: URL(fileURLWithPath: trimmed)
                ).loadPromptSnapshot()
                let skillsPrompt = snapshot.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                let bootstrapPrompt = bootstrap.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !bootstrapPrompt.isEmpty {
                    sections.append(bootstrapPrompt)
                }
                if !skillsPrompt.isEmpty {
                    sections.append(skillsPrompt)
                }
            }
        }
        if !attachments.isEmpty {
            sections.append(Self.composeAttachmentSection(attachments))
        }
        if sections.isEmpty {
            return basePrompt
        }

        sections.append("## User Request")
        sections.append(basePrompt)
        return sections.joined(separator: "\n\n")
    }

    private static func normalizeAttachments(
        _ attachments: [MediaAttachment],
        using mediaPipeline: MediaPipeline
    ) async throws -> [MediaAttachment] {
        guard !attachments.isEmpty else {
            return []
        }
        var normalized: [MediaAttachment] = []
        normalized.reserveCapacity(attachments.count)
        for attachment in attachments {
            let prepared = try await mediaPipeline.prepare(attachment)
            normalized.append(prepared.attachment)
        }
        return normalized
    }

    private static func makeModelGenerationRequest(
        from request: AgentRunRequest,
        prompt: String,
        streamTokens: Bool = false,
        timeoutMs: Int? = nil
    ) -> ModelGenerationRequest {
        ModelGenerationRequest(
            sessionKey: request.sessionKey,
            prompt: prompt,
            providerID: request.modelProviderID,
            modelID: request.modelID,
            metadata: Self.modelControlMetadata(from: request),
            policy: ModelGenerationPolicy(
                streamTokens: streamTokens,
                requestTimeoutMs: timeoutMs,
                reasoningEffort: Self.reasoningEffort(
                    from: request.thinkingLevel,
                    reasoningLevel: request.reasoningLevel
                ),
                fastMode: request.fastMode,
                thinkingLevel: request.thinkingLevel,
                reasoningLevel: request.reasoningLevel,
                verboseLevel: request.verboseLevel,
                responseUsage: request.responseUsage,
                elevatedLevel: request.elevatedLevel
            )
        )
    }

    private static func reasoningEffort(
        from thinkingLevel: ThinkLevel?,
        reasoningLevel: ReasoningLevel?
    ) -> ModelReasoningEffort? {
        if reasoningLevel == .off {
            return nil
        }
        switch thinkingLevel {
        case .minimal, .low:
            return .low
        case .medium:
            return .medium
        case .high, .xhigh:
            return .high
        case .off, .adaptive, nil:
            return nil
        }
    }

    private static func modelControlMetadata(from request: AgentRunRequest) -> [String: String] {
        var metadata: [String: String] = [:]
        if let thinkingLevel = request.thinkingLevel {
            metadata["thinkingLevel"] = thinkingLevel.rawValue
        }
        if let reasoningLevel = request.reasoningLevel {
            metadata["reasoningLevel"] = reasoningLevel.rawValue
        }
        if let verboseLevel = request.verboseLevel {
            metadata["verboseLevel"] = verboseLevel.rawValue
        }
        if let responseUsage = request.responseUsage {
            metadata["responseUsage"] = responseUsage.rawValue
        }
        if let elevatedLevel = request.elevatedLevel {
            metadata["elevatedLevel"] = elevatedLevel.rawValue
        }
        return metadata
    }

    private static func composeAttachmentSection(_ attachments: [MediaAttachment]) -> String {
        var lines: [String] = ["## Attachments"]
        lines.reserveCapacity(attachments.count + 1)
        for attachment in attachments {
            let trimmedName = attachment.fileName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let displayName: String
            if trimmedName.isEmpty {
                displayName = "attachment-\(attachment.id.uuidString.prefix(8))"
            } else {
                displayName = trimmedName
            }
            let kind = attachment.metadata["kind"] ?? "unknown"
            lines.append(
                "- \(displayName) (\(attachment.mimeType), kind=\(kind), bytes=\(attachment.byteCount))"
            )
        }
        return lines.joined(separator: "\n")
    }

    private func emitDiagnostic(
        name: String,
        runID: String?,
        sessionKey: String?,
        metadata: [String: String] = [:]
    ) async {
        guard let diagnosticsSink else { return }
        await diagnosticsSink(
            RuntimeDiagnosticEvent(
                subsystem: "runtime",
                name: name,
                runID: runID,
                sessionKey: sessionKey,
                metadata: metadata
            )
        )
    }
}
