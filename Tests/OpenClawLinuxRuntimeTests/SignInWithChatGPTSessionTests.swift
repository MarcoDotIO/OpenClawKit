import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import OpenClawCore

@Suite("Sign in with ChatGPT tokens and credentials")
struct SignInWithChatGPTTokenTests {
    @Test("Token responses decode earliest_refresh_at as seconds or ISO 8601")
    func tokenResponseDecoding() throws {
        let seconds = try JSONDecoder().decode(
            SignInWithChatGPTTokenResponse.self,
            from: Data((#"{"access_token":"a","refresh_token":"r","id_token":"i","token_type":"Bearer","expires_in":3600,"#
                + #""scope":"openid email","earliest_refresh_at":1800001800}"#).utf8)
        )
        #expect(seconds.expiresIn == 3600)
        #expect(seconds.grantedScopes == ["openid", "email"])
        #expect(seconds.earliestRefreshAt == Date(timeIntervalSince1970: 1_800_001_800))
        let iso = try JSONDecoder().decode(
            SignInWithChatGPTTokenResponse.self,
            from: Data(#"{"access_token":"a","expires_in":"3600","earliest_refresh_at":"2027-01-15T08:00:00Z"}"#.utf8)
        )
        #expect(iso.tokenType == "Bearer")
        #expect(iso.expiresIn == 3600)
        #expect(iso.earliestRefreshAt == SignInWithChatGPTDates.parseISO8601("2027-01-15T08:00:00Z"))
    }

    @Test("Credential records use the documented field names and ISO 8601 saved_at")
    func credentialRecord() throws {
        let credential = SignInWithChatGPTCredential(
            email: "person@example.com",
            issuer: "https://auth.openai.com",
            subject: "user-abc",
            clientID: "oaiapp_test",
            hostIdentifier: SignInWithChatGPTHostIdentifier(rawValue: "urn:uuid:3f2c8a4e-7b1d-4c9e-9a51-2d6f0b8e4c17")!,
            idToken: "id",
            accessToken: "access",
            refreshToken: "refresh",
            expiresIn: 3600,
            scopes: ["openid", "chatgpt.tokens.use.direct"],
            savedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let json = try #require(JSONSerialization.jsonObject(with: credential.recordJSON()) as? [String: Any])
        #expect(Set(json.keys) == [
            "email", "issuer", "subject", "client_id", "ext_agent_host_id", "id_token", "access_token",
            "refresh_token", "token_type", "expires_in", "scopes", "saved_at",
        ])
        #expect(json["saved_at"] as? String == "2027-01-15T08:00:00.000Z")
        #expect(json["scopes"] as? [String] == ["openid", "chatgpt.tokens.use.direct"])
        let decoded = try SignInWithChatGPTCredential.decodeRecord(credential.recordJSON())
        #expect(decoded == credential)
        #expect(decoded.allowsPlanUsage)
        #expect(decoded.expiresAt == Date(timeIntervalSince1970: 1_800_003_600))

        let minimal = try SignInWithChatGPTCredential.decodeRecord(Data(
            (#"{"client_id":"oaiapp_test","access_token":"a","refresh_token":"r","expires_in":3600,"saved_at":"2027-01-15T08:00:00Z","#
                + #""ext_agent_host_id":"urn:uuid:3f2c8a4e-7b1d-4c9e-9a51-2d6f0b8e4c17","scopes":"openid email"}"#).utf8
        ))
        #expect(minimal.subject.isEmpty)
        #expect(minimal.scopes == ["openid", "email"])
        #expect(minimal.savedAt == SignInWithChatGPTDates.parseISO8601("2027-01-15T08:00:00Z"))
    }

    @Test("Refresh timing honours the leeway and earliest_refresh_at")
    func needsRefresh() {
        let saved = Date(timeIntervalSince1970: 1_800_000_000)
        var credential = SignInWithChatGPTCredential(
            email: nil,
            issuer: "https://auth.openai.com",
            subject: "user-abc",
            clientID: "oaiapp_test",
            hostIdentifier: .randomUUID(),
            idToken: nil,
            accessToken: "a",
            refreshToken: "r",
            expiresIn: 3600,
            scopes: [],
            savedAt: saved
        )
        #expect(!credential.needsRefresh(now: saved.addingTimeInterval(3000), leeway: 300))
        #expect(credential.needsRefresh(now: saved.addingTimeInterval(3400), leeway: 300))
        credential.earliestRefreshAt = saved.addingTimeInterval(3500)
        #expect(!credential.needsRefresh(now: saved.addingTimeInterval(3400), leeway: 300))
        #expect(credential.needsRefresh(now: saved.addingTimeInterval(3600), leeway: 300))
        credential.refreshToken = nil
        #expect(!credential.needsRefresh(now: saved.addingTimeInterval(7200), leeway: 300))
    }

    @Test("Code exchange and refresh send the documented form fields and map OAuth errors")
    func tokenClient() async throws {
        let server = SIWCFakeServer()
        server.useRotatingRefresh()
        let client = SignInWithChatGPTTokenClient(endpoints: .production, transport: server.transport)
        let pending = try SignInWithChatGPTAuthorizationRequest.make(
            endpoints: .production,
            redirectURI: SignInWithChatGPTConfiguration.callbackURL(port: 1455),
            hostIdentifier: .randomUUID(),
            scopes: [],
            agentName: "TestAgent",
            reauthentication: nil,
            consent: .automatic,
            now: Date(),
            secrets: SIWCTest.secrets
        )
        let callback = try SignInWithChatGPTAuthorizationCallback.parse(SIWCTest.callbackURL(), pending: pending)
        let exchanged = try await client.exchange(callback, pending: pending)
        #expect(exchanged.accessToken == "access-1")
        let exchange = try #require(server.forms(path: "/api/accounts/oauth/token").first)
        #expect(exchange == [
            "grant_type": "authorization_code",
            "client_id": "oaiapp_test",
            "code": "code-1",
            "code_verifier": SIWCTest.secrets.verifier,
            "redirect_uri": "http://127.0.0.1:1455/auth/callback",
            "resource": "https://api.openai.com/v1",
        ])
        let request = try #require(server.recordedRequests.first)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)

        _ = try await client.refresh(refreshToken: "refresh-1", clientID: "oaiapp_test", subject: "user-abc")
        #expect(server.forms(path: "/api/accounts/oauth/token").last == [
            "grant_type": "refresh_token",
            "client_id": "oaiapp_test",
            "refresh_token": "refresh-1",
            "resource": "https://api.openai.com/v1",
        ])

        server.setTokenHandler { _, _ in SIWCFakeServer.json(["error": "invalid_grant", "error_description": "code used"], status: 400) }
        await #expect(throws: SignInWithChatGPTError.authorizationCodeRejected("code used")) {
            try await client.exchange(callback, pending: pending)
        }
        for code in SignInWithChatGPTTokenClient.reauthenticationCodes {
            server.setTokenHandler { _, _ in SIWCFakeServer.json(["error": code], status: 400) }
            await #expect(throws: SignInWithChatGPTError.reauthenticationRequired(subject: "user-abc", reason: code)) {
                try await client.refresh(refreshToken: "r", clientID: "oaiapp_test", subject: "user-abc")
            }
        }
        server.setTokenHandler { _, _ in SIWCFakeServer.json(["error": ["code": "invalid_client", "message": "unknown client"]], status: 401) }
        await #expect(throws: SignInWithChatGPTError.invalidClient("unknown client")) {
            try await client.refresh(refreshToken: "r", clientID: "oaiapp_test", subject: "user-abc")
        }
        server.setTokenHandler { _, _ in SIWCFakeServer.json(["error": "temporarily_unavailable"], status: 503) }
        await #expect(throws: SignInWithChatGPTError.tokenRequestFailed(statusCode: 503, code: "temporarily_unavailable", description: nil)) {
            try await client.refresh(refreshToken: "r", clientID: "oaiapp_test", subject: "user-abc")
        }
    }

    @Test("Revocation retries 5xx responses and stops on 4xx")
    func revocation() async throws {
        let server = SIWCFakeServer()
        let attempts = SIWCCounter()
        server.setRevokeHandler { _, _ in
            HTTPResponseData(statusCode: attempts.increment() < 2 ? 503 : 200, headers: [:], body: Data())
        }
        let client = SignInWithChatGPTTokenClient(endpoints: .production, transport: server.transport, revocationRetryDelays: [0.01, 0.01, 0.01])
        try await client.revoke(refreshToken: "refresh-1", clientID: "oaiapp_test")
        #expect(attempts.value == 3)
        #expect(server.forms(path: "/api/accounts/oauth/revoke").last == [
            "token": "refresh-1",
            "token_type_hint": "refresh_token",
            "client_id": "oaiapp_test",
        ])

        let rejected = SIWCFakeServer()
        let rejectedAttempts = SIWCCounter()
        rejected.setRevokeHandler { _, _ in
            rejectedAttempts.increment()
            return SIWCFakeServer.json(["error": "invalid_request"], status: 400)
        }
        let rejectingClient = SignInWithChatGPTTokenClient(endpoints: .production, transport: rejected.transport, revocationRetryDelays: [0.01, 0.01])
        await #expect(throws: SignInWithChatGPTError.self) {
            try await rejectingClient.revoke(refreshToken: "refresh-1", clientID: "oaiapp_test")
        }
        #expect(rejectedAttempts.value == 1)
    }
}

final class SIWCCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    @discardableResult
    func increment() -> Int {
        self.lock.withLock {
            let previous = self.count
            self.count += 1
            return previous
        }
    }

    var value: Int {
        self.lock.withLock { self.count }
    }
}

@Suite("Sign in with ChatGPT session")
struct SignInWithChatGPTSessionTests {
    @Test("A first sign-in registers the account and persists the host id first")
    func registration() async throws {
        let server = SIWCFakeServer()
        let clock = SIWCTestClock()
        let store = InMemoryTestCredentialStore()
        let session = SIWCTest.makeSession(server: server, clock: clock, store: store)
        let pending = try await session.beginAuthorization(
            redirectURI: SignInWithChatGPTConfiguration.callbackURL(port: 1455),
            reauthenticating: nil,
            consent: .automatic,
            secrets: SIWCTest.secrets
        )
        let hostID = try await session.hostIdentifier()
        #expect(try await store.loadSecret(for: "openclaw.siwc.host-id") == hostID.rawValue)
        let query = SIWCTest.queryItems(pending.authorizationURL)
        #expect(query["client_id"] == "dynamic_agent_client")
        #expect(query["agent_name_hint"] == "TestAgent")
        #expect(query["ext_agent_host_id"] == hostID.rawValue)

        let result = try await session.completeAuthorization(callbackURL: SIWCTest.callbackURL(), pending: pending)
        #expect(result.isNewAccount)
        #expect(result.shouldShowPlanWelcome)
        #expect(result.account.subject == "user-abc")
        #expect(result.account.email == "person@example.com")
        #expect(result.account.clientID == "oaiapp_test")
        #expect(result.account.usesChatGPTPlan)
        #expect(try await session.activeAccount()?.subject == "user-abc")
        #expect(try await session.accessToken() == "access-1")

        let credential = try #require(try await session.store.credential(subject: "user-abc"))
        #expect(credential.hostIdentifier == hostID)
        #expect(credential.idToken == SignInWithChatGPTFixtures.Token.valid)
        #expect(credential.savedAt == clock.now)

        try await session.markPlanWelcomeSeen(subject: "user-abc")
        let again = try await SIWCTest.signIn(session)
        #expect(!again.isNewAccount)
        #expect(!again.shouldShowPlanWelcome)
        #expect(try await session.hostIdentifier() == hostID)
    }

    @Test("Access tokens refresh before expiry, once, with rotated refresh tokens")
    func refresh() async throws {
        let server = SIWCFakeServer()
        server.useRotatingRefresh()
        let clock = SIWCTestClock()
        let session = SIWCTest.makeSession(server: server, clock: clock)
        try await SIWCTest.signIn(session)

        clock.advance(3_400)
        #expect(try await session.accessToken() == "access-2")
        let refresh = try #require(server.forms(path: "/api/accounts/oauth/token").last)
        #expect(refresh["grant_type"] == "refresh_token")
        #expect(refresh["refresh_token"] == "refresh-1")
        #expect(refresh["client_id"] == "oaiapp_test")
        #expect(refresh["scope"] == nil)
        #expect(try await session.store.credential(subject: "user-abc")?.refreshToken == "refresh-2")

        clock.advance(3_600)
        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<6 {
                group.addTask { try await session.accessToken() }
            }
            return try await group.reduce(into: Set<String>()) { $0.insert($1) }
        }
        #expect(tokens == ["access-3"])
        #expect(server.forms(path: "/api/accounts/oauth/token").filter { $0["grant_type"] == "refresh_token" }.count == 2)

        // A 401 forces a refresh even though the token has not expired.
        #expect(try await session.chatGPTPlanAccessToken(rejectedAccessToken: "access-3") == "access-4")
        // A stale rejected token does not refresh again.
        #expect(try await session.chatGPTPlanAccessToken(rejectedAccessToken: "access-3") == "access-4")
        let pinned = session.tokenProvider(for: "user-abc")
        #expect(try await pinned.chatGPTPlanAccessToken(rejectedAccessToken: nil) == "access-4")
    }

    @Test("A rejected refresh token clears tokens but keeps the account's client id")
    func refreshRejected() async throws {
        let server = SIWCFakeServer()
        let clock = SIWCTestClock()
        let session = SIWCTest.makeSession(server: server, clock: clock)
        try await SIWCTest.signIn(session)
        server.setTokenHandler { _, _ in SIWCFakeServer.json(["error": "refresh_token_reused"], status: 400) }
        clock.advance(4_000)
        await #expect(throws: SignInWithChatGPTError.reauthenticationRequired(subject: "user-abc", reason: "refresh_token_reused")) {
            try await session.accessToken()
        }
        #expect(try await session.store.credential(subject: "user-abc") == nil)
        let account = try #require(try await session.accounts().first)
        #expect(!account.isSignedIn)
        #expect(account.clientID == "oaiapp_test")
        await #expect(throws: SignInWithChatGPTError.notSignedIn) {
            try await session.accessToken()
        }

        // Signing in again re-authenticates with the saved client id and hints.
        let pending = try await session.beginAuthorization(redirectURI: SignInWithChatGPTConfiguration.callbackURL(port: 1455), reauthenticating: "user-abc")
        let query = SIWCTest.queryItems(pending.authorizationURL)
        #expect(query["client_id"] == "oaiapp_test")
        #expect(query["agent_name_hint"] == nil)
        #expect(query["login_hint"] == "person@example.com")
    }

    @Test("Plan inference requires chatgpt.tokens.use.direct")
    func planScopeRequired() async throws {
        let server = SIWCFakeServer()
        server.useRotatingRefresh(scope: "openid profile email offline_access")
        let session = SIWCTest.makeSession(server: server, clock: SIWCTestClock())
        let result = try await SIWCTest.signIn(session)
        #expect(!result.account.usesChatGPTPlan)
        #expect(!result.shouldShowPlanWelcome)
        await #expect(throws: SignInWithChatGPTError.planUsageNotGranted) {
            try await session.chatGPTPlanAccessToken(rejectedAccessToken: nil)
        }
        #expect(try await session.accessToken(requirePlanUsage: false) == "access-1")
    }

    @Test("Re-authenticating must return the same account")
    func reauthenticationSubjectMismatch() async throws {
        let server = SIWCFakeServer()
        let session = SIWCTest.makeSession(server: server, clock: SIWCTestClock())
        try await SIWCTest.signIn(session)
        server.setTokenHandler { _, _ in
            SIWCFakeServer.json(SIWCFakeServer.tokenBody(access: "a", refresh: "r", idToken: SignInWithChatGPTFixtures.Token.otherSubject))
        }
        let pending = try await session.beginAuthorization(
            redirectURI: SignInWithChatGPTConfiguration.callbackURL(port: 1455),
            reauthenticating: "user-abc",
            consent: .automatic,
            secrets: SIWCTest.secrets
        )
        await #expect(throws: SignInWithChatGPTError.self) {
            try await session.completeAuthorization(callbackURL: SIWCTest.callbackURL(clientID: nil), pending: pending)
        }
        #expect(try await session.store.credential(subject: "user-abc")?.accessToken == "access-1")
        await #expect(throws: SignInWithChatGPTError.unknownAccount("user-nobody")) {
            try await session.beginAuthorization(redirectURI: SignInWithChatGPTConfiguration.callbackURL(port: 1455), reauthenticating: "user-nobody")
        }
    }

    @Test("Sign-out revokes the refresh token and keeps the client mapping and host id")
    func signOut() async throws {
        let server = SIWCFakeServer()
        let session = SIWCTest.makeSession(server: server, clock: SIWCTestClock())
        try await SIWCTest.signIn(session)
        let hostID = try await session.hostIdentifier()
        #expect(try await session.signOut() == .revoked)
        #expect(server.forms(path: "/api/accounts/oauth/revoke").last?["token"] == "refresh-1")
        #expect(try await session.store.credential(subject: "user-abc") == nil)
        #expect(try await session.accounts().first?.clientID == "oaiapp_test")
        #expect(try await session.hostIdentifier() == hostID)
        await #expect(throws: SignInWithChatGPTError.notSignedIn) {
            try await session.signOut()
        }

        try await SIWCTest.signIn(session)
        server.setRevokeHandler { _, _ in SIWCFakeServer.json(["error": "invalid_request"], status: 400) }
        let result = try await session.signOut(subject: "user-abc")
        guard case .revocationFailed = result else {
            Issue.record("expected revocationFailed, got \(result)")
            return
        }
        #expect(try await session.store.credential(subject: "user-abc") == nil)

        try await session.removeAccount(subject: "user-abc")
        #expect(try await session.accounts().isEmpty)
    }

    @Test("Credential records export and import between hosts")
    func exportImport() async throws {
        let server = SIWCFakeServer()
        let source = SIWCTest.makeSession(server: server, clock: SIWCTestClock())
        try await SIWCTest.signIn(source)
        let record = try await source.exportCredentialRecord()
        #expect(String(decoding: record, as: UTF8.self).contains("\"client_id\" : \"oaiapp_test\""))

        let destinationStore = InMemoryTestCredentialStore()
        let destination = SIWCTest.makeSession(server: server, clock: SIWCTestClock(), store: destinationStore)
        let account = try await destination.importCredentialRecord(record)
        #expect(account.subject == "user-abc")
        #expect(account.clientID == "oaiapp_test")
        #expect(try await destination.accessToken() == "access-1")
        #expect(try await destination.hostIdentifier() != source.hostIdentifier())

        await #expect(throws: SignInWithChatGPTError.self) {
            try await destination.importCredentialRecord(Data("{}".utf8))
        }
    }

    #if !os(tvOS) && !os(watchOS)
    @Test("Browser sign-in completes through the loopback listener")
    func browserSignIn() async throws {
        let server = SIWCFakeServer()
        let session = SIWCTest.makeSession(server: server, clock: SIWCTestClock(), callbackPort: 0)
        let browser = LoopbackCallingBrowser()
        let result = try await session.signIn(using: browser, reauthenticating: nil, consent: .automatic, timeout: 20, secrets: SIWCTest.secrets)
        #expect(result.account.subject == "user-abc")
        #expect(browser.presentedURL.map { SIWCTest.queryItems($0)["client_id"] } == "dynamic_agent_client")
        #expect(browser.dismissCount >= 1)
        let deadline = Date().addingTimeInterval(10)
        while browser.responseBody == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(browser.responseStatuses == [400, 200])
        let page = try #require(browser.responseBody)
        #expect(page.contains("Signed in with ChatGPT"))
        #expect(page.contains("TestAgent"))
    }

    @Test("Closing the browser after the redirect still completes the sign-in")
    func browserClosedAfterRedirect() async throws {
        let server = SIWCFakeServer()
        let session = SIWCTest.makeSession(server: server, clock: SIWCTestClock(), callbackPort: 0)
        let browser = LoopbackCallingBrowser(closesAfterCallback: true)
        let result = try await session.signIn(using: browser, reauthenticating: nil, consent: .automatic, timeout: 20, secrets: SIWCTest.secrets)
        #expect(result.account.subject == "user-abc")
    }

    @Test("Closing the browser cancels the sign-in and a silent browser times out")
    func browserCancelAndTimeout() async throws {
        let server = SIWCFakeServer()
        let session = SIWCTest.makeSession(server: server, clock: SIWCTestClock(), callbackPort: 0)
        await #expect(throws: SignInWithChatGPTError.cancelled) {
            try await session.signIn(using: CancellingBrowser(), timeout: 20)
        }
        await #expect(throws: SignInWithChatGPTError.timedOut) {
            try await session.signIn(using: SignInWithChatGPTExternalBrowser { _ in true }, timeout: 1)
        }
        await #expect(throws: OpenClawCoreError.self) {
            try await session.signIn(using: SignInWithChatGPTExternalBrowser { _ in false }, timeout: 20)
        }
        #expect(try await session.accounts().isEmpty)
    }
    #endif
}

#if !os(tvOS) && !os(watchOS)
/// Browser that plays the authorization server: it calls the loopback redirect with a code.
final class LoopbackCallingBrowser: SignInWithChatGPTBrowser, @unchecked Sendable {
    private let closesAfterCallback: Bool
    private let lock = NSLock()
    private var url: URL?
    private var body: String?
    private var statuses: [Int] = []
    private var dismissals = 0

    var presentedURL: URL? { self.lock.withLock { self.url } }
    var responseBody: String? { self.lock.withLock { self.body } }
    var responseStatuses: [Int] { self.lock.withLock { self.statuses } }
    var dismissCount: Int { self.lock.withLock { self.dismissals } }

    /// - Parameter closesAfterCallback: Throw `cancelled` after the redirect, like a user closing the sheet.
    init(closesAfterCallback: Bool = false) {
        self.closesAfterCallback = closesAfterCallback
    }

    func present(_ authorizationURL: URL) async throws {
        self.lock.withLock { self.url = authorizationURL }
        let query = SIWCTest.queryItems(authorizationURL)
        guard let redirect = query["redirect_uri"].flatMap(URL.init(string:)) else {
            throw SignInWithChatGPTError.invalidCallback("missing redirect_uri")
        }
        // A forged callback with the wrong state is ignored by the listener.
        var forged = URLComponents(url: redirect, resolvingAgainstBaseURL: false)!
        forged.queryItems = [URLQueryItem(name: "code", value: "evil"), URLQueryItem(name: "state", value: "forged")]
        var components = URLComponents(url: redirect, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "code", value: "code-1"),
            URLQueryItem(name: "state", value: query["state"]),
            URLQueryItem(name: "client_id", value: "oaiapp_test"),
        ]
        let forgedURL = forged.url!
        let callbackURL = components.url!
        // The session cancels `present` as soon as the callback lands, so the requests run detached
        // (like a real browser) and finish recording their responses regardless.
        let recorded = Task.detached { () -> ([Int], String) in
            let (_, forgedResponse) = try await URLSession.shared.data(from: forgedURL)
            let (data, response) = try await URLSession.shared.data(from: callbackURL)
            return (
                [(forgedResponse as? HTTPURLResponse)?.statusCode ?? 0, (response as? HTTPURLResponse)?.statusCode ?? 0],
                String(decoding: data, as: UTF8.self)
            )
        }
        let (statuses, body) = try await recorded.value
        self.lock.withLock {
            self.statuses = statuses
            self.body = body
        }
        if self.closesAfterCallback {
            throw SignInWithChatGPTError.cancelled
        }
    }

    func dismiss() async {
        self.lock.withLock { self.dismissals += 1 }
    }
}

/// Browser that the user closes right away.
struct CancellingBrowser: SignInWithChatGPTBrowser {
    func present(_: URL) async throws {
        throw SignInWithChatGPTError.cancelled
    }

    func dismiss() async {}
}
#endif
