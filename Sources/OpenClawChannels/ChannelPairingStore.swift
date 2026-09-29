import Foundation
import OpenClawCore

/// One pending DM pairing request (upstream `PairingRequestRecord`).
public struct ChannelPairingRequest: Codable, Sendable, Equatable {
    /// Sender id that requested access.
    public var id: String
    /// Human-facing pairing code (8 characters).
    public var code: String
    /// Creation time as an ISO-8601 string with milliseconds (upstream format).
    public var createdAt: String
    /// Last time the sender asked again, ISO-8601.
    public var lastSeenAt: String
    /// Request metadata; `accountId` holds the channel account key.
    public var meta: [String: String]

    /// Creates a pairing request.
    /// - Parameters:
    ///   - id: Sender id.
    ///   - code: Pairing code.
    ///   - createdAt: ISO-8601 creation time.
    ///   - lastSeenAt: ISO-8601 last-seen time.
    ///   - meta: Metadata.
    public init(id: String, code: String, createdAt: String, lastSeenAt: String, meta: [String: String] = [:]) {
        self.id = id
        self.code = code
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
        self.meta = meta
    }

    /// Channel account key the request belongs to (`"default"` when unset).
    public var accountID: String {
        ChannelPairingStore.normalizeAccountID(self.meta["accountId"])
    }

    /// Creation time.
    public var createdDate: Date? {
        ChannelPairingStore.parseTimestamp(self.createdAt)
    }

    /// Last-seen time.
    public var lastSeenDate: Date? {
        ChannelPairingStore.parseTimestamp(self.lastSeenAt) ?? self.createdDate
    }

    /// Expiry time (creation plus the pending TTL).
    public var expiresAt: Date? {
        self.createdDate?.addingTimeInterval(TimeInterval(ChannelPairingStore.pendingTTLMs) / 1_000)
    }

    /// Stable opaque request id (upstream `resolveChannelPairingRequestId`): the first 32
    /// base64url characters of `sha256("<channel>\0<account>\0<id>\0<createdAt>")`.
    /// - Parameter channel: Channel id.
    /// - Returns: Request id.
    public func requestID(channel: ChannelID) -> String {
        let material = "\(channel.rawValue)\u{0}\(self.accountID)\u{0}\(self.id)\u{0}\(self.createdAt)"
        let hex = OpenClawCrypto.sha256Hex(Data(material.utf8))
        var bytes = [UInt8]()
        bytes.reserveCapacity(32)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        let base64 = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return String(base64.prefix(32))
    }
}

/// Persisted pairing state for one channel.
public struct ChannelPairingChannelState: Codable, Sendable, Equatable {
    /// Pending requests.
    public var requests: [ChannelPairingRequest]
    /// Approved sender ids keyed by channel account key.
    public var allowFrom: [String: [String]]

    /// Creates channel pairing state.
    /// - Parameters:
    ///   - requests: Pending requests.
    ///   - allowFrom: Approved senders by account.
    public init(requests: [ChannelPairingRequest] = [], allowFrom: [String: [String]] = [:]) {
        self.requests = requests
        self.allowFrom = allowFrom
    }
}

/// Persisted pairing state for every channel (`channel-pairing.json`).
public struct ChannelPairingSnapshot: Codable, Sendable, Equatable {
    /// Schema version.
    public var version: Int
    /// State keyed by channel id.
    public var channels: [String: ChannelPairingChannelState]

    /// Creates a snapshot.
    /// - Parameters:
    ///   - version: Schema version.
    ///   - channels: State keyed by channel id.
    public init(version: Int = 1, channels: [String: ChannelPairingChannelState] = [:]) {
        self.version = version
        self.channels = channels
    }
}

/// Storage backend for ``ChannelPairingStore``.
public protocol ChannelPairingPersistence: Sendable {
    /// Loads the persisted snapshot (`nil` when nothing was saved yet).
    func load() async throws -> ChannelPairingSnapshot?
    /// Saves a snapshot.
    /// - Parameter snapshot: Snapshot to persist.
    func save(_ snapshot: ChannelPairingSnapshot) async throws
}

/// In-memory pairing persistence (tests and ephemeral hosts).
public actor InMemoryChannelPairingPersistence: ChannelPairingPersistence {
    private var snapshot: ChannelPairingSnapshot?

    /// Creates empty in-memory persistence.
    /// - Parameter snapshot: Initial snapshot.
    public init(snapshot: ChannelPairingSnapshot? = nil) {
        self.snapshot = snapshot
    }

    /// Returns the stored snapshot.
    public func load() async throws -> ChannelPairingSnapshot? {
        self.snapshot
    }

    /// Stores a snapshot.
    /// - Parameter snapshot: Snapshot to store.
    public func save(_ snapshot: ChannelPairingSnapshot) async throws {
        self.snapshot = snapshot
    }
}

/// JSON-file pairing persistence (`<stateDir>/channel-pairing.json`).
public struct FileChannelPairingPersistence: ChannelPairingPersistence {
    /// Backing file.
    public let fileURL: URL

    /// Creates file persistence.
    /// - Parameter fileURL: Backing JSON file.
    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Creates file persistence under a state directory.
    /// - Parameter stateDirectory: State directory; the file is `channel-pairing.json`.
    public init(stateDirectory: URL) {
        self.fileURL = stateDirectory.appendingPathComponent("channel-pairing.json", isDirectory: false)
    }

    /// Loads the snapshot, returning `nil` when the file does not exist.
    public func load() async throws -> ChannelPairingSnapshot? {
        guard FileManager.default.fileExists(atPath: self.fileURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: self.fileURL)
        return try JSONDecoder().decode(ChannelPairingSnapshot.self, from: data)
    }

    /// Atomically writes the snapshot.
    /// - Parameter snapshot: Snapshot to write.
    public func save(_ snapshot: ChannelPairingSnapshot) async throws {
        try FileManager.default.createDirectory(
            at: self.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot).write(to: self.fileURL, options: [.atomic])
    }
}

/// Pending pairing request plus its channel, as listed by ``ChannelPairingStore/list(channel:accountID:)``.
public struct ChannelPairingListing: Sendable, Equatable {
    /// Channel id.
    public var channel: ChannelID
    /// Pending request.
    public var request: ChannelPairingRequest

    /// Opaque request id.
    public var requestID: String {
        self.request.requestID(channel: self.channel)
    }
}

/// DM pairing store (upstream `pairing-store.ts`): pending pairing codes and approved senders.
///
/// Codes are 8 characters from `ABCDEFGHJKLMNPQRSTUVWXYZ23456789`, pending requests expire after
/// one hour, and at most 3 requests are pending per channel account; when the cap is reached no
/// new request is created until one expires or is resolved.
public actor ChannelPairingStore {
    /// Pairing code length.
    public static let codeLength = 8
    /// Pairing code alphabet (no ambiguous `0`, `O`, `1`, `I`).
    public static let codeAlphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
    /// Pending request TTL in milliseconds (1 hour).
    public static let pendingTTLMs: Int64 = 3_600_000
    /// Maximum pending requests per channel account.
    public static let maxPendingPerAccount = 3

    private let persistence: any ChannelPairingPersistence
    private let now: @Sendable () -> Date
    private var snapshot: ChannelPairingSnapshot?
    /// Single in-flight first load shared by concurrent callers.
    private var loadTask: Task<ChannelPairingSnapshot, Error>?
    /// Last queued save; each save waits for the previous one so the newest snapshot lands last.
    private var saveTail: Task<Void, Error>?

    /// Creates a pairing store.
    /// - Parameters:
    ///   - persistence: Storage backend (defaults to in-memory).
    ///   - now: Clock (injectable for tests).
    public init(
        persistence: any ChannelPairingPersistence = InMemoryChannelPairingPersistence(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.persistence = persistence
        self.now = now
    }

    /// Creates a file-backed pairing store at `<stateDirectory>/channel-pairing.json`.
    /// - Parameter stateDirectory: State directory.
    public init(stateDirectory: URL) {
        self.init(persistence: FileChannelPairingPersistence(stateDirectory: stateDirectory))
    }

    /// Creates or refreshes a pending request for a sender.
    ///
    /// Returns the existing code (`created: false`) when the sender already has a pending request,
    /// and an empty code (`created: false`) when the account already has 3 pending requests.
    /// - Parameters:
    ///   - channel: Channel id.
    ///   - accountID: Channel account key (`nil` = default).
    ///   - senderID: Sender id.
    ///   - meta: Request metadata (empty values are dropped).
    /// - Returns: Pairing code and whether a new request was created.
    public func upsert(
        channel: ChannelID,
        accountID: String?,
        senderID: String,
        meta: [String: String] = [:]
    ) async throws -> (code: String, created: Bool) {
        var state = try await self.state(for: channel)
        let nowDate = self.now()
        let nowString = Self.formatTimestamp(nowDate)
        let id = senderID.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = Self.normalizeAccountID(accountID)
        var requestMeta = meta.compactMapValues { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        requestMeta["accountId"] = account

        let pruned = Self.pruneExpired(state.requests, now: nowDate)
        var requests = pruned.requests
        let existingCodes = Set(requests.map { $0.code.uppercased() })
        if let index = requests.firstIndex(where: { $0.id == id && $0.accountID == account }) {
            let existing = requests[index]
            let code = existing.code.isEmpty ? Self.generateUniqueCode(existing: existingCodes) : existing.code
            requests[index] = ChannelPairingRequest(
                id: id,
                code: code,
                createdAt: existing.createdAt,
                lastSeenAt: nowString,
                meta: requestMeta
            )
            state.requests = Self.pruneExcess(requests).requests
            try await self.store(state, for: channel)
            return (code, false)
        }

        let capped = Self.pruneExcess(requests)
        requests = capped.requests
        let pendingForAccount = requests.filter { $0.accountID == account }.count
        if pendingForAccount >= Self.maxPendingPerAccount {
            if pruned.removed || capped.removed {
                state.requests = requests
                try await self.store(state, for: channel)
            }
            return ("", false)
        }
        let code = Self.generateUniqueCode(existing: existingCodes)
        requests.append(ChannelPairingRequest(id: id, code: code, createdAt: nowString, lastSeenAt: nowString, meta: requestMeta))
        state.requests = requests
        try await self.store(state, for: channel)
        return (code, true)
    }

    /// Lists pending (unexpired) requests, oldest first.
    /// - Parameters:
    ///   - channel: Channel filter (`nil` = every channel).
    ///   - accountID: Account filter (`nil` = every account).
    /// - Returns: Pending requests.
    public func list(channel: ChannelID? = nil, accountID: String? = nil) async throws -> [ChannelPairingListing] {
        let channels = channel.map { [$0] } ?? ChannelID.allCases
        var result: [ChannelPairingListing] = []
        let nowDate = self.now()
        for id in channels {
            var state = try await self.state(for: id)
            let pruned = Self.pruneExpired(state.requests, now: nowDate)
            let capped = Self.pruneExcess(pruned.requests)
            if pruned.removed || capped.removed {
                state.requests = capped.requests
                try await self.store(state, for: id)
            }
            let account = accountID.map { Self.normalizeAccountID($0) }
            let matching = capped.requests
                .filter { account == nil || $0.accountID == account }
                .sorted { lhs, rhs in
                    if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                    if lhs.accountID != rhs.accountID { return lhs.accountID < rhs.accountID }
                    return lhs.id < rhs.id
                }
            result.append(contentsOf: matching.map { ChannelPairingListing(channel: id, request: $0) })
        }
        return result
    }

    /// Approves a pending request by pairing code and adds the sender to the approved list.
    /// - Parameters:
    ///   - channel: Channel id.
    ///   - accountID: Account filter (`nil` = any account).
    ///   - code: Pairing code (case-insensitive).
    /// - Returns: The approved request, or `nil` when no pending request matches.
    public func approve(channel: ChannelID, accountID: String? = nil, code: String) async throws -> ChannelPairingRequest? {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !normalized.isEmpty else { return nil }
        return try await self.resolve(channel: channel, accountID: accountID, approve: true) {
            $0.code.uppercased() == normalized
        }
    }

    /// Approves a pending request by opaque request id.
    /// - Parameters:
    ///   - channel: Channel id.
    ///   - accountID: Account filter (`nil` = any account).
    ///   - requestID: Opaque request id from ``ChannelPairingRequest/requestID(channel:)``.
    /// - Returns: The approved request, or `nil`.
    public func approve(channel: ChannelID, accountID: String? = nil, requestID: String) async throws -> ChannelPairingRequest? {
        let normalized = requestID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return try await self.resolve(channel: channel, accountID: accountID, approve: true) {
            $0.requestID(channel: channel) == normalized
        }
    }

    /// Dismisses a pending request without approving the sender (they may request again).
    /// - Parameters:
    ///   - channel: Channel id.
    ///   - accountID: Account filter (`nil` = any account).
    ///   - requestID: Opaque request id.
    /// - Returns: The dismissed request, or `nil`.
    public func dismiss(channel: ChannelID, accountID: String? = nil, requestID: String) async throws -> ChannelPairingRequest? {
        let normalized = requestID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return try await self.resolve(channel: channel, accountID: accountID, approve: false) {
            $0.requestID(channel: channel) == normalized
        }
    }

    /// Dismisses a pending request by pairing code.
    /// - Parameters:
    ///   - channel: Channel id.
    ///   - accountID: Account filter.
    ///   - code: Pairing code.
    /// - Returns: The dismissed request, or `nil`.
    public func dismiss(channel: ChannelID, accountID: String? = nil, code: String) async throws -> ChannelPairingRequest? {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !normalized.isEmpty else { return nil }
        return try await self.resolve(channel: channel, accountID: accountID, approve: false) {
            $0.code.uppercased() == normalized
        }
    }

    /// Approved sender ids for a channel account.
    /// - Parameters:
    ///   - channel: Channel id.
    ///   - accountID: Account key (`nil` = default).
    /// - Returns: Approved sender ids in approval order.
    public func approvedSenders(channel: ChannelID, accountID: String?) async throws -> [String] {
        try await self.state(for: channel).allowFrom[Self.normalizeAccountID(accountID)] ?? []
    }

    /// Adds a sender to the approved list directly.
    /// - Parameters:
    ///   - channel: Channel id.
    ///   - accountID: Account key.
    ///   - senderID: Sender id.
    /// - Returns: `true` when the list changed.
    @discardableResult
    public func addApprovedSender(channel: ChannelID, accountID: String?, senderID: String) async throws -> Bool {
        let entry = senderID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entry.isEmpty, entry != "*" else { return false }
        var state = try await self.state(for: channel)
        let account = Self.normalizeAccountID(accountID)
        var current = state.allowFrom[account] ?? []
        guard !current.contains(entry) else { return false }
        current.append(entry)
        state.allowFrom[account] = current
        try await self.store(state, for: channel)
        return true
    }

    /// Removes an approved sender.
    /// - Parameters:
    ///   - channel: Channel id.
    ///   - accountID: Account key.
    ///   - senderID: Sender id.
    /// - Returns: `true` when the list changed.
    @discardableResult
    public func removeApproved(channel: ChannelID, accountID: String?, senderID: String) async throws -> Bool {
        var state = try await self.state(for: channel)
        let account = Self.normalizeAccountID(accountID)
        let current = state.allowFrom[account] ?? []
        let next = current.filter { $0 != senderID.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard next.count != current.count else { return false }
        state.allowFrom[account] = next
        try await self.store(state, for: channel)
        return true
    }

    // MARK: - Internals

    private func resolve(
        channel: ChannelID,
        accountID: String?,
        approve: Bool,
        matches: (ChannelPairingRequest) -> Bool
    ) async throws -> ChannelPairingRequest? {
        var state = try await self.state(for: channel)
        let pruned = Self.pruneExpired(state.requests, now: self.now())
        var requests = pruned.requests
        let account = accountID.map { Self.normalizeAccountID($0) }
        guard let index = requests.firstIndex(where: { (account == nil || $0.accountID == account) && matches($0) }) else {
            if pruned.removed {
                state.requests = requests
                try await self.store(state, for: channel)
            }
            return nil
        }
        let entry = requests.remove(at: index)
        state.requests = requests
        if approve {
            let allowAccount = account ?? entry.accountID
            var current = state.allowFrom[allowAccount] ?? []
            if !entry.id.isEmpty, !current.contains(entry.id) {
                current.append(entry.id)
                state.allowFrom[allowAccount] = current
            }
        }
        try await self.store(state, for: channel)
        return entry
    }

    /// Current state for a channel. The first load is shared by concurrent callers and never
    /// overwrites a snapshot another caller already mutated (upstream runs each read-modify-write
    /// in one SQLite transaction).
    private func state(for channel: ChannelID) async throws -> ChannelPairingChannelState {
        if self.snapshot == nil {
            let task: Task<ChannelPairingSnapshot, Error>
            if let loadTask {
                task = loadTask
            } else {
                let persistence = self.persistence
                task = Task { try await persistence.load() ?? ChannelPairingSnapshot() }
                self.loadTask = task
            }
            do {
                let loaded = try await task.value
                if self.snapshot == nil {
                    self.snapshot = loaded
                }
            } catch {
                if self.loadTask == task {
                    self.loadTask = nil
                }
                throw error
            }
        }
        return self.snapshot?.channels[channel.rawValue] ?? ChannelPairingChannelState()
    }

    /// Applies a channel state in memory, then persists the snapshot after every earlier save.
    private func store(_ state: ChannelPairingChannelState, for channel: ChannelID) async throws {
        var snapshot = self.snapshot ?? ChannelPairingSnapshot()
        snapshot.channels[channel.rawValue] = state
        self.snapshot = snapshot
        let previous = self.saveTail
        let persistence = self.persistence
        let save = Task<Void, Error> {
            _ = await previous?.result
            try await persistence.save(snapshot)
        }
        self.saveTail = save
        try await save.value
    }

    static func normalizeAccountID(_ raw: String?) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return trimmed.isEmpty ? "default" : trimmed
    }

    static func pruneExpired(_ requests: [ChannelPairingRequest], now: Date) -> (requests: [ChannelPairingRequest], removed: Bool) {
        let ttl = TimeInterval(Self.pendingTTLMs) / 1_000
        let kept = requests.filter { request in
            guard let created = request.createdDate else { return false }
            return now.timeIntervalSince(created) <= ttl
        }
        return (kept, kept.count != requests.count)
    }

    static func pruneExcess(_ requests: [ChannelPairingRequest]) -> (requests: [ChannelPairingRequest], removed: Bool) {
        guard requests.count > Self.maxPendingPerAccount else { return (requests, false) }
        var grouped: [String: [(offset: Int, request: ChannelPairingRequest)]] = [:]
        for (offset, request) in requests.enumerated() {
            grouped[request.accountID, default: []].append((offset, request))
        }
        var dropped = Set<Int>()
        for entries in grouped.values where entries.count > Self.maxPendingPerAccount {
            let sorted = entries.sorted {
                ($0.request.lastSeenDate ?? .distantPast) < ($1.request.lastSeenDate ?? .distantPast)
            }
            for entry in sorted.prefix(sorted.count - Self.maxPendingPerAccount) {
                dropped.insert(entry.offset)
            }
        }
        guard !dropped.isEmpty else { return (requests, false) }
        return (requests.enumerated().filter { !dropped.contains($0.offset) }.map(\.element), true)
    }

    static func randomCode() -> String {
        var generator = SystemRandomNumberGenerator()
        return String((0..<Self.codeLength).map { _ in Self.codeAlphabet.randomElement(using: &generator) ?? "A" })
    }

    static func generateUniqueCode(existing: Set<String>) -> String {
        for _ in 0..<500 {
            let code = Self.randomCode()
            if !existing.contains(code) {
                return code
            }
        }
        return Self.randomCode()
    }

    static func formatTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    static func parseTimestamp(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }
}

/// Pairing challenge reply text (upstream `buildPairingReply`).
public enum ChannelPairingReply {
    /// Builds the reply sent to an unapproved sender. Lines are joined with `\n`.
    /// - Parameters:
    ///   - channel: Channel id used in the approve command.
    ///   - idLine: Sender id line, for example `Your Telegram user id: 123`.
    ///   - code: Pairing code.
    /// - Returns: Reply text.
    public static func text(channel: ChannelID, idLine: String, code: String) -> String {
        [
            "OpenClaw: access not configured.",
            "",
            idLine,
            "Pairing code:",
            "```",
            code,
            "```",
            "",
            "Ask the bot owner to approve with:",
            "```",
            "openclaw pairing approve \(channel.rawValue) \(code)",
            "```",
        ].joined(separator: "\n")
    }

    /// Default sender id line, for example `Your Telegram user id: 123`.
    /// - Parameters:
    ///   - channel: Channel id.
    ///   - senderID: Sender id.
    /// - Returns: Id line.
    public static func idLine(channel: ChannelID, senderID: String) -> String {
        "Your \(channel.metadata.label) user id: \(senderID)"
    }
}
