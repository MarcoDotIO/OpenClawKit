import Foundation
import OpenClawCore
import OpenClawProtocol

/// Native iMessage outbound payload used by host integrations.
public struct IMessageTransportMessage: Sendable, Equatable {
    public let accountID: String?
    public let peerID: String
    public let text: String
    public let attachments: [MediaAttachment]
    public let bundleIdentifier: String?

    /// Creates a transport message for a native iMessage sender.
    public init(
        accountID: String?,
        peerID: String,
        text: String,
        attachments: [MediaAttachment] = [],
        bundleIdentifier: String? = nil
    ) {
        self.accountID = accountID
        self.peerID = peerID
        self.text = text
        self.attachments = attachments
        self.bundleIdentifier = bundleIdentifier
    }
}

/// Minimal host-provided transport used for native iMessage sends.
public protocol IMessageTransport: Sendable {
    /// Sends a normalized iMessage payload through the host transport.
    /// - Parameter message: Outbound transport payload.
    func send(_ message: IMessageTransportMessage) async throws
}

/// Host-delivered inbound iMessage event.
public struct IMessageInboundEvent: Sendable, Equatable {
    public let accountID: String?
    public let peerID: String
    public let text: String
    public let attachments: [MediaAttachment]

    /// Creates an inbound iMessage event.
    public init(
        accountID: String? = nil,
        peerID: String,
        text: String,
        attachments: [MediaAttachment] = []
    ) {
        self.accountID = accountID
        self.peerID = peerID
        self.text = text
        self.attachments = attachments
    }
}

private struct IMessageReflectionRecord: Sendable, Equatable {
    let peerID: String
    let text: String
    let recordedAt: Date
}

/// iMessage adapter with explicit platform guards and deterministic fallback mode.
///
/// On macOS (and Linux, where `cliPath` is an SSH wrapper around `imsg` on the Messages Mac) the
/// adapter talks to `imsg rpc --json` through ``IMsgRPCTransport`` unless a transport is injected
/// or ``IMessageChannelConfig/allowUnsupportedPlatformSimulation`` is enabled. Inbound messages
/// arrive through `watch.subscribe`; own messages (`is_from_me`) and recent reflections of our
/// sends are dropped, group chats route as `chat_id:<n>` with ``ChannelChatType/group``.
/// The launching process needs Full Disk Access and Messages Automation; sandboxed App Store
/// apps cannot spawn `imsg`.
public actor IMessageChannelAdapter: InboundChannelAdapter, ReceiptingChannelAdapter, ChannelMessageActions {
    /// Adapter channel identifier.
    public let id: ChannelID = .imessage

    private let config: IMessageChannelConfig
    private let transport: (any IMessageTransport)?
    private var started = false
    private var inboundHandler: InboundMessageHandler?
    private var simulatedOutbound: [OutboundMessage] = []
    private var reflectionRecords: [IMessageReflectionRecord] = []
    private let reflectionTTL: TimeInterval = 120
    private var recentInboundGUIDs = ChannelRecentIDs(capacity: 1_000)
    private var chatGUIDs: [String: String] = [:]
    private var unsupportedPrivateMethods: Set<String> = []
    private var lastRowID: Int64?
    private var catchupProcessed = 0
    private var catchupWatchStartedAt: Date?
    private let cursorFileURL: URL?

    /// Creates an iMessage adapter.
    /// - Parameters:
    ///   - config: iMessage channel configuration.
    ///   - transport: Optional host-provided native transport. When `nil` on macOS/Linux and
    ///     simulation is disabled, an ``IMsgRPCTransport`` over `config.cliPath` is created.
    public init(config: IMessageChannelConfig, transport: (any IMessageTransport)? = nil) {
        self.init(config: config, transport: transport, cursorFileURL: nil)
    }

    /// Creates an iMessage adapter that persists the watch cursor for catch-up.
    /// - Parameters:
    ///   - config: iMessage channel configuration.
    ///   - transport: Optional native transport (see ``init(config:transport:)``).
    ///   - cursorFileURL: File holding the last processed message row id; with
    ///     `catchup.enabled`, restarts replay missed messages oldest-first from it.
    public init(config: IMessageChannelConfig, transport: (any IMessageTransport)?, cursorFileURL: URL?) {
        self.config = config
        self.cursorFileURL = cursorFileURL
        self.lastRowID = cursorFileURL.flatMap { try? Data(contentsOf: $0) }.flatMap { Int64(String(decoding: $0, as: UTF8.self)) }
        if let transport {
            self.transport = transport
        } else if !config.allowUnsupportedPlatformSimulation, IMsgRPCTransport.isProcessTransportSupported {
            self.transport = IMsgRPCTransport(config: config)
        } else {
            self.transport = nil
        }
    }

    /// Registers or clears inbound callback.
    /// - Parameter handler: Optional callback invoked for inbound messages.
    public func setInboundHandler(_ handler: InboundMessageHandler?) async {
        self.inboundHandler = handler
    }

    /// Starts adapter lifecycle.
    public func start() async throws {
        guard self.config.enabled else {
            throw OpenClawCoreError.unavailable("iMessage channel is disabled")
        }
        if self.started {
            return
        }
        if self.transport == nil, !self.config.allowUnsupportedPlatformSimulation {
            throw OpenClawCoreError.unavailable(self.unsupportedStartReason())
        }
        self.simulatedOutbound.removeAll(keepingCapacity: true)
        self.reflectionRecords.removeAll(keepingCapacity: true)
        if let inbound = self.transport as? any IMessageInboundTransport {
            do {
                let sinceRowID = self.config.catchup.enabled ? self.lastRowID : nil
                self.catchupProcessed = 0
                self.catchupWatchStartedAt = sinceRowID == nil ? nil : Date()
                try await inbound.startWatching(includeAttachments: self.config.includeAttachments, sinceRowID: sinceRowID) { [weak self] payload in
                    await self?.handleNativePayload(payload)
                }
            } catch {
                await inbound.stopWatching()
                throw OpenClawCoreError.unavailable(
                    "iMessage imsg transport failed to start: \(error.localizedDescription). Install imsg, grant Full Disk Access "
                        + "and Messages Automation to the launching process, or enable allowUnsupportedPlatformSimulation for simulation fallback."
                )
            }
        }
        self.started = true
    }

    /// Stops adapter lifecycle (unsubscribes from `imsg watch`).
    public func stop() async {
        self.started = false
        if let inbound = self.transport as? any IMessageInboundTransport {
            await inbound.stopWatching()
        }
    }

    /// Probes the transport (`imsg ping`).
    /// - Parameter timeoutMs: Probe timeout.
    /// - Returns: Probe result.
    public func probe(timeoutMs: Int) async -> ChannelProbeResult {
        guard let inbound = self.transport as? any IMessageInboundTransport else {
            return ChannelProbeResult(ok: self.transport != nil || self.config.allowUnsupportedPlatformSimulation, detail: nil)
        }
        return await ChannelAsync.probe(timeoutMs: timeoutMs) {
            try await inbound.ping(timeoutMs: timeoutMs)
            return "imsg"
        }
    }

    /// Sends outbound message through the native transport, or captures it in simulation mode.
    /// - Parameter message: Outbound payload.
    public func send(_ message: OutboundMessage) async throws {
        _ = try await self.sendReturningReceipt(message)
    }

    /// Sends and returns the message GUID reported by `imsg` (a local id in simulation mode).
    /// - Parameter message: Outbound payload.
    /// - Returns: Receipt.
    public func sendReturningReceipt(_ message: OutboundMessage) async throws -> ChannelSendReceipt {
        guard self.started else {
            throw OpenClawCoreError.unavailable("iMessage adapter is not started")
        }
        let peerID = try self.resolvePeerID(from: message)
        let text = try self.resolveText(from: message)

        if let transport = self.transport {
            let outbound = IMessageTransportMessage(
                accountID: message.accountID,
                peerID: peerID,
                text: text,
                attachments: message.attachments,
                bundleIdentifier: self.config.bundleIdentifier
            )
            var platformID: String?
            if let inbound = transport as? any IMessageInboundTransport {
                platformID = try await inbound.sendReturningID(outbound)
            } else {
                try await transport.send(outbound)
            }
            self.recordReflection(peerID: peerID, text: text)
            return ChannelSendReceipt(platformMessageID: platformID ?? "local-\(UUID().uuidString.lowercased())")
        }

        guard self.config.allowUnsupportedPlatformSimulation else {
            throw OpenClawCoreError.unavailable("Native iMessage transport path is not configured")
        }
        let normalized = OutboundMessage(
            channel: .imessage,
            accountID: message.accountID,
            peerID: peerID,
            text: text,
            attachments: message.attachments
        )
        self.simulatedOutbound.append(normalized)
        self.recordReflection(peerID: peerID, text: text)
        return ChannelSendReceipt(platformMessageID: "simulated-\(UUID().uuidString.lowercased())")
    }

    /// Returns simulated outbound history used by tests and diagnostics.
    public func simulatedOutboundHistory() -> [OutboundMessage] {
        self.simulatedOutbound
    }

    /// Handles an inbound iMessage event from the host integration.
    /// - Parameter event: Normalized inbound event payload.
    public func handleInboundEvent(_ event: IMessageInboundEvent) async throws {
        guard self.started else {
            throw OpenClawCoreError.unavailable("iMessage adapter is not started")
        }
        let peerID = try self.resolveInboundPeerID(from: event)
        let text = try self.resolveText(from: event.text)
        if self.shouldSuppressReflection(peerID: peerID, text: text) {
            return
        }
        let inbound = InboundMessage(
            channel: .imessage,
            accountID: event.accountID,
            peerID: peerID,
            text: text,
            attachments: event.attachments,
            senderID: peerID,
            legacyRoutingAccountID: event.accountID
        )
        if let inboundHandler {
            await inboundHandler(inbound)
        }
    }

    /// Maps an `imsg` watch notification to an inbound message (own messages, tapbacks and
    /// reflections of recent sends are dropped).
    /// - Parameter payload: Watch payload.
    public func handleNativePayload(_ payload: IMessagePayload) async {
        guard self.started else { return }
        let isReplay = self.recordRowID(payload)
        guard payload.isFromMe != true, payload.isReaction != true else { return }
        guard let peerID = payload.conversationPeerID else { return }
        if let guid = payload.guid?.channelTrimmedNonEmpty ?? payload.id.map(String.init), !self.recentInboundGUIDs.insert(guid) {
            return
        }
        if isReplay, !self.admitCatchup(payload) {
            return
        }
        if let chatGUID = payload.chatGUID?.channelTrimmedNonEmpty {
            self.chatGUIDs[peerID] = chatGUID
        }
        let text = payload.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let attachments = self.loadAttachments(payload.attachments ?? [])
        guard !text.isEmpty || !attachments.isEmpty else { return }
        if !text.isEmpty, self.shouldSuppressReflection(peerID: peerID, text: text) {
            return
        }
        let isGroup = payload.isGroup == true
        var metadata: [String: String] = [:]
        metadata["chatGuid"] = payload.chatGUID
        metadata["chatIdentifier"] = payload.chatIdentifier
        metadata["chatName"] = payload.chatName
        metadata["replyToText"] = payload.replyToText
        let inbound = InboundMessage(
            channel: .imessage,
            accountID: nil,
            peerID: peerID,
            text: text,
            attachments: attachments,
            senderID: payload.sender?.channelTrimmedNonEmpty,
            senderName: payload.senderName?.channelTrimmedNonEmpty,
            chatType: isGroup ? .group : .direct,
            messageID: payload.guid ?? payload.id.map(String.init),
            threadID: payload.threadOriginatorGUID?.channelTrimmedNonEmpty,
            replyToID: payload.replyToGUID?.channelTrimmedNonEmpty,
            metadata: metadata
        )
        if !isGroup, self.config.sendReadReceipts {
            await self.callPrivate("read", target: peerID, extra: [:])
        }
        if let inboundHandler {
            await inboundHandler(inbound)
        }
    }

    // MARK: Catch-up

    /// Records the row id; returns `true` when the payload replays history (created before the
    /// watch started while catch-up replays from a persisted cursor).
    private func recordRowID(_ payload: IMessagePayload) -> Bool {
        if let rowID = payload.id, rowID > (self.lastRowID ?? 0) {
            self.lastRowID = rowID
            if let cursorFileURL {
                try? Data(String(rowID).utf8).write(to: cursorFileURL, options: .atomic)
            }
        }
        guard let watchStartedAt = self.catchupWatchStartedAt,
              let created = payload.createdAt.flatMap(Self.parseTimestamp)
        else { return false }
        return created < watchStartedAt
    }

    /// Replayed messages must be younger than `catchup.maxAgeMinutes` and within `perRunLimit`.
    private func admitCatchup(_ payload: IMessagePayload) -> Bool {
        guard self.catchupProcessed < self.config.catchup.perRunLimit else { return false }
        if let created = payload.createdAt.flatMap(Self.parseTimestamp),
           Date().timeIntervalSince(created) > TimeInterval(self.config.catchup.maxAgeMinutes * 60)
        {
            return false
        }
        self.catchupProcessed += 1
        return true
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    // MARK: Private-API actions (imsg bridge)

    /// Typing uses the private-API bridge (`imsg launch`); it disables itself after the first failure.
    nonisolated public var supportsTypingIndicator: Bool {
        true
    }

    /// Actions enabled by `channels.imessage.actions.*`.
    nonisolated public var supportedMessageActions: Set<ChannelMessageActionName> {
        var actions: Set<ChannelMessageActionName> = []
        if self.config.actions.reactions { actions.insert(.react) }
        if self.config.actions.edit { actions.insert(.edit) }
        if self.config.actions.unsend { actions.formUnion([.unsend, .delete]) }
        if self.config.actions.polls { actions.insert(.poll) }
        return actions
    }

    /// Starts the typing bubble in direct chats (best effort; needs the private-API bridge).
    /// - Parameters:
    ///   - accountID: Unused.
    ///   - peerID: Conversation.
    public func sendTypingIndicator(accountID _: String?, peerID: String) async throws {
        guard !peerID.hasPrefix("chat_") else { return }
        await self.callPrivate("typing", target: peerID, extra: ["typing": AnyCodable(true)])
    }

    /// Stops the typing bubble.
    /// - Parameters:
    ///   - accountID: Unused.
    ///   - peerID: Conversation.
    public func stopTypingIndicator(accountID _: String?, peerID: String) async throws {
        guard !peerID.hasPrefix("chat_") else { return }
        await self.callPrivate("typing", target: peerID, extra: ["typing": AnyCodable(false)])
    }

    /// Sends or removes a tapback (`love`, `like`, `dislike`, `laugh`, `emphasize`, `question`).
    /// - Parameters:
    ///   - peerID: Conversation.
    ///   - messageID: Target message GUID.
    ///   - emoji: Tapback kind or emoji.
    ///   - remove: Remove instead of add.
    public func react(peerID: String, messageID: String, emoji: String, remove: Bool) async throws {
        guard self.config.actions.reactions else {
            throw ChannelMessageActionError.disabledByConfig(action: "react", channel: .imessage)
        }
        var params: [String: AnyCodable] = [
            "chat_guid": AnyCodable(try self.chatGUID(for: peerID)),
            "message_id": AnyCodable(messageID),
            "reaction": AnyCodable(Self.tapbackKind(emoji)),
            "part_index": AnyCodable(0),
        ]
        if remove {
            params["remove"] = AnyCodable(true)
        }
        _ = try await self.requirePrivateTransport().call("tapback", params: params)
    }

    /// Edits a sent message (`message.edit`).
    /// - Parameters:
    ///   - peerID: Conversation.
    ///   - messageID: Message GUID.
    ///   - text: New text.
    public func edit(peerID: String, messageID: String, text: String) async throws {
        guard self.config.actions.edit else {
            throw ChannelMessageActionError.disabledByConfig(action: "edit", channel: .imessage)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ChannelMessageActionError.invalidParams("iMessage edit requires non-empty text")
        }
        _ = try await self.requirePrivateTransport().call("message.edit", params: [
            "chat_guid": AnyCodable(try self.chatGUID(for: peerID)),
            "message_id": AnyCodable(messageID),
            "text": AnyCodable(trimmed),
            "backwards_compatibility_message": AnyCodable(trimmed),
            "part_index": AnyCodable(0),
        ])
    }

    /// Unsends a message (`message.unsend`).
    /// - Parameters:
    ///   - peerID: Conversation.
    ///   - messageID: Message GUID.
    public func unsend(peerID: String, messageID: String) async throws {
        guard self.config.actions.unsend else {
            throw ChannelMessageActionError.disabledByConfig(action: "unsend", channel: .imessage)
        }
        _ = try await self.requirePrivateTransport().call("message.unsend", params: [
            "chat_guid": AnyCodable(try self.chatGUID(for: peerID)),
            "message_id": AnyCodable(messageID),
            "part_index": AnyCodable(0),
        ])
    }

    /// Sends a native Apple Messages poll (`poll.send`; single choice, distinct options).
    /// - Parameters:
    ///   - peerID: Conversation.
    ///   - question: Question.
    ///   - options: Options (at least two, distinct).
    ///   - allowMultiple: Unsupported natively; must be `false`.
    /// - Returns: Receipt with the poll message GUID.
    public func sendPoll(peerID: String, question: String, options: [String], allowMultiple: Bool) async throws -> ChannelSendReceipt? {
        guard self.config.actions.polls else {
            throw ChannelMessageActionError.disabledByConfig(action: "poll", channel: .imessage)
        }
        let choices = options.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !allowMultiple, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, choices.count >= 2,
              !choices.contains(where: \.isEmpty), Set(choices).count == choices.count
        else {
            throw ChannelMessageActionError.invalidParams("iMessage polls need a question and at least two distinct options (single choice)")
        }
        let result = try await self.requirePrivateTransport().call("poll.send", params: [
            "chat_guid": AnyCodable(try self.chatGUID(for: peerID)),
            "question": AnyCodable(question),
            "options": AnyCodable(choices.map(AnyCodable.init)),
        ])
        let id = result.dictionaryValue?["guid"]?.stringValue ?? result.dictionaryValue?["message_id"]?.stringValue
        return id.map { ChannelSendReceipt(platformMessageID: $0) }
    }

    private func requirePrivateTransport() throws -> any IMessageInboundTransport {
        guard self.started, let transport = self.transport as? any IMessageInboundTransport else {
            throw ChannelMessageActionError.unsupported(action: "private-api", channel: .imessage)
        }
        return transport
    }

    private func chatGUID(for peerID: String) throws -> String {
        let trimmed = peerID.trimmingCharacters(in: .whitespacesAndNewlines)
        if let known = self.chatGUIDs[trimmed] {
            return known
        }
        if case .chatGUID(let guid)? = try? IMessageTarget.parse(trimmed) {
            return guid
        }
        throw ChannelMessageActionError.invalidParams("Unknown iMessage chat for \(trimmed); use chat_guid:<guid> or a conversation seen inbound")
    }

    /// Best-effort private-API call; methods that fail once are not retried this session.
    private func callPrivate(_ method: String, target peerID: String, extra: [String: AnyCodable]) async {
        guard self.started, !self.unsupportedPrivateMethods.contains(method),
              let transport = self.transport as? any IMessageInboundTransport,
              let target = try? IMessageTarget.parse(peerID)
        else { return }
        var params = target.rpcParams()
        params.merge(extra) { _, new in new }
        do {
            _ = try await transport.call(method, params: params)
        } catch {
            self.unsupportedPrivateMethods.insert(method)
        }
    }

    static func tapbackKind(_ value: String) -> String {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "❤️", "♥️", "love": "love"
        case "👍", "like": "like"
        case "👎", "dislike": "dislike"
        case "😂", "🤣", "laugh", "haha": "laugh"
        case "‼️", "❗", "emphasize", "emphasis": "emphasize"
        case "❓", "?", "question": "question"
        default: value
        }
    }

    private func loadAttachments(_ attachments: [IMessagePayload.Attachment]) -> [MediaAttachment] {
        guard self.config.includeAttachments else { return [] }
        let maxBytes = ChannelMediaLimits.maxBytes(megabytes: self.config.policy.mediaMaxMb, defaultMegabytes: 16)
        var total = 0
        var loaded: [MediaAttachment] = []
        for attachment in attachments where attachment.missing != true {
            guard let path = attachment.originalPath?.channelTrimmedNonEmpty else { continue }
            let expanded = NSString(string: path).expandingTildeInPath
            if let roots = self.config.attachmentRoots, !roots.isEmpty,
               !roots.contains(where: { expanded.hasPrefix(NSString(string: $0).expandingTildeInPath) })
            {
                continue
            }
            guard let data = FileManager.default.contents(atPath: expanded), total + data.count <= maxBytes else { continue }
            total += data.count
            loaded.append(MediaAttachment(
                mimeType: attachment.mimeType ?? "application/octet-stream",
                data: data,
                fileName: attachment.transferName,
                metadata: ["source": "imsg"]
            ))
        }
        return loaded
    }

    private func resolvePeerID(from message: OutboundMessage) throws -> String {
        let directPeerID = message.peerID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !directPeerID.isEmpty {
            return directPeerID
        }
        let defaultHandle = self.config.defaultHandle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !defaultHandle.isEmpty {
            return defaultHandle
        }
        throw OpenClawCoreError.invalidConfiguration("iMessage recipient handle is required")
    }

    private func resolveInboundPeerID(from event: IMessageInboundEvent) throws -> String {
        let directPeerID = event.peerID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !directPeerID.isEmpty {
            return directPeerID
        }
        let defaultHandle = self.config.defaultHandle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !defaultHandle.isEmpty {
            return defaultHandle
        }
        throw OpenClawCoreError.invalidConfiguration("iMessage inbound peer handle is required")
    }

    private func resolveText(from message: OutboundMessage) throws -> String {
        try self.resolveText(from: message.text)
    }

    private func resolveText(from rawText: String) throws -> String {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw OpenClawCoreError.invalidConfiguration("iMessage outbound text is required")
        }
        return text
    }

    private func recordReflection(peerID: String, text: String) {
        self.pruneReflectionRecords(now: Date())
        self.reflectionRecords.append(
            IMessageReflectionRecord(
                peerID: self.normalizedReflectionPeerID(peerID),
                text: self.normalizedReflectionText(text),
                recordedAt: Date()
            )
        )
    }

    private func shouldSuppressReflection(peerID: String, text: String) -> Bool {
        let now = Date()
        self.pruneReflectionRecords(now: now)
        let normalizedPeerID = self.normalizedReflectionPeerID(peerID)
        let normalizedText = self.normalizedReflectionText(text)
        guard let index = self.reflectionRecords.firstIndex(where: {
            $0.peerID == normalizedPeerID && $0.text == normalizedText
        }) else {
            return false
        }
        self.reflectionRecords.remove(at: index)
        return true
    }

    private func pruneReflectionRecords(now: Date) {
        let cutoff = now.addingTimeInterval(-self.reflectionTTL)
        self.reflectionRecords.removeAll { $0.recordedAt < cutoff }
    }

    private func normalizedReflectionPeerID(_ peerID: String) -> String {
        peerID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedReflectionText(_ text: String) -> String {
        text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func unsupportedStartReason() -> String {
        if Self.platformCanHostNativeIMessageTransport {
            return "iMessage native transport is not enabled in this build; enable simulation fallback"
        }
        return "iMessage adapter is unavailable on this platform without simulation fallback"
    }

    private static var platformCanHostNativeIMessageTransport: Bool {
#if os(macOS)
        if #available(macOS 14.0, *) {
            return true
        }
        return false
#elseif os(iOS)
        if #available(iOS 17.0, *) {
            return true
        }
        return false
#else
        return false
#endif
    }
}
