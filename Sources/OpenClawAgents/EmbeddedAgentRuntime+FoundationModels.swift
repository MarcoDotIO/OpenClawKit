import Foundation
import OpenClawCore
import OpenClawModels
import OpenClawProtocol
import OpenClawSkills
#if canImport(FoundationModels) && !os(tvOS) && (!os(watchOS) || compiler(>=6.4))
import FoundationModels
#endif

// Apple Foundation Models sessions built from the embedded runtime's configuration. The default
// OpenClaw path keeps tool execution host-owned (FoundationModelsProvider proposes calls and the agent
// loop approves them); these sessions run the runtime's tools inside the framework loop instead, behind
// a FoundationModelsAgentToolGate that applies the loop's policy, hooks and approvals to every call.

/// Inputs shared by Foundation Models session builders (platform-neutral so they can be tested).
struct FoundationModelsSessionPlan: Sendable {
    let systemPrompt: String
    let registry: AgentToolRegistry
    let toolNames: [String]
}

extension EmbeddedAgentRuntime {
    /// Instructions and policy-filtered tools for a Foundation Models session: the loop's base system
    /// prompt, workspace bootstrap and the skill catalog (with the jailed `read` tool), then prompt
    /// contributors (for example the memory-recall section).
    func foundationModelsSessionPlan(
        agentID: String?,
        sessionKey: String?,
        workspaceRootPath: String?,
        modelID: String
    ) async throws -> FoundationModelsSessionPlan {
        let loop = self.currentLoopConfiguration()
        let policy = self.currentToolsConfiguration().policy
        let registry = AgentToolRegistry()
        for descriptor in policy.filter(await self.toolRegistry.descriptors()) {
            if let tool = await self.toolRegistry.tool(named: descriptor.name) {
                await registry.register(tool)
            }
        }
        var sections: [String] = []
        if let base = loop.baseSystemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !base.isEmpty {
            sections.append(base)
        }
        if let root = workspaceRootPath?.trimmingCharacters(in: .whitespacesAndNewlines), !root.isEmpty {
            let workspace = URL(fileURLWithPath: root)
            let bootstrap = try await BootstrapContextLoader(workspaceRoot: workspace).loadPromptSnapshot().prompt
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !bootstrap.isEmpty {
                sections.append(bootstrap)
            }
            let skills = SkillRegistry(workspaceRoot: workspace, configuration: loop.skills ?? SkillsConfiguration())
            let catalog = try await skills.loadPromptSnapshot(options: SkillPromptOptions(mode: .catalog, contextTokenBudget: loop.contextWindowTokens))
            let prompt = catalog.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !prompt.isEmpty {
                sections.append(prompt)
                if await registry.tool(named: SkillReadTool.toolName) == nil, policy.allows(SkillReadTool.toolName) {
                    await registry.register(SkillReadTool(access: await skills.readAccess()))
                }
            }
        }
        let names = await registry.descriptors().map(\.name)
        let context = AgentPromptContext(
            runID: UUID().uuidString,
            sessionKey: sessionKey ?? "",
            agentID: SessionKey.normalizeAgentID(agentID ?? self.defaultAgentID),
            providerID: FoundationModelsProvider.providerID,
            modelID: modelID,
            capabilities: ModelProviderCapabilities(supportsStreaming: true, supportsTools: true, supportsJSONSchema: true, supportsTranscript: true),
            availableToolNames: Set(names)
        )
        sections.append(contentsOf: await self.promptContributions(for: context))
        return FoundationModelsSessionPlan(systemPrompt: sections.joined(separator: "\n\n"), registry: registry, toolNames: names)
    }

    /// Gate that applies this runtime's tool policy, closure hooks, typed hooks and approvals to tool
    /// calls running inside a Foundation Models session (snapshot of the policy and closure hooks).
    func foundationModelsToolGate(registry: AgentToolRegistry, agentID: String?, sessionKey: String?) -> FoundationModelsAgentToolGate {
        FoundationModelsAgentToolGate(
            registry: registry,
            context: AgentToolInvocationContext(
                sessionKey: sessionKey,
                agentID: SessionKey.normalizeAgentID(agentID ?? self.defaultAgentID)
            ),
            policy: self.currentToolsConfiguration().policy,
            hooks: self.currentHooks(),
            hookRegistry: self.hookRegistry,
            approvals: self.approvals
        )
    }
}

#if canImport(FoundationModels) && !os(tvOS) && (!os(watchOS) || compiler(>=6.4))
#if compiler(>=6.4)
@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
public extension EmbeddedAgentRuntime {
    /// Builds a Foundation Models session for an agent from this runtime: instructions from the base
    /// system prompt, workspace bootstrap, skill catalog and prompt contributors (skills and memory
    /// reach the model through ``OpenClawAgentProfile/systemPrompt``) and tools filtered by the runtime
    /// tool policy.
    ///
    /// Tools run inside the framework loop, but every call first passes the same checks as the agent
    /// loop (``FoundationModelsAgentToolGate``): the tool policy, the argument schema, the runtime's
    /// closure `beforeToolCall` hook and typed `before_tool_call` handlers in ``hookRegistry`` (which
    /// can block, rewrite or require approval through ``approvals``). `after_tool_call` fires after each
    /// call. The closure hooks and policy are captured when the session is built.
    /// - Parameters:
    ///   - agentID: Agent identifier (defaults to ``defaultAgentID``).
    ///   - sessionKey: Session key for tool invocations and hooks.
    ///   - workspaceRootPath: Workspace for bootstrap context and skills.
    ///   - route: On-device, Private Cloud Compute, or automatic routing.
    ///   - maxHistoryEntries: History entries kept besides instructions.
    /// - Returns: The session and any tools that could not be bridged.
    /// - Throws: Errors loading workspace bootstrap or skills.
    func makeFoundationModelsSession(
        agentID: String? = nil,
        sessionKey: String? = nil,
        workspaceRootPath: String? = nil,
        route: OpenClawAgentProfile.Route = .onDevice,
        maxHistoryEntries: Int = 40
    ) async throws -> (session: LanguageModelSession, skipped: [FoundationModelsSkippedTool]) {
        let modelID = route == .privateCloud ? FoundationModelsProvider.privateCloudComputeModelID : FoundationModelsProvider.systemModelID
        let plan = try await self.foundationModelsSessionPlan(
            agentID: agentID,
            sessionKey: sessionKey,
            workspaceRootPath: workspaceRootPath,
            modelID: modelID
        )
        return await FoundationModelsAgentSession.make(
            systemPrompt: plan.systemPrompt,
            gate: self.foundationModelsToolGate(registry: plan.registry, agentID: agentID, sessionKey: sessionKey),
            route: route,
            maxHistoryEntries: maxHistoryEntries
        )
    }
}
#endif
#endif
