import Foundation

/// A ChatGPT account known on this host.
///
/// The account keeps its issued client id after sign-out so the next sign-in re-authenticates the
/// same registration instead of registering a new client.
public struct SignInWithChatGPTAccount: Codable, Sendable, Equatable, Identifiable {
    /// Stable account identifier (`sub`).
    public var subject: String
    /// Account email, when shared.
    public var email: String?
    /// Display name, when shared.
    public var name: String?
    /// Issued client id of this account's registration.
    public var clientID: String
    /// Scopes granted by the latest sign-in or refresh.
    public var grantedScopes: [String]
    /// Whether tokens are stored for the account.
    public var isSignedIn: Bool
    /// Whether the "You're using your ChatGPT plan" welcome was shown.
    public var hasSeenPlanWelcome: Bool
    /// First sign-in time.
    public var createdAt: Date
    /// Latest sign-in time.
    public var lastSignedInAt: Date?

    /// Creates an account.
    /// - Parameters:
    ///   - subject: Account subject.
    ///   - email: Email.
    ///   - name: Display name.
    ///   - clientID: Issued client id.
    ///   - grantedScopes: Granted scopes.
    ///   - isSignedIn: Whether tokens are stored.
    ///   - hasSeenPlanWelcome: Whether the plan welcome was shown.
    ///   - createdAt: First sign-in time.
    ///   - lastSignedInAt: Latest sign-in time.
    public init(
        subject: String,
        email: String? = nil,
        name: String? = nil,
        clientID: String,
        grantedScopes: [String] = [],
        isSignedIn: Bool = false,
        hasSeenPlanWelcome: Bool = false,
        createdAt: Date = Date(),
        lastSignedInAt: Date? = nil
    ) {
        self.subject = subject
        self.email = email
        self.name = name
        self.clientID = clientID
        self.grantedScopes = grantedScopes
        self.isSignedIn = isSignedIn
        self.hasSeenPlanWelcome = hasSeenPlanWelcome
        self.createdAt = createdAt
        self.lastSignedInAt = lastSignedInAt
    }

    /// Identity for SwiftUI lists (the subject).
    public var id: String {
        self.subject
    }

    /// Whether the latest grant allows ChatGPT plan inference.
    public var usesChatGPTPlan: Bool {
        self.grantedScopes.contains(SignInWithChatGPTConfiguration.planUsageScope)
    }

    /// Label for account pickers: the email, the name, or a shortened subject.
    public var displayLabel: String {
        if let email, !email.isEmpty { return email }
        if let name, !name.isEmpty { return name }
        return "ChatGPT account \(self.subject.suffix(6))"
    }
}

/// Persists SIWC host identity, accounts and credential records in a ``CredentialStore``.
///
/// Keys (under ``keyPrefix``): `host-id`, `accounts` (account index), `active` (active subject) and
/// `credential.<hash>` (one credential record per account). Use a Keychain store on Apple platforms
/// (``CredentialStoreFactory/makeDefault(fallbackFileURL:keychainService:keychainAccessGroup:)``); the
/// file store writes `0600` files.
public actor SignInWithChatGPTAccountStore {
    /// Default key prefix.
    public static let defaultKeyPrefix = "openclaw.siwc"

    /// Backing store.
    public let credentialStore: any CredentialStore
    /// Key prefix.
    public let keyPrefix: String
    private var cachedHostIdentifier: SignInWithChatGPTHostIdentifier?

    /// Creates an account store.
    /// - Parameters:
    ///   - credentialStore: Backing secret store.
    ///   - keyPrefix: Key prefix (use distinct prefixes for separate app profiles).
    public init(credentialStore: any CredentialStore, keyPrefix: String = SignInWithChatGPTAccountStore.defaultKeyPrefix) {
        self.credentialStore = credentialStore
        self.keyPrefix = keyPrefix
    }

    /// Returns the persisted host identifier, creating and saving a random `urn:uuid:` one first.
    /// - Returns: The host identifier.
    public func hostIdentifier() async throws -> SignInWithChatGPTHostIdentifier {
        if let cachedHostIdentifier {
            return cachedHostIdentifier
        }
        if let stored = try await self.credentialStore.loadSecret(for: self.key("host-id")),
           let identifier = SignInWithChatGPTHostIdentifier(rawValue: stored) {
            self.cachedHostIdentifier = identifier
            return identifier
        }
        let identifier = SignInWithChatGPTHostIdentifier.randomUUID()
        try await self.setHostIdentifier(identifier)
        return identifier
    }

    /// Replaces the host identifier (for example with ``SignInWithChatGPTHostIdentifier/jwkThumbprint(ed25519PublicKey:)``
    /// of a device key). Do this before the first sign-in; changing it later splits usage attribution.
    /// - Parameter identifier: Host identifier.
    public func setHostIdentifier(_ identifier: SignInWithChatGPTHostIdentifier) async throws {
        try await self.credentialStore.saveSecret(identifier.rawValue, for: self.key("host-id"))
        self.cachedHostIdentifier = identifier
    }

    /// Known accounts, most recently signed in first.
    /// - Returns: Accounts.
    public func accounts() async throws -> [SignInWithChatGPTAccount] {
        guard let raw = try await self.credentialStore.loadSecret(for: self.key("accounts")), let data = raw.data(using: .utf8) else {
            return []
        }
        let accounts = (try? Self.decoder.decode([SignInWithChatGPTAccount].self, from: data)) ?? []
        return accounts.sorted { ($0.lastSignedInAt ?? $0.createdAt) > ($1.lastSignedInAt ?? $1.createdAt) }
    }

    /// Returns one account.
    /// - Parameter subject: Account subject.
    /// - Returns: The account, when known.
    public func account(subject: String) async throws -> SignInWithChatGPTAccount? {
        try await self.accounts().first { $0.subject == subject }
    }

    /// Inserts or replaces an account.
    /// - Parameter account: Account.
    public func save(_ account: SignInWithChatGPTAccount) async throws {
        var accounts = try await self.accounts()
        accounts.removeAll { $0.subject == account.subject }
        accounts.append(account)
        try await self.persist(accounts)
    }

    /// Forgets an account and its credential.
    /// - Parameter subject: Account subject.
    public func remove(subject: String) async throws {
        var accounts = try await self.accounts()
        accounts.removeAll { $0.subject == subject }
        try await self.persist(accounts)
        try await self.deleteCredential(subject: subject)
        if try await self.activeSubject() == subject {
            try await self.credentialStore.deleteSecret(for: self.key("active"))
        }
    }

    /// Subject of the active account.
    /// - Returns: Subject, when set.
    public func activeSubject() async throws -> String? {
        try await self.credentialStore.loadSecret(for: self.key("active"))
    }

    /// Sets or clears the active account.
    /// - Parameter subject: Account subject, or `nil` to clear.
    public func setActiveSubject(_ subject: String?) async throws {
        if let subject {
            try await self.credentialStore.saveSecret(subject, for: self.key("active"))
        } else {
            try await self.credentialStore.deleteSecret(for: self.key("active"))
        }
    }

    /// Loads an account's credential record.
    /// - Parameter subject: Account subject.
    /// - Returns: The credential, when stored.
    public func credential(subject: String) async throws -> SignInWithChatGPTCredential? {
        guard let raw = try await self.credentialStore.loadSecret(for: self.credentialKey(subject)), let data = raw.data(using: .utf8) else {
            return nil
        }
        return try? SignInWithChatGPTCredential.decodeRecord(data)
    }

    /// Saves an account's credential record.
    /// - Parameter credential: Credential.
    public func saveCredential(_ credential: SignInWithChatGPTCredential) async throws {
        let data = try Self.encoder.encode(credential)
        try await self.credentialStore.saveSecret(String(decoding: data, as: UTF8.self), for: self.credentialKey(credential.subject))
    }

    /// Deletes an account's credential record.
    /// - Parameter subject: Account subject.
    public func deleteCredential(subject: String) async throws {
        try await self.credentialStore.deleteSecret(for: self.credentialKey(subject))
    }

    private func persist(_ accounts: [SignInWithChatGPTAccount]) async throws {
        let data = try Self.encoder.encode(accounts)
        try await self.credentialStore.saveSecret(String(decoding: data, as: UTF8.self), for: self.key("accounts"))
    }

    private func key(_ suffix: String) -> String {
        "\(self.keyPrefix).\(suffix)"
    }

    private func credentialKey(_ subject: String) -> String {
        self.key("credential.\(OpenClawCrypto.sha256Hex(Data(subject.utf8)).prefix(32))")
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
