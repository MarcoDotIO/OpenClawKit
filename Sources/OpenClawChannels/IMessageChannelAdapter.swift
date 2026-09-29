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
public actor IMessageChannelAdapter: InboundChannelAdapter, ReceiptingChannelAdapter {
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

    /// Creates an iMessage adapter.
    /// - Parameters:
    ///   - config: iMessage channel configuration.
    ///   - transport: Optional host-provided native transport. When `nil` on macOS/Linux and
    ///     simulation is disabled, an ``IMsgRPCTransport`` over `config.cliPath` is created.
    public init(config: IMessageChannelConfig, transport: (any IMessageTransport)? = nil) {
        self.config = config
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
                try await inbound.startWatching(includeAttachments: self.config.includeAttachments, sinceRowID: nil) { [weak self] payload in
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
        guard self.started, payload.isFromMe != true, payload.isReaction != true else { return }
        guard let peerID = payload.conversationPeerID else { return }
        if let guid = payload.guid?.channelTrimmedNonEmpty ?? payload.id.map(String.init), !self.recentInboundGUIDs.insert(guid) {
            return
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
        if let inboundHandler {
            await inboundHandler(inbound)
        }
    }

    private func loadAttachments(_ attachments: [IMessagePayload.Attachment]) -> [MediaAttachment] {
        guard self.config.includeAttachments else { return [] }
        let maxBytes = Int((self.config.policy.mediaMaxMb ?? 16) * 1_024 * 1_024)
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
