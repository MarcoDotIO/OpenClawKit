import Foundation
import OpenClawCore
import OpenClawGateway
import OpenClawProtocol

/// A `tools.effective` notice (upstream `ToolsEffectiveNotice`), for example MCP servers that did
/// not connect.
public struct AgentToolInventoryNotice: Sendable, Equatable {
    /// Stable notice identifier (for example `mcp-not-yet-connected`).
    public var id: String
    /// `info` or `warning`.
    public var severity: String
    /// Human-readable message.
    public var message: String
    /// MCP servers the notice is about.
    public var servers: [String]?

    /// Creates a notice.
    /// - Parameters:
    ///   - id: Stable identifier.
    ///   - severity: `info` or `warning`.
    ///   - message: Message.
    ///   - servers: Affected MCP servers.
    public init(id: String, severity: String = "info", message: String, servers: [String]? = nil) {
        self.id = id
        self.severity = severity
        self.message = message
        self.servers = servers
    }

    var payload: AnyCodable {
        var object: [String: AnyCodable] = [
            "id": AnyCodable(self.id),
            "severity": AnyCodable(self.severity),
            "message": AnyCodable(self.message),
        ]
        if let servers {
            object["servers"] = AnyCodable(servers.map { AnyCodable($0) })
        }
        return AnyCodable(object)
    }
}

/// Options for ``EmbeddedAgentRuntime/registerToolGatewayMethods(on:options:)``.
public struct AgentToolGatewayOptions: Sendable {
    /// Hooks run around `tools.invoke` (`beforeToolCall` may block, rewrite arguments or require
    /// approval). The runtime's own loop hooks are not readable, so pass the same hooks here to apply
    /// them to direct invocations.
    public var hooks: AgentLoopHooks
    /// Extra `tools.effective` notices (for example `MCPClientManager.toolInventoryNotices()`).
    public var notices: (@Sendable () async -> [AgentToolInventoryNotice])?
    /// Upper bound (ms) for waiting on an approval when `tools.invoke` is called with `confirm: true`.
    public var approvalTimeoutMs: Int64?

    /// Creates options.
    /// - Parameters:
    ///   - hooks: Hooks around direct invocations.
    ///   - notices: Extra `tools.effective` notices.
    ///   - approvalTimeoutMs: Approval wait bound for confirmed invocations.
    public init(
        hooks: AgentLoopHooks = AgentLoopHooks(),
        notices: (@Sendable () async -> [AgentToolInventoryNotice])? = nil,
        approvalTimeoutMs: Int64? = nil
    ) {
        self.hooks = hooks
        self.notices = notices
        self.approvalTimeoutMs = approvalTimeoutMs
    }
}

public extension EmbeddedAgentRuntime {
    /// Methods registered by ``registerToolGatewayMethods(on:options:)``.
    static let toolGatewayMethodNames: [String] = ["tools.catalog", "tools.effective", "tools.invoke"]

    /// Registers `tools.catalog`, `tools.effective` and `tools.invoke` over the runtime's tool registry
    /// and tool policy (upstream `tools-catalog.ts`, `tools-effective.ts`, `tools-invoke.ts`).
    ///
    /// - `tools.catalog {agentId?, includePlugins?}` → `{agentId, profiles, groups}`: the core sections
    ///   of ``CoreToolCatalog``, app-registered tools outside the core catalog (group `sdk`, an SDK
    ///   extension), and one group per plugin (`plugin:<id>`).
    /// - `tools.effective {agentId?, sessionKey}` → `{agentId, profile, groups, notices?}`: registered
    ///   tools visible after the tool policy and the session's permission mode and `toolOverrides`,
    ///   grouped `core`/`plugin`/`channel`/`mcp`; tools only the session denies carry `deniedBySession`.
    /// - `tools.invoke {name, args?, sessionKey?, agentId?, confirm?, idempotencyKey?}` →
    ///   `{ok, toolName, output?, source?, requiresApproval?, approvalId?, error?}`. When a
    ///   `beforeToolCall` hook requires approval, `confirm: true` asks for an approval and waits for
    ///   the decision (upstream `approvalMode: "request"`). Without `confirm`, the answer carries the
    ///   pending `approvalId` from ``ApprovalBroker/begin(presentation:sessionKey:agentID:runID:toolCallID:grantKey:timeoutMs:)``
    ///   (an SDK extension); resolve it and call again with the same `name`, `args`, `sessionKey` and
    ///   `agentId` plus `confirm: true` and `approvalId`. That id authorizes exactly one invocation of
    ///   the call it was raised for: a different tool, arguments, session or agent, an id not issued
    ///   by `tools.invoke`, or a second use answers `forbidden`. Error codes follow upstream:
    ///   `not_found`, `validation_error`, `forbidden`, `requires_approval`, `internal_error`.
    /// - Parameters:
    ///   - registrar: Gateway server or registrar.
    ///   - options: Hooks, notices and approval settings.
    func registerToolGatewayMethods(on registrar: some GatewayMethodRegistrar, options: AgentToolGatewayOptions = AgentToolGatewayOptions()) async {
        let handlers = AgentToolGatewayHandlers(
            runtime: self,
            options: options,
            idempotency: GatewayIdempotencyCache(),
            approvalBindings: ToolInvokeApprovalBindings()
        )
        await registrar.register(method: "tools.catalog") { try await handlers.catalog($0) }
        await registrar.register(method: "tools.effective") { try await handlers.effective($0) }
        await registrar.register(method: "tools.invoke") { try await handlers.invoke($0) }
    }
}

/// Approvals minted by `tools.invoke`, each bound to the exact invocation it was raised for and
/// usable once (the SDK's two-step `approvalId` round trip; upstream only waits inline).
actor ToolInvokeApprovalBindings {
    /// The invocation an approval authorizes.
    struct Binding: Sendable, Equatable {
        let toolName: String
        let grantKey: String
        let sessionKey: String?
        let agentID: String
        /// Canonical (sorted-key) JSON of the arguments after `beforeToolCall` rewrites.
        let arguments: String
    }

    /// Outcome of presenting an `approvalId`.
    enum Claim: Sendable, Equatable {
        case accepted(toolCallID: String)
        case unknown
        case mismatch
        case consumed
    }

    private struct Entry {
        let binding: Binding
        let toolCallID: String
    }

    static let capacity = 512
    private var entries: [String: Entry] = [:]
    private var entryOrder: [String] = []
    private var consumed: Set<String> = []
    private var consumedOrder: [String] = []

    /// Canonical JSON of tool arguments (sorted keys) used to compare invocations.
    static func canonicalArguments(_ arguments: [String: AnyCodable]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(arguments)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    func bind(_ approvalID: String, toolCallID: String, binding: Binding) {
        if self.entries[approvalID] == nil {
            self.entryOrder.append(approvalID)
        }
        self.entries[approvalID] = Entry(binding: binding, toolCallID: toolCallID)
        while self.entryOrder.count > Self.capacity {
            self.entries.removeValue(forKey: self.entryOrder.removeFirst())
        }
    }

    /// Checks an id against the current invocation without using it up.
    func check(_ approvalID: String, binding: Binding) -> Claim {
        if self.consumed.contains(approvalID) {
            return .consumed
        }
        guard let entry = self.entries[approvalID] else {
            return .unknown
        }
        return entry.binding == binding ? .accepted(toolCallID: entry.toolCallID) : .mismatch
    }

    /// Uses an id up when it still matches; the first caller wins.
    func consume(_ approvalID: String, binding: Binding) -> Claim {
        let claim = self.check(approvalID, binding: binding)
        guard case .accepted = claim else { return claim }
        self.entries.removeValue(forKey: approvalID)
        self.entryOrder.removeAll { $0 == approvalID }
        self.consumed.insert(approvalID)
        self.consumedOrder.append(approvalID)
        while self.consumedOrder.count > Self.capacity {
            self.consumed.remove(self.consumedOrder.removeFirst())
        }
        return claim
    }
}

struct AgentToolGatewayHandlers: Sendable {
    let runtime: EmbeddedAgentRuntime
    let options: AgentToolGatewayOptions
    let idempotency: GatewayIdempotencyCache
    let approvalBindings: ToolInvokeApprovalBindings

    static let profileLabels: [(ToolProfileID, String)] = [
        (.minimal, "Minimal"), (.coding, "Coding"), (.messaging, "Messaging"), (.full, "Full"),
    ]

    private func agentID(_ request: GatewayMethodRequest, record: SessionRecord? = nil) -> String {
        SessionKey.normalizeAgentID(request.stringParam("agentId") ?? record?.agentID ?? self.runtime.defaultAgentID)
    }

    // MARK: - tools.catalog

    func catalog(_ request: GatewayMethodRequest) async throws -> AnyCodable? {
        let agentID = self.agentID(request)
        let includePlugins = request.params["includePlugins"]?.boolValue ?? true
        let descriptors = await self.runtime.toolRegistry.descriptors()
        let byName = Dictionary(descriptors.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var groups: [AnyCodable] = CoreToolCatalog.visibleSections().map { section, tools in
            AnyCodable([
                "id": AnyCodable(section.id),
                "label": AnyCodable(section.label),
                "source": AnyCodable("core"),
                "tools": AnyCodable(tools.map { tool in
                    Self.catalogEntry(
                        id: tool.id,
                        label: byName[tool.id]?.label ?? tool.id,
                        description: tool.description,
                        source: "core",
                        pluginID: nil,
                        descriptor: byName[tool.id],
                        defaultProfiles: tool.profiles
                    )
                }),
            ] as [String: AnyCodable])
        }
        var runtimeTools: [AgentToolDescriptor] = []
        var pluginTools: [String: [AgentToolDescriptor]] = [:]
        for descriptor in descriptors where !CoreToolCatalog.isKnownCoreTool(descriptor.name) {
            switch descriptor.source {
            case .plugin(let id):
                pluginTools[id, default: []].append(descriptor)
            case .core, .client:
                if let owner = await self.runtime.toolRegistry.ownerPluginID(forTool: descriptor.name) {
                    pluginTools[owner, default: []].append(descriptor)
                } else {
                    runtimeTools.append(descriptor)
                }
            case .mcp, .channel:
                continue
            }
        }
        if !runtimeTools.isEmpty {
            groups.append(AnyCodable([
                "id": AnyCodable("sdk"),
                "label": AnyCodable("SDK tools"),
                "source": AnyCodable("core"),
                "tools": AnyCodable(runtimeTools.map { descriptor in
                    Self.catalogEntry(
                        id: descriptor.name,
                        label: descriptor.label,
                        description: Self.summary(descriptor),
                        source: "core",
                        pluginID: nil,
                        descriptor: descriptor,
                        defaultProfiles: descriptor.defaultProfiles
                    )
                }),
            ] as [String: AnyCodable]))
        }
        if includePlugins {
            for pluginID in pluginTools.keys.sorted() {
                let tools = (pluginTools[pluginID] ?? []).sorted { $0.name < $1.name }
                groups.append(AnyCodable([
                    "id": AnyCodable("plugin:\(pluginID)"),
                    "label": AnyCodable(pluginID),
                    "source": AnyCodable("plugin"),
                    "pluginId": AnyCodable(pluginID),
                    "tools": AnyCodable(tools.map { descriptor in
                        Self.catalogEntry(
                            id: descriptor.name,
                            label: descriptor.label,
                            description: Self.summary(descriptor),
                            source: "plugin",
                            pluginID: pluginID,
                            descriptor: descriptor,
                            defaultProfiles: []
                        )
                    }),
                ] as [String: AnyCodable]))
            }
        }
        return AnyCodable([
            "agentId": AnyCodable(agentID),
            "profiles": AnyCodable(Self.profileLabels.map { AnyCodable(["id": AnyCodable($0.0.rawValue), "label": AnyCodable($0.1)]) }),
            "groups": AnyCodable(groups),
        ])
    }

    private static func catalogEntry(
        id: String,
        label: String,
        description: String,
        source: String,
        pluginID: String?,
        descriptor: AgentToolDescriptor?,
        defaultProfiles: [ToolProfileID]
    ) -> AnyCodable {
        var entry: [String: AnyCodable] = [
            "id": AnyCodable(id),
            "label": AnyCodable(label.isEmpty ? id : label),
            "description": AnyCodable(description),
            "source": AnyCodable(source),
            "defaultProfiles": AnyCodable(defaultProfiles.map { AnyCodable($0.rawValue) }),
        ]
        if let pluginID { entry["pluginId"] = AnyCodable(pluginID) }
        if let risk = descriptor?.risk { entry["risk"] = AnyCodable(risk.rawValue) }
        if let tags = descriptor?.tags, !tags.isEmpty { entry["tags"] = AnyCodable(tags.map { AnyCodable($0) }) }
        if let descriptor, !descriptor.description.isEmpty, descriptor.description != description {
            entry["fullDescription"] = AnyCodable(descriptor.description)
        }
        return AnyCodable(entry)
    }

    private static func summary(_ descriptor: AgentToolDescriptor) -> String {
        if let summary = descriptor.displaySummary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            return summary
        }
        let firstLine = descriptor.description.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        return firstLine.isEmpty ? descriptor.name : firstLine
    }

    // MARK: - tools.effective

    private func policies(sessionKey: String?, record: SessionRecord?, agentID: String) async -> (base: ToolPolicy, session: ToolPolicy) {
        let base = await self.runtime.currentToolsConfiguration().policy
        let probe = AgentRunRequest(sessionKey: sessionKey ?? "tools.inventory", prompt: "", agentID: agentID)
        return (base, AgentLoop.effectivePolicy(base: base, request: probe, session: record))
    }

    func effective(_ request: GatewayMethodRequest) async throws -> AnyCodable? {
        guard let sessionKey = request.stringParam("sessionKey", "key") else {
            throw GatewayMethodError.invalidRequest("tools.effective requires sessionKey")
        }
        let record = await self.runtime.sessionStore?.recordForKey(sessionKey)
        let agentID = self.agentID(request, record: record)
        let (base, session) = await self.policies(sessionKey: sessionKey, record: record, agentID: agentID)
        var buckets: [String: [AnyCodable]] = [:]
        for descriptor in await self.runtime.toolRegistry.descriptors() where base.allows(descriptor) {
            let deniedBySession = !session.allows(descriptor)
            let source = Self.sourceKind(descriptor.source)
            let bucket = source == "client" ? "core" : source
            var entry: [String: AnyCodable] = [
                "id": AnyCodable(descriptor.name),
                "label": AnyCodable(descriptor.label.isEmpty ? descriptor.name : descriptor.label),
                "description": AnyCodable(Self.summary(descriptor)),
                "rawDescription": AnyCodable(descriptor.description),
                "source": AnyCodable(bucket),
            ]
            switch descriptor.source {
            case .plugin(let id): entry["pluginId"] = AnyCodable(id)
            case .channel(let id): entry["channelId"] = AnyCodable(id)
            case .mcp(let server, let toolName):
                entry["mcpServer"] = AnyCodable(server)
                entry["mcpToolName"] = AnyCodable(toolName)
            case .core, .client: break
            }
            if deniedBySession { entry["deniedBySession"] = AnyCodable(true) }
            if let risk = descriptor.risk { entry["risk"] = AnyCodable(risk.rawValue) }
            if !descriptor.tags.isEmpty { entry["tags"] = AnyCodable(descriptor.tags.map { AnyCodable($0) }) }
            buckets[bucket, default: []].append(AnyCodable(entry))
        }
        let labels = ["core": "Built-in tools", "plugin": "Connected tools", "channel": "Channel tools", "mcp": "MCP server tools"]
        let groups: [AnyCodable] = ["core", "plugin", "channel", "mcp"].compactMap { source in
            guard let tools = buckets[source], !tools.isEmpty else { return nil }
            return AnyCodable([
                "id": AnyCodable(source),
                "label": AnyCodable(labels[source] ?? source),
                "source": AnyCodable(source),
                "tools": AnyCodable(tools),
            ] as [String: AnyCodable])
        }
        var payload: [String: AnyCodable] = [
            "agentId": AnyCodable(agentID),
            "profile": AnyCodable(session.profile?.rawValue ?? ToolProfileID.full.rawValue),
            "groups": AnyCodable(groups),
        ]
        if let notices = await self.options.notices?(), !notices.isEmpty {
            payload["notices"] = AnyCodable(notices.map(\.payload))
        }
        return AnyCodable(payload)
    }

    static func sourceKind(_ source: AgentToolSource) -> String {
        switch source {
        case .core: return "core"
        case .plugin: return "plugin"
        case .mcp: return "mcp"
        case .client: return "client"
        case .channel: return "channel"
        }
    }

    // MARK: - tools.invoke

    func invoke(_ request: GatewayMethodRequest) async throws -> AnyCodable? {
        guard let requested = request.stringParam("name") else {
            throw GatewayMethodError.invalidRequest("invalid tools.invoke params: name required")
        }
        if let args = request.params["args"], !args.isNull, args.dictionaryValue == nil {
            throw GatewayMethodError.invalidRequest("invalid tools.invoke params: args must be an object")
        }
        let key = request.stringParam("idempotencyKey").map { "tools.invoke:\($0)" }
        return try await self.idempotency.run(key: key) {
            try await self.performInvoke(request, requested: requested)
        }
    }

    private static func failure(_ toolName: String, code: String, message: String, requiresApproval: Bool = false, approvalID: String? = nil) -> AnyCodable {
        var payload: [String: AnyCodable] = [
            "ok": AnyCodable(false),
            "toolName": AnyCodable(toolName),
            "error": AnyCodable(["code": AnyCodable(code), "message": AnyCodable(message)]),
        ]
        if requiresApproval { payload["requiresApproval"] = AnyCodable(true) }
        if let approvalID { payload["approvalId"] = AnyCodable(approvalID) }
        return AnyCodable(payload)
    }

    private func performInvoke(_ request: GatewayMethodRequest, requested: String) async throws -> AnyCodable? {
        let registry = self.runtime.toolRegistry
        guard let tool = await registry.tool(named: requested) else {
            return Self.failure(requested, code: "not_found", message: "Tool not found: \(requested)")
        }
        let descriptor = tool.descriptor
        let toolName = tool.name
        let sessionKey = request.stringParam("sessionKey")
        var record: SessionRecord?
        if let sessionKey {
            record = await self.runtime.sessionStore?.recordForKey(sessionKey)
        }
        let agentID = self.agentID(request, record: record)
        let policy = await self.policies(sessionKey: sessionKey, record: record, agentID: agentID).session
        guard policy.allows(descriptor) else {
            return Self.failure(toolName, code: "forbidden", message: "Tool \(toolName) is not allowed by the current tool policy")
        }
        var arguments = request.params["args"]?.dictionaryValue ?? [:]
        if let violation = AgentLoop.schemaViolation(arguments, descriptor: descriptor) {
            return Self.failure(toolName, code: "validation_error", message: "Invalid arguments for \(toolName): \(violation)")
        }
        let toolCallID = "rpc_\(UUID().uuidString.lowercased())"
        var hookContext = AgentToolCallHookContext(
            runID: "tools.invoke",
            sessionKey: sessionKey ?? "",
            agentID: agentID,
            toolCallID: toolCallID,
            toolName: toolName,
            arguments: arguments,
            descriptor: descriptor
        )
        if let beforeToolCall = self.options.hooks.beforeToolCall {
            switch await beforeToolCall(hookContext) {
            case .proceed:
                break
            case .rewrite(let rewritten):
                arguments = rewritten
                hookContext.arguments = rewritten
            case .block(let reason):
                return Self.failure(toolName, code: "forbidden", message: "Tool call blocked: \(reason)")
            case .requireApproval(let approvalRequest):
                let denial = await self.resolveApproval(
                    approvalRequest,
                    request: request,
                    descriptor: descriptor,
                    toolName: toolName,
                    sessionKey: sessionKey,
                    agentID: agentID,
                    toolCallID: toolCallID,
                    arguments: arguments
                )
                if let denial {
                    return denial
                }
            }
        }
        let result = try await registry.invoke(
            AgentToolCall(id: toolCallID, name: toolName, arguments: arguments),
            context: AgentToolInvocationContext(sessionKey: sessionKey, agentID: agentID)
        )
        await self.options.hooks.afterToolCall?(hookContext, result)
        let source = Self.sourceKind(descriptor.source)
        guard !result.output.isError else {
            var failure = Self.failure(toolName, code: "internal_error", message: result.output.text.isEmpty ? "Tool \(toolName) failed" : result.output.text)
                .dictionaryValue ?? [:]
            failure["source"] = AnyCodable(source)
            return AnyCodable(failure)
        }
        let output = result.output.details ?? (try? AnyCodable(encoding: result.output.content)) ?? AnyCodable(result.output.text)
        return AnyCodable([
            "ok": AnyCodable(true),
            "toolName": AnyCodable(toolName),
            "output": output,
            "source": AnyCodable(source),
        ])
    }

    /// Approval gate of a direct invocation; returns the failure payload, or `nil` to proceed.
    ///
    /// A presented `approvalId` is honored only when `tools.invoke` minted it for this exact call
    /// (tool, grant key, session, agent and arguments) and it was not used before; it is consumed on
    /// success, so an `allow-once` decision authorizes one invocation.
    private func resolveApproval(
        _ approvalRequest: AgentToolApprovalRequest,
        request: GatewayMethodRequest,
        descriptor: AgentToolDescriptor,
        toolName: String,
        sessionKey: String?,
        agentID: String,
        toolCallID: String,
        arguments: [String: AnyCodable]
    ) async -> AnyCodable? {
        let broker = self.runtime.approvals
        let confirmed = request.params["confirm"]?.boolValue == true
        let grantKey: String
        if case .mcp(let server, let tool) = descriptor.source {
            grantKey = ApprovalBroker.mcpGrantKey(server: server, tool: tool)
        } else {
            grantKey = ApprovalBroker.pluginGrantKey(pluginID: approvalRequest.pluginID, toolName: toolName)
        }
        let binding = ToolInvokeApprovalBindings.Binding(
            toolName: toolName,
            grantKey: grantKey,
            sessionKey: sessionKey,
            agentID: agentID,
            arguments: ToolInvokeApprovalBindings.canonicalArguments(arguments)
        )
        if confirmed, let approvalID = request.stringParam("approvalId") {
            return await self.redeemApproval(approvalID, binding: binding, toolName: toolName)
        }
        let started = await broker.begin(
            presentation: .plugin(
                title: approvalRequest.title,
                description: approvalRequest.description,
                severity: approvalRequest.severity,
                pluginID: approvalRequest.pluginID,
                toolName: toolName,
                agentID: agentID,
                allowedDecisions: approvalRequest.allowedDecisions
            ),
            sessionKey: sessionKey,
            agentID: agentID,
            runID: Self.approvalRunID,
            toolCallID: toolCallID,
            grantKey: grantKey,
            timeoutMs: GatewayTimeouts.clamped(self.options.approvalTimeoutMs ?? approvalRequest.timeoutMs)
        )
        if started.isAllowed {
            return nil
        }
        guard confirmed else {
            await self.approvalBindings.bind(started.id, toolCallID: toolCallID, binding: binding)
            return Self.failure(
                toolName,
                code: "requires_approval",
                message: "Tool \(toolName) requires approval; resolve approval \(started.id) and retry with confirm: true",
                requiresApproval: true,
                approvalID: started.id
            )
        }
        let terminal = await broker.waitUntilTerminal(started)
        if terminal.isAllowed {
            return nil
        }
        return Self.failure(
            toolName,
            code: "forbidden",
            message: "Tool call was not approved (\(terminal.state.rawValue))",
            requiresApproval: true,
            approvalID: terminal.id
        )
    }

    /// `runId` recorded on approvals raised by direct invocations.
    static let approvalRunID = "tools.invoke"

    /// Redeems a presented `approvalId` for the current invocation (waiting while it is pending).
    private func redeemApproval(_ approvalID: String, binding: ToolInvokeApprovalBindings.Binding, toolName: String) async -> AnyCodable? {
        let broker = self.runtime.approvals
        let toolCallID: String
        switch await self.approvalBindings.check(approvalID, binding: binding) {
        case .accepted(let boundToolCallID):
            toolCallID = boundToolCallID
        case .unknown:
            return Self.failure(toolName, code: "forbidden", message: "approvalId \(approvalID) was not issued by tools.invoke for this call")
        case .mismatch:
            return Self.failure(toolName, code: "forbidden", message: "approvalId \(approvalID) does not match this invocation")
        case .consumed:
            return Self.failure(toolName, code: "forbidden", message: "approvalId \(approvalID) was already used")
        }
        guard let prior = await broker.get(id: approvalID),
              prior.kind == .plugin,
              prior.runID == Self.approvalRunID,
              prior.toolCallID == toolCallID,
              prior.grantKey == binding.grantKey,
              prior.presentation.toolName == binding.toolName,
              prior.sessionKey == binding.sessionKey,
              prior.agentID == binding.agentID
        else {
            return Self.failure(toolName, code: "forbidden", message: "approvalId \(approvalID) does not match this invocation")
        }
        let terminal = prior.state == .pending ? await broker.waitUntilTerminal(prior) : prior
        guard terminal.isAllowed else {
            return Self.failure(
                toolName,
                code: "forbidden",
                message: "Tool call was not approved (\(terminal.state.rawValue))",
                requiresApproval: true,
                approvalID: terminal.id
            )
        }
        // A concurrent confirmation may have used the id while this one waited.
        guard case .accepted = await self.approvalBindings.consume(approvalID, binding: binding) else {
            return Self.failure(toolName, code: "forbidden", message: "approvalId \(approvalID) was already used")
        }
        return nil
    }
}
