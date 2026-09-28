import Foundation

/// Session-key format produced by ``SessionKeyResolver``.
public enum SessionKeyFormat: String, Codable, Sendable, Equatable, CaseIterable {
    /// Legacy OpenClawKit keys (`channel:account:peer`). Default in 2026.3.0.
    case legacy
    /// Upstream agent-scoped keys (`agent:<agentId>:…`).
    case canonical
}

/// Peer kind used in canonical peer session keys (upstream `ChatType`).
public enum SessionPeerKind: String, Codable, Sendable, Equatable, CaseIterable {
    /// Direct message.
    case direct
    /// Group chat.
    case group
    /// Channel.
    case channel
}

/// Direct-message session scope (upstream `session.dmScope`).
public enum SessionDMScope: String, Codable, Sendable, Equatable, CaseIterable {
    /// Every DM shares the agent main session.
    case main
    /// One session per peer.
    case perPeer = "per-peer"
    /// One session per channel and peer.
    case perChannelPeer = "per-channel-peer"
    /// One session per account, channel and peer.
    case perAccountChannelPeer = "per-account-channel-peer"
}

/// Group session scope (upstream `session.groupScope`).
public enum SessionGroupScope: String, Codable, Sendable, Equatable, CaseIterable {
    /// Groups share the agent main session.
    case main
    /// One session per group.
    case perGroup = "per-group"
}

/// Canonical OpenClaw session-key helpers (upstream `src/routing/session-key.ts`,
/// `packages/session-url-contract/src/session-key.ts`, `packages/normalization-core/src/agent-id.ts`).
///
/// Canonical keys look like `agent:<agentId>:<rest>`. Agent ids are lowercase and filesystem safe;
/// Signal group ids and Matrix room tails keep their case (they are provider-owned opaque ids).
public enum SessionKey {
    /// Default agent id used when an id cannot be represented (`main`).
    public static let defaultAgentID = "main"
    /// Default main-session key (`main`).
    public static let defaultMainKey = "main"
    /// Default account id (`default`).
    public static let defaultAccountID = "default"

    /// Parsed `agent:<agentId>:<rest>` key.
    public struct Parsed: Sendable, Equatable {
        /// Agent id segment.
        public let agentID: String
        /// Remaining key after the agent id.
        public let rest: String
    }

    /// Normalizes an agent id (upstream `normalizeAgentId`).
    ///
    /// Values matching `^[a-z0-9][a-z0-9_-]{0,63}$` (case-insensitive) are lowercased; anything else
    /// is lowercased, runs of other characters become `-`, leading/trailing dashes are trimmed and the
    /// result is capped at 64 characters. Unrepresentable values fall back to `main`.
    /// - Parameter value: Raw agent id.
    /// - Returns: Canonical agent id.
    public static func normalizeAgentID(_ value: String?) -> String {
        Self.normalizeAgentIDStrict(value) ?? Self.defaultAgentID
    }

    /// Normalizes an explicitly supplied agent id without the `main` fallback.
    /// - Parameter value: Raw agent id.
    /// - Returns: Canonical agent id, or `nil` when unrepresentable.
    public static func normalizeAgentIDStrict(_ value: String?) -> String? {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        if Self.isValidAgentID(trimmed) {
            return lowered
        }
        let canonical = Self.canonicalizeIdentifier(lowered)
        return canonical.isEmpty ? nil : canonical
    }

    /// Whether a value is already a canonical agent-id input (`^[a-z0-9][a-z0-9_-]{0,63}$`, case-insensitive).
    /// - Parameter value: Raw agent id.
    /// - Returns: `true` when valid.
    public static func isValidAgentID(_ value: String?) -> Bool {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let scalars = Array(trimmed.lowercased().unicodeScalars)
        guard let first = scalars.first, scalars.count <= 64, Self.isAlphanumeric(first) else {
            return false
        }
        return scalars.dropFirst().allSatisfy { Self.isAlphanumeric($0) || $0 == "_" || $0 == "-" }
    }

    /// Normalizes an account id (upstream `normalizeAccountId`); blank or unrepresentable ids become `default`.
    /// - Parameter value: Raw account id.
    /// - Returns: Canonical account id.
    public static func normalizeAccountID(_ value: String?) -> String {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Self.defaultAccountID }
        if Self.isValidAgentID(trimmed) {
            return trimmed.lowercased()
        }
        let canonical = Self.canonicalizeIdentifier(trimmed.lowercased())
        guard !canonical.isEmpty, !["__proto__", "constructor", "prototype"].contains(canonical) else {
            return Self.defaultAccountID
        }
        return canonical
    }

    /// Normalizes a main-session key (blank becomes `main`).
    /// - Parameter value: Raw main key.
    /// - Returns: Lowercased main key.
    public static func normalizeMainKey(_ value: String?) -> String {
        let lowered = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lowered.isEmpty ? Self.defaultMainKey : lowered
    }

    /// Main session key for an agent: `agent:<id>:<mainKey>`.
    /// - Parameters:
    ///   - agentID: Agent id.
    ///   - mainKey: Main key (default `main`).
    /// - Returns: The main session key.
    public static func mainKey(agentID: String, mainKey: String? = nil) -> String {
        "agent:\(Self.normalizeAgentID(agentID)):\(Self.normalizeMainKey(mainKey))"
    }

    /// Splits `agent:<agentId>:<rest>` without normalizing (upstream `parseAgentSessionKeyParts`).
    ///
    /// The prefix is matched case-insensitively; the agent id must be non-empty and the rest must be
    /// non-empty and must not start with `:`.
    /// - Parameter key: Candidate key.
    /// - Returns: The parts, or `nil` when the key is not agent scoped.
    public static func parseParts(_ key: String) -> Parsed? {
        guard key.count > 6, key.prefix(6).lowercased() == "agent:" else {
            return nil
        }
        let afterPrefix = key.dropFirst(6)
        guard let separator = afterPrefix.firstIndex(of: ":") else {
            return nil
        }
        let agentID = afterPrefix[afterPrefix.startIndex..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
        let rest = String(afterPrefix[afterPrefix.index(after: separator)...])
        guard !agentID.isEmpty, !rest.isEmpty, !rest.hasPrefix(":") else {
            return nil
        }
        return Parsed(agentID: agentID, rest: rest)
    }

    /// Parses an agent-scoped key after canonical case folding (upstream `parseAgentSessionKey`).
    /// - Parameter key: Candidate key.
    /// - Returns: Canonical parts, or `nil` when the key is not agent scoped.
    public static func parse(_ key: String?) -> Parsed? {
        Self.parseParts(Self.normalizeKeyPreservingOpaquePeerIDs(key))
    }

    /// Whether the key is agent scoped.
    /// - Parameter key: Candidate key.
    /// - Returns: `true` for `agent:<id>:<rest>` keys.
    public static func isAgentScoped(_ key: String?) -> Bool {
        Self.parse(key) != nil
    }

    /// Whether the key is a sub-agent session key (`agent:<id>:subagent:…`).
    /// - Parameter key: Candidate key.
    /// - Returns: `true` for sub-agent keys.
    public static func isSubagentKey(_ key: String?) -> Bool {
        guard let parsed = Self.parse(key) else { return false }
        return parsed.rest.hasPrefix("subagent:")
    }

    /// Scopes a request key to an agent store key (upstream `toAgentStoreSessionKey`).
    ///
    /// Blank keys and `main` become the agent main key; agent-scoped keys are canonicalized; any
    /// other key becomes `agent:<id>:<normalized key>`.
    /// - Parameters:
    ///   - agentID: Agent id.
    ///   - requestKey: Request key.
    ///   - mainKey: Optional main key.
    /// - Returns: The store key.
    public static func toStoreKey(agentID: String, requestKey: String?, mainKey: String? = nil) -> String {
        let raw = (requestKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = raw.lowercased()
        if raw.isEmpty || lowered == Self.defaultMainKey {
            return Self.mainKey(agentID: agentID, mainKey: mainKey)
        }
        if let parsed = Self.parse(raw) {
            return "agent:\(parsed.agentID):\(parsed.rest)"
        }
        let normalized = Self.normalizeKeyPreservingOpaquePeerIDs(raw)
        if lowered.hasPrefix("agent:") {
            return normalized
        }
        return "agent:\(Self.normalizeAgentID(agentID)):\(normalized)"
    }

    /// Request-facing key for a store key (upstream `toAgentRequestSessionKey`): the rest after the agent id.
    /// - Parameter storeKey: Store key.
    /// - Returns: The request key, or `nil` when blank.
    public static func toRequestKey(_ storeKey: String?) -> String? {
        let raw = (storeKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        return Self.parse(raw)?.rest ?? raw
    }

    /// Agent id embedded in a key, or the fallback for legacy keys.
    /// - Parameters:
    ///   - key: Session key.
    ///   - fallback: Agent id used for keys that are not agent scoped.
    /// - Returns: Canonical agent id.
    public static func agentID(from key: String?, fallback: String = SessionKey.defaultAgentID) -> String {
        if let parsed = Self.parse(key) {
            return Self.normalizeAgentID(parsed.agentID)
        }
        return Self.normalizeAgentID(fallback)
    }

    /// Builds a peer session key (upstream `buildAgentPeerSessionKey`, without identity links).
    ///
    /// Shapes: `agent:<id>:<channel>:<account>:direct:<peer>` (`per-account-channel-peer`),
    /// `agent:<id>:<channel>:direct:<peer>` (`per-channel-peer`), `agent:<id>:direct:<peer>`
    /// (`per-peer`), the agent main key (DM scope `main`, or group scope `main`), and
    /// `agent:<id>:<channel>:<kind>:<peer>` for groups and channels.
    /// - Parameters:
    ///   - agentID: Agent id.
    ///   - channel: Channel id.
    ///   - accountID: Optional account id.
    ///   - peerKind: Peer kind.
    ///   - peerID: Peer id.
    ///   - dmScope: DM scope.
    ///   - groupScope: Group scope.
    ///   - mainKey: Optional main key.
    /// - Returns: The peer session key.
    public static func peerKey(
        agentID: String,
        channel: String,
        accountID: String? = nil,
        peerKind: SessionPeerKind = .direct,
        peerID: String?,
        dmScope: SessionDMScope = .main,
        groupScope: SessionGroupScope = .perGroup,
        mainKey: String? = nil
    ) -> String {
        let agent = Self.normalizeAgentID(agentID)
        let loweredChannel = channel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let channelSegment = loweredChannel.isEmpty ? "unknown" : loweredChannel
        if peerKind == .direct {
            let peer = (peerID ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !peer.isEmpty {
                switch dmScope {
                case .perAccountChannelPeer:
                    return "agent:\(agent):\(channelSegment):\(Self.normalizeAccountID(accountID)):direct:\(peer)"
                case .perChannelPeer:
                    return "agent:\(agent):\(channelSegment):direct:\(peer)"
                case .perPeer:
                    return "agent:\(agent):direct:\(peer)"
                case .main:
                    break
                }
            }
            return Self.mainKey(agentID: agent, mainKey: mainKey)
        }
        if groupScope == .main {
            return Self.mainKey(agentID: agent, mainKey: mainKey)
        }
        let peer = Self.normalizePeerID(channel: channel, peerKind: peerKind, peerID: peerID)
        return "agent:\(agent):\(channelSegment):\(peerKind.rawValue):\(peer.isEmpty ? "unknown" : peer)"
    }

    /// New sub-agent session key: `agent:<id>:subagent:<uuid>`.
    /// - Parameter agentID: Agent id.
    /// - Returns: A unique sub-agent key.
    public static func subagentKey(agentID: String) -> String {
        "agent:\(Self.normalizeAgentID(agentID)):subagent:\(UUID().uuidString.lowercased())"
    }

    /// Normalizes a peer id: Signal group ids and Matrix channel/group ids keep their case, others lowercase.
    /// - Parameters:
    ///   - channel: Channel id.
    ///   - peerKind: Peer kind.
    ///   - peerID: Raw peer id.
    /// - Returns: The normalized peer id.
    public static func normalizePeerID(channel: String?, peerKind: SessionPeerKind?, peerID: String?) -> String {
        let peer = (peerID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !peer.isEmpty else { return "" }
        return Self.preservesPeerCase(channel: channel, peerKind: peerKind?.rawValue) ? peer : peer.lowercased()
    }

    /// Lowercases a key while keeping provider-owned opaque peer ids (upstream
    /// `normalizeSessionKeyPreservingOpaquePeerIds`): the Signal `signal:group:<id>` segment and the
    /// Matrix `matrix:channel|group:` tail (up to a trailing `:thread:` marker) keep their case.
    /// - Parameter key: Raw key.
    /// - Returns: The folded key.
    public static func normalizeKeyPreservingOpaquePeerIDs(_ key: String?) -> String {
        let raw = (key ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "" }
        let folded = raw.lowercased()
        guard folded.contains("signal:") || folded.contains("matrix:") else {
            return folded
        }
        var segments = raw.components(separatedBy: ":")
        var index = 0
        var preservedTailFrom: Int?
        while index < segments.count {
            let segment = segments[index].lowercased()
            if segment == "signal", index + 2 < segments.count, segments[index + 1].lowercased() == "group" {
                segments[index] = "signal"
                segments[index + 1] = "group"
                segments[index + 2] = segments[index + 2].trimmingCharacters(in: .whitespacesAndNewlines)
                index += 3
                continue
            }
            if segment == "matrix", index + 2 < segments.count,
               ["channel", "group"].contains(segments[index + 1].lowercased())
            {
                segments[index] = "matrix"
                segments[index + 1] = segments[index + 1].lowercased()
                preservedTailFrom = index + 2
                break
            }
            segments[index] = segment
            index += 1
        }
        if let tailStart = preservedTailFrom {
            // Fold only the structural `thread` marker inside the preserved Matrix tail.
            if let marker = segments[tailStart...].lastIndex(where: { $0.lowercased() == "thread" }), marker > tailStart {
                segments[marker] = "thread"
            }
        }
        return segments.joined(separator: ":")
    }

    private static func preservesPeerCase(channel: String?, peerKind: String?) -> Bool {
        let channel = (channel ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let kind = (peerKind ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return (channel == "signal" && kind == "group") || (channel == "matrix" && (kind == "channel" || kind == "group"))
    }

    private static func canonicalizeIdentifier(_ lowered: String) -> String {
        var result = ""
        var pendingDash = false
        for scalar in lowered.unicodeScalars {
            if Self.isAlphanumeric(scalar) || scalar == "_" || scalar == "-" {
                if pendingDash {
                    result.append("-")
                    pendingDash = false
                }
                result.unicodeScalars.append(scalar)
            } else {
                pendingDash = true
            }
        }
        while result.hasPrefix("-") {
            result.removeFirst()
        }
        while result.hasSuffix("-") {
            result.removeLast()
        }
        return String(result.prefix(64))
    }

    private static func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        (97...122).contains(scalar.value) || (48...57).contains(scalar.value)
    }
}
