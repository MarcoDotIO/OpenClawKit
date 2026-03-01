import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenClawCore

/// Minimal HTTP transport contract used by the Signal adapter.
public protocol SignalHTTPTransport: Sendable {
    /// Executes an HTTP request and returns normalized response data.
    /// - Parameter request: Configured URL request.
    /// - Returns: Normalized response payload.
    func data(for request: URLRequest) async throws -> HTTPResponseData
}

extension HTTPClient: SignalHTTPTransport {}

private struct SignalSendRequest: Encodable {
    let message: String
    let number: String
    let recipients: [String]
}

private struct SignalReceiveResponse: Decodable {
    let messages: [SignalInboundEnvelope]

    private enum CodingKeys: String, CodingKey {
        case messages
    }

    init(from decoder: Decoder) throws {
        if let rawArray = try? [SignalInboundEnvelope](from: decoder) {
            self.messages = rawArray
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.messages = try container.decodeIfPresent([SignalInboundEnvelope].self, forKey: .messages) ?? []
    }
}

private struct SignalInboundEnvelope: Decodable {
    let envelope: SignalInboundPayload?
    let source: String?
    let sourceNumber: String?
    let timestamp: Int64?
    let message: String?
    let text: String?
    let dataMessage: SignalDataMessage?
}

private struct SignalInboundPayload: Decodable {
    let source: String?
    let sourceNumber: String?
    let timestamp: Int64?
    let dataMessage: SignalDataMessage?
}

private struct SignalDataMessage: Decodable {
    let message: String?
}

/// Signal adapter backed by a Signal bridge REST API.
public actor SignalChannelAdapter: InboundChannelAdapter {
    /// Adapter channel identifier.
    public let id: ChannelID = .signal

    private let config: SignalChannelConfig
    private let transport: any SignalHTTPTransport
    private let explicitServiceURL: URL?

    private var started = false
    private var pollTask: Task<Void, Never>?
    private var inboundHandler: InboundMessageHandler?
    private var recentInboundMessageIDs: [String] = []
    private var recentInboundMessageIDSet: Set<String> = []
    private let maxRecentInboundMessageCount = 1_024

    /// Creates a Signal channel adapter.
    /// - Parameters:
    ///   - config: Signal channel configuration.
    ///   - transport: HTTP transport implementation.
    ///   - serviceURL: Optional Signal bridge service URL override.
    public init(
        config: SignalChannelConfig,
        transport: any SignalHTTPTransport = HTTPClient(),
        serviceURL: URL? = nil
    ) {
        self.config = config
        self.transport = transport
        self.explicitServiceURL = serviceURL
    }

    /// Registers or clears inbound callback.
    /// - Parameter handler: Optional callback for accepted inbound messages.
    public func setInboundHandler(_ handler: InboundMessageHandler?) async {
        self.inboundHandler = handler
    }

    /// Starts adapter lifecycle and inbound polling loop.
    public func start() async throws {
        guard self.config.enabled else {
            throw OpenClawCoreError.unavailable("Signal channel is disabled")
        }
        if self.started {
            return
        }
        _ = try self.resolveServiceURL()
        _ = try self.resolveAccountID(fromOutboundAccountID: nil)
        self.recentInboundMessageIDs.removeAll(keepingCapacity: true)
        self.recentInboundMessageIDSet.removeAll(keepingCapacity: true)
        self.started = true
        self.pollTask = Task { [weak self] in
            await self?.pollLoop()
        }
    }

    /// Stops adapter lifecycle.
    public func stop() async {
        self.started = false
        self.pollTask?.cancel()
        self.pollTask = nil
    }

    /// Sends outbound Signal message.
    /// - Parameter message: Outbound payload.
    public func send(_ message: OutboundMessage) async throws {
        guard self.started else {
            throw OpenClawCoreError.unavailable("Signal adapter is not started")
        }
        let accountID = try self.resolveAccountID(fromOutboundAccountID: message.accountID)
        let recipient = try self.resolveRecipient(from: message)
        let endpoint = try self.resolveServiceURL()
            .appendingPathComponent("v2")
            .appendingPathComponent("send")
        let payload = SignalSendRequest(
            message: try self.resolveOutboundText(from: message),
            number: accountID,
            recipients: [recipient]
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let authToken = self.resolvedAuthToken() {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(payload)
        let response = try await self.transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw OpenClawCoreError.unavailable("Signal send failed with status \(response.statusCode)")
        }
    }

    private func pollLoop() async {
        while !Task.isCancelled && self.started {
            do {
                try await self.pollOnce()
            } catch {
                // Keep loop alive; adapter retries on next interval tick.
            }
            let sleepNs = UInt64(max(250, self.config.pollIntervalMs)) * 1_000_000
            try? await Task.sleep(nanoseconds: sleepNs)
        }
    }

    private func pollOnce() async throws {
        let accountID = try self.resolveAccountID(fromOutboundAccountID: nil)
        var endpoint = try self.resolveServiceURL()
            .appendingPathComponent("v1")
            .appendingPathComponent("receive")
            .appendingPathComponent(accountID)
        if var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) {
            components.queryItems = [URLQueryItem(name: "timeout", value: "0")]
            endpoint = components.url ?? endpoint
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        if let authToken = self.resolvedAuthToken() {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }
        let response = try await self.transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw OpenClawCoreError.unavailable("Signal poll failed with status \(response.statusCode)")
        }

        let parsed = try JSONDecoder().decode(SignalReceiveResponse.self, from: response.body)
        for inbound in parsed.messages {
            guard let source = Self.resolveInboundSource(inbound) else {
                continue
            }
            guard source != accountID else {
                continue
            }
            guard let text = Self.resolveInboundText(inbound) else {
                continue
            }
            let timestamp = Self.resolveInboundTimestamp(inbound)
            guard !self.shouldSkipInbound(source: source, timestamp: timestamp, text: text) else {
                continue
            }
            let message = InboundMessage(
                channel: .signal,
                accountID: source,
                peerID: source,
                text: text
            )
            if let inboundHandler {
                await inboundHandler(message)
            }
        }
    }

    private func resolveAccountID(fromOutboundAccountID outboundAccountID: String?) throws -> String {
        let outbound = outboundAccountID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !outbound.isEmpty {
            return outbound
        }
        let configured = self.config.accountID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !configured.isEmpty {
            return configured
        }
        throw OpenClawCoreError.invalidConfiguration("Signal account ID is required")
    }

    private func resolveRecipient(from message: OutboundMessage) throws -> String {
        let peer = message.peerID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !peer.isEmpty {
            return peer
        }
        let fallback = self.config.defaultRecipient?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !fallback.isEmpty {
            return fallback
        }
        throw OpenClawCoreError.invalidConfiguration("Signal recipient is required")
    }

    private func resolveOutboundText(from message: OutboundMessage) throws -> String {
        let trimmed = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw OpenClawCoreError.invalidConfiguration("Signal outbound text is required")
        }
        return trimmed
    }

    private func resolveServiceURL() throws -> URL {
        let rawURL = self.explicitServiceURL?.absoluteString ?? self.config.serviceURL
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else {
            throw OpenClawCoreError.invalidConfiguration("Signal service URL is invalid")
        }
        return url
    }

    private func resolvedAuthToken() -> String? {
        let token = self.config.authToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return token.isEmpty ? nil : token
    }

    private func shouldSkipInbound(source: String, timestamp: Int64, text: String) -> Bool {
        let stableID = "\(source)|\(timestamp)|\(text)"
        if self.recentInboundMessageIDSet.contains(stableID) {
            return true
        }
        self.recentInboundMessageIDSet.insert(stableID)
        self.recentInboundMessageIDs.append(stableID)
        if self.recentInboundMessageIDs.count > self.maxRecentInboundMessageCount {
            let evicted = self.recentInboundMessageIDs.removeFirst()
            self.recentInboundMessageIDSet.remove(evicted)
        }
        return false
    }

    private static func resolveInboundSource(_ envelope: SignalInboundEnvelope) -> String? {
        let source = envelope.source
            ?? envelope.sourceNumber
            ?? envelope.envelope?.source
            ?? envelope.envelope?.sourceNumber
        let trimmed = source?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func resolveInboundTimestamp(_ envelope: SignalInboundEnvelope) -> Int64 {
        envelope.timestamp
            ?? envelope.envelope?.timestamp
            ?? 0
    }

    private static func resolveInboundText(_ envelope: SignalInboundEnvelope) -> String? {
        let text = envelope.message
            ?? envelope.text
            ?? envelope.dataMessage?.message
            ?? envelope.envelope?.dataMessage?.message
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
