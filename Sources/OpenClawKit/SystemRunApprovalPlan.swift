import Foundation
import OpenClawProtocol

/// A file operand an approval bound by content (upstream `SystemRunApprovalFileOperand`).
public struct OpenClawSystemRunApprovalFileOperand: Codable, Sendable, Equatable {
    /// Index of the operand in ``OpenClawSystemRunApprovalPlan/argv``.
    public var argvIndex: Int
    /// Path of the bound file.
    public var path: String
    /// SHA-256 of the file when the approval was prepared.
    public var sha256: String

    /// Creates a bound file operand.
    public init(argvIndex: Int, path: String, sha256: String) {
        self.argvIndex = argvIndex
        self.path = path
        self.sha256 = sha256
    }

    private enum CodingKeys: String, CodingKey {
        case argvIndex
        case path
        case sha256
    }

    /// Decodes with upstream validation: a non-negative index and non-empty path and hash.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let argvIndex = try container.decode(Int.self, forKey: .argvIndex)
        guard argvIndex >= 0,
              let path = OpenClawSystemRunApprovalPlan.nonEmpty(try container.decodeIfPresent(String.self, forKey: .path)),
              let sha256 = OpenClawSystemRunApprovalPlan.nonEmpty(try container.decodeIfPresent(String.self, forKey: .sha256))
        else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "invalid mutableFileOperand"))
        }
        self.init(argvIndex: argvIndex, path: path, sha256: sha256)
    }
}

/// The approval plan a node builds in `system.run.prepare` and the gateway forwards back as
/// `systemRunPlan` on the approved `system.run` (upstream `SystemRunApprovalPlan`).
///
/// Its ``policySnapshot`` is the exec policy the approval was granted under; exec hosts re-check it
/// right before launch (``OpenClawSystemRunLaunchGuard``). The gateway never sends the snapshot
/// anywhere else, and never synthesizes a plan: node approvals require `system.run.prepare`.
public struct OpenClawSystemRunApprovalPlan: Codable, Sendable, Equatable {
    /// Argument vector that was approved; the first element is the executable.
    public var argv: [String]
    /// Approved working directory.
    public var cwd: String?
    /// Authoritative command text shown to the approver.
    public var commandText: String
    /// Optional shorter preview of the command.
    public var commandPreview: String?
    /// Agent the plan was prepared for.
    public var agentId: String?
    /// Session the plan was prepared for.
    public var sessionKey: String?
    /// Exec policy the approval was prepared under (delayed-approval authority).
    public var policySnapshot: OpenClawSystemRunApprovalPolicySnapshot?
    /// A file operand the approval bound by content, when the command mutates one.
    public var mutableFileOperand: OpenClawSystemRunApprovalFileOperand?

    /// Creates a plan.
    public init(
        argv: [String],
        cwd: String? = nil,
        commandText: String,
        commandPreview: String? = nil,
        agentId: String? = nil,
        sessionKey: String? = nil,
        policySnapshot: OpenClawSystemRunApprovalPolicySnapshot? = nil,
        mutableFileOperand: OpenClawSystemRunApprovalFileOperand? = nil)
    {
        self.argv = argv
        self.cwd = cwd
        self.commandText = commandText
        self.commandPreview = commandPreview
        self.agentId = agentId
        self.sessionKey = sessionKey
        self.policySnapshot = policySnapshot
        self.mutableFileOperand = mutableFileOperand
    }

    /// Decodes a plan from the wire `systemRunPlan` value.
    /// - Throws: `DecodingError` when the value is not a valid plan.
    public init(wireValue: AnyCodable) throws {
        let data = try JSONEncoder().encode(wireValue)
        self = try JSONDecoder().decode(Self.self, from: data)
    }

    /// Returns a copy carrying the snapshot of `document` for the plan's agent, which
    /// `system.run.prepare` must embed so delayed approvals can be re-checked before launch.
    /// - Parameter document: The node's current exec approvals document (`nil` uses the defaults).
    public func withPolicySnapshot(from document: ExecApprovalsDocument?) -> Self {
        var plan = self
        plan.policySnapshot = OpenClawSystemRunApprovalPolicySnapshot(document: document, agentId: self.agentId)
        return plan
    }

    private enum CodingKeys: String, CodingKey {
        case argv
        case cwd
        case commandText
        case rawCommand
        case commandPreview
        case agentId
        case sessionKey
        case policySnapshot
        case mutableFileOperand
    }

    /// Decodes with upstream `normalizeSystemRunApprovalPlan` rules: a non-empty `argv`, a command
    /// text (`commandText`, else legacy `rawCommand`), and a present `policySnapshot` or
    /// `mutableFileOperand` must be valid (a malformed one fails the whole plan instead of being
    /// dropped). Optional strings are trimmed; empty ones decode as `nil`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let argv = try Self.decodeArgv(container)
        let commandText = try Self.nonEmpty(container.decodeIfPresent(AnyCodable.self, forKey: .commandText)?.stringValue)
            ?? Self.nonEmpty(container.decodeIfPresent(AnyCodable.self, forKey: .rawCommand)?.stringValue)
        guard !argv.isEmpty, let commandText else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "systemRunPlan requires argv and commandText"))
        }
        func optionalString(_ key: CodingKeys) throws -> String? {
            try Self.nonEmpty(container.decodeIfPresent(AnyCodable.self, forKey: key)?.stringValue)
        }
        self.init(
            argv: argv,
            cwd: try optionalString(.cwd),
            commandText: commandText,
            commandPreview: try optionalString(.commandPreview),
            agentId: try optionalString(.agentId),
            sessionKey: try optionalString(.sessionKey),
            policySnapshot: try Self.decodePresent(OpenClawSystemRunApprovalPolicySnapshot.self, container, .policySnapshot),
            mutableFileOperand: try Self.decodePresent(
                OpenClawSystemRunApprovalFileOperand.self,
                container,
                .mutableFileOperand))
    }

    /// Encodes the upstream wire shape.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.argv, forKey: .argv)
        try container.encode(self.cwd, forKey: .cwd)
        try container.encode(self.commandText, forKey: .commandText)
        try container.encodeIfPresent(self.commandPreview, forKey: .commandPreview)
        try container.encode(self.agentId, forKey: .agentId)
        try container.encode(self.sessionKey, forKey: .sessionKey)
        try container.encodeIfPresent(self.policySnapshot, forKey: .policySnapshot)
        try container.encodeIfPresent(self.mutableFileOperand, forKey: .mutableFileOperand)
    }

    /// Upstream coerces argv entries to strings; anything other than strings and integers fails closed.
    private static func decodeArgv(_ container: KeyedDecodingContainer<CodingKeys>) throws -> [String] {
        guard let values = try container.decodeIfPresent(AnyCodable.self, forKey: .argv)?.arrayValue else { return [] }
        var argv: [String] = []
        argv.reserveCapacity(values.count)
        for value in values {
            if let string = value.stringValue {
                argv.append(string)
            } else if let integer = value.intValue {
                argv.append(String(integer))
            } else {
                return []
            }
        }
        return argv
    }

    /// `undefined` stays `nil`; an explicit `null` or a malformed value fails the plan.
    private static func decodePresent<T: Decodable>(
        _ type: T.Type,
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys) throws -> T?
    {
        guard container.contains(key) else { return nil }
        return try container.decode(type, forKey: key)
    }

    static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

/// `system.run.prepare` response payload (upstream `{ plan, execPolicy, allowAlwaysCoverage }`).
public struct OpenClawSystemRunPrepareResult: Codable, Sendable, Equatable {
    /// The node's effective exec policy for the prepared command.
    public struct ExecPolicy: Codable, Sendable, Equatable {
        /// Effective security mode.
        public var security: OpenClawSystemRunApprovalPolicySnapshot.Security
        /// Effective ask mode.
        public var ask: OpenClawSystemRunApprovalPolicySnapshot.Ask

        /// Creates an exec policy summary.
        public init(security: OpenClawSystemRunApprovalPolicySnapshot.Security, ask: OpenClawSystemRunApprovalPolicySnapshot.Ask) {
            self.security = security
            self.ask = ask
        }
    }

    /// One allow-always pattern the approval could persist.
    public struct AllowAlwaysPattern: Codable, Sendable, Equatable {
        /// Executable pattern.
        public var pattern: String
        /// Optional argument pattern.
        public var argPattern: String?

        /// Creates a pattern.
        public init(pattern: String, argPattern: String? = nil) {
            self.pattern = pattern
            self.argPattern = argPattern
        }
    }

    /// Whether an allow-always decision fully covers the command, and with which patterns.
    public struct AllowAlwaysCoverage: Codable, Sendable, Equatable {
        /// `true` when ``patterns`` cover every executable the command runs.
        public var complete: Bool
        /// Patterns an allow-always decision would persist.
        public var patterns: [AllowAlwaysPattern]

        /// Creates a coverage summary.
        public init(complete: Bool, patterns: [AllowAlwaysPattern]) {
            self.complete = complete
            self.patterns = patterns
        }
    }

    /// The prepared plan; it must carry ``OpenClawSystemRunApprovalPlan/policySnapshot``.
    public var plan: OpenClawSystemRunApprovalPlan
    /// The node's effective exec policy.
    public var execPolicy: ExecPolicy
    /// Allow-always coverage (`complete: false, patterns: []` when none).
    public var allowAlwaysCoverage: AllowAlwaysCoverage

    /// Creates a prepare response, embedding the policy snapshot of `document` in `plan`.
    /// - Parameters:
    ///   - plan: The plan built from the requested command.
    ///   - document: The node's current exec approvals document (`nil` uses the defaults).
    ///   - execPolicy: Effective exec policy; defaults to the snapshot's security and ask.
    ///   - allowAlwaysCoverage: Allow-always coverage for the command.
    public init(
        plan: OpenClawSystemRunApprovalPlan,
        document: ExecApprovalsDocument?,
        execPolicy: ExecPolicy? = nil,
        allowAlwaysCoverage: AllowAlwaysCoverage = AllowAlwaysCoverage(complete: false, patterns: []))
    {
        let prepared = plan.withPolicySnapshot(from: document)
        self.plan = prepared
        self.execPolicy = execPolicy ?? ExecPolicy(
            security: prepared.policySnapshot?.security ?? .deny,
            ask: prepared.policySnapshot?.ask ?? .always)
        self.allowAlwaysCoverage = allowAlwaysCoverage
    }
}
