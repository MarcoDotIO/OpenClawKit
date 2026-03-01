import Foundation
import OpenClawCore

/// iMessage adapter with explicit platform guards and deterministic fallback mode.
public actor IMessageChannelAdapter: InboundChannelAdapter {
    /// Adapter channel identifier.
    public let id: ChannelID = .imessage

    private let config: IMessageChannelConfig
    private var started = false
    private var inboundHandler: InboundMessageHandler?
    private var simulatedOutbound: [OutboundMessage] = []

    /// Creates an iMessage adapter.
    /// - Parameter config: iMessage channel configuration.
    public init(config: IMessageChannelConfig) {
        self.config = config
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
        if !self.config.allowUnsupportedPlatformSimulation {
            throw OpenClawCoreError.unavailable(self.unsupportedStartReason())
        }
        self.simulatedOutbound.removeAll(keepingCapacity: true)
        self.started = true
    }

    /// Stops adapter lifecycle.
    public func stop() async {
        self.started = false
    }

    /// Sends outbound message. In current release this uses deterministic simulation mode.
    /// - Parameter message: Outbound payload.
    public func send(_ message: OutboundMessage) async throws {
        guard self.started else {
            throw OpenClawCoreError.unavailable("iMessage adapter is not started")
        }
        guard self.config.allowUnsupportedPlatformSimulation else {
            throw OpenClawCoreError.unavailable("Native iMessage transport path is not configured")
        }
        let peerID = try self.resolvePeerID(from: message)
        let text = try self.resolveText(from: message)
        self.simulatedOutbound.append(
            OutboundMessage(
                channel: .imessage,
                accountID: message.accountID,
                peerID: peerID,
                text: text,
                attachments: message.attachments
            )
        )
    }

    /// Returns simulated outbound history used by tests and diagnostics.
    public func simulatedOutboundHistory() -> [OutboundMessage] {
        self.simulatedOutbound
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

    private func resolveText(from message: OutboundMessage) throws -> String {
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw OpenClawCoreError.invalidConfiguration("iMessage outbound text is required")
        }
        return text
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
