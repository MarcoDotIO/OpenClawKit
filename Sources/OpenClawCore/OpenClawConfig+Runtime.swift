import Foundation

/// Runtime behavior controls for replay and adaptive routing.
public struct RuntimeConfig: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var replay: ReplayConfig
    public var adaptiveRouting: AdaptiveRoutingConfig
    public var memoryGraph: MemoryGraphConfig

    /// Creates runtime behavior settings.
    /// - Parameters:
    ///   - schemaVersion: Runtime config schema version.
    ///   - replay: Replay event/capture settings.
    ///   - adaptiveRouting: Adaptive model routing settings.
    ///   - memoryGraph: SwiftData+CloudKit memory graph settings.
    public init(
        schemaVersion: Int = ReplayEvent.currentSchemaVersion,
        replay: ReplayConfig = ReplayConfig(),
        adaptiveRouting: AdaptiveRoutingConfig = AdaptiveRoutingConfig(),
        memoryGraph: MemoryGraphConfig = MemoryGraphConfig()
    ) {
        self.schemaVersion = max(1, schemaVersion)
        self.replay = replay
        self.adaptiveRouting = adaptiveRouting
        self.memoryGraph = memoryGraph
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case replay
        case adaptiveRouting
        case memoryGraph
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = max(
            1,
            try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? ReplayEvent.currentSchemaVersion
        )
        self.replay = try container.decodeIfPresent(ReplayConfig.self, forKey: .replay) ?? ReplayConfig()
        self.adaptiveRouting = try container.decodeIfPresent(
            AdaptiveRoutingConfig.self,
            forKey: .adaptiveRouting
        ) ?? AdaptiveRoutingConfig()
        self.memoryGraph = try container.decodeIfPresent(MemoryGraphConfig.self, forKey: .memoryGraph)
            ?? MemoryGraphConfig()
    }
}

/// Replay capture controls.
public struct ReplayConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var persistToDisk: Bool
    public var maxInMemoryEvents: Int
    public var storePath: String?
    public var signEvents: Bool

    /// Creates replay settings.
    /// - Parameters:
    ///   - enabled: Enables replay event capture.
    ///   - persistToDisk: Persists replay events to file-backed storage.
    ///   - maxInMemoryEvents: Maximum replay events retained in memory.
    ///   - storePath: Optional custom replay store path.
    ///   - signEvents: Enables event signing.
    public init(
        enabled: Bool = false,
        persistToDisk: Bool = true,
        maxInMemoryEvents: Int = 10_000,
        storePath: String? = nil,
        signEvents: Bool = false
    ) {
        self.enabled = enabled
        self.persistToDisk = persistToDisk
        self.maxInMemoryEvents = max(1, maxInMemoryEvents)
        self.storePath = storePath
        self.signEvents = signEvents
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case persistToDisk
        case maxInMemoryEvents
        case storePath
        case signEvents
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        self.persistToDisk = try container.decodeIfPresent(Bool.self, forKey: .persistToDisk) ?? true
        self.maxInMemoryEvents = max(1, try container.decodeIfPresent(Int.self, forKey: .maxInMemoryEvents) ?? 10_000)
        self.storePath = try container.decodeIfPresent(String.self, forKey: .storePath)
        self.signEvents = try container.decodeIfPresent(Bool.self, forKey: .signEvents) ?? false
    }
}

/// SwiftData + CloudKit memory graph controls.
public struct MemoryGraphConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var swiftDataEnabled: Bool
    public var cloudKitSyncEnabled: Bool
    public var cloudKitContainerID: String?
    public var legacyStorePath: String?

    /// Creates memory graph settings.
    /// - Parameters:
    ///   - enabled: Enables memory graph storage.
    ///   - swiftDataEnabled: Enables SwiftData backing where available.
    ///   - cloudKitSyncEnabled: Enables CloudKit sync where available.
    ///   - cloudKitContainerID: Optional CloudKit container identifier.
    ///   - legacyStorePath: Optional legacy JSON store path used for migration.
    public init(
        enabled: Bool = false,
        swiftDataEnabled: Bool = true,
        cloudKitSyncEnabled: Bool = false,
        cloudKitContainerID: String? = nil,
        legacyStorePath: String? = nil
    ) {
        self.enabled = enabled
        self.swiftDataEnabled = swiftDataEnabled
        self.cloudKitSyncEnabled = cloudKitSyncEnabled
        self.cloudKitContainerID = cloudKitContainerID
        self.legacyStorePath = legacyStorePath
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case swiftDataEnabled
        case cloudKitSyncEnabled
        case cloudKitContainerID
        case legacyStorePath
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        self.swiftDataEnabled = try container.decodeIfPresent(Bool.self, forKey: .swiftDataEnabled) ?? true
        self.cloudKitSyncEnabled = try container.decodeIfPresent(Bool.self, forKey: .cloudKitSyncEnabled) ?? false
        self.cloudKitContainerID = try container.decodeIfPresent(String.self, forKey: .cloudKitContainerID)
        self.legacyStorePath = try container.decodeIfPresent(String.self, forKey: .legacyStorePath)
    }
}

/// Optimization objective for adaptive routing policy.
public enum AdaptiveRoutingObjective: String, Codable, Sendable, Equatable, CaseIterable {
    case balanced
    case latency
    case cost
    case quality
}

/// Runtime adaptive model routing controls.
public struct AdaptiveRoutingConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var minSamplesPerProvider: Int
    public var explorationRate: Double
    public var decisionWindow: Int
    public var objective: AdaptiveRoutingObjective

    /// Creates adaptive routing settings.
    /// - Parameters:
    ///   - enabled: Enables adaptive provider ordering.
    ///   - minSamplesPerProvider: Minimum samples before hard ranking.
    ///   - explorationRate: Probability of non-greedy exploration (`0...1`).
    ///   - decisionWindow: Number of recent calls considered for scoring.
    ///   - objective: Optimization objective.
    public init(
        enabled: Bool = false,
        minSamplesPerProvider: Int = 20,
        explorationRate: Double = 0.05,
        decisionWindow: Int = 500,
        objective: AdaptiveRoutingObjective = .balanced
    ) {
        self.enabled = enabled
        self.minSamplesPerProvider = max(1, minSamplesPerProvider)
        self.explorationRate = min(max(0, explorationRate), 1)
        self.decisionWindow = max(1, decisionWindow)
        self.objective = objective
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case minSamplesPerProvider
        case explorationRate
        case decisionWindow
        case objective
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        self.minSamplesPerProvider = max(
            1,
            try container.decodeIfPresent(Int.self, forKey: .minSamplesPerProvider) ?? 20
        )
        self.explorationRate = min(
            max(0, try container.decodeIfPresent(Double.self, forKey: .explorationRate) ?? 0.05),
            1
        )
        self.decisionWindow = max(1, try container.decodeIfPresent(Int.self, forKey: .decisionWindow) ?? 500)
        self.objective = try container.decodeIfPresent(AdaptiveRoutingObjective.self, forKey: .objective) ?? .balanced
    }
}
