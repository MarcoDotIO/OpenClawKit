import Foundation
import OpenClawKit
import OpenClawProtocol

// Pure port of the catalog assembly in upstream OpenClaw 2026.9.6
// `apps/ios/Sources/Chat/IOSGatewayChatTransport+ComposerCapabilities.swift`. Transports fetch `config.get`,
// `skills.status {agentId?}` and `tools.effective {sessionKey, agentId?}` on one route (see
// `OpenClawChatGatewayRequests.composerConfigGet/composerSkillsStatus/composerToolsEffective`) and hand the raw
// payloads here; the view model then gates skills, connectors, web search and execution permissions on the result.

/// Outcome of one composer capability request.
public enum OpenClawChatComposerCapabilityResponse: Sendable {
    /// The gateway does not advertise the method, or the operator lacks read scope; no request was sent.
    case unavailable
    /// The request failed or the payload did not decode.
    case failed
    /// Raw response payload.
    case loaded(Data)
}

/// Gateway facts that gate composer capability mutations.
public struct OpenClawChatComposerCapabilityAccess: Sendable, Equatable {
    /// Operator scopes granted to the connection (`operator.read`, `operator.write`, `operator.admin`).
    public var operatorScopes: Set<String>
    /// Whether the hello advertises `sessions.patch` (`nil` when the gateway does not list methods).
    public var sessionsPatchAdvertised: Bool?
    /// Whether the gateway supports the session-settings contract (`session-settings-contract`).
    public var sessionSettingsContract: Bool
    /// Whether the gateway supports compare-and-swap session settings (`session-settings-cas`).
    public var sessionSettingsCAS: Bool

    /// Creates access facts.
    public init(
        operatorScopes: Set<String>,
        sessionsPatchAdvertised: Bool?,
        sessionSettingsContract: Bool,
        sessionSettingsCAS: Bool)
    {
        self.operatorScopes = operatorScopes
        self.sessionsPatchAdvertised = sessionsPatchAdvertised
        self.sessionSettingsContract = sessionSettingsContract
        self.sessionSettingsCAS = sessionSettingsCAS
    }

    var canAdmin: Bool {
        self.operatorScopes.contains("operator.admin")
    }

    var canWrite: Bool {
        self.canAdmin || self.operatorScopes.contains("operator.write")
    }

    /// Whether the operator may read the capability surfaces (`config.get`, `skills.status`, `tools.effective`).
    public var canRead: Bool {
        self.canWrite || self.operatorScopes.contains("operator.read")
    }
}

extension OpenClawChatComposerCapabilityCatalog {
    /// Builds the composer catalog from the three capability responses.
    ///
    /// Skills come from `skills.status`, connectors from `config.get` `mcp.servers` joined with the MCP tools in
    /// `tools.effective`, and web search from `config.get` `tools.web.search.enabled`. Mutation flags follow the
    /// operator scopes: model changes need `operator.write`, effort and tool overrides `operator.admin`, and
    /// execution-permission changes the session-settings CAS contract plus `operator.write` (full permission needs
    /// `operator.admin`).
    /// - Parameters:
    ///   - config: `config.get` response.
    ///   - skills: `skills.status` response.
    ///   - tools: `tools.effective` response.
    ///   - access: Scope and capability facts for the same route.
    /// - Returns: The catalog.
    public static func build(
        config: OpenClawChatComposerCapabilityResponse,
        skills: OpenClawChatComposerCapabilityResponse,
        tools: OpenClawChatComposerCapabilityResponse,
        access: OpenClawChatComposerCapabilityAccess) -> Self
    {
        let patchAdvertised = access.sessionsPatchAdvertised == true
        let sessionSettingsAvailable = access.sessionSettingsContract && patchAdvertised
        let configSurface = ComposerSurface.decode(config, as: ComposerConfigSnapshot.self)
        let skillsSurface = ComposerSurface.decode(skills, as: SkillsStatusReport.self)
        let toolsSurface = ComposerSurface.decode(tools, as: ToolsEffectiveResult.self)
        let toolsByServer = Self.composerToolsByServer(toolsSurface.value)
        let noticesByServer = Self.composerNoticesByServer(toolsSurface.value)
        let configuredServers = configSurface.value?.runtimeConfig.mcp?.servers ?? [:]
        let connectorNames = Set(configuredServers.keys).union(toolsByServer.keys).sorted()
        let failedSurfaces = [
            configSurface.failed ? String(localized: "Web Search and Connectors") : nil,
            skillsSurface.failed ? String(localized: "Skills") : nil,
            toolsSurface.failed ? String(localized: "Tool Access") : nil,
        ].compactMap(\.self)
        let failureMessage = failedSurfaces.isEmpty
            ? nil
            : String(format: String(localized: "Could not load: %@. Retry."), failedSurfaces.joined(separator: ", "))

        return Self(
            sessionSettingsAvailable: sessionSettingsAvailable,
            modelMutationAvailable: Self.mutationAvailable(
                methodSupport: access.sessionsPatchAdvertised,
                allowedByScope: access.canWrite),
            effortMutationAvailable: Self.mutationAvailable(
                methodSupport: access.sessionsPatchAdvertised,
                allowedByScope: access.canAdmin),
            webSearchBaseEnabled: configSurface.value?.runtimeConfig.tools?.web?.search?.enabled != false,
            webSearchAvailable: configSurface.loaded,
            skills: (skillsSurface.value?.skills ?? []).map(Self.composerSkill).sorted { $0.name < $1.name },
            connectors: connectorNames.map { name in
                OpenClawChatComposerConnector(
                    name: name,
                    baseEnabled: configuredServers[name]?.enabled != false,
                    tools: toolsByServer[name] ?? [],
                    notice: noticesByServer[name])
            },
            skillsAvailable: skillsSurface.loaded,
            connectorsAvailable: configSurface.loaded,
            toolAccessAvailable: toolsSurface.loaded,
            permissionMutationAvailable: sessionSettingsAvailable && access.sessionSettingsCAS && access.canWrite,
            sessionSettingsCASAvailable: access.sessionSettingsCAS,
            toolOverrideMutationAvailable: sessionSettingsAvailable && access.sessionSettingsCAS && access.canAdmin,
            toolOverrideMutationRequiresGatewayUpgrade: sessionSettingsAvailable && !access.sessionSettingsCAS,
            canSelectFullPermission: sessionSettingsAvailable && access.sessionSettingsCAS && access.canAdmin,
            loadFailureMessage: failureMessage)
    }

    /// A mutation is available when the gateway does not list methods (`nil`), or lists it and scope allows it.
    static func mutationAvailable(methodSupport: Bool?, allowedByScope: Bool) -> Bool {
        methodSupport == nil || (methodSupport == true && allowedByScope)
    }

    static func composerSkill(_ skill: SkillStatus) -> OpenClawChatComposerSkill {
        let missing = skill.missing
        let missingDependencies = !missing.bins.isEmpty || !missing.anyBins.isEmpty ||
            !missing.env.isEmpty || !missing.config.isEmpty || !missing.os.isEmpty
        return OpenClawChatComposerSkill(
            key: skill.skillKey,
            name: skill.name,
            baseEnabled: !skill.disabled,
            missingDependencies: missingDependencies,
            blocked: skill.blockedByAllowlist == true || skill.platformIncompatible == true,
            agentFiltered: skill.blockedByAgentFilter == true)
    }

    static func composerToolsByServer(_ result: ToolsEffectiveResult?) -> [String: [OpenClawChatComposerTool]] {
        var tools: [String: [OpenClawChatComposerTool]] = [:]
        for entry in result?.groups.flatMap(\.tools) ?? [] {
            guard entry.source.stringValue == "mcp",
                  let server = entry.mcpserver?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !server.isEmpty,
                  let name = entry.mcptoolname?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty
            else { continue }
            tools[server, default: []].append(OpenClawChatComposerTool(
                name: name,
                label: entry.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? name : entry.label,
                baseEnabled: true,
                sessionDenied: entry.deniedbysession == true))
        }
        return tools.mapValues { values in
            Dictionary(grouping: values, by: \.name).values.compactMap(\.first).sorted { $0.name < $1.name }
        }
    }

    static func composerNoticesByServer(_ result: ToolsEffectiveResult?) -> [String: String] {
        var notices: [String: String] = [:]
        for notice in result?.notices ?? [] {
            for server in notice.servers ?? [] where notices[server] == nil {
                notices[server] = notice.message
            }
        }
        return notices
    }
}

private struct ComposerSurface<Value: Decodable> {
    let value: Value?
    let loaded: Bool
    let failed: Bool

    static func decode(_ response: OpenClawChatComposerCapabilityResponse, as _: Value.Type) -> Self {
        switch response {
        case let .loaded(data):
            do {
                return Self(value: try JSONDecoder().decode(Value.self, from: data), loaded: true, failed: false)
            } catch {
                return Self(value: nil, loaded: false, failed: true)
            }
        case .failed:
            return Self(value: nil, loaded: false, failed: true)
        case .unavailable:
            return Self(value: nil, loaded: false, failed: false)
        }
    }
}

private struct ComposerConfigSnapshot: Decodable {
    let runtimeConfig: ComposerRuntimeConfig
}

private struct ComposerRuntimeConfig: Decodable {
    let mcp: ComposerMCPConfig?
    let tools: ComposerToolsConfig?
}

private struct ComposerMCPConfig: Decodable {
    let servers: [String: ComposerMCPServer]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.servers = try container.decodeIfPresent([String: ComposerMCPServer].self, forKey: .servers) ?? [:]
    }

    private enum CodingKeys: String, CodingKey { case servers }
}

private struct ComposerMCPServer: Decodable {
    let enabled: Bool?
}

private struct ComposerToolsConfig: Decodable {
    let web: ComposerWebToolsConfig?
}

private struct ComposerWebToolsConfig: Decodable {
    let search: ComposerWebSearchConfig?
}

private struct ComposerWebSearchConfig: Decodable {
    let enabled: Bool?
}
