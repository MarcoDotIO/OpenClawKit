import Foundation

/// Components of an embedded agent stack created by `OpenClawSDK.makeEmbeddedAgentStack(stateDirectory:credentialStore:…)`.
public struct EmbeddedAgentStack: Sendable {
    /// In-process gateway server with the runtime attached.
    public let server: GatewayServer
    /// Agent runtime.
    public let runtime: EmbeddedAgentRuntime
    /// Session store (`<stateDir>/sessions.json`).
    public let sessionStore: SessionStore
    /// Transcript store (`<stateDir>/agents/<agentId>/sessions/`).
    public let transcriptStore: JSONLSessionTranscriptStore
    /// Task ledger (`<stateDir>/tasks.json`) with `tasks.*` RPCs.
    public let taskLedger: TaskLedger
    /// Sub-agent manager (`sessions_spawn`, `subagents`, `sessions_yield` registered).
    public let subagents: SubagentManager
    /// Goal manager (`get_goal`, `create_goal`, `update_goal`, `sessions.goal.*`).
    public let goals: SessionGoalManager
    /// Progress cards (`progress_card`, `progressCard.*`).
    public let progressCards: ProgressCardStore
}

public extension OpenClawSDK {
    /// Creates a persistent embedded agent stack: session and JSONL transcript stores, a runtime with
    /// the agent loop, `ask_user`, sub-agent and goal tools, a task ledger, and an in-process gateway
    /// server with every runtime RPC registered and runtime events bridged.
    /// - Parameters:
    ///   - stateDirectory: SDK state directory.
    ///   - credentialStore: Secret store for `secrets.*`.
    ///   - modelRouter: Model router.
    ///   - agentID: Default agent id.
    ///   - workspaceRoot: Optional workspace root for `skills.*`.
    ///   - loopConfiguration: Loop settings.
    ///   - toolsConfiguration: Tool policy and search settings.
    /// - Returns: The stack.
    func makeEmbeddedAgentStack(
        stateDirectory: URL,
        credentialStore: any CredentialStore,
        modelRouter: ModelRouter = ModelRouter(),
        agentID: String = SessionKey.defaultAgentID,
        workspaceRoot: URL? = nil,
        loopConfiguration: AgentLoopConfiguration = AgentLoopConfiguration(),
        toolsConfiguration: AgentToolsConfiguration = AgentToolsConfiguration()
    ) async throws -> EmbeddedAgentStack {
        let sessionStore = SessionStore(fileURL: stateDirectory.appendingPathComponent("sessions.json"))
        try await sessionStore.load()
        let transcripts = JSONLSessionTranscriptStore(
            directory: JSONLSessionTranscriptStore.defaultDirectory(stateDirectory: stateDirectory, agentID: agentID)
        )
        let runtime = EmbeddedAgentRuntime(
            modelRouter: modelRouter,
            sessionStore: sessionStore,
            transcriptStore: transcripts,
            approvalBroker: ApprovalBroker(grantsFileURL: stateDirectory.appendingPathComponent("approval-grants.json")),
            toolsConfiguration: toolsConfiguration,
            loopConfiguration: loopConfiguration,
            defaultAgentID: agentID
        )
        await runtime.registerAskUserTool()
        let server = self.makeGatewayServer(
            sessionStore: sessionStore,
            credentialStore: credentialStore,
            modelRouter: modelRouter,
            runtime: runtime,
            workspaceRoot: workspaceRoot
        )
        await runtime.attach(to: server)
        let ledger = TaskLedger(fileURL: stateDirectory.appendingPathComponent("tasks.json"))
        await ledger.attach(to: runtime)
        await ledger.attach(to: server, runtime: runtime)
        let subagents = SubagentManager(runtime: runtime, ledger: ledger)
        await subagents.registerTools()
        let goals = SessionGoalManager(store: sessionStore)
        for tool in SessionGoalTools.tools(manager: goals) {
            await runtime.registerTool(tool)
        }
        await goals.registerGatewayMethods(on: server)
        let progressCards = ProgressCardStore()
        await runtime.registerTool(progressCards.tool)
        await progressCards.attach(to: server, runtime: runtime)
        return EmbeddedAgentStack(
            server: server,
            runtime: runtime,
            sessionStore: sessionStore,
            transcriptStore: transcripts,
            taskLedger: ledger,
            subagents: subagents,
            goals: goals,
            progressCards: progressCards
        )
    }
}
