import Foundation

/// Node kinds represented in the OpenClaw intent graph.
public enum IntentGraphNodeKind: String, Codable, Sendable, Equatable {
    case run
    case prompt
    case tool
    case skill
    case model
    case output
    case channel
    case memory
}

/// Edge kinds represented in the OpenClaw intent graph.
public enum IntentGraphEdgeKind: String, Codable, Sendable, Equatable {
    case initiates
    case invokes
    case feeds
    case produces
    case reads
    case writes
    case triggers
    case routes
}

/// One intent-graph node.
public struct IntentGraphNode: Codable, Sendable, Equatable, Identifiable {
    /// Stable node identifier.
    public let id: String
    /// Semantic node kind.
    public let kind: IntentGraphNodeKind
    /// Human-readable label.
    public let title: String
    /// Optional structured metadata.
    public let metadata: [String: String]

    /// Creates one graph node.
    /// - Parameters:
    ///   - id: Stable node identifier.
    ///   - kind: Semantic node kind.
    ///   - title: Human-readable node label.
    ///   - metadata: Optional metadata bag.
    public init(
        id: String,
        kind: IntentGraphNodeKind,
        title: String,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.metadata = metadata
    }
}

/// One directed intent-graph edge.
public struct IntentGraphEdge: Codable, Sendable, Equatable {
    /// Source node identifier.
    public let sourceID: String
    /// Target node identifier.
    public let targetID: String
    /// Semantic edge kind.
    public let kind: IntentGraphEdgeKind
    /// Optional structured metadata.
    public let metadata: [String: String]

    /// Creates one graph edge.
    /// - Parameters:
    ///   - sourceID: Source node identifier.
    ///   - targetID: Target node identifier.
    ///   - kind: Semantic edge kind.
    ///   - metadata: Optional metadata bag.
    public init(
        sourceID: String,
        targetID: String,
        kind: IntentGraphEdgeKind,
        metadata: [String: String] = [:]
    ) {
        self.sourceID = sourceID
        self.targetID = targetID
        self.kind = kind
        self.metadata = metadata
    }
}

/// Serializable intent graph for one run plan/execution.
public struct IntentGraph: Codable, Sendable, Equatable {
    /// Current graph schema version.
    public static let currentSchemaVersion = 1

    /// Graph schema version.
    public let schemaVersion: Int
    /// Stable graph identifier.
    public let graphID: String
    /// Correlated run identifier.
    public let runID: String
    /// Correlated session key.
    public let sessionKey: String
    /// Graph creation timestamp.
    public let createdAt: Date
    /// Graph nodes.
    public let nodes: [IntentGraphNode]
    /// Graph edges.
    public let edges: [IntentGraphEdge]

    /// Creates a complete intent graph.
    /// - Parameters:
    ///   - schemaVersion: Schema version.
    ///   - graphID: Graph identifier.
    ///   - runID: Correlated run identifier.
    ///   - sessionKey: Correlated session key.
    ///   - createdAt: Creation timestamp.
    ///   - nodes: Graph nodes.
    ///   - edges: Graph edges.
    public init(
        schemaVersion: Int = IntentGraph.currentSchemaVersion,
        graphID: String = UUID().uuidString,
        runID: String,
        sessionKey: String,
        createdAt: Date = Date(),
        nodes: [IntentGraphNode],
        edges: [IntentGraphEdge]
    ) {
        self.schemaVersion = schemaVersion
        self.graphID = graphID
        self.runID = runID
        self.sessionKey = sessionKey
        self.createdAt = createdAt
        self.nodes = nodes
        self.edges = edges
    }

    /// Looks up one node by identifier.
    /// - Parameter id: Node identifier.
    /// - Returns: Matching node if found.
    public func node(id: String) -> IntentGraphNode? {
        self.nodes.first(where: { $0.id == id })
    }

    /// Returns outgoing edges for one node.
    /// - Parameter nodeID: Source node identifier.
    /// - Returns: Outgoing edges.
    public func outgoingEdges(from nodeID: String) -> [IntentGraphEdge] {
        self.edges.filter { $0.sourceID == nodeID }
    }

    /// Returns incoming edges for one node.
    /// - Parameter nodeID: Target node identifier.
    /// - Returns: Incoming edges.
    public func incomingEdges(to nodeID: String) -> [IntentGraphEdge] {
        self.edges.filter { $0.targetID == nodeID }
    }
}
