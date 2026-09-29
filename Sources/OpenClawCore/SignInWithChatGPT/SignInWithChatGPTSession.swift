import Foundation

/// Supplies ChatGPT plan access tokens to inference clients such as `ChatGPTPlanModelProvider`.
public protocol ChatGPTPlanAccessTokenProvider: Sendable {
    /// Returns a current access token that allows plan inference.
    /// - Parameter rejectedAccessToken: Token the server just rejected with `401`; the provider must
    ///   refresh instead of returning it again.
    /// - Returns: Access token for `Authorization: Bearer`.
    func chatGPTPlanAccessToken(rejectedAccessToken: String?) async throws -> String
}

/// Presents the SIWC authorization page.
///
/// ``SignInWithChatGPTSession/signIn(using:reauthenticating:consent:timeout:)`` receives the result on
/// its loopback listener, then calls ``dismiss()``.
public protocol SignInWithChatGPTBrowser: Sendable {
    /// Shows the authorization page.
    ///
    /// Return right away after handing the URL to an external browser, or suspend until an in-app
    /// browser closes. Throw (for example ``SignInWithChatGPTError/cancelled``) when the user closes
    /// the browser before finishing; the sign-in then stops.
    /// - Parameter authorizationURL: Authorization URL.
    func present(_ authorizationURL: URL) async throws

    /// Closes the browser UI after the callback arrived (no-op for external browsers).
    func dismiss() async
}

/// Opens the authorization page with a host-supplied closure (for example the system browser).
public struct SignInWithChatGPTExternalBrowser: SignInWithChatGPTBrowser {
    private let open: @Sendable (URL) async -> Bool

    /// Creates an external-browser presenter.
    /// - Parameter open: Opens a URL and returns whether it succeeded (for example
    ///   `{ await NSWorkspace.shared.open($0) }` on macOS).
    public init(open: @escaping @Sendable (URL) async -> Bool) {
        self.open = open
    }

    /// Opens the URL.
    /// - Parameter authorizationURL: Authorization URL.
    public func present(_ authorizationURL: URL) async throws {
        guard await self.open(authorizationURL) else {
            throw OpenClawCoreError.unavailable("Could not open the browser for Sign in with ChatGPT")
        }
    }

    /// No-op: an external browser tab cannot be closed by the app.
    public func dismiss() async {}
}

/// Result of a completed sign-in.
public struct SignInWithChatGPTSignInResult: Sendable, Equatable {
    /// Signed-in account.
    public let account: SignInWithChatGPTAccount
    /// Whether this sign-in created the account on this host.
    public let isNewAccount: Bool

    /// Creates a result.
    /// - Parameters:
    ///   - account: Signed-in account.
    ///   - isNewAccount: Whether the account is new on this host.
    public init(account: SignInWithChatGPTAccount, isNewAccount: Bool) {
        self.account = account
        self.isNewAccount = isNewAccount
    }

    /// Whether to show the one-time "You're using your ChatGPT plan" welcome: plan usage was granted
    /// and the welcome was never shown for this account. Call
    /// ``SignInWithChatGPTSession/markPlanWelcomeSeen(subject:)`` once it was shown.
    public var shouldShowPlanWelcome: Bool {
        self.account.usesChatGPTPlan && !self.account.hasSeenPlanWelcome
    }
}

/// Outcome of ``SignInWithChatGPTSession/signOut(subject:)``.
public enum SignInWithChatGPTSignOutResult: Sendable, Equatable {
    /// The refresh token was revoked and the tokens were cleared.
    case revoked
    /// No refresh token was stored; local tokens were cleared.
    case clearedLocally
    /// Revocation failed after retries; local tokens were cleared anyway.
    case revocationFailed(String)
}

/// Sign in with ChatGPT client: sign-in, token refresh, accounts and sign-out.
///
/// ```swift
/// let session = SignInWithChatGPTSession(
///     configuration: SignInWithChatGPTClientConfiguration(agentName: "MyAgent"),
///     credentialStore: KeychainCredentialStore()
/// )
/// let result = try await session.signIn(using: SignInWithChatGPTWebAuthenticationBrowser())
/// if result.shouldShowPlanWelcome { showWelcome() }
/// let provider = ChatGPTPlanModelProvider(tokenProvider: session, defaultModelID: modelSlug)
/// ```
///
/// - Registration vs re-authentication: the first sign-in of an account registers a client with
///   `dynamic_agent_client` and `agent_name_hint`; later sign-ins of a known account reuse its issued
///   client id with `id_token_hint` / `login_hint`. Client ids and tokens of different accounts are
///   never mixed.
/// - Refresh: access tokens refresh ``SignInWithChatGPTClientConfiguration/refreshLeeway`` before they
///   expire (never before `earliest_refresh_at`), one refresh per account at a time; rotated refresh
///   tokens replace the stored ones together with the access token. A rejected refresh token clears
///   the tokens and throws ``SignInWithChatGPTError/reauthenticationRequired(subject:reason:)``.
/// - Sign-out revokes the refresh token (with retries), clears tokens and keeps the account's client
///   id and the host identifier.
/// - Refreshes are serialized within this process. Share one session per credential store; other
///   processes using the same store must coordinate on their own.
public actor SignInWithChatGPTSession: ChatGPTPlanAccessTokenProvider {
    /// Client configuration.
    public let configuration: SignInWithChatGPTClientConfiguration
    /// Account and credential storage.
    public let store: SignInWithChatGPTAccountStore
    private let tokenClient: SignInWithChatGPTTokenClient
    private let validator: SignInWithChatGPTIDTokenValidator
    private let now: @Sendable () -> Date
    private var refreshTasks: [String: Task<SignInWithChatGPTCredential, Error>] = [:]

    /// Creates a session.
    /// - Parameters:
    ///   - configuration: Client configuration.
    ///   - credentialStore: Secret store (Keychain on Apple platforms).
    ///   - keyPrefix: Credential-store key prefix.
    ///   - transport: HTTP transport for token, revocation and JWKS requests.
    ///   - now: Clock.
    public init(
        configuration: SignInWithChatGPTClientConfiguration,
        credentialStore: any CredentialStore,
        keyPrefix: String = SignInWithChatGPTAccountStore.defaultKeyPrefix,
        transport: SignInWithChatGPTHTTPTransport = .urlSession(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(
            configuration: configuration,
            store: SignInWithChatGPTAccountStore(credentialStore: credentialStore, keyPrefix: keyPrefix),
            tokenClient: SignInWithChatGPTTokenClient(endpoints: configuration.endpoints, transport: transport),
            jwks: SignInWithChatGPTJWKSCache(url: configuration.endpoints.jwksURL, transport: transport),
            now: now
        )
    }

    init(
        configuration: SignInWithChatGPTClientConfiguration,
        store: SignInWithChatGPTAccountStore,
        tokenClient: SignInWithChatGPTTokenClient,
        jwks: SignInWithChatGPTJWKSCache,
        now: @escaping @Sendable () -> Date
    ) {
        self.configuration = configuration
        self.store = store
        self.tokenClient = tokenClient
        self.validator = SignInWithChatGPTIDTokenValidator(issuer: configuration.endpoints.issuer, jwks: jwks, clockSkew: configuration.clockSkew)
        self.now = now
    }

    // MARK: - Accounts

    /// Known accounts, most recent first.
    /// - Returns: Accounts.
    public func accounts() async throws -> [SignInWithChatGPTAccount] {
        try await self.store.accounts()
    }

    /// The active account: the one set with ``setActiveAccount(subject:)`` or the latest sign-in.
    /// - Returns: The account, or `nil` when none is signed in.
    public func activeAccount() async throws -> SignInWithChatGPTAccount? {
        let accounts = try await self.store.accounts()
        if let subject = try await self.store.activeSubject(), let account = accounts.first(where: { $0.subject == subject }) {
            return account
        }
        return accounts.first { $0.isSignedIn }
    }

    /// Selects the account used by ``accessToken(for:requirePlanUsage:)`` and ``chatGPTPlanAccessToken(rejectedAccessToken:)``.
    /// - Parameter subject: Account subject.
    public func setActiveAccount(subject: String) async throws {
        guard try await self.store.account(subject: subject) != nil else {
            throw SignInWithChatGPTError.unknownAccount(subject)
        }
        try await self.store.setActiveSubject(subject)
    }

    /// Records that the plan welcome was shown for an account.
    /// - Parameter subject: Account subject.
    public func markPlanWelcomeSeen(subject: String) async throws {
        guard var account = try await self.store.account(subject: subject) else {
            throw SignInWithChatGPTError.unknownAccount(subject)
        }
        account.hasSeenPlanWelcome = true
        try await self.store.save(account)
    }

    /// Persisted host identifier (created on first use).
    /// - Returns: The host identifier.
    public func hostIdentifier() async throws -> SignInWithChatGPTHostIdentifier {
        try await self.store.hostIdentifier()
    }

    // MARK: - Sign-in

    #if !os(tvOS) && !os(watchOS)
    /// Runs the complete browser sign-in: starts the loopback listener, opens the authorization page,
    /// waits for the callback and exchanges the code.
    /// - Parameters:
    ///   - browser: Browser presenter.
    ///   - subject: Known account to re-authenticate (uses its issued client id); `nil` signs in a new
    ///     or returning account (a returning account is matched by `sub` after the sign-in).
    ///   - consent: Re-consent parameter (use ``SignInWithChatGPTConsentPrompt/forceReconsent`` or
    ///     ``SignInWithChatGPTConsentPrompt/consent`` to re-enable plan usage).
    ///   - timeout: Seconds to wait for the callback (defaults to the configuration).
    /// - Returns: The sign-in result.
    public func signIn(
        using browser: any SignInWithChatGPTBrowser,
        reauthenticating subject: String? = nil,
        consent: SignInWithChatGPTConsentPrompt = .automatic,
        timeout: TimeInterval? = nil
    ) async throws -> SignInWithChatGPTSignInResult {
        try await self.signIn(using: browser, reauthenticating: subject, consent: consent, timeout: timeout, secrets: nil)
    }

    func signIn(
        using browser: any SignInWithChatGPTBrowser,
        reauthenticating subject: String?,
        consent: SignInWithChatGPTConsentPrompt,
        timeout: TimeInterval?,
        secrets: SignInWithChatGPTAuthorizationRequest.Secrets?
    ) async throws -> SignInWithChatGPTSignInResult {
        let listener = try SignInWithChatGPTLoopbackListener.start(
            port: self.configuration.callbackPort,
            allowsFallback: self.configuration.allowsCallbackPortFallback,
            page: .default(appName: self.configuration.agentName)
        )
        defer { listener.stop() }
        let pending = try await self.beginAuthorization(redirectURI: listener.redirectURI, reauthenticating: subject, consent: consent, secrets: secrets)
        listener.expect(state: pending.state)
        let callbackURL = try await Self.awaitCallback(
            listener: listener,
            browser: browser,
            authorizationURL: pending.authorizationURL,
            timeout: timeout ?? self.configuration.signInTimeout
        )
        return try await self.completeAuthorization(callbackURL: callbackURL, pending: pending)
    }

    private enum CallbackRace: Sendable {
        case callback(URL)
        case browserReturned
        case timedOut
    }

    private static func awaitCallback(
        listener: SignInWithChatGPTLoopbackListener,
        browser: any SignInWithChatGPTBrowser,
        authorizationURL: URL,
        timeout: TimeInterval
    ) async throws -> URL {
        try await withThrowingTaskGroup(of: CallbackRace.self) { group in
            group.addTask { .callback(try await listener.waitForCallback()) }
            group.addTask {
                try await browser.present(authorizationURL)
                return .browserReturned
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(1, timeout) * 1_000_000_000))
                return .timedOut
            }
            do {
                while let outcome = try await group.next() {
                    switch outcome {
                    case .callback(let url):
                        await browser.dismiss()
                        group.cancelAll()
                        return url
                    case .browserReturned:
                        continue
                    case .timedOut:
                        await browser.dismiss()
                        group.cancelAll()
                        throw SignInWithChatGPTError.timedOut
                    }
                }
            } catch {
                // The user may close the browser right after the redirect already reached us.
                if let url = listener.receivedCallbackURL {
                    return url
                }
                listener.stop()
                if !(error is SignInWithChatGPTError) {
                    await browser.dismiss()
                }
                throw error
            }
            throw SignInWithChatGPTError.cancelled
        }
    }
    #endif

    /// Starts an authorization for a loopback redirect URI you serve yourself.
    ///
    /// Use with ``completeAuthorization(callbackURL:pending:)``; ``signIn(using:reauthenticating:consent:timeout:)``
    /// does both.
    /// - Parameters:
    ///   - redirectURI: `http://127.0.0.1:<port>/auth/callback`.
    ///   - subject: Known account to re-authenticate.
    ///   - consent: Re-consent parameter.
    /// - Returns: The pending authorization (open its ``SignInWithChatGPTPendingAuthorization/authorizationURL``).
    public func beginAuthorization(
        redirectURI: URL,
        reauthenticating subject: String? = nil,
        consent: SignInWithChatGPTConsentPrompt = .automatic
    ) async throws -> SignInWithChatGPTPendingAuthorization {
        try await self.beginAuthorization(redirectURI: redirectURI, reauthenticating: subject, consent: consent, secrets: nil)
    }

    func beginAuthorization(
        redirectURI: URL,
        reauthenticating subject: String?,
        consent: SignInWithChatGPTConsentPrompt,
        secrets: SignInWithChatGPTAuthorizationRequest.Secrets?
    ) async throws -> SignInWithChatGPTPendingAuthorization {
        let hostIdentifier = try await self.store.hostIdentifier()
        var reauthentication: SignInWithChatGPTAuthorizationRequest.Reauthentication?
        if let subject {
            guard let account = try await self.store.account(subject: subject) else {
                throw SignInWithChatGPTError.unknownAccount(subject)
            }
            let credential = try await self.store.credential(subject: subject)
            reauthentication = .init(clientID: account.clientID, subject: subject, idTokenHint: credential?.idToken, loginHint: account.email)
        }
        return try SignInWithChatGPTAuthorizationRequest.make(
            endpoints: self.configuration.endpoints,
            redirectURI: redirectURI,
            hostIdentifier: hostIdentifier,
            scopes: self.configuration.scopes,
            agentName: self.configuration.agentName,
            reauthentication: reauthentication,
            consent: consent,
            now: self.now(),
            secrets: secrets
        )
    }

    /// Validates the callback, exchanges the code, validates the ID token and stores the account.
    /// - Parameters:
    ///   - callbackURL: Callback URL received on the redirect URI.
    ///   - pending: Pending authorization from ``beginAuthorization(redirectURI:reauthenticating:consent:)``.
    /// - Returns: The sign-in result.
    public func completeAuthorization(callbackURL: URL, pending: SignInWithChatGPTPendingAuthorization) async throws -> SignInWithChatGPTSignInResult {
        let callback = try SignInWithChatGPTAuthorizationCallback.parse(callbackURL, pending: pending)
        let tokens = try await self.tokenClient.exchange(callback, pending: pending)
        guard let idToken = tokens.idToken else {
            throw SignInWithChatGPTError.invalidServerResponse("token response did not include an ID token")
        }
        let now = self.now()
        let claims = try await self.validator.validate(idToken, clientID: callback.clientID, nonce: pending.nonce, now: now)
        if let expected = pending.accountSubject, claims.subject != expected {
            throw SignInWithChatGPTError.invalidIDToken("signed in with a different account than the one being re-authenticated")
        }
        let scopes = tokens.grantedScopes ?? callback.grantedScopes ?? pending.requestedScopes
        let credential = SignInWithChatGPTCredential(
            email: claims.email,
            issuer: claims.issuer,
            subject: claims.subject,
            clientID: callback.clientID,
            hostIdentifier: pending.hostIdentifier,
            idToken: idToken,
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            tokenType: tokens.tokenType,
            expiresIn: tokens.expiresIn,
            scopes: scopes,
            savedAt: now,
            earliestRefreshAt: tokens.earliestRefreshAt
        )
        let existing = try await self.store.account(subject: claims.subject)
        if let previous = try await self.store.credential(subject: claims.subject),
           previous.clientID != credential.clientID,
           let refreshToken = previous.refreshToken {
            // A new registration replaced the account's client; retire the old registration's tokens.
            let tokenClient = self.tokenClient
            Task.detached { try? await tokenClient.revoke(refreshToken: refreshToken, clientID: previous.clientID) }
        }
        try await self.store.saveCredential(credential)
        var account = existing ?? SignInWithChatGPTAccount(subject: claims.subject, clientID: callback.clientID, createdAt: now)
        account.clientID = callback.clientID
        account.email = claims.email ?? account.email
        account.name = claims.name ?? account.name
        account.grantedScopes = scopes
        account.isSignedIn = true
        account.lastSignedInAt = now
        try await self.store.save(account)
        try await self.store.setActiveSubject(account.subject)
        return SignInWithChatGPTSignInResult(account: account, isNewAccount: existing == nil)
    }

    // MARK: - Tokens

    /// Returns a current access token, refreshing it first when it is (nearly) expired.
    /// - Parameters:
    ///   - subject: Account subject; `nil` uses the active account.
    ///   - requirePlanUsage: Throw ``SignInWithChatGPTError/planUsageNotGranted`` unless the grant allows
    ///     plan inference.
    /// - Returns: Access token.
    public func accessToken(for subject: String? = nil, requirePlanUsage: Bool = true) async throws -> String {
        try await self.currentCredential(for: subject, requirePlanUsage: requirePlanUsage, rejectedAccessToken: nil).accessToken
    }

    /// Returns a plan access token for the active account (``ChatGPTPlanAccessTokenProvider``).
    /// - Parameter rejectedAccessToken: Token rejected with `401`; forces a refresh.
    /// - Returns: Access token.
    public func chatGPTPlanAccessToken(rejectedAccessToken: String?) async throws -> String {
        try await self.currentCredential(for: nil, requirePlanUsage: true, rejectedAccessToken: rejectedAccessToken).accessToken
    }

    /// A token provider pinned to one account (for apps that run several accounts side by side).
    /// - Parameter subject: Account subject.
    /// - Returns: Token provider.
    nonisolated public func tokenProvider(for subject: String) -> any ChatGPTPlanAccessTokenProvider {
        AccountTokenProvider(session: self, subject: subject)
    }

    /// Refreshes an account's tokens now.
    /// - Parameter subject: Account subject; `nil` uses the active account.
    /// - Returns: The refreshed credential.
    @discardableResult
    public func refresh(subject: String? = nil) async throws -> SignInWithChatGPTCredential {
        let subject = try await self.resolveSubject(subject)
        guard let credential = try await self.store.credential(subject: subject) else {
            throw SignInWithChatGPTError.notSignedIn
        }
        return try await self.refreshed(credential, force: true)
    }

    private func currentCredential(for subject: String?, requirePlanUsage: Bool, rejectedAccessToken: String?) async throws -> SignInWithChatGPTCredential {
        let subject = try await self.resolveSubject(subject)
        guard var credential = try await self.store.credential(subject: subject) else {
            throw SignInWithChatGPTError.notSignedIn
        }
        if let rejectedAccessToken, credential.accessToken == rejectedAccessToken {
            guard credential.refreshToken != nil else {
                throw SignInWithChatGPTError.reauthenticationRequired(subject: subject, reason: "access token rejected")
            }
            credential = try await self.refreshed(credential, force: true)
        } else if credential.needsRefresh(now: self.now(), leeway: self.configuration.refreshLeeway) {
            credential = try await self.refreshed(credential, force: false)
        } else if let expiresAt = credential.expiresAt, credential.refreshToken == nil, self.now() >= expiresAt {
            throw SignInWithChatGPTError.reauthenticationRequired(subject: subject, reason: "access token expired")
        }
        if requirePlanUsage, !credential.allowsPlanUsage {
            throw SignInWithChatGPTError.planUsageNotGranted
        }
        return credential
    }

    private func resolveSubject(_ subject: String?) async throws -> String {
        if let subject {
            return subject
        }
        guard let account = try await self.activeAccount(), account.isSignedIn else {
            throw SignInWithChatGPTError.notSignedIn
        }
        return account.subject
    }

    /// Single-flight refresh per account.
    private func refreshed(_ credential: SignInWithChatGPTCredential, force: Bool) async throws -> SignInWithChatGPTCredential {
        let subject = credential.subject
        let rejectedAccessToken = credential.accessToken
        if let running = self.refreshTasks[subject] {
            let value = try await running.value
            // A forced refresh joined a refresh that kept the rejected token: refresh again below.
            if !force || value.accessToken != rejectedAccessToken {
                return value
            }
        }
        let task = Task { try await self.performRefresh(subject: subject, rejectedAccessToken: rejectedAccessToken, force: force) }
        self.refreshTasks[subject] = task
        defer {
            if self.refreshTasks[subject] == task {
                self.refreshTasks[subject] = nil
            }
        }
        return try await task.value
    }

    private func performRefresh(subject: String, rejectedAccessToken: String, force: Bool) async throws -> SignInWithChatGPTCredential {
        // Re-read: another session sharing the store may have rotated the tokens already.
        guard let current = try await self.store.credential(subject: subject) else {
            throw SignInWithChatGPTError.notSignedIn
        }
        if current.accessToken != rejectedAccessToken, !current.needsRefresh(now: self.now(), leeway: self.configuration.refreshLeeway) {
            return current
        }
        if !force, !current.needsRefresh(now: self.now(), leeway: self.configuration.refreshLeeway) {
            return current
        }
        guard let refreshToken = current.refreshToken else {
            throw SignInWithChatGPTError.reauthenticationRequired(subject: subject, reason: "no refresh token")
        }
        let response: SignInWithChatGPTTokenResponse
        do {
            response = try await self.tokenClient.refresh(refreshToken: refreshToken, clientID: current.clientID, subject: subject)
        } catch let error as SignInWithChatGPTError {
            if case .reauthenticationRequired = error {
                try await self.clearTokens(subject: subject)
            }
            throw error
        }
        let now = self.now()
        var updated = current.applying(response, now: now)
        if let idToken = response.idToken {
            // Keep the previous ID token when the new one does not validate for this account.
            let claims = try? await self.validator.validate(idToken, clientID: current.clientID, nonce: nil, now: now)
            if claims?.subject != subject {
                updated.idToken = current.idToken
            } else if let email = claims?.email {
                updated.email = email
            }
        }
        try await self.store.saveCredential(updated)
        if var account = try await self.store.account(subject: subject) {
            account.grantedScopes = updated.scopes
            account.email = updated.email ?? account.email
            try await self.store.save(account)
        }
        return updated
    }

    // MARK: - Sign-out and records

    /// Signs an account out: revokes its refresh token (with retries), then clears its tokens. The
    /// account's client id and the host identifier are kept for the next sign-in.
    /// - Parameter subject: Account subject; `nil` uses the active account.
    /// - Returns: Whether the server confirmed the revocation.
    @discardableResult
    public func signOut(subject: String? = nil) async throws -> SignInWithChatGPTSignOutResult {
        let subject = try await self.resolveSubject(subject)
        let credential = try await self.store.credential(subject: subject)
        var result = SignInWithChatGPTSignOutResult.clearedLocally
        if let credential, let refreshToken = credential.refreshToken {
            do {
                try await self.tokenClient.revoke(refreshToken: refreshToken, clientID: credential.clientID)
                result = .revoked
            } catch let error as SignInWithChatGPTError {
                result = .revocationFailed(error.localizedDescription)
            }
        }
        try await self.clearTokens(subject: subject)
        if try await self.store.activeSubject() == subject {
            let next = try await self.store.accounts().first { $0.isSignedIn && $0.subject != subject }
            try await self.store.setActiveSubject(next?.subject)
        }
        return result
    }

    /// Signs out (when signed in) and forgets the account, including its client id.
    /// - Parameter subject: Account subject.
    public func removeAccount(subject: String) async throws {
        if try await self.store.credential(subject: subject) != nil {
            try await self.signOut(subject: subject)
        }
        try await self.store.remove(subject: subject)
    }

    /// Exports an account's credential record (documented JSON), for example to move a session to a
    /// self-hosted VM. The record contains live tokens.
    /// - Parameter subject: Account subject; `nil` uses the active account.
    /// - Returns: Record JSON.
    public func exportCredentialRecord(subject: String? = nil) async throws -> Data {
        let subject = try await self.resolveSubject(subject)
        guard let credential = try await self.store.credential(subject: subject) else {
            throw SignInWithChatGPTError.notSignedIn
        }
        return try credential.recordJSON()
    }

    /// Imports a credential record produced on another machine. This host keeps its own host identifier
    /// for later authorizations and refreshes the imported tokens itself.
    /// - Parameter data: Record JSON.
    /// - Returns: The imported account.
    @discardableResult
    public func importCredentialRecord(_ data: Data) async throws -> SignInWithChatGPTAccount {
        var credential: SignInWithChatGPTCredential
        do {
            credential = try SignInWithChatGPTCredential.decodeRecord(data)
        } catch {
            throw SignInWithChatGPTError.invalidServerResponse("credential record is not valid")
        }
        let claims = credential.idToken.flatMap(SignInWithChatGPTIDTokenValidator.unverifiedClaims)
        if credential.subject.isEmpty {
            guard let subject = claims?.subject else {
                throw SignInWithChatGPTError.invalidServerResponse("credential record has no subject")
            }
            credential.subject = subject
        }
        credential.email = credential.email ?? claims?.email
        _ = try await self.store.hostIdentifier()
        try await self.store.saveCredential(credential)
        var account = try await self.store.account(subject: credential.subject)
            ?? SignInWithChatGPTAccount(subject: credential.subject, clientID: credential.clientID, createdAt: self.now())
        account.clientID = credential.clientID
        account.email = credential.email ?? account.email
        account.grantedScopes = credential.scopes
        account.isSignedIn = true
        account.lastSignedInAt = self.now()
        try await self.store.save(account)
        if try await self.store.activeSubject() == nil {
            try await self.store.setActiveSubject(account.subject)
        }
        return account
    }

    private func clearTokens(subject: String) async throws {
        try await self.store.deleteCredential(subject: subject)
        if var account = try await self.store.account(subject: subject) {
            account.isSignedIn = false
            try await self.store.save(account)
        }
    }
}

/// Token provider pinned to one account.
private struct AccountTokenProvider: ChatGPTPlanAccessTokenProvider {
    let session: SignInWithChatGPTSession
    let subject: String

    func chatGPTPlanAccessToken(rejectedAccessToken: String?) async throws -> String {
        try await self.session.planAccessToken(subject: self.subject, rejectedAccessToken: rejectedAccessToken)
    }
}

extension SignInWithChatGPTSession {
    func planAccessToken(subject: String, rejectedAccessToken: String?) async throws -> String {
        try await self.currentCredential(for: subject, requirePlanUsage: true, rejectedAccessToken: rejectedAccessToken).accessToken
    }
}
