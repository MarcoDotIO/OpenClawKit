import Foundation
import Testing
@testable import OpenClawChannels
import OpenClawCore

@Suite("Channel ingress access policy")
struct ChannelAccessPolicyTests {
    private let evaluator = ChannelAccessPolicyEvaluator()

    private func dm(_ sender: String? = "42", channel: ChannelID = .telegram, eventKind: InboundEventKind = .userRequest) -> InboundMessage {
        InboundMessage(channel: channel, peerID: sender ?? "peer", text: "hello", senderID: sender, chatType: .direct, eventKind: eventKind)
    }

    private func group(_ sender: String? = "42", text: String = "hi", mentioned: Bool? = true, peer: String = "-100") -> InboundMessage {
        InboundMessage(channel: .telegram, peerID: peer, text: text, senderID: sender, chatType: .group, wasMentioned: mentioned)
    }

    private func evaluate(
        _ message: InboundMessage,
        _ policy: ChannelMessagingPolicyConfig,
        store: ChannelPairingStore? = nil
    ) async -> ChannelAccessEvaluation {
        await self.evaluator.evaluateDetailed(message, config: policy, store: store)
    }

    // MARK: DM matrix

    @Test(arguments: [
        // (dmPolicy, allowFrom, expected decision kind, expected reason)
        (ChannelDMPolicy.disabled, ["*"] as [String]?, "block", ChannelAccessReasonCode.dmPolicyDisabled),
        (.open, ["*"], "allow", .dmPolicyOpen),
        (.open, nil, "allow", .dmPolicyOpen),
        (.open, ["42"], "allow", .dmPolicyAllowlisted),
        (.open, ["7"], "block", .dmPolicyNotAllowlisted),
        (.open, [], "block", .dmPolicyNotAllowlisted),
        (.allowlist, ["42"], "allow", .dmPolicyAllowlisted),
        (.allowlist, ["*"], "allow", .dmPolicyAllowlisted),
        (.allowlist, [], "block", .dmPolicyNotAllowlisted),
        (.allowlist, nil, "block", .dmPolicyNotAllowlisted),
        (.pairing, ["42"], "allow", .dmPolicyAllowlisted),
        (.pairing, ["telegram:42"], "allow", .dmPolicyAllowlisted),
        (.pairing, nil, "pairing", .dmPolicyPairingRequired),
    ])
    func directMessageMatrix(
        policy: ChannelDMPolicy,
        allowFrom: [String]?,
        expected: String,
        reason: ChannelAccessReasonCode
    ) async {
        let store = ChannelPairingStore()
        let result = await self.evaluate(self.dm(), ChannelMessagingPolicyConfig(dmPolicy: policy, allowFrom: allowFrom), store: store)
        #expect(result.reasonCode == reason)
        switch (expected, result.decision) {
        case ("allow", .allow), ("block", .block), ("pairing", .pairingRequired):
            break
        default:
            Issue.record("unexpected decision \(result.decision) for \(policy) \(String(describing: allowFrom))")
        }
    }

    @Test
    func pairingIsTheDefaultDMPolicy() async {
        let result = await self.evaluate(self.dm(), ChannelMessagingPolicyConfig(), store: ChannelPairingStore())
        guard case .pairingRequired(let code, let created) = result.decision else {
            Issue.record("expected pairing, got \(result.decision)")
            return
        }
        #expect(code.count == 8)
        #expect(created)
    }

    @Test
    func pairingStoreMatchesOnlyCountUnderPairingPolicy() async throws {
        let store = ChannelPairingStore()
        try await store.addApprovedSender(channel: .telegram, accountID: nil, senderID: "42")
        let pairing = await self.evaluate(self.dm(), ChannelMessagingPolicyConfig(dmPolicy: .pairing), store: store)
        #expect(pairing.decision == .allow)
        #expect(pairing.reasonCode == .dmPolicyAllowlisted)
        let allowlist = await self.evaluate(self.dm(), ChannelMessagingPolicyConfig(dmPolicy: .allowlist, allowFrom: ["7"]), store: store)
        #expect(allowlist.decision == .block(reason: "dm_policy_not_allowlisted"))
    }

    @Test
    func pairingWithoutSenderOrForRoomEventsIsNotAllowed() async {
        let store = ChannelPairingStore()
        let noSender = await self.evaluate(self.dm(nil), ChannelMessagingPolicyConfig(), store: store)
        #expect(noSender.reasonCode == .eventPairingNotAllowed)
        let roomEvent = await self.evaluate(self.dm(eventKind: .roomEvent), ChannelMessagingPolicyConfig(), store: store)
        #expect(roomEvent.reasonCode == .eventPairingNotAllowed)
        let noStore = await self.evaluate(self.dm(), ChannelMessagingPolicyConfig(), store: nil)
        #expect(noStore.reasonCode == .eventPairingNotAllowed)
    }

    @Test
    func pairingStopsIssuingCodesAtTheAccountCap() async {
        let store = ChannelPairingStore()
        for sender in ["1", "2", "3"] {
            let result = await self.evaluate(self.dm(sender), ChannelMessagingPolicyConfig(), store: store)
            guard case .pairingRequired = result.decision else {
                Issue.record("expected pairing for \(sender)")
                return
            }
        }
        let fourth = await self.evaluate(self.dm("4"), ChannelMessagingPolicyConfig(), store: store)
        #expect(fourth.decision == .block(reason: "dm_policy_pairing_required"))
        let repeatSender = await self.evaluate(self.dm("1"), ChannelMessagingPolicyConfig(), store: store)
        guard case .pairingRequired(_, let created) = repeatSender.decision else {
            Issue.record("expected pairing for a repeat sender")
            return
        }
        #expect(created == false)
    }

    // MARK: Groups

    @Test
    func groupAllowFromFallsBackToAllowFromOnlyWhenUnset() async {
        let fallback = await self.evaluate(self.group(), ChannelMessagingPolicyConfig(allowFrom: ["42"]))
        #expect(fallback.decision == .allow)
        #expect(fallback.reasonCode == .groupPolicyAllowed)
        let explicitEmpty = await self.evaluate(self.group(), ChannelMessagingPolicyConfig(allowFrom: ["42"], groupAllowFrom: []))
        #expect(explicitEmpty.reasonCode == .groupPolicyEmptyAllowlist)
        let unset = await self.evaluate(self.group(), ChannelMessagingPolicyConfig())
        #expect(unset.reasonCode == .groupPolicyEmptyAllowlist)
        let notListed = await self.evaluate(self.group(), ChannelMessagingPolicyConfig(groupAllowFrom: ["7"]))
        #expect(notListed.reasonCode == .groupPolicyNotAllowlisted)
    }

    @Test
    func groupPolicyOpenAndDisabled() async {
        let open = await self.evaluate(self.group(), ChannelMessagingPolicyConfig(groupPolicy: .open))
        #expect(open.decision == .allow)
        #expect(open.reasonCode == .groupPolicyOpen)
        let disabled = await self.evaluate(self.group(), ChannelMessagingPolicyConfig(groupPolicy: .disabled))
        #expect(disabled.reasonCode == .groupPolicyDisabled)
        var routed = ChannelMessagingPolicyConfig(groupPolicy: .open)
        routed.groups = ["-100": ChannelGroupConfig(enabled: false)]
        let blocked = await self.evaluate(self.group(), routed)
        #expect(blocked.reasonCode == .routeBlocked)
    }

    @Test
    func mentionGatingDefaultsOnAndHonorsOverridesAndImplicitMentions() async {
        let policy = ChannelMessagingPolicyConfig(groupPolicy: .open)
        let unmentioned = await self.evaluate(self.group(mentioned: false), policy)
        #expect(unmentioned.decision == .mentionRequired)
        let undetectable = await self.evaluate(self.group(mentioned: nil), policy)
        #expect(undetectable.decision == .allow)

        var override = policy
        override.groups = ["*": ChannelGroupConfig(requireMention: false)]
        let wildcard = await self.evaluate(self.group(mentioned: false), override)
        #expect(wildcard.decision == .allow)

        var reply = self.group(mentioned: false)
        reply.implicitMentionKinds = [.replyToBot]
        let implicit = await self.evaluate(reply, policy)
        #expect(implicit.decision == .allow)
        var disabledImplicit = policy
        disabledImplicit.implicitMentions = ChannelImplicitMentionsConfig(replyToBot: false)
        let blockedImplicit = await self.evaluate(reply, disabledImplicit)
        #expect(blockedImplicit.decision == .mentionRequired)
    }

    @Test
    func controlCommandsInGroupsRequireAnAllowlistedSender() async {
        let open = ChannelMessagingPolicyConfig(groupPolicy: .open)
        let stranger = await self.evaluate(self.group(text: "/status", mentioned: false), open)
        #expect(stranger.reasonCode == .controlCommandUnauthorized)
        let allowlisted = await self.evaluate(
            self.group(text: "/status@openclaw_bot", mentioned: false),
            ChannelMessagingPolicyConfig(groupPolicy: .open, groupAllowFrom: ["42"])
        )
        #expect(allowlisted.decision == .allow)
        #expect(allowlisted.commandAuthorized)
    }

    @Test
    func skillCommandsInGroupsNeedAnAuthorizedSender() async {
        let open = ChannelMessagingPolicyConfig(groupPolicy: .open)
        let skills: Set<String> = ["/skill", "/deploy-now"]
        let stranger = await self.evaluator.evaluateDetailed(
            self.group(text: "/skill deploy --force", mentioned: false),
            config: open,
            store: nil,
            additionalCommands: skills
        )
        #expect(stranger.reasonCode == .controlCommandUnauthorized)
        let suffixed = await self.evaluator.evaluateDetailed(
            self.group(text: "/Deploy_Now@openclaw_bot target", mentioned: false),
            config: open,
            store: nil,
            additionalCommands: skills
        )
        #expect(suffixed.reasonCode == .controlCommandUnauthorized)
        // Plain text from the same sender is admitted but not authorized to run commands.
        let chatter = await self.evaluate(self.group(text: "what does deploy do?", mentioned: true), open)
        #expect(chatter.decision == .allow)
        #expect(chatter.commandAuthorized == false)

        let allowlisted = ChannelMessagingPolicyConfig(groupPolicy: .open, groupAllowFrom: ["42"])
        let command = await self.evaluator.evaluateDetailed(
            self.group(text: "/deploy-now", mentioned: false),
            config: allowlisted,
            store: nil,
            additionalCommands: skills
        )
        #expect(command.decision == .allow)
        #expect(command.commandAuthorized)
        let plain = await self.evaluate(self.group(text: "hello", mentioned: true), allowlisted)
        #expect(plain.commandAuthorized)
        #expect(ChannelAccessPolicyEvaluator.isControlCommand("/skill x", additionalCommands: skills))
        #expect(ChannelAccessPolicyEvaluator.isControlCommand("/unknown", additionalCommands: skills) == false)
        #expect(ChannelAccessPolicyEvaluator.isControlCommand("skill x", additionalCommands: skills) == false)
    }

    @Test
    func botSendersNeedAllowBots() async {
        var bot = self.dm()
        bot.isFromBot = true
        let open = ChannelMessagingPolicyConfig(dmPolicy: .open)
        #expect(await self.evaluate(bot, open).reasonCode == .botSenderNotAllowed)
        var mentions = open
        mentions.allowBots = .mentions
        #expect(await self.evaluate(bot, mentions).reasonCode == .botSenderNotMentioned)
        bot.wasMentioned = true
        #expect(await self.evaluate(bot, mentions).decision == .allow)
    }

    @Test
    func allowlistNormalizationHandlesPhonesHandlesAndPrefixes() {
        #expect(ChannelAccessPolicyEvaluator.normalizeAllowEntry("+1 (555) 123-4567", channel: .signal) == "+15551234567")
        #expect(ChannelAccessPolicyEvaluator.normalizeAllowEntry("sms:+1-555-123-4567", channel: .sms) == "+15551234567")
        #expect(ChannelAccessPolicyEvaluator.normalizeAllowEntry("Friend@iCloud.com", channel: .imessage) == "friend@icloud.com")
        #expect(ChannelAccessPolicyEvaluator.normalizeAllowEntry("@SomeUser", channel: .telegram) == "someuser")
        #expect(ChannelAccessPolicyEvaluator.normalizeAllowEntry("<@!12345>", channel: .discord) == "12345")
        #expect(ChannelAccessPolicyEvaluator.normalizeAllowEntry("teams:29:abc", channel: .msteams) == "29:abc")
        #expect(ChannelAccessPolicyEvaluator.normalizeAllowEntry("*", channel: .slack) == "*")
    }
}
