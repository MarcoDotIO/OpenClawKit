import Foundation
import OpenClawProtocol

// Typed Agent2Agent (A2A) 1.0 JSON-RPC models (port of upstream `extensions/a2a/src/protocol.ts`).

/// Message author role (`ROLE_USER` / `ROLE_AGENT`; A2A 0.3 `user` / `agent` also decode).
public enum A2ARole: String, Codable, Sendable, Equatable, CaseIterable {
    /// The requesting agent.
    case user = "ROLE_USER"
    /// The responding agent.
    case agent = "ROLE_AGENT"

    /// Decodes a role, accepting the A2A 0.3 lowercase spellings.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "ROLE_USER", "user": self = .user
        case "ROLE_AGENT", "agent": self = .agent
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown A2A role \(raw)"))
        }
    }
}

/// One message or artifact part.
public struct A2APart: Codable, Sendable, Equatable {
    /// Part payload.
    public enum Content: Sendable, Equatable {
        /// Plain text.
        case text(String)
        /// Structured JSON data.
        case data(AnyCodable)
        /// A file referenced by URL.
        case url(String)
        /// Inline base64 bytes.
        case raw(String)
    }

    /// Part payload.
    public var content: Content
    /// Part metadata.
    public var metadata: [String: AnyCodable]?

    /// Creates a part.
    /// - Parameters:
    ///   - content: Payload.
    ///   - metadata: Metadata.
    public init(_ content: Content, metadata: [String: AnyCodable]? = nil) {
        self.content = content
        self.metadata = metadata
    }

    /// Creates a text part.
    /// - Parameter text: Text.
    /// - Returns: Part.
    public static func text(_ text: String) -> A2APart {
        A2APart(.text(text))
    }

    /// Text payload, when this is a text part.
    public var text: String? {
        if case .text(let value) = self.content { return value }
        return nil
    }

    private enum CodingKeys: String, CodingKey {
        case text, data, url, raw, metadata
    }

    /// Decodes a part (`text`, `data`, `url` or `raw`).
    /// - Parameter decoder: Source decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.metadata = try container.decodeIfPresent([String: AnyCodable].self, forKey: .metadata)
        if let text = try container.decodeIfPresent(String.self, forKey: .text) {
            self.content = .text(text)
        } else if container.contains(.data) {
            self.content = .data(try container.decode(AnyCodable.self, forKey: .data))
        } else if let url = try container.decodeIfPresent(String.self, forKey: .url) {
            self.content = .url(url)
        } else if let raw = try container.decodeIfPresent(String.self, forKey: .raw) {
            self.content = .raw(raw)
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "A2A part needs text, data, url or raw"))
        }
    }

    /// Encodes the part.
    /// - Parameter encoder: Target encoder.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self.content {
        case .text(let value): try container.encode(value, forKey: .text)
        case .data(let value): try container.encode(value, forKey: .data)
        case .url(let value): try container.encode(value, forKey: .url)
        case .raw(let value): try container.encode(value, forKey: .raw)
        }
        try container.encodeIfPresent(self.metadata, forKey: .metadata)
    }
}

/// An A2A message.
public struct A2AMessage: Codable, Sendable, Equatable {
    /// Message id.
    public var messageId: String
    /// Conversation context id (`^[A-Za-z0-9._:-]{1,128}$`).
    public var contextId: String?
    /// Task the message belongs to.
    public var taskId: String?
    /// Author role.
    public var role: A2ARole
    /// Message parts.
    public var parts: [A2APart]
    /// Message metadata.
    public var metadata: [String: AnyCodable]?

    /// Creates a message.
    /// - Parameters:
    ///   - messageId: Message id.
    ///   - contextId: Context id.
    ///   - taskId: Task id.
    ///   - role: Role.
    ///   - parts: Parts.
    ///   - metadata: Metadata.
    public init(
        messageId: String = UUID().uuidString.lowercased(),
        contextId: String? = nil,
        taskId: String? = nil,
        role: A2ARole,
        parts: [A2APart],
        metadata: [String: AnyCodable]? = nil
    ) {
        self.messageId = messageId
        self.contextId = contextId
        self.taskId = taskId
        self.role = role
        self.parts = parts
        self.metadata = metadata
    }

    /// Text parts joined with newlines.
    public var text: String {
        self.parts.compactMap(\.text).joined(separator: "\n")
    }
}

/// Task lifecycle state.
public enum A2ATaskState: String, Codable, Sendable, Equatable, CaseIterable {
    /// Accepted, not started.
    case submitted = "TASK_STATE_SUBMITTED"
    /// Running.
    case working = "TASK_STATE_WORKING"
    /// Finished with a reply.
    case completed = "TASK_STATE_COMPLETED"
    /// Failed.
    case failed = "TASK_STATE_FAILED"
    /// Canceled.
    case canceled = "TASK_STATE_CANCELED"
    /// Refused (for example slash commands from peers).
    case rejected = "TASK_STATE_REJECTED"

    /// Whether the state is terminal.
    public var isTerminal: Bool {
        self != .submitted && self != .working
    }
}

/// Task status.
public struct A2ATaskStatus: Codable, Sendable, Equatable {
    /// State.
    public var state: A2ATaskState
    /// ISO-8601 timestamp.
    public var timestamp: String
    /// Status message (terminal states).
    public var message: A2AMessage?

    /// Creates a status.
    /// - Parameters:
    ///   - state: State.
    ///   - timestamp: ISO-8601 timestamp (default now).
    ///   - message: Status message.
    public init(state: A2ATaskState, timestamp: String = A2AProtocol.timestamp(), message: A2AMessage? = nil) {
        self.state = state
        self.timestamp = timestamp
        self.message = message
    }
}

/// Task output artifact.
public struct A2AArtifact: Codable, Sendable, Equatable {
    /// Artifact id.
    public var artifactId: String
    /// Artifact name.
    public var name: String?
    /// Artifact parts.
    public var parts: [A2APart]

    /// Creates an artifact.
    /// - Parameters:
    ///   - artifactId: Artifact id.
    ///   - name: Name.
    ///   - parts: Parts.
    public init(artifactId: String = UUID().uuidString.lowercased(), name: String? = nil, parts: [A2APart]) {
        self.artifactId = artifactId
        self.name = name
        self.parts = parts
    }
}

/// An A2A task.
public struct A2ATask: Codable, Sendable, Equatable {
    /// Task id.
    public var id: String
    /// Context id.
    public var contextId: String
    /// Status.
    public var status: A2ATaskStatus
    /// Artifacts (the reply text on completion).
    public var artifacts: [A2AArtifact]
    /// Message history.
    public var history: [A2AMessage]

    /// Creates a task.
    /// - Parameters:
    ///   - id: Task id.
    ///   - contextId: Context id.
    ///   - status: Status.
    ///   - artifacts: Artifacts.
    ///   - history: History.
    public init(
        id: String = UUID().uuidString.lowercased(),
        contextId: String,
        status: A2ATaskStatus = A2ATaskStatus(state: .submitted),
        artifacts: [A2AArtifact] = [],
        history: [A2AMessage] = []
    ) {
        self.id = id
        self.contextId = contextId
        self.status = status
        self.artifacts = artifacts
        self.history = history
    }

    /// Artifact text parts joined with newlines (the peer's reply).
    public var replyText: String? {
        let text = self.artifacts.flatMap(\.parts).compactMap(\.text).joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    private enum CodingKeys: String, CodingKey {
        case id, contextId, status, artifacts, history
    }

    /// Decodes a task leniently (peers may omit everything but `id`).
    /// - Parameter decoder: Source decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.contextId = try container.decodeIfPresent(String.self, forKey: .contextId) ?? ""
        self.status = try container.decodeIfPresent(A2ATaskStatus.self, forKey: .status) ?? A2ATaskStatus(state: .submitted, timestamp: "")
        self.artifacts = try container.decodeIfPresent([A2AArtifact].self, forKey: .artifacts) ?? []
        self.history = try container.decodeIfPresent([A2AMessage].self, forKey: .history) ?? []
    }
}

/// `SendMessage` configuration.
public struct A2ASendMessageConfiguration: Codable, Sendable, Equatable {
    /// Accepted output MIME types.
    public var acceptedOutputModes: [String]?
    /// History entries to return.
    public var historyLength: Int?
    /// Return the working task immediately instead of blocking for the reply.
    public var returnImmediately: Bool?

    /// Creates a configuration.
    /// - Parameters:
    ///   - acceptedOutputModes: Output modes.
    ///   - historyLength: History length.
    ///   - returnImmediately: Non-blocking send.
    public init(acceptedOutputModes: [String]? = nil, historyLength: Int? = nil, returnImmediately: Bool? = nil) {
        self.acceptedOutputModes = acceptedOutputModes
        self.historyLength = historyLength
        self.returnImmediately = returnImmediately
    }
}

/// `SendMessage` parameters.
public struct A2ASendMessageParams: Codable, Sendable, Equatable {
    /// Message to send.
    public var message: A2AMessage
    /// Send configuration.
    public var configuration: A2ASendMessageConfiguration?
    /// Tenant.
    public var tenant: String?
    /// Request metadata.
    public var metadata: [String: AnyCodable]?

    /// Creates parameters.
    /// - Parameters:
    ///   - message: Message.
    ///   - configuration: Configuration.
    ///   - tenant: Tenant.
    ///   - metadata: Metadata.
    public init(
        message: A2AMessage,
        configuration: A2ASendMessageConfiguration? = nil,
        tenant: String? = nil,
        metadata: [String: AnyCodable]? = nil
    ) {
        self.message = message
        self.configuration = configuration
        self.tenant = tenant
        self.metadata = metadata
    }
}

/// `SendMessage` result (`task` or, from some peers, a direct `message`).
public struct A2ASendMessageResult: Codable, Sendable, Equatable {
    /// Created task.
    public var task: A2ATask?
    /// Direct reply message.
    public var message: A2AMessage?

    /// Creates a result.
    /// - Parameters:
    ///   - task: Task.
    ///   - message: Direct message.
    public init(task: A2ATask? = nil, message: A2AMessage? = nil) {
        self.task = task
        self.message = message
    }
}

/// `GetTask` parameters.
public struct A2AGetTaskParams: Codable, Sendable, Equatable {
    /// Task id.
    public var id: String
    /// History entries to return.
    public var historyLength: Int?
    /// Tenant.
    public var tenant: String?

    /// Creates parameters.
    /// - Parameters:
    ///   - id: Task id.
    ///   - historyLength: History length.
    ///   - tenant: Tenant.
    public init(id: String, historyLength: Int? = nil, tenant: String? = nil) {
        self.id = id
        self.historyLength = historyLength
        self.tenant = tenant
    }
}

/// Public Agent Card served at `/.well-known/agent-card.json`.
public struct A2AAgentCard: Codable, Sendable, Equatable {
    /// One JSON-RPC interface.
    public struct Interface: Codable, Sendable, Equatable {
        /// Endpoint URL (`<origin>/a2a/v1`).
        public var url: String
        /// Protocol binding (`JSONRPC`).
        public var protocolBinding: String
        /// Protocol version (`1.0`).
        public var protocolVersion: String

        /// Creates an interface.
        /// - Parameters:
        ///   - url: Endpoint URL.
        ///   - protocolBinding: Binding.
        ///   - protocolVersion: Version.
        public init(url: String, protocolBinding: String = "JSONRPC", protocolVersion: String = A2AProtocol.version) {
            self.url = url
            self.protocolBinding = protocolBinding
            self.protocolVersion = protocolVersion
        }
    }

    /// Card capabilities.
    public struct Capabilities: Codable, Sendable, Equatable {
        /// Streaming support (`false`).
        public var streaming: Bool
        /// Push notification support (`false`).
        public var pushNotifications: Bool

        /// Creates capabilities.
        /// - Parameters:
        ///   - streaming: Streaming.
        ///   - pushNotifications: Push notifications.
        public init(streaming: Bool = false, pushNotifications: Bool = false) {
            self.streaming = streaming
            self.pushNotifications = pushNotifications
        }
    }

    /// One advertised skill (an exposed agent id).
    public struct Skill: Codable, Sendable, Equatable {
        /// Skill id.
        public var id: String
        /// Skill name.
        public var name: String
        /// Skill description.
        public var description: String
        /// Tags.
        public var tags: [String]

        /// Creates a skill.
        /// - Parameters:
        ///   - id: Id.
        ///   - name: Name.
        ///   - description: Description.
        ///   - tags: Tags.
        public init(id: String, name: String, description: String, tags: [String]) {
            self.id = id
            self.name = name
            self.description = description
            self.tags = tags
        }
    }

    /// Default card version when the host does not supply one.
    public static let defaultVersion = "2026.3.0"

    /// Agent name.
    public var name: String
    /// Agent description.
    public var description: String
    /// Interfaces.
    public var supportedInterfaces: [Interface]
    /// Card version.
    public var version: String
    /// Capabilities.
    public var capabilities: Capabilities
    /// Accepted input MIME types.
    public var defaultInputModes: [String]
    /// Produced output MIME types.
    public var defaultOutputModes: [String]
    /// Skills.
    public var skills: [Skill]

    /// Creates a card.
    /// - Parameters:
    ///   - name: Name.
    ///   - description: Description.
    ///   - supportedInterfaces: Interfaces.
    ///   - version: Version.
    ///   - capabilities: Capabilities.
    ///   - defaultInputModes: Input modes.
    ///   - defaultOutputModes: Output modes.
    ///   - skills: Skills.
    public init(
        name: String,
        description: String,
        supportedInterfaces: [Interface],
        version: String = A2AAgentCard.defaultVersion,
        capabilities: Capabilities = Capabilities(),
        defaultInputModes: [String] = ["text/plain"],
        defaultOutputModes: [String] = ["text/plain"],
        skills: [Skill] = []
    ) {
        self.name = name
        self.description = description
        self.supportedInterfaces = supportedInterfaces
        self.version = version
        self.capabilities = capabilities
        self.defaultInputModes = defaultInputModes
        self.defaultOutputModes = defaultOutputModes
        self.skills = skills
    }
}

/// JSON-RPC request id (`string`, `number` or `null`).
public enum A2AJSONRPCID: Codable, Sendable, Equatable, Hashable {
    /// String id.
    case string(String)
    /// Numeric id.
    case number(Double)
    /// `null` id.
    case null

    /// Decodes an id.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            self = .number(try container.decode(Double.self))
        }
    }

    /// Encodes the id (integral numbers without a fraction).
    /// - Parameter encoder: Target encoder.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value):
            if value.rounded() == value, let int = Int64(exactly: value) {
                try container.encode(int)
            } else {
                try container.encode(value)
            }
        case .null: try container.encodeNil()
        }
    }
}

/// JSON-RPC error object.
public struct A2AJSONRPCError: Codable, Sendable, Equatable, Error, LocalizedError {
    /// Error code (`-32004` unsupported operation, `-32001` task not found, ...).
    public var code: Int
    /// Error message.
    public var message: String

    /// Creates an error.
    /// - Parameters:
    ///   - code: Code.
    ///   - message: Message.
    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }

    /// Error description.
    public var errorDescription: String? {
        "A2A error \(self.code): \(self.message)"
    }
}

/// JSON-RPC 2.0 request envelope.
public struct A2AJSONRPCRequest<Params: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    /// Always `2.0`.
    public var jsonrpc: String
    /// Request id (`nil` for notifications).
    public var id: A2AJSONRPCID?
    /// Method name.
    public var method: String
    /// Parameters.
    public var params: Params?

    /// Creates a request.
    /// - Parameters:
    ///   - id: Request id.
    ///   - method: Method.
    ///   - params: Parameters.
    public init(id: A2AJSONRPCID? = .string(UUID().uuidString.lowercased()), method: String, params: Params?) {
        self.jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
    }
}

/// JSON-RPC 2.0 response envelope.
public struct A2AJSONRPCResponse<Result: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    /// Always `2.0`.
    public var jsonrpc: String
    /// Request id.
    public var id: A2AJSONRPCID?
    /// Result on success.
    public var result: Result?
    /// Error on failure.
    public var error: A2AJSONRPCError?

    /// Creates a response.
    /// - Parameters:
    ///   - id: Request id.
    ///   - result: Result.
    ///   - error: Error.
    public init(id: A2AJSONRPCID?, result: Result? = nil, error: A2AJSONRPCError? = nil) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = result
        self.error = error
    }
}

/// Protocol constants and helpers.
public enum A2AProtocol {
    /// Protocol version advertised in the Agent Card.
    public static let version = "1.0"
    /// Canonical `SendMessage` method.
    public static let sendMessageMethod = "SendMessage"
    /// Canonical `GetTask` method.
    public static let getTaskMethod = "GetTask"
    /// Inbound text cap in UTF-8 bytes.
    public static let messageMaxBytes = 64 * 1_024
    /// Suffix appended to truncated inbound text.
    public static let truncationMarker = "\n[message truncated at \(64 * 1_024) bytes]"
    /// Error code for unsupported operations.
    public static let unsupportedOperationCode = -32_004
    /// Error code for unknown tasks.
    public static let taskNotFoundCode = -32_001

    /// Resolved RPC method.
    public enum Method: Sendable, Equatable {
        /// `SendMessage` / `message/send`.
        case sendMessage
        /// `GetTask` / `tasks/get`.
        case getTask
        /// A known A2A method this gateway refuses with `-32004`.
        case unsupported
    }

    /// Methods refused with `-32004` (cancellation is refused rather than faked).
    public static let unsupportedMethods: Set<String> = [
        "CancelTask", "tasks/cancel", "ListTasks", "SendStreamingMessage", "SubscribeToTask",
        "CreateTaskPushNotificationConfig", "SetTaskPushNotificationConfig", "GetTaskPushNotificationConfig",
        "ListTaskPushNotificationConfig", "ListTaskPushNotificationConfigs", "DeleteTaskPushNotificationConfig",
        "GetExtendedAgentCard",
    ]

    /// Resolves a method name (including the A2A 0.3 aliases `message/send` and `tasks/get`).
    /// - Parameter method: Raw method.
    /// - Returns: Resolved method, or `nil` when unknown (`-32601`).
    public static func resolveMethod(_ method: String) -> Method? {
        switch method {
        case "SendMessage", "message/send": return .sendMessage
        case "GetTask", "tasks/get": return .getTask
        default: return self.unsupportedMethods.contains(method) ? .unsupported : nil
        }
    }

    /// Whether a context id matches `^[A-Za-z0-9._:-]{1,128}$`.
    /// - Parameter value: Candidate.
    /// - Returns: `true` when valid.
    public static func isContextID(_ value: String) -> Bool {
        guard (1...128).contains(value.utf8.count) else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "._:-".unicodeScalars.contains(scalar))
        }
    }

    /// Extracts inbound text: text parts and compact JSON of data parts joined with newlines,
    /// capped at 64 KiB on a character boundary.
    /// - Parameter parts: Raw JSON parts.
    /// - Returns: Text, or `nil` when no usable text exists.
    public static func extractText(from parts: [AnyCodable]) -> String? {
        var pieces: [String] = []
        for part in parts {
            guard let object = part.dictionaryValue else { continue }
            if let text = object["text"]?.stringValue {
                pieces.append(text)
            } else if let data = object["data"] {
                pieces.append(self.compactJSON(data))
            }
        }
        let text = pieces.joined(separator: "\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard text.utf8.count > self.messageMaxBytes else { return text }
        let budget = self.messageMaxBytes - self.truncationMarker.utf8.count
        var prefix = ""
        var used = 0
        for character in text {
            let size = String(character).utf8.count
            if used + size > budget { break }
            prefix.append(character)
            used += size
        }
        return prefix + self.truncationMarker
    }

    /// ISO-8601 timestamp with fractional seconds.
    /// - Parameter date: Date.
    /// - Returns: Timestamp.
    public static func timestamp(_ date: Date = Date()) -> String {
        self.timestampFormatter.string(from: date)
    }

    // ISO8601DateFormatter is thread-safe; creating one per call dominates task-store cost.
    nonisolated(unsafe) private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func compactJSON(_ value: AnyCodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
