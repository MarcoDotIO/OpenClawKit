import CryptoKit
import Foundation
import OpenClawProtocol
import Testing
@testable import OpenClawKit

struct WatchNodeContractsTests {
    static let watchClient = OpenClawWatchNodeClientInfo(
        displayName: "Test Watch",
        version: "1.0.0",
        platform: "watchOS 11.5.0",
        deviceFamily: "Apple Watch",
        instanceId: "watch-test")

    static func setupCode(
        url: String = "wss://gateway.example.com",
        urls: [String] = [],
        bootstrapToken: String? = "bootstrap-1",
        token: String? = nil) -> String
    {
        var object: [String: Any] = ["url": url]
        if !urls.isEmpty { object["urls"] = urls }
        if let bootstrapToken { object["bootstrapToken"] = bootstrapToken }
        if let token { object["token"] = token }
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(bytes: data, encoding: .utf8)!
    }

    @Test func `endpoints and limits match the gateway transport`() {
        let base = URL(string: "https://gateway.example.com:8443/openclaw")!
        #expect(OpenClawWatchNodeHTTP.url(for: .poll, baseURL: base).absoluteString ==
            "https://gateway.example.com:8443/openclaw/api/nodes/watch/poll")
        #expect(OpenClawWatchNodeHTTP.Endpoint.challenge.method == "GET")
        #expect(OpenClawWatchNodeHTTP.Endpoint.allCases.filter { $0.method == "POST" }.count == 4)
        #expect(OpenClawWatchNodeHTTP.Endpoint.result.path == "/api/nodes/watch/result")
        #expect(OpenClawWatchNodeHTTP.Endpoint.poll.requestTimeout > TimeInterval(OpenClawWatchNodeHTTP.pollTimeoutMs) / 1000)
        #expect(OpenClawWatchNodeHTTP.allowedCommands == ["device.info", "device.status", "system.notify"])
        #expect(OpenClawWatchNodeHTTP.isBoundedSurface(
            caps: [], commands: ["device.info"], permissions: ["notifications"]))
        #expect(!OpenClawWatchNodeHTTP.isBoundedSurface(caps: ["camera"], commands: ["device.info"], permissions: []))
        #expect(!OpenClawWatchNodeHTTP.isBoundedSurface(caps: [], commands: ["system.run"], permissions: []))
        #expect(!OpenClawWatchNodeHTTP.isBoundedSurface(caps: [], commands: [], permissions: []))
        #expect(!OpenClawWatchNodeHTTP.isBoundedSurface(
            caps: [], commands: ["device.info"], permissions: ["location"]))
    }

    @Test(.stateDirectoryIsolated)
    func `connect body is a signed v3 node proof over the challenge time`() throws {
        let identity = try DeviceIdentityStore.loadOrCreatePersistedOrThrow(profile: .primary)
        let challenge = try JSONDecoder().decode(
            OpenClawWatchNodeChallenge.self,
            from: Data(#"{"ok":true,"nonce":"nonce-1","ts":1800000000123,"expiresAtMs":1800000060123}"#.utf8))
        let request = try OpenClawWatchNodeConnectRequest.signed(
            identity: identity,
            challenge: challenge,
            credential: .bootstrap("bootstrap-1"),
            client: Self.watchClient,
            notificationsAuthorized: true,
            fallbackNowMs: 1,
            locale: "en-US",
            userAgent: "watchOS test")
        let data = try JSONEncoder().encode(request)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == [
            "minProtocol", "maxProtocol", "client", "caps", "commands", "permissions", "role", "scopes",
            "device", "auth", "locale", "userAgent",
        ])
        #expect(object["minProtocol"] as? Int == GATEWAY_MIN_PROTOCOL_VERSION)
        #expect(object["maxProtocol"] as? Int == GATEWAY_PROTOCOL_VERSION)
        #expect(object["role"] as? String == "node")
        #expect((object["caps"] as? [String])?.isEmpty == true)
        #expect((object["scopes"] as? [String])?.isEmpty == true)
        #expect(object["commands"] as? [String] == OpenClawWatchNodeHTTP.allowedCommands)
        #expect(object["permissions"] as? [String: Bool] == ["notifications": true])
        #expect(object["auth"] as? [String: String] == ["bootstrapToken": "bootstrap-1"])
        let client = try #require(object["client"] as? [String: Any])
        #expect(client["id"] as? String == "openclaw-watchos")
        #expect(client["mode"] as? String == "node")
        #expect(client["deviceFamily"] as? String == "Apple Watch")
        #expect(client["modelIdentifier"] == nil)
        let device = try #require(object["device"] as? [String: Any])
        #expect(Set(device.keys) == ["id", "publicKey", "signature", "signedAt", "nonce"])
        #expect((device["signedAt"] as? NSNumber)?.int64Value == Int64(1_800_000_000_123))
        #expect(String(bytes: data, encoding: .utf8)?.contains("\"signedAt\":1800000000123") == true)
        #expect(device["id"] as? String == identity.deviceId)

        let payload = OpenClawWatchNodeConnectRequest.signaturePayload(
            deviceId: identity.deviceId,
            client: Self.watchClient,
            signedAtMs: Int64(1_800_000_000_123),
            credential: .bootstrap("bootstrap-1"),
            nonce: "nonce-1")
        #expect(payload == "v3|\(identity.deviceId)|openclaw-watchos|node|node||1800000000123|bootstrap-1|nonce-1|" +
            "watchos 11.5.0|apple watch")
        let publicKey = try Curve25519.Signing.PublicKey(
            rawRepresentation: #require(Self.base64URLDecode(device["publicKey"] as? String)))
        let signature = try #require(Self.base64URLDecode(device["signature"] as? String))
        #expect(publicKey.isValidSignature(signature, for: Data(payload.utf8)))

        let deviceRequest = try OpenClawWatchNodeConnectRequest.signed(
            identity: identity,
            challenge: OpenClawWatchNodeChallenge(nonce: "nonce-2", ts: nil),
            credential: .device("device-token"),
            client: Self.watchClient,
            notificationsAuthorized: false,
            fallbackNowMs: 42)
        #expect(deviceRequest.auth == ["deviceToken": "device-token"])
        #expect(deviceRequest.device.signedAt == 42)
        #expect(deviceRequest.permissions == ["notifications": false])
    }

    @Test func `challenge responses reject empty nonces and negative times`() throws {
        let legacy = try JSONDecoder().decode(OpenClawWatchNodeChallenge.self, from: Data(#"{"nonce":"n"}"#.utf8))
        #expect(legacy.ts == nil)
        #expect(legacy.signingTimeMs(fallbackNowMs: 7) == 7)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(OpenClawWatchNodeChallenge.self, from: Data(#"{"nonce":"n","ts":-1}"#.utf8))
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(OpenClawWatchNodeChallenge.self, from: Data(#"{"nonce":""}"#.utf8))
        }
    }

    @Test func `connect responses accept only the bounded voice grant`() throws {
        let plain = try JSONDecoder().decode(OpenClawWatchNodeConnectResponse.self, from: Data("""
        {"ok":true,"sessionToken":"s","deviceToken":"d","nodeId":"node","protocol":4,"pollTimeoutMs":20000}
        """.utf8))
        #expect(plain.voiceCredential == nil)
        #expect(plain.nodeId == "node")
        #expect(plain.protocolVersion == 4)
        #expect(plain.pollTimeoutMs == 20000)

        let voice = try JSONDecoder().decode(OpenClawWatchNodeConnectResponse.self, from: Data("""
        {"sessionToken":"s","deviceToken":"d","deviceTokens":[{"deviceToken":"op","role":"operator",
        "scopes":["operator.talk","operator.read"],"issuedAtMs":1800000000000}]}
        """.utf8))
        #expect(voice.voiceCredential?.deviceToken == "op")
        #expect(voice.voiceCredential?.issuedAtMs == Int64(1_800_000_000_000))

        for invalid in [
            #"{"sessionToken":"","deviceToken":"d"}"#,
            #"{"sessionToken":"s","deviceToken":"d","deviceTokens":[]}"#,
            #"{"sessionToken":"s","deviceToken":"d","deviceTokens":[{"deviceToken":"op","role":"operator","scopes":["operator.admin"]}]}"#,
            #"{"sessionToken":"s","deviceToken":"d","deviceTokens":[{"deviceToken":"op","role":"node","scopes":["operator.read","operator.talk"]}]}"#,
        ] {
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(OpenClawWatchNodeConnectResponse.self, from: Data(invalid.utf8))
            }
        }
    }

    @Test func `polls decode idle, invoke, and unrelated events`() throws {
        let idle = try JSONDecoder().decode(OpenClawWatchNodePollResponse.self, from: Data(#"{"ok":true,"event":null}"#.utf8))
        #expect(idle.event == nil)
        let invoke = try JSONDecoder().decode(OpenClawWatchNodePollResponse.self, from: Data("""
        {"ok":true,"event":{"event":"node.invoke.request","payload":{"id":"i1","nodeId":"n","command":"device.info",
        "paramsJSON":null,"timeoutMs":30000,"idempotencyKey":"k","sessionKey":"main"}}}
        """.utf8))
        let request = try #require(invoke.event?.invokeRequest)
        #expect(request.id == "i1")
        #expect(request.timeoutMs == 30000)
        #expect(request.bridgeRequest.command == "device.info")
        #expect(request.bridgeRequest.timeoutMs == 30000)
        #expect(request.bridgeRequest.sessionKey == "main")
        let other = try JSONDecoder().decode(OpenClawWatchNodePollResponse.self, from: Data("""
        {"ok":true,"event":{"event":"node.invoke.cancel","payload":{"invokeId":"i1","nodeId":"n"}}}
        """.utf8))
        #expect(other.event?.event == "node.invoke.cancel")
        #expect(other.event?.invokeRequest == nil)
    }

    @Test func `invoke results map payloads and node errors`() throws {
        let structured = try OpenClawWatchNodeInvokeResult(response: BridgeInvokeResponse(
            id: "i1", ok: true, payload: AnyCodable(["battery": AnyCodable(0.5)])))
        #expect(structured.payloadJSON == #"{"battery":0.5}"#)
        let failure = try OpenClawWatchNodeInvokeResult(response: BridgeInvokeResponse(
            id: "i2",
            ok: false,
            error: OpenClawNodeError(code: .invalidRequest, message: "INVALID_REQUEST: nope")))
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(failure)) as? [String: Any])
        #expect(object["id"] as? String == "i2")
        #expect(object["ok"] as? Bool == false)
        #expect(object["error"] as? [String: String] == ["code": "INVALID_REQUEST", "message": "INVALID_REQUEST: nope"])
        #expect(object["payloadJSON"] == nil)
    }

    @Test func `configuration keeps only trusted https endpoints and a bootstrap credential`() throws {
        let setup = OpenClawWatchNodeSetupMessage(
            setupCode: Self.setupCode(
                url: "wss://Gateway.Example.com:8443/claw",
                urls: ["ws://192.168.1.2:18789", "wss://backup.example.com"]),
            sentAtMs: 1000)
        let configuration = try #require(OpenClawWatchNodeConfiguration(setup: setup))
        #expect(configuration.gatewayID == "watch-direct:https://gateway.example.com:8443/claw")
        #expect(configuration.httpsBaseURLs.map(\.absoluteString) == [
            "https://Gateway.Example.com:8443/claw",
            "https://backup.example.com:443",
        ])
        #expect(configuration.voiceWebSocketURLs.map(\.absoluteString) == [
            "wss://Gateway.Example.com:8443/claw",
            "wss://backup.example.com:443",
        ])
        #expect(configuration.hasBootstrapCredential)
        #expect(configuration.setupSentAtMs == 1000)
        let sanitized = configuration.withoutBootstrapToken()
        #expect(!sanitized.hasBootstrapCredential)
        #expect(sanitized.isSameInstallation(as: configuration))
        #expect(sanitized.httpsBaseURLs == configuration.httpsBaseURLs)
        let restored = try JSONDecoder().decode(
            OpenClawWatchNodeConfiguration.self, from: JSONEncoder().encode(sanitized))
        #expect(restored == sanitized)

        #expect(OpenClawWatchNodeConfiguration(setup: .init(
            setupCode: Self.setupCode(url: "ws://192.168.1.2:18789"), sentAtMs: 1)) == nil)
        #expect(OpenClawWatchNodeConfiguration(setup: .init(
            setupCode: Self.setupCode(bootstrapToken: nil), sentAtMs: 1)) == nil)
        #expect(OpenClawWatchNodeConfiguration(setup: .init(
            setupCode: Self.setupCode(token: "shared"), sentAtMs: 1)) == nil)
        #expect(OpenClawWatchNodeConfiguration(setup: .init(setupCode: "garbage", sentAtMs: 1)) == nil)
    }

    @Test func `setup messages are accepted only inside the freshness window`() {
        let now = Int64(1_800_000_000_000)
        #expect(OpenClawWatchNodeSetupMessage(setupCode: "c", sentAtMs: now).isFresh(nowMs: now))
        #expect(OpenClawWatchNodeSetupMessage(setupCode: "c", sentAtMs: now - 12 * 60 * 1000).isFresh(nowMs: now))
        #expect(!OpenClawWatchNodeSetupMessage(setupCode: "c", sentAtMs: now - 12 * 60 * 1000 - 1).isFresh(nowMs: now))
        #expect(OpenClawWatchNodeSetupMessage(setupCode: "c", sentAtMs: now + 2 * 60 * 1000).isFresh(nowMs: now))
        #expect(!OpenClawWatchNodeSetupMessage(setupCode: "c", sentAtMs: now + 2 * 60 * 1000 + 1).isFresh(nowMs: now))
        #expect(!OpenClawWatchNodeSetupMessage(setupCode: "c", sentAtMs: 0).isFresh(nowMs: Int64.max))
    }

    @Test func `router serves the fixed surface and rejects everything else`() async throws {
        let notifier = RecordingWatchNotifier(allowed: true)
        let router = Self.router(notifier: notifier)
        let info = await router.handle(BridgeInvokeRequest(id: "1", command: "device.info"))
        #expect(info.ok)
        let decodedInfo = try JSONDecoder().decode(
            OpenClawDeviceInfoPayload.self, from: Data(#require(info.payloadJSON).utf8))
        #expect(decodedInfo.systemName == "watchOS")
        let status = await router.handle(BridgeInvokeRequest(id: "2", command: "device.status"))
        #expect(status.ok && status.payloadJSON?.contains("\"battery\"") == true)

        let notify = await router.handle(BridgeInvokeRequest(
            id: "3",
            command: "system.notify",
            paramsJSON: #"{"title":"  Hi ","body":"There","sound":"Silent","priority":"timeSensitive"}"#))
        #expect(notify.ok)
        #expect(await notifier.posted == [.init(title: "Hi", body: "There", priority: .timeSensitive, playsSound: false)])

        let empty = await router.handle(BridgeInvokeRequest(
            id: "4", command: "system.notify", paramsJSON: #"{"title":" ","body":""}"#))
        #expect(empty.error?.code == .invalidRequest)
        let unsupported = await router.handle(BridgeInvokeRequest(id: "5", command: "system.run"))
        #expect(unsupported.error == OpenClawNodeError(
            code: .invalidRequest, message: "INVALID_REQUEST: unsupported watchOS command"))
        let malformed = await router.handle(BridgeInvokeRequest(id: "6", command: "system.notify", paramsJSON: "[]"))
        #expect(malformed.error?.code == .unavailable)

        let denied = Self.router(notifier: RecordingWatchNotifier(allowed: false))
        let blocked = await denied.handle(BridgeInvokeRequest(
            id: "7", command: "system.notify", paramsJSON: #"{"title":"Hi","body":""}"#))
        #expect(blocked.error == OpenClawNodeError(code: .unavailable, message: "NOT_AUTHORIZED: notifications"))
        #expect(await denied.notificationsAuthorized() == false)
    }

    static func router(notifier: RecordingWatchNotifier) -> OpenClawWatchNodeCommandRouter {
        OpenClawWatchNodeCommandRouter(
            deviceInfo: {
                OpenClawDeviceInfoPayload(
                    deviceName: "Watch",
                    modelIdentifier: "Watch7,1",
                    systemName: "watchOS",
                    systemVersion: "27.0",
                    appVersion: "1.0",
                    appBuild: "1",
                    locale: "en-US")
            },
            deviceStatus: {
                OpenClawDeviceStatusPayload(
                    battery: .init(level: 0.5, state: .unplugged, lowPowerModeEnabled: false, levelPercent: 50),
                    thermal: .init(state: .nominal),
                    storage: .init(totalBytes: 100, freeBytes: 40, usedBytes: 60),
                    network: .init(status: .satisfied, isExpensive: false, isConstrained: false, interfaces: [.other]),
                    uptimeSeconds: 12)
            },
            notifier: notifier)
    }

    static func base64URLDecode(_ value: String?) -> Data? {
        guard var value else { return nil }
        value = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while value.count % 4 != 0 { value += "=" }
        return Data(base64Encoded: value)
    }
}

actor RecordingWatchNotifier: OpenClawWatchNodeNotifying {
    struct Posted: Equatable {
        let title: String
        let body: String
        let priority: OpenClawNotificationPriority
        let playsSound: Bool
    }

    let allowed: Bool
    private(set) var posted: [Posted] = []

    init(allowed: Bool) {
        self.allowed = allowed
    }

    func allowsPosting() async -> Bool {
        self.allowed
    }

    func post(title: String, body: String, priority: OpenClawNotificationPriority, playsSound: Bool) async throws {
        self.posted.append(Posted(title: title, body: body, priority: priority, playsSound: playsSound))
    }
}
