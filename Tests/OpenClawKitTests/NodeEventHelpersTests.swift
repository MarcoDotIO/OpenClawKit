import Foundation
import Testing
@testable import OpenClawKit

struct NodePresenceAliveBeaconTests {
    @Test func `unknown triggers normalize to background`() {
        #expect(NodePresenceAliveBeacon.normalizeTrigger(" SILENT_PUSH ") == .silentPush)
        #expect(NodePresenceAliveBeacon.normalizeTrigger("bg_app_refresh") == .bgAppRefresh)
        #expect(NodePresenceAliveBeacon.normalizeTrigger("mystery") == .background)
    }

    @Test func `recent successes are skipped only while connected`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fiveMinutesAgo: Int64 = 1_800_000_000_000 - 5 * 60 * 1000
        let elevenMinutesAgo: Int64 = 1_800_000_000_000 - 11 * 60 * 1000
        #expect(NodePresenceAliveBeacon.shouldSkipRecentSuccess(
            isGatewayConnected: true, now: now, lastSuccessAtMs: fiveMinutesAgo))
        #expect(!NodePresenceAliveBeacon.shouldSkipRecentSuccess(
            isGatewayConnected: false, now: now, lastSuccessAtMs: fiveMinutesAgo))
        #expect(!NodePresenceAliveBeacon.shouldSkipRecentSuccess(
            isGatewayConnected: true, now: now, lastSuccessAtMs: elevenMinutesAgo))
        #expect(!NodePresenceAliveBeacon.shouldSkipRecentSuccess(
            isGatewayConnected: true, now: now, lastSuccessAtMs: nil))
    }

    @Test func `beacons wrap an Int64 payload in node.event params`() async throws {
        let payload = NodePresenceAliveBeacon.makePayload(
            trigger: .significantLocation,
            displayName: "Test Phone",
            pushTransport: "direct",
            now: Date(timeIntervalSince1970: 1_800_000_000.5))
        #expect(payload.sentAtMs == 1_800_000_000_500)
        #expect(payload.platform == InstanceIdentity.platformString)
        #expect(payload.deviceFamily == InstanceIdentity.deviceFamily)

        let sender = RecordingGatewaySender()
        sender.respond("node.event", json: #"{"ok":true,"event":"node.presence.alive","handled":true}"#)
        let result = try await NodePresenceAliveBeacon.send(payload, on: sender)
        #expect(result.handled)

        let paramsJSON = try #require(sender.lastCall?.paramsJSON)
        let params = try #require(JSONSerialization.jsonObject(with: Data(paramsJSON.utf8)) as? [String: String])
        #expect(params["event"] == "node.presence.alive")
        let inner = try JSONDecoder().decode(
            NodePresenceAliveBeacon.Payload.self,
            from: Data(try #require(params["payloadJSON"]).utf8))
        #expect(inner == payload)
        #expect(try #require(params["payloadJSON"]).contains(#""trigger":"significant_location""#))
    }
}

struct GatewayPushRegistrarTests {
    private let consent = GatewayPushConsent(disclosureAccepted: true, authorization: .authorized)

    @Test func `enrollment is consent gated and never logs tokens`() async {
        let sender = RecordingGatewaySender()
        let logs = LogRecorder()
        let registrar = GatewayPushRegistrar(node: sender, diagnostics: { logs.append($0) })

        let noDisclosure = await registrar.register(
            apnsTokenHex: "deadbeef",
            topic: "com.example.app",
            environment: .sandbox,
            consent: GatewayPushConsent(disclosureAccepted: false, authorization: .authorized),
            gatewayKey: "gw")
        #expect(noDisclosure == .skipped(.enrollmentDisclosureNotAccepted))

        let denied = await registrar.register(
            apnsTokenHex: "deadbeef",
            topic: "com.example.app",
            environment: .sandbox,
            consent: GatewayPushConsent(disclosureAccepted: true, authorization: .denied),
            gatewayKey: "gw")
        #expect(denied == .skipped(.notificationsNotAuthorized))

        let missingToken = await registrar.register(
            apnsTokenHex: " ",
            topic: "com.example.app",
            environment: .sandbox,
            consent: self.consent,
            gatewayKey: "gw")
        #expect(missingToken == .skipped(.missingAPNsToken))
        #expect(sender.sentEvents.isEmpty)
        #expect(logs.lines.allSatisfy { !$0.contains("deadbeef") })
        #expect(logs.lines.contains { $0.contains("enrollment_disclosure_not_accepted") })
    }

    @Test func `direct registrations publish once per gateway and token`() async throws {
        let sender = RecordingGatewaySender()
        let registrar = GatewayPushRegistrar(node: sender)
        let first = await registrar.register(
            apnsTokenHex: "abc123",
            topic: "com.example.app",
            environment: .production,
            consent: self.consent,
            gatewayKey: "gw-1")
        #expect(first == .registered(.direct))
        let repeated = await registrar.register(
            apnsTokenHex: "abc123",
            topic: "com.example.app",
            environment: .production,
            consent: self.consent,
            gatewayKey: "gw-1")
        #expect(repeated == .skipped(.unchanged))
        let newGateway = await registrar.register(
            apnsTokenHex: "abc123",
            topic: "com.example.app",
            environment: .production,
            consent: self.consent,
            gatewayKey: "gw-2")
        #expect(newGateway == .registered(.direct))

        #expect(sender.sentEvents.count == 2)
        let event = try #require(sender.sentEvents.first)
        #expect(event.event == "push.apns.register")
        let payload = try JSONDecoder().decode(
            DirectGatewayPushRegistrationPayload.self,
            from: Data(try #require(event.payloadJSON).utf8))
        #expect(payload == DirectGatewayPushRegistrationPayload(token: "abc123", topic: "com.example.app", environment: .production))
    }

    @Test func `offline node and relay without operator are skipped`() async {
        let offline = GatewayPushRegistrar(node: nil)
        #expect(await offline.register(
            apnsTokenHex: "abc",
            topic: "t",
            environment: .sandbox,
            consent: self.consent,
            gatewayKey: "gw") == .skipped(.gatewayOffline))

        let relay = GatewayPushRegistrar(node: RecordingGatewaySender(), transport: .relay)
        #expect(await relay.register(
            apnsTokenHex: "abc",
            topic: "t",
            environment: .sandbox,
            consent: self.consent,
            gatewayKey: "gw") == .skipped(.operatorOffline))
    }

    @Test func `relay registrations scope grants to the gateway identity`() async throws {
        struct FakeRelay: PushRelayClient {
            func register(
                apnsTokenHex: String,
                topic: String,
                environment: GatewayAPNsEnvironment,
                gatewayIdentity: GatewayRelayIdentity) async throws -> PushRelayRegistration
            {
                PushRelayRegistration(
                    relayHandle: "handle-\(gatewayIdentity.deviceId)",
                    sendGrant: "grant",
                    relayOrigin: "https://relay.example",
                    tokenSuffix: "3456")
            }
        }
        let node = RecordingGatewaySender()
        let operatorSender = RecordingGatewaySender()
        operatorSender.respond("gateway.identity.get", json: #"{"deviceId":"gw-9","publicKey":"pk"}"#)
        let registrar = GatewayPushRegistrar(
            node: node,
            transport: .relay,
            relayClient: FakeRelay(),
            operatorClient: GatewayOperatorClient(sender: operatorSender),
            installationId: "install-1")
        let outcome = await registrar.register(
            apnsTokenHex: "abc123456",
            topic: "com.example.app",
            environment: .production,
            consent: self.consent,
            gatewayKey: "gw-9")
        #expect(outcome == .registered(.relay))
        let payload = try JSONDecoder().decode(
            RelayGatewayPushRegistrationPayload.self,
            from: Data(try #require(node.sentEvents.first?.payloadJSON).utf8))
        #expect(payload.relayHandle == "handle-gw-9")
        #expect(payload.gatewayDeviceId == "gw-9")
        #expect(payload.installationId == "install-1")
        #expect(payload.transport == "relay")
    }

    @Test func `notification categories match the gateway vocabulary`() {
        #expect(OpenClawNotificationCategory.allCases.map(\.rawValue) == [
            "approval-requested",
            "agent-finished",
            "agent-question",
            "human-mentioned",
            "scheduled-task-failed",
            "background-task-failed",
        ])
    }
}

final class LogRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ line: String) {
        self.lock.withLock { self.storage.append(line) }
    }

    var lines: [String] {
        self.lock.withLock { self.storage }
    }
}

struct GatewayTerminalClientTests {
    @Test func `terminal events are filtered by session and end at exit`() async {
        let (frames, continuation) = AsyncStream<EventFrame>.makeStream()
        let events = GatewayTerminalClient.events(from: frames, sessionId: "term-1")
        continuation.yield(EventFrame(
            type: "event",
            event: "terminal.data",
            payload: AnyCodable(["sessionId": AnyCodable("term-2"), "seq": AnyCodable(1), "data": AnyCodable("x")])))
        continuation.yield(EventFrame(
            type: "event",
            event: "terminal.data",
            payload: AnyCodable(["sessionId": AnyCodable("term-1"), "seq": AnyCodable(2), "data": AnyCodable("hi")])))
        continuation.yield(EventFrame(type: "event", event: "chat", payload: nil))
        continuation.yield(EventFrame(
            type: "event",
            event: "terminal.exit",
            payload: AnyCodable(["sessionId": AnyCodable("term-1"), "exitCode": AnyCodable(0)])))
        continuation.yield(EventFrame(
            type: "event",
            event: "terminal.data",
            payload: AnyCodable(["sessionId": AnyCodable("term-1"), "seq": AnyCodable(3), "data": AnyCodable("late")])))

        var received: [String] = []
        for await event in events {
            switch event {
            case let .data(data): received.append("data:\(data.data)")
            case .exit: received.append("exit")
            }
        }
        #expect(received == ["data:hi", "exit"])
        continuation.finish()
    }

    @Test func `terminal availability follows advertised methods`() {
        #expect(GatewayTerminalClient.isAvailable(advertisedMethods: ["terminal.open", "terminal.input", "chat.send"]))
        #expect(!GatewayTerminalClient.isAvailable(advertisedMethods: ["chat.send"]))
    }

    @Test func `terminal uploads send base64 content`() async throws {
        let sender = RecordingGatewaySender()
        sender.respond("terminal.upload", json: #"{"path":"/tmp/a.txt","size":2}"#)
        let result = try await GatewayTerminalClient(sender: sender).upload(
            sessionId: "t",
            name: "a.txt",
            contents: Data("hi".utf8))
        #expect(result.path == "/tmp/a.txt")
        #expect(sender.lastCall?.params?["contentBase64"]?.stringValue == "aGk=")
    }

    @Test func `workspace file previews decode by encoding`() throws {
        let text = try JSONDecoder().decode(AgentsWorkspaceFile.self, from: Data(#"""
        {"path":"a.md","name":"a.md","size":2,"updatedAtMs":1,"mimeType":"text/markdown","encoding":"utf8","content":"hi"}
        """#.utf8))
        #expect(GatewayWorkspaceFilesClient.contentData(of: text) == Data("hi".utf8))
        let binary = try JSONDecoder().decode(AgentsWorkspaceFile.self, from: Data(#"""
        {"path":"a.bin","name":"a.bin","size":2,"updatedAtMs":1,"mimeType":"application/octet-stream","encoding":"base64","content":"aGk="}
        """#.utf8))
        #expect(GatewayWorkspaceFilesClient.contentData(of: binary) == Data("hi".utf8))
    }
}
