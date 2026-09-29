import Foundation
import OpenClawCore

// MARK: - Bot loop protection

/// Resolved bot-loop guard thresholds (upstream `PairLoopGuardSettings`).
public struct ChannelBotLoopGuardSettings: Sendable, Equatable {
    /// Whether the guard is active.
    public var enabled: Bool
    /// Pair events allowed per window before the cooldown starts.
    public var maxEventsPerWindow: Int
    /// Rolling window in milliseconds.
    public var windowMs: Int64
    /// Suppression cooldown in milliseconds.
    public var cooldownMs: Int64

    /// Creates settings.
    /// - Parameters:
    ///   - enabled: Whether the guard is active.
    ///   - maxEventsPerWindow: Events per window.
    ///   - windowMs: Window in milliseconds.
    ///   - cooldownMs: Cooldown in milliseconds.
    public init(enabled: Bool = true, maxEventsPerWindow: Int = 20, windowMs: Int64 = 60_000, cooldownMs: Int64 = 60_000) {
        self.enabled = enabled
        self.maxEventsPerWindow = maxEventsPerWindow
        self.windowMs = windowMs
        self.cooldownMs = cooldownMs
    }

    /// Built-in defaults: enabled, 20 events per 60 s, 60 s cooldown.
    public static let defaults = ChannelBotLoopGuardSettings()

    /// Resolves settings from configs ordered broadest to narrowest (upstream precedence: built-in,
    /// `channels.defaults`, channel, account, room). Non-positive numbers are ignored.
    /// - Parameters:
    ///   - configs: Configs from broadest to narrowest.
    ///   - defaultEnabled: Channel capability gate; `false` disables the guard regardless of config.
    /// - Returns: Resolved settings.
    public static func resolve(
        _ configs: [ChannelBotLoopProtectionConfig?],
        defaultEnabled: Bool = true
    ) -> ChannelBotLoopGuardSettings {
        var settings = Self.defaults
        for config in configs.compactMap({ $0 }) {
            if let enabled = config.enabled {
                settings.enabled = enabled
            }
            if let value = config.maxEventsPerWindow, value > 0 {
                settings.maxEventsPerWindow = value
            }
            if let value = config.windowSeconds, value > 0 {
                settings.windowMs = Int64(value) * 1_000
            }
            if let value = config.cooldownSeconds, value > 0 {
                settings.cooldownMs = Int64(value) * 1_000
            }
        }
        settings.enabled = settings.enabled && defaultEnabled
        return settings
    }
}

/// Result of recording one bot-to-bot interaction.
public enum ChannelBotLoopGuardResult: Sendable, Equatable {
    /// The message may be processed.
    case allowed
    /// The pair is in cooldown until the given time.
    case suppressed(cooldownUntil: Date)
}

/// Sliding-window guard that suppresses bot-to-bot reply loops (upstream `createPairLoopGuard`).
///
/// Interactions are keyed by scope (channel + account), conversation and the *unordered* pair of
/// bot ids, so A→B and B→A count together. When a pair exceeds the budget it is suppressed for
/// the cooldown. Human messages are never recorded.
public actor ChannelBotLoopGuard {
    private struct Entry {
        var recent: [(timestampMs: Int64, eventID: String?)] = []
        var windowMs: Int64 = 0
        var cooldownStartedAtMs: Int64 = 0
        var cooldownUntilMs: Int64 = 0
    }

    private var tracked: [String: Entry] = [:]
    private var nextPruneAtMs: Int64 = 0
    private let pruneIntervalMs: Int64
    private let now: @Sendable () -> Date

    /// Creates a guard.
    /// - Parameters:
    ///   - pruneIntervalMs: Interval between pruning inactive pairs.
    ///   - now: Clock (injectable for tests).
    public init(pruneIntervalMs: Int64 = 60_000, now: @escaping @Sendable () -> Date = { Date() }) {
        self.pruneIntervalMs = pruneIntervalMs
        self.now = now
    }

    /// Records one interaction and reports whether the pair must be suppressed.
    /// - Parameters:
    ///   - scopeID: Channel/account scope.
    ///   - conversationID: Conversation or thread id.
    ///   - senderID: Sending bot id.
    ///   - receiverID: Receiving bot id.
    ///   - eventID: Stable event id (retries with the same id are not double counted).
    ///   - settings: Resolved thresholds.
    /// - Returns: Guard result.
    public func recordAndCheck(
        scopeID: String,
        conversationID: String,
        senderID: String,
        receiverID: String,
        eventID: String? = nil,
        settings: ChannelBotLoopGuardSettings
    ) -> ChannelBotLoopGuardResult {
        guard settings.enabled,
              !scopeID.isEmpty, !conversationID.isEmpty, !senderID.isEmpty, !receiverID.isEmpty,
              senderID != receiverID,
              settings.maxEventsPerWindow > 0, settings.windowMs > 0, settings.cooldownMs > 0
        else {
            return .allowed
        }
        let nowMs = Int64((self.now().timeIntervalSince1970 * 1_000).rounded())
        self.pruneInactive(nowMs: nowMs)
        let lhs = min(senderID, receiverID)
        let rhs = max(senderID, receiverID)
        let key = [scopeID, conversationID, lhs, rhs].joined(separator: "\u{1}")
        var entry = self.tracked[key] ?? Entry()
        entry.windowMs = settings.windowMs
        entry.recent.removeAll { $0.timestampMs <= nowMs - settings.windowMs }
        let trimmedEventID = eventID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedEventID, !trimmedEventID.isEmpty, entry.recent.contains(where: { $0.eventID == trimmedEventID }) {
            self.tracked[key] = entry
            return .allowed
        }
        if entry.cooldownStartedAtMs <= nowMs, entry.cooldownUntilMs > nowMs {
            self.tracked[key] = entry
            return .suppressed(cooldownUntil: Date(timeIntervalSince1970: TimeInterval(entry.cooldownUntilMs) / 1_000))
        }
        entry.recent.append((nowMs, trimmedEventID?.isEmpty == false ? trimmedEventID : nil))
        if entry.recent.filter({ $0.timestampMs <= nowMs }).count > settings.maxEventsPerWindow {
            entry.cooldownStartedAtMs = nowMs
            entry.cooldownUntilMs = nowMs + settings.cooldownMs
            entry.recent.removeAll { $0.timestampMs <= nowMs }
            self.tracked[key] = entry
            return .suppressed(cooldownUntil: Date(timeIntervalSince1970: TimeInterval(entry.cooldownUntilMs) / 1_000))
        }
        self.tracked[key] = entry
        return .allowed
    }

    /// Records a bot message using channel policy precedence.
    ///
    /// Applies only to bot senders; the room override (`groups.<peer>.botLoopProtection`) wins over
    /// the resolved channel/account/defaults policy.
    /// - Parameters:
    ///   - message: Inbound message.
    ///   - policy: Resolved messaging policy (already merged with `channels.defaults`).
    /// - Returns: Guard result.
    public func check(_ message: InboundMessage, policy: ChannelMessagingPolicyConfig) -> ChannelBotLoopGuardResult {
        guard message.isFromBot, (policy.allowBots ?? .disabled).admitsBots else {
            return .allowed
        }
        let settings = ChannelBotLoopGuardSettings.resolve([
            policy.botLoopProtection,
            policy.groupConfig(for: message.peerID)?.botLoopProtection,
        ])
        return self.recordAndCheck(
            scopeID: "\(message.channel.rawValue):\(message.resolvedAccountID)",
            conversationID: message.threadID.map { "\(message.peerID):\($0)" } ?? message.peerID,
            senderID: message.senderID ?? "",
            receiverID: message.recipientID ?? "self",
            eventID: message.messageID,
            settings: settings
        )
    }

    /// Clears all tracked state.
    public func reset() {
        self.tracked.removeAll()
        self.nextPruneAtMs = 0
    }

    /// Number of tracked pairs (diagnostics).
    public var trackedPairCount: Int {
        self.tracked.count
    }

    private func pruneInactive(nowMs: Int64) {
        guard self.pruneIntervalMs > 0, nowMs >= self.nextPruneAtMs else { return }
        self.nextPruneAtMs = nowMs + self.pruneIntervalMs
        for (key, var entry) in self.tracked {
            entry.recent.removeAll { $0.timestampMs <= nowMs - entry.windowMs }
            if entry.recent.isEmpty, entry.cooldownUntilMs <= nowMs {
                self.tracked.removeValue(forKey: key)
            } else {
                self.tracked[key] = entry
            }
        }
    }
}

// MARK: - Ack reactions

/// Acknowledgement reaction gate (upstream `shouldAckReaction`).
public enum ChannelAckReactions {
    /// Default acknowledgement emoji.
    public static let defaultEmoji = "👀"

    /// Whether an inbound message should receive an acknowledgement reaction.
    ///
    /// Scope defaults to `group-mentions`; `off`/`none` never ack; room events only ack under `all`;
    /// `direct` acks direct messages; `group-all` acks every group message; `group-mentions` acks
    /// mentionable groups when mentions are detectable and the bot was (or is treated as) mentioned.
    /// - Parameters:
    ///   - scope: Configured scope.
    ///   - eventKind: Inbound event kind.
    ///   - isDirect: Whether the message is a DM.
    ///   - isGroup: Whether the message is in a group.
    ///   - isMentionableGroup: Whether the group supports mentions.
    ///   - canDetectMention: Whether the adapter can detect mentions.
    ///   - wasMentioned: Whether the bot was mentioned (including implicit mentions).
    ///   - shouldBypassMention: Whether an earlier gate established the conversation is active.
    /// - Returns: `true` when a reaction should be sent.
    public static func shouldAckReaction(
        scope: ChannelAckReactionScope?,
        eventKind: InboundEventKind = .userRequest,
        isDirect: Bool,
        isGroup: Bool,
        isMentionableGroup: Bool,
        canDetectMention: Bool,
        wasMentioned: Bool,
        shouldBypassMention: Bool = false
    ) -> Bool {
        let scope = scope ?? .groupMentions
        switch scope {
        case .off, .none:
            return false
        case .all:
            return true
        default:
            break
        }
        if eventKind == .roomEvent {
            return false
        }
        switch scope {
        case .direct:
            return isDirect
        case .groupAll:
            return isGroup
        case .groupMentions:
            guard isMentionableGroup, canDetectMention else { return false }
            return wasMentioned || shouldBypassMention
        case .all, .off, .none:
            return false
        }
    }
}

/// Adapter capability: add and remove emoji reactions on platform messages.
public protocol ReactingChannelAdapter: ChannelAdapter {
    /// Adds a reaction.
    /// - Parameters:
    ///   - peerID: Conversation id.
    ///   - messageID: Platform message id.
    ///   - emoji: Unicode emoji.
    func addReaction(peerID: String, messageID: String, emoji: String) async throws
    /// Removes a reaction added by this bot.
    /// - Parameters:
    ///   - peerID: Conversation id.
    ///   - messageID: Platform message id.
    ///   - emoji: Unicode emoji.
    func removeReaction(peerID: String, messageID: String, emoji: String) async throws
}

// MARK: - Typing

/// Typing indicator lifecycle settings (upstream `createTypingCallbacks`).
public struct ChannelTypingSettings: Sendable, Equatable {
    /// Keepalive interval in milliseconds.
    public var keepaliveIntervalMs: Int
    /// Maximum typing duration before auto-stop (safety TTL).
    public var maxDurationMs: Int
    /// Consecutive start failures after which keepalive stops.
    public var maxConsecutiveFailures: Int

    /// Creates typing settings.
    /// - Parameters:
    ///   - keepaliveIntervalMs: Keepalive interval.
    ///   - maxDurationMs: Safety TTL (default 60000).
    ///   - maxConsecutiveFailures: Failure budget (default 2).
    public init(keepaliveIntervalMs: Int = 3_000, maxDurationMs: Int = 60_000, maxConsecutiveFailures: Int = 2) {
        self.keepaliveIntervalMs = max(1, keepaliveIntervalMs)
        self.maxDurationMs = max(1, maxDurationMs)
        self.maxConsecutiveFailures = max(1, maxConsecutiveFailures)
    }

    /// Default keepalive interval: Telegram 4000 ms (chat actions last ~5 s), others 3000 ms.
    /// - Parameter channel: Channel id.
    /// - Returns: Interval in milliseconds.
    public static func defaultKeepaliveIntervalMs(for channel: ChannelID) -> Int {
        channel == .telegram ? 4_000 : 3_000
    }
}
