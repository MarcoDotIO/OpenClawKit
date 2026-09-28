import Foundation
import OpenClawCore
import OpenClawGateway
import OpenClawProtocol

public extension EmbeddedAgentRuntime {
    /// Methods registered by ``registerSessionBranchGatewayMethods(on:)``.
    static let sessionBranchGatewayMethodNames: [String] = [
        "sessions.rewind", "sessions.fork", "sessions.branches.list", "sessions.branches.switch", "sessions.search",
    ]

    /// Registers the transcript DAG and search methods (upstream `sessions-rewind.ts`,
    /// `sessions-search.ts`; they replace the removed `sessions.compaction.branch/restore`):
    ///
    /// - `sessions.rewind {sessionKey, agentId?, entryId}` → `{editorText?, editorAttachments?}`: the
    ///   entry must be a user message on the active path; the leaf moves to its parent and the message
    ///   comes back for the composer (images as `{mimeType, data}`). Chat context only, files are untouched.
    /// - `sessions.fork {sessionKey, agentId?, entryId}` → `{sessionKey, editorText?, editorAttachments?}`:
    ///   a new session (`agent:<agentId>:fork:<uuid>`, same agent and settings) whose transcript copies
    ///   the active path up to the entry's parent.
    /// - `sessions.branches.list {sessionKey, agentId?}` → `{branches: [{leafEntryId, headline,
    ///   messageCount, updatedAt, active}]}`.
    /// - `sessions.branches.switch {sessionKey, agentId?, leafEntryId}` → `{}`.
    /// - `sessions.search {query, agentId?, sessionKeys?, limit?}` → `{results: [{sessionKey, sessionId,
    ///   messageId, role, timestamp, snippet, score}], sessions, truncated?}`: case-insensitive; a
    ///   quoted query matches the exact phrase, otherwise every word must occur in the message.
    ///
    /// Rewind, fork and switch refuse while the session has an active run (`UNAVAILABLE`) and emit
    /// `sessions.changed` (`rewind`, `fork`, `branch-switch`). Every call carries the selected
    /// `agentId`; a session owned by another agent answers `INVALID_REQUEST`.
    /// - Parameter registrar: Gateway server or registrar.
    func registerSessionBranchGatewayMethods(on registrar: some GatewayMethodRegistrar) async {
        let handlers = SessionBranchGatewayHandlers(runtime: self)
        await registrar.register(method: "sessions.rewind") { try await handlers.rewind($0, fork: false) }
        await registrar.register(method: "sessions.fork") { try await handlers.rewind($0, fork: true) }
        await registrar.register(method: "sessions.branches.list") { try await handlers.branchesList($0) }
        await registrar.register(method: "sessions.branches.switch") { try await handlers.branchesSwitch($0) }
        await registrar.register(method: "sessions.search") { try await handlers.search($0) }
    }
}

struct SessionBranchGatewayHandlers: Sendable {
    let runtime: EmbeddedAgentRuntime

    private struct Target {
        let sessionKey: String
        let sessionID: String
        let record: SessionRecord?
        let store: any SessionTranscriptStore
    }

    private func target(_ request: GatewayMethodRequest, action: String) async throws -> Target {
        guard let sessionKey = request.stringParam("sessionKey", "key") else {
            throw GatewayMethodError.invalidRequest("\(request.method) requires sessionKey")
        }
        guard let store = self.runtime.transcriptStore else {
            throw GatewayMethodError.invalidRequest("session transcript storage does not support \(action)")
        }
        let record = await self.runtime.sessionStore?.recordForKey(sessionKey)
        if let agentID = request.stringParam("agentId"), let record,
           SessionKey.normalizeAgentID(agentID) != SessionKey.normalizeAgentID(record.agentID)
        {
            throw GatewayMethodError.invalidRequest("session \(sessionKey) belongs to agent \(record.agentID)")
        }
        let sessionID = await self.runtime.transcriptSessionID(for: sessionKey)
        guard (try? await store.header(sessionID: sessionID)) != nil else {
            throw GatewayMethodError.invalidRequest("session not found: \(sessionKey)")
        }
        return Target(sessionKey: sessionKey, sessionID: sessionID, record: record, store: store)
    }

    private func requireIdle(_ target: Target, action: String) async throws {
        guard await self.runtime.activeRunIDs(sessionKey: target.sessionKey).isEmpty else {
            throw GatewayMethodError.unavailable("Session \(target.sessionKey) is busy; retry \(action) after the active run ends.", retryable: true)
        }
    }

    private static func emitChanged(_ request: GatewayMethodRequest, key: String, record: SessionRecord?, reason: String, agentID: String?) async {
        var extra: [String: AnyCodable] = [:]
        if let agentID { extra["agentId"] = AnyCodable(agentID) }
        await request.events.emit(
            .sessionsChanged,
            payload: GatewayServer.sessionsChangedPayload(sessionKey: key, record: record, reason: reason, extra: extra)
        )
    }

    // MARK: - Rewind / fork

    func rewind(_ request: GatewayMethodRequest, fork: Bool) async throws -> AnyCodable? {
        let action = fork ? "fork" : "rewind"
        let target = try await self.target(request, action: action)
        guard let entryID = request.stringParam("entryId") else {
            throw GatewayMethodError.invalidRequest("\(request.method) requires entryId")
        }
        try await self.requireIdle(target, action: action)
        let path = try await target.store.activePath(sessionID: target.sessionID)
        guard let index = path.firstIndex(where: { $0.id == entryID }) else {
            let known = try await target.store.entries(sessionID: target.sessionID).contains { $0.id == entryID }
            throw GatewayMethodError.invalidRequest(known ? "message entry is not on the active path: \(entryID)" : "message entry not found: \(entryID)")
        }
        guard case .message(.user(let user)) = path[index].payload else {
            throw GatewayMethodError.invalidRequest("entry is not a user message: \(entryID)")
        }
        var payload = Self.editorPayload(user)
        let agentID = target.record?.agentID ?? SessionKey.agentID(from: target.sessionKey, fallback: self.runtime.defaultAgentID)
        if fork {
            let forkKey = "agent:\(SessionKey.normalizeAgentID(agentID)):fork:\(UUID().uuidString.lowercased())"
            let record = try await self.createFork(from: target, key: forkKey, agentID: agentID, prefix: Array(path[..<index]))
            payload["sessionKey"] = AnyCodable(forkKey)
            await Self.emitChanged(request, key: forkKey, record: record, reason: "fork", agentID: agentID)
        } else {
            try await target.store.setLeaf(path[index].parentID, sessionID: target.sessionID)
            let record = await self.runtime.sessionStore?.update(forKey: target.sessionKey) { _ in }
            try? await self.runtime.sessionStore?.save()
            await Self.emitChanged(request, key: target.sessionKey, record: record ?? target.record, reason: "rewind", agentID: agentID)
        }
        return AnyCodable(payload)
    }

    private func createFork(from target: Target, key: String, agentID: String, prefix: [SessionTranscriptEntry]) async throws -> SessionRecord? {
        var record: SessionRecord?
        var sessionID = SessionTranscriptIdentity.sessionID(forKey: key)
        if let sessionStore = self.runtime.sessionStore {
            let created = await sessionStore.resolveOrCreate(sessionKey: key, defaultAgentID: agentID, route: nil)
            let parent = target.record
            record = await sessionStore.update(forKey: key) { forked in
                forked.parentSessionID = target.sessionID
                guard let parent else { return }
                forked.label = parent.label.map { "\($0) (fork)" }
                forked.modelOverride = parent.modelOverride
                forked.thinkingLevel = parent.thinkingLevel
                forked.fastModeSetting = parent.fastModeSetting
                forked.verboseLevel = parent.verboseLevel
                forked.reasoningLevel = parent.reasoningLevel
                forked.traceLevel = parent.traceLevel
                forked.permissionMode = parent.permissionMode
                forked.toolOverrides = parent.toolOverrides
                forked.category = parent.category
                forked.contextWindow = parent.contextWindow
                forked.agentRuntime = parent.agentRuntime
            } ?? created
            try? await sessionStore.save()
            sessionID = record?.sessionID ?? created.sessionID ?? sessionID
        }
        let header = try await target.store.header(sessionID: target.sessionID)
        try await target.store.ensureSession(id: sessionID, cwd: header?.cwd ?? "", parentSession: target.sessionID)
        for entry in prefix {
            _ = try await target.store.append(entry, sessionID: sessionID)
        }
        return record
    }

    private static func editorPayload(_ user: AgentUserMessage) -> [String: AnyCodable] {
        var payload: [String: AnyCodable] = [:]
        let text = user.content.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            payload["editorText"] = AnyCodable(user.content.text)
        }
        let images: [AnyCodable] = user.content.blocks.compactMap { block in
            guard case .image(let data, let mimeType) = block else { return nil }
            return AnyCodable(["mimeType": AnyCodable(mimeType), "data": AnyCodable(data)])
        }
        if !images.isEmpty {
            payload["editorAttachments"] = AnyCodable(images)
        }
        return payload
    }

    // MARK: - Branches

    func branchesList(_ request: GatewayMethodRequest) async throws -> AnyCodable? {
        let target: Target
        do {
            target = try await self.target(request, action: "branch listing")
        } catch let error as GatewayMethodError where error.message.hasPrefix("session not found") {
            return AnyCodable(["branches": AnyCodable([AnyCodable]())])
        }
        let branches = try await target.store.branches(sessionID: target.sessionID)
        return AnyCodable(["branches": AnyCodable(branches.map(Self.branchPayload))])
    }

    func branchesSwitch(_ request: GatewayMethodRequest) async throws -> AnyCodable? {
        let target = try await self.target(request, action: "branch switch")
        guard let leafID = request.stringParam("leafEntryId") else {
            throw GatewayMethodError.invalidRequest("sessions.branches.switch requires leafEntryId")
        }
        try await self.requireIdle(target, action: "switch")
        let branches = try await target.store.branches(sessionID: target.sessionID)
        guard let branch = branches.first(where: { $0.leafEntryId == leafID }) else {
            let known = try await target.store.entries(sessionID: target.sessionID).contains { $0.id == leafID }
            throw GatewayMethodError.invalidRequest(known ? "entry is not a branch tip: \(leafID)" : "branch entry not found: \(leafID)")
        }
        guard !branch.active else {
            throw GatewayMethodError.invalidRequest("branch is already active: \(leafID)")
        }
        try await target.store.setLeaf(leafID, sessionID: target.sessionID)
        let record = await self.runtime.sessionStore?.update(forKey: target.sessionKey) { _ in }
        try? await self.runtime.sessionStore?.save()
        await Self.emitChanged(request, key: target.sessionKey, record: record ?? target.record, reason: "branch-switch", agentID: target.record?.agentID)
        return AnyCodable([String: AnyCodable]())
    }

    static func branchPayload(_ branch: SessionTranscriptBranch) -> AnyCodable {
        var payload: [String: AnyCodable] = [
            "leafEntryId": AnyCodable(branch.leafEntryId),
            "headline": AnyCodable(branch.headline),
            "messageCount": AnyCodable(branch.messageCount),
            "active": AnyCodable(branch.active),
        ]
        if branch.updatedAt > 0 {
            payload["updatedAt"] = AnyCodable(Self.isoTimestamp(branch.updatedAt))
        }
        return AnyCodable(payload)
    }

    static func isoTimestamp(_ ms: Int64) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    // MARK: - Search

    func search(_ request: GatewayMethodRequest) async throws -> AnyCodable? {
        guard let rawQuery = request.stringParam("query") else {
            throw GatewayMethodError.invalidRequest("sessions.search requires query")
        }
        guard let store = self.runtime.transcriptStore else {
            return AnyCodable(["results": AnyCodable([AnyCodable]()), "sessions": AnyCodable([AnyCodable]())])
        }
        let matcher = SessionSearchMatcher(query: rawQuery)
        let limit = min(100, max(1, request.params["limit"]?.intValue ?? 20))
        let requestedKeys = request.params["sessionKeys"]?.arrayValue?.compactMap(\.stringValue)
        let agentFilter = request.stringParam("agentId").map { SessionKey.normalizeAgentID($0) }
        var records = await self.runtime.sessionStore?.allRecords() ?? []
        if let requestedKeys {
            let wanted = Set(requestedKeys)
            records = records.filter { wanted.contains($0.key) }
        }
        if let agentFilter {
            records = records.filter { SessionKey.normalizeAgentID($0.agentID) == agentFilter }
        }
        let archivedExcluded = request.params["scope"]?.dictionaryValue?["includeArchived"]?.boolValue == true ? 0 : records.filter(\.archived).count
        if archivedExcluded > 0 {
            records = records.filter { !$0.archived }
        }
        var hits: [(score: Double, timestamp: Int64, payload: AnyCodable)] = []
        var matchedKeys: Set<String> = []
        for record in records {
            let sessionID = await self.runtime.transcriptSessionID(for: record.key)
            guard let path = try? await store.activePath(sessionID: sessionID) else { continue }
            for entry in path {
                guard case .message(let message) = entry.payload else { continue }
                if case .other("custom", let raw) = message, raw["display"]?.boolValue == false { continue }
                let text = message.text
                guard let match = matcher.match(text) else { continue }
                matchedKeys.insert(record.key)
                hits.append((
                    match.score,
                    message.timestamp,
                    AnyCodable([
                        "sessionKey": AnyCodable(record.key),
                        "sessionId": AnyCodable(sessionID),
                        "messageId": AnyCodable(entry.id),
                        "role": AnyCodable(message.role),
                        "timestamp": AnyCodable(message.timestamp),
                        "snippet": AnyCodable(match.snippet),
                        "score": AnyCodable(match.score),
                    ] as [String: AnyCodable])
                ))
            }
        }
        hits.sort { $0.score == $1.score ? $0.timestamp > $1.timestamp : $0.score > $1.score }
        let truncated = hits.count > limit
        let rows = records.filter { matchedKeys.contains($0.key) }.compactMap { try? GatewayPayloadCodec.encode(GatewayServer.sessionInfo(from: $0)) }
        var payload: [String: AnyCodable] = [
            "results": AnyCodable(hits.prefix(limit).map(\.payload)),
            "sessions": AnyCodable(rows),
        ]
        if truncated { payload["truncated"] = AnyCodable(true) }
        if archivedExcluded > 0 { payload["archivedTranscriptsExcluded"] = AnyCodable(archivedExcluded) }
        return AnyCodable(payload)
    }
}

/// Case-insensitive transcript matcher for `sessions.search`: a quoted query matches the phrase,
/// otherwise every word must occur; the score counts occurrences.
struct SessionSearchMatcher: Sendable {
    let terms: [String]
    let phrase: Bool

    init(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") {
            self.terms = [String(trimmed.dropFirst().dropLast()).lowercased()]
            self.phrase = true
        } else {
            self.terms = trimmed.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
            self.phrase = false
        }
    }

    func match(_ text: String) -> (score: Double, snippet: String)? {
        let lowered = text.lowercased()
        guard !self.terms.isEmpty, self.terms.allSatisfy({ !$0.isEmpty && lowered.contains($0) }) else { return nil }
        var occurrences = 0
        for term in self.terms {
            occurrences += lowered.components(separatedBy: term).count - 1
        }
        let first = self.terms.compactMap { lowered.range(of: $0) }.min { $0.lowerBound < $1.lowerBound }
        let snippet: String
        if let first {
            let startOffset = max(0, lowered.distance(from: lowered.startIndex, to: first.lowerBound) - 60)
            let start = text.index(text.startIndex, offsetBy: min(startOffset, text.count))
            let end = text.index(start, offsetBy: min(160, text.distance(from: start, to: text.endIndex)))
            snippet = (startOffset > 0 ? "…" : "") + text[start..<end] + (end < text.endIndex ? "…" : "")
        } else {
            snippet = String(text.prefix(160))
        }
        return (Double(occurrences) + (self.phrase ? 1 : 0), snippet)
    }
}
