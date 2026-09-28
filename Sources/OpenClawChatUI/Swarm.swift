import Foundation
import OpenClawKit

// Ported from upstream OpenClaw 2026.9.6 `Swarm.swift` (projection model and view-model integration).
// The Swarm progress views belong with the transcript views.

private let maxTrackedSwarmGroups = 10000
private let maxTrackedSwarmChildren = 100_000
private let maxRenderedSwarmDotsPerPhase = 256
private let swarmRefreshRetryDelays = [1.0, 2.0, 4.0]

/// Live Swarm phase/log state folded from `sessions.changed` notes.
struct OpenClawChatSwarmActivityState: Equatable {
    private var currentPhaseByGroup: [String: String] = [:]
    private var phaseRankByGroupPhase: [String: Int] = [:]
    private var nextPhaseRank = 0
    private var latestLogByGroup: [String: String] = [:]
    private var phaseByChild: [String: String] = [:]

    mutating func clear() {
        self = OpenClawChatSwarmActivityState()
    }

    mutating func observe(_ event: OpenClawChatSessionsChangedEvent) -> Bool {
        guard let groupID = ChatPayloadDecoding.trimmedNonEmptyString(event.swarmGroupId) else { return false }
        let kind = ChatPayloadDecoding.trimmedNonEmptyString(event.kind)
        let text = ChatPayloadDecoding.trimmedNonEmptyString(event.text)
        if let text, kind == "phase" || kind == "log" {
            if kind == "phase" {
                let rankKey = Self.phaseRankKey(groupID: groupID, phase: text)
                if self.phaseRankByGroupPhase[rankKey] == nil {
                    Self.setBounded(
                        &self.phaseRankByGroupPhase,
                        key: rankKey,
                        value: self.nextPhaseRank,
                        limit: maxTrackedSwarmChildren)
                    self.nextPhaseRank += 1
                }
                Self.setBounded(
                    &self.currentPhaseByGroup,
                    key: groupID,
                    value: text,
                    limit: maxTrackedSwarmGroups)
            } else {
                Self.setBounded(
                    &self.latestLogByGroup,
                    key: groupID,
                    value: text,
                    limit: maxTrackedSwarmGroups)
            }
            return true
        }

        guard let childKey = ChatPayloadDecoding.trimmedNonEmptyString(event.sessionKey) else { return true }
        if let phase = ChatPayloadDecoding.trimmedNonEmptyString(event.swarmPhase) {
            Self.setBounded(
                &self.phaseByChild,
                key: childKey,
                value: phase,
                limit: maxTrackedSwarmChildren)
            return true
        }
        if event.reason == "create",
           self.phaseByChild[childKey] == nil,
           let currentPhase = currentPhaseByGroup[groupID]
        {
            Self.setBounded(
                &self.phaseByChild,
                key: childKey,
                value: currentPhase,
                limit: maxTrackedSwarmChildren)
        }
        return true
    }

    func decorate(_ sessions: [OpenClawChatSessionEntry]) -> [OpenClawChatSessionEntry] {
        sessions.map { row in
            guard let groupID = ChatPayloadDecoding.trimmedNonEmptyString(row.swarmGroupId) else { return row }
            let phase = self.phaseByChild[row.key] ?? row.swarmPhase
            let rank = phase.flatMap { self.phaseRankByGroupPhase[Self.phaseRankKey(groupID: groupID, phase: $0)] }
                ?? row.swarmPhaseRank
            let log = self.latestLogByGroup[groupID] ?? row.swarmLog
            var decorated = row
            decorated.swarmPhase = phase
            decorated.swarmPhaseRank = rank
            decorated.swarmLog = log
            return decorated
        }
    }

    private static func phaseRankKey(groupID: String, phase: String) -> String {
        "\(groupID)\u{0}\(phase)"
    }

    private static func setBounded<Value>(
        _ values: inout [String: Value],
        key: String,
        value: Value,
        limit: Int)
    {
        if values[key] == nil, values.count >= limit, let evicted = values.keys.first {
            values.removeValue(forKey: evicted)
        }
        values[key] = value
    }
}

/// Status of one Swarm worker dot.
enum OpenClawChatSwarmDotStatus: Int, Comparable, Sendable {
    case running
    case queued
    case failed
    case done

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .running: String(localized: "Running")
        case .queued: String(localized: "Queued")
        case .failed: String(localized: "Failed")
        case .done: String(localized: "Done")
        }
    }
}

/// One Swarm worker.
struct OpenClawChatSwarmDot: Identifiable, Sendable {
    let id: String
    let label: String
    let status: OpenClawChatSwarmDotStatus
}

/// Swarm workers grouped by phase.
struct OpenClawChatSwarmPhase: Identifiable, Sendable {
    let id: String
    let title: String?
    let dots: [OpenClawChatSwarmDot]
    let hidden: Int
}

/// One live Swarm group under the current session.
struct OpenClawChatSwarmGroup: Identifiable, Sendable {
    let id: String
    let label: String
    let running: Int
    let done: Int
    let failed: Int
    let narrator: String?
    let phases: [OpenClawChatSwarmPhase]
}

/// Groups child rows into live Swarm groups owned by the parent session.
func buildOpenClawChatSwarmGroups(
    sessions: [OpenClawChatSessionEntry],
    matchesParent: (String) -> Bool) -> [OpenClawChatSwarmGroup]
{
    struct Entry {
        let phase: String?
        let phaseRank: Int
        let log: String?
        let dot: OpenClawChatSwarmDot
    }

    var byGroup: [String: [Entry]] = [:]
    for row in sessions {
        guard let groupID = row.swarmGroupId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !groupID.isEmpty,
              SelfContainedSwarmHelpers.belongsToParent(row, groupID: groupID, matchesParent: matchesParent),
              let status = SelfContainedSwarmHelpers.status(row)
        else { continue }
        let label = [row.label, row.displayName, row.derivedTitle, row.key]
            .compactMap { value -> String? in
                let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines)
                return normalized?.isEmpty == false ? normalized : nil
            }
            .first ?? row.key
        byGroup[groupID, default: []].append(Entry(
            phase: row.swarmPhase?.trimmingCharacters(in: .whitespacesAndNewlines),
            phaseRank: row.swarmPhaseRank ?? .max,
            log: row.swarmLog?.trimmingCharacters(in: .whitespacesAndNewlines),
            dot: OpenClawChatSwarmDot(id: row.key, label: label, status: status)))
    }

    return byGroup.map { groupID, entries in
        var phaseBuckets: [String: (title: String?, rank: Int, dots: [OpenClawChatSwarmDot])] = [:]
        for entry in entries {
            let phaseKey = entry.phase?.isEmpty == false ? entry.phase! : "\u{0}"
            var bucket = phaseBuckets[phaseKey] ?? (entry.phase, entry.phaseRank, [])
            bucket.rank = min(bucket.rank, entry.phaseRank)
            bucket.dots.append(entry.dot)
            phaseBuckets[phaseKey] = bucket
        }
        let phases = phaseBuckets.map { key, bucket -> OpenClawChatSwarmPhase in
            let ordered = bucket.dots.count > maxRenderedSwarmDotsPerPhase
                ? bucket.dots.sorted { $0.status < $1.status }
                : bucket.dots
            return OpenClawChatSwarmPhase(
                id: key,
                title: bucket.title,
                dots: Array(ordered.prefix(maxRenderedSwarmDotsPerPhase)),
                hidden: max(0, ordered.count - maxRenderedSwarmDotsPerPhase))
        }.sorted { lhs, rhs in
            let leftRank = phaseBuckets[lhs.id]?.rank ?? .max
            let rightRank = phaseBuckets[rhs.id]?.rank ?? .max
            if leftRank != rightRank {
                return leftRank < rightRank
            }
            return lhs.id < rhs.id
        }
        let dots = entries.map(\.dot)
        return OpenClawChatSwarmGroup(
            id: groupID,
            label: groupID.split(separator: ":").last.map(String.init) ?? groupID,
            running: dots.count { $0.status == .running },
            done: dots.count { $0.status == .done },
            failed: dots.count { $0.status == .failed },
            narrator: entries.compactMap(\.log).first { !$0.isEmpty },
            phases: phases)
    }.filter { group in
        group.phases.contains { phase in
            phase.dots.contains { $0.status == .queued || $0.status == .running }
        }
    }.sorted { $0.id < $1.id }
}

/// Swarm row classification helpers.
enum SelfContainedSwarmHelpers {
    static func status(_ row: OpenClawChatSessionEntry) -> OpenClawChatSwarmDotStatus? {
        if row.status == "queued" {
            return .queued
        }
        if row.status == "running" || row.hasActiveRun == true {
            return .running
        }
        if row.status == "done" {
            return .done
        }
        if row.status == "failed" || row.status == "killed" || row.status == "timeout" {
            return .failed
        }
        return row.subagentRunState == "active" || row.hasActiveSubagentRun == true ? .queued : nil
    }

    static func belongsToParent(
        _ row: OpenClawChatSessionEntry,
        groupID: String,
        matchesParent: (String) -> Bool) -> Bool
    {
        if let parent = row.parentSessionKey, matchesParent(parent) {
            return true
        }
        if let spawnedBy = row.spawnedBy, matchesParent(spawnedBy) {
            return true
        }
        return self.generatedGroupBelongsToParent(groupID, matchesParent: matchesParent)
    }

    static func isActivityNote(_ event: OpenClawChatSessionsChangedEvent) -> Bool {
        let kind = ChatPayloadDecoding.trimmedNonEmptyString(event.kind)
        return kind == "phase" || kind == "log"
    }

    static func eventBelongsToParent(
        _ event: OpenClawChatSessionsChangedEvent,
        matchesParent: (String) -> Bool) -> Bool
    {
        if let parent = ChatPayloadDecoding.trimmedNonEmptyString(event.parentSessionKey)
            ?? ChatPayloadDecoding.trimmedNonEmptyString(event.spawnedBy)
        {
            return matchesParent(parent)
        }
        let kind = ChatPayloadDecoding.trimmedNonEmptyString(event.kind)
        if kind == "phase" || kind == "log" {
            guard let sessionKey = ChatPayloadDecoding.trimmedNonEmptyString(event.sessionKey) else { return false }
            return matchesParent(sessionKey)
        }
        guard let groupID = ChatPayloadDecoding.trimmedNonEmptyString(event.swarmGroupId) else { return false }
        return self.generatedGroupBelongsToParent(groupID, matchesParent: matchesParent)
    }

    private static func generatedGroupBelongsToParent(
        _ groupID: String,
        matchesParent: (String) -> Bool) -> Bool
    {
        let parts = groupID.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.first == "swarm", parts.count > 2 else { return false }
        return matchesParent(parts.dropFirst().dropLast().joined(separator: ":"))
    }
}

extension OpenClawChatViewModel {
    private func updateSwarmProjection() {
        self.activeSwarmGroups = buildOpenClawChatSwarmGroups(sessions: self.swarmSessions) { candidate in
            self.matchesCurrentSessionKey(incoming: candidate, current: self.sessionKey)
        }
    }

    func observeSwarmEvent(_ event: OpenClawChatSessionsChangedEvent) -> Bool {
        guard swarmEnabled,
              SelfContainedSwarmHelpers.eventBelongsToParent(event, matchesParent: { candidate in
                  self.matchesCurrentSessionKey(
                      incoming: candidate,
                      agentId: event.agentId,
                      current: self.sessionKey)
              })
        else { return false }
        var nextActivity = swarmActivityState
        guard nextActivity.observe(event) else { return false }
        swarmActivityState = nextActivity
        swarmSessions = nextActivity.decorate(swarmSessions)
        self.updateSwarmProjection()
        if event.kind != "phase", event.kind != "log" {
            self.scheduleSwarmRefresh()
        }
        return true
    }

    func refreshSwarmCapability(
        sessionSnapshot: SessionSnapshot? = nil,
        retryAttempt: Int = 0) async
    {
        let session = sessionSnapshot ?? self.currentSessionSnapshot()
        guard self.isCurrentSession(session) else { return }
        // Capability and child rows are one observation. A later refresh or reset
        // must fence both, even when the Gateway route and session key are unchanged.
        self.swarmRefreshGeneration &+= 1
        let generation = self.swarmRefreshGeneration
        let isCurrent = {
            self.swarmRefreshGeneration == generation && self.isCurrentSession(session)
        }
        let routeLease = await self.transport.acquireSwarmRouteLease()
        guard isCurrent() else { return }
        guard let routeLease else {
            self.scheduleSwarmCapabilityRetry(sessionSnapshot: session, retryAttempt: retryAttempt)
            return
        }
        do {
            let enabled = try await routeLease.isEnabled(sessionKey: session.key)
            guard isCurrent() else { return }
            self.swarmEnabled = enabled
            guard enabled else {
                self.resetSwarmProgress()
                return
            }
            if self.swarmSessionKey != session.key {
                self.swarmSessionKey = session.key
                self.swarmActivityState.clear()
                self.swarmSessions = []
                self.updateSwarmProjection()
            }
            let rows = try await routeLease.listChildSessions(parentKey: session.key)
            guard isCurrent() else { return }
            self.swarmSessions = self.swarmActivityState.decorate(rows)
            self.updateSwarmProjection()
        } catch {
            guard isCurrent() else { return }
            chatUILogger.debug("swarm refresh failed \(error.localizedDescription, privacy: .public)")
            self.scheduleSwarmCapabilityRetry(sessionSnapshot: session, retryAttempt: retryAttempt)
        }
    }

    private func scheduleSwarmCapabilityRetry(
        sessionSnapshot: SessionSnapshot,
        retryAttempt: Int)
    {
        guard self.isCurrentSession(sessionSnapshot),
              swarmRefreshRetryDelays.indices.contains(retryAttempt)
        else { return }
        let delay = swarmRefreshRetryDelays[retryAttempt]
        self.swarmRefreshTask?.cancel()
        self.swarmRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.refreshSwarmCapability(
                sessionSnapshot: sessionSnapshot,
                retryAttempt: retryAttempt + 1)
        }
    }

    func scheduleSwarmRefresh() {
        guard self.swarmEnabled else { return }
        let session = self.currentSessionSnapshot()
        self.swarmRefreshTask?.cancel()
        self.swarmRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.refreshSwarmCapability(sessionSnapshot: session)
        }
    }

    func resetSwarmProgress() {
        swarmRefreshTask?.cancel()
        swarmRefreshTask = nil
        swarmRefreshGeneration &+= 1
        swarmSessionKey = sessionKey
        swarmActivityState.clear()
        swarmSessions = []
        self.updateSwarmProjection()
    }
}
