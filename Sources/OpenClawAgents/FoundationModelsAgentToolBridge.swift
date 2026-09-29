import Foundation
import OpenClawCore
import OpenClawModels
import OpenClawProtocol

// Bridges OpenClaw agent tools into Apple Foundation Models.
//
// - ``FoundationModelsAgentToolExecutor`` (all platforms): runs model-proposed calls through an
//   ``AgentToolRegistry`` for ``FoundationModelsToolExecutionMode/executeInProcess(_:)``.
// - `FoundationModelsAgentToolAdapter` (iOS/macOS/visionOS 26+, watchOS 27+): an `AgentTool` as a
//   FoundationModels `Tool`, with a `GenerationSchema` converted from the tool's JSON Schema
//   (strict upstream rules first, then a sanitized schema; tools that still fail are skipped and
//   reported).
// - `OpenClawAgentProfile` (OS 27): a `LanguageModelSession.DynamicProfile` built from agent
//   configuration (instructions, bridged tools, on-device or Private Cloud Compute routing, history
//   compaction, tool hooks).
//
// Tools bridged this way run inside the framework loop. The default OpenClaw path stays host-owned:
// ``FoundationModelsProvider`` proposes tool calls and the agent loop approves and executes them.
// Sessions built with `FoundationModelsAgentSession` run every call through a
// ``FoundationModelsAgentToolGate`` (policy, schema, `before_tool_call` hooks, approvals); the raw
// registry adapters and ``FoundationModelsAgentToolExecutor/init(registry:context:)`` do not.

/// Runs Foundation Models tool calls through an ``AgentToolRegistry`` (in-process mode).
///
/// Unknown tools and tool failures become error outputs the model can react to; only cancellation
/// propagates. Pair it with ``FoundationModelsProvider`` via
/// `FoundationModelsProviderOptions(tools: .init(execution: .executeInProcess(executor)))` for embedded
/// apps without an approval loop. ``init(registry:context:)`` runs tools directly, without
/// `before_tool_call` hooks or approvals; to apply them, pass a ``FoundationModelsAgentToolGate``:
/// `FoundationModelsAgentToolExecutor(invoke: gate.invoke)`.
public struct FoundationModelsAgentToolExecutor: FoundationModelsToolExecuting {
    private let invoke: @Sendable (AgentToolCall) async throws -> AgentToolResult

    /// Creates an executor over a registry.
    /// - Parameters:
    ///   - registry: Tool registry.
    ///   - context: Run context passed to each invocation.
    public init(registry: AgentToolRegistry, context: AgentToolInvocationContext = AgentToolInvocationContext()) {
        self.invoke = { call in
            try await registry.invoke(call, context: context)
        }
    }

    /// Creates an executor over a custom invocation path (for example one that applies hooks,
    /// policy and approvals before calling the registry).
    /// - Parameter invoke: Runs one call.
    public init(invoke: @escaping @Sendable (AgentToolCall) async throws -> AgentToolResult) {
        self.invoke = invoke
    }

    /// Runs one call.
    /// - Parameter call: Model-proposed call.
    /// - Returns: Text output for the model.
    public func executeTool(_ call: ModelToolCall) async throws -> FoundationModelsToolOutput {
        let result = try await self.invoke(AgentToolCall(call))
        return FoundationModelsToolOutput(text: result.output.text, isError: result.isError)
    }
}

/// An agent tool that could not be offered to a Foundation Models session.
public struct FoundationModelsSkippedTool: Sendable, Equatable {
    /// Tool name.
    public var name: String
    /// Why the tool was skipped (schema conversion error).
    public var reason: String

    /// Creates a skipped-tool notice.
    /// - Parameters:
    ///   - name: Tool name.
    ///   - reason: Skip reason.
    public init(name: String, reason: String) {
        self.name = name
        self.reason = reason
    }
}

public extension AgentToolDescriptor {
    /// Parameter schema usable with Foundation Models: the declared schema when it converts under the
    /// strict upstream rules, else the sanitized schema (see ``FoundationModelsSchemaConverter/sanitize(_:path:)``).
    /// - Returns: Schema and notices describing any rewrites.
    /// - Throws: ``FoundationModelsError`` when even the sanitized schema cannot be converted.
    func foundationModelsParameters() throws -> (schema: [String: AnyCodable], notices: [String]) {
        if FoundationModelsSchemaConverter.canConvert(self.parameters, name: self.name) {
            return (self.parameters, [])
        }
        let sanitized = FoundationModelsSchemaConverter.sanitize(self.parameters, path: self.name)
        _ = try FoundationModelsSchemaConverter.parse(sanitized.schema, name: self.name)
        return sanitized
    }
}

#if canImport(FoundationModels) && !os(tvOS) && (!os(watchOS) || compiler(>=6.4))
import FoundationModels

/// An OpenClaw ``AgentTool`` exposed as a Foundation Models `Tool`.
///
/// `call(arguments:)` decodes the generated JSON arguments, runs the tool through ``AgentTool/invoke(_:update:)``
/// (or a custom invocation path that applies hooks and approvals), and returns the output text.
/// Failed tools return `Tool error: <message>` so the model can recover.
@available(iOS 26.0, macOS 26.0, visionOS 26.0, watchOS 27.0, *)
public struct FoundationModelsAgentToolAdapter: Tool {
    /// Framework argument type: the raw generated content.
    public typealias Arguments = GeneratedContent
    /// Framework output type: text handed back to the model.
    public typealias Output = String

    /// Tool name.
    public let name: String
    /// Tool description.
    public let description: String
    /// Converted parameter schema.
    public let parameters: GenerationSchema
    /// Bridged tool descriptor.
    public let descriptor: AgentToolDescriptor
    /// Schema rewrites applied during conversion (empty when the declared schema converted as-is).
    public let schemaNotices: [String]
    private let invoke: @Sendable (AgentToolCall) async throws -> AgentToolResult

    /// Bridges a tool.
    /// - Parameters:
    ///   - tool: Agent tool.
    ///   - context: Run context passed to each invocation.
    /// - Throws: ``FoundationModelsError`` when the parameter schema cannot be converted.
    public init(tool: any AgentTool, context: AgentToolInvocationContext = AgentToolInvocationContext()) throws {
        try self.init(descriptor: tool.descriptor) { call in
            let invocation = AgentToolInvocation(toolCallID: call.id ?? AgentToolCall.makeID(), arguments: call.arguments, context: context)
            do {
                let output = try await tool.invoke(invocation, update: nil)
                return AgentToolResult(name: call.name, toolCallID: invocation.toolCallID, output: output)
            } catch let error as CancellationError {
                throw error
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                return AgentToolResult(name: call.name, toolCallID: invocation.toolCallID, output: .error(message))
            }
        }
    }

    /// Bridges a descriptor with a custom invocation path.
    /// - Parameters:
    ///   - descriptor: Tool descriptor.
    ///   - invoke: Runs one call (for example `registry.invoke(_:context:)` behind hooks and approvals).
    /// - Throws: ``FoundationModelsError`` when the parameter schema cannot be converted.
    public init(
        descriptor: AgentToolDescriptor,
        invoke: @escaping @Sendable (AgentToolCall) async throws -> AgentToolResult
    ) throws {
        let (schema, notices) = try descriptor.foundationModelsParameters()
        self.name = descriptor.name
        self.description = descriptor.description.isEmpty ? (descriptor.displaySummary ?? descriptor.label) : descriptor.description
        self.parameters = try FoundationModelsSchemaConverter.generationSchema(schema, name: descriptor.name)
        self.descriptor = descriptor
        self.schemaNotices = notices
        self.invoke = invoke
    }

    /// Runs the tool.
    /// - Parameter arguments: Generated arguments.
    /// - Returns: Output text for the model.
    public func call(arguments: GeneratedContent) async throws -> String {
        let call = ModelToolCall(id: AgentToolCall.makeID(), name: self.name, argumentsJSON: arguments.jsonString)
        let result = try await self.invoke(AgentToolCall(call))
        return result.isError ? "Tool error: \(result.output.text)" : result.output.text
    }
}

/// Builds Foundation Models tools from agent tools.
@available(iOS 26.0, macOS 26.0, visionOS 26.0, watchOS 27.0, *)
public enum FoundationModelsAgentTools {
    /// Bridges every tool in a registry; tools whose schemas cannot be converted are skipped.
    /// - Parameters:
    ///   - registry: Tool registry.
    ///   - context: Run context passed to each invocation.
    ///   - names: Optional allowlist of tool names.
    ///   - invoke: Invocation path for every bridged call. `nil` calls `registry.invoke(_:context:)`
    ///     directly, without `before_tool_call` hooks or approvals; pass
    ///     ``FoundationModelsAgentToolGate/invoke(_:)`` to apply them.
    /// - Returns: Bridged tools (sorted by name) and skipped tools.
    public static func adapters(
        for registry: AgentToolRegistry,
        context: AgentToolInvocationContext = AgentToolInvocationContext(),
        names: Set<String>? = nil,
        invoke: (@Sendable (AgentToolCall) async throws -> AgentToolResult)? = nil
    ) async -> (tools: [FoundationModelsAgentToolAdapter], skipped: [FoundationModelsSkippedTool]) {
        var tools: [FoundationModelsAgentToolAdapter] = []
        var skipped: [FoundationModelsSkippedTool] = []
        let run: @Sendable (AgentToolCall) async throws -> AgentToolResult = invoke ?? { call in
            try await registry.invoke(call, context: context)
        }
        for descriptor in await registry.descriptors() where names?.contains(descriptor.name) ?? true {
            do {
                tools.append(try FoundationModelsAgentToolAdapter(descriptor: descriptor, invoke: run))
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                skipped.append(FoundationModelsSkippedTool(name: descriptor.name, reason: reason))
            }
        }
        return (tools, skipped)
    }

    /// Bridges a list of tools; tools whose schemas cannot be converted are skipped.
    /// - Parameters:
    ///   - tools: Agent tools.
    ///   - context: Run context passed to each invocation.
    /// - Returns: Bridged and skipped tools.
    public static func adapters(
        for tools: [any AgentTool],
        context: AgentToolInvocationContext = AgentToolInvocationContext()
    ) -> (tools: [FoundationModelsAgentToolAdapter], skipped: [FoundationModelsSkippedTool]) {
        var bridged: [FoundationModelsAgentToolAdapter] = []
        var skipped: [FoundationModelsSkippedTool] = []
        for tool in tools {
            do {
                bridged.append(try FoundationModelsAgentToolAdapter(tool: tool, context: context))
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                skipped.append(FoundationModelsSkippedTool(name: tool.name, reason: reason))
            }
        }
        return (bridged, skipped)
    }
}

#if compiler(>=6.4)
/// Dynamic Foundation Models profile built from OpenClaw agent configuration (OS 27).
///
/// Instructions and bridged tools are re-evaluated each turn; the model is Private Cloud Compute or
/// the on-device system model; history is compacted to the instructions plus the most recent
/// entries; tool calls and outputs are reported to optional hooks. The on-device model does not
/// exist on watchOS, so watchOS profiles always use Private Cloud Compute.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
public struct OpenClawAgentProfile: LanguageModelSession.DynamicProfile {
    /// Model routing for the profile.
    public enum Route: String, Sendable, Equatable, CaseIterable {
        /// On-device system model (Private Cloud Compute on watchOS).
        case onDevice
        /// Private Cloud Compute.
        case privateCloud
        /// Private Cloud Compute when available, else on device.
        case auto
    }

    /// Instructions (bootstrap and skills context).
    public var systemPrompt: String
    /// Tools offered to the session (for example bridged agent tools).
    public var tools: [any Tool]
    /// Model routing.
    public var route: Route
    /// History entries kept besides instructions.
    public var maxHistoryEntries: Int
    /// Maximum response tokens.
    public var maximumResponseTokens: Int
    /// Reasoning level for Private Cloud Compute.
    public var reasoningLevel: ContextOptions.ReasoningLevel?
    /// Called when the model calls a tool.
    public var onToolCall: (@Sendable (Transcript.ToolCall) async -> Void)?
    /// Called when a tool output is recorded.
    public var onToolOutput: (@Sendable (Transcript.ToolCall, Transcript.ToolOutput) async -> Void)?

    /// Creates a profile.
    /// - Parameters:
    ///   - systemPrompt: Instructions.
    ///   - tools: Tools for the session.
    ///   - route: Model routing.
    ///   - maxHistoryEntries: History entries kept besides instructions.
    ///   - maximumResponseTokens: Maximum response tokens.
    ///   - reasoningLevel: Reasoning level for Private Cloud Compute.
    ///   - onToolCall: Tool-call hook.
    ///   - onToolOutput: Tool-output hook.
    public init(
        systemPrompt: String,
        tools: [any Tool] = [],
        route: Route = .onDevice,
        maxHistoryEntries: Int = 40,
        maximumResponseTokens: Int = FoundationModelsProvider.defaultMaxTokens,
        reasoningLevel: ContextOptions.ReasoningLevel? = nil,
        onToolCall: (@Sendable (Transcript.ToolCall) async -> Void)? = nil,
        onToolOutput: (@Sendable (Transcript.ToolCall, Transcript.ToolOutput) async -> Void)? = nil
    ) {
        self.systemPrompt = systemPrompt
        self.tools = tools
        self.route = route
        self.maxHistoryEntries = Swift.max(1, maxHistoryEntries)
        self.maximumResponseTokens = Swift.max(1, maximumResponseTokens)
        self.reasoningLevel = reasoningLevel
        self.onToolCall = onToolCall
        self.onToolOutput = onToolOutput
    }

    /// Whether the profile resolves to Private Cloud Compute.
    public var usesPrivateCloudCompute: Bool {
        #if os(watchOS)
        return true
        #else
        switch self.route {
        case .onDevice:
            return false
        case .privateCloud:
            return true
        case .auto:
            return PrivateCloudComputeLanguageModel().isAvailable
        }
        #endif
    }

    /// Profile body.
    public var body: some LanguageModelSession.DynamicProfile {
        let keep = self.maxHistoryEntries
        let onToolCall = self.onToolCall
        let onToolOutput = self.onToolOutput
        if self.usesPrivateCloudCompute {
            LanguageModelSession.Profile {
                Instructions(self.systemPrompt)
                self.tools
            }
            .model(PrivateCloudComputeLanguageModel())
            .reasoningLevel(self.reasoningLevel)
            .maximumResponseTokens(self.maximumResponseTokens)
            .historyTransform { Self.compact($0, keep: keep) }
            .transcriptErrorHandlingPolicy(.revertTranscript)
            .onToolCall { call in await onToolCall?(call) }
            .onToolOutput { call, output in await onToolOutput?(call, output) }
        } else {
            LanguageModelSession.Profile {
                Instructions(self.systemPrompt)
                self.tools
            }
            .toolCallingMode(.allowed)
            .maximumResponseTokens(self.maximumResponseTokens)
            .historyTransform { Self.compact($0, keep: keep) }
            .transcriptErrorHandlingPolicy(.revertTranscript)
            .onToolCall { call in await onToolCall?(call) }
            .onToolOutput { call, output in await onToolOutput?(call, output) }
        }
    }

    /// Keeps instructions plus the last `keep` other entries, dropping tool outputs orphaned from
    /// their tool calls at the cut.
    /// - Parameters:
    ///   - entries: Transcript history.
    ///   - keep: Entries kept besides instructions.
    /// - Returns: Compacted history.
    public static func compact(_ entries: [Transcript.Entry], keep: Int) -> [Transcript.Entry] {
        let instructions = entries.filter { entry in
            if case .instructions = entry { return true }
            return false
        }
        var rest = entries.filter { entry in
            if case .instructions = entry { return false }
            return true
        }
        guard rest.count > keep else { return entries }
        rest = Array(rest.suffix(keep))
        while let first = rest.first, case .toolOutput = first {
            rest.removeFirst()
        }
        return instructions + rest
    }
}

/// Builds Foundation Models sessions for OpenClaw agents (OS 27).
///
/// Every bridged call runs through a ``FoundationModelsAgentToolGate``, so tool policy, argument
/// schemas, `before_tool_call` hooks (block, rewrite, require approval) and approvals apply exactly as
/// in the agent loop, and `after_tool_call` fires after each call.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
public enum FoundationModelsAgentSession {
    /// Creates a session whose tools run through the registry behind a gate built from `hooks` and
    /// `approvals`.
    /// - Parameters:
    ///   - systemPrompt: Instructions.
    ///   - registry: Tool registry.
    ///   - context: Run context for tool invocations and hooks.
    ///   - route: Model routing.
    ///   - hooks: Optional hook registry: `before_tool_call` handlers can block, rewrite or require
    ///     approval, and each call emits ``HookName/afterToolCall``.
    ///   - approvals: Approval broker for calls that require approval; without one they are denied.
    ///   - maxHistoryEntries: History entries kept besides instructions.
    /// - Returns: The session and any tools that could not be bridged.
    public static func make(
        systemPrompt: String,
        registry: AgentToolRegistry,
        context: AgentToolInvocationContext = AgentToolInvocationContext(),
        route: OpenClawAgentProfile.Route = .onDevice,
        hooks: HookRegistry? = nil,
        approvals: ApprovalBroker? = nil,
        maxHistoryEntries: Int = 40
    ) async -> (session: LanguageModelSession, skipped: [FoundationModelsSkippedTool]) {
        await Self.make(
            systemPrompt: systemPrompt,
            gate: FoundationModelsAgentToolGate(registry: registry, context: context, hookRegistry: hooks, approvals: approvals),
            route: route,
            maxHistoryEntries: maxHistoryEntries
        )
    }

    /// Creates a session whose tools (the gate's registry) run through `gate`.
    /// - Parameters:
    ///   - systemPrompt: Instructions.
    ///   - gate: Tool gate (registry, run context, policy, hooks and approvals).
    ///   - route: Model routing.
    ///   - maxHistoryEntries: History entries kept besides instructions.
    /// - Returns: The session and any tools that could not be bridged.
    public static func make(
        systemPrompt: String,
        gate: FoundationModelsAgentToolGate,
        route: OpenClawAgentProfile.Route = .onDevice,
        maxHistoryEntries: Int = 40
    ) async -> (session: LanguageModelSession, skipped: [FoundationModelsSkippedTool]) {
        let (tools, skipped) = await FoundationModelsAgentTools.adapters(
            for: gate.registry,
            context: gate.context,
            invoke: { call in try await gate.invoke(call) }
        )
        let profile = OpenClawAgentProfile(
            systemPrompt: systemPrompt,
            tools: tools,
            route: route,
            maxHistoryEntries: maxHistoryEntries
        )
        return (LanguageModelSession(profile: profile), skipped)
    }
}
#endif
#endif
