import Foundation
import OpenClawCore
import OpenClawMedia
import OpenClawModels
import OpenClawProtocol
import OpenClawSkills

// Tool execution and transcript writes of the agent loop.

extension AgentLoop {
    // MARK: - Tools

    struct ToolView: Sendable {
        let visible: [AgentToolDescriptor]
        let catalog: ToolSearchCatalog?
        /// Canonical names of every tool this turn may execute (visible or behind Tool Search): the
        /// registry after the policy, session MCP overrides and `toolsAllow`.
        let callableNames: Set<String>
    }

    /// Execution-time tool checks. Hiding a tool from the model is not enough: a model can still call
    /// it by name, so every call is re-checked against the turn's callable set and the current
    /// session policy (permission mode and tool overrides re-read per call, so a mid-run tightening
    /// applies to the next call).
    struct ToolExecutionGate: Sendable {
        /// Enforce the checks (`false` for forced `AgentRunRequest.toolCalls`, which the host issued).
        let enforce: Bool
        /// Canonical names callable this turn; `nil` skips the check.
        let callableNames: Set<String>?
        /// Current policy and session tool overrides.
        let live: @Sendable () async -> (policy: ToolPolicy, overrides: SessionToolOverrides?)

        /// Gate that runs every call (forced host tool calls).
        static let unenforced = ToolExecutionGate(enforce: false, callableNames: nil) { (ToolPolicy.allowAll, nil) }

        /// Why a call must not run, or `nil` when it may.
        func denial(for descriptor: AgentToolDescriptor, calledAs name: String) async -> String? {
            guard self.enforce else { return nil }
            let current = await self.live()
            if !current.policy.allows(descriptor) {
                return "Tool \(name) is not allowed by the current tool policy"
            }
            if case .mcp(let server, let tool) = descriptor.source, current.overrides?.deniesMCPTool(server: server, tool: tool) == true {
                return "Tool \(name) is not allowed by the current tool policy"
            }
            if let callableNames, !callableNames.contains(AgentToolRegistry.canonicalName(descriptor.name)) {
                return "Tool \(name) is not available in this run"
            }
            return nil
        }
    }

    /// Gate for model-proposed calls of one turn: the turn's callable set plus a live re-read of the
    /// session record before each call.
    func toolGate(request: AgentRunRequest, fallback: SessionRecord?, callableNames: Set<String>?) -> ToolExecutionGate {
        let store = self.deps.sessionStore
        let base = self.deps.tools.policy
        let sessionKey = request.sessionKey
        return ToolExecutionGate(enforce: true, callableNames: callableNames) {
            let record = await store?.recordForKey(sessionKey) ?? fallback
            return (Self.effectivePolicy(base: base, request: request, session: record), record?.toolOverrides)
        }
    }

    /// Policy-filtered tools (shared registry, then run-scoped tools); large catalogs move behind Tool
    /// Search control tools. Session overrides remove denied MCP tools by source; `toolsAllow` from
    /// `before_prompt_build` narrows the set.
    func toolView(
        policy: ToolPolicy,
        model: AgentRunModelContext,
        session: SessionRecord?,
        promptBuild: AgentPromptBuildOverrides
    ) async -> ToolView {
        let shared = await self.deps.toolRegistry.descriptors()
        let sharedNames = Set(shared.map(\.name))
        let scoped = await self.deps.runTools.descriptors().filter { !sharedNames.contains($0.name) }
        var descriptors = policy.filter(shared + scoped)
        if let overrides = session?.toolOverrides {
            descriptors = descriptors.filter { descriptor in
                guard case .mcp(let server, let toolName) = descriptor.source else { return true }
                return !overrides.deniesMCPTool(server: server, tool: toolName)
            }
        }
        descriptors = promptBuild.filterTools(descriptors)
        let callableNames = Set(descriptors.map { AgentToolRegistry.canonicalName($0.name) })
        var configuration = self.deps.tools.toolSearch ?? .embeddedDefault
        if self.isSmallContext(model), configuration.enabled {
            configuration.minCatalogSize = min(configuration.minCatalogSize, self.deps.configuration.smallContextToolSearchThreshold + 1)
        }
        let catalog = ToolSearchCatalog(descriptors: descriptors, configuration: configuration)
        guard catalog.isActive else {
            return ToolView(visible: descriptors, catalog: nil, callableNames: callableNames)
        }
        return ToolView(visible: catalog.modelVisibleDescriptors, catalog: catalog, callableNames: callableNames)
    }

    /// Whether the model has a small context window (Apple's on-device `apple-fm/system` model, or a
    /// resolved window at or below ``AgentLoopConfiguration/smallContextWindowTokens``).
    func isSmallContext(_ model: AgentRunModelContext) -> Bool {
        if let providerID = model.providerID, FoundationModelsProvider.handles(providerID: providerID) {
            let target = FoundationModelsProvider.resolveTarget(modelID: model.modelID, defaultTarget: .system)
            if target == .system {
                return true
            }
        }
        guard let window = model.contextWindow else { return false }
        return window <= self.deps.configuration.smallContextWindowTokens
    }

    /// Looks a tool up in the shared registry first, then among run-scoped tools.
    func resolveTool(named name: String) async -> (any AgentTool)? {
        if let tool = await self.deps.toolRegistry.tool(named: name) {
            return tool
        }
        return await self.deps.runTools.tool(named: name)
    }

    /// Runs a Tool Search control call (`tool_search`, `tool_describe`, `tool_call`).
    func executeSearchControl(
        _ call: AgentToolCall,
        catalog: ToolSearchCatalog,
        context: AgentToolInvocationContext,
        agentID: String,
        gate: ToolExecutionGate,
        request: AgentRunRequest,
        hooks: AgentLoopHookEmitter,
        events: AgentEventSequencer,
        recorder: AgentRunRecorder
    ) async throws -> AgentToolResult {
        let toolCallID = call.id ?? AgentToolCall.makeID()
        switch call.name {
        case ToolSearchCatalog.searchToolName:
            return AgentToolResult(name: call.name, toolCallID: toolCallID, output: catalog.runSearch(call.arguments))
        case ToolSearchCatalog.describeToolName:
            return AgentToolResult(name: call.name, toolCallID: toolCallID, output: catalog.runDescribe(call.arguments))
        default:
            guard let targetID = call.arguments["id"]?.stringValue, let descriptor = catalog.descriptor(for: targetID) else {
                return AgentToolResult(
                    name: call.name,
                    toolCallID: toolCallID,
                    output: .error("Unknown tool id: \(call.arguments["id"]?.stringValue ?? ""); use tool_search first")
                )
            }
            let arguments = call.arguments["args"]?.dictionaryValue ?? [:]
            if let violation = Self.schemaViolation(arguments, descriptor: descriptor) {
                return AgentToolResult(
                    name: call.name,
                    toolCallID: toolCallID,
                    output: .error("Invalid arguments for \(descriptor.name): \(violation). Expected \(ToolSearchCatalog.inputSignature(descriptor))")
                )
            }
            let inner = try await self.executeOne(
                AgentToolCall(id: "\(toolCallID).inner", name: descriptor.name, arguments: arguments),
                descriptor: descriptor,
                context: AgentToolInvocationContext(
                    runID: context.runID,
                    sessionKey: context.sessionKey,
                    agentID: context.agentID,
                    parentToolCallID: toolCallID
                ),
                agentID: agentID,
                gate: gate,
                request: request,
                hooks: hooks,
                events: events,
                recorder: recorder
            )
            return AgentToolResult(name: call.name, toolCallID: toolCallID, output: inner.output, durationMs: inner.durationMs)
        }
    }

    static func effectivePolicy(base: ToolPolicy, request: AgentRunRequest, session: SessionRecord?) -> ToolPolicy {
        Self.effectivePolicy(base: base, requestPolicy: request.toolPolicy, session: session)
    }

    /// The policy a run of `session` executes under: the per-run policy (else the runtime base) plus
    /// the session's read-only mutation denies and tool-override denies.
    static func effectivePolicy(base: ToolPolicy, requestPolicy: ToolPolicy?, session: SessionRecord?) -> ToolPolicy {
        var policy = requestPolicy ?? base
        var deny: [String] = []
        if session?.permissionMode == .readOnly {
            deny.append(contentsOf: Self.mutationToolNames)
        }
        if let overrides = session?.toolOverrides {
            if overrides.webSearch == false {
                deny.append("web_search")
            }
            for (server, enabled) in overrides.mcpServers ?? [:] where !enabled {
                deny.append("\(server)\(CoreToolCatalog.mcpToolNameSeparator)*")
            }
            for (server, tools) in overrides.mcpToolsDeny ?? [:] {
                deny.append(contentsOf: tools.map { "\(server)\(CoreToolCatalog.mcpToolNameSeparator)\($0)" })
            }
        }
        if !deny.isEmpty {
            policy = policy.denying(deny)
        }
        return policy
    }

    func executeBatch(
        _ calls: [AgentToolCall],
        context: AgentToolInvocationContext,
        agentID: String,
        gate: ToolExecutionGate,
        searchCatalog: ToolSearchCatalog?,
        sessionID: String,
        request: AgentRunRequest,
        transcript: any SessionTranscriptStore,
        hooks: AgentLoopHookEmitter,
        events: AgentEventSequencer,
        recorder: AgentRunRecorder,
        loopHistory: inout [String]
    ) async throws -> [AgentToolResult] {
        var descriptors: [String: AgentToolDescriptor] = [:]
        var controlCalls: Set<Int> = []
        for (index, call) in calls.enumerated() {
            if let tool = await self.resolveTool(named: call.name) {
                descriptors[call.name] = tool.descriptor
            } else if searchCatalog != nil, ToolSearchCatalog.controlToolNames.contains(call.name) {
                controlCalls.insert(index)
            }
        }
        let controlCallIndices = controlCalls
        let resolvedDescriptors = descriptors
        let dispatch: @Sendable (Int, AgentToolCall) async throws -> AgentToolResult = { index, call in
            let controlCalls = controlCallIndices
            let descriptors = resolvedDescriptors
            if controlCalls.contains(index), let searchCatalog {
                return try await self.executeSearchControl(
                    call,
                    catalog: searchCatalog,
                    context: context,
                    agentID: agentID,
                    gate: gate,
                    request: request,
                    hooks: hooks,
                    events: events,
                    recorder: recorder
                )
            }
            return try await self.executeOne(
                call,
                descriptor: descriptors[call.name],
                context: context,
                agentID: agentID,
                gate: gate,
                request: request,
                hooks: hooks,
                events: events,
                recorder: recorder
            )
        }
        let parallel = calls.count > 1 && calls.allSatisfy { descriptors[$0.name]?.executionMode == .parallel }
        // The assistant tool-call turn is already persisted, so every call id must get a result in the
        // transcript, including calls an abort, timeout or error interrupted: providers reject a
        // replayed tool call without a result. Results are written in call order as they complete.
        var completed = [AgentToolResult?](repeating: nil, count: calls.count)
        var persisted = 0
        do {
            if parallel {
                let outcomes = await withTaskGroup(of: (Int, Result<AgentToolResult, Error>).self) { group in
                    for (index, call) in calls.enumerated() {
                        group.addTask {
                            do {
                                return (index, .success(try await dispatch(index, call)))
                            } catch {
                                return (index, .failure(error))
                            }
                        }
                    }
                    var collected: [(Int, Result<AgentToolResult, Error>)] = []
                    for await item in group {
                        collected.append(item)
                    }
                    return collected
                }
                var firstError: Error?
                for (index, outcome) in outcomes.sorted(by: { $0.0 < $1.0 }) {
                    switch outcome {
                    case .success(let result):
                        completed[index] = result
                    case .failure(let error):
                        firstError = firstError ?? error
                    }
                }
                if let firstError {
                    throw firstError
                }
            } else {
                for (index, call) in calls.enumerated() {
                    try Task.checkCancellation()
                    let result = try await dispatch(index, call)
                    completed[index] = result
                    recorder.record(result)
                    try await self.appendToolResult(
                        result,
                        sessionID: sessionID,
                        request: request,
                        transcript: transcript,
                        hooks: hooks,
                        recorder: recorder,
                        isSynthetic: false
                    )
                    persisted = index + 1
                }
            }
            while persisted < calls.count, let result = completed[persisted] {
                recorder.record(result)
                try await self.appendToolResult(
                    result,
                    sessionID: sessionID,
                    request: request,
                    transcript: transcript,
                    hooks: hooks,
                    recorder: recorder,
                    isSynthetic: false
                )
                persisted += 1
            }
        } catch {
            await self.persistInterruptedBatch(
                calls,
                completed: completed,
                from: persisted,
                sessionID: sessionID,
                request: request,
                transcript: transcript,
                hooks: hooks,
                recorder: recorder
            )
            throw error
        }
        let results = completed.compactMap { $0 }
        if self.deps.tools.loopDetection.enabled {
            let detection = self.deps.tools.loopDetection
            for (call, result) in zip(calls, results) {
                let argumentsJSON = ModelToolCall(id: "", name: call.name, arguments: call.arguments).argumentsJSON
                let signature = "\(AgentToolRegistry.canonicalName(call.name))|\(argumentsJSON)|\(result.output.text)"
                loopHistory.append(signature)
                if loopHistory.count > detection.window {
                    loopHistory.removeFirst(loopHistory.count - detection.window)
                }
                let repeats = loopHistory.filter { $0 == signature }.count
                if repeats >= detection.threshold {
                    await self.emitDiagnostic("tool.loop.detected", request: request, metadata: ["toolName": call.name, "repeats": String(repeats)])
                    throw AgentLoopDetectedError(toolName: call.name, repeats: repeats)
                }
            }
        }
        return results
    }

    /// Text of the synthetic result written for a tool call that an abort, timeout or error interrupted.
    static let interruptedToolResultText = "Tool call was interrupted before it returned a result (the run was aborted, "
        + "timed out or failed); its effects are unknown. Check before retrying it."

    /// Writes the results of an interrupted batch in call order: calls that finished keep their real
    /// result; the rest get a synthetic error result, so no call id is left without a result.
    func persistInterruptedBatch(
        _ calls: [AgentToolCall],
        completed: [AgentToolResult?],
        from start: Int,
        sessionID: String,
        request: AgentRunRequest,
        transcript: any SessionTranscriptStore,
        hooks: AgentLoopHookEmitter,
        recorder: AgentRunRecorder
    ) async {
        for index in start..<calls.count {
            if let result = completed[index] {
                recorder.record(result)
                do {
                    try await self.appendToolResult(
                        result,
                        sessionID: sessionID,
                        request: request,
                        transcript: transcript,
                        hooks: hooks,
                        recorder: recorder,
                        isSynthetic: false
                    )
                    continue
                } catch {
                    // Fall through to the synthetic result below.
                }
            }
            let call = calls[index]
            let synthetic = AgentToolResultMessage(
                toolCallId: call.id ?? "",
                toolName: call.name,
                content: [.text(Self.interruptedToolResultText)],
                isError: true,
                timestamp: SessionTranscriptClock.nowMs()
            )
            try? await self.appendSyntheticMessage(
                .toolResult(synthetic),
                sessionID: sessionID,
                sessionKey: request.sessionKey,
                transcript: transcript,
                recorder: recorder
            )
        }
    }

    func executeOne(
        _ call: AgentToolCall,
        descriptor: AgentToolDescriptor?,
        context: AgentToolInvocationContext,
        agentID: String,
        gate: ToolExecutionGate,
        request: AgentRunRequest,
        hooks: AgentLoopHookEmitter,
        events: AgentEventSequencer,
        recorder: AgentRunRecorder
    ) async throws -> AgentToolResult {
        let toolCallID = call.id ?? AgentToolCall.makeID()
        // The registry resolves case variants and aliases ("Bash" → exec), so hooks, approvals, events
        // and diagnostics use the resolved tool (upstream passes hooks `normalizeToolPolicyName(tool.name)`);
        // results still echo the proposed name, which providers require.
        let toolName = descriptor.map { AgentToolRegistry.canonicalName($0.name) } ?? call.name
        let displayName = descriptor?.name ?? call.name
        var arguments = call.arguments
        events.emit(.tool, [
            "phase": AnyCodable("start"),
            "name": AnyCodable(displayName),
            "toolCallId": AnyCodable(toolCallID),
            "args": AnyCodable(arguments),
        ])
        recorder.record(AgentRunEvent(runID: request.runID, kind: .toolStarted, toolName: displayName))
        await self.emitDiagnostic("tool.call.started", request: request, metadata: ["toolName": displayName, "toolCallId": toolCallID])

        let startedAt = Date()
        var hookContext = AgentToolCallHookContext(
            runID: request.runID,
            sessionKey: request.sessionKey,
            agentID: agentID,
            toolCallID: toolCallID,
            toolName: toolName,
            rawToolName: call.name,
            arguments: arguments,
            descriptor: descriptor
        )
        var result: AgentToolResult?

        if let descriptor {
            if let denial = await gate.denial(for: descriptor, calledAs: call.name) {
                result = AgentToolResult(name: call.name, toolCallID: toolCallID, output: .error(denial))
            } else if let violation = Self.schemaViolation(arguments, descriptor: descriptor) {
                result = AgentToolResult(name: call.name, toolCallID: toolCallID, output: .error("Invalid arguments for \(call.name): \(violation)"))
            }
        } else {
            result = AgentToolResult(name: call.name, toolCallID: toolCallID, output: .error("Tool not found: \(call.name)"))
        }

        // Closure hook seam, then typed `before_tool_call` handlers (which see earlier rewrites).
        if result == nil, let beforeToolCall = self.deps.hooks.beforeToolCall {
            switch await beforeToolCall(hookContext) {
            case .proceed:
                break
            case .rewrite(let rewritten):
                arguments = rewritten
                hookContext.arguments = rewritten
            case .block(let reason):
                result = AgentToolResult(name: call.name, toolCallID: toolCallID, output: .error("Tool call blocked: \(reason)"))
            case .requireApproval(let approvalRequest):
                result = try await self.requestToolApproval(
                    approvalRequest,
                    call: call,
                    toolName: toolName,
                    toolCallID: toolCallID,
                    descriptor: descriptor,
                    agentID: agentID,
                    request: request,
                    events: events
                )
            }
        }
        if result == nil, let decision = await hooks.beforeToolCall(
            BeforeToolCallEvent(
                toolName: toolName,
                params: arguments,
                toolKind: descriptor.map(Self.toolKind(of:)),
                runId: request.runID,
                toolCallId: toolCallID,
                derivedPaths: Self.derivedPaths(arguments)
            )
        ) {
            if decision.block == true {
                let reason = decision.blockReason?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                result = AgentToolResult(
                    name: call.name,
                    toolCallID: toolCallID,
                    output: .error(reason.map { "Tool call blocked: \($0)" } ?? Self.defaultHookBlockReason)
                )
            } else {
                if let approval = decision.requireApproval {
                    result = try await self.requestToolApproval(
                        AgentToolApprovalRequest(approval),
                        call: call,
                        toolName: toolName,
                        toolCallID: toolCallID,
                        descriptor: descriptor,
                        agentID: agentID,
                        request: request,
                        events: events
                    )
                }
                if result == nil, let params = decision.params {
                    arguments = params
                    hookContext.arguments = params
                }
            }
        }
        // Rewritten arguments must still match the tool schema.
        if result == nil, arguments != call.arguments, let descriptor, let violation = Self.schemaViolation(arguments, descriptor: descriptor) {
            result = AgentToolResult(name: call.name, toolCallID: toolCallID, output: .error("Invalid arguments for \(call.name): \(violation)"))
        }

        if result == nil {
            let invokeCall = AgentToolCall(id: toolCallID, name: call.name, arguments: arguments)
            let update: AgentToolUpdateHandler = { partial in
                var data: [String: AnyCodable] = [
                    "phase": AnyCodable("update"),
                    "name": AnyCodable(displayName),
                    "toolCallId": AnyCodable(toolCallID),
                ]
                if let progress = partial.progress {
                    var meta: [String: AnyCodable] = [:]
                    if let message = progress.message { meta["message"] = AnyCodable(message) }
                    if let fraction = progress.fraction { meta["fraction"] = AnyCodable(fraction) }
                    data["meta"] = AnyCodable(meta)
                }
                if !partial.text.isEmpty {
                    data["partialResult"] = AnyCodable(String(partial.text.prefix(2_000)))
                }
                events.emit(.tool, data)
            }
            if await self.deps.toolRegistry.tool(named: call.name) != nil {
                result = try await self.deps.toolRegistry.invoke(invokeCall, context: context, update: update)
            } else {
                result = try await self.deps.runTools.invoke(invokeCall, context: context, update: update)
            }
        }

        guard var finished = result else {
            throw CancellationError()
        }
        if finished.durationMs == nil {
            finished = AgentToolResult(
                name: finished.name,
                toolCallID: finished.toolCallID,
                output: finished.output,
                durationMs: RuntimeTime.elapsedMilliseconds(since: startedAt)
            )
        }
        await self.deps.hooks.afterToolCall?(hookContext, finished)
        let completedContext = hookContext
        let completed = finished
        await hooks.observe(
            .afterToolCall,
            metadata: [
                "toolName": AnyCodable(toolName),
                "toolCallId": AnyCodable(toolCallID),
                "isError": AnyCodable(finished.isError),
                "durationMs": AnyCodable(finished.durationMs ?? 0),
            ]
        ) {
            Self.afterToolCallEvent(context: completedContext, result: completed)
        }
        recorder.record(AgentRunEvent(runID: request.runID, kind: .toolCompleted, toolName: displayName))
        let preview = String(finished.output.text.prefix(self.deps.configuration.toolResultEventMaxChars))
        events.emit(.tool, [
            "phase": AnyCodable("result"),
            "name": AnyCodable(displayName),
            "toolCallId": AnyCodable(toolCallID),
            "isError": AnyCodable(finished.isError),
            "result": AnyCodable(preview),
            "durationMs": AnyCodable(finished.durationMs ?? 0),
        ])
        await self.emitDiagnostic(
            finished.isError ? "tool.call.failed" : "tool.call.completed",
            request: request,
            metadata: ["toolName": displayName, "toolCallId": toolCallID, "durationMs": String(finished.durationMs ?? 0)]
        )
        return finished
    }

    /// Asks the approval broker; returns an error result unless the call was approved.
    func requestToolApproval(
        _ approvalRequest: AgentToolApprovalRequest,
        call: AgentToolCall,
        toolName: String,
        toolCallID: String,
        descriptor: AgentToolDescriptor?,
        agentID: String,
        request: AgentRunRequest,
        events: AgentEventSequencer
    ) async throws -> AgentToolResult? {
        let presentation = AgentApprovalPresentation.plugin(
            title: approvalRequest.title,
            description: approvalRequest.description,
            severity: approvalRequest.severity,
            pluginID: approvalRequest.pluginID,
            toolName: toolName,
            agentID: agentID,
            allowedDecisions: approvalRequest.allowedDecisions
        )
        let grantKey: String
        if case .mcp(let server, let mcpTool) = descriptor?.source {
            grantKey = ApprovalBroker.mcpGrantKey(server: server, tool: mcpTool)
        } else {
            grantKey = ApprovalBroker.pluginGrantKey(pluginID: approvalRequest.pluginID, toolName: toolName)
        }
        let started = await self.deps.approvalBroker.begin(
            presentation: presentation,
            sessionKey: request.sessionKey,
            agentID: agentID,
            runID: request.runID,
            toolCallID: toolCallID,
            grantKey: grantKey,
            timeoutMs: approvalRequest.timeoutMs
        )
        var approval = started
        if started.state == .pending {
            events.emit(.approval, started.agentEventData)
            approval = await self.deps.approvalBroker.waitUntilTerminal(started)
            events.emit(.approval, approval.agentEventData)
        }
        try Task.checkCancellation()
        guard !approval.isAllowed else { return nil }
        if approval.state == .expired, let timeoutReason = approvalRequest.timeoutReason?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            return AgentToolResult(name: call.name, toolCallID: toolCallID, output: .error(timeoutReason))
        }
        let reason = approval.reason?.rawValue ?? approval.state.rawValue
        return AgentToolResult(
            name: call.name,
            toolCallID: toolCallID,
            output: .error("Tool call was not approved (\(approval.state.rawValue): \(reason)); do not retry it")
        )
    }

    /// Upstream `after_tool_call` event for a finished call.
    static func afterToolCallEvent(context: AgentToolCallHookContext, result: AgentToolResult) -> AfterToolCallEvent {
        AfterToolCallEvent(
            toolName: context.toolName,
            params: context.arguments,
            runId: context.runID,
            toolCallId: context.toolCallID,
            result: result.isError ? nil : (result.output.details ?? AnyCodable(result.output.text)),
            error: result.isError ? result.output.text : nil,
            durationMs: result.durationMs
        )
    }

    /// Host discriminator passed to `before_tool_call` (`mcp`, `plugin`, `client`, `channel`, `core`).
    static func toolKind(of descriptor: AgentToolDescriptor) -> String {
        switch descriptor.source {
        case .core:
            return "core"
        case .plugin:
            return "plugin"
        case .mcp:
            return "mcp"
        case .client:
            return "client"
        case .channel:
            return "channel"
        }
    }

    /// Best-effort destination paths (`path`, `file_path`, `filePath`, `paths`) for `before_tool_call`.
    static func derivedPaths(_ arguments: [String: AnyCodable]) -> [String]? {
        var paths: [String] = []
        for key in ["path", "file_path", "filePath", "target", "destination"] {
            if let value = arguments[key]?.stringValue, !value.isEmpty {
                paths.append(value)
            }
        }
        for value in arguments["paths"]?.arrayValue ?? [] {
            if let path = value.stringValue, !path.isEmpty {
                paths.append(path)
            }
        }
        return paths.isEmpty ? nil : paths
    }

    static func schemaViolation(_ arguments: [String: AnyCodable], descriptor: AgentToolDescriptor) -> String? {
        // Tools that declare no schema (the default empty object, typical of v1 tools) accept any arguments.
        if descriptor.parameters == AgentToolDescriptor.emptyParametersSchema {
            return nil
        }
        return JSONSchemaValidator.firstViolation(instance: AnyCodable(.object(arguments)), against: descriptor.parameters)
    }

    /// Records tool calls a provider executed in-process: an assistant tool-call message, the results,
    /// and `tool` events, without executing them again.
    func recordExecutedToolCalls(
        _ response: ModelGenerationResponse,
        sessionID: String,
        request: AgentRunRequest,
        transcript: any SessionTranscriptStore,
        hooks: AgentLoopHookEmitter,
        events: AgentEventSequencer,
        recorder: AgentRunRecorder
    ) async throws {
        let executed = response.executedToolCalls
        let message = AgentAssistantMessage(
            content: executed.map { .toolCall(AgentToolCallBlock(id: $0.call.id, name: $0.call.name, arguments: $0.call.arguments ?? [:])) },
            provider: response.providerID,
            model: response.modelID ?? "",
            stopReason: .toolUse,
            timestamp: SessionTranscriptClock.nowMs()
        )
        try await self.appendMessage(
            .assistant(message),
            sessionID: sessionID,
            sessionKey: request.sessionKey,
            transcript: transcript,
            hooks: hooks,
            recorder: recorder
        )
        for record in executed {
            let text = record.result.content.compactMap(\.text).joined(separator: "\n")
            events.emit(.tool, [
                "phase": AnyCodable("start"),
                "name": AnyCodable(record.call.name),
                "toolCallId": AnyCodable(record.call.id),
                "args": AnyCodable(record.call.arguments ?? [:]),
                "executedByProvider": AnyCodable(true),
            ])
            let result = AgentToolResult(
                name: record.call.name,
                toolCallID: record.call.id,
                output: AgentToolOutput(content: [.text(text)], details: record.result.details, isError: record.result.isError)
            )
            recorder.record(AgentRunEvent(runID: request.runID, kind: .toolStarted, toolName: record.call.name))
            recorder.record(result)
            recorder.record(AgentRunEvent(runID: request.runID, kind: .toolCompleted, toolName: record.call.name))
            events.emit(.tool, [
                "phase": AnyCodable("result"),
                "name": AnyCodable(record.call.name),
                "toolCallId": AnyCodable(record.call.id),
                "isError": AnyCodable(record.result.isError),
                "result": AnyCodable(String(text.prefix(self.deps.configuration.toolResultEventMaxChars))),
                "executedByProvider": AnyCodable(true),
            ])
            try await self.appendToolResult(
                result,
                sessionID: sessionID,
                request: request,
                transcript: transcript,
                hooks: hooks,
                recorder: recorder,
                isSynthetic: true
            )
        }
    }

    // MARK: - Transcript

    /// Appends a tool result after `tool_result_persist` handlers had a chance to replace it.
    func appendToolResult(
        _ result: AgentToolResult,
        sessionID: String,
        request: AgentRunRequest,
        transcript: any SessionTranscriptStore,
        hooks: AgentLoopHookEmitter,
        recorder: AgentRunRecorder,
        isSynthetic: Bool
    ) async throws {
        var message = AgentMessageConversion.toolResultMessage(from: result, timestamp: SessionTranscriptClock.nowMs())
        let original = message
        if let replacement = await hooks.toolResultPersist({
            ToolResultPersistEvent(
                toolName: original.toolName,
                toolCallId: original.toolCallId,
                message: HookPayloadCoding.encode(AgentMessage.toolResult(original)) ?? AnyCodable(.null),
                isSynthetic: isSynthetic ? true : nil
            )
        })?.message {
            if let decoded = HookPayloadCoding.decode(AgentMessage.self, from: replacement), case .toolResult(let rewritten) = decoded {
                message = rewritten
            } else if let decoded = HookPayloadCoding.decode(AgentToolResultMessage.self, from: replacement) {
                message = decoded
            }
        }
        let written = try await self.appendMessage(
            .toolResult(message),
            sessionID: sessionID,
            sessionKey: request.sessionKey,
            transcript: transcript,
            hooks: hooks,
            recorder: recorder
        )
        if !written {
            // A `before_message_write` block must not leave the call without a result (providers
            // reject the replayed tool call), so a content-free placeholder takes its place.
            let placeholder = AgentToolResultMessage(
                toolCallId: original.toolCallId,
                toolName: original.toolName,
                content: [.text(Self.blockedToolResultText)],
                isError: true,
                timestamp: SessionTranscriptClock.nowMs()
            )
            try await self.appendSyntheticMessage(
                .toolResult(placeholder),
                sessionID: sessionID,
                sessionKey: request.sessionKey,
                transcript: transcript,
                recorder: recorder
            )
        }
    }

    /// Text of the placeholder written when a `before_message_write` handler blocks a tool result.
    static let blockedToolResultText = "Tool result was not recorded (blocked by a before_message_write hook)."

    /// Writes a runtime-generated message (placeholders for missing tool results) without running
    /// the write hooks again.
    func appendSyntheticMessage(
        _ message: AgentMessage,
        sessionID: String,
        sessionKey: String,
        transcript: any SessionTranscriptStore,
        recorder: AgentRunRecorder
    ) async throws {
        try await transcript.appendMessage(message, sessionID: sessionID)
        recorder.record(message)
        if let engine = await self.deps.contextEngines.selected() {
            _ = await engine.ingest(sessionID: sessionID, sessionKey: sessionKey, message: message)
        }
    }

    /// Writes one transcript message after `before_message_write` handlers (block or replace).
    /// - Returns: `false` when a handler blocked the write.
    @discardableResult
    func appendMessage(
        _ message: AgentMessage,
        sessionID: String,
        sessionKey: String,
        transcript: any SessionTranscriptStore,
        hooks: AgentLoopHookEmitter,
        recorder: AgentRunRecorder
    ) async throws -> Bool {
        var written = message
        let agentID = hooks.agentID
        if let decision = await hooks.beforeMessageWrite({
            BeforeMessageWriteEvent(message: HookPayloadCoding.encode(message) ?? AnyCodable(.null), sessionKey: sessionKey, agentId: agentID)
        }) {
            if decision.block == true {
                await self.emitDiagnostic(
                    "transcript.write.blocked",
                    runID: hooks.runID,
                    sessionKey: sessionKey,
                    metadata: ["role": message.role]
                )
                return false
            }
            if let replacement = decision.message, let decoded = HookPayloadCoding.decode(AgentMessage.self, from: replacement) {
                written = decoded
            }
        }
        try await transcript.appendMessage(written, sessionID: sessionID)
        recorder.record(written)
        if let engine = await self.deps.contextEngines.selected() {
            _ = await engine.ingest(sessionID: sessionID, sessionKey: sessionKey, message: written)
        }
        return true
    }

    /// Records the turn an abort, timeout or error interrupted. `partialText` is the visible text the
    /// interrupted model turn streamed before it was persisted (empty when every turn was persisted).
    func recordInterruptedTurn(
        error: Error,
        control: AgentRunControl,
        partialText: String,
        sessionID: String,
        request: AgentRunRequest,
        transcript: any SessionTranscriptStore
    ) async throws {
        let aborted = error is CancellationError || control.cancellation != nil
        let partial = partialText
        guard aborted || !partial.isEmpty else { return }
        let message = AgentAssistantMessage(
            content: partial.isEmpty ? [] : [.text(partial)],
            provider: request.modelProviderID ?? "",
            model: request.modelID ?? "",
            stopReason: aborted ? .aborted : .error,
            errorMessage: aborted ? (control.cancellation == .timedOut ? "timed out" : "aborted") : error.localizedDescription,
            timestamp: SessionTranscriptClock.nowMs()
        )
        try await transcript.appendMessage(.assistant(message), sessionID: sessionID)
    }
}
