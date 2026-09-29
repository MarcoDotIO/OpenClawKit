import Foundation
import OpenClawNativeState

/// Exec security policy: how shell commands requested by an agent are admitted.
public enum ExecApprovalsSecurity: String, CaseIterable, Codable, Identifiable, Sendable {
    /// Refuse every command.
    case deny
    /// Run only commands that match the allowlist.
    case allowlist
    /// Run every command.
    case full

    /// Stable identifier (the raw value).
    public var id: String {
        self.rawValue
    }
}

/// When the operator is asked to approve a command.
public enum ExecApprovalsAsk: String, CaseIterable, Codable, Identifiable, Sendable {
    /// Never ask; apply the security policy.
    case off
    /// Ask when a command misses the allowlist (`"on-miss"`).
    case onMiss = "on-miss"
    /// Ask for every command.
    case always

    /// Stable identifier (the raw value).
    public var id: String {
        self.rawValue
    }
}

/// One allowlist rule in an exec-approvals document.
///
/// Decodes the legacy bare-string form as a pattern. Encoding intentionally omits `commandText`
/// (display-only, matching upstream).
public struct ExecApprovalsAllowlistEntry: Codable, Hashable, Identifiable, Sendable {
    /// Rule identifier; generated when missing or empty in the source document.
    public var id: String
    /// Executable pattern (path or glob).
    public var pattern: String
    /// Origin of the rule, for example `allow-always`.
    public var source: String?
    /// Display text of the command that created the rule (not persisted).
    public var commandText: String?
    /// Optional argument pattern.
    public var argPattern: String?
    /// Last use time in milliseconds since the Unix epoch (the Node gateway writes `Date.now()`).
    public var lastUsedAt: Double?
    /// Last command that matched the rule.
    public var lastUsedCommand: String?
    /// Last resolved executable path for the rule.
    public var lastResolvedPath: String?

    /// Creates an allowlist entry.
    public init(
        id: String = UUID().uuidString,
        pattern: String,
        source: String? = nil,
        commandText: String? = nil,
        argPattern: String? = nil,
        lastUsedAt: Double? = nil,
        lastUsedCommand: String? = nil,
        lastResolvedPath: String? = nil)
    {
        self.id = id
        self.pattern = pattern
        self.source = source
        self.commandText = commandText
        self.argPattern = argPattern
        self.lastUsedAt = lastUsedAt
        self.lastUsedCommand = lastUsedCommand
        self.lastResolvedPath = lastResolvedPath
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case pattern
        case source
        case commandText
        case argPattern
        case lastUsedAt
        case lastUsedCommand
        case lastResolvedPath
    }

    /// Decodes either the object form or a legacy bare-string pattern.
    public init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let legacyPattern = try? container.decode(String.self)
        {
            self.init(pattern: legacyPattern.trimmingCharacters(in: .whitespacesAndNewlines))
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedID = try container.decodeIfPresent(String.self, forKey: .id)
        let id = decodedID.flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString
        try self.init(
            id: id,
            pattern: container.decode(String.self, forKey: .pattern),
            source: container.decodeIfPresent(String.self, forKey: .source),
            commandText: container.decodeIfPresent(String.self, forKey: .commandText),
            argPattern: container.decodeIfPresent(String.self, forKey: .argPattern),
            lastUsedAt: container.decodeIfPresent(Double.self, forKey: .lastUsedAt),
            lastUsedCommand: container.decodeIfPresent(String.self, forKey: .lastUsedCommand),
            lastResolvedPath: container.decodeIfPresent(String.self, forKey: .lastResolvedPath))
    }

    /// Encodes the entry, omitting `commandText`.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .id)
        try container.encode(self.pattern, forKey: .pattern)
        try container.encodeIfPresent(self.source, forKey: .source)
        try container.encodeIfPresent(self.argPattern, forKey: .argPattern)
        try container.encodeIfPresent(self.lastUsedAt, forKey: .lastUsedAt)
        try container.encodeIfPresent(self.lastUsedCommand, forKey: .lastUsedCommand)
        try container.encodeIfPresent(self.lastResolvedPath, forKey: .lastResolvedPath)
    }
}

/// Default policy applied to agents without their own overrides.
public struct ExecApprovalsDefaultsDocument: Codable, Sendable, Equatable {
    /// Default security policy.
    public var security: ExecApprovalsSecurity?
    /// Default ask mode.
    public var ask: ExecApprovalsAsk?
    /// Security applied when an approval prompt cannot be shown or times out.
    public var askFallback: ExecApprovalsSecurity?
    /// Whether commands required by installed skills are allowed automatically.
    public var autoAllowSkills: Bool?

    /// Creates a defaults document.
    public init(
        security: ExecApprovalsSecurity? = nil,
        ask: ExecApprovalsAsk? = nil,
        askFallback: ExecApprovalsSecurity? = nil,
        autoAllowSkills: Bool? = nil)
    {
        self.security = security
        self.ask = ask
        self.askFallback = askFallback
        self.autoAllowSkills = autoAllowSkills
    }
}

/// Per-agent policy overrides and allowlist.
public struct ExecApprovalsAgentDocument: Codable, Sendable, Equatable {
    /// Agent security policy override.
    public var security: ExecApprovalsSecurity?
    /// Agent ask mode override.
    public var ask: ExecApprovalsAsk?
    /// Agent ask-fallback override.
    public var askFallback: ExecApprovalsSecurity?
    /// Agent skill auto-allow override.
    public var autoAllowSkills: Bool?
    /// Agent allowlist rules.
    public var allowlist: [ExecApprovalsAllowlistEntry]?

    /// Creates an agent document.
    public init(
        security: ExecApprovalsSecurity? = nil,
        ask: ExecApprovalsAsk? = nil,
        askFallback: ExecApprovalsSecurity? = nil,
        autoAllowSkills: Bool? = nil,
        allowlist: [ExecApprovalsAllowlistEntry]? = nil)
    {
        self.security = security
        self.ask = ask
        self.askFallback = askFallback
        self.autoAllowSkills = autoAllowSkills
        self.allowlist = allowlist
    }

    /// Whether the document carries no overrides and no allowlist rules.
    public var isEmpty: Bool {
        self.security == nil && self.ask == nil && self.askFallback == nil
            && self.autoAllowSkills == nil && (self.allowlist?.isEmpty ?? true)
    }
}

/// Exec-approvals prompt socket settings (macOS exec host).
public struct ExecApprovalsSocketDocument: Codable, Sendable, Equatable {
    /// Unix socket path.
    public var path: String?
    /// Shared secret for the socket; never log it.
    public var token: String?

    /// Creates a socket document.
    public init(path: String? = nil, token: String? = nil) {
        self.path = path
        self.token = token
    }
}

/// The exec-approvals document (`exec-approvals.json` shape, version 1), shared with the Node gateway.
public struct ExecApprovalsDocument: Codable, Sendable, Equatable {
    /// Document version; must be 1.
    public var version: Int
    /// Prompt socket settings.
    public var socket: ExecApprovalsSocketDocument?
    /// Default policy.
    public var defaults: ExecApprovalsDefaultsDocument?
    /// Per-agent overrides keyed by agent id (`"default"` is a legacy alias of `"main"`).
    public var agents: [String: ExecApprovalsAgentDocument]?

    /// Creates an exec-approvals document.
    public init(
        version: Int,
        socket: ExecApprovalsSocketDocument? = nil,
        defaults: ExecApprovalsDefaultsDocument? = nil,
        agents: [String: ExecApprovalsAgentDocument]? = nil)
    {
        self.version = version
        self.socket = socket
        self.defaults = defaults
        self.agents = agents
    }
}

/// The stored exec-approvals singleton: the authoritative raw JSON and its decoded document.
public struct ExecApprovalsSQLiteRecord: Sendable, Equatable {
    /// Authoritative `raw_json` column value.
    public let rawJSON: String
    /// Strictly validated decoded document.
    public let document: ExecApprovalsDocument

    /// Creates a record.
    public init(rawJSON: String, document: ExecApprovalsDocument) {
        self.rawJSON = rawJSON
        self.document = document
    }
}

/// Result of an ``ExecApprovalsSQLiteStore/withImmediateTransaction(stateDirectoryURL:updatedAtMilliseconds:_:)`` body.
public struct ExecApprovalsSQLiteMutation<Value> {
    /// Value returned to the caller after commit.
    public let value: Value
    /// Replacement document to write in the same transaction, or nil to leave the row unchanged.
    public let documentToWrite: ExecApprovalsDocument?

    /// Creates a mutation result.
    public init(value: Value, documentToWrite: ExecApprovalsDocument? = nil) {
        self.value = value
        self.documentToWrite = documentToWrite
    }
}

/// SQLite store for the exec-approvals singleton (`exec_approvals_config`, key `"current"`).
///
/// Every call takes an explicit state directory; there is no hidden default. A macOS exec host
/// that passes `OpenClawStateDirectory.cliShared()` shares approvals with the Node gateway through
/// its versioned database. Before any access the legacy gate refuses to run while
/// `<stateDir>/exec-approvals.json` (or Doctor's `.doctor-importing` claim) exists: Doctor owns
/// that import, so the SDK never reads the JSON file.
///
/// All methods are synchronous and may block on SQLite locks.
public enum ExecApprovalsSQLiteStore {
    /// Singleton row key.
    public static let configKey = "current"
    /// Upstream locator string for the singleton.
    public static let locator = "state/openclaw.sqlite#exec_approvals_config"
    private static let busyTimeoutMilliseconds: Int32 = 30000

    /// Database location for a state directory: `<stateDir>/state/openclaw.sqlite`.
    public static func databaseURL(stateDirectoryURL: URL) -> URL {
        stateDirectoryURL
            .appendingPathComponent("state", isDirectory: true)
            .appendingPathComponent("openclaw.sqlite", isDirectory: false)
    }

    /// Reads the singleton, or nil when no document has been written.
    ///
    /// - Throws: ``ExecApprovalsLegacyMigrationRequiredError`` while a legacy JSON file awaits Doctor,
    ///   or an `OpenClawNativeStateError` for schema or decode failures.
    public static func read(stateDirectoryURL: URL) throws -> ExecApprovalsSQLiteRecord? {
        try ExecApprovalsLegacyMigrationGate.assertReady(stateDirectoryURL: stateDirectoryURL)
        let database = try self.openDatabase(stateDirectoryURL: stateDirectoryURL)
        return try database.withImmediateTransaction {
            try database.ensureCanonicalTable(.execApprovalsConfig)
            return try self.readRecord(database)
        }
    }

    /// Replaces the singleton with `document`, deriving every projection column from it.
    public static func write(
        _ document: ExecApprovalsDocument,
        stateDirectoryURL: URL,
        updatedAtMilliseconds: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) throws
    {
        try self.withImmediateTransaction(
            stateDirectoryURL: stateDirectoryURL,
            updatedAtMilliseconds: updatedAtMilliseconds)
        { _ in
            ExecApprovalsSQLiteMutation(value: (), documentToWrite: document)
        }
    }

    /// Reads, optionally replaces, and commits the singleton inside one `BEGIN IMMEDIATE` transaction.
    ///
    /// Writes are fenced while a Node agent deletion is in progress for any agent whose projected
    /// policy changes.
    public static func withImmediateTransaction<Value>(
        stateDirectoryURL: URL,
        updatedAtMilliseconds: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        _ body: (ExecApprovalsSQLiteRecord?) throws -> ExecApprovalsSQLiteMutation<Value>) throws -> Value
    {
        try ExecApprovalsLegacyMigrationGate.assertReady(stateDirectoryURL: stateDirectoryURL)
        let database = try self.openDatabase(stateDirectoryURL: stateDirectoryURL)
        return try database.withImmediateTransaction {
            try database.ensureCanonicalTable(.execApprovalsConfig)
            let current = try self.readRecord(database)
            let mutation = try body(current)
            if let document = mutation.documentToWrite {
                try self.assertMutationNotFenced(
                    database,
                    current: current?.document,
                    next: document)
                try self.writeRecord(
                    database,
                    document: document,
                    updatedAtMilliseconds: updatedAtMilliseconds)
            }
            return mutation.value
        }
    }

    static func decode(_ rawJSON: String) throws -> ExecApprovalsDocument {
        guard let data = rawJSON.data(using: .utf8), self.hasValidPersistedStructure(data) else {
            throw OpenClawNativeStateError("Malformed exec approvals raw_json")
        }
        let document = try JSONDecoder().decode(ExecApprovalsDocument.self, from: data)
        guard document.version == 1 else {
            throw OpenClawNativeStateError(
                "Unsupported exec approvals version \(document.version) in raw_json")
        }
        return document
    }

    /// Serializes a version-1 document as pretty-printed, key-sorted JSON with a trailing newline.
    ///
    /// The output is re-validated with the strict persisted-structure decoder before it is returned.
    public static func serialize(_ document: ExecApprovalsDocument) throws -> String {
        guard document.version == 1 else {
            throw OpenClawNativeStateError("Exec approvals document version must be 1")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        guard let rawJSON = String(data: data, encoding: .utf8) else {
            throw OpenClawNativeStateError("Could not encode exec approvals as UTF-8")
        }
        let persisted = rawJSON + "\n"
        _ = try self.decode(persisted)
        return persisted
    }

    private static func openDatabase(stateDirectoryURL: URL) throws -> OpenClawNativeStateSQLite {
        try OpenClawNativeStateSQLite(
            databaseURL: self.databaseURL(stateDirectoryURL: stateDirectoryURL),
            busyTimeoutMilliseconds: self.busyTimeoutMilliseconds)
    }

    private static func readRecord(
        _ database: OpenClawNativeStateSQLite) throws -> ExecApprovalsSQLiteRecord?
    {
        let statement = try database.prepare(
            "SELECT raw_json FROM exec_approvals_config WHERE config_key = ?")
        try statement.bindText(self.configKey, at: 1)
        guard try statement.step() == .row else { return nil }
        let rawJSON = try statement.requiredText(at: 0, field: "exec approvals raw_json")
        guard try statement.step() == .done else {
            throw OpenClawNativeStateError("Exec approvals singleton query returned multiple rows")
        }
        return try ExecApprovalsSQLiteRecord(rawJSON: rawJSON, document: self.decode(rawJSON))
    }

    private static func writeRecord(
        _ database: OpenClawNativeStateSQLite,
        document: ExecApprovalsDocument,
        updatedAtMilliseconds: Int64) throws
    {
        let rawJSON = try self.serialize(document)
        let projected = self.projectionDocument(document)
        let agents = Array((projected.agents ?? [:]).values)
        let statement = try database.prepare("""
        INSERT INTO exec_approvals_config (
          config_key, raw_json, socket_path, has_socket_token,
          default_security, default_ask, default_ask_fallback, auto_allow_skills,
          agent_count, allowlist_count, updated_at_ms
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(config_key) DO UPDATE SET
          raw_json = excluded.raw_json,
          socket_path = excluded.socket_path,
          has_socket_token = excluded.has_socket_token,
          default_security = excluded.default_security,
          default_ask = excluded.default_ask,
          default_ask_fallback = excluded.default_ask_fallback,
          auto_allow_skills = excluded.auto_allow_skills,
          agent_count = excluded.agent_count,
          allowlist_count = excluded.allowlist_count,
          updated_at_ms = excluded.updated_at_ms
        """)
        try statement.bindText(self.configKey, at: 1)
        try statement.bindText(rawJSON, at: 2)
        try self.bind(projected.socket?.path, to: statement, at: 3)
        try statement.bindInt64(projected.socket?.token?.isEmpty == false ? 1 : 0, at: 4)
        try self.bind(projected.defaults?.security?.rawValue, to: statement, at: 5)
        try self.bind(projected.defaults?.ask?.rawValue, to: statement, at: 6)
        try self.bind(projected.defaults?.askFallback?.rawValue, to: statement, at: 7)
        if let autoAllowSkills = projected.defaults?.autoAllowSkills {
            try statement.bindInt64(autoAllowSkills ? 1 : 0, at: 8)
        } else {
            try statement.bindNull(at: 8)
        }
        try statement.bindInt64(Int64(agents.count), at: 9)
        try statement.bindInt64(
            Int64(agents.reduce(0) { $0 + ($1.allowlist?.count ?? 0) }),
            at: 10)
        try statement.bindInt64(updatedAtMilliseconds, at: 11)
        guard try statement.step() == .done else {
            throw OpenClawNativeStateError("Exec approvals upsert did not complete")
        }
    }

    private static func assertMutationNotFenced(
        _ database: OpenClawNativeStateSQLite,
        current: ExecApprovalsDocument?,
        next: ExecApprovalsDocument) throws
    {
        let table = try database.prepare(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'agent_deletion_journal'")
        guard try table.step() == .row else { return }

        let currentAgents = current.map { self.projectionDocument($0).agents ?? [:] } ?? [:]
        let nextAgents = self.projectionDocument(next).agents ?? [:]
        for agentID in Set(currentAgents.keys).union(nextAgents.keys)
            where currentAgents[agentID] != nextAgents[agentID]
        {
            let statement = try database.prepare(
                "SELECT 1 FROM agent_deletion_journal WHERE agent_id = ? LIMIT 1")
            try statement.bindText(self.normalizedAgentID(agentID), at: 1)
            if try statement.step() == .row {
                throw OpenClawNativeStateError(
                    "Exec approvals cannot be changed while agent deletion is in progress; retry.")
            }
        }
    }

    private static func normalizedAgentID(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "main" }
        let normalized = trimmed.lowercased()
        if trimmed.range(
            of: "^[a-z0-9][a-z0-9_-]{0,63}$",
            options: [.regularExpression, .caseInsensitive]) != nil
        {
            return normalized
        }
        let replaced = normalized.replacingOccurrences(
            of: "[^a-z0-9_-]+", with: "-", options: .regularExpression)
        let stripped = replaced.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let truncated = String(stripped.prefix(64))
        return truncated.isEmpty ? "main" : truncated
    }

    private static func projectionDocument(
        _ document: ExecApprovalsDocument) -> ExecApprovalsDocument
    {
        var agents = document.agents ?? [:]
        if let legacyDefault = agents.removeValue(forKey: "default") {
            if let current = agents["main"] {
                agents["main"] = self.mergeAgent(current: current, legacy: legacyDefault)
            } else {
                agents["main"] = legacyDefault
            }
        }
        for (key, var agent) in agents {
            agent.allowlist = agent.allowlist?.filter {
                !$0.pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            agents[key] = agent
        }
        let socketPath = document.socket?.path?.trimmingCharacters(in: .whitespacesAndNewlines)
        let socketToken = document.socket?.token?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ExecApprovalsDocument(
            version: 1,
            socket: ExecApprovalsSocketDocument(
                path: socketPath?.isEmpty == false ? socketPath : nil,
                token: socketToken?.isEmpty == false ? socketToken : nil),
            defaults: document.defaults,
            agents: agents)
    }

    private static func mergeAgent(
        current: ExecApprovalsAgentDocument,
        legacy: ExecApprovalsAgentDocument) -> ExecApprovalsAgentDocument
    {
        var seen = Set<String>()
        let allowlist = ((current.allowlist ?? []) + (legacy.allowlist ?? [])).filter { entry in
            let pattern = entry.pattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !pattern.isEmpty else { return false }
            let key = "\(pattern)\0\(entry.argPattern?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")"
            return seen.insert(key).inserted
        }
        return ExecApprovalsAgentDocument(
            security: current.security ?? legacy.security,
            ask: current.ask ?? legacy.ask,
            askFallback: current.askFallback ?? legacy.askFallback,
            autoAllowSkills: current.autoAllowSkills ?? legacy.autoAllowSkills,
            allowlist: allowlist.isEmpty ? nil : allowlist)
    }

    private static func bind(
        _ value: String?,
        to statement: OpenClawNativeStateSQLiteStatement,
        at index: Int32) throws
    {
        if let value {
            try statement.bindText(value, at: index)
        } else {
            try statement.bindNull(at: index)
        }
    }

    private static func hasValidPersistedStructure(_ data: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = root["version"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(),
              version.doubleValue == 1
        else { return false }
        if let socket = root["socket"] {
            guard let object = socket as? [String: Any],
                  self.hasOptionalString(object, key: "path"),
                  self.hasOptionalString(object, key: "token")
            else { return false }
        }
        if let defaults = root["defaults"], !self.hasValidPolicyFields(defaults) {
            return false
        }
        if let agents = root["agents"] {
            guard let object = agents as? [String: Any] else { return false }
            for value in object.values {
                guard self.hasValidPolicyFields(value), let agent = value as? [String: Any] else {
                    return false
                }
                if let allowlist = agent["allowlist"] {
                    guard let entries = allowlist as? [Any],
                          entries.allSatisfy(self.hasValidAllowlistEntry)
                    else { return false }
                }
            }
        }
        return true
    }

    private static func hasValidAllowlistEntry(_ value: Any) -> Bool {
        if let pattern = value as? String {
            return !pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard let object = value as? [String: Any],
              let pattern = object["pattern"] as? String,
              !pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        for key in ["id", "source", "commandText", "argPattern", "lastUsedCommand", "lastResolvedPath"] {
            if let value = object[key], !(value is String) {
                return false
            }
        }
        if let lastUsedAt = object["lastUsedAt"] {
            guard let number = lastUsedAt as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite
            else { return false }
        }
        return true
    }

    private static func hasValidPolicyFields(_ value: Any) -> Bool {
        guard let object = value as? [String: Any] else { return false }
        if let security = object["security"] {
            guard let raw = security as? String, ExecApprovalsSecurity(rawValue: raw) != nil else {
                return false
            }
        }
        if let ask = object["ask"] {
            guard let raw = ask as? String, ExecApprovalsAsk(rawValue: raw) != nil else {
                return false
            }
        }
        if let fallback = object["askFallback"] {
            guard let raw = fallback as? String, ExecApprovalsSecurity(rawValue: raw) != nil else {
                return false
            }
        }
        if let autoAllowSkills = object["autoAllowSkills"], !(autoAllowSkills is Bool) {
            return false
        }
        return true
    }

    private static func hasOptionalString(_ object: [String: Any], key: String) -> Bool {
        guard let value = object[key] else { return true }
        return value is String
    }
}
