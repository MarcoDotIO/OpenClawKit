import Foundation
import OpenClawCore
import OpenClawProtocol

/// Inbound message pushed by `imsg watch.subscribe` (upstream `IMessagePayload`).
public struct IMessagePayload: Codable, Sendable, Equatable {
    /// One attachment.
    public struct Attachment: Codable, Sendable, Equatable {
        /// Absolute path on the Messages Mac.
        public var originalPath: String?
        /// MIME type.
        public var mimeType: String?
        /// Whether the file is missing (not downloaded).
        public var missing: Bool?
        /// Transfer name.
        public var transferName: String?
        /// Uniform type identifier.
        public var uti: String?

        /// Creates an attachment.
        /// - Parameters:
        ///   - originalPath: Path.
        ///   - mimeType: MIME type.
        ///   - missing: Missing flag.
        ///   - transferName: Transfer name.
        ///   - uti: UTI.
        public init(originalPath: String? = nil, mimeType: String? = nil, missing: Bool? = nil, transferName: String? = nil, uti: String? = nil) {
            self.originalPath = originalPath
            self.mimeType = mimeType
            self.missing = missing
            self.transferName = transferName
            self.uti = uti
        }

        private enum CodingKeys: String, CodingKey {
            case originalPath = "original_path"
            case mimeType = "mime_type"
            case missing
            case transferName = "transfer_name"
            case uti
        }
    }

    /// Message row id.
    public var id: Int64?
    /// Message GUID.
    public var guid: String?
    /// Chat row id.
    public var chatID: Int64?
    /// Sender handle.
    public var sender: String?
    /// Sender display name.
    public var senderName: String?
    /// Whether the local account sent it.
    public var isFromMe: Bool?
    /// Message text.
    public var text: String?
    /// Thread originator GUID.
    public var threadOriginatorGUID: String?
    /// Replied-to message GUID.
    public var replyToGUID: String?
    /// Replied-to text.
    public var replyToText: String?
    /// Creation timestamp (ISO-8601).
    public var createdAt: String?
    /// Whether this is a tapback.
    public var isReaction: Bool?
    /// Tapback type.
    public var reactionType: String?
    /// Tapback emoji.
    public var reactionEmoji: String?
    /// Whether the tapback was added (vs removed).
    public var isReactionAdd: Bool?
    /// Reacted-to message GUID.
    public var reactedToGUID: String?
    /// Attachments.
    public var attachments: [Attachment]?
    /// Chat identifier.
    public var chatIdentifier: String?
    /// Chat GUID.
    public var chatGUID: String?
    /// Chat display name.
    public var chatName: String?
    /// Whether the chat is a group.
    public var isGroup: Bool?

    /// Creates a payload.
    /// - Parameters:
    ///   - id: Row id.
    ///   - guid: GUID.
    ///   - chatID: Chat row id.
    ///   - sender: Sender handle.
    ///   - text: Text.
    ///   - isFromMe: From-me flag.
    ///   - isGroup: Group flag.
    public init(
        id: Int64? = nil,
        guid: String? = nil,
        chatID: Int64? = nil,
        sender: String? = nil,
        text: String? = nil,
        isFromMe: Bool? = nil,
        isGroup: Bool? = nil
    ) {
        self.id = id
        self.guid = guid
        self.chatID = chatID
        self.sender = sender
        self.text = text
        self.isFromMe = isFromMe
        self.isGroup = isGroup
    }

    private enum CodingKeys: String, CodingKey {
        case id, guid
        case chatID = "chat_id"
        case sender
        case senderName = "sender_name"
        case isFromMe = "is_from_me"
        case text
        case threadOriginatorGUID = "thread_originator_guid"
        case replyToGUID = "reply_to_guid"
        case replyToText = "reply_to_text"
        case createdAt = "created_at"
        case isReaction = "is_reaction"
        case reactionType = "reaction_type"
        case reactionEmoji = "reaction_emoji"
        case isReactionAdd = "is_reaction_add"
        case reactedToGUID = "reacted_to_guid"
        case attachments
        case chatIdentifier = "chat_identifier"
        case chatGUID = "chat_guid"
        case chatName = "chat_name"
        case isGroup = "is_group"
    }

    /// Conversation peer id: `chat_id:<n>` for groups (or `chat_guid:`/`chat_identifier:`), else the sender handle.
    public var conversationPeerID: String? {
        if self.isGroup == true {
            if let chatID { return "chat_id:\(chatID)" }
            if let chatGUID = chatGUID?.channelTrimmedNonEmpty { return "chat_guid:\(chatGUID)" }
            if let chatIdentifier = chatIdentifier?.channelTrimmedNonEmpty { return "chat_identifier:\(chatIdentifier)" }
        }
        return self.sender?.channelTrimmedNonEmpty ?? self.chatIdentifier?.channelTrimmedNonEmpty
    }
}

/// Parsed outbound iMessage target (upstream `parseIMessageTarget`).
public enum IMessageTarget: Sendable, Equatable {
    /// `chat_id:<n>`.
    case chatID(Int64)
    /// `chat_guid:<guid>`.
    case chatGUID(String)
    /// `chat_identifier:<id>` (also bare 32-hex group identifiers).
    case chatIdentifier(String)
    /// A handle (E.164 phone number or email), optionally with an explicit service.
    case handle(String, service: IMessageService?)

    private static let chatIDPrefixes = ["chat_id:", "chatid:", "chat:"]
    private static let chatGUIDPrefixes = ["chat_guid:", "chatguid:", "guid:"]
    private static let chatIdentifierPrefixes = ["chat_identifier:", "chatidentifier:", "chatident:"]
    private static let servicePrefixes: [(String, IMessageService)] = [("imessage:", .imessage), ("sms:", .sms), ("auto:", .auto)]

    /// Parses a target string.
    /// - Parameter raw: Raw target.
    /// - Returns: Target.
    public static func parse(_ raw: String) throws -> IMessageTarget {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw OpenClawCoreError.invalidConfiguration("iMessage target is required")
        }
        let lower = trimmed.lowercased()
        for (prefix, service) in self.servicePrefixes where lower.hasPrefix(prefix) {
            let rest = String(trimmed.dropFirst(prefix.count))
            if let bare = self.bareChatIdentifier(rest) {
                return .chatIdentifier(bare)
            }
            switch try self.parse(rest) {
            case .handle(let handle, _):
                return .handle(handle, service: service)
            case let other:
                return other
            }
        }
        for prefix in self.chatIDPrefixes where lower.hasPrefix(prefix) {
            let value = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            guard let chatID = Int64(value) else {
                throw OpenClawCoreError.invalidConfiguration("Invalid iMessage chat_id: \(value)")
            }
            return .chatID(chatID)
        }
        for prefix in self.chatGUIDPrefixes where lower.hasPrefix(prefix) {
            let value = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { throw OpenClawCoreError.invalidConfiguration("chat_guid is required") }
            return .chatGUID(value)
        }
        for prefix in self.chatIdentifierPrefixes where lower.hasPrefix(prefix) {
            let value = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { throw OpenClawCoreError.invalidConfiguration("chat_identifier is required") }
            return .chatIdentifier(value)
        }
        if let bare = self.bareChatIdentifier(trimmed) {
            return .chatIdentifier(bare)
        }
        return .handle(trimmed, service: nil)
    }

    /// Bare 32-hex group identifiers route as chat identifiers, never as phone numbers.
    static func bareChatIdentifier(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 32, trimmed.allSatisfy(\.isHexDigit) else { return nil }
        return trimmed.lowercased()
    }

    /// JSON-RPC target parameters (exactly one of `chat_id`, `chat_guid`, `chat_identifier`, `to`).
    /// - Parameter attachment: `send.attachment` form (handles use `chat_identifier`).
    /// - Returns: Parameters.
    func rpcParams(attachment: Bool = false) -> [String: AnyCodable] {
        switch self {
        case .chatID(let id): return ["chat_id": AnyCodable(id)]
        case .chatGUID(let guid): return ["chat_guid": AnyCodable(guid)]
        case .chatIdentifier(let identifier): return ["chat_identifier": AnyCodable(identifier)]
        case .handle(let handle, _): return attachment ? ["chat_identifier": AnyCodable(handle)] : ["to": AnyCodable(handle)]
        }
    }
}

/// Native iMessage transport that can also watch for inbound messages.
public protocol IMessageInboundTransport: IMessageTransport {
    /// Subscribes to new messages.
    /// - Parameters:
    ///   - includeAttachments: Include attachment metadata.
    ///   - sinceRowID: Replay cursor.
    ///   - handler: Callback for each inbound payload.
    func startWatching(includeAttachments: Bool, sinceRowID: Int64?, handler: @escaping @Sendable (IMessagePayload) async -> Void) async throws
    /// Unsubscribes.
    func stopWatching() async
    /// Health probe.
    /// - Parameter timeoutMs: Timeout.
    func ping(timeoutMs: Int) async throws
    /// Sends and returns the platform message id when reported.
    /// - Parameter message: Payload.
    /// - Returns: Message GUID or id.
    func sendReturningID(_ message: IMessageTransportMessage) async throws -> String?
    /// Calls an arbitrary `imsg` RPC method (private-API actions such as `typing`, `read`,
    /// `tapback`, `message.edit`, `message.unsend`, `poll.send`).
    /// - Parameters:
    ///   - method: Method.
    ///   - params: Parameters.
    /// - Returns: Result.
    func call(_ method: String, params: [String: AnyCodable]) async throws -> AnyCodable
}

/// `IMessageTransport` backed by `imsg rpc --json` (upstream iMessage channel runtime).
///
/// Sends use method `send` (`text`, `service`, `region`, `transport`, `reply_to`, `file`, and one
/// target key); extra attachments use `send.attachment`. Inbound uses `watch.subscribe`
/// (`attachments`, `include_reactions`, `since_rowid`) and `message` notifications; `ping`
/// is the probe.
///
/// Requirements: macOS with Messages signed in, `imsg` installed, Full Disk Access and Messages
/// Automation for the launching process. Not usable from sandboxed or App Store apps. Private-API
/// actions (tapbacks, edit, unsend, typing, polls) additionally need `imsg launch` with SIP
/// disabled and are not wired by this transport.
public actor IMsgRPCTransport: IMessageInboundTransport {
    /// Builds the process pipe (inject a fake in tests).
    public typealias PipeFactory = @Sendable () -> any IMsgRPCPipe

    private let pipeFactory: PipeFactory
    private let service: IMessageService
    private let region: String?
    private let sendTransport: IMessageSendTransport?
    private let probeTimeoutMs: Int
    private var client: IMsgRPCClient?
    private var subscription: Int64?
    private var notificationTask: Task<Void, Never>?

    /// Creates a transport from `channels.imessage` settings.
    /// - Parameters:
    ///   - config: iMessage settings (`cliPath`, `dbPath`, `service`, `region`, `sendTransport`).
    ///   - pipeFactory: Pipe factory (default spawns `imsg` on macOS/Linux).
    public init(config: IMessageChannelConfig, pipeFactory: PipeFactory? = nil) {
        self.service = config.service ?? .auto
        self.region = config.region?.channelTrimmedNonEmpty
        self.sendTransport = config.sendTransport
        self.probeTimeoutMs = config.probeTimeoutMs
        if let pipeFactory {
            self.pipeFactory = pipeFactory
        } else {
            let cliPath = config.cliPath
            let dbPath = config.dbPath
            self.pipeFactory = { Self.defaultPipe(cliPath: cliPath, dbPath: dbPath) }
        }
    }

    /// Whether this platform can spawn `imsg` (macOS and Linux).
    public static var isProcessTransportSupported: Bool {
        #if os(macOS) || os(Linux)
        return true
        #else
        return false
        #endif
    }

    private static func defaultPipe(cliPath: String, dbPath: String?) -> any IMsgRPCPipe {
        #if os(macOS) || os(Linux)
        return IMsgProcessPipe(cliPath: cliPath, dbPath: dbPath)
        #else
        return UnsupportedIMsgPipe()
        #endif
    }

    /// Sends a message.
    /// - Parameter message: Payload.
    public func send(_ message: IMessageTransportMessage) async throws {
        _ = try await self.sendReturningID(message)
    }

    /// Sends a message (text plus first attachment via `send`, remaining attachments via `send.attachment`).
    /// - Parameter message: Payload.
    /// - Returns: Message GUID or id from the first send.
    public func sendReturningID(_ message: IMessageTransportMessage) async throws -> String? {
        let target = try IMessageTarget.parse(message.peerID)
        let client = try await self.connectedClient()
        var files: [URL] = []
        defer {
            for file in files {
                try? FileManager.default.removeItem(at: file)
            }
        }
        for attachment in message.attachments {
            files.append(try Self.writeTemporaryFile(attachment))
        }
        var params: [String: AnyCodable] = ["text": AnyCodable(message.text)]
        var service = self.service
        if case .handle(_, let explicit?) = target {
            service = explicit
        }
        params["service"] = AnyCodable(service.rawValue)
        if let region {
            params["region"] = AnyCodable(region)
        }
        if let sendTransport {
            params["transport"] = AnyCodable(sendTransport.rawValue)
        }
        if let first = files.first {
            params["file"] = AnyCodable(first.path)
        }
        params.merge(target.rpcParams()) { _, new in new }
        let result = try await client.request("send", params: params, timeoutMs: IMsgRPCClient.sendTimeoutMs)
        for file in files.dropFirst() {
            var attachmentParams = target.rpcParams(attachment: true)
            attachmentParams["file"] = AnyCodable(file.path)
            _ = try await client.request("send.attachment", params: attachmentParams, timeoutMs: IMsgRPCClient.sendTimeoutMs)
        }
        let object = result.dictionaryValue
        return object?["guid"]?.stringValue ?? object?["message_id"]?.stringValue ?? object?["messageId"]?.stringValue
            ?? object?["id"]?.int64Value.map(String.init)
    }

    /// Subscribes to inbound messages.
    /// - Parameters:
    ///   - includeAttachments: Include attachment metadata.
    ///   - sinceRowID: Replay cursor.
    ///   - handler: Inbound callback.
    public func startWatching(
        includeAttachments: Bool,
        sinceRowID: Int64? = nil,
        handler: @escaping @Sendable (IMessagePayload) async -> Void
    ) async throws {
        let client = try await self.connectedClient()
        self.notificationTask?.cancel()
        let notifications = client.notifications
        self.notificationTask = Task {
            for await notification in notifications where notification.method == "message" {
                guard let message = notification.params?.dictionaryValue?["message"],
                      let data = try? JSONEncoder().encode(message),
                      let payload = try? JSONDecoder().decode(IMessagePayload.self, from: data)
                else { continue }
                await handler(payload)
            }
        }
        var params: [String: AnyCodable] = ["attachments": AnyCodable(includeAttachments), "include_reactions": AnyCodable(true)]
        if let sinceRowID {
            params["since_rowid"] = AnyCodable(sinceRowID)
        }
        let result = try await client.request("watch.subscribe", params: params, timeoutMs: self.probeTimeoutMs)
        self.subscription = result.dictionaryValue?["subscription"]?.int64Value
    }

    /// Unsubscribes and stops the process.
    public func stopWatching() async {
        if let subscription, let client, await client.isRunning {
            _ = try? await client.request("watch.unsubscribe", params: ["subscription": AnyCodable(subscription)], timeoutMs: self.probeTimeoutMs)
        }
        self.subscription = nil
        self.notificationTask?.cancel()
        self.notificationTask = nil
        await self.client?.stop()
        self.client = nil
    }

    /// Calls an arbitrary RPC method with the probe timeout.
    /// - Parameters:
    ///   - method: Method.
    ///   - params: Parameters.
    /// - Returns: Result.
    public func call(_ method: String, params: [String: AnyCodable]) async throws -> AnyCodable {
        try await self.connectedClient().request(method, params: params, timeoutMs: max(self.probeTimeoutMs, IMsgRPCClient.defaultTimeoutMs))
    }

    /// Calls `ping`.
    /// - Parameter timeoutMs: Timeout.
    public func ping(timeoutMs: Int) async throws {
        _ = try await self.connectedClient().request("ping", timeoutMs: timeoutMs)
    }

    private func connectedClient() async throws -> IMsgRPCClient {
        if let client, await client.isRunning {
            return client
        }
        let client = IMsgRPCClient(pipe: self.pipeFactory())
        try await client.start()
        self.client = client
        return client
    }

    private static func writeTemporaryFile(_ attachment: MediaAttachment) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("openclaw-imsg", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = attachment.fileName?.channelTrimmedNonEmpty.map { ($0 as String).replacingOccurrences(of: "/", with: "_") }
            ?? "attachment"
        let url = directory.appendingPathComponent("\(UUID().uuidString)-\(name)")
        try attachment.data.write(to: url, options: .atomic)
        return url
    }
}

#if !(os(macOS) || os(Linux))
/// Placeholder pipe for platforms that cannot spawn processes.
struct UnsupportedIMsgPipe: IMsgRPCPipe {
    func open() async throws -> AsyncStream<IMsgRPCPipeEvent> {
        throw OpenClawCoreError.unavailable("imsg requires macOS (or Linux with an SSH wrapper); supply a custom IMsgRPCPipe")
    }

    func write(line _: String) async throws {
        throw OpenClawCoreError.unavailable("imsg rpc not running")
    }

    func close() async {}
}
#endif
