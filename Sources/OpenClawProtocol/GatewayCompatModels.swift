import Foundation

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
public struct GatewayAgentAccepted: Codable, Sendable, Equatable {
    public let runID: String
    public let status: String

    public init(runID: String, status: String = "accepted") {
        self.runID = runID
        self.status = status
    }
}

/// Wait request payload for an in-flight agent run.
public struct GatewayAgentWaitParams: Codable, Sendable, Equatable {
    public let runID: String
    public let timeoutMs: Int?

    public init(runID: String, timeoutMs: Int? = nil) {
        self.runID = runID
        self.timeoutMs = timeoutMs
    }
}

/// Completion payload for an agent run wait request.
public struct GatewayAgentWaitResult: Codable, Sendable, Equatable {
    public let runID: String
    public let status: String
    public let sessionKey: String?
    public let output: String?
    public let error: String?

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
