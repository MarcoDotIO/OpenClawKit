import Foundation
import OpenClawProtocol
import Testing
@testable import OpenClawKit

private actor NodeRouteValueBox<Value: Sendable> {
    private var value: Value?

    func set(_ value: Value?) {
        self.value = value
    }

    func get() -> Value? {
        self.value
    }
}

private actor NodeRouteGate {
    private var started = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        self.started = true
        guard !self.released else { return }
        await withCheckedContinuation { continuation in
            self.waiters.append(continuation)
        }
    }

    func hasStarted() -> Bool {
        self.started
    }

    func release() {
        self.released = true
        let waiters = self.waiters
        self.waiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private actor NodeRouteInvokeProbe {
    private var invocationCount = 0
    private let gate = NodeRouteGate()

    func execute(_ request: BridgeInvokeRequest) async -> BridgeInvokeResponse {
        self.invocationCount += 1
        await self.gate.wait()
        return BridgeInvokeResponse(id: request.id, ok: true, payloadJSON: #"{"acted":true}"#)
    }

    func count() -> Int {
        self.invocationCount
    }

    func release() async {
        await self.gate.release()
    }
}

private func nodeOptions(
    role: String = "node",
    commands: [String] = [],
    deviceAuthGatewayID: String? = nil) -> GatewayConnectOptions
{
    GatewayConnectOptions(
        role: role,
        scopes: role == "node" ? [] : ["operator.read"],
        caps: [],
        commands: commands,
        permissions: [:],
        clientId: role == "node" ? "node-host" : "openclaw-ios",
        clientMode: role == "node" ? "node" : "ui",
        clientDisplayName: "Node Route Test",
        includeDeviceIdentity: false,
        deviceAuthGatewayID: deviceAuthGatewayID)
}

private func invokeRequestFrame(
    id: String,
    command: String,
    paramsJSON: String? = "{}",
    idempotencyKey: String? = nil,
    extra: [String: Any] = [:]) -> [String: Any]
{
    var payload: [String: Any] = [
        "id": id,
        "nodeId": "test-node",
        "command": command,
        "paramsJSON": paramsJSON ?? NSNull(),
    ]
    if let idempotencyKey { payload["idempotencyKey"] = idempotencyKey }
    payload.merge(extra) { _, new in new }
    return GatewayCoreFrames.event("node.invoke.request", payload: payload)
}

extension GatewayNodeSession {
    fileprivate func connectForRouteTest(
        _ url: String,
        credentials: GatewayNodeSessionCredentials = .init(),
        options: GatewayConnectOptions = nodeOptions(),
        session: GatewayCoreFakeSession,
        extraHeadersProvider: (@Sendable () -> [String: String])? = nil,
        onConnected: @escaping @Sendable () async -> Void = {},
        onDisconnected: @escaping @Sendable (String) async -> Void = { _ in },
        onInvoke: @escaping @Sendable (BridgeInvokeRequest) async -> BridgeInvokeResponse = {
            BridgeInvokeResponse(id: $0.id, ok: true)
        },
        onInvokeInput: (@Sendable (NodeInvokeInputEvent) async -> Void)? = nil,
        onInvokeCancel: (@Sendable (String) async -> Void)? = nil,
        onRouteInvalidated: (@Sendable () async -> Void)? = nil) async throws
    {
        try await self.connect(
            url: try #require(URL(string: url)),
            credentials: credentials,
            connectOptions: options,
            sessionBox: WebSocketSessionBox(session: session),
            extraHeadersProvider: extraHeadersProvider,
            onConnected: onConnected,
            onDisconnected: onDisconnected,
            onInvoke: onInvoke,
            onInvokeInput: onInvokeInput,
            onInvokeCancel: onInvokeCancel,
            onRouteInvalidated: onRouteInvalidated)
    }
}

private func surfaceRefreshSession(protocolVersion: Int = 4) -> GatewayCoreFakeSession {
    GatewayCoreFakeSession(fixedScript: GatewayCoreSocketScript(
        connectReply: { _ in .ok(GatewayCoreFrames.hello(protocolVersion: protocolVersion)) },
        requestReply: { method, _ in
            method.hasSuffix("urface.refresh") ? .none : .ok([:])
        }))
}

private func respondToSurfaceRefresh(
    _ socket: GatewayCoreFakeSocket,
    method: String = "node.pluginSurface.refresh",
    index: Int = 0,
    url: String) throws
{
    let request = socket.sentFrames(method: method)[index]
    socket.respond(
        id: try #require(request["id"] as? String),
        reply: .ok(["surface": "canvas", "pluginSurfaceUrls": ["canvas": url]]))
}

@Suite("Gateway node session routes", .serialized, .timeLimit(.minutes(1)))
struct GatewayNodeSessionRouteTests {
    @Test
    func invokeMetadataReachesTheHandlerAndResultCarriesStructuredPayload() async throws {
        let session = GatewayCoreFakeSession()
        let gateway = GatewayNodeSession()
        let captured = NodeRouteValueBox<BridgeInvokeRequest>()
        try await gateway.connectForRouteTest(
            "ws://gateway.example.invalid",
            session: session,
            onInvoke: { request in
                await captured.set(request)
                return BridgeInvokeResponse(
                    id: request.id,
                    ok: true,
                    payload: AnyCodable(["content": AnyCodable([AnyCodable(["text": AnyCodable("worker-ok")])])]))
            })
        let socket = try #require(session.latestSocket)
        socket.emit(invokeRequestFrame(
            id: "invoke-metadata",
            command: "system.worker.start",
            extra: ["sessionKey": "agent:main:owner", "timeoutMs": 42000, "idempotencyKey": "attempt"]))

        try await gatewayCoreWaitUntil("invoke result sent") {
            socket.sentFrames(method: "node.invoke.result").count == 1
        }
        let request = try #require(await captured.get())
        #expect(request.nodeId == "test-node")
        #expect(request.sessionKey == "agent:main:owner")
        #expect(request.timeoutMs == 42000)
        #expect(request.idempotencyKey == "attempt")
        let params = try #require(socket.sentFrames(method: "node.invoke.result").first?["params"] as? [String: Any])
        #expect(params["id"] as? String == "invoke-metadata")
        #expect(params["nodeId"] as? String == "test-node")
        #expect(params["ok"] as? Bool == true)
        let payload = try #require(params["payload"] as? [String: Any])
        let content = try #require(payload["content"] as? [[String: Any]])
        #expect(content.first?["text"] as? String == "worker-ok")
        await gateway.disconnect()
    }

    @Test
    func invokeInputAndCancellationReachRouteCallbacks() async throws {
        let session = GatewayCoreFakeSession()
        let gateway = GatewayNodeSession()
        let inputs = GatewayCoreRecorder<String>()
        let cancels = GatewayCoreRecorder<String>()
        try await gateway.connectForRouteTest(
            "ws://gateway.example.invalid",
            session: session,
            onInvokeInput: { input in inputs.append("\(input.id):\(input.seq):\(input.payloadjson)") },
            onInvokeCancel: { id in cancels.append(id) })
        let socket = try #require(session.latestSocket)
        socket.emit(GatewayCoreFrames.event("node.invoke.input", payload: [
            "id": "terminal-1", "nodeId": "test-node", "seq": 3, "payloadJSON": #"{"data":"hello"}"#,
        ]))
        socket.emit(GatewayCoreFrames.event("node.invoke.cancel", payload: ["invokeId": "terminal-1"]))
        try await gatewayCoreWaitUntil("input and cancel delivered") {
            inputs.values.count == 1 && cancels.values.count == 1
        }
        #expect(inputs.values == [#"terminal-1:3:{"data":"hello"}"#])
        #expect(cancels.values == ["terminal-1"])
        await gateway.disconnect()
    }

    @Test
    func invokeResultIsDiscardedAfterTheRouteIsReplaced() async throws {
        let session = GatewayCoreFakeSession()
        let gateway = GatewayNodeSession()
        let gate = NodeRouteGate()
        try await gateway.connectForRouteTest(
            "ws://first.example.invalid",
            credentials: .init(token: "first"),
            session: session,
            onInvoke: { request in
                await gate.wait()
                return BridgeInvokeResponse(id: request.id, ok: true, payloadJSON: #"{"sensitive":true}"#)
            })
        let first = try #require(session.latestSocket)
        first.emit(invokeRequestFrame(id: "invoke-old", command: "camera.snap"))
        try await gatewayCoreWaitUntil("invoke started") { await gate.hasStarted() }

        try await gateway.connectForRouteTest(
            "ws://replacement.example.invalid",
            credentials: .init(token: "replacement"),
            session: session)
        let replacement = try #require(session.latestSocket)
        await gate.release()
        for _ in 0..<50 {
            await Task.yield()
        }
        #expect(first.sentFrames(method: "node.invoke.result").isEmpty)
        #expect(replacement.sentFrames(method: "node.invoke.result").isEmpty)
        await gateway.disconnect()
    }

    @Test
    func routeBoundRequestsRevalidateTheRouteForResponsesAndErrors() async throws {
        let session = GatewayCoreFakeSession(fixedScript: GatewayCoreSocketScript(
            requestReply: { method, _ in method == "progressCard.get" ? .none : .ok([:]) }))
        let gateway = GatewayNodeSession()
        try await gateway.connectForRouteTest("ws://gateway.example.invalid", session: session)
        let route = try #require(await gateway.currentRoute())
        let socket = try #require(session.latestSocket)

        let answered = Task {
            try await gateway.request(method: "progressCard.get", paramsJSON: #"{"seq":0,"ratio":1.5}"#, ifCurrentRoute: route)
        }
        try await gatewayCoreWaitUntil("request sent") { socket.sentFrames(method: "progressCard.get").count == 1 }
        let sent = try #require(socket.sentFrames(method: "progressCard.get").first)
        let params = try #require(sent["params"] as? [String: Any])
        #expect((params["seq"] as? NSNumber).map { CFGetTypeID($0) != CFBooleanGetTypeID() } == true)
        #expect((params["ratio"] as? NSNumber)?.doubleValue == 1.5)
        socket.respond(id: try #require(sent["id"] as? String), reply: .ok(["card": NSNull()]))
        let answeredData = try await answered.value
        #expect(!answeredData.isEmpty)

        #if DEBUG
        let retired = Task {
            try await gateway.request(method: "progressCard.get", params: nil, ifCurrentRoute: route)
        }
        try await gatewayCoreWaitUntil("second request sent") { socket.sentFrames(method: "progressCard.get").count == 2 }
        let retiredFrame = try #require(socket.sentFrames(method: "progressCard.get").last)
        // Retire the route before the (late) response arrives: it must not reach the caller.
        await gateway._test_handleChannelDisconnected("socket retired", socketGeneration: 1)
        socket.respond(id: try #require(retiredFrame["id"] as? String), reply: .ok(["card": NSNull()]))
        await #expect(throws: CancellationError.self) { _ = try await retired.value }
        #else
        socket.emitReceiveFailure()
        try await gatewayCoreWaitUntil("route retired") { await gateway.currentRoute() != route }
        #endif
        await #expect(throws: GatewayNodeSessionRequestError.self) {
            _ = try await gateway.request(
                method: "progressCard.get",
                params: nil,
                ifCurrentRoute: route,
                distinguishPreDispatchRouteChange: true)
        }
        #expect(await gateway.sendEvent(event: "stale", payloadJSON: nil, ifCurrentRoute: route) == false)
        await gateway.disconnect()
    }

    @Test
    func routeQueriesStayBoundToTheConnectedRoute() async throws {
        let session = GatewayCoreFakeSession(fixedScript: GatewayCoreSocketScript(
            connectReply: { _ in
                .ok(GatewayCoreFrames.hello(
                    auth: ["scopes": ["operator.read"]],
                    methods: ["approval.get"],
                    capabilities: ["published-model-catalog", "future-capability"],
                    sessionDefaults: ["mainSessionKey": " agent:main:main "]))
            }))
        let gateway = GatewayNodeSession()
        try await gateway.connectForRouteTest(
            "ws://gateway.example.invalid",
            options: nodeOptions(role: "operator", deviceAuthGatewayID: "gw-1"),
            session: session)
        let route = try #require(await gateway.currentRoute())
        #expect(await gateway.currentRoute(ifGatewayID: "gw-1") == route)
        #expect(await gateway.currentRoute(ifGatewayID: "gw-2") == nil)
        #expect(await gateway.supportsServerMethod("approval.get", ifCurrentRoute: route) == true)
        #expect(await gateway.supportsServerMethod("missing", ifCurrentRoute: route) == false)
        #expect(await gateway.supportsServerCapability(.publishedModelCatalog, ifCurrentRoute: route) == true)
        #expect(await gateway.supportsServerCapability(.profileBinding, ifCurrentRoute: route) == false)
        #expect(await gateway.currentOperatorScopes(ifCurrentRoute: route) == ["operator.read"])
        #expect(await gateway.currentGatewayID(ifCurrentRoute: route) == "gw-1")
        #expect(await gateway.negotiatedProtocolVersion(ifCurrentRoute: route) == 4)
        #expect(await gateway.waitForCurrentMainSessionKey(ifCurrentRoute: route) == "agent:main:main")

        await gateway.disconnect()
        #expect(await gateway.supportsServerMethod("approval.get", ifCurrentRoute: route) == nil)
        #expect(await gateway.currentGatewayID(ifCurrentRoute: route) == nil)
        #expect(await gateway.waitForCurrentMainSessionKey(ifCurrentRoute: route) == nil)
    }

    @Test
    func workerConnectionUsesTheAuthenticatedRouteAndExpires() async throws {
        let fingerprint = String(repeating: "ab", count: 32)
        let session = GatewayCoreFakeSession(tlsFingerprint: fingerprint, fixedScript: GatewayCoreSocketScript(
            connectReply: { _ in .ok(GatewayCoreFrames.hello(capabilities: ["node-worker-portal-stream-v1"])) }))
        let gateway = GatewayNodeSession()
        try await gateway.connectForRouteTest(
            "wss://gateway.example.invalid/current",
            session: session,
            extraHeadersProvider: {
                ["CF-Access-Client-Id": "edge-id", "CF-Access-Client-Secret": "edge-secret", "Authorization": "x"]
            })
        let route = try #require(await gateway.currentRoute())
        let data = try #require(await gateway.workerConnectionData(ifCurrentRoute: route))
        let connection = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(connection["url"] as? String == "wss://gateway.example.invalid/current")
        #expect(connection["protocol"] as? Int == 4)
        #expect(connection["capabilities"] as? [String] == ["node-worker-portal-stream-v1"])
        #expect(connection["tlsFingerprint"] as? String == fingerprint)
        #expect(connection["cloudflareAccess"] as? [String: String] == ["clientId": "edge-id", "clientSecret": "edge-secret"])
        await gateway.disconnect()
        #expect(await gateway.workerConnectionData(ifCurrentRoute: route) == nil)
    }

    @Test
    func routeBoundNodeEventRequestsDistinguishHandledAndLegacyAcknowledgements() async throws {
        let replies = GatewayCoreRecorder<Int>()
        let session = GatewayCoreFakeSession(fixedScript: GatewayCoreSocketScript(
            requestReply: { method, _ in
                guard method == "node.event" else { return .ok([:]) }
                replies.append(1)
                return replies.values.count == 1
                    ? .ok(["ok": true, "event": "node.presence.activity", "handled": true, "reason": "cleared"])
                    : .ok(["ok": true])
            }))
        let gateway = GatewayNodeSession()
        try await gateway.connectForRouteTest("ws://gateway.example.invalid", session: session)
        let route = try #require(await gateway.currentRoute())

        let handled = try await gateway.requestEventResult(
            event: "node.presence.activity",
            payloadJSON: #"{"action":"clear"}"#,
            ifCurrentRoute: route)
        #expect(handled?.handled == true)
        #expect(handled?.reason == "cleared")
        let legacy = try await gateway.requestEventResult(event: "node.presence.activity", payloadJSON: nil, ifCurrentRoute: route)
        #expect(legacy == nil)
        let frame = try #require(session.latestSocket?.sentFrames(method: "node.event").last)
        #expect((frame["params"] as? [String: Any])?["payloadJSON"] is NSNull)
        await gateway.disconnect()
    }

    @Test
    func surfaceRefreshIsSingleFlightAcrossCallers() async throws {
        let fingerprint = String(repeating: "cd", count: 32)
        let session = GatewayCoreFakeSession(tlsFingerprint: fingerprint, fixedScript: GatewayCoreSocketScript(
            connectReply: { _ in .ok(GatewayCoreFrames.hello()) },
            requestReply: { method, _ in method == "node.pluginSurface.refresh" ? .none : .ok([:]) }))
        let gateway = GatewayNodeSession()
        try await gateway.connectForRouteTest("wss://gateway.example.invalid", session: session)
        let socket = try #require(session.latestSocket)

        async let first = gateway.refreshCanvasHostUrl(timeoutSeconds: 5)
        try await gatewayCoreWaitUntil("refresh sent") {
            socket.sentFrames(method: "node.pluginSurface.refresh").count == 1
        }
        async let second = gateway.refreshCanvasHostUrl(replacing: nil)
        async let third = gateway.refreshPluginSurfaceUrl(surface: "canvas", replacing: nil)
        try respondToSurfaceRefresh(socket, url: "http://127.0.0.1:18789/__openclaw__/cap/new-token")
        let values = await (first, second, third)
        #expect(values.0 == "https://gateway.example.invalid/__openclaw__/cap/new-token")
        #expect(values.0 == values.1)
        #expect(values.0 == values.2)
        #expect(socket.sentFrames(method: "node.pluginSurface.refresh").count == 1)
        #expect(await gateway.pluginSurfaceURL("canvas") == values.0)
        let route = try #require(await gateway.currentCanvasHostRoute())
        #expect(route.url == values.0)
        #expect(route.tlsFingerprintSHA256 == fingerprint)
        await gateway.disconnect()
    }

    @Test
    func laggingRefreshReusesTheRotatedCapabilityAndSendsObservedURL() async throws {
        let session = surfaceRefreshSession()
        let gateway = GatewayNodeSession()
        try await gateway.connectForRouteTest("ws://gateway.example.invalid", session: session)
        let socket = try #require(session.latestSocket)

        async let seeded = gateway.refreshCanvasHostUrl(replacing: nil)
        try await gatewayCoreWaitUntil("seed refresh") { socket.sentFrames(method: "node.pluginSurface.refresh").count == 1 }
        try respondToSurfaceRefresh(socket, url: "http://gateway.example.invalid/__openclaw__/cap/old")
        let oldURL = try #require(await seeded)

        async let rotated = gateway.refreshCanvasHostUrl(replacing: oldURL)
        try await gatewayCoreWaitUntil("rotate refresh") { socket.sentFrames(method: "node.pluginSurface.refresh").count == 2 }
        let rotateParams = try #require(socket.sentFrames(method: "node.pluginSurface.refresh").last?["params"] as? [String: Any])
        #expect(rotateParams["observedUrl"] as? String == oldURL)
        try respondToSurfaceRefresh(socket, index: 1, url: "http://gateway.example.invalid/__openclaw__/cap/new")
        let newURL = try #require(await rotated)

        #expect(await gateway.refreshCanvasHostUrl(replacing: oldURL) == newURL)
        #expect(socket.sentFrames(method: "node.pluginSurface.refresh").count == 2)
        await gateway.disconnect()
    }

    @Test
    func lastTimedOutWaiterReleasesAStalledRefreshForRetry() async throws {
        let session = surfaceRefreshSession()
        let gateway = GatewayNodeSession()
        try await gateway.connectForRouteTest("ws://gateway.example.invalid", session: session)
        let socket = try #require(session.latestSocket)

        #expect(await gateway.refreshCanvasHostUrl(timeoutSeconds: 1) == nil)
        async let retry = gateway.refreshCanvasHostUrl(timeoutSeconds: 5)
        try await gatewayCoreWaitUntil("retry sent") { socket.sentFrames(method: "node.pluginSurface.refresh").count == 2 }
        try respondToSurfaceRefresh(socket, index: 1, url: "http://gateway.example.invalid/__openclaw__/cap/retry")
        #expect(await retry?.hasSuffix("/retry") == true)
        await gateway.disconnect()
    }

    @Test
    func surfaceRefreshMethodFollowsTheRoleAndProtocol() async throws {
        let operatorSession = surfaceRefreshSession()
        let operatorGateway = GatewayNodeSession()
        try await operatorGateway.connectForRouteTest(
            "ws://gateway.example.invalid",
            options: nodeOptions(role: "operator"),
            session: operatorSession)
        let socket = try #require(operatorSession.latestSocket)
        async let refreshed = operatorGateway.refreshCanvasHostUrl(replacing: nil)
        try await gatewayCoreWaitUntil("operator refresh") { socket.sentFrames(method: "plugin.surface.refresh").count == 1 }
        try respondToSurfaceRefresh(socket, method: "plugin.surface.refresh", url: "http://gateway.example.invalid/__openclaw__/cap/op")
        #expect(await refreshed?.hasSuffix("/op") == true)
        #expect(socket.sentFrames(method: "node.pluginSurface.refresh").isEmpty)
        await operatorGateway.disconnect()

        // Protocol-3 (N-1) node sessions have no plugin surfaces.
        let legacySession = surfaceRefreshSession(protocolVersion: 3)
        let legacyGateway = GatewayNodeSession()
        try await legacyGateway.connectForRouteTest("ws://gateway.example.invalid", session: legacySession)
        #expect(await legacyGateway.refreshCanvasHostUrl(timeoutSeconds: 1) == nil)
        #expect(legacySession.latestSocket?.sentFrames(method: "node.pluginSurface.refresh").isEmpty == true)
        await legacyGateway.disconnect()
    }

    @Test
    func helloPluginSurfacesAreCanonicalizedAgainstTheActiveGateway() async throws {
        let session = GatewayCoreFakeSession(fixedScript: GatewayCoreSocketScript(
            connectReply: { _ in
                .ok(GatewayCoreFrames.hello(pluginSurfaceUrls: [
                    "canvas": "http://127.0.0.1:18789/__openclaw__/cap/token",
                    "future": 42,
                ]))
            }))
        let gateway = GatewayNodeSession()
        try await gateway.connectForRouteTest("wss://gateway.example.invalid:7443", session: session)
        #expect(await gateway.currentCanvasHostUrl() == "https://gateway.example.invalid:7443/__openclaw__/cap/token")
        #expect(await gateway.pluginSurfaceURL("future") == nil)
        await gateway.disconnect()
    }

    @Test
    func reconnectSnapshotBroadcastsASyntheticSeqGap() async throws {
        let session = GatewayCoreFakeSession()
        let gateway = GatewayNodeSession()
        let subscription = await gateway.makeServerEventSubscription(matching: { $0.event == "seqGap" })
        defer { subscription.cancel() }
        try await gateway.connectForRouteTest("ws://gateway.example.invalid", session: session)
        session.latestSocket?.emitReceiveFailure()
        var iterator = subscription.events.makeAsyncIterator()
        let event = await iterator.next()
        #expect(event?.event == "seqGap")
        #expect(session.makeCount == 2)
        await gateway.disconnect()
    }

    @Test
    func disconnectCallbackAndInvalidationFollowTheRetiredRoute() async throws {
        let session = GatewayCoreFakeSession()
        let gateway = GatewayNodeSession()
        let events = GatewayCoreRecorder<String>()
        try await gateway.connectForRouteTest(
            "ws://gateway.example.invalid",
            session: session,
            onConnected: { events.append("connected") },
            onDisconnected: { reason in events.append("disconnected:\(reason.hasPrefix("receive failed"))") },
            onRouteInvalidated: { events.append("invalidated") })
        #expect(events.values == ["connected"])
        session.latestSocket?.emitReceiveFailure()
        try await gatewayCoreWaitUntil("reconnected") { events.values.filter { $0 == "connected" }.count == 2 }
        #expect(events.values.prefix(3) == ["connected", "invalidated", "disconnected:true"])
        await gateway.disconnect()
        #expect(events.values.last == "invalidated")
    }

    #if DEBUG
    @Test
    func computerReceiptsDeduplicateInFlightAndRejectReusedKeys() async throws {
        let gateway = GatewayNodeSession()
        let probe = NodeRouteInvokeProbe()
        let scope = "gateway:test"
        let key = "computer.act:v1:stable"
        let params = #"{"action":"type","text":"hello"}"#

        let first = Task {
            await gateway.invokeComputerWithReceiptForTesting(
                requestId: "first", paramsJSON: params, idempotencyKey: key, receiptScope: scope,
                onInvoke: { await probe.execute($0) })
        }
        try await gatewayCoreWaitUntil("first invoke started") { await probe.count() == 1 }
        let replay = Task {
            await gateway.invokeComputerWithReceiptForTesting(
                requestId: "replay", paramsJSON: params, idempotencyKey: key, receiptScope: scope,
                onInvoke: { await probe.execute($0) })
        }
        try await gatewayCoreWaitUntil("replay joined") {
            await gateway.computerReceiptJoinCountForTesting(idempotencyKey: key, receiptScope: scope) == 1
        }
        await probe.release()
        #expect(await first.value.id == "first")
        let replayed = await replay.value
        #expect(replayed.id == "replay")
        #expect(replayed.ok)
        #expect(await probe.count() == 1)

        let mismatch = await gateway.invokeComputerWithReceiptForTesting(
            requestId: "mismatch", paramsJSON: #"{"action":"type","text":"other"}"#, idempotencyKey: key,
            receiptScope: scope, onInvoke: { await probe.execute($0) })
        #expect(mismatch.ok == false)
        #expect(mismatch.error?.code == .invalidRequest)

        // Receipts are scoped byte-exactly: canonically equivalent owners stay separate.
        let composed = await gateway.invokeComputerWithReceiptForTesting(
            requestId: "composed", paramsJSON: params, idempotencyKey: key, receiptScope: "gateway:gw-\u{00E9}",
            onInvoke: { await probe.execute($0) })
        let decomposed = await gateway.invokeComputerWithReceiptForTesting(
            requestId: "decomposed", paramsJSON: params, idempotencyKey: key, receiptScope: "gateway:gw-e\u{0301}",
            onInvoke: { await probe.execute($0) })
        #expect(composed.ok && decomposed.ok)
        #expect(await probe.count() == 3)
    }

    @Test
    func invokesDuringABlockedLifecycleTransitionAreRejectedPromptly() async throws {
        let session = GatewayCoreFakeSession()
        let gateway = GatewayNodeSession()
        let gate = NodeRouteGate()
        try await gateway.connectForRouteTest(
            "ws://gateway.example.invalid",
            session: session,
            onDisconnected: { _ in await gate.wait() })
        let first = try #require(session.latestSocket)
        first.emitReceiveFailure()
        try await gatewayCoreWaitUntil("disconnect callback blocked") { await gate.hasStarted() }
        try await gatewayCoreWaitUntil("replacement socket") { session.makeCount == 2 }
        let replacement = try #require(session.latestSocket)
        try await gatewayCoreWaitUntil("replacement admitted") {
            replacement.connectParams() != nil
        }
        // Deliver on the replacement socket while the old route's cleanup is suspended.
        try await gatewayCoreWaitUntil("replacement snapshot admitted") {
            await gateway.currentRoute() != nil
        }
        replacement.emit(invokeRequestFrame(id: "during-transition", command: "camera.snap"))
        try await gatewayCoreWaitUntil("rejection sent") {
            replacement.sentFrames(method: "node.invoke.result").count == 1
        }
        let params = try #require(replacement.sentFrames(method: "node.invoke.result").first?["params"] as? [String: Any])
        #expect(params["ok"] as? Bool == false)
        let error = try #require(params["error"] as? [String: Any])
        #expect(["NODE_NOT_READY", "UNAVAILABLE"].contains(error["code"] as? String ?? ""))
        await gate.release()
        await gateway.disconnect()
    }

    @Test
    func delayedPushesFromARetiredSocketAreIgnored() async throws {
        let gateway = GatewayNodeSession()
        let session = GatewayCoreFakeSession()
        let invoked = GatewayCoreRecorder<String>()
        try await gateway.connectForRouteTest(
            "ws://gateway.example.invalid",
            session: session,
            onInvoke: { request in
                invoked.append(request.id)
                return BridgeInvokeResponse(id: request.id, ok: true)
            })
        let admission = await gateway._test_admissionGeneration()
        await gateway._test_handleChannelDisconnected("socket retired", socketGeneration: 1)
        #expect(await gateway._test_admissionGeneration() == admission &+ 1)
        await gateway._test_handlePush(.event(EventFrame(
            type: "event",
            event: "node.invoke.request",
            payload: AnyCodable([
                "id": AnyCodable("late"),
                "nodeId": AnyCodable("test-node"),
                "command": AnyCodable("camera.snap"),
            ]))), socketGeneration: 1)
        for _ in 0..<50 {
            await Task.yield()
        }
        #expect(invoked.values.isEmpty)
        await gateway.disconnect()
    }
    #endif

    @Test
    func serverEventSubscriptionFiltersBeforeBuffering() async throws {
        let session = GatewayCoreFakeSession()
        let gateway = GatewayNodeSession()
        let subscription = await gateway.makeServerEventSubscription(bufferingNewest: 1, matching: { $0.event == "target" })
        defer { subscription.cancel() }
        try await gateway.connectForRouteTest("ws://gateway.example.invalid", session: session)
        let socket = try #require(session.latestSocket)
        socket.emit(GatewayCoreFrames.event("noise"))
        socket.emit(GatewayCoreFrames.event("target"))
        socket.emit(GatewayCoreFrames.event("noise"))
        var iterator = subscription.events.makeAsyncIterator()
        #expect(await iterator.next()?.event == "target")
        await gateway.disconnect()
    }

    @Test
    func invokeTimeoutRaceHonorsZeroDefaultAndHostileValues() async {
        let fast = await GatewayNodeSession.invokeWithTimeout(
            request: BridgeInvokeRequest(id: "1", command: "x"),
            timeoutMs: 50,
            onInvoke: { BridgeInvokeResponse(id: $0.id, ok: true, payloadJSON: "{}") })
        #expect(fast.ok && fast.payloadJSON == "{}")

        let slow = await GatewayNodeSession.invokeWithTimeout(
            request: BridgeInvokeRequest(id: "slow", command: "x"),
            timeoutMs: 10,
            onInvoke: { request in
                // Ignores cancellation on purpose: the race must not wait for it.
                try? await Task.sleep(for: .milliseconds(300))
                return BridgeInvokeResponse(id: request.id, ok: true)
            })
        #expect(slow.ok == false)
        #expect(slow.error?.code == .unavailable)
        #expect(slow.error?.message == "node invoke timed out")

        let unbounded = await GatewayNodeSession.invokeWithTimeout(
            request: BridgeInvokeRequest(id: "zero", command: "x"),
            timeoutMs: 0,
            onInvoke: { request in
                try? await Task.sleep(for: .milliseconds(20))
                return BridgeInvokeResponse(id: request.id, ok: true)
            })
        #expect(unbounded.ok)

        let hostile = await GatewayNodeSession.invokeWithTimeout(
            request: BridgeInvokeRequest(id: "max", command: "computer.act"),
            timeoutMs: .max,
            onInvoke: { BridgeInvokeResponse(id: $0.id, ok: true) })
        #expect(hostile.ok)
    }

    @Test
    func invocationRegistryTracksTeardownOwnership() {
        #expect(GatewayNodeInvocationRegistry.waitsForRouteTeardown(command: "computer.act"))
        #expect(GatewayNodeInvocationRegistry.waitsForRouteTeardown(command: "camera.ptz.control"))
        #expect(GatewayNodeInvocationRegistry.waitsForRouteTeardown(command: "talk.ptt.start"))
        #expect(!GatewayNodeInvocationRegistry.waitsForRouteTeardown(command: "system.notify"))
        var registry = GatewayNodeInvocationRegistry()
        let untracked = registry.register(requestID: "r1", command: "camera.snap", admissionGeneration: 1)
        #expect(untracked == nil)
        let notify = registry.register(requestID: "r2", command: "system.notify", admissionGeneration: 1)
        #expect(notify != nil)
        let computer = registry.register(requestID: "r3", command: "computer.act", admissionGeneration: 1)
        #expect(computer != nil)
        #expect(registry.activeCount == 2)
        registry.cancel(requestID: "r3", admissionGeneration: 1)
        if let computer {
            let started = registry.start(id: computer, makeTask: { Task { BridgeInvokeResponse(id: "r3", ok: true) } })
            #expect(started == nil)
        }
        let cleanup = registry.cancel(admissionGeneration: 1)
        #expect(cleanup.isEmpty)
        #expect(registry.activeCount == 0)
    }

    @Test
    func pluginSurfaceURLRulesMatchUpstream() throws {
        #expect(GatewayPluginSurfaceURL.canonicalize(
            raw: "https://canvas.example.com:9443/__openclaw__/cap/token",
            against: URL(string: "wss://gateway.example.com")) == "https://canvas.example.com:9443/__openclaw__/cap/token")
        #expect(GatewayPluginSurfaceURL.canonicalize(
            raw: "http://127.0.0.1:18789/__openclaw__/cap/token",
            against: URL(string: "wss://gateway.example.com:7443")) == "https://gateway.example.com:7443/__openclaw__/cap/token")
        #expect(GatewayPluginSurfaceURL.canonicalize(
            raw: "http://127.0.0.1:18789/cap",
            against: URL(string: "ws://127.0.0.1:18789")) == "http://127.0.0.1:18789/cap")

        let gateway = URL(string: "wss://gateway.example.com:7443/control?tenant=a")
        #expect(GatewayPluginSurfaceURL.resolveHTTPURL(raw: "/plugins/codex/calls", against: gateway)?.absoluteString
            == "https://gateway.example.com:7443/plugins/codex/calls")
        #expect(GatewayPluginSurfaceURL.resolveHTTPURL(raw: "wss://gateway.example.com/realtime", against: gateway) == nil)
        let mounted = URL(string: "wss://gateway.example.invalid/team%2Fa/?socket=only#fragment")
        #expect(GatewayPluginSurfaceURL.resolveHTTPURL(
            raw: "/plugins/tool%2Fv1/calls?reservation=a%2Fb#answer",
            against: mounted,
            relativeToGatewayContext: true)?.absoluteString
            == "https://gateway.example.invalid/team%2Fa/plugins/tool%2Fv1/calls?reservation=a%2Fb#answer")
        for escaping in ["../calls", "/plugins/../calls", "//other.example/calls", "?query=only"] {
            #expect(GatewayPluginSurfaceURL.resolveHTTPURL(
                raw: escaping,
                against: URL(string: "wss://gateway.example.invalid/team"),
                relativeToGatewayContext: true) == nil)
        }

        let fingerprint = String(repeating: "ab", count: 32)
        let pinned = URL(string: "wss://gateway.example.com:7443")
        #expect(GatewayPluginSurfaceURL.tlsFingerprintForSurface(
            fingerprint, surfaceURL: "https://gateway.example.com:7443/cap", gatewayURL: pinned) == fingerprint)
        #expect(GatewayPluginSurfaceURL.tlsFingerprintForSurface(
            fingerprint, surfaceURL: "https://canvas.example.com:7443/cap", gatewayURL: pinned) == nil)
        #expect(GatewayPluginSurfaceURL.tlsFingerprintForSurface(
            fingerprint, surfaceURL: "https://gateway.example.com:9443/cap", gatewayURL: pinned) == nil)
    }

    @Test
    func socketGenerationStateRejectsRetiredGenerations() {
        var state = GatewaySocketGenerationState()
        let admittedFirst = state.admit(1)
        let admittedOther = state.admit(2)
        let retiredFirst = state.retire(1)
        #expect(admittedFirst)
        #expect(!admittedOther)
        #expect(retiredFirst)
        #expect(!state.accepts(1))
        let admittedSecond = state.admit(2)
        #expect(admittedSecond)
        #expect(state.activeGeneration == 2)
        let retiredStale = state.retire(1)
        #expect(!retiredStale)
    }
}
