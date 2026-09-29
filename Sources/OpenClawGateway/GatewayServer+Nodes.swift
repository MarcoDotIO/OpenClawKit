import Foundation
import OpenClawCore
import OpenClawProtocol

// Presence (`system-presence`, `presence` events) and node pairing (`node.pair.*`, `node.list`,
// `node.rename`) for the in-process server. Presence entries are built as JSON objects (not the
// generated `PresenceEntry`, whose `Int` timestamps would trap on 32-bit watchOS).
extension GatewayServer {
    // MARK: - Presence

    /// Records an open client connection and emits a `presence` event.
    ///
    /// ``LoopbackGatewaySocket`` calls this on connect; transports bridging other sockets should too.
    /// - Parameter connection: Connection identity.
    public func connectionOpened(_ connection: GatewayConnectionContext) {
        let now = gatewayNowMs()
        self.connections[connection.connectionID] = ConnectionPresence(context: connection, onlineSince: now, lastActivityAt: now)
        self.broadcastPresence()
    }

    /// Forgets a closed connection (presence and session subscriptions) and emits a `presence` event.
    /// - Parameter connectionID: Connection identifier.
    public func connectionClosed(connectionID: String) {
        self.messageSubscriptions[connectionID] = nil
        self.sessionEventConnections.remove(connectionID)
        guard self.connections.removeValue(forKey: connectionID) != nil else { return }
        self.broadcastPresence()
    }

    /// Presence entries of the open connections (upstream `PresenceEntry` objects, `Int64` timestamps).
    public func presenceEntries() -> [AnyCodable] {
        self.connections.values
            .sorted { ($0.onlineSince, $0.context.connectionID) < ($1.onlineSince, $1.context.connectionID) }
            .map(Self.presencePayload)
    }

    func touchConnection(_ connectionID: String) {
        guard var presence = self.connections[connectionID] else { return }
        presence.lastActivityAt = gatewayNowMs()
        self.connections[connectionID] = presence
    }

    private func broadcastPresence() {
        self.broadcast(event: GatewayEventName.presence.rawValue, payload: AnyCodable(["presence": AnyCodable(self.presenceEntries())]))
    }

    private static func presencePayload(_ presence: ConnectionPresence) -> AnyCodable {
        let context = presence.context
        var entry: [String: AnyCodable] = [
            "ts": AnyCodable(presence.lastActivityAt),
            "onlineSince": AnyCodable(presence.onlineSince),
            "lastActivityAt": AnyCodable(presence.lastActivityAt),
            "reason": AnyCodable("connect"),
            "roles": AnyCodable([AnyCodable(context.role)]),
            "scopes": AnyCodable(context.scopes.map { AnyCodable($0) }),
        ]
        if let clientID = context.clientID { entry["clientId"] = AnyCodable(clientID) }
        if let mode = context.clientMode { entry["mode"] = AnyCodable(mode) }
        if let version = context.clientVersion { entry["version"] = AnyCodable(version) }
        if let platform = context.platform { entry["platform"] = AnyCodable(platform) }
        if let displayName = context.displayName {
            entry["host"] = AnyCodable(displayName)
            entry["text"] = AnyCodable(displayName)
        }
        if let instanceID = context.instanceID { entry["instanceId"] = AnyCodable(instanceID) }
        if let deviceID = context.deviceID { entry["deviceId"] = AnyCodable(deviceID) }
        return AnyCodable(entry)
    }

    // MARK: - Nodes

    func handleNodeBuiltin(_ builtin: BuiltinMethod, request: GatewayMethodRequest) async throws -> AnyCodable? {
        switch builtin {
        case .nodeList:
            let paired = await self.nodePairing.list().paired
            let connected = Set(self.connections.values.filter { $0.context.role == "node" }.compactMap { $0.context.deviceID ?? $0.context.instanceID })
            return AnyCodable([
                "ts": AnyCodable(gatewayNowMs()),
                "nodes": AnyCodable(paired.map { node in
                    var payload = Self.pairedNodePayload(node).dictionaryValue ?? [:]
                    payload["paired"] = AnyCodable(true)
                    payload["connected"] = AnyCodable(connected.contains(node.nodeID))
                    return AnyCodable(payload)
                }),
            ])
        case .nodePairList:
            let list = await self.nodePairing.list()
            return AnyCodable([
                "pending": try GatewayPayloadCodec.encode(list.pending),
                "paired": AnyCodable(list.paired.map(Self.pairedNodePayload)),
            ])
        case .nodePairApprove:
            let requestID = try Self.requiredParam(request, "requestId")
            // Upstream `approveNodePairing` with caller scopes: the declared commands decide the
            // scopes needed (admin for system.run and other admin-only commands, write for any
            // other command); a denied request stays pending.
            let connection = request.connection
            let approved = try await self.nodePairing.approve(requestID: requestID) { pending in
                let required = GatewayMethodScopePolicy.nodePairApprovalScopes(commands: pending.commands)
                if let missing = required.first(where: { !connection.allows(scope: $0) }) {
                    throw GatewayMethodError.missingScope(missing, requiredScopes: required)
                }
            }
            guard let node = approved else {
                throw GatewayMethodError.invalidRequest("unknown requestId")
            }
            self.broadcastNodeResolution(requestID: requestID, nodeID: node.nodeID, decision: "approved")
            return AnyCodable(["requestId": AnyCodable(requestID), "node": Self.pairedNodePayload(node)])
        case .nodePairReject:
            let requestID = try Self.requiredParam(request, "requestId")
            guard let rejected = await self.nodePairing.reject(requestID: requestID) else {
                throw GatewayMethodError.invalidRequest("unknown requestId")
            }
            self.broadcastNodeResolution(requestID: requestID, nodeID: rejected.nodeID, decision: "rejected")
            return try GatewayPayloadCodec.encode(rejected)
        case .nodePairRemove:
            let nodeID = try Self.requiredParam(request, "nodeId")
            guard let removed = await self.nodePairing.remove(nodeID: nodeID) else {
                throw GatewayMethodError.invalidRequest("unknown nodeId")
            }
            self.broadcastNodeResolution(requestID: "", nodeID: removed.nodeID, decision: "removed")
            // Node-role presence of the removed device ends with its pairing (upstream disconnects it).
            for (connectionID, presence) in self.connections where presence.context.role == "node"
                && (presence.context.deviceID == removed.nodeID || presence.context.instanceID == removed.nodeID)
            {
                self.connectionClosed(connectionID: connectionID)
            }
            return AnyCodable(["nodeId": AnyCodable(removed.nodeID)])
        case .nodeRename:
            let nodeID = try Self.requiredParam(request, "nodeId")
            guard let displayName = request.stringParam("displayName") else {
                throw GatewayMethodError.invalidRequest("displayName required")
            }
            guard let renamed = await self.nodePairing.rename(nodeID: nodeID, displayName: displayName) else {
                throw GatewayMethodError.invalidRequest("unknown nodeId")
            }
            return AnyCodable(["nodeId": AnyCodable(renamed.nodeID), "displayName": AnyCodable(displayName)])
        default:
            return nil
        }
    }

    private func broadcastNodeResolution(requestID: String, nodeID: String, decision: String) {
        self.broadcast(
            event: GatewayEventName.nodePairResolved.rawValue,
            payload: AnyCodable([
                "requestId": AnyCodable(requestID),
                "nodeId": AnyCodable(nodeID),
                "decision": AnyCodable(decision),
                "ts": AnyCodable(gatewayNowMs()),
            ])
        )
    }

    static func pairedNodePayload(_ node: GatewayNodePairingStore.PairedNode) -> AnyCodable {
        (try? GatewayPayloadCodec.encode(node)) ?? AnyCodable(["nodeId": AnyCodable(node.nodeID)])
    }

    static func requiredParam(_ request: GatewayMethodRequest, _ key: String) throws -> String {
        guard let value = request.stringParam(key) else {
            throw GatewayMethodError.invalidRequest("\(request.method) requires \(key)")
        }
        return value
    }
}
