import Foundation

/// `watch.notify`: iPhone → Watch notification or prompt, as carried over WatchConnectivity.
///
/// The wire dictionary is flat: `type`, `id`, `sentAtMs`, the ``OpenClawWatchNotifyParams`` fields
/// (`priority` defaults to `active`), and the optional `chatDeliveryContext` a quick reply must carry.
public struct OpenClawWatchNotifyMessage: Codable, Sendable, Equatable {
    /// Always ``OpenClawWatchPayloadType/notify``.
    public var type: OpenClawWatchPayloadType
    /// Message identifier (the `watch.notify` invoke id).
    public var id: String?
    /// Notification params.
    public var params: OpenClawWatchNotifyParams
    /// Send time in milliseconds since the Unix epoch.
    public var sentAtMs: Int64?
    /// Routing owner a quick reply to this prompt must carry; nil for informational alerts.
    public var chatDeliveryContext: OpenClawWatchChatDeliveryContext?

    /// Creates a notify message.
    public init(
        id: String?,
        params: OpenClawWatchNotifyParams,
        sentAtMs: Int64? = nil,
        chatDeliveryContext: OpenClawWatchChatDeliveryContext? = nil)
    {
        self.type = .notify
        self.id = id
        self.params = params
        self.sentAtMs = sentAtMs
        self.chatDeliveryContext = chatDeliveryContext
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case id
        case sentAtMs
        case chatDeliveryContext
    }

    /// Decodes the flat wire shape.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decode(OpenClawWatchPayloadType.self, forKey: .type)
        self.id = try container.decodeIfPresent(String.self, forKey: .id)
        self.sentAtMs = try container.decodeIfPresent(Int64.self, forKey: .sentAtMs)
        self.chatDeliveryContext = try container.decodeIfPresent(
            OpenClawWatchChatDeliveryContext.self, forKey: .chatDeliveryContext)
        self.params = try OpenClawWatchNotifyParams(from: decoder)
    }

    /// Encodes the flat wire shape; a missing priority is written as `active`.
    public func encode(to encoder: Encoder) throws {
        var params = self.params
        params.priority = params.priority ?? .active
        try params.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.type, forKey: .type)
        try container.encodeIfPresent(self.id, forKey: .id)
        try container.encodeIfPresent(self.sentAtMs, forKey: .sentAtMs)
        try container.encodeIfPresent(self.chatDeliveryContext, forKey: .chatDeliveryContext)
    }
}

/// A decoded iPhone ↔ Watch companion message.
public enum OpenClawWatchMessage: Sendable, Equatable {
    /// `watch.notify`.
    case notify(OpenClawWatchNotifyMessage)
    /// `watch.node.setup`.
    case directNodeSetup(OpenClawWatchNodeSetupMessage)
    /// `watch.reply`: retired legacy quick reply; hosts should answer with a rejection or ignore it.
    case legacyReply
    /// `watch.app.snapshot`.
    case appSnapshot(OpenClawWatchAppSnapshotMessage)
    /// `watch.app.snapshotRequest`.
    case appSnapshotRequest(OpenClawWatchAppSnapshotRequestMessage)
    /// `watch.app.command`.
    case appCommand(OpenClawWatchAppCommandMessage)
    /// `watch.chat.completion`.
    case chatCompletion(OpenClawWatchChatCompletionMessage)
    /// `watch.chat.delivery.command` (strictly validated structure).
    case chatDeliveryCommand(OpenClawWatchChatDeliveryCommand)
    /// `watch.chat.delivery.receipt` (strictly validated).
    case chatDeliveryReceipt(OpenClawWatchChatDeliveryReceipt)
    /// `watch.chat.delivery.receiptAck` (strictly validated).
    case chatDeliveryReceiptAck(OpenClawWatchChatDeliveryReceiptAck)
    /// `watch.execApproval.prompt`.
    case execApprovalPrompt(OpenClawWatchExecApprovalPromptMessage)
    /// `watch.execApproval.resolve`.
    case execApprovalResolve(OpenClawWatchExecApprovalResolveMessage)
    /// `watch.execApproval.resolved`.
    case execApprovalResolved(OpenClawWatchExecApprovalResolvedMessage)
    /// `watch.execApproval.expired`.
    case execApprovalExpired(OpenClawWatchExecApprovalExpiredMessage)
    /// `watch.execApproval.snapshot`.
    case execApprovalSnapshot(OpenClawWatchExecApprovalSnapshotMessage)
    /// `watch.execApproval.snapshotRequest`.
    case execApprovalSnapshotRequest(OpenClawWatchExecApprovalSnapshotRequestMessage)

    /// Payload type of this message.
    public var type: OpenClawWatchPayloadType {
        switch self {
        case .notify: .notify
        case .directNodeSetup: .directNodeSetup
        case .legacyReply: .reply
        case .appSnapshot: .appSnapshot
        case .appSnapshotRequest: .appSnapshotRequest
        case .appCommand: .appCommand
        case .chatCompletion: .chatCompletion
        case .chatDeliveryCommand: .chatDeliveryCommand
        case .chatDeliveryReceipt: .chatDeliveryReceipt
        case .chatDeliveryReceiptAck: .chatDeliveryReceiptAck
        case .execApprovalPrompt: .execApprovalPrompt
        case .execApprovalResolve: .execApprovalResolve
        case .execApprovalResolved: .execApprovalResolved
        case .execApprovalExpired: .execApprovalExpired
        case .execApprovalSnapshot: .execApprovalSnapshot
        case .execApprovalSnapshotRequest: .execApprovalSnapshotRequest
        }
    }
}

/// Error raised by ``OpenClawWatchMessageCodec``.
public struct OpenClawWatchMessageCodecError: Error, LocalizedError, Sendable, Equatable {
    /// Payload `type` value, when present.
    public let type: String?
    /// What was wrong with the payload.
    public let reason: String

    /// Creates a codec error.
    public init(type: String?, reason: String) {
        self.type = type
        self.reason = reason
    }

    /// Human-readable description.
    public var errorDescription: String? {
        "Invalid Watch message\(self.type.map { " (\($0))" } ?? ""): \(self.reason)"
    }
}

/// Transport-agnostic `[String: Any]` codec for WatchConnectivity (`sendMessage`, `transferUserInfo`,
/// `updateApplicationContext`), dispatching on the payload `type`.
///
/// The SDK does not import WatchConnectivity: hosts pass the dictionaries to and from `WCSession`
/// themselves. Values are property-list compatible (`String`, `NSNumber`, arrays, dictionaries).
/// Chat delivery messages go through the strict ``OpenClawWatchChatDeliveryCodec``; the other messages
/// use their `Codable` shape with the upstream wire quirks: the app snapshot writes `agentAvatarUrl`
/// (and reads either spelling), and a snapshot request without `heldApprovals` decodes as empty.
public enum OpenClawWatchMessageCodec {
    /// Payload types persisted through `updateApplicationContext`.
    public static let durableSnapshotTypes: [OpenClawWatchPayloadType] = [.appSnapshot, .execApprovalSnapshot]

    private static let avatarURLKey = "agentAvatarURL"
    private static let avatarURLWireKey = "agentAvatarUrl"

    /// Reads the payload `type`, or nil when it is missing or unknown.
    public static func payloadType(_ payload: [String: Any]) -> OpenClawWatchPayloadType? {
        (payload["type"] as? String).flatMap(OpenClawWatchPayloadType.init(rawValue:))
    }

    /// Encodes a message as a WatchConnectivity dictionary.
    public static func encode(_ message: OpenClawWatchMessage) throws -> [String: Any] {
        switch message {
        case let .notify(value): try self.encodeValue(value)
        case let .directNodeSetup(value): try self.encodeValue(value)
        case .legacyReply: ["type": OpenClawWatchPayloadType.reply.rawValue]
        case let .appSnapshot(value): try self.encodeAppSnapshot(value)
        case let .appSnapshotRequest(value): try self.encodeValue(value)
        case let .appCommand(value): try self.encodeValue(value)
        case let .chatCompletion(value): try self.encodeValue(value)
        case let .chatDeliveryCommand(value): try OpenClawWatchChatDeliveryCodec.encode(value)
        case let .chatDeliveryReceipt(value): try OpenClawWatchChatDeliveryCodec.encode(value)
        case let .chatDeliveryReceiptAck(value): try OpenClawWatchChatDeliveryCodec.encode(value)
        case let .execApprovalPrompt(value): try self.encodeValue(value)
        case let .execApprovalResolve(value): try self.encodeValue(value)
        case let .execApprovalResolved(value): try self.encodeValue(value)
        case let .execApprovalExpired(value): try self.encodeValue(value)
        case let .execApprovalSnapshot(value): try self.encodeValue(value)
        case let .execApprovalSnapshotRequest(value): try self.encodeValue(value)
        }
    }

    /// Decodes a WatchConnectivity dictionary; returns nil for a missing or unknown `type`.
    ///
    /// - Throws: ``OpenClawWatchChatDeliveryError`` for invalid chat delivery messages, otherwise
    ///   ``OpenClawWatchMessageCodecError``.
    public static func decode(_ payload: [String: Any]) throws -> OpenClawWatchMessage? {
        guard let type = self.payloadType(payload) else { return nil }
        switch type {
        case .notify:
            return try .notify(self.decodeValue(payload))
        case .directNodeSetup:
            return try .directNodeSetup(self.decodeValue(payload))
        case .reply:
            return .legacyReply
        case .appSnapshot:
            var normalized = payload
            if normalized[self.avatarURLKey] == nil, let wireValue = normalized[self.avatarURLWireKey] {
                normalized[self.avatarURLKey] = wireValue
            }
            normalized.removeValue(forKey: self.avatarURLWireKey)
            return try .appSnapshot(self.decodeValue(normalized))
        case .appSnapshotRequest:
            return try .appSnapshotRequest(self.decodeValue(payload))
        case .appCommand:
            return try .appCommand(self.decodeValue(payload))
        case .chatCompletion:
            return try .chatCompletion(self.decodeValue(payload))
        case .chatDeliveryCommand:
            return try .chatDeliveryCommand(OpenClawWatchChatDeliveryCodec.decodeCommandStructure(payload))
        case .chatDeliveryReceipt:
            return try .chatDeliveryReceipt(OpenClawWatchChatDeliveryCodec.decodeReceipt(payload))
        case .chatDeliveryReceiptAck:
            return try .chatDeliveryReceiptAck(OpenClawWatchChatDeliveryCodec.decodeReceiptAck(payload))
        case .execApprovalPrompt:
            return try .execApprovalPrompt(self.decodeValue(payload))
        case .execApprovalResolve:
            return try .execApprovalResolve(self.decodeValue(payload))
        case .execApprovalResolved:
            return try .execApprovalResolved(self.decodeValue(payload))
        case .execApprovalExpired:
            return try .execApprovalExpired(self.decodeValue(payload))
        case .execApprovalSnapshot:
            return try .execApprovalSnapshot(self.decodeValue(payload))
        case .execApprovalSnapshotRequest:
            var normalized = payload
            // Shipped Watch builds request snapshots without heldApprovals.
            if normalized["heldApprovals"] == nil { normalized["heldApprovals"] = [Any]() }
            return try .execApprovalSnapshotRequest(self.decodeValue(normalized))
        }
    }

    /// Builds the `updateApplicationContext` dictionary for a durable snapshot payload.
    ///
    /// The context retains one dictionary, so both logical snapshots are nested under their type keys
    /// while the newest one stays at the top level for older Watch builds. Other payloads are returned
    /// unchanged.
    public static func applicationContext(
        for payload: [String: Any],
        merging existingContext: [String: Any]) -> [String: Any]
    {
        guard let payloadType = payload["type"] as? String,
              self.durableSnapshotTypes.map(\.rawValue).contains(payloadType)
        else {
            return payload
        }
        var context = payload
        for snapshotType in self.durableSnapshotTypes.map(\.rawValue) {
            if snapshotType == payloadType {
                context[snapshotType] = payload
            } else if let previous = existingContext[snapshotType] as? [String: Any] {
                context[snapshotType] = previous
            } else if existingContext["type"] as? String == snapshotType {
                context[snapshotType] = existingContext
            }
        }
        return context
    }

    /// Extracts the durable snapshots from a received application context (nested or top-level).
    public static func snapshots(
        fromApplicationContext context: [String: Any]) -> (
        app: OpenClawWatchAppSnapshotMessage?,
        execApprovals: OpenClawWatchExecApprovalSnapshotMessage?)
    {
        func snapshot(_ type: OpenClawWatchPayloadType) -> OpenClawWatchMessage? {
            let nested = context[type.rawValue] as? [String: Any]
            let payload = nested ?? (context["type"] as? String == type.rawValue ? context : nil)
            return payload.flatMap { try? self.decode($0) }
        }
        var app: OpenClawWatchAppSnapshotMessage?
        if case let .appSnapshot(value) = snapshot(.appSnapshot) { app = value }
        var approvals: OpenClawWatchExecApprovalSnapshotMessage?
        if case let .execApprovalSnapshot(value) = snapshot(.execApprovalSnapshot) { approvals = value }
        return (app, approvals)
    }

    private static func encodeAppSnapshot(_ value: OpenClawWatchAppSnapshotMessage) throws -> [String: Any] {
        var payload = try self.encodeValue(value)
        if let avatar = payload.removeValue(forKey: self.avatarURLKey) {
            payload[self.avatarURLWireKey] = avatar
        }
        return payload
    }

    private static func encodeValue(_ value: some Encodable) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenClawWatchMessageCodecError(type: nil, reason: "Encoded value is not an object")
        }
        return payload
    }

    private static func decodeValue<Value: Decodable>(_ payload: [String: Any]) throws -> Value {
        let type = payload["type"] as? String
        guard JSONSerialization.isValidJSONObject(payload) else {
            throw OpenClawWatchMessageCodecError(type: type, reason: "Payload is not JSON-compatible")
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            throw OpenClawWatchMessageCodecError(type: type, reason: String(describing: error))
        }
    }
}
