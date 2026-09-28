import Foundation

// OpenClawKit-owned gateway payloads.
//
// Everything in this file is SDK-local: these types back the in-process `GatewayServer`
// (OpenClawGateway) and the typed `GatewayClient` helpers. They are NOT generated from upstream
// OpenClaw and must never share a name with a type in the vendored GatewayModels.swift
// (Scripts/protocol-gen-swift.mjs enforces this with a collision guard).
//
// Overlapping upstream (OpenClaw 2026.9.6) equivalents, for callers that talk to a real gateway:
// - GatewayAgentRequest            <-> AgentParams (`agent`); the server also accepts AgentParams.
// - GatewayAgentAccepted           <-> `agent` accepted payload `{ runId, status }`.
// - GatewayAgentWaitParams/Result  <-> AgentWaitParams (`agent.wait`, wire key `runId`).
// - GatewaySessionPatchParams      <-> SessionsPatchParams (`model`/`agentId` aliases are accepted).
// - GatewaySessionKeyParams        <-> SessionsResetParams / SessionsDeleteParams.
// - GatewayModelsListResult        <-> ModelsListResult (`models.list` rows also carry ModelChoice keys).
// - GatewaySecret*                 <-> SecretsStore* (`secrets.store.*`); `secrets.*` stay SDK extensions.
// - GatewaySkill*                  <-> no core equivalent (`skills.list`/`skills.invoke` are SDK extensions).
// - GatewayBrowserRequestParams    <-> extensions/browser `browser.request` (plugin-owned upstream).

/// Empty request or response payload (`{}`).
public struct EmptyPayload: Codable, Sendable, Equatable {
    /// Creates an empty payload marker.
    public init() {}
}

/// JSON bridge used for encoding and decoding typed gateway payloads through `AnyCodable`.
public enum GatewayPayloadCodec {
    /// Encodes a typed payload into an `AnyCodable` JSON wrapper.
    /// - Parameter value: Encodable payload value.
    /// - Returns: Type-erased JSON payload.
    public static func encode<T: Encodable>(_ value: T) throws -> AnyCodable {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(AnyCodable.self, from: data)
    }

    /// Decodes a typed payload from an `AnyCodable` request/response payload.
    /// - Parameters:
    ///   - type: Target payload type.
    ///   - payload: Type-erased JSON payload.
    /// - Returns: Decoded typed payload.
    public static func decode<T: Decodable>(_ type: T.Type, from payload: AnyCodable?) throws -> T {
        let decoder = JSONDecoder()
        if let payload {
            let data = try JSONEncoder().encode(payload)
            return try decoder.decode(type, from: data)
        }
        if let emptyObject = "{}".data(using: .utf8), let decoded = try? decoder.decode(type, from: emptyObject) {
            return decoded
        }
        let nullPayload = Data("null".utf8)
        return try decoder.decode(type, from: nullPayload)
    }
}

/// Request payload for in-process agent execution.
public struct GatewayAgentRequest: Codable, Sendable, Equatable {
    public let sessionKey: String
    public let prompt: String?
    public let message: String?
    public let modelProviderID: String?
    public let modelID: String?
    public let timeoutMs: Int?
    public let deliver: Bool?

    public init(
        sessionKey: String,
        prompt: String? = nil,
        message: String? = nil,
        modelProviderID: String? = nil,
        modelID: String? = nil,
        timeoutMs: Int? = nil,
        deliver: Bool? = nil
    ) {
        self.sessionKey = sessionKey
        self.prompt = prompt
        self.message = message
        self.modelProviderID = modelProviderID
        self.modelID = modelID
        self.timeoutMs = timeoutMs
        self.deliver = deliver
    }
}

/// Accepted gateway response for an agent run.
///
/// Encodes the upstream wire key `runId`; decoding also accepts the legacy SDK key `runID`.
public struct GatewayAgentAccepted: Codable, Sendable, Equatable {
    /// Identifier of the started run, used with `agent.wait`.
    public let runID: String
    /// Acceptance status (`accepted`).
    public let status: String

    /// Creates an accepted-run payload.
    /// - Parameters:
    ///   - runID: Identifier of the started run.
    ///   - status: Acceptance status.
    public init(runID: String, status: String = "accepted") {
        self.runID = runID
        self.status = status
    }

    private enum CodingKeys: String, CodingKey {
        case runID = "runId"
        case status
    }

    /// Decodes the payload, accepting both `runId` and the legacy `runID` key.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.runID = try GatewayLegacyRunIDKey.decodeRunID(from: decoder, container: container, key: .runID)
        self.status = try container.decode(String.self, forKey: .status)
    }
}

/// Wait request payload for an in-flight agent run.
///
/// Encodes the upstream `AgentWaitParams` wire keys (`runId`, `timeoutMs`); decoding also accepts `runID`.
public struct GatewayAgentWaitParams: Codable, Sendable, Equatable {
    /// Identifier of the run to wait for.
    public let runID: String
    /// Optional wait timeout in milliseconds.
    public let timeoutMs: Int?

    /// Creates a wait request.
    /// - Parameters:
    ///   - runID: Identifier of the run to wait for.
    ///   - timeoutMs: Optional wait timeout in milliseconds.
    public init(runID: String, timeoutMs: Int? = nil) {
        self.runID = runID
        self.timeoutMs = timeoutMs
    }

    private enum CodingKeys: String, CodingKey {
        case runID = "runId"
        case timeoutMs
    }

    /// Decodes the payload, accepting both `runId` and the legacy `runID` key.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.runID = try GatewayLegacyRunIDKey.decodeRunID(from: decoder, container: container, key: .runID)
        self.timeoutMs = try container.decodeIfPresent(Int.self, forKey: .timeoutMs)
    }
}

/// Completion payload for an agent run wait request.
///
/// Encodes the upstream wire key `runId`; decoding also accepts the legacy SDK key `runID`.
public struct GatewayAgentWaitResult: Codable, Sendable, Equatable {
    /// Identifier of the run.
    public let runID: String
    /// Terminal or interim status (`ok`, `error`, `timeout`).
    public let status: String
    /// Session key the run belongs to.
    public let sessionKey: String?
    /// Final assistant output when the run succeeded.
    public let output: String?
    /// Error message when the run failed.
    public let error: String?

    /// Creates a wait result.
    /// - Parameters:
    ///   - runID: Identifier of the run.
    ///   - status: Run status.
    ///   - sessionKey: Session key the run belongs to.
    ///   - output: Final assistant output.
    ///   - error: Error message.
    public init(
        runID: String,
        status: String,
        sessionKey: String? = nil,
        output: String? = nil,
        error: String? = nil
    ) {
        self.runID = runID
        self.status = status
        self.sessionKey = sessionKey
        self.output = output
        self.error = error
    }

    private enum CodingKeys: String, CodingKey {
        case runID = "runId"
        case status
        case sessionKey
        case output
        case error
    }

    /// Decodes the payload, accepting both `runId` and the legacy `runID` key.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.runID = try GatewayLegacyRunIDKey.decodeRunID(from: decoder, container: container, key: .runID)
        self.status = try container.decode(String.self, forKey: .status)
        self.sessionKey = try container.decodeIfPresent(String.self, forKey: .sessionKey)
        self.output = try container.decodeIfPresent(String.self, forKey: .output)
        self.error = try container.decodeIfPresent(String.self, forKey: .error)
    }
}

/// Decoding helper for the legacy `runID` wire key used before OpenClawKit 2026.3.0.
private struct GatewayLegacyRunIDKey: CodingKey {
    static let legacy = GatewayLegacyRunIDKey(stringValue: "runID")

    let stringValue: String
    var intValue: Int? { nil }

    init(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue _: Int) {
        nil
    }

    static func decodeRunID<Key: CodingKey>(
        from decoder: Decoder,
        container: KeyedDecodingContainer<Key>,
        key: Key
    ) throws -> String {
        if let runID = try container.decodeIfPresent(String.self, forKey: key) {
            return runID
        }
        let legacy = try decoder.container(keyedBy: GatewayLegacyRunIDKey.self)
        return try legacy.decode(String.self, forKey: .legacy)
    }
}

/// Typed session summary returned by gateway session methods.
public struct GatewaySessionInfo: Codable, Sendable, Equatable {
    public let key: String
    public let agentID: String
    public let updatedAtMs: Int
    public let channel: String?
    public let accountID: String?
    public let peerID: String?
    public let label: String?
    public let modelOverride: String?
    public let thinkingLevel: String?
    public let verboseLevel: String?
    public let reasoningLevel: String?
    public let responseUsage: String?
    public let elevatedLevel: String?
    public let groupActivation: String?
    public let sendPolicy: String?
    public let execHost: String?
    public let execSecurity: String?
    public let execAsk: String?
    public let execNode: String?

    public init(
        key: String,
        agentID: String,
        updatedAtMs: Int,
        channel: String? = nil,
        accountID: String? = nil,
        peerID: String? = nil,
        label: String? = nil,
        modelOverride: String? = nil,
        thinkingLevel: String? = nil,
        verboseLevel: String? = nil,
        reasoningLevel: String? = nil,
        responseUsage: String? = nil,
        elevatedLevel: String? = nil,
        groupActivation: String? = nil,
        sendPolicy: String? = nil,
        execHost: String? = nil,
        execSecurity: String? = nil,
        execAsk: String? = nil,
        execNode: String? = nil
    ) {
        self.key = key
        self.agentID = agentID
        self.updatedAtMs = updatedAtMs
        self.channel = channel
        self.accountID = accountID
        self.peerID = peerID
        self.label = label
        self.modelOverride = modelOverride
        self.thinkingLevel = thinkingLevel
        self.verboseLevel = verboseLevel
        self.reasoningLevel = reasoningLevel
        self.responseUsage = responseUsage
        self.elevatedLevel = elevatedLevel
        self.groupActivation = groupActivation
        self.sendPolicy = sendPolicy
        self.execHost = execHost
        self.execSecurity = execSecurity
        self.execAsk = execAsk
        self.execNode = execNode
    }
}

/// List response for gateway session enumeration.
public struct GatewaySessionListResult: Codable, Sendable, Equatable {
    public let sessions: [GatewaySessionInfo]

    public init(sessions: [GatewaySessionInfo]) {
        self.sessions = sessions
    }
}

/// Lookup request for one session.
public struct GatewaySessionGetParams: Codable, Sendable, Equatable {
    public let key: String

    public init(key: String) {
        self.key = key
    }
}

/// Lookup response for one session.
public struct GatewaySessionGetResult: Codable, Sendable, Equatable {
    public let session: GatewaySessionInfo?

    public init(session: GatewaySessionInfo?) {
        self.session = session
    }
}

/// Patch request for session mutation.
public struct GatewaySessionPatchParams: Codable, Sendable, Equatable {
    public let key: String
    public let agentID: String?
    public let label: String?
    public let modelOverride: String?
    public let thinkingLevel: String?
    public let verboseLevel: String?
    public let reasoningLevel: String?
    public let responseUsage: String?
    public let elevatedLevel: String?
    public let groupActivation: String?
    public let sendPolicy: String?
    public let execHost: String?
    public let execSecurity: String?
    public let execAsk: String?
    public let execNode: String?

    public init(
        key: String,
        agentID: String? = nil,
        label: String? = nil,
        modelOverride: String? = nil,
        thinkingLevel: String? = nil,
        verboseLevel: String? = nil,
        reasoningLevel: String? = nil,
        responseUsage: String? = nil,
        elevatedLevel: String? = nil,
        groupActivation: String? = nil,
        sendPolicy: String? = nil,
        execHost: String? = nil,
        execSecurity: String? = nil,
        execAsk: String? = nil,
        execNode: String? = nil
    ) {
        self.key = key
        self.agentID = agentID
        self.label = label
        self.modelOverride = modelOverride
        self.thinkingLevel = thinkingLevel
        self.verboseLevel = verboseLevel
        self.reasoningLevel = reasoningLevel
        self.responseUsage = responseUsage
        self.elevatedLevel = elevatedLevel
        self.groupActivation = groupActivation
        self.sendPolicy = sendPolicy
        self.execHost = execHost
        self.execSecurity = execSecurity
        self.execAsk = execAsk
        self.execNode = execNode
    }
}

/// Session key payload used by reset/delete methods.
public struct GatewaySessionKeyParams: Codable, Sendable, Equatable {
    public let key: String

    public init(key: String) {
        self.key = key
    }
}

/// Mutation response for gateway session operations.
public struct GatewaySessionMutationResult: Codable, Sendable, Equatable {
    public let ok: Bool
    public let key: String
    public let session: GatewaySessionInfo?
    public let deleted: Bool?

    public init(ok: Bool = true, key: String, session: GatewaySessionInfo? = nil, deleted: Bool? = nil) {
        self.ok = ok
        self.key = key
        self.session = session
        self.deleted = deleted
    }
}

/// Catalog entry returned by `models.list`.
public struct GatewayModelCatalogEntry: Codable, Sendable, Equatable {
    public let providerID: String
    public let modelID: String
    public let displayName: String
    public let api: String?
    public let authMode: String?

    public init(
        providerID: String,
        modelID: String,
        displayName: String,
        api: String? = nil,
        authMode: String? = nil
    ) {
        self.providerID = providerID
        self.modelID = modelID
        self.displayName = displayName
        self.api = api
        self.authMode = authMode
    }
}

/// Response payload for `models.list`.
public struct GatewayModelsListResult: Codable, Sendable, Equatable {
    public let models: [GatewayModelCatalogEntry]

    public init(models: [GatewayModelCatalogEntry]) {
        self.models = models
    }
}

/// Skill summary returned by `skills.list`.
public struct GatewaySkillDescriptor: Codable, Sendable, Equatable {
    public let name: String
    public let description: String
    public let source: String
    public let entrypoint: String?
    public let userInvocable: Bool

    public init(
        name: String,
        description: String,
        source: String,
        entrypoint: String? = nil,
        userInvocable: Bool
    ) {
        self.name = name
        self.description = description
        self.source = source
        self.entrypoint = entrypoint
        self.userInvocable = userInvocable
    }
}

/// Response payload for `skills.list`.
public struct GatewaySkillsListResult: Codable, Sendable, Equatable {
    public let skills: [GatewaySkillDescriptor]

    public init(skills: [GatewaySkillDescriptor]) {
        self.skills = skills
    }
}

/// Request payload for `skills.invoke`.
public struct GatewaySkillInvokeParams: Codable, Sendable, Equatable {
    public let name: String
    public let input: String

    public init(name: String, input: String) {
        self.name = name
        self.input = input
    }
}

/// Response payload for `skills.invoke`.
public struct GatewaySkillInvokeResult: Codable, Sendable, Equatable {
    public let skillName: String
    public let output: String
    public let executorID: String?
    public let durationMs: Int?

    public init(skillName: String, output: String, executorID: String? = nil, durationMs: Int? = nil) {
        self.skillName = skillName
        self.output = output
        self.executorID = executorID
        self.durationMs = durationMs
    }
}

/// Secret descriptor returned by `secrets.list`.
public struct GatewaySecretDescriptor: Codable, Sendable, Equatable {
    public let key: String

    public init(key: String) {
        self.key = key
    }
}

/// Response payload for `secrets.list`.
public struct GatewaySecretsListResult: Codable, Sendable, Equatable {
    public let secrets: [GatewaySecretDescriptor]

    public init(secrets: [GatewaySecretDescriptor]) {
        self.secrets = secrets
    }
}

/// Mutation request payload for `secrets.set`.
public struct GatewaySecretSetParams: Codable, Sendable, Equatable {
    public let key: String
    public let value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

/// Mutation request payload for `secrets.delete`.
public struct GatewaySecretDeleteParams: Codable, Sendable, Equatable {
    public let key: String

    public init(key: String) {
        self.key = key
    }
}

/// Mutation result payload returned by secret mutation methods.
public struct GatewaySecretMutationResult: Codable, Sendable, Equatable {
    public let ok: Bool
    public let key: String
    public let deleted: Bool?

    public init(ok: Bool = true, key: String, deleted: Bool? = nil) {
        self.ok = ok
        self.key = key
        self.deleted = deleted
    }
}

/// Typed request for `browser.request`.
public struct GatewayBrowserRequestParams: Codable, Sendable, Equatable {
    public let method: String
    public let path: String
    public let query: [String: String]?
    public let body: AnyCodable?
    public let timeoutMs: Int?
    public let workspaceRoot: String?
    public let spawnedWorkspaceRoot: String?

    public init(
        method: String,
        path: String,
        query: [String: String]? = nil,
        body: AnyCodable? = nil,
        timeoutMs: Int? = nil,
        workspaceRoot: String? = nil,
        spawnedWorkspaceRoot: String? = nil
    ) {
        self.method = method
        self.path = path
        self.query = query
        self.body = body
        self.timeoutMs = timeoutMs
        self.workspaceRoot = workspaceRoot
        self.spawnedWorkspaceRoot = spawnedWorkspaceRoot
    }
}

/// Typed response for `browser.request`.
public struct GatewayBrowserResponse: Codable, Sendable, Equatable {
    public let status: Int
    public let headers: [String: String]
    public let body: AnyCodable?

    public init(status: Int, headers: [String: String] = [:], body: AnyCodable? = nil) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}
