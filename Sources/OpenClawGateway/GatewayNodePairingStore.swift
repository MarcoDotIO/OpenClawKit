import Foundation
import OpenClawProtocol

/// Node pairing records served by the in-process gateway (`node.pair.*`, `node.list`, `node.rename`).
///
/// The in-process server has no WebSocket node handshake of its own, so pending requests are added
/// by the host through ``request(nodeID:displayName:platform:version:deviceFamily:modelIdentifier:caps:commands:)``
/// (for example from a bridged node transport). Records live in memory and, with a file URL, are
/// persisted as JSON after each mutation.
public actor GatewayNodePairingStore {
    /// A node waiting for operator approval (upstream `NodePairingPendingRequest`).
    public struct PendingRequest: Codable, Sendable, Equatable {
        /// Request identifier.
        public var requestID: String
        /// Node identifier.
        public var nodeID: String
        /// Node display name.
        public var displayName: String?
        /// Node platform.
        public var platform: String?
        /// Node version.
        public var version: String?
        /// Device family.
        public var deviceFamily: String?
        /// Device model identifier.
        public var modelIdentifier: String?
        /// Declared capabilities.
        public var caps: [String]?
        /// Declared commands.
        public var commands: [String]?
        /// Request time (epoch milliseconds; wire key `ts`).
        public var requestedAtMs: Int64

        private enum CodingKeys: String, CodingKey {
            case requestID = "requestId"
            case nodeID = "nodeId"
            case displayName, platform, version, deviceFamily, modelIdentifier, caps, commands
            case requestedAtMs = "ts"
        }
    }

    /// An approved node (upstream `NodePairingPairedNode`).
    public struct PairedNode: Codable, Sendable, Equatable {
        /// Node identifier.
        public var nodeID: String
        /// Node display name.
        public var displayName: String?
        /// Node platform.
        public var platform: String?
        /// Node version.
        public var version: String?
        /// Device family.
        public var deviceFamily: String?
        /// Device model identifier.
        public var modelIdentifier: String?
        /// Approved capabilities.
        public var caps: [String]?
        /// Approved commands.
        public var commands: [String]?
        /// Approval time (epoch milliseconds).
        public var approvedAtMs: Int64

        /// Creates a paired node record.
        /// - Parameters:
        ///   - nodeID: Node identifier.
        ///   - displayName: Display name.
        ///   - platform: Platform.
        ///   - version: Version.
        ///   - deviceFamily: Device family.
        ///   - modelIdentifier: Model identifier.
        ///   - caps: Capabilities.
        ///   - commands: Commands.
        ///   - approvedAtMs: Approval time in epoch milliseconds.
        public init(
            nodeID: String,
            displayName: String? = nil,
            platform: String? = nil,
            version: String? = nil,
            deviceFamily: String? = nil,
            modelIdentifier: String? = nil,
            caps: [String]? = nil,
            commands: [String]? = nil,
            approvedAtMs: Int64
        ) {
            self.nodeID = nodeID
            self.displayName = displayName
            self.platform = platform
            self.version = version
            self.deviceFamily = deviceFamily
            self.modelIdentifier = modelIdentifier
            self.caps = caps
            self.commands = commands
            self.approvedAtMs = approvedAtMs
        }

        private enum CodingKeys: String, CodingKey {
            case nodeID = "nodeId"
            case displayName, platform, version, deviceFamily, modelIdentifier, caps, commands, approvedAtMs
        }
    }

    private struct Snapshot: Codable {
        var pending: [PendingRequest]
        var paired: [PairedNode]
    }

    private let fileURL: URL?
    private var pending: [String: PendingRequest] = [:]
    private var paired: [String: PairedNode] = [:]

    /// Creates a store.
    /// - Parameter fileURL: Optional JSON file; loaded now and rewritten after each mutation.
    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
        {
            self.pending = Dictionary(snapshot.pending.map { ($0.requestID, $0) }, uniquingKeysWith: { _, last in last })
            self.paired = Dictionary(snapshot.paired.map { ($0.nodeID, $0) }, uniquingKeysWith: { _, last in last })
        }
    }

    /// Pending requests (oldest first) and paired nodes (by node id).
    public func list() -> (pending: [PendingRequest], paired: [PairedNode]) {
        (
            self.pending.values.sorted { ($0.requestedAtMs, $0.requestID) < ($1.requestedAtMs, $1.requestID) },
            self.paired.values.sorted { $0.nodeID < $1.nodeID }
        )
    }

    /// Paired node by identifier.
    /// - Parameter nodeID: Node identifier.
    public func pairedNode(_ nodeID: String) -> PairedNode? {
        self.paired[nodeID]
    }

    /// Records (or refreshes) a pending pairing request for a node.
    /// - Parameters:
    ///   - nodeID: Node identifier.
    ///   - displayName: Display name.
    ///   - platform: Platform.
    ///   - version: Version.
    ///   - deviceFamily: Device family.
    ///   - modelIdentifier: Model identifier.
    ///   - caps: Declared capabilities.
    ///   - commands: Declared commands.
    /// - Returns: The pending request (an existing request for the same node is reused).
    @discardableResult
    public func request(
        nodeID: String,
        displayName: String? = nil,
        platform: String? = nil,
        version: String? = nil,
        deviceFamily: String? = nil,
        modelIdentifier: String? = nil,
        caps: [String]? = nil,
        commands: [String]? = nil
    ) -> PendingRequest {
        let existingID = self.pending.values.first { $0.nodeID == nodeID }?.requestID
        let request = PendingRequest(
            requestID: existingID ?? UUID().uuidString.lowercased(),
            nodeID: nodeID,
            displayName: displayName,
            platform: platform,
            version: version,
            deviceFamily: deviceFamily,
            modelIdentifier: modelIdentifier,
            caps: caps,
            commands: commands,
            requestedAtMs: gatewayNowMs()
        )
        self.pending[request.requestID] = request
        self.persist()
        return request
    }

    /// Approves a pending request.
    /// - Parameter requestID: Request identifier.
    /// - Returns: The paired node, or `nil` for an unknown request.
    public func approve(requestID: String) -> PairedNode? {
        // A non-throwing authorizer never fails.
        (try? self.approve(requestID: requestID) { _ in }) ?? nil
    }

    /// Approves a pending request after `authorize` accepts it, atomically on the store's actor.
    ///
    /// When `authorize` throws, the request stays pending and the error is rethrown; the gateway uses
    /// this to require the scopes the declared commands need (``GatewayMethodScopePolicy/nodePairApprovalScopes(commands:)``).
    /// - Parameters:
    ///   - requestID: Request identifier.
    ///   - authorize: Check run against the pending request before it is approved.
    /// - Returns: The paired node, or `nil` for an unknown request.
    /// - Throws: The error thrown by `authorize`.
    public func approve(requestID: String, authorize: @Sendable (PendingRequest) throws -> Void) throws -> PairedNode? {
        guard let pendingRequest = self.pending[requestID] else { return nil }
        try authorize(pendingRequest)
        guard let request = self.pending.removeValue(forKey: requestID) else { return nil }
        let node = PairedNode(
            nodeID: request.nodeID,
            displayName: request.displayName,
            platform: request.platform,
            version: request.version,
            deviceFamily: request.deviceFamily,
            modelIdentifier: request.modelIdentifier,
            caps: request.caps,
            commands: request.commands,
            approvedAtMs: gatewayNowMs()
        )
        self.paired[node.nodeID] = node
        self.persist()
        return node
    }

    /// Rejects a pending request.
    /// - Parameter requestID: Request identifier.
    /// - Returns: The rejected request, or `nil` for an unknown request.
    public func reject(requestID: String) -> PendingRequest? {
        guard let request = self.pending.removeValue(forKey: requestID) else { return nil }
        self.persist()
        return request
    }

    /// Removes a paired node (upstream `node.pair.remove`).
    /// - Parameter nodeID: Node identifier.
    /// - Returns: The removed node, or `nil` for an unknown node.
    public func remove(nodeID: String) -> PairedNode? {
        guard let node = self.paired.removeValue(forKey: nodeID) else { return nil }
        self.persist()
        return node
    }

    /// Renames a paired node.
    /// - Parameters:
    ///   - nodeID: Node identifier.
    ///   - displayName: New display name.
    /// - Returns: The renamed node, or `nil` for an unknown node.
    public func rename(nodeID: String, displayName: String) -> PairedNode? {
        guard var node = self.paired[nodeID] else { return nil }
        node.displayName = displayName
        self.paired[nodeID] = node
        self.persist()
        return node
    }

    /// Inserts or replaces a paired node (for hosts that approve nodes out of band).
    /// - Parameter node: Paired node.
    public func upsert(_ node: PairedNode) {
        self.paired[node.nodeID] = node
        self.persist()
    }

    private func persist() {
        guard let fileURL else { return }
        let list = self.list()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(Snapshot(pending: list.pending, paired: list.paired)) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: [.atomic])
    }
}
