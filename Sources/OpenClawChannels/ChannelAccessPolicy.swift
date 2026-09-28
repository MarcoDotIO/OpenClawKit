import Foundation
import OpenClawCore

/// Upstream ingress reason codes (`src/channels/message-access`).
public enum ChannelAccessReasonCode: String, Sendable, Equatable, Hashable, CaseIterable {
    /// Direct messages are disabled.
    case dmPolicyDisabled = "dm_policy_disabled"
    /// Open DM policy with a `"*"` allowlist.
    case dmPolicyOpen = "dm_policy_open"
    /// Sender matched `allowFrom` (or, under pairing, the pairing store).
    case dmPolicyAllowlisted = "dm_policy_allowlisted"
    /// Sender is not allowlisted.
    case dmPolicyNotAllowlisted = "dm_policy_not_allowlisted"
    /// Sender must pair first.
    case dmPolicyPairingRequired = "dm_policy_pairing_required"
    /// Pairing policy, but the event cannot start pairing (no sender, or not a user request).
    case eventPairingNotAllowed = "event_pairing_not_allowed"
    /// Group messages are disabled.
    case groupPolicyDisabled = "group_policy_disabled"
    /// Open group policy.
    case groupPolicyOpen = "group_policy_open"
    /// Sender matched the group allowlist.
    case groupPolicyAllowed = "group_policy_allowed"
    /// Allowlist group policy with an empty allowlist.
    case groupPolicyEmptyAllowlist = "group_policy_empty_allowlist"
    /// Sender is not in the group allowlist.
    case groupPolicyNotAllowlisted = "group_policy_not_allowlisted"
    /// The route (group/room override) blocks dispatch.
    case routeBlocked = "route_blocked"
    /// Control command from an unauthorized group sender.
    case controlCommandUnauthorized = "control_command_unauthorized"
    /// Group message without the required mention.
    case mentionRequired = "mention_required"
    /// Bot sender while `allowBots` is off.
    case botSenderNotAllowed = "bot_sender_not_allowed"
    /// Bot sender without a mention while `allowBots` is `mentions`.
    case botSenderNotMentioned = "bot_sender_not_mentioned"
}

/// Outcome of the ingress access gate.
public enum ChannelAccessDecision: Sendable, Equatable {
    /// Dispatch the message.
    case allow
    /// Drop the message; `reason` is an upstream reason code.
    case block(reason: String)
    /// Sender must pair; `created` is `true` when a new pairing request (and reply) was issued.
    case pairingRequired(code: String, created: Bool)
    /// Group message without the required mention.
    case mentionRequired
}

/// Detailed access evaluation (decision plus the decisive reason code).
public struct ChannelAccessEvaluation: Sendable, Equatable {
    /// Decision.
    public var decision: ChannelAccessDecision
    /// Decisive reason code.
    public var reasonCode: ChannelAccessReasonCode
    /// Whether the message is an authorized control command (bypasses mention gating).
    public var commandAuthorized: Bool

    /// Creates an evaluation.
    /// - Parameters:
    ///   - decision: Decision.
    ///   - reasonCode: Decisive reason code.
    ///   - commandAuthorized: Whether a control command was authorized.
    public init(decision: ChannelAccessDecision, reasonCode: ChannelAccessReasonCode, commandAuthorized: Bool = false) {
        self.decision = decision
        self.reasonCode = reasonCode
        self.commandAuthorized = commandAuthorized
    }
}

/// Channel ingress access policy (upstream sender, command and mention gates).
///
/// Direct messages:
/// - `disabled` blocks;
/// - `open` admits `"*"` or an allowlist match (an explicit list still narrows; an unset list is
///   treated as `"*"`);
/// - `allowlist` admits only `allowFrom` matches;
/// - `pairing` (default) admits `allowFrom` matches and approved pairing-store senders, otherwise
///   issues a pairing code. Pairing-store matches only count under `pairing`.
///
/// Groups: `disabled` blocks; `open` admits; `allowlist` (default) requires the sender in
/// `groupAllowFrom`, falling back to `allowFrom` when `groupAllowFrom` is unset (an explicit `[]`
/// blocks all). Then control commands (`/health`, `/status`, `/help`) need an allowlisted sender,
/// and `requireMention` (default `true`, per-group overridable) drops unmentioned messages when
/// the adapter can detect mentions; implicit mentions count when enabled.
public struct ChannelAccessPolicyEvaluator: Sendable {
    /// Control commands handled by the auto-reply engine.
    public static let controlCommands: Set<String> = ["/health", "/status", "/help"]

    /// Creates an evaluator.
    public init() {}

    /// Evaluates one inbound message.
    /// - Parameters:
    ///   - message: Inbound message.
    ///   - config: Resolved messaging policy for the channel account.
    ///   - store: Pairing store (`nil` disables pairing-store matches and new pairing requests).
    /// - Returns: Access decision.
    public func evaluate(
        _ message: InboundMessage,
        config: ChannelMessagingPolicyConfig,
        store: ChannelPairingStore?
    ) async -> ChannelAccessDecision {
        await self.evaluateDetailed(message, config: config, store: store).decision
    }

    /// Evaluates one inbound message and returns the decisive reason code.
    /// - Parameters:
    ///   - message: Inbound message.
    ///   - config: Resolved messaging policy.
    ///   - store: Pairing store.
    /// - Returns: Detailed evaluation.
    public func evaluateDetailed(
        _ message: InboundMessage,
        config: ChannelMessagingPolicyConfig,
        store: ChannelPairingStore?
    ) async -> ChannelAccessEvaluation {
        let sender = message.senderID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.isFromBot {
            switch config.allowBots ?? .disabled {
            case .disabled:
                return ChannelAccessEvaluation(decision: .block(reason: ChannelAccessReasonCode.botSenderNotAllowed.rawValue), reasonCode: .botSenderNotAllowed)
            case .mentions where message.wasMentioned != true:
                return ChannelAccessEvaluation(
                    decision: .block(reason: ChannelAccessReasonCode.botSenderNotMentioned.rawValue),
                    reasonCode: .botSenderNotMentioned
                )
            default:
                break
            }
        }
        if message.chatType == .direct {
            return await self.evaluateDirect(message, sender: sender, config: config, store: store)
        }
        return self.evaluateGroup(message, sender: sender, config: config)
    }

    // MARK: Direct messages

    private func evaluateDirect(
        _ message: InboundMessage,
        sender: String?,
        config: ChannelMessagingPolicyConfig,
        store: ChannelPairingStore?
    ) async -> ChannelAccessEvaluation {
        let policy = config.effectiveDMPolicy
        let allowFrom = config.allowFrom
        let entries = Self.normalizedEntries(allowFrom ?? [], channel: message.channel)
        let matched = sender.map { Self.matches(entries, sender: $0, channel: message.channel) } ?? false
        func allow(_ code: ChannelAccessReasonCode) -> ChannelAccessEvaluation {
            ChannelAccessEvaluation(decision: .allow, reasonCode: code, commandAuthorized: true)
        }
        func block(_ code: ChannelAccessReasonCode) -> ChannelAccessEvaluation {
            ChannelAccessEvaluation(decision: .block(reason: code.rawValue), reasonCode: code)
        }
        switch policy {
        case .disabled:
            return block(.dmPolicyDisabled)
        case .open:
            if allowFrom == nil || entries.contains("*") {
                return allow(.dmPolicyOpen)
            }
            return matched ? allow(.dmPolicyAllowlisted) : block(.dmPolicyNotAllowlisted)
        case .allowlist:
            return matched ? allow(.dmPolicyAllowlisted) : block(.dmPolicyNotAllowlisted)
        case .pairing:
            if matched {
                return allow(.dmPolicyAllowlisted)
            }
            guard let sender, !sender.isEmpty else {
                return block(.eventPairingNotAllowed)
            }
            if let store {
                let approved = (try? await store.approvedSenders(channel: message.channel, accountID: message.accountID)) ?? []
                if Self.matches(Self.normalizedEntries(approved, channel: message.channel), sender: sender, channel: message.channel) {
                    return allow(.dmPolicyAllowlisted)
                }
            }
            guard message.eventKind == .userRequest, let store else {
                return block(.eventPairingNotAllowed)
            }
            var meta: [String: String] = [:]
            if let name = message.senderName {
                meta["name"] = name
            }
            // An empty code means the account already has the maximum number of pending requests.
            guard let result = try? await store.upsert(
                channel: message.channel,
                accountID: message.accountID,
                senderID: sender,
                meta: meta
            ), !result.code.isEmpty else {
                return block(.dmPolicyPairingRequired)
            }
            return ChannelAccessEvaluation(
                decision: .pairingRequired(code: result.code, created: result.created),
                reasonCode: .dmPolicyPairingRequired
            )
        }
    }

    // MARK: Groups

    private func evaluateGroup(
        _ message: InboundMessage,
        sender: String?,
        config: ChannelMessagingPolicyConfig
    ) -> ChannelAccessEvaluation {
        func block(_ code: ChannelAccessReasonCode) -> ChannelAccessEvaluation {
            ChannelAccessEvaluation(decision: .block(reason: code.rawValue), reasonCode: code)
        }
        let groupOverride = config.groupConfig(for: message.peerID)
        if groupOverride?.enabled == false {
            return block(.routeBlocked)
        }
        let policy = groupOverride?.groupPolicy ?? config.effectiveGroupPolicy
        let list = groupOverride?.allowFrom ?? config.groupAllowFrom ?? config.allowFrom
        let entries = Self.normalizedEntries(list ?? [], channel: message.channel)
        let matched = sender.map { Self.matches(entries, sender: $0, channel: message.channel) } ?? false

        let senderReason: ChannelAccessReasonCode
        switch policy {
        case .disabled:
            return block(.groupPolicyDisabled)
        case .open:
            senderReason = .groupPolicyOpen
        case .allowlist:
            guard !entries.isEmpty else {
                return block(.groupPolicyEmptyAllowlist)
            }
            guard matched else {
                return block(.groupPolicyNotAllowlisted)
            }
            senderReason = .groupPolicyAllowed
        }

        let isCommand = Self.isControlCommand(message.text)
        if isCommand, !matched {
            return block(.controlCommandUnauthorized)
        }

        let requireMention = groupOverride?.requireMention ?? config.requireMention ?? true
        let canDetectMention = message.wasMentioned != nil
        let allowedImplicit = Self.allowedImplicitMentionKinds(groupOverride?.implicitMentions.map {
            (config.implicitMentions ?? ChannelImplicitMentionsConfig()).merged(with: $0)
        } ?? config.implicitMentions)
        let implicitMention = !message.implicitMentionKinds.isDisjoint(with: allowedImplicit)
        let effectiveWasMentioned = message.wasMentioned == true || implicitMention || isCommand
        if message.eventKind == .userRequest, requireMention, canDetectMention, !effectiveWasMentioned {
            return ChannelAccessEvaluation(decision: .mentionRequired, reasonCode: .mentionRequired)
        }
        return ChannelAccessEvaluation(decision: .allow, reasonCode: senderReason, commandAuthorized: isCommand)
    }

    // MARK: Helpers

    /// Implicit mention kinds admitted by a config (upstream `allowedImplicitMentionKindsFromConfig`).
    /// - Parameter config: Implicit mention config (`nil` enables every kind).
    /// - Returns: Admitted kinds.
    public static func allowedImplicitMentionKinds(_ config: ChannelImplicitMentionsConfig?) -> Set<ChannelImplicitMentionKind> {
        var kinds: Set<ChannelImplicitMentionKind> = [.native]
        if config?.replyToBot != false { kinds.insert(.replyToBot) }
        if config?.quotedBot != false { kinds.insert(.quotedBot) }
        if config?.threadParticipation != false { kinds.insert(.botThreadParticipant) }
        return kinds
    }

    /// Whether text is a control command handled by the auto-reply engine.
    /// - Parameter text: Message text.
    /// - Returns: `true` for `/health`, `/status` and `/help` (optionally `@botname`-suffixed).
    public static func isControlCommand(_ text: String) -> Bool {
        let first = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(maxSplits: 1, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
            .first
            .map { String($0).lowercased() } ?? ""
        let command = first.split(separator: "@", maxSplits: 1).first.map(String.init) ?? first
        return Self.controlCommands.contains(command)
    }

    /// Normalizes an allowlist entry for matching.
    ///
    /// Trims, drops a `<channel>:` (or alias) prefix and a leading `@`, lowercases, and for phone
    /// channels (SMS, Signal, iMessage, WhatsApp, BlueBubbles) reduces phone numbers to E.164.
    /// - Parameters:
    ///   - entry: Raw entry or sender id.
    ///   - channel: Channel id.
    /// - Returns: Normalized entry (`"*"` stays `"*"`).
    public static func normalizeAllowEntry(_ entry: String, channel: ChannelID) -> String {
        var value = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value != "*" else { return "*" }
        let prefixes = [channel.rawValue] + channel.metadata.aliases + ["user", "tg"]
        for prefix in prefixes {
            let marker = prefix.lowercased() + ":"
            if value.lowercased().hasPrefix(marker) {
                value = String(value.dropFirst(marker.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        if value.hasPrefix("<@"), value.hasSuffix(">") {
            value = String(value.dropFirst(2).dropLast()).trimmingCharacters(in: CharacterSet(charactersIn: "!&"))
        }
        if value.hasPrefix("@") {
            value.removeFirst()
        }
        value = value.lowercased()
        if Self.phoneChannels.contains(channel), let e164 = Self.e164(value) {
            return e164
        }
        return value
    }

    static let phoneChannels: Set<ChannelID> = [.sms, .signal, .imessage, .whatsapp, .bluebubbles]

    static func e164(_ value: String) -> String? {
        guard !value.contains("@") else { return nil }
        let allowed = CharacterSet(charactersIn: "+0123456789 -().")
        guard value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        let digits = value.filter(\.isNumber)
        guard digits.count >= 6 else { return nil }
        return "+" + digits
    }

    static func normalizedEntries(_ entries: [String], channel: ChannelID) -> Set<String> {
        Set(entries.map { self.normalizeAllowEntry($0, channel: channel) }.filter { !$0.isEmpty })
    }

    static func matches(_ entries: Set<String>, sender: String, channel: ChannelID) -> Bool {
        if entries.contains("*") {
            return true
        }
        return entries.contains(self.normalizeAllowEntry(sender, channel: channel))
    }
}
