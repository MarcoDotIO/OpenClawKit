import Foundation
import OpenClawProtocol

/// Errors raised by transcript stores.
public enum SessionTranscriptError: Error, LocalizedError, Sendable, Equatable {
    /// The transcript session does not exist.
    case sessionNotFound(String)
    /// The transcript session already exists.
    case sessionExists(String)
    /// A writer's expected leaf no longer matches (another writer appended first).
    case staleLeaf(expected: String?, actual: String?)
    /// The referenced entry does not exist in the session.
    case entryNotFound(String)
    /// The transcript file is corrupt.
    case corrupt(String)

    /// Human-readable message.
    public var errorDescription: String? {
        switch self {
        case .sessionNotFound(let id):
            return "Transcript session not found: \(id)"
        case .sessionExists(let id):
            return "Transcript session already exists: \(id)"
        case .staleLeaf(let expected, let actual):
            return "Transcript leaf changed (expected \(expected ?? "root"), found \(actual ?? "root"))"
        case .entryNotFound(let id):
            return "Transcript entry not found: \(id)"
        case .corrupt(let detail):
            return "Transcript is corrupt: \(detail)"
        }
    }
}

/// Transcript storage for agent sessions: an append-only DAG of ``SessionTranscriptEntry`` values with a
/// movable leaf that selects the active path (upstream session manager semantics).
///
/// ``append(_:sessionID:expectedLeafID:)`` links the entry to the current leaf and makes it the new
/// leaf; ``setLeaf(_:sessionID:)`` moves the leaf to branch or rewind. Path, context-window and branch
/// queries are provided by the protocol extension.
public protocol SessionTranscriptStore: Actor {
    /// Creates a transcript session.
    /// - Parameters:
    ///   - id: Session identifier.
    ///   - cwd: Working directory recorded in the header.
    ///   - parentSession: Parent transcript session.
    /// - Returns: The header.
    func createSession(id: String, cwd: String, parentSession: String?) async throws -> SessionTranscriptHeader

    /// Returns the header of a session, or `nil` when the session does not exist.
    /// - Parameter sessionID: Session identifier.
    func header(sessionID: String) async throws -> SessionTranscriptHeader?

    /// Appends an entry linked to the current leaf and moves the leaf to it.
    /// - Parameters:
    ///   - entry: Entry to append (its `parentID` is overwritten with the current leaf).
    ///   - sessionID: Session identifier.
    ///   - expectedLeafID: When non-`nil`, the append fails with ``SessionTranscriptError/staleLeaf(expected:actual:)``
    ///     unless the current leaf equals the wrapped value (fences stale writers).
    /// - Returns: The entry identifier.
    @discardableResult
    func append(_ entry: SessionTranscriptEntry, sessionID: String, expectedLeafID: String??) async throws -> String

    /// Current leaf entry, or `nil` for an empty transcript.
    /// - Parameter sessionID: Session identifier.
    func leafID(sessionID: String) async throws -> String?

    /// Moves the leaf (`nil` rewinds to before the first entry).
    /// - Parameters:
    ///   - entryID: New leaf entry.
    ///   - sessionID: Session identifier.
    func setLeaf(_ entryID: String?, sessionID: String) async throws

    /// Every entry of the session in append order.
    /// - Parameter sessionID: Session identifier.
    func entries(sessionID: String) async throws -> [SessionTranscriptEntry]

    /// Deletes a session transcript (no-op when missing).
    /// - Parameter sessionID: Session identifier.
    func delete(sessionID: String) async throws

    /// Identifiers of every stored session.
    func sessionIDs() async throws -> [String]
}

public extension SessionTranscriptStore {
    /// Appends an entry without a leaf fence.
    /// - Parameters:
    ///   - entry: Entry to append.
    ///   - sessionID: Session identifier.
    /// - Returns: The entry identifier.
    @discardableResult
    func append(_ entry: SessionTranscriptEntry, sessionID: String) async throws -> String {
        try await self.append(entry, sessionID: sessionID, expectedLeafID: nil)
    }

    /// Appends a message entry.
    /// - Parameters:
    ///   - message: Message.
    ///   - sessionID: Session identifier.
    /// - Returns: The entry identifier.
    @discardableResult
    func appendMessage(_ message: AgentMessage, sessionID: String) async throws -> String {
        try await self.append(.message(message), sessionID: sessionID, expectedLeafID: nil)
    }

    /// Creates the session when it does not exist yet.
    /// - Parameters:
    ///   - id: Session identifier.
    ///   - cwd: Working directory.
    ///   - parentSession: Parent transcript session.
    /// - Returns: The existing or new header.
    @discardableResult
    func ensureSession(id: String, cwd: String = "", parentSession: String? = nil) async throws -> SessionTranscriptHeader {
        if let header = try await self.header(sessionID: id) {
            return header
        }
        return try await self.createSession(id: id, cwd: cwd, parentSession: parentSession)
    }

    /// Entries from the root to the leaf (walk leaf → root, then reverse).
    /// - Parameter sessionID: Session identifier.
    /// - Returns: The active path.
    func activePath(sessionID: String) async throws -> [SessionTranscriptEntry] {
        let entries = try await self.entries(sessionID: sessionID)
        let leaf = try await self.leafID(sessionID: sessionID)
        return SessionTranscriptPaths.path(to: leaf, in: entries)
    }

    /// Model-context messages of the active path (upstream `buildSessionContext`).
    ///
    /// The window starts after the latest `compaction` or `reset` boundary: a compaction contributes a
    /// synthetic `compactionSummary` message followed by the entries from its `firstKeptEntryId`; a
    /// reset keeps the entries from its `firstKeptEntryId` (dropping orphaned tool results). Custom
    /// messages and branch summaries become `custom`/`branchSummary` messages; metadata entries are skipped.
    /// - Parameter sessionID: Session identifier.
    /// - Returns: Messages in order.
    func contextMessages(sessionID: String) async throws -> [AgentMessage] {
        SessionTranscriptPaths.contextMessages(for: try await self.activePath(sessionID: sessionID))
    }

    /// Branch tips of the DAG (entries without children), newest first.
    /// - Parameter sessionID: Session identifier.
    /// - Returns: Branch summaries.
    func branches(sessionID: String) async throws -> [SessionTranscriptBranch] {
        let entries = try await self.entries(sessionID: sessionID)
        let leaf = try await self.leafID(sessionID: sessionID)
        return SessionTranscriptPaths.branches(in: entries, activeLeaf: leaf)
    }
}

/// Pure path and context-window helpers shared by every transcript backend.
public enum SessionTranscriptPaths {
    /// Path from the root to `leaf` (empty when `leaf` is `nil` or unknown).
    /// - Parameters:
    ///   - leaf: Leaf entry id.
    ///   - entries: Every entry.
    /// - Returns: Entries root → leaf.
    public static func path(to leaf: String?, in entries: [SessionTranscriptEntry]) -> [SessionTranscriptEntry] {
        guard let leaf else { return [] }
        var byID: [String: SessionTranscriptEntry] = [:]
        for entry in entries {
            byID[entry.id] = entry
        }
        var path: [SessionTranscriptEntry] = []
        var seen: Set<String> = []
        var current = byID[leaf]
        while let entry = current, seen.insert(entry.id).inserted {
            path.append(entry)
            current = entry.parentID.flatMap { byID[$0] }
        }
        return path.reversed()
    }

    /// Model-context messages for a root → leaf path (see ``SessionTranscriptStore/contextMessages(sessionID:)``).
    /// - Parameter path: Active path.
    /// - Returns: Messages in order.
    public static func contextMessages(for path: [SessionTranscriptEntry]) -> [AgentMessage] {
        let boundaryIndex = path.lastIndex { entry in
            if case .compaction = entry.payload { return true }
            if case .reset = entry.payload { return true }
            return false
        }
        var messages: [AgentMessage] = []
        var retained: ArraySlice<SessionTranscriptEntry> = []
        var current: ArraySlice<SessionTranscriptEntry> = path[...]
        var isReset = false
        if let boundaryIndex {
            let boundary = path[boundaryIndex]
            let firstKeptID: String?
            switch boundary.payload {
            case .compaction(let data):
                firstKeptID = data.firstKeptEntryId
                messages.append(.compactionSummary(data.summary, tokensBefore: data.tokensBefore, timestamp: boundary.timestampMs))
            case .reset(_, let firstKept):
                firstKeptID = firstKept
                isReset = true
            default:
                firstKeptID = nil
            }
            if let firstKeptID, let firstKeptIndex = path.firstIndex(where: { $0.id == firstKeptID }), firstKeptIndex < boundaryIndex {
                retained = path[firstKeptIndex..<boundaryIndex]
            }
            current = path[(boundaryIndex + 1)...]
        }
        var retainedMessages = retained.compactMap(Self.projectMessage)
        if isReset {
            retainedMessages = Self.dropOrphanedToolResults(retainedMessages)
        }
        messages.append(contentsOf: retainedMessages)
        messages.append(contentsOf: current.compactMap(Self.projectMessage))
        return messages
    }

    /// Projects an entry into its context message (upstream `projectSessionEntryMessage`).
    /// - Parameter entry: Transcript entry.
    /// - Returns: The message, or `nil` for metadata entries and excluded messages.
    public static func projectMessage(_ entry: SessionTranscriptEntry) -> AgentMessage? {
        switch entry.payload {
        case .message(let message):
            return message.isExcludedFromContext ? nil : message
        case .customMessage(let customType, let content, let display, let details):
            return .custom(customType: customType, content: content, display: display, details: details, timestamp: entry.timestampMs)
        case .branchSummary(let fromID, let summary, _):
            return summary.isEmpty ? nil : .branchSummary(summary, fromID: fromID, timestamp: entry.timestampMs)
        default:
            return nil
        }
    }

    /// Branch tips (entries without children), newest first.
    /// - Parameters:
    ///   - entries: Every entry.
    ///   - activeLeaf: Current leaf.
    /// - Returns: Branch summaries.
    public static func branches(in entries: [SessionTranscriptEntry], activeLeaf: String?) -> [SessionTranscriptBranch] {
        let parents = Set(entries.compactMap(\.parentID))
        var tips = entries.filter { !parents.contains($0.id) }.map(\.id)
        if let activeLeaf, !tips.contains(activeLeaf), entries.contains(where: { $0.id == activeLeaf }) {
            tips.append(activeLeaf)
        }
        let branches = tips.map { tip -> SessionTranscriptBranch in
            let path = Self.path(to: tip, in: entries)
            let messages = path.compactMap(\.message)
            let headlineSource = messages.last(where: { $0.role == "user" })?.text ?? messages.last?.text ?? ""
            let headline = String(headlineSource.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
            return SessionTranscriptBranch(
                leafEntryId: tip,
                headline: headline,
                messageCount: messages.count,
                updatedAt: path.last?.timestampMs ?? 0,
                active: tip == activeLeaf
            )
        }
        return branches.sorted { lhs, rhs in
            lhs.updatedAt == rhs.updatedAt ? lhs.leafEntryId < rhs.leafEntryId : lhs.updatedAt > rhs.updatedAt
        }
    }

    private static func dropOrphanedToolResults(_ messages: [AgentMessage]) -> [AgentMessage] {
        var callIDs: Set<String> = []
        var result: [AgentMessage] = []
        for message in messages {
            switch message {
            case .assistant(let assistant):
                callIDs.formUnion(assistant.toolCalls.map(\.id))
                result.append(message)
            case .toolResult(let toolResult):
                if callIDs.contains(toolResult.toolCallId) {
                    result.append(message)
                }
            default:
                result.append(message)
            }
        }
        return result
    }
}

// MARK: - In-memory backend

/// In-memory transcript store (tests and ephemeral sessions).
public actor InMemorySessionTranscriptStore: SessionTranscriptStore {
    private struct Session {
        var header: SessionTranscriptHeader
        var entries: [SessionTranscriptEntry]
        var leaf: String?
    }

    private var sessions: [String: Session] = [:]

    /// Creates an empty store.
    public init() {}

    /// Creates a session.
    public func createSession(id: String, cwd: String, parentSession: String?) throws -> SessionTranscriptHeader {
        guard self.sessions[id] == nil else {
            throw SessionTranscriptError.sessionExists(id)
        }
        let header = SessionTranscriptHeader(id: id, cwd: cwd, parentSession: parentSession)
        self.sessions[id] = Session(header: header, entries: [], leaf: nil)
        return header
    }

    /// Returns a session header.
    public func header(sessionID: String) -> SessionTranscriptHeader? {
        self.sessions[sessionID]?.header
    }

    /// Appends an entry linked to the leaf.
    @discardableResult
    public func append(_ entry: SessionTranscriptEntry, sessionID: String, expectedLeafID: String??) throws -> String {
        guard var session = self.sessions[sessionID] else {
            throw SessionTranscriptError.sessionNotFound(sessionID)
        }
        if let expected = expectedLeafID, expected != session.leaf {
            throw SessionTranscriptError.staleLeaf(expected: expected, actual: session.leaf)
        }
        var linked = entry
        linked.parentID = session.leaf
        session.entries.append(linked)
        session.leaf = linked.id
        self.sessions[sessionID] = session
        return linked.id
    }

    /// Returns the leaf.
    public func leafID(sessionID: String) throws -> String? {
        guard let session = self.sessions[sessionID] else {
            throw SessionTranscriptError.sessionNotFound(sessionID)
        }
        return session.leaf
    }

    /// Moves the leaf.
    public func setLeaf(_ entryID: String?, sessionID: String) throws {
        guard var session = self.sessions[sessionID] else {
            throw SessionTranscriptError.sessionNotFound(sessionID)
        }
        if let entryID, !session.entries.contains(where: { $0.id == entryID }) {
            throw SessionTranscriptError.entryNotFound(entryID)
        }
        session.leaf = entryID
        self.sessions[sessionID] = session
    }

    /// Returns every entry.
    public func entries(sessionID: String) throws -> [SessionTranscriptEntry] {
        guard let session = self.sessions[sessionID] else {
            throw SessionTranscriptError.sessionNotFound(sessionID)
        }
        return session.entries
    }

    /// Deletes a session.
    public func delete(sessionID: String) {
        self.sessions[sessionID] = nil
    }

    /// Returns every session id.
    public func sessionIDs() -> [String] {
        self.sessions.keys.sorted()
    }
}

// MARK: - JSONL backend

/// JSONL transcript store: one file per session, `<directory>/<sessionId>.jsonl`.
///
/// Layout (SDK-owned; upstream moved transcripts to SQLite in 2026.8.1): the first line is the
/// ``SessionTranscriptHeader``, then one ``SessionTranscriptEntry`` per line, append-only. A leaf move
/// that is not implied by an append is recorded as a `{"type":"leaf","id":…}` control line
/// (`"id":null` rewinds to the root). Malformed lines are skipped when loading. The conventional
/// directory is `<stateDir>/agents/<agentId>/sessions/` (see ``defaultDirectory(stateDirectory:agentID:)``).
public actor JSONLSessionTranscriptStore: SessionTranscriptStore {
    private struct Session {
        var header: SessionTranscriptHeader
        var entries: [SessionTranscriptEntry]
        var leaf: String?
    }

    private struct LeafLine: Codable {
        var type = "leaf"
        var id: String?

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(self.type, forKey: .type)
            try container.encode(self.id, forKey: .id)
        }
    }

    private let directory: URL
    private var cache: [String: Session] = [:]

    /// Conventional transcript directory `<stateDir>/agents/<agentId>/sessions/`.
    /// - Parameters:
    ///   - stateDirectory: SDK state directory.
    ///   - agentID: Agent identifier.
    /// - Returns: The directory URL.
    public static func defaultDirectory(stateDirectory: URL, agentID: String) -> URL {
        stateDirectory
            .appendingPathComponent("agents", isDirectory: true)
            .appendingPathComponent(SessionKey.normalizeAgentID(agentID), isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    /// Creates a JSONL store rooted at `directory`.
    /// - Parameter directory: Directory holding `<sessionId>.jsonl` files.
    public init(directory: URL) {
        self.directory = directory
    }

    /// Creates a session file.
    public func createSession(id: String, cwd: String, parentSession: String?) throws -> SessionTranscriptHeader {
        let url = try self.fileURL(for: id)
        if self.cache[id] != nil || FileManager.default.fileExists(atPath: url.path) {
            throw SessionTranscriptError.sessionExists(id)
        }
        try OpenClawFileSystem.ensurePrivateDirectory(self.directory)
        let header = SessionTranscriptHeader(id: id, cwd: cwd, parentSession: parentSession)
        try (Self.encodeLine(header) + "\n").write(to: url, atomically: true, encoding: .utf8)
        OpenClawFileSystem.restrictToOwner(url)
        self.cache[id] = Session(header: header, entries: [], leaf: nil)
        return header
    }

    /// Returns a session header.
    public func header(sessionID: String) throws -> SessionTranscriptHeader? {
        try self.loadIfPresent(sessionID)?.header
    }

    /// Appends an entry line.
    @discardableResult
    public func append(_ entry: SessionTranscriptEntry, sessionID: String, expectedLeafID: String??) throws -> String {
        guard var session = try self.loadIfPresent(sessionID) else {
            throw SessionTranscriptError.sessionNotFound(sessionID)
        }
        if let expected = expectedLeafID, expected != session.leaf {
            throw SessionTranscriptError.staleLeaf(expected: expected, actual: session.leaf)
        }
        var linked = entry
        linked.parentID = session.leaf
        try self.appendLine(Self.encodeLine(linked), sessionID: sessionID)
        session.entries.append(linked)
        session.leaf = linked.id
        self.cache[sessionID] = session
        return linked.id
    }

    /// Returns the leaf.
    public func leafID(sessionID: String) throws -> String? {
        guard let session = try self.loadIfPresent(sessionID) else {
            throw SessionTranscriptError.sessionNotFound(sessionID)
        }
        return session.leaf
    }

    /// Moves the leaf and records a control line.
    public func setLeaf(_ entryID: String?, sessionID: String) throws {
        guard var session = try self.loadIfPresent(sessionID) else {
            throw SessionTranscriptError.sessionNotFound(sessionID)
        }
        if let entryID, !session.entries.contains(where: { $0.id == entryID }) {
            throw SessionTranscriptError.entryNotFound(entryID)
        }
        guard session.leaf != entryID else { return }
        try self.appendLine(Self.encodeLine(LeafLine(id: entryID)), sessionID: sessionID)
        session.leaf = entryID
        self.cache[sessionID] = session
    }

    /// Returns every entry.
    public func entries(sessionID: String) throws -> [SessionTranscriptEntry] {
        guard let session = try self.loadIfPresent(sessionID) else {
            throw SessionTranscriptError.sessionNotFound(sessionID)
        }
        return session.entries
    }

    /// Deletes a session file.
    public func delete(sessionID: String) throws {
        self.cache[sessionID] = nil
        let url = try self.fileURL(for: sessionID)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Returns every session id with a transcript file.
    public func sessionIDs() throws -> [String] {
        guard FileManager.default.fileExists(atPath: self.directory.path) else {
            return self.cache.keys.sorted()
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: self.directory.path)
        let ids = files.filter { $0.hasSuffix(".jsonl") }.map { String($0.dropLast(6)) }
        return Array(Set(ids).union(self.cache.keys)).sorted()
    }

    /// Drops cached sessions so the next access re-reads the files.
    public func invalidateCache() {
        self.cache.removeAll()
    }

    private func loadIfPresent(_ sessionID: String) throws -> Session? {
        if let cached = self.cache[sessionID] {
            return cached
        }
        let url = try self.fileURL(for: sessionID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        var header: SessionTranscriptHeader?
        var entries: [SessionTranscriptEntry] = []
        var leaf: String?
        let decoder = JSONDecoder()
        for line in text.split(whereSeparator: \.isNewline) where !line.allSatisfy(\.isWhitespace) {
            let data = Data(line.utf8)
            guard let object = try? decoder.decode([String: AnyCodable].self, from: data),
                  let type = object["type"]?.stringValue
            else {
                continue
            }
            switch type {
            case "session":
                header = header ?? (try? decoder.decode(SessionTranscriptHeader.self, from: data))
            case "leaf":
                leaf = object["id"]?.stringValue
            default:
                if let entry = try? decoder.decode(SessionTranscriptEntry.self, from: data) {
                    entries.append(entry)
                    leaf = entry.id
                }
            }
        }
        guard let header else {
            throw SessionTranscriptError.corrupt("missing session header in \(url.lastPathComponent)")
        }
        let session = Session(header: header, entries: entries, leaf: leaf)
        self.cache[sessionID] = session
        return session
    }

    private func appendLine(_ line: String, sessionID: String) throws {
        let url = try self.fileURL(for: sessionID)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
    }

    private func fileURL(for sessionID: String) throws -> URL {
        let trimmed = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("/"),
              !trimmed.contains("\\"),
              trimmed != ".",
              trimmed != ".."
        else {
            throw SessionTranscriptError.corrupt("invalid session id: \(sessionID)")
        }
        return self.directory.appendingPathComponent("\(trimmed).jsonl", isDirectory: false)
    }

    private static func encodeLine(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

// MARK: - Importer

/// One legacy conversation row to import into a transcript (for example a `ConversationMemoryEntry`).
public struct SessionTranscriptImportRow: Sendable, Equatable {
    /// Row role: `user` or `assistant`.
    public var role: String
    /// Message text.
    public var text: String
    /// Timestamp (ms).
    public var timestampMs: Int64

    /// Creates an import row.
    /// - Parameters:
    ///   - role: `user` or `assistant`.
    ///   - text: Message text.
    ///   - timestampMs: Timestamp (ms).
    public init(role: String, text: String, timestampMs: Int64) {
        self.role = role
        self.text = text
        self.timestampMs = timestampMs
    }
}

/// Imports legacy conversation rows as transcript `message` entries so existing apps keep their history.
public enum SessionTranscriptImporter {
    /// Appends rows (sorted by timestamp) to a transcript session, creating the session when needed.
    ///
    /// Assistant rows become assistant messages with provider `import`; unknown roles are skipped.
    /// - Parameters:
    ///   - rows: Rows to import.
    ///   - store: Target store.
    ///   - sessionID: Target session.
    ///   - cwd: Working directory recorded when the session is created.
    /// - Returns: Number of imported messages.
    @discardableResult
    public static func importRows(
        _ rows: [SessionTranscriptImportRow],
        into store: any SessionTranscriptStore,
        sessionID: String,
        cwd: String = ""
    ) async throws -> Int {
        try await store.ensureSession(id: sessionID, cwd: cwd)
        var imported = 0
        for row in rows.sorted(by: { $0.timestampMs < $1.timestampMs }) {
            let message: AgentMessage
            switch row.role.lowercased() {
            case "user":
                message = .userText(row.text, timestamp: row.timestampMs)
            case "assistant":
                message = .assistant(
                    AgentAssistantMessage(content: [.text(row.text)], provider: "import", model: "import", timestamp: row.timestampMs)
                )
            default:
                continue
            }
            let entry = SessionTranscriptEntry(timestamp: SessionTranscriptClock.iso(fromMilliseconds: row.timestampMs), payload: .message(message))
            try await store.append(entry, sessionID: sessionID)
            imported += 1
        }
        return imported
    }
}
