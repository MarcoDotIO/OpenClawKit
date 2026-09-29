import Foundation
import OpenClawCore
import OpenClawProtocol

// Pre-execution gate for agent tools that run outside the agent loop, inside a Foundation Models
// session (`FoundationModelsAgentSession`, `EmbeddedAgentRuntime.makeFoundationModelsSession`) or
// through `FoundationModelsAgentToolExecutor`. It applies the same checks as
// `AgentLoop.executeOne` before a tool body runs (upstream wraps every tool with
// `wrapToolWithBeforeToolCallHook`, so hooks apply in every execution mode):
//
// 1. registration, tool policy and argument schema;
// 2. the closure `AgentLoopHooks.beforeToolCall` seam (proceed, rewrite, block, requireApproval);
// 3. typed `before_tool_call` handlers from the `HookRegistry` (block, params, requireApproval);
// 4. approvals through the `ApprovalBroker` (fail closed when no broker is available);
// 5. re-validation of rewritten arguments;
//
// then invokes the registry and reports `AgentLoopHooks.afterToolCall` and typed `after_tool_call`.
// Blocked or unapproved calls become error results the model can read; the tool never runs.

/// Applies the agent loop's pre-execution checks (policy, schema, `before_tool_call` hooks and
/// approvals) to tool calls that run inside a Foundation Models session instead of the agent loop.
///
/// Pass ``invoke(_:)`` as the invocation path of ``FoundationModelsAgentToolExecutor/init(invoke:)``
/// or `FoundationModelsAgentTools.adapters(for:context:names:invoke:)`. Loop detection is not applied.
public struct FoundationModelsAgentToolGate: Sendable {
    /// Registry that owns the tools.
    public let registry: AgentToolRegistry
    /// Run context passed to each invocation and to hooks.
    public let context: AgentToolInvocationContext
    /// Tool policy re-checked for every call (`nil` skips the policy check).
    public let policy: ToolPolicy?
    /// Closure hook seams (`beforeToolCall`, `afterToolCall`).
    public let hooks: AgentLoopHooks
    /// Typed hook registry (`before_tool_call`, `after_tool_call`).
    public let hookRegistry: HookRegistry?
    /// Approval broker for `requireApproval` decisions; without one such calls are denied.
    public let approvals: ApprovalBroker?

    /// Creates a gate.
    /// - Parameters:
    ///   - registry: Registry that owns the tools.
    ///   - context: Run context for invocations and hooks.
    ///   - policy: Tool policy re-checked for every call (`nil` skips the check).
    ///   - hooks: Closure hook seams.
    ///   - hookRegistry: Typed hook registry.
    ///   - approvals: Approval broker; `nil` denies calls that require approval.
    public init(
        registry: AgentToolRegistry,
        context: AgentToolInvocationContext = AgentToolInvocationContext(),
        policy: ToolPolicy? = nil,
        hooks: AgentLoopHooks = AgentLoopHooks(),
        hookRegistry: HookRegistry? = nil,
        approvals: ApprovalBroker? = nil
    ) {
        self.registry = registry
        self.context = context
        self.policy = policy
        self.hooks = hooks
        self.hookRegistry = hookRegistry
        self.approvals = approvals
    }

    /// Error text returned when a call requires approval but no broker is available.
    static let noApprovalBrokerMessage = "Tool call requires approval, but no approval broker is available for this Foundation Models session; do not retry it"
    /// Source reported in `after_tool_call` metadata.
    static let hookSource = "foundation-models"

    /// Runs one call through the gate.
    /// - Parameter call: Model-proposed call.
    /// - Returns: The tool result, or an error result when the call was rejected, blocked or not approved.
    /// - Throws: `CancellationError` when cancelled; tool errors surface as error results.
    public func invoke(_ call: AgentToolCall) async throws -> AgentToolResult {
        let toolCallID = call.id ?? AgentToolCall.makeID()
        let runID = self.context.runID ?? "foundation-models"
        let sessionKey = self.context.sessionKey ?? ""
        let agentID = self.context.agentID ?? SessionKey.normalizeAgentID(nil)
        let emitter = AgentLoopHookEmitter(registry: self.hookRegistry, runID: runID, sessionKey: sessionKey, agentID: agentID)
        let descriptor = await self.registry.tool(named: call.name)?.descriptor
        var arguments = call.arguments
        var hookContext = AgentToolCallHookContext(
            runID: runID,
            sessionKey: sessionKey,
            agentID: agentID,
            toolCallID: toolCallID,
            toolName: call.name,
            arguments: arguments,
            descriptor: descriptor
        )
        let startedAt = Date()
        var result = self.staticRejection(call, toolCallID: toolCallID, descriptor: descriptor)

        if result == nil, let beforeToolCall = self.hooks.beforeToolCall {
            switch await beforeToolCall(hookContext) {
            case .proceed:
                break
            case .rewrite(let rewritten):
                arguments = rewritten
                hookContext.arguments = rewritten
            case .block(let reason):
                result = AgentToolResult(name: call.name, toolCallID: toolCallID, output: .error("Tool call blocked: \(reason)"))
            case .requireApproval(let request):
                result = try await self.requestApproval(request, call: call, toolCallID: toolCallID, descriptor: descriptor, context: hookContext)
            }
        }
        if result == nil, let decision = await emitter.beforeToolCall(
            BeforeToolCallEvent(
                toolName: call.name,
                params: arguments,
                toolKind: descriptor.map(AgentLoop.toolKind(of:)),
                runId: runID,
                toolCallId: toolCallID,
                derivedPaths: AgentLoop.derivedPaths(arguments)
            )
        ) {
            if decision.block == true {
                let reason = decision.blockReason?.trimmingCharacters(in: .whitespacesAndNewlines)
                let text = reason.flatMap { $0.isEmpty ? nil : "Tool call blocked: \($0)" } ?? AgentLoop.defaultHookBlockReason
                result = AgentToolResult(name: call.name, toolCallID: toolCallID, output: .error(text))
            } else {
                if let approval = decision.requireApproval {
                    result = try await self.requestApproval(
                        AgentToolApprovalRequest(approval),
                        call: call,
                        toolCallID: toolCallID,
                        descriptor: descriptor,
                        context: hookContext
                    )
                }
                if result == nil, let params = decision.params {
                    arguments = params
                    hookContext.arguments = params
                }
            }
        }
        // Rewritten arguments must still match the tool schema.
        if result == nil, arguments != call.arguments, let descriptor, let violation = AgentLoop.schemaViolation(arguments, descriptor: descriptor) {
            result = AgentToolResult(name: call.name, toolCallID: toolCallID, output: .error("Invalid arguments for \(call.name): \(violation)"))
        }
        let finished: AgentToolResult
        if let result {
            finished = result
        } else {
            try Task.checkCancellation()
            let invoked = try await self.registry.invoke(AgentToolCall(id: toolCallID, name: call.name, arguments: arguments), context: self.context)
            finished = invoked.durationMs == nil
                ? AgentToolResult(
                    name: invoked.name,
                    toolCallID: invoked.toolCallID,
                    output: invoked.output,
                    durationMs: Int(Date().timeIntervalSince(startedAt) * 1000)
                )
                : invoked
        }
        await self.hooks.afterToolCall?(hookContext, finished)
        let completedContext = hookContext
        await emitter.observe(
            .afterToolCall,
            metadata: [
                "toolName": AnyCodable(call.name),
                "toolCallId": AnyCodable(toolCallID),
                "isError": AnyCodable(finished.isError),
                "durationMs": AnyCodable(finished.durationMs ?? 0),
                "source": AnyCodable(Self.hookSource),
            ]
        ) {
            AgentLoop.afterToolCallEvent(context: completedContext, result: finished)
        }
        return finished
    }

    /// Registration, policy and schema checks.
    private func staticRejection(_ call: AgentToolCall, toolCallID: String, descriptor: AgentToolDescriptor?) -> AgentToolResult? {
        guard let descriptor else {
            return AgentToolResult(name: call.name, toolCallID: toolCallID, output: .error("Tool not found: \(call.name)"))
        }
        if let policy = self.policy, !policy.allows(descriptor) {
            return AgentToolResult(name: call.name, toolCallID: toolCallID, output: .error("Tool \(call.name) is not allowed by the current tool policy"))
        }
        if let violation = AgentLoop.schemaViolation(call.arguments, descriptor: descriptor) {
            return AgentToolResult(name: call.name, toolCallID: toolCallID, output: .error("Invalid arguments for \(call.name): \(violation)"))
        }
        return nil
    }

    /// Asks the approval broker; returns an error result unless the call was approved (no broker denies).
    private func requestApproval(
        _ request: AgentToolApprovalRequest,
        call: AgentToolCall,
        toolCallID: String,
        descriptor: AgentToolDescriptor?,
        context: AgentToolCallHookContext
    ) async throws -> AgentToolResult? {
        guard let approvals = self.approvals else {
            return AgentToolResult(name: call.name, toolCallID: toolCallID, output: .error(Self.noApprovalBrokerMessage))
        }
        let presentation = AgentApprovalPresentation.plugin(
            title: request.title,
            description: request.description,
            severity: request.severity,
            pluginID: request.pluginID,
            toolName: call.name,
            agentID: context.agentID,
            allowedDecisions: request.allowedDecisions
        )
        let grantKey: String
        if case .mcp(let server, let toolName) = descriptor?.source {
            grantKey = ApprovalBroker.mcpGrantKey(server: server, tool: toolName)
        } else {
            grantKey = ApprovalBroker.pluginGrantKey(pluginID: request.pluginID, toolName: call.name)
        }
        let started = await approvals.begin(
            presentation: presentation,
            sessionKey: context.sessionKey,
            agentID: context.agentID,
            runID: context.runID,
            toolCallID: toolCallID,
            grantKey: grantKey,
            timeoutMs: request.timeoutMs
        )
        let approval = started.state == .pending ? await approvals.waitUntilTerminal(started) : started
        try Task.checkCancellation()
        guard !approval.isAllowed else { return nil }
        if approval.state == .expired,
           let timeoutReason = request.timeoutReason?.trimmingCharacters(in: .whitespacesAndNewlines),
           !timeoutReason.isEmpty
        {
            return AgentToolResult(name: call.name, toolCallID: toolCallID, output: .error(timeoutReason))
        }
        let reason = approval.reason?.rawValue ?? approval.state.rawValue
        return AgentToolResult(
            name: call.name,
            toolCallID: toolCallID,
            output: .error("Tool call was not approved (\(approval.state.rawValue): \(reason)); do not retry it")
        )
    }
}
