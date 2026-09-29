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
        var configuration = self.deps.tools.toolSearch ?? .embeddedDefault
        if self.isSmallContext(model), configuration.enabled {
            configuration.minCatalogSize = min(configuration.minCatalogSize, self.deps.configuration.smallContextToolSearchThreshold + 1)
        }
        let catalog = ToolSearchCatalog(descriptors: descriptors, configuration: configuration)
        guard catalog.isActive else {
            return ToolView(visible: descriptors, catalog: nil)
        }
        return ToolView(visible: catalog.modelVisibleDescriptors, catalog: catalog)
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
        policy: ToolPolicy,
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
                policy: policy,
                enforcePolicy: true,
                request: request,
                hooks: hooks,
                events: events,
                recorder: recorder
            )
            return AgentToolResult(name: call.name, toolCallID: toolCallID, output: inner.output, durationMs: inner.durationMs)
        }
    }

    static func effectivePolicy(base: ToolPolicy, request: AgentRunRequest, session: SessionRecord?) -> ToolPolicy {
        var policy = request.toolPolicy ?? base
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
        policy: ToolPolicy,
        enforcePolicy: Bool,
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
                    policy: policy,
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
                policy: policy,
                enforcePolicy: enforcePolicy,
                request: request,
                hooks: hooks,
                events: events,
                recorder: recorder
            )
        }
        let parallel = calls.count > 1 && calls.allSatisfy { descriptors[$0.name]?.executionMode == .parallel }
        var results: [AgentToolResult] = []
        if parallel {
            results = try await withThrowingTaskGroup(of: (Int, AgentToolResult).self) { group in
                for (index, call) in calls.enumerated() {
                    group.addTask {
                        (index, try await dispatch(index, call))
                    }
                }
                var ordered: [(Int, AgentToolResult)] = []
                for try await item in group {
                    ordered.append(item)
                }
                return ordered.sorted { $0.0 < $1.0 }.map(\.1)
            }
        } else {
            for (index, call) in calls.enumerated() {
                try Task.checkCancellation()
                results.append(try await dispatch(index, call))
            }
        }
        for result in results {
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
        }
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

    func executeOne(
        _ call: AgentToolCall,
        descriptor: AgentToolDescriptor?,
        context: AgentToolInvocationContext,
        agentID: String,
        policy: ToolPolicy,
        enforcePolicy: Bool,
        request: AgentRunRequest,
        hooks: AgentLoopHookEmitter,
        events: AgentEventSequencer,
        recorder: AgentRunRecorder
    ) async throws -> AgentToolResult {
        let toolCallID = call.id ?? AgentToolCall.makeID()
        var arguments = call.arguments
        events.emit(.tool, [
            "phase": AnyCodable("start"),
            "name": AnyCodable(call.name),
            "toolCallId": AnyCodable(toolCallID),
            "args": AnyCodable(arguments),
        ])
        recorder.record(AgentRunEvent(runID: request.runID, kind: .toolStarted, toolName: call.name))
        await self.emitDiagnostic("tool.call.started", request: request, metadata: ["toolName": call.name, "toolCallId": toolCallID])

        let startedAt = Date()
        var hookContext = AgentToolCallHookContext(
            runID: request.runID,
            sessionKey: request.sessionKey,
            agentID: agentID,
            toolCallID: toolCallID,
            toolName: call.name,
            arguments: arguments,
            descriptor: descriptor
        )
        var result: AgentToolResult?

        if let descriptor {
            if enforcePolicy, !policy.allows(descriptor) {
                result = AgentToolResult(name: call.name, toolCallID: toolCallID, output: .error("Tool \(call.name) is not allowed by the current tool policy"))
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
                toolName: call.name,
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
                    "name": AnyCodable(call.name),
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
                durationMs: Int(Date().timeIntervalSince(startedAt) * 1000)
            )
        }
        await self.deps.hooks.afterToolCall?(hookContext, finished)
        let completedContext = hookContext
        let completed = finished
        await hooks.observe(
            .afterToolCall,
            metadata: [
                "toolName": AnyCodable(call.name),
                "toolCallId": AnyCodable(toolCallID),
                "isError": AnyCodable(finished.isError),
                "durationMs": AnyCodable(finished.durationMs ?? 0),
            ]
        ) {
            Self.afterToolCallEvent(context: completedContext, result: completed)
        }
        recorder.record(AgentRunEvent(runID: request.runID, kind: .toolCompleted, toolName: call.name))
        let preview = String(finished.output.text.prefix(self.deps.configuration.toolResultEventMaxChars))
        events.emit(.tool, [
            "phase": AnyCodable("result"),
            "name": AnyCodable(call.name),
            "toolCallId": AnyCodable(toolCallID),
            "isError": AnyCodable(finished.isError),
            "result": AnyCodable(preview),
            "durationMs": AnyCodable(finished.durationMs ?? 0),
        ])
        await self.emitDiagnostic(
            finished.isError ? "tool.call.failed" : "tool.call.completed",
            request: request,
            metadata: ["toolName": call.name, "toolCallId": toolCallID, "durationMs": String(finished.durationMs ?? 0)]
        )
        return finished
    }

    /// Asks the approval broker; returns an error result unless the call was approved.
    func requestToolApproval(
        _ approvalRequest: AgentToolApprovalRequest,
        call: AgentToolCall,
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
            toolName: call.name,
            agentID: agentID,
            allowedDecisions: approvalRequest.allowedDecisions
        )
        let grantKey: String
        if case .mcp(let server, let toolName) = descriptor?.source {
            grantKey = ApprovalBroker.mcpGrantKey(server: server, tool: toolName)
        } else {
            grantKey = ApprovalBroker.pluginGrantKey(pluginID: approvalRequest.pluginID, toolName: call.name)
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
        try await self.appendMessage(
            .toolResult(message),
            sessionID: sessionID,
            sessionKey: request.sessionKey,
            transcript: transcript,
            hooks: hooks,
            recorder: recorder
        )
    }

    /// Writes one transcript message after `before_message_write` handlers (block or replace).
    func appendMessage(
        _ message: AgentMessage,
        sessionID: String,
        sessionKey: String,
        transcript: any SessionTranscriptStore,
        hooks: AgentLoopHookEmitter,
        recorder: AgentRunRecorder
    ) async throws {
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
                return
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
    }

    func recordInterruptedTurn(
        error: Error,
        control: AgentRunControl,
        accumulator: AgentStreamAccumulator,
        sessionID: String,
        request: AgentRunRequest,
        transcript: any SessionTranscriptStore
    ) async throws {
        let aborted = error is CancellationError || control.cancellation != nil
        let partial = accumulator.partialVisibleText
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
