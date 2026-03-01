import Foundation
import OpenClawCore

/// Aggregate metrics captured for one provider in adaptive routing state.
public struct AdaptiveRoutingProviderMetrics: Sendable, Equatable {
    public let providerID: String
    public let sampleCount: Int
    public let failureCount: Int
    public let averageLatencyMs: Int
    public let averageCostUSD: Double
    public let averageQualityScore: Double

    /// Creates provider metrics.
    public init(
        providerID: String,
        sampleCount: Int,
        failureCount: Int,
        averageLatencyMs: Int,
        averageCostUSD: Double,
        averageQualityScore: Double
    ) {
        self.providerID = providerID
        self.sampleCount = max(0, sampleCount)
        self.failureCount = max(0, failureCount)
        self.averageLatencyMs = max(0, averageLatencyMs)
        self.averageCostUSD = max(0, averageCostUSD)
        self.averageQualityScore = min(max(0, averageQualityScore), 1)
    }
}

/// Deterministic provider score emitted by adaptive policy.
public struct AdaptiveRoutingScore: Sendable, Equatable {
    public let providerID: String
    public let score: Double
    public let metrics: AdaptiveRoutingProviderMetrics

    /// Creates a provider score payload.
    public init(providerID: String, score: Double, metrics: AdaptiveRoutingProviderMetrics) {
        self.providerID = providerID
        self.score = score
        self.metrics = metrics
    }
}

/// Snapshot of adaptive routing state and ranked provider scores.
public struct AdaptiveRoutingSnapshot: Sendable, Equatable {
    public let objective: AdaptiveRoutingObjective
    public let providers: [AdaptiveRoutingScore]

    /// Creates an adaptive routing snapshot.
    public init(objective: AdaptiveRoutingObjective, providers: [AdaptiveRoutingScore]) {
        self.objective = objective
        self.providers = providers
    }
}

/// Mutable adaptive provider-policy state.
public struct AdaptiveRoutingPolicy: Sendable {
    private struct Observation: Sendable {
        let succeeded: Bool
        let latencyMs: Int
        let costUSD: Double
        let qualityScore: Double
    }

    private let config: AdaptiveRoutingConfig
    private var observationsByProvider: [String: [Observation]]

    /// Creates adaptive routing policy state.
    /// - Parameter config: Adaptive routing configuration.
    public init(config: AdaptiveRoutingConfig) {
        self.config = config
        self.observationsByProvider = [:]
    }

    /// Records one provider observation.
    /// - Parameters:
    ///   - providerID: Provider identifier.
    ///   - succeeded: Whether request succeeded.
    ///   - latencyMs: End-to-end latency.
    ///   - costUSD: Optional cost estimate.
    ///   - qualityScore: Optional quality score (`0...1`).
    public mutating func record(
        providerID: String,
        succeeded: Bool,
        latencyMs: Int,
        costUSD: Double?,
        qualityScore: Double?
    ) {
        let normalizedProvider = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedProvider.isEmpty else {
            return
        }
        let observation = Observation(
            succeeded: succeeded,
            latencyMs: max(0, latencyMs),
            costUSD: max(0, costUSD ?? 0),
            qualityScore: min(max(0, qualityScore ?? 0.5), 1)
        )
        var observations = self.observationsByProvider[normalizedProvider] ?? []
        observations.append(observation)
        if observations.count > self.config.decisionWindow {
            observations.removeFirst(observations.count - self.config.decisionWindow)
        }
        self.observationsByProvider[normalizedProvider] = observations
    }

    /// Returns providers ranked by policy score.
    /// - Parameter providerIDs: Candidate providers.
    /// - Returns: Deterministically ranked provider identifiers.
    public func rankedProviderIDs(from providerIDs: [String]) -> [String] {
        let unique = Array(Set(providerIDs)).sorted()
        let snapshot = self.snapshot(for: unique)
        let ranked = snapshot.providers.sorted { lhs, rhs in
            if lhs.score == rhs.score {
                return lhs.providerID < rhs.providerID
            }
            return lhs.score > rhs.score
        }
        return ranked.map(\.providerID)
    }

    /// Returns scoring snapshot for candidate providers.
    /// - Parameter providerIDs: Candidate providers.
    /// - Returns: Snapshot with scores and raw metrics.
    public func snapshot(for providerIDs: [String]) -> AdaptiveRoutingSnapshot {
        let unique = Array(Set(providerIDs)).sorted()
        let scores = unique.map { providerID in
            let metrics = self.metrics(for: providerID)
            let score = self.score(for: metrics)
            return AdaptiveRoutingScore(providerID: providerID, score: score, metrics: metrics)
        }
        return AdaptiveRoutingSnapshot(objective: self.config.objective, providers: scores)
    }

    private func metrics(for providerID: String) -> AdaptiveRoutingProviderMetrics {
        let observations = self.observationsByProvider[providerID] ?? []
        guard !observations.isEmpty else {
            return AdaptiveRoutingProviderMetrics(
                providerID: providerID,
                sampleCount: 0,
                failureCount: 0,
                averageLatencyMs: 0,
                averageCostUSD: 0,
                averageQualityScore: 0.5
            )
        }

        let failures = observations.filter { !$0.succeeded }.count
        let totalLatency = observations.reduce(0) { $0 + $1.latencyMs }
        let totalCost = observations.reduce(0.0) { $0 + $1.costUSD }
        let totalQuality = observations.reduce(0.0) { $0 + $1.qualityScore }
        let count = observations.count
        return AdaptiveRoutingProviderMetrics(
            providerID: providerID,
            sampleCount: count,
            failureCount: failures,
            averageLatencyMs: totalLatency / count,
            averageCostUSD: totalCost / Double(count),
            averageQualityScore: totalQuality / Double(count)
        )
    }

    private func score(for metrics: AdaptiveRoutingProviderMetrics) -> Double {
        let sampleCount = max(1, metrics.sampleCount)
        let successRate = Double(sampleCount - metrics.failureCount) / Double(sampleCount)
        let latencyScore = 1.0 / (1.0 + (Double(metrics.averageLatencyMs) / 1_000.0))
        let costScore = 1.0 / (1.0 + metrics.averageCostUSD)
        let qualityScore = metrics.averageQualityScore

        let weightedScore: Double
        switch self.config.objective {
        case .balanced:
            weightedScore = (0.45 * successRate) + (0.30 * latencyScore) + (0.15 * costScore) + (0.10 * qualityScore)
        case .latency:
            weightedScore = (0.25 * successRate) + (0.60 * latencyScore) + (0.10 * costScore) + (0.05 * qualityScore)
        case .cost:
            weightedScore = (0.25 * successRate) + (0.10 * latencyScore) + (0.55 * costScore) + (0.10 * qualityScore)
        case .quality:
            weightedScore = (0.25 * successRate) + (0.15 * latencyScore) + (0.10 * costScore) + (0.50 * qualityScore)
        }

        let explorationBoost = metrics.sampleCount < self.config.minSamplesPerProvider
            ? self.config.explorationRate
            : 0
        return weightedScore + explorationBoost
    }
}
