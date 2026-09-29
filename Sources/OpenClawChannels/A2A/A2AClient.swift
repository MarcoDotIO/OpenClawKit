import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenClawCore
import OpenClawProtocol

/// Outbound A2A peer client (port of upstream `extensions/a2a/src/outbound.ts`); usable standalone.
///
/// Sends `SendMessage` to the configured peer `url` with `Authorization: Bearer <outboundToken>`
/// and no Agent Card discovery. Each peer keeps a stable context id (`ctx-oc-<peer>`) unless the
/// caller supplies one. When a peer answers `-32601` (A2A 0.3 peers), the call is retried once
/// with the dotted `message/send` / `tasks/get` method name.
public actor A2AClient {
    /// Outbound request timeout.
    public static let requestTimeout: TimeInterval = 30

    private let peers: [String: A2APeerConfig]
    private let transport: any ChannelHTTPTransport

    /// Creates a client.
    /// - Parameters:
    ///   - peers: Peers keyed by name (resolve SecretRefs first).
    ///   - transport: HTTP transport.
    public init(peers: [String: A2APeerConfig], transport: any ChannelHTTPTransport = HTTPClient()) {
        self.peers = peers
        self.transport = transport
    }

    /// Stable default context id for a peer.
    /// - Parameter peer: Peer name.
    /// - Returns: `ctx-oc-<peer>`.
    public static func defaultContextID(for peer: String) -> String {
        "ctx-oc-\(peer)"
    }

    /// Normalizes an outbound target (`a2a:<peer>` or `<peer>`).
    /// - Parameter target: Raw target.
    /// - Returns: Peer name.
    public static func peerName(fromTarget target: String) -> String {
        var value = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("a2a:") {
            value = String(value.dropFirst(4))
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Sends a text task to a peer.
    /// - Parameters:
    ///   - text: Task text.
    ///   - peer: Peer name or `a2a:<peer>` target.
    ///   - contextId: Conversation context (default ``defaultContextID(for:)``).
    ///   - returnImmediately: Ask the peer not to block for its reply (default `true`).
    /// - Returns: The peer's task (a direct message reply is wrapped as a completed task).
    public func send(text: String, to peer: String, contextId: String? = nil, returnImmediately: Bool = true) async throws -> A2ATask {
        let name = Self.peerName(fromTarget: peer)
        let context = contextId ?? Self.defaultContextID(for: name)
        guard A2AProtocol.isContextID(context) else {
            throw OpenClawCoreError.invalidConfiguration("Invalid A2A contextId \(context)")
        }
        let message = A2AMessage(contextId: context, role: .user, parts: [.text(text)])
        let params = A2ASendMessageParams(message: message, configuration: A2ASendMessageConfiguration(returnImmediately: returnImmediately))
        let result: A2ASendMessageResult = try await self.call(
            peer: name,
            methods: [A2AProtocol.sendMessageMethod, "message/send"],
            params: params
        )
        if let task = result.task {
            return task
        }
        if let reply = result.message {
            return A2ATask(
                id: reply.taskId ?? reply.messageId,
                contextId: reply.contextId ?? context,
                status: A2ATaskStatus(state: .completed),
                artifacts: [A2AArtifact(parts: reply.parts)],
                history: [message, reply]
            )
        }
        throw ChannelSendError.unknownOutcome(underlying: "peer \(name) returned an A2A response without a task")
    }

    /// Fetches a task from a peer.
    /// - Parameters:
    ///   - id: Task id.
    ///   - peer: Peer name or `a2a:<peer>` target.
    /// - Returns: Task.
    public func getTask(id: String, from peer: String) async throws -> A2ATask {
        try await self.call(
            peer: Self.peerName(fromTarget: peer),
            methods: [A2AProtocol.getTaskMethod, "tasks/get"],
            params: A2AGetTaskParams(id: id)
        )
    }

    private func call<Params: Codable & Sendable & Equatable, Result: Codable & Sendable & Equatable>(
        peer name: String,
        methods: [String],
        params: Params
    ) async throws -> Result {
        guard let peer = self.peers[name] else {
            throw OpenClawCoreError.invalidConfiguration("Unknown A2A peer \(name)")
        }
        guard let raw = peer.url?.channelTrimmedNonEmpty,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host != nil
        else {
            throw OpenClawCoreError.invalidConfiguration("peer \(name) has no url configured for outbound A2A")
        }
        var headers = ["Accept": "application/json"]
        if let token = peer.outboundToken?.channelTrimmedNonEmpty {
            headers["Authorization"] = "Bearer \(token)"
        }
        for (attempt, method) in methods.enumerated() {
            let request = A2AJSONRPCRequest(method: method, params: params)
            let body = try JSONEncoder().encode(request)
            let urlRequest = ChannelHTTP.jsonRequest(url: url, body: body, headers: headers, timeout: Self.requestTimeout)
            let response: HTTPResponseData
            do {
                response = try await self.transport.data(for: urlRequest)
            } catch {
                throw ChannelSendError.classify(error)
            }
            if (300..<400).contains(response.statusCode) {
                throw ChannelSendError.rejected(status: response.statusCode, detail: "peer \(name) redirected the A2A request; redirects are refused")
            }
            if let error = ChannelSendError.classify(statusCode: response.statusCode, headers: response.headers, body: response.body) {
                throw error
            }
            let decoded: A2AJSONRPCResponse<Result>
            do {
                decoded = try JSONDecoder().decode(A2AJSONRPCResponse<Result>.self, from: response.body)
            } catch {
                throw ChannelSendError.unknownOutcome(underlying: "peer \(name) returned an invalid A2A JSON-RPC response")
            }
            if let error = decoded.error {
                if error.code == -32_601, attempt + 1 < methods.count {
                    continue
                }
                throw ChannelSendError.rejected(status: response.statusCode, detail: "outbound A2A request to peer \(name) failed: \(error.message)")
            }
            guard let result = decoded.result else {
                throw ChannelSendError.unknownOutcome(underlying: "peer \(name) returned an A2A response without a result")
            }
            return result
        }
        throw ChannelSendError.rejected(status: 0, detail: "outbound A2A request to peer \(name) exhausted its compatibility retry")
    }
}
