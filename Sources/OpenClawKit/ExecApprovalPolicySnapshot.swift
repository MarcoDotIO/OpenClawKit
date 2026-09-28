import Foundation

/// Canonical persisted-policy snapshot carried with delayed exec authority.
///
/// Rules are de-duplicated by exact UTF-8 bytes (not canonical equivalence) and sorted by UTF-8
/// byte order so every platform produces the same canonical encoding.
public struct OpenClawSystemRunApprovalPolicySnapshot: Codable, Sendable, Equatable {
    /// Security policy.
    public enum Security: String, Codable, Sendable, Hashable {
        /// Refuse every command.
        case deny
        /// Run only allowlisted commands.
        case allowlist
        /// Run every command.
        case full
    }

    /// Ask mode.
    public enum Ask: String, Codable, Sendable, Hashable {
        /// Never ask.
        case off
        /// Ask when a command misses the allowlist.
        case onMiss = "on-miss"
        /// Always ask.
        case always
    }

    /// Origin of an allowlist rule.
    public enum RuleSource: String, Codable, Sendable, Hashable {
        /// Created from an "allow always" approval.
        case allowAlways = "allow-always"
    }

    /// One allowlist rule.
    public struct Rule: Codable, Sendable, Hashable {
        /// Executable pattern.
        public let pattern: String
        /// Optional argument pattern.
        public let argPattern: String?
        /// Rule origin.
        public let source: RuleSource?

        /// Creates a rule.
        public init(pattern: String, argPattern: String? = nil, source: RuleSource? = nil) {
            self.pattern = pattern
            self.argPattern = argPattern
            self.source = source
        }
    }

    /// Security policy.
    public let security: Security
    /// Ask mode.
    public let ask: Ask
    /// Fallback security when no prompt can be shown.
    public let askFallback: Security
    /// Whether skill commands are allowed automatically.
    public let autoAllowSkills: Bool
    /// Canonical (de-duplicated, byte-sorted) allowlist rules.
    public let allowlistRules: [Rule]

    private struct RuleKey: Hashable {
        let pattern: Data
        let argPattern: Data?
        let source: RuleSource?

        init(_ rule: Rule) {
            self.pattern = Data(rule.pattern.utf8)
            self.argPattern = rule.argPattern.map { Data($0.utf8) }
            self.source = rule.source
        }
    }

    /// Creates a snapshot, canonicalizing `allowlistRules`.
    public init(
        security: Security,
        ask: Ask,
        askFallback: Security,
        autoAllowSkills: Bool,
        allowlistRules: [Rule])
    {
        self.security = security
        self.ask = ask
        self.askFallback = askFallback
        self.autoAllowSkills = autoAllowSkills
        self.allowlistRules = Dictionary(
            allowlistRules.map { (RuleKey($0), $0) },
            uniquingKeysWith: { first, _ in first }).values.sorted(by: Self.rulePrecedes)
    }

    private enum CodingKeys: String, CodingKey {
        case security
        case ask
        case askFallback
        case autoAllowSkills
        case allowlistRules
    }

    /// Decodes a snapshot and canonicalizes its rules.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            security: container.decode(Security.self, forKey: .security),
            ask: container.decode(Ask.self, forKey: .ask),
            askFallback: container.decode(Security.self, forKey: .askFallback),
            autoAllowSkills: container.decode(Bool.self, forKey: .autoAllowSkills),
            allowlistRules: container.decode([Rule].self, forKey: .allowlistRules))
    }

    /// Encodes the canonical snapshot.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.security, forKey: .security)
        try container.encode(self.ask, forKey: .ask)
        try container.encode(self.askFallback, forKey: .askFallback)
        try container.encode(self.autoAllowSkills, forKey: .autoAllowSkills)
        try container.encode(self.allowlistRules, forKey: .allowlistRules)
    }

    private static func rulePrecedes(_ lhs: Rule, _ rhs: Rule) -> Bool {
        let patternOrder = self.compareUTF8(lhs.pattern, rhs.pattern)
        if patternOrder != 0 {
            return patternOrder < 0
        }
        let argPatternOrder = self.compareOptionalUTF8(lhs.argPattern, rhs.argPattern)
        if argPatternOrder != 0 {
            return argPatternOrder < 0
        }
        return self.compareOptionalUTF8(lhs.source?.rawValue, rhs.source?.rawValue) < 0
    }

    private static func compareOptionalUTF8(_ lhs: String?, _ rhs: String?) -> Int {
        switch (lhs, rhs) {
        case (nil, nil): 0
        case (nil, .some): -1
        case (.some, nil): 1
        case let (.some(lhs), .some(rhs)):
            self.compareUTF8(lhs, rhs)
        }
    }

    private static func compareUTF8(_ lhs: String, _ rhs: String) -> Int {
        let lhsBytes = Array(lhs.utf8)
        let rhsBytes = Array(rhs.utf8)
        if lhsBytes == rhsBytes {
            return 0
        }
        return lhsBytes.lexicographicallyPrecedes(rhsBytes) ? -1 : 1
    }
}
