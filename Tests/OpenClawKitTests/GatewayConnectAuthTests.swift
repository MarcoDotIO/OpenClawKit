import CryptoKit
import Foundation
import OpenClawProtocol
import Testing
@testable import OpenClawKit

private func authChannel(
    url: String,
    token: String? = nil,
    bootstrapToken: String? = nil,
    password: String? = nil,
    authBindingKey: SymmetricKey? = nil,
    session: GatewayCoreFakeSession,
    options: GatewayConnectOptions) throws -> GatewayChannelActor
{
    GatewayChannelActor(
        url: try #require(URL(string: url)),
        token: token,
        bootstrapToken: bootstrapToken,
        password: password,
        authBindingKey: authBindingKey,
        session: WebSocketSessionBox(session: session),
        connectOptions: options)
}

/// Runs `body` against an isolated, empty device identity/auth state directory.
private func withIsolatedDeviceState(_ body: () async throws -> Void) async throws {
    let directory = try gatewayCoreTemporaryStateDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await DeviceIdentityStore.withStateDirectory(directory) {
        try await body()
    }
}

private func storedToken(
    deviceId: String,
    role: String,
    gatewayID: String? = nil,
    profile: GatewayDeviceIdentityProfile = .primary) -> DeviceAuthEntry?
{
    DeviceAuthStore.loadToken(deviceId: deviceId, role: role, gatewayID: gatewayID, profile: profile)
}

private func store(
    deviceId: String,
    role: String,
    token: String,
    scopes: [String] = [],
    gatewayID: String? = nil)
{
    _ = DeviceAuthStore.storeTokenResult(
        deviceId: deviceId,
        role: role,
        token: token,
        scopes: scopes,
        gatewayID: gatewayID,
        profile: .primary)
}

@Suite("Gateway connect auth")
struct GatewayConnectAuthTests {
    @Test(arguments: [
        ("operator", ["operator.read"], ["operator.write"], false),
        ("operator", ["operator.write"], ["operator.read"], true),
        ("operator", ["operator.pairing"], ["operator.admin"], false),
        ("operator", ["operator.questions"], ["operator.read", "operator.write"], true),
        ("operator", [" operator.read ", "operator.read"], ["operator.read"], false),
        ("operator", [], ["operator.read"], false),
        ("node", ["node.exec"], ["node.exec"], false),
        ("node", ["operator.read"], ["operator.admin"], true),
    ])
    func storedScopeCoverageFollowsUpstreamRules(
        role: String,
        requested: [String],
        stored: [String],
        exceeds: Bool)
    {
        #expect(GatewayChannelActor._test_requestedScopesExceedStoredToken(
            role: role,
            requestedScopes: requested,
            storedToken: "stored",
            storedScopes: stored) == exceeds)
        // Without a stored token (or with legacy scope-less entries) nothing is exceeded.
        #expect(GatewayChannelActor._test_requestedScopesExceedStoredToken(
            role: role,
            requestedScopes: requested,
            storedToken: nil,
            storedScopes: stored) == false)
        #expect(GatewayChannelActor._test_requestedScopesExceedStoredToken(
            role: role,
            requestedScopes: requested,
            storedToken: "stored",
            storedScopes: []) == false)
    }

    @Test
    func bootstrapHandoffScopesDropAdminOnlyGrants() {
        #expect(GatewayChannelActor.filteredBootstrapHandoffScopes(
            role: "operator",
            scopes: ["operator.pairing", "operator.write", "operator.read", "operator.admin", "operator.write"])
            == ["operator.admin", "operator.read", "operator.write"])
        #expect(GatewayChannelActor.filteredBootstrapHandoffScopes(role: "node", scopes: ["node.exec"]) == [])
        #expect(GatewayChannelActor.filteredBootstrapHandoffScopes(role: "custom", scopes: ["x"]) == nil)
    }

    @Test
    func trustedDeviceRetryHostsAreStrictlyLoopback() {
        #expect(GatewayChannelActor.isTrustedDeviceRetryLoopbackHost("127.0.0.1"))
        #expect(GatewayChannelActor.isTrustedDeviceRetryLoopbackHost("localhost"))
        #expect(GatewayChannelActor.isTrustedDeviceRetryLoopbackHost("[::1]"))
        #expect(!GatewayChannelActor.isTrustedDeviceRetryLoopbackHost("0.0.0.0"))
        #expect(!GatewayChannelActor.isTrustedDeviceRetryLoopbackHost("::"))
        #expect(!GatewayChannelActor.isTrustedDeviceRetryLoopbackHost("127.example.com"))
        #expect(!GatewayChannelActor.isTrustedDeviceRetryLoopbackHost("gateway.example.com"))
    }

    @Test
    func deviceProofSignsTheServerChallengeTimestampWithTheV2Payload() async throws {
        try await withIsolatedDeviceState {
            let session = GatewayCoreFakeSession(fixedScript: GatewayCoreSocketScript(
                challenge: GatewayCoreFrames.challenge(nonce: "server-nonce", ts: GatewayCoreFrames.challengeTimestampMs)))
            let channel = try authChannel(
                url: "ws://127.0.0.1:18789",
                token: "shared-token",
                session: session,
                options: gatewayCoreOptions(scopes: ["operator.read", "operator.write"], includeDeviceIdentity: true))
            try await channel.connect()

            let identity = try DeviceIdentityStore.loadOrCreatePersistedOrThrow(profile: .primary)
            let params = try #require(session.latestSocket?.connectParams())
            let device = try #require(params["device"] as? [String: Any])
            #expect(device["id"] as? String == identity.deviceId)
            #expect((device["signedAt"] as? NSNumber)?.int64Value == GatewayCoreFrames.challengeTimestampMs)
            #expect(device["nonce"] as? String == "server-nonce")
            #expect(Set(device.keys) == ["id", "publicKey", "signature", "signedAt", "nonce"])

            let expectedPayload = GatewayDeviceAuthPayload.buildConnectCompatibilityPayload(fields: .init(
                deviceId: identity.deviceId,
                client: .init(id: GatewayClientID.iosApp.rawValue, mode: "ui"),
                role: "operator",
                scopes: ["operator.read", "operator.write"],
                signedAtMs: GatewayCoreFrames.challengeTimestampMs,
                token: "shared-token",
                nonce: "server-nonce"))
            #expect(expectedPayload.hasPrefix("v2|"))
            let signature = try #require(device["signature"] as? String)
            #expect(try Self.verify(signature: signature, payload: expectedPayload, publicKey: identity.publicKey))
            await channel.shutdown()
        }
    }

    @Test
    func v3DeviceProofIsOptIn() async throws {
        try await withIsolatedDeviceState {
            let session = GatewayCoreFakeSession()
            let channel = try authChannel(
                url: "ws://127.0.0.1:18789",
                session: session,
                options: gatewayCoreOptions(includeDeviceIdentity: true, deviceProofPayload: .v3))
            try await channel.connect()
            let identity = try DeviceIdentityStore.loadOrCreatePersistedOrThrow(profile: .primary)
            let device = try #require(session.latestSocket?.connectParams()?["device"] as? [String: Any])
            let payload = GatewayDeviceAuthPayload.buildV3(
                fields: .init(
                    deviceId: identity.deviceId,
                    client: .init(id: GatewayClientID.iosApp.rawValue, mode: "ui"),
                    role: "operator",
                    scopes: ["operator.read"],
                    signedAtMs: GatewayCoreFrames.challengeTimestampMs,
                    token: nil,
                    nonce: "nonce-1"),
                platform: InstanceIdentity.platformString,
                deviceFamily: InstanceIdentity.deviceFamily)
            let signature = try #require(device["signature"] as? String)
            #expect(try Self.verify(signature: signature, payload: payload, publicKey: identity.publicKey))
            await channel.shutdown()
        }
    }

    @Test
    func challengeWithoutTimestampFailsInsteadOfSigningTheLocalClock() async throws {
        let session = GatewayCoreFakeSession(fixedScript: GatewayCoreSocketScript(
            challenge: GatewayCoreFrames.challenge(ts: nil)))
        let channel = try authChannel(url: "ws://127.0.0.1:1", session: session, options: gatewayCoreOptions())
        await #expect(throws: (any Error).self) { try await channel.connect() }
        #expect(session.latestSocket?.sentFrames(method: "connect").isEmpty == true)
        await channel.shutdown()
    }

    @Test
    func storedTokenIsReusedWithItsScopesWhenNoExplicitCredential() async throws {
        try await withIsolatedDeviceState {
            let identity = try DeviceIdentityStore.loadOrCreatePersistedOrThrow(profile: .primary)
            store(deviceId: identity.deviceId, role: "operator", token: "stored-token", scopes: ["operator.admin"])
            let session = GatewayCoreFakeSession()
            let channel = try authChannel(
                url: "ws://gateway.example.com",
                session: session,
                options: gatewayCoreOptions(scopes: ["operator.read"], includeDeviceIdentity: true))
            try await channel.connect()

            #expect(session.latestSocket?.connectAuth()?["token"] as? String == "stored-token")
            #expect(session.latestSocket?.connectParams()?["scopes"] as? [String] == ["operator.admin"])
            #expect(await channel.authSource() == .deviceToken)
            await channel.shutdown()

            let explicit = GatewayCoreFakeSession()
            let explicitChannel = try authChannel(
                url: "ws://gateway.example.com",
                session: explicit,
                options: gatewayCoreOptions(scopes: ["operator.read"], scopesAreExplicit: true, includeDeviceIdentity: true))
            try await explicitChannel.connect()
            #expect(explicit.latestSocket?.connectParams()?["scopes"] as? [String] == ["operator.read"])
            await explicitChannel.shutdown()
        }
    }

    @Test
    func scannedSetupCodePrefersBootstrapOverStoredTokenAndPasswordWins() async throws {
        try await withIsolatedDeviceState {
            let identity = try DeviceIdentityStore.loadOrCreatePersistedOrThrow(profile: .primary)
            store(deviceId: identity.deviceId, role: "operator", token: "stored-token")
            let session = GatewayCoreFakeSession()
            let channel = try authChannel(
                url: "ws://gateway.example.com",
                bootstrapToken: " fresh-bootstrap ",
                session: session,
                options: gatewayCoreOptions(includeDeviceIdentity: true))
            try await channel.connect()
            let auth = try #require(session.latestSocket?.connectAuth())
            #expect(auth["bootstrapToken"] as? String == "fresh-bootstrap")
            #expect(auth["token"] == nil)
            #expect(await channel.authSource() == .bootstrapToken)
            await channel.shutdown()

            let passwordSession = GatewayCoreFakeSession()
            let passwordChannel = try authChannel(
                url: "ws://gateway.example.com",
                bootstrapToken: "bootstrap",
                password: "secret",
                session: passwordSession,
                options: gatewayCoreOptions())
            try await passwordChannel.connect()
            #expect(passwordSession.latestSocket?.connectAuth() as? [String: String] == ["password": "secret"])
            await passwordChannel.shutdown()
        }
    }

    @Test
    func bootstrapHandoffPersistsBoundedTokensOnlyOnTrustedTransports() async throws {
        try await withIsolatedDeviceState {
            let identity = try DeviceIdentityStore.loadOrCreatePersistedOrThrow(profile: .primary)
            let hello: @Sendable () -> [String: Any] = {
                GatewayCoreFrames.hello(auth: [
                    "role": "operator",
                    "deviceToken": "operator-handoff",
                    "scopes": ["operator.admin", "operator.pairing", "operator.read"],
                    "deviceTokens": [
                        ["deviceToken": "node-handoff", "role": "node", "scopes": ["node.exec"]],
                    ],
                ])
            }
            let session = GatewayCoreFakeSession(fixedScript: GatewayCoreSocketScript(
                connectReply: { _ in .ok(hello()) }))
            let channel = try authChannel(
                url: "ws://192.168.1.20:18789",
                bootstrapToken: "setup-code",
                session: session,
                options: gatewayCoreOptions(
                    scopes: ["operator.admin", "operator.pairing", "operator.read"],
                    includeDeviceIdentity: true,
                    deviceAuthGatewayID: "gateway-lan"))
            try await channel.connect()

            #expect(session.latestSocket?.connectParams()?["scopes"] as? [String] == ["operator.admin", "operator.read"])
            let operatorEntry = storedToken(deviceId: identity.deviceId, role: "operator", gatewayID: "gateway-lan")
            #expect(operatorEntry?.token == "operator-handoff")
            #expect(operatorEntry?.scopes == ["operator.admin", "operator.read"])
            let nodeEntry = storedToken(deviceId: identity.deviceId, role: "node", gatewayID: "gateway-lan")
            #expect(nodeEntry?.token == "node-handoff")
            #expect(nodeEntry?.scopes == [])
            let roles = await channel.currentDeviceAuthRoles()
            #expect(roles.received == ["operator", "node"])
            #expect(roles.persisted == ["operator", "node"])
            await channel.shutdown()

            let untrusted = GatewayCoreFakeSession(fixedScript: GatewayCoreSocketScript(
                connectReply: { _ in .ok(hello()) }))
            let untrustedChannel = try authChannel(
                url: "ws://gateway.example.com",
                bootstrapToken: "setup-code",
                session: untrusted,
                options: gatewayCoreOptions(includeDeviceIdentity: true, deviceAuthGatewayID: "gateway-wan"))
            try await untrustedChannel.connect()
            #expect(storedToken(deviceId: identity.deviceId, role: "operator", gatewayID: "gateway-wan") == nil)
            #expect(await untrustedChannel.currentDeviceAuthRoles().persisted.isEmpty)
            await untrustedChannel.shutdown()
        }
    }

    @Test
    func reissuedStoredTokenKeepsItsReusableScopes() async throws {
        try await withIsolatedDeviceState {
            let identity = try DeviceIdentityStore.loadOrCreatePersistedOrThrow(profile: .primary)
            store(deviceId: identity.deviceId, role: "operator", token: "stable", scopes: ["operator.admin", "operator.read"])
            let session = GatewayCoreFakeSession(fixedScript: GatewayCoreSocketScript(
                connectReply: { _ in
                    .ok(GatewayCoreFrames.hello(auth: ["role": "operator", "deviceToken": "stable", "scopes": ["operator.read"]]))
                }))
            let channel = try authChannel(
                url: "wss://gateway.example.com",
                session: session,
                options: gatewayCoreOptions(includeDeviceIdentity: true))
            try await channel.connect()
            #expect(storedToken(deviceId: identity.deviceId, role: "operator")?.scopes == ["operator.admin", "operator.read"])
            await channel.shutdown()
        }
    }

    @Test
    func storedDeviceTokenNeverCrossesGatewayOwners() async throws {
        try await withIsolatedDeviceState {
            let identity = try DeviceIdentityStore.loadOrCreatePersistedOrThrow(profile: .primary)
            store(deviceId: identity.deviceId, role: "node", token: "gateway-a-token", gatewayID: "gateway-a")
            let session = GatewayCoreFakeSession()
            let channel = try authChannel(
                url: "ws://gateway-b.example.com",
                session: session,
                options: gatewayCoreOptions(role: "node", scopes: [], includeDeviceIdentity: true, deviceAuthGatewayID: "gateway-b"))
            try await channel.connect()
            #expect(session.latestSocket?.connectAuth()?["token"] == nil)
            #expect(storedToken(deviceId: identity.deviceId, role: "node", gatewayID: "gateway-a")?.token == "gateway-a-token")
            await channel.shutdown()
        }
    }

    @Test
    func ownerlessHandoffNeitherReusesNorPersistsTokens() async throws {
        try await withIsolatedDeviceState {
            let identity = try DeviceIdentityStore.loadOrCreatePersistedOrThrow(profile: .primary)
            store(deviceId: identity.deviceId, role: "node", token: "previous")
            let session = GatewayCoreFakeSession(fixedScript: GatewayCoreSocketScript(
                connectReply: { _ in
                    .ok(GatewayCoreFrames.hello(auth: ["deviceToken": "issued", "role": "node", "scopes": []]))
                }))
            let channel = try authChannel(
                url: "ws://new-gateway.example.com",
                session: session,
                options: gatewayCoreOptions(role: "node", scopes: [], includeDeviceIdentity: true, allowStoredDeviceAuth: false))
            try await channel.connect()
            #expect(session.latestSocket?.connectAuth()?.isEmpty != false)
            #expect(session.latestSocket?.connectParams()?["device"] != nil)
            let roles = await channel.currentDeviceAuthRoles()
            #expect(roles.received == ["node"])
            #expect(roles.persisted.isEmpty)
            #expect(storedToken(deviceId: identity.deviceId, role: "node")?.token == "previous")
            await channel.shutdown()
        }
    }

    @Test(arguments: [("ws://127.0.0.1:18789", true), ("ws://gateway.example.com", false)])
    func tokenMismatchRetriesWithTheStoredDeviceTokenOnlyOnTrustedHosts(url: String, retries: Bool) async throws {
        try await withIsolatedDeviceState {
            let identity = try DeviceIdentityStore.loadOrCreatePersistedOrThrow(profile: .primary)
            store(deviceId: identity.deviceId, role: "operator", token: "stored-device-token", scopes: ["operator.read"])
            let session = GatewayCoreFakeSession(script: { index in
                var script = GatewayCoreSocketScript()
                if index == 0 {
                    script.connectReply = { _ in
                        .error(GatewayCoreFrames.error(
                            code: "INVALID_REQUEST",
                            message: "token mismatch",
                            details: ["code": "AUTH_TOKEN_MISMATCH", "canRetryWithDeviceToken": true]))
                    }
                }
                return script
            })
            let channel = try authChannel(
                url: url,
                token: "explicit-token",
                session: session,
                options: gatewayCoreOptions(includeDeviceIdentity: true))
            await channel._test_setConnectFailureBackoffWaitHandler {}
            await #expect(throws: GatewayConnectAuthError.self) { try await channel.connect() }
            #expect(await channel._test_connectFailureBackoffDelayMs() == 1000)
            try await channel.connect()
            let auth = try #require(session.latestSocket?.connectAuth())
            #expect(auth["token"] as? String == "explicit-token")
            #expect((auth["deviceToken"] as? String == "stored-device-token") == retries)
            await channel.shutdown()
        }
    }

    @Test
    func deviceTokenMismatchClearsTheStaleStoredToken() async throws {
        try await withIsolatedDeviceState {
            let identity = try DeviceIdentityStore.loadOrCreatePersistedOrThrow(profile: .primary)
            store(deviceId: identity.deviceId, role: "operator", token: "stale-token")
            let session = GatewayCoreFakeSession(fixedScript: GatewayCoreSocketScript(
                connectReply: { _ in
                    .error(GatewayCoreFrames.error(
                        code: "INVALID_REQUEST",
                        message: "device token mismatch",
                        details: ["code": "AUTH_DEVICE_TOKEN_MISMATCH"]))
                }))
            let channel = try authChannel(
                url: "ws://gateway.example.com",
                session: session,
                options: gatewayCoreOptions(includeDeviceIdentity: true))
            await #expect(throws: GatewayConnectAuthError.self) { try await channel.connect() }
            #expect(storedToken(deviceId: identity.deviceId, role: "operator") == nil)
            await channel.shutdown()
        }
    }

    @Test
    func httpBearerAndAuthBindingFollowTheAcceptedSocket() async throws {
        let key = SymmetricKey(size: .bits256)
        let session = GatewayCoreFakeSession()
        let channel = try authChannel(
            url: "ws://gateway.example.com",
            token: "shared",
            authBindingKey: key,
            session: session,
            options: gatewayCoreOptions())
        try await channel.connect()
        let generation = try #require(await channel.currentConnectionGeneration())
        #expect(await channel.httpResourceBearer(ifCurrentConnectionGeneration: generation) == "shared")
        let binding = try #require(await channel.authBinding(ifCurrentConnectionGeneration: generation))
        #expect(binding.source == .sharedToken)
        let framed = ["shared-token", "", "token", "shared"].map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
        let expected = HMAC<SHA256>.authenticationCode(for: Data(framed.utf8), using: key)
            .map { String(format: "%02x", $0) }.joined()
        #expect(binding.credentialFingerprint == expected)
        #expect(await channel.httpResourceBearer(ifCurrentConnectionGeneration: generation &+ 1) == nil)
        await channel.shutdown()
        #expect(await channel.authBinding(ifCurrentConnectionGeneration: generation) == nil)

        let bootstrap = GatewayCoreFakeSession()
        let bootstrapChannel = try authChannel(
            url: "ws://gateway.example.com",
            bootstrapToken: "setup",
            session: bootstrap,
            options: gatewayCoreOptions())
        try await bootstrapChannel.connect()
        let bootstrapGeneration = try #require(await bootstrapChannel.currentConnectionGeneration())
        #expect(await bootstrapChannel.httpResourceBearer(ifCurrentConnectionGeneration: bootstrapGeneration) == nil)
        #expect(await bootstrapChannel.authBinding(ifCurrentConnectionGeneration: bootstrapGeneration)?
            .credentialFingerprint == nil)
        await bootstrapChannel.shutdown()
    }

    @Test
    func scopeMismatchPausesWithoutClearingTheToken() async throws {
        try await withIsolatedDeviceState {
            let identity = try DeviceIdentityStore.loadOrCreatePersistedOrThrow(profile: .primary)
            store(deviceId: identity.deviceId, role: "operator", token: "narrow-token", scopes: ["operator.read"])
            let session = GatewayCoreFakeSession(fixedScript: GatewayCoreSocketScript(
                connectReply: { _ in
                    .error(GatewayCoreFrames.error(
                        code: "INVALID_REQUEST",
                        message: "scope upgrade requires approval",
                        details: ["code": "AUTH_SCOPE_MISMATCH", "requestId": "req-9"]))
                }))
            let channel = try authChannel(
                url: "ws://gateway.example.com",
                session: session,
                options: gatewayCoreOptions(includeDeviceIdentity: true))
            do {
                try await channel.connect()
                Issue.record("expected a scope mismatch")
            } catch let error as GatewayConnectAuthError {
                #expect(error.detail == .authScopeMismatch)
                #expect(error.isNonRecoverable)
                #expect(GatewayConnectionProblemMapper.map(error: error)?.kind == .deviceTokenScopeMismatch)
            }
            #expect(storedToken(deviceId: identity.deviceId, role: "operator")?.token == "narrow-token")
            await channel.shutdown()
        }
    }

    private static func verify(signature: String, payload: String, publicKey: String) throws -> Bool {
        let base64 = signature
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = String(repeating: "=", count: (4 - base64.count % 4) % 4)
        let signatureData = try #require(Data(base64Encoded: base64 + padding))
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: try #require(Data(base64Encoded: publicKey)))
        return key.isValidSignature(signatureData, for: Data(payload.utf8))
    }
}
