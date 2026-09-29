import Foundation
import OpenClawCore
import OpenClawProtocol

/// Sender authentication strength (upstream `IdentifierAuthentication`), ordered weakest first.
public enum IMAPSenderAuthStrength: String, Codable, Sendable, Equatable, CaseIterable, Comparable {
    /// Mutable identity (display names).
    case mutable
    /// Unverified (no or untrusted authentication evidence).
    case unverified
    /// Asserted by a trusted receiving server (`Authentication-Results` dmarc=pass from a trusted authserv-id).
    case asserted
    /// Locally verified DKIM/DMARC (not available natively; see ``IMAPSenderGate``).
    case verified

    private var rank: Int {
        switch self {
        case .mutable: 0
        case .unverified: 1
        case .asserted: 2
        case .verified: 3
        }
    }

    /// Orders by strength.
    /// - Parameters:
    ///   - lhs: Left value.
    ///   - rhs: Right value.
    /// - Returns: Whether `lhs` is weaker.
    public static func < (lhs: IMAPSenderAuthStrength, rhs: IMAPSenderAuthStrength) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// Mailbox watch mode.
public enum IMAPWatchMode: String, Codable, Sendable, Equatable, CaseIterable {
    /// IDLE when the server supports it, otherwise polling.
    case auto
    /// IDLE (falls back to polling without the capability).
    case idle
    /// Polling only.
    case interval
}

/// One IMAP account (upstream `plugins.entries.imap.config.accounts.<id>`).
public struct IMAPAccountConfig: Sendable, Equatable {
    /// Recipient-token rule: mail to `local+<token>@…` from one of `senders` is accepted.
    public struct AddressToken: Sendable, Equatable {
        /// Plus-address token.
        public var token: String
        /// Sender entries (`user@domain` or `@domain`).
        public var senders: [String]

        /// Creates a token rule.
        /// - Parameters:
        ///   - token: Token.
        ///   - senders: Senders.
        public init(token: String, senders: [String]) {
            self.token = token
            self.senders = senders
        }
    }

    /// IMAP host.
    public var host: String
    /// Port (default 993).
    public var port: Int
    /// Implicit TLS (default `true`).
    public var secure: Bool
    /// Login user.
    public var user: String
    /// Login password (resolve SecretRefs first).
    public var password: String
    /// Mailbox (default `INBOX`).
    public var mailbox: String
    /// Watch mode.
    public var watchMode: IMAPWatchMode
    /// Poll/reconcile interval in seconds (minimum 15, default 60).
    public var pollSeconds: Int
    /// Allowed senders (`user@domain` with case-sensitive local part, or `@domain`); empty disables the account.
    public var allowedSenders: [String]
    /// Minimum sender authentication strength (default `verified`).
    public var senderAuthMin: IMAPSenderAuthStrength
    /// Receiving servers whose `Authentication-Results` are trusted.
    public var trustedAuthservIds: [String]
    /// Whether a trusted authserv dmarc=pass counts as `asserted`.
    public var acceptTrustedAuthservId: Bool
    /// Recipient-token rules.
    public var addressTokens: [AddressToken]
    /// Agent that handles the mail.
    public var agentId: String
    /// Deliver the agent reply to a channel (default `false`).
    public var deliver: Bool
    /// Include the body in the prompt (default `true`).
    public var includeBody: Bool
    /// Prompt byte cap (256–1,048,576, default 20,000).
    public var maxBytes: Int
    /// Model override.
    public var model: String?
    /// Thinking level override.
    public var thinking: String?
    /// Turn timeout in seconds.
    public var timeoutSeconds: Int?

    /// Creates account settings.
    /// - Parameters:
    ///   - host: Host.
    ///   - user: User.
    ///   - password: Password.
    ///   - agentId: Agent id.
    ///   - allowedSenders: Allowed senders.
    public init(host: String, user: String, password: String, agentId: String, allowedSenders: [String] = []) {
        self.host = host
        self.port = 993
        self.secure = true
        self.user = user
        self.password = password
        self.mailbox = "INBOX"
        self.watchMode = .auto
        self.pollSeconds = 60
        self.allowedSenders = allowedSenders
        self.senderAuthMin = .verified
        self.trustedAuthservIds = []
        self.acceptTrustedAuthservId = false
        self.addressTokens = []
        self.agentId = agentId
        self.deliver = false
        self.includeBody = true
        self.maxBytes = 20_000
        self.model = nil
        self.thinking = nil
        self.timeoutSeconds = nil
    }
}

/// IMAP watcher configuration (upstream `plugins.entries.imap.config`).
public struct IMAPWatcherConfig: Sendable, Equatable {
    /// Account id pattern (session-safe).
    public static let accountIDPattern = "^[A-Za-z0-9][A-Za-z0-9_-]*$"
    /// Thinking levels accepted upstream.
    public static let thinkingLevels: Set<String> = ["off", "minimal", "low", "medium", "high", "xhigh", "adaptive", "max", "ultra"]

    /// Accounts keyed by id.
    public var accounts: [String: IMAPAccountConfig]
    /// Accounts skipped because their password is an unresolved SecretRef.
    public var unavailableAccounts: [String]

    /// Creates a configuration.
    /// - Parameter accounts: Accounts.
    public init(accounts: [String: IMAPAccountConfig] = [:]) {
        self.accounts = accounts
        self.unavailableAccounts = []
    }

    /// Resolves the plugin config object like upstream `resolveImapConfig`.
    /// - Parameter value: `plugins.entries.imap.config` value.
    /// - Returns: Resolved configuration.
    public static func resolve(_ value: AnyCodable?) throws -> IMAPWatcherConfig {
        var config = IMAPWatcherConfig()
        let accounts = value?.dictionaryValue?["accounts"]?.dictionaryValue ?? [:]
        for (accountID, input) in accounts.sorted(by: { $0.key < $1.key }) {
            guard accountID.range(of: self.accountIDPattern, options: .regularExpression) != nil else {
                throw OpenClawCoreError.invalidConfiguration("IMAP account id \"\(accountID)\" is not session-safe")
            }
            guard let account = input.dictionaryValue else {
                throw OpenClawCoreError.invalidConfiguration("IMAP account \(accountID) must be an object")
            }
            guard let host = account["host"]?.stringValue, let user = account["user"]?.stringValue,
                  let agentId = account["agentId"]?.stringValue
            else {
                throw OpenClawCoreError.invalidConfiguration("IMAP account \(accountID) requires host, user, resolved password, and agentId")
            }
            guard let password = account["password"]?.stringValue else {
                if account["password"]?.dictionaryValue != nil {
                    config.unavailableAccounts.append(accountID)
                    continue
                }
                throw OpenClawCoreError.invalidConfiguration("IMAP account \(accountID) requires a resolved password")
            }
            var resolved = IMAPAccountConfig(host: host, user: user, password: password, agentId: agentId)
            resolved.port = account["port"]?.intValue ?? 993
            resolved.secure = account["secure"]?.boolValue != false
            resolved.mailbox = account["mailbox"]?.stringValue ?? "INBOX"
            let watch = account["watch"]?.dictionaryValue
            resolved.watchMode = watch?["mode"]?.stringValue.flatMap(IMAPWatchMode.init(rawValue:)) ?? .auto
            resolved.pollSeconds = max(15, watch?["pollSeconds"]?.intValue ?? 60)
            resolved.allowedSenders = Self.stringList(account["allowedSenders"])
            let senderAuth = account["senderAuth"]?.dictionaryValue
            resolved.senderAuthMin = senderAuth?["min"]?.stringValue.flatMap(IMAPSenderAuthStrength.init(rawValue:)) ?? .verified
            resolved.trustedAuthservIds = Self.stringList(senderAuth?["trustedAuthservIds"])
            resolved.acceptTrustedAuthservId = senderAuth?["acceptTrustedAuthservId"]?.boolValue == true
            resolved.addressTokens = (account["addressTokens"]?.arrayValue ?? []).compactMap { entry in
                guard let object = entry.dictionaryValue, let token = object["token"]?.stringValue else { return nil }
                return IMAPAccountConfig.AddressToken(token: token, senders: Self.stringList(object["senders"]))
            }
            resolved.deliver = account["deliver"]?.boolValue == true
            resolved.includeBody = account["includeBody"]?.boolValue != false
            resolved.maxBytes = min(max(account["maxBytes"]?.intValue ?? 20_000, 256), 1_048_576)
            resolved.model = account["model"]?.stringValue
            resolved.thinking = account["thinking"]?.stringValue.flatMap { self.thinkingLevels.contains($0) ? $0 : nil }
            resolved.timeoutSeconds = account["timeoutSeconds"]?.intValue
            config.accounts[accountID] = resolved
        }
        return config
    }

    private static func stringList(_ value: AnyCodable?) -> [String] {
        (value?.arrayValue ?? []).compactMap(\.stringValue)
    }
}
