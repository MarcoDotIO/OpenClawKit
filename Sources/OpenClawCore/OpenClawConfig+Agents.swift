import Foundation

/// Agent runtime defaults and workspace location.
public struct AgentsConfig: Codable, Sendable, Equatable {
    public var defaultAgentID: String
    public var workspaceRoot: String
    public var skillInvocationTimeoutMs: Int
    public var agentIDs: [String]
    public var routeAgentMap: [String: String]
    public var thinkingLevel: ThinkLevel?
    public var verboseLevel: VerboseLevel?
    public var reasoningLevel: ReasoningLevel?
    public var responseUsage: UsageDisplayLevel?
    public var elevatedLevel: ElevatedLevel?
    public var groupActivation: GroupActivation?
    public var groupActivationNeedsSystemIntro: Bool
    public var sendPolicy: SendPolicy?
    public var modelOverride: String?
    public var execHost: ExecHost?
    public var execSecurity: ExecSecurity?
    public var execAsk: ExecAsk?
    public var execNode: String?

    /// Creates agent defaults.
    /// - Parameters:
    ///   - defaultAgentID: Default agent identifier.
    ///   - workspaceRoot: Workspace root path.
    ///   - skillInvocationTimeoutMs: Default timeout for skill invocation in milliseconds.
    ///   - agentIDs: Declared agent identifiers available at runtime.
    ///   - routeAgentMap: Route mapping table (`channel[:accountID[:peerID]] -> agentID`).
    public init(
        defaultAgentID: String = "main",
        workspaceRoot: String = "./workspace",
        skillInvocationTimeoutMs: Int = 30_000,
        agentIDs: [String] = [],
        routeAgentMap: [String: String] = [:],
        thinkingLevel: ThinkLevel? = nil,
        verboseLevel: VerboseLevel? = nil,
        reasoningLevel: ReasoningLevel? = nil,
        responseUsage: UsageDisplayLevel? = nil,
        elevatedLevel: ElevatedLevel? = nil,
        groupActivation: GroupActivation? = nil,
        groupActivationNeedsSystemIntro: Bool = false,
        sendPolicy: SendPolicy? = nil,
        modelOverride: String? = nil,
        execHost: ExecHost? = nil,
        execSecurity: ExecSecurity? = nil,
        execAsk: ExecAsk? = nil,
        execNode: String? = nil
    ) {
        self.defaultAgentID = defaultAgentID
        self.workspaceRoot = workspaceRoot
        self.skillInvocationTimeoutMs = max(1, skillInvocationTimeoutMs)
        var normalizedAgentIDs = Set(agentIDs.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        normalizedAgentIDs.insert(defaultAgentID)
        self.agentIDs = normalizedAgentIDs.sorted()
        self.routeAgentMap = routeAgentMap
        self.thinkingLevel = thinkingLevel
        self.verboseLevel = verboseLevel
        self.reasoningLevel = reasoningLevel
        self.responseUsage = responseUsage
        self.elevatedLevel = elevatedLevel
        self.groupActivation = groupActivation
        self.groupActivationNeedsSystemIntro = groupActivationNeedsSystemIntro
        self.sendPolicy = sendPolicy
        self.modelOverride = modelOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.execHost = execHost
        self.execSecurity = execSecurity
        self.execAsk = execAsk
        self.execNode = execNode?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private enum CodingKeys: String, CodingKey {
        case defaultAgentID
        case workspaceRoot
        case skillInvocationTimeoutMs
        case agentIDs
        case routeAgentMap
        case thinkingLevel
        case verboseLevel
        case reasoningLevel
        case responseUsage
        case elevatedLevel
        case groupActivation
        case groupActivationNeedsSystemIntro
        case sendPolicy
        case modelOverride
        case execHost
        case execSecurity
        case execAsk
        case execNode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaultAgentID = try container.decodeIfPresent(String.self, forKey: .defaultAgentID) ?? "main"
        let workspaceRoot = try container.decodeIfPresent(String.self, forKey: .workspaceRoot) ?? "./workspace"
        let skillInvocationTimeoutMs = try container.decodeIfPresent(Int.self, forKey: .skillInvocationTimeoutMs) ?? 30_000
        let agentIDs = try container.decodeIfPresent([String].self, forKey: .agentIDs) ?? []
        let routeAgentMap = try container.decodeIfPresent([String: String].self, forKey: .routeAgentMap) ?? [:]
        let thinkingLevel = try container.decodeIfPresent(ThinkLevel.self, forKey: .thinkingLevel)
        let verboseLevel = try container.decodeIfPresent(VerboseLevel.self, forKey: .verboseLevel)
        let reasoningLevel = try container.decodeIfPresent(ReasoningLevel.self, forKey: .reasoningLevel)
        let responseUsage = try container.decodeIfPresent(UsageDisplayLevel.self, forKey: .responseUsage)
        let elevatedLevel = try container.decodeIfPresent(ElevatedLevel.self, forKey: .elevatedLevel)
        let groupActivation = try container.decodeIfPresent(GroupActivation.self, forKey: .groupActivation)
        let groupActivationNeedsSystemIntro = try container.decodeIfPresent(
            Bool.self,
            forKey: .groupActivationNeedsSystemIntro
        ) ?? false
        let sendPolicy = try container.decodeIfPresent(SendPolicy.self, forKey: .sendPolicy)
        let modelOverride = try container.decodeIfPresent(String.self, forKey: .modelOverride)
        let execHost = try container.decodeIfPresent(ExecHost.self, forKey: .execHost)
        let execSecurity = try container.decodeIfPresent(ExecSecurity.self, forKey: .execSecurity)
        let execAsk = try container.decodeIfPresent(ExecAsk.self, forKey: .execAsk)
        let execNode = try container.decodeIfPresent(String.self, forKey: .execNode)
        self.init(
            defaultAgentID: defaultAgentID,
            workspaceRoot: workspaceRoot,
            skillInvocationTimeoutMs: skillInvocationTimeoutMs,
            agentIDs: agentIDs,
            routeAgentMap: routeAgentMap,
            thinkingLevel: thinkingLevel,
            verboseLevel: verboseLevel,
            reasoningLevel: reasoningLevel,
            responseUsage: responseUsage,
            elevatedLevel: elevatedLevel,
            groupActivation: groupActivation,
            groupActivationNeedsSystemIntro: groupActivationNeedsSystemIntro,
            sendPolicy: sendPolicy,
            modelOverride: modelOverride,
            execHost: execHost,
            execSecurity: execSecurity,
            execAsk: execAsk,
            execNode: execNode
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.defaultAgentID, forKey: .defaultAgentID)
        try container.encode(self.workspaceRoot, forKey: .workspaceRoot)
        try container.encode(self.skillInvocationTimeoutMs, forKey: .skillInvocationTimeoutMs)
        try container.encode(self.agentIDs, forKey: .agentIDs)
        try container.encode(self.routeAgentMap, forKey: .routeAgentMap)
        try container.encodeIfPresent(self.thinkingLevel, forKey: .thinkingLevel)
        try container.encodeIfPresent(self.verboseLevel, forKey: .verboseLevel)
        try container.encodeIfPresent(self.reasoningLevel, forKey: .reasoningLevel)
        try container.encodeIfPresent(self.responseUsage, forKey: .responseUsage)
        try container.encodeIfPresent(self.elevatedLevel, forKey: .elevatedLevel)
        try container.encodeIfPresent(self.groupActivation, forKey: .groupActivation)
        try container.encode(self.groupActivationNeedsSystemIntro, forKey: .groupActivationNeedsSystemIntro)
        try container.encodeIfPresent(self.sendPolicy, forKey: .sendPolicy)
        try container.encodeIfPresent(self.modelOverride, forKey: .modelOverride)
        try container.encodeIfPresent(self.execHost, forKey: .execHost)
        try container.encodeIfPresent(self.execSecurity, forKey: .execSecurity)
        try container.encodeIfPresent(self.execAsk, forKey: .execAsk)
        try container.encodeIfPresent(self.execNode, forKey: .execNode)
    }

    /// Creates a route map key for channel/account/peer matching.
    /// - Parameters:
    ///   - channel: Channel identifier.
    ///   - accountID: Optional account identifier.
    ///   - peerID: Optional peer identifier.
    /// - Returns: Canonical route key.
    public static func routeKey(channel: String, accountID: String? = nil, peerID: String? = nil) -> String {
        [channel, accountID, peerID]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ":")
    }

    /// Resolves the effective agent ID for the provided routing context.
    /// - Parameter context: Routing context for inbound message/session.
    /// - Returns: Mapped or default agent identifier.
    public func resolvedAgentID(for context: SessionRoutingContext) -> String {
        let channel = context.channel.trimmingCharacters(in: .whitespacesAndNewlines)
        let accountID = context.accountID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let peerID = context.peerID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidateKeys = [
            Self.routeKey(channel: channel, accountID: accountID, peerID: peerID),
            Self.routeKey(channel: channel, accountID: accountID, peerID: nil),
            Self.routeKey(channel: channel),
        ].filter { !$0.isEmpty }

        let available = Set(self.agentIDs)
        for key in candidateKeys {
            guard let mapped = self.routeAgentMap[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !mapped.isEmpty
            else {
                continue
            }
            if available.isEmpty || available.contains(mapped) {
                return mapped
            }
        }
        return self.defaultAgentID
    }
}
