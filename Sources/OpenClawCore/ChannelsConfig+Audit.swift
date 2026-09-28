import Foundation
import OpenClawProtocol

/// Upstream secret-bearing keys of plugin-only channel sections (see upstream
/// `docs/reference/secretref-user-supplied-credentials-matrix.json`).
public enum ChannelSecretPaths {
    /// Secret keys per raw channel id. `peers.*` entries match every peer object.
    public static let rawSectionSecretKeys: [String: [String]] = [
        "sms": ["authToken"],
        "buzz": ["privateKey", "authTag"],
        "clickclack": ["token"],
        "a2a": ["peers.*.token", "peers.*.outboundToken"],
        "matrix": ["accessToken", "password"],
        "mattermost": ["botToken"],
        "nostr": ["privateKey"],
        "feishu": ["appSecret", "encryptKey", "verificationToken"],
        "irc": ["password"],
        "nextcloud-talk": ["apiPassword", "botSecret"],
        "zalo": ["botToken", "webhookSecret"],
        "qqbot": ["clientSecret"],
        "line": ["channelAccessToken", "channelSecret"],
        "synology-chat": ["token"],
        "twitch": ["accessToken"],
        "whatsapp": [],
    ]
}

public extension ChannelsConfig {
    /// Upstream-spelled config paths (for example `channels.sms.authToken`) whose value is a
    /// plaintext secret. Env templates (`${VAR}`) and SecretRef objects are not reported.
    ///
    /// Covers typed sections, their `accounts.*` overrides, and raw plugin sections.
    /// - Returns: Sorted paths.
    func plaintextSecretPaths() -> [String] {
        var paths: Set<String> = []
        func check(_ input: SecretInput?, _ path: String) {
            if case .string(let value) = input, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                paths.insert(path)
            }
        }
        check(self.discord.botTokenInput, "channels.discord.token")
        check(self.telegram.botTokenInput, "channels.telegram.botToken")
        check(self.telegram.webhookSecretInput, "channels.telegram.webhookSecret")
        check(self.whatsappCloud.accessTokenInput, "channels.whatsappCloud.accessToken")
        check(self.whatsappCloud.webhookVerifyTokenInput, "channels.whatsappCloud.webhookVerifyToken")
        check(self.slack.botTokenInput, "channels.slack.botToken")
        check(self.slack.appTokenInput, "channels.slack.appToken")
        check(self.slack.signingSecretInput, "channels.slack.signingSecret")
        check(self.slack.userTokenInput, "channels.slack.userToken")
        check(self.slack.relay?.authTokenInput, "channels.slack.relay.authToken")
        check(self.googleChat.bearerTokenInput, "channels.googlechat.bearerToken")
        check(self.googleChat.verificationTokenInput, "channels.googlechat.verificationToken")
        if let serviceAccount = self.googleChat.serviceAccount, Self.isPlaintextSecret(serviceAccount) {
            paths.insert("channels.googlechat.serviceAccount")
        }
        check(self.signal.authTokenInput, "channels.signal.authToken")
        check(self.bluebubbles.passwordInput, "channels.bluebubbles.password")
        check(self.msteams.botAppPasswordInput, "channels.msteams.appPassword")
        check(self.webchat.sharedSecretInput, "channels.webchat.sharedSecret")

        let typedAccountSecrets: [(String, [String: ChannelAccountOverride], [String])] = [
            ("discord", self.discord.accounts, ["token", "botToken"]),
            ("telegram", self.telegram.accounts, ["botToken", "webhookSecret"]),
            ("slack", self.slack.accounts, ["botToken", "appToken", "signingSecret", "userToken"]),
            ("googlechat", self.googleChat.accounts, ["serviceAccount", "bearerToken", "verificationToken"]),
            ("signal", self.signal.accounts, ["authToken"]),
            ("msteams", self.msteams.accounts, ["appPassword", "botAppPassword"]),
            ("bluebubbles", self.bluebubbles.accounts, ["password"]),
        ]
        for (channel, accounts, keys) in typedAccountSecrets {
            for (accountID, account) in accounts {
                for key in keys {
                    if let value = account.values[key], Self.isPlaintextSecret(value) {
                        paths.insert("channels.\(channel).accounts.\(accountID).\(key)")
                    }
                }
            }
        }

        for (channel, keys) in ChannelSecretPaths.rawSectionSecretKeys {
            guard let raw = self.rawSection(named: channel) else { continue }
            Self.collectRawSecrets(raw, keys: keys, prefix: "channels.\(channel)", into: &paths)
            for (accountID, account) in raw["accounts"]?.dictionaryValue ?? [:] {
                if let accountObject = account.dictionaryValue {
                    Self.collectRawSecrets(accountObject, keys: keys, prefix: "channels.\(channel).accounts.\(accountID)", into: &paths)
                }
            }
        }
        return paths.sorted()
    }

    /// Channel-owned security audit findings.
    ///
    /// Reports plaintext channel secrets (upstream path spelling), an enabled BlueBubbles section
    /// (removed upstream), and Teams non-public clouds without a matching service URL.
    /// - Returns: Findings ordered by id.
    func securityAuditFindings() -> [SecurityAuditFinding] {
        var findings: [SecurityAuditFinding] = []
        let plaintext = self.plaintextSecretPaths()
        if !plaintext.isEmpty {
            findings.append(
                SecurityAuditFinding(
                    id: "channels.secrets.plaintext",
                    severity: .warning,
                    summary: "Channel configuration includes plaintext secrets",
                    detail: "Found plaintext channel secrets at: \(plaintext.joined(separator: ", "))",
                    recommendation: "Use SecretRef objects ({source, provider, id}) or ${ENV} templates for channel credentials."
                )
            )
        }
        if self.bluebubbles.enabled {
            findings.append(
                SecurityAuditFinding(
                    id: "channels.bluebubbles.removed-upstream",
                    severity: .info,
                    summary: "BlueBubbles is removed upstream",
                    detail: "channels.bluebubbles is enabled, but OpenClaw removed BlueBubbles in 2026.5.12; the SDK adapter is deprecated.",
                    recommendation: "Migrate to channels.imessage (imsg) with ChannelsConfig.migrateBlueBubblesToIMessage(). "
                        + "See /channels/imessage-from-bluebubbles."
                )
            )
        }
        if self.msteams.enabled, self.msteams.cloud != .public,
           self.msteams.serviceURL == MicrosoftTeamsChannelConfig.defaultServiceURL
        {
            findings.append(
                SecurityAuditFinding(
                    id: "channels.msteams.cloud-service-url",
                    severity: .warning,
                    summary: "Teams sovereign cloud uses the public service URL",
                    detail: "channels.msteams.cloud is \(self.msteams.cloud.rawValue) but serviceUrl is the public default.",
                    recommendation: "Set channels.msteams.serviceUrl to the Bot Framework endpoint of your cloud."
                )
            )
        }
        return findings.sorted { $0.id < $1.id }
    }

    /// Upstream channel validation issues (upstream `ChannelsSchema` refinements).
    ///
    /// - `dmPolicy: open` requires `allowFrom` to contain `"*"`;
    /// - `dmPolicy: allowlist` requires a non-empty `allowFrom`;
    /// - two or more accounts need `defaultAccount` or an `accounts.default` entry;
    /// - `defaultAccount` must name a configured account;
    /// - channel-local `bindings.acp` blocks were removed upstream.
    /// - Returns: Issues in channel order.
    func validationIssues() -> [ConfigDecodeIssue] {
        var issues: [ConfigDecodeIssue] = []
        func checkPolicy(_ channel: String, _ policy: ChannelMessagingPolicyConfig) {
            if policy.dmPolicy == .open, !(policy.allowFrom ?? []).contains("*") {
                issues.append(
                    ConfigDecodeIssue(
                        path: "channels.\(channel).allowFrom",
                        message: "dmPolicy \"open\" requires allowFrom to contain \"*\".",
                        kind: .invalidValue
                    )
                )
            }
            if policy.dmPolicy == .allowlist, (policy.allowFrom ?? []).isEmpty {
                issues.append(
                    ConfigDecodeIssue(
                        path: "channels.\(channel).allowFrom",
                        message: "dmPolicy \"allowlist\" requires a non-empty allowFrom.",
                        kind: .invalidValue
                    )
                )
            }
        }
        func checkAccounts(_ channel: String, accounts: [String], defaultAccount: String?) {
            let lowered = Set(accounts.map { $0.lowercased() })
            if accounts.count >= 2, defaultAccount == nil, !lowered.contains("default") {
                issues.append(
                    ConfigDecodeIssue(
                        path: "channels.\(channel).defaultAccount",
                        message: "Multiple accounts are configured; set defaultAccount or add accounts.default.",
                        kind: .invalidValue
                    )
                )
            }
            if let defaultAccount, !lowered.contains(defaultAccount.lowercased()) {
                issues.append(
                    ConfigDecodeIssue(
                        path: "channels.\(channel).defaultAccount",
                        message: "defaultAccount \"\(defaultAccount)\" does not name a configured account.",
                        kind: .invalidValue
                    )
                )
            }
        }
        let typed: [(String, ChannelMessagingPolicyConfig, [String], String?)] = [
            ("discord", self.discord.policy, self.discord.accountIDs, self.discord.defaultAccount),
            ("telegram", self.telegram.policy, self.telegram.accountIDs, self.telegram.defaultAccount),
            ("slack", self.slack.policy, self.slack.accountIDs, self.slack.defaultAccount),
            ("googlechat", self.googleChat.policy, self.googleChat.accountIDs, self.googleChat.defaultAccount),
            ("signal", self.signal.policy, self.signal.accountIDs, self.signal.defaultAccount),
            ("imessage", self.imessage.policy, self.imessage.accountIDs, self.imessage.defaultAccount),
            ("msteams", self.msteams.policy, self.msteams.accountIDs, self.msteams.defaultAccount),
            ("whatsappCloud", self.whatsappCloud.policy, self.whatsappCloud.accountIDs, self.whatsappCloud.defaultAccount),
        ]
        for (channel, policy, accounts, defaultAccount) in typed {
            checkPolicy(channel, policy)
            checkAccounts(channel, accounts: accounts, defaultAccount: defaultAccount)
        }
        for channel in self.extensionChannels.keys.sorted() {
            guard let raw = self.extensionChannels[channel]?.dictionaryValue else { continue }
            if let policy = ChannelConfigJSON.decode(ChannelMessagingPolicyConfig.self, from: raw) {
                checkPolicy(channel, policy)
            }
            let accounts = (raw["accounts"]?.dictionaryValue?.keys).map(Array.init) ?? []
            checkAccounts(channel, accounts: accounts, defaultAccount: raw["defaultAccount"]?.stringValue)
            if Self.containsLegacyACPBinding(AnyCodable(AnySendableValue.object(raw))) {
                issues.append(
                    ConfigDecodeIssue(
                        path: "channels.\(channel).bindings.acp",
                        message: "Legacy channel-local ACP bindings were removed; use top-level bindings[] entries.",
                        kind: .retiredKey
                    )
                )
            }
        }
        return issues
    }

    private static func isPlaintextSecret(_ value: AnyCodable) -> Bool {
        guard let input = ChannelConfigJSON.secretInput(from: value), case .string(let string) = input else {
            return false
        }
        return !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func collectRawSecrets(
        _ object: [String: AnyCodable],
        keys: [String],
        prefix: String,
        into paths: inout Set<String>
    ) {
        for key in keys {
            let segments = key.split(separator: ".").map(String.init)
            if segments.count == 3, segments[1] == "*" {
                for (peerID, peer) in object[segments[0]]?.dictionaryValue ?? [:] {
                    if let value = peer.dictionaryValue?[segments[2]], self.isPlaintextSecret(value) {
                        paths.insert("\(prefix).\(segments[0]).\(peerID).\(segments[2])")
                    }
                }
            } else if let value = object[key], self.isPlaintextSecret(value) {
                paths.insert("\(prefix).\(key)")
            }
        }
    }

    private static func containsLegacyACPBinding(_ value: AnyCodable) -> Bool {
        if let object = value.dictionaryValue {
            if object["bindings"]?.dictionaryValue?["acp"]?.dictionaryValue != nil {
                return true
            }
            return object.values.contains { self.containsLegacyACPBinding($0) }
        }
        if let array = value.arrayValue {
            return array.contains { self.containsLegacyACPBinding($0) }
        }
        return false
    }
}
