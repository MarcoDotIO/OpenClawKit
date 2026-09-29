import Foundation
import Testing
@testable import OpenClawKit

/// In-memory stand-in for `src/gateway/watch-node-http.ts`: one-time bootstrap redemption, device-token
/// reconnects, long polls that wait for queued events, and session invalidation.
private actor FakeWatchNodeGateway: OpenClawWatchNodeHTTPTransport {
    struct Recorded: Sendable {
        let endpoint: String
        let authorization: String?
        let body: [String: any Sendable]?
    }

    static let challengeTs = Int64(1_800_000_000_123)

    private var bootstrapTokens: Set<String>
    private let voiceGrant: Bool
    private var issuedDeviceTokens: Set<String>
    private var sessions: Set<String> = []
    private var sessionCounter = 0
    private var queue: [String] = []
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private(set) var recorded: [Recorded] = []

    init(bootstrapTokens: Set<String>, deviceTokens: Set<String> = [], voiceGrant: Bool = false) {
        self.bootstrapTokens = bootstrapTokens
        self.issuedDeviceTokens = deviceTokens
        self.voiceGrant = voiceGrant
    }

    func enqueueInvoke(id: String, command: String, paramsJSON: String? = nil) {
        var payload: [String: Any] = ["id": id, "nodeId": "watch-node", "command": command, "timeoutMs": 30000]
        if let paramsJSON { payload["paramsJSON"] = paramsJSON }
        let event: [String: Any] = ["event": "node.invoke.request", "payload": payload]
        let data = try! JSONSerialization.data(withJSONObject: event)
        self.queue.append(String(bytes: data, encoding: .utf8)!)
        self.wakeWaiters()
    }

    func invalidateSessions() {
        self.sessions.removeAll()
        self.wakeWaiters()
    }

    func revokeDeviceTokens() {
        self.issuedDeviceTokens.removeAll()
    }

    func records(_ endpoint: String) -> [Recorded] {
        self.recorded.filter { $0.endpoint == endpoint }
    }

    nonisolated func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await self.handle(request)
    }

    private func handle(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        #expect(url.scheme == "https")
        let endpoint = url.lastPathComponent
        let authorization = request.value(forHTTPHeaderField: "Authorization")
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        self.recorded.append(Recorded(
            endpoint: endpoint,
            authorization: authorization,
            body: body.map(Self.sendable)))
        switch endpoint {
        case "challenge":
            #expect(request.httpMethod == "GET")
            return Self.json(#"{"ok":true,"nonce":"nonce-\#(self.recorded.count)","ts":\#(Self.challengeTs)}"#, url: url)
        case "connect":
            return self.connect(body: body ?? [:], url: url)
        case "poll":
            guard let token = Self.bearer(authorization), self.sessions.contains(token) else {
                return Self.json(#"{"ok":false,"error":"unauthorized"}"#, url: url, status: 401)
            }
            while self.queue.isEmpty {
                try Task.checkCancellation()
                await self.waitForChange()
                guard self.sessions.contains(token) else {
                    return Self.json(#"{"ok":false,"reason":"session invalidated"}"#, url: url, status: 401)
                }
            }
            return Self.json(#"{"ok":true,"event":\#(self.queue.removeFirst())}"#, url: url)
        case "result", "disconnect":
            guard let token = Self.bearer(authorization), self.sessions.contains(token) else {
                return Self.json(#"{"ok":false}"#, url: url, status: 401)
            }
            if endpoint == "disconnect" { self.sessions.remove(token) }
            return Self.json(#"{"ok":true}"#, url: url)
        default:
            return Self.json(#"{"ok":false,"error":"not found"}"#, url: url, status: 404)
        }
    }

    private func connect(body: [String: Any], url: URL) -> (Data, HTTPURLResponse) {
        let auth = body["auth"] as? [String: String] ?? [:]
        let device = body["device"] as? [String: Any] ?? [:]
        guard (device["signedAt"] as? NSNumber)?.int64Value == Self.challengeTs else {
            return Self.json(#"{"ok":false}"#, url: url, status: 401)
        }
        var voice = ""
        if let bootstrap = auth["bootstrapToken"], self.bootstrapTokens.remove(bootstrap) != nil {
            if self.voiceGrant {
                voice = #","deviceTokens":[{"deviceToken":"operator-token","role":"operator","#
                    + #""scopes":["operator.read","operator.talk"],"issuedAtMs":1800000000000}]"#
            }
        } else if let deviceToken = auth["deviceToken"], self.issuedDeviceTokens.contains(deviceToken) {
            // Reconnect with the issued device token.
        } else {
            return Self.json(#"{"ok":false,"error":"unauthorized"}"#, url: url, status: 401)
        }
        self.sessionCounter += 1
        let session = "session-\(self.sessionCounter)"
        self.sessions.insert(session)
        self.issuedDeviceTokens.insert("node-token")
        return Self.json(
            #"{"ok":true,"sessionToken":"\#(session)","deviceToken":"node-token","nodeId":"watch-node","protocol":4,"#
                + #""pollTimeoutMs":20000\#(voice)}"#,
            url: url)
    }

    private func waitForChange() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    self.waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.resumeWaiter(id) }
        }
    }

    private func resumeWaiter(_ id: UUID) {
        self.waiters.removeValue(forKey: id)?.resume()
    }

    private func wakeWaiters() {
        let waiters = self.waiters
        self.waiters.removeAll()
        for waiter in waiters.values {
            waiter.resume()
        }
    }

    private static func bearer(_ header: String?) -> String? {
        guard let header, header.hasPrefix("Bearer ") else { return nil }
        return String(header.dropFirst("Bearer ".count))
    }

    private static func json(_ body: String, url: URL, status: Int = 200) -> (Data, HTTPURLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }

    private static func sendable(_ object: [String: Any]) -> [String: any Sendable] {
        object.mapValues { value -> any Sendable in
            switch value {
            case let nested as [String: Any]: Self.sendable(nested)
            case let string as String: string
            case let number as NSNumber: number.int64Value
            case let array as [Any]: array.map { String(describing: $0) }
            default: String(describing: value)
            }
        }
    }
}

private final class InMemoryWatchNodeConfigurationStore: OpenClawWatchNodeConfigurationStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var configuration: OpenClawWatchNodeConfiguration?
    private var lastAccepted: Int64 = 0

    func loadConfiguration() -> OpenClawWatchNodeConfiguration? {
        self.lock.withLock { self.configuration }
    }

    func saveConfiguration(_ configuration: OpenClawWatchNodeConfiguration) -> Bool {
        self.lock.withLock { self.configuration = configuration }
        return true
    }

    func deleteConfiguration() {
        self.lock.withLock { self.configuration = nil }
    }

    func lastAcceptedSetupSentAtMs() -> Int64 {
        self.lock.withLock { self.lastAccepted }
    }

    func saveLastAcceptedSetupSentAtMs(_ sentAtMs: Int64) {
        self.lock.withLock { self.lastAccepted = sentAtMs }
    }
}

@Suite(.serialized)
struct WatchNodeClientTests {
    private static let nowMs = Int64(1_800_000_000_000)

    private static func makeClient(
        gateway: FakeWatchNodeGateway,
        store: InMemoryWatchNodeConfigurationStore = InMemoryWatchNodeConfigurationStore()) -> OpenClawWatchNodeClient
    {
        OpenClawWatchNodeClient(
            handler: WatchNodeContractsTests.router(notifier: RecordingWatchNotifier(allowed: true)),
            store: store,
            transport: gateway,
            clientInfo: { WatchNodeContractsTests.watchClient },
            retryDelay: .milliseconds(20),
            now: { Self.nowMs })
    }

    private static func setup(bootstrapToken: String = "bootstrap-1", sentAtMs: Int64 = Self.nowMs)
        -> OpenClawWatchNodeSetupMessage
    {
        OpenClawWatchNodeSetupMessage(
            setupCode: WatchNodeContractsTests.setupCode(
                url: "wss://gateway.example.com/claw",
                bootstrapToken: bootstrapToken),
            sentAtMs: sentAtMs)
    }

    private static func eventually(
        timeout: Duration = .seconds(5),
        _ condition: @Sendable () async -> Bool) async -> Bool
    {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    @Test(.stateDirectoryIsolated)
    func `bootstrap pairing stores the node token and answers invokes`() async throws {
        let gateway = FakeWatchNodeGateway(bootstrapTokens: ["bootstrap-1"])
        let store = InMemoryWatchNodeConfigurationStore()
        let client = Self.makeClient(gateway: gateway, store: store)
        #expect(await client.state == .notConfigured)
        let configuration = try await client.install(Self.setup())
        #expect(configuration.gatewayID == "watch-direct:https://gateway.example.com:443/claw")
        #expect(await client.state == .idle)

        await client.start()
        #expect(await Self.eventually { await client.isConnected })
        let connect = try #require(await gateway.records("connect").first?.body)
        #expect(connect["auth"] as? [String: any Sendable] != nil)
        #expect((connect["auth"] as? [String: any Sendable])?["bootstrapToken"] as? String == "bootstrap-1")
        #expect((connect["device"] as? [String: any Sendable])?["signedAt"] as? Int64 == FakeWatchNodeGateway.challengeTs)
        #expect((connect["client"] as? [String: any Sendable])?["id"] as? String == "openclaw-watchos")

        // The one-time credential is gone from the saved configuration once the device token is durable.
        #expect(store.loadConfiguration()?.hasBootstrapCredential == false)
        let identity = try DeviceIdentityStore.loadOrCreatePersistedOrThrow(profile: .primary)
        #expect(DeviceAuthStore.loadToken(
            deviceId: identity.deviceId, role: "node", gatewayID: configuration.gatewayID)?.token == "node-token")
        #expect(await client.voiceAccess() == nil)

        await gateway.enqueueInvoke(id: "invoke-1", command: "device.info")
        #expect(await Self.eventually { await gateway.records("result").count == 1 })
        let result = try #require(await gateway.records("result").first)
        #expect(result.authorization == "Bearer session-1")
        #expect(result.body?["id"] as? String == "invoke-1")
        #expect(result.body?["ok"] as? Int64 == 1)
        #expect((result.body?["payloadJSON"] as? String)?.contains("\"systemName\":\"watchOS\"") == true)

        await gateway.enqueueInvoke(id: "invoke-2", command: "system.run")
        #expect(await Self.eventually { await gateway.records("result").count == 2 })
        let rejected = try #require(await gateway.records("result").last?.body)
        #expect((rejected["error"] as? [String: any Sendable])?["code"] as? String == "INVALID_REQUEST")

        await client.stop()
        #expect(await Self.eventually { await gateway.records("disconnect").count == 1 })
        #expect(await gateway.records("disconnect").first?.authorization == "Bearer session-1")
        #expect(await client.state == .idle)
    }

    @Test(.stateDirectoryIsolated)
    func `an invalidated session reconnects with the device token`() async throws {
        let gateway = FakeWatchNodeGateway(bootstrapTokens: ["bootstrap-1"])
        let client = Self.makeClient(gateway: gateway)
        try await client.install(Self.setup())
        await client.start()
        #expect(await Self.eventually { await client.isConnected })

        await gateway.invalidateSessions()
        #expect(await Self.eventually { await gateway.records("connect").count == 2 })
        #expect(await Self.eventually { await client.isConnected })
        let reconnect = try #require(await gateway.records("connect").last?.body)
        #expect((reconnect["auth"] as? [String: any Sendable])?.keys.sorted() == ["deviceToken"])
        #expect((reconnect["auth"] as? [String: any Sendable])?["deviceToken"] as? String == "node-token")

        await gateway.enqueueInvoke(id: "after-reconnect", command: "device.status")
        #expect(await Self.eventually { await gateway.records("result").count == 1 })
        #expect(await gateway.records("result").first?.authorization == "Bearer session-2")

        // A revoked device keeps failing visibly instead of reusing the consumed bootstrap token.
        await gateway.revokeDeviceTokens()
        await gateway.invalidateSessions()
        #expect(await Self.eventually {
            if case .waitingToRetry = await client.state { return true }
            return false
        })
        await client.stop()
    }

    @Test(.stateDirectoryIsolated)
    func `a foreground restart right after stop reconnects once`() async throws {
        let gateway = FakeWatchNodeGateway(bootstrapTokens: ["bootstrap-1"])
        let client = Self.makeClient(gateway: gateway)
        try await client.install(Self.setup())
        await client.start()
        #expect(await Self.eventually { await client.isConnected })
        await client.stop()
        await client.start()
        #expect(await Self.eventually { await gateway.records("connect").count == 2 })
        #expect(await Self.eventually { await client.isConnected })
        await gateway.enqueueInvoke(id: "after-restart", command: "device.info")
        #expect(await Self.eventually { await gateway.records("result").count == 1 })
        #expect(await gateway.records("result").first?.authorization == "Bearer session-2")
        #expect(await gateway.records("connect").count == 2)
        await client.stop()
    }

    @Test(.stateDirectoryIsolated)
    func `a consumed bootstrap falls back to the stored device token`() async throws {
        let gateway = FakeWatchNodeGateway(bootstrapTokens: [], deviceTokens: ["stored-token"])
        let client = Self.makeClient(gateway: gateway)
        let configuration = try await client.install(Self.setup())
        let identity = try DeviceIdentityStore.loadOrCreatePersistedOrThrow(profile: .primary)
        #expect(DeviceAuthStore.storeTokenPersisted(
            deviceId: identity.deviceId, role: "node", token: "stored-token", gatewayID: configuration.gatewayID))

        await client.start()
        #expect(await Self.eventually { await client.isConnected })
        let attempts = await gateway.records("connect").compactMap {
            ($0.body?["auth"] as? [String: any Sendable])?.keys.first
        }
        #expect(attempts == ["bootstrapToken", "deviceToken"])
        await client.stop()
    }

    @Test(.stateDirectoryIsolated)
    func `voice setup stores the operator grant and forget clears every credential`() async throws {
        let gateway = FakeWatchNodeGateway(bootstrapTokens: ["bootstrap-1"], voiceGrant: true)
        let store = InMemoryWatchNodeConfigurationStore()
        let client = Self.makeClient(gateway: gateway, store: store)
        let configuration = try await client.install(Self.setup())
        await client.start()
        #expect(await Self.eventually { await client.isConnected })
        #expect(await Self.eventually { await client.voiceAccess() != nil })
        let voice = try #require(await client.voiceAccess())
        #expect(voice.operatorToken.token == "operator-token")
        #expect(voice.operatorToken.scopes == ["operator.read", "operator.talk"])
        #expect(voice.webSocketURLs.map(\.absoluteString) == ["wss://gateway.example.com:443/claw"])

        await client.forget()
        #expect(await client.state == .notConfigured)
        #expect(store.loadConfiguration() == nil)
        let identity = try DeviceIdentityStore.loadOrCreatePersistedOrThrow(profile: .primary)
        for role in ["node", "operator"] {
            #expect(DeviceAuthStore.loadToken(
                deviceId: identity.deviceId, role: role, gatewayID: configuration.gatewayID) == nil)
        }
        #expect(await client.voiceAccess() == nil)
    }

    @Test(.stateDirectoryIsolated)
    func `setups are fenced by freshness, replay, and transport security`() async throws {
        let gateway = FakeWatchNodeGateway(bootstrapTokens: [])
        let store = InMemoryWatchNodeConfigurationStore()
        let client = Self.makeClient(gateway: gateway, store: store)
        await #expect(throws: OpenClawWatchNodeError.expiredSetup) {
            try await client.install(Self.setup(sentAtMs: Self.nowMs - 13 * 60 * 1000))
        }
        await #expect(throws: OpenClawWatchNodeError.insecureEndpoint) {
            try await client.install(OpenClawWatchNodeSetupMessage(
                setupCode: WatchNodeContractsTests.setupCode(url: "ws://192.168.1.5:18789"),
                sentAtMs: Self.nowMs))
        }
        try await client.install(Self.setup(sentAtMs: Self.nowMs - 1000))
        await #expect(throws: OpenClawWatchNodeError.staleSetup) {
            try await client.install(Self.setup(sentAtMs: Self.nowMs - 1000))
        }
        await #expect(throws: OpenClawWatchNodeError.staleSetup) {
            try await client.install(Self.setup(sentAtMs: Self.nowMs - 2000))
        }
        let newer = try await client.install(Self.setup(bootstrapToken: "bootstrap-2", sentAtMs: Self.nowMs))
        #expect(newer.link.bootstrapToken == "bootstrap-2")
        #expect(store.lastAcceptedSetupSentAtMs() == Self.nowMs)

        // A restarted client keeps the replay fence and the installed configuration.
        let restarted = Self.makeClient(gateway: gateway, store: store)
        #expect(await restarted.currentConfiguration == newer)
        #expect(await restarted.state == .idle)
        await #expect(throws: OpenClawWatchNodeError.staleSetup) {
            try await restarted.install(Self.setup(sentAtMs: Self.nowMs))
        }
    }
}
