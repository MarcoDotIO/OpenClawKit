import Foundation
import OpenClawCore
import OpenClawProtocol

/// Tool allow/deny policy (upstream `tools` / `agents.entries.<id>.tools` policy fields).
///
/// Matching follows upstream `createToolPolicyMatcher` and the profile stage of the effective policy
/// pipeline:
/// - Names are normalized (trim, lowercase, aliases `bash`→`exec`, `apply-patch`→`apply_patch`,
///   `cron`→`automations`; legacy list entry `image`→`view_image`) and groups (`group:<section>`,
///   `group:openclaw`) are expanded. Entries may use `*` globs.
/// - Deny always wins. `bundle-mcp` or `group:plugins` in `deny` removes every MCP tool; a
///   `server__*` pattern denies one MCP namespace; `group:plugins` also removes plugin tools.
/// - A `profile` restricts tools to the profile allow list (plus ``alsoAllow``); `full` allows all.
/// - A non-empty `allow` restricts tools further (``alsoAllow`` extends it); an empty or missing
///   `allow` allows everything not denied.
/// - Allowing `write` also allows `apply_patch`. `bundle-mcp` in an allow list admits MCP tools and
///   `group:plugins` admits plugin and MCP tools.
/// - ``stages`` are further policies that must also allow the tool (upstream's policy pipeline:
///   global `tools`, then `agents.entries.<id>.tools`). Each stage can only restrict: deny in any
///   stage wins and allow lists intersect.
public struct ToolPolicy: Codable, Sendable, Equatable {
    /// Built-in profile (`minimal`, `coding`, `messaging`, `full`).
    public var profile: ToolProfileID?
    /// Allow list (empty or `nil` = everything not denied).
    public var allow: [String]?
    /// Extra entries merged into the profile and allow lists.
    public var alsoAllow: [String]?
    /// Deny list (always wins).
    public var deny: [String]?
    /// Further policies a tool must also pass (intersection; `nil` = none).
    public var stages: [ToolPolicy]?

    /// Policy that allows every tool.
    public static let allowAll = ToolPolicy()

    /// Creates a policy.
    /// - Parameters:
    ///   - profile: Built-in profile.
    ///   - allow: Allow list.
    ///   - alsoAllow: Extra allow entries.
    ///   - deny: Deny list.
    public init(profile: ToolProfileID? = nil, allow: [String]? = nil, alsoAllow: [String]? = nil, deny: [String]? = nil) {
        self.profile = profile
        self.allow = allow
        self.alsoAllow = alsoAllow
        self.deny = deny
    }

    private enum CodingKeys: String, CodingKey {
        case profile
        case allow
        case alsoAllow
        case deny
        case stages
    }

    /// Decodes a policy, tolerating unknown keys and single-string lists.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func list(_ key: CodingKeys) -> [String]? {
            if let values = try? container.decodeIfPresent([String].self, forKey: key) {
                return values
            }
            if let value = try? container.decodeIfPresent(String.self, forKey: key) {
                return [value]
            }
            return nil
        }
        self.profile = (try? container.decodeIfPresent(ToolProfileID.self, forKey: .profile)) ?? nil
        self.allow = list(.allow)
        self.alsoAllow = list(.alsoAllow)
        self.deny = list(.deny)
        self.stages = (try? container.decodeIfPresent([ToolPolicy].self, forKey: .stages)) ?? nil
    }

    /// Encodes the policy (`stages` only when present).
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.profile, forKey: .profile)
        try container.encodeIfPresent(self.allow, forKey: .allow)
        try container.encodeIfPresent(self.alsoAllow, forKey: .alsoAllow)
        try container.encodeIfPresent(self.deny, forKey: .deny)
        try container.encodeIfPresent(self.stages, forKey: .stages)
    }

    /// Whether the policy restricts nothing.
    public var isUnrestricted: Bool {
        self.profile == nil && (self.allow ?? []).isEmpty && (self.deny ?? []).isEmpty
            && (self.stages ?? []).allSatisfy(\.isUnrestricted)
    }

    /// Policy that allows a tool only when both this policy and `other` allow it.
    /// - Parameter other: Additional restriction.
    /// - Returns: The intersected policy (`self` when `other` restricts nothing).
    public func intersecting(_ other: ToolPolicy) -> ToolPolicy {
        guard !other.isUnrestricted else { return self }
        var copy = self
        copy.stages = (self.stages ?? []) + [other]
        return copy
    }

    /// Returns whether a tool is allowed.
    /// - Parameters:
    ///   - name: Tool name.
    ///   - source: Tool origin (MCP and plugin tools have extra group tokens).
    /// - Returns: `true` when the tool passes every stage of the policy.
    public func allows(_ name: String, source: AgentToolSource = .core) -> Bool {
        ToolPolicyMatcher(policy: self).allows(name, source: source)
    }

    /// Returns whether a descriptor is allowed.
    /// - Parameter descriptor: Tool descriptor.
    /// - Returns: `true` when allowed.
    public func allows(_ descriptor: AgentToolDescriptor) -> Bool {
        self.allows(descriptor.name, source: descriptor.source)
    }

    /// Filters descriptors by the policy.
    /// - Parameter descriptors: Candidate descriptors.
    /// - Returns: Allowed descriptors, in order.
    public func filter(_ descriptors: [AgentToolDescriptor]) -> [AgentToolDescriptor] {
        guard !self.isUnrestricted else { return descriptors }
        let matcher = ToolPolicyMatcher(policy: self)
        return descriptors.filter { matcher.allows($0.name, source: $0.source) }
    }

    /// Policy that removes `names` (added to ``deny``).
    /// - Parameter names: Tool names to deny.
    /// - Returns: The tightened policy.
    public func denying(_ names: [String]) -> ToolPolicy {
        var copy = self
        copy.deny = (self.deny ?? []) + names
        return copy
    }
}

/// Compiled ``ToolPolicy`` for repeated matching.
public struct ToolPolicyMatcher: Sendable {
    private let deny: [ToolGlobPattern]
    private let denyAllMCP: Bool
    private let denyPlugins: Bool
    private let profileAllow: ToolAllowStage?
    private let configAllow: ToolAllowStage?
    private let stages: [ToolPolicyMatcher]

    /// Compiles a policy.
    /// - Parameter policy: Policy to compile.
    public init(policy: ToolPolicy) {
        let denyEntries = (policy.deny ?? []).map(CoreToolCatalog.normalizePolicyEntry)
        self.deny = CoreToolCatalog.expandGroups(policy.deny ?? []).map(ToolGlobPattern.init)
        self.denyAllMCP = denyEntries.contains(CoreToolCatalog.bundleMCPToken) || denyEntries.contains(CoreToolCatalog.pluginsGroupToken)
        self.denyPlugins = denyEntries.contains(CoreToolCatalog.pluginsGroupToken)
        let also = policy.alsoAllow ?? []
        if let profile = policy.profile, let profileList = CoreToolCatalog.profileAllowList(profile) {
            self.profileAllow = ToolAllowStage(entries: profileList + also)
        } else {
            self.profileAllow = nil
        }
        if let allow = policy.allow, !allow.isEmpty {
            self.configAllow = ToolAllowStage(entries: allow + also)
        } else {
            self.configAllow = nil
        }
        self.stages = (policy.stages ?? []).map(ToolPolicyMatcher.init(policy:))
    }

    /// Returns whether a tool is allowed.
    /// - Parameters:
    ///   - name: Tool name.
    ///   - source: Tool origin.
    /// - Returns: `true` when allowed.
    public func allows(_ name: String, source: AgentToolSource = .core) -> Bool {
        let normalized = AgentToolRegistry.canonicalName(name)
        let isMCP: Bool
        let isPlugin: Bool
        switch source {
        case .mcp:
            isMCP = true
            isPlugin = false
        case .plugin:
            isMCP = false
            isPlugin = true
        default:
            isMCP = false
            isPlugin = false
        }
        if self.deny.contains(where: { $0.matches(normalized) }) {
            return false
        }
        if isMCP, self.denyAllMCP {
            return false
        }
        if isPlugin, self.denyPlugins {
            return false
        }
        if let stage = self.profileAllow, !stage.allows(normalized, isMCP: isMCP, isPlugin: isPlugin) {
            return false
        }
        if let stage = self.configAllow, !stage.allows(normalized, isMCP: isMCP, isPlugin: isPlugin) {
            return false
        }
        return self.stages.allSatisfy { $0.allows(name, source: source) }
    }
}

private struct ToolAllowStage: Sendable {
    let patterns: [ToolGlobPattern]
    let admitsMCP: Bool
    let admitsPlugins: Bool

    init(entries: [String]) {
        let normalized = entries.map(CoreToolCatalog.normalizePolicyEntry)
        self.patterns = CoreToolCatalog.expandGroups(entries).map(ToolGlobPattern.init)
        self.admitsMCP = normalized.contains(CoreToolCatalog.bundleMCPToken) || normalized.contains(CoreToolCatalog.pluginsGroupToken)
        self.admitsPlugins = normalized.contains(CoreToolCatalog.pluginsGroupToken)
    }

    func allows(_ normalized: String, isMCP: Bool, isPlugin: Bool) -> Bool {
        if self.patterns.contains(where: { $0.matches(normalized) }) {
            return true
        }
        if normalized == "apply_patch", self.patterns.contains(where: { $0.matches("write") }) {
            return true
        }
        if isMCP, self.admitsMCP {
            return true
        }
        if isPlugin, self.admitsPlugins {
            return true
        }
        return false
    }
}

/// Lightweight glob used by tool policies (`*` matches any run of characters).
struct ToolGlobPattern: Sendable, Equatable {
    private enum Kind: Sendable, Equatable {
        case all
        case exact(String)
        case glob([String])
    }

    private let kind: Kind

    init(_ raw: String) {
        let normalized = CoreToolCatalog.normalizePolicyEntry(raw)
        if normalized == "*" {
            self.kind = .all
        } else if normalized.contains("*") {
            self.kind = .glob(normalized.components(separatedBy: "*"))
        } else {
            self.kind = .exact(normalized)
        }
    }

    func matches(_ value: String) -> Bool {
        switch self.kind {
        case .all:
            return true
        case .exact(let exact):
            return !exact.isEmpty && value == exact
        case .glob(let parts):
            guard let first = parts.first, let last = parts.last, value.hasPrefix(first) else {
                return false
            }
            var remainder = value.dropFirst(first.count)
            for middle in parts.dropFirst().dropLast() where !middle.isEmpty {
                guard let range = remainder.range(of: middle) else { return false }
                remainder = remainder[range.upperBound...]
            }
            return parts.count == 1 || remainder.hasSuffix(last)
        }
    }
}

/// Runtime tool configuration for the embedded agent loop (SDK counterpart of upstream `tools`).
public struct AgentToolsConfiguration: Codable, Sendable, Equatable {
    /// Allow/deny policy applied to every run.
    public var policy: ToolPolicy
    /// Loop detection (off by default).
    public var loopDetection: AgentLoopDetectionConfiguration
    /// Tool search configuration (`nil` = upstream default for embedded runs).
    public var toolSearch: ToolSearchConfiguration?

    /// Creates a configuration.
    /// - Parameters:
    ///   - policy: Allow/deny policy.
    ///   - loopDetection: Loop detection settings.
    ///   - toolSearch: Tool search settings.
    public init(
        policy: ToolPolicy = .allowAll,
        loopDetection: AgentLoopDetectionConfiguration = AgentLoopDetectionConfiguration(),
        toolSearch: ToolSearchConfiguration? = nil
    ) {
        self.policy = policy
        self.loopDetection = loopDetection
        self.toolSearch = toolSearch
    }
}

/// Repeated tool-call loop detection (upstream `docs/tools/loop-detection.md`), off by default.
///
/// When enabled, the loop aborts the run once the same `(tool, arguments, result)` triple repeats
/// ``threshold`` times within the last ``window`` tool results.
public struct AgentLoopDetectionConfiguration: Codable, Sendable, Equatable {
    /// Whether detection is enabled.
    public var enabled: Bool
    /// Number of identical triples that trips the detector.
    public var threshold: Int
    /// Number of recent tool results inspected.
    public var window: Int

    /// Creates loop detection settings.
    /// - Parameters:
    ///   - enabled: Whether detection is enabled.
    ///   - threshold: Identical repeats that trip the detector (minimum 2).
    ///   - window: Recent results inspected (minimum `threshold`).
    public init(enabled: Bool = false, threshold: Int = 3, window: Int = 12) {
        self.enabled = enabled
        self.threshold = max(2, threshold)
        self.window = max(max(2, threshold), window)
    }
}
