import Foundation
import OpenClawProtocol
import Testing
@testable import OpenClawChatUI
@testable import OpenClawKit

// Covers the turnkey OpenClawGatewaySessionChatTransport over a scripted in-memory gateway
// (GatewayCoreTestSupport): route-bound outbox leases, strict vs best-effort replay, gateway-id
// binding, sessions.subscribe replay and route-change events.

private func transportTestAgentsList() -> [String: Any] {
    [
        "defaultId": "main",
        "mainKey": "main",
        "scope": "per-sender",
        "agents": [["id": "main"]],
    ]
}

private func transportTestSession(
    capabilities: [String],
    methods: [String]? = ["chat.send", "chat.history", "agents.list"],
    requestReply: @escaping @Sendable (String, [String: Any]) -> GatewayCoreReply = { method, _ in
        switch method {
        case "agents.list": .ok(transportTestAgentsList())
        case "chat.send": .ok(["runId": "run-1", "status": "started"])
        case "chat.history": .ok(["sessionKey": "agent:main:main", "messages": []])
        default: .ok([:])
        }
    }) -> GatewayCoreFakeSession
{
    GatewayCoreFakeSession(fixedScript: GatewayCoreSocketScript(
        connectReply: { _ in
            .ok(GatewayCoreFrames.hello(
                auth: ["scopes": ["operator.read", "operator.write"]],
                methods: methods,
                capabilities: capabilities))
        },
        requestReply: requestReply))
}

extension GatewayNodeSession {
    fileprivate func connectForChatTransportTest(
        _ url: String = "ws://gateway.example.invalid",
        session: GatewayCoreFakeSession,
        gatewayID: String? = nil) async throws
    {
        try await self.connect(
            url: try #require(URL(string: url)),
            credentials: GatewayNodeSessionCredentials(),
            connectOptions: gatewayCoreOptions(
                scopes: ["operator.read", "operator.write"],
                deviceAuthGatewayID: gatewayID),
            sessionBox: WebSocketSessionBox(session: session),
            onConnected: {},
            onDisconnected: { _ in },
            onInvoke: { BridgeInvokeResponse(id: $0.id, ok: true) })
    }
}

private func sentParams(_ socket: GatewayCoreFakeSocket, method: String) -> [[String: Any]] {
    socket.sentFrames(method: method).compactMap { $0["params"] as? [String: Any] }
}

@Suite("Gateway session chat transport", .serialized, .timeLimit(.minutes(1)))
struct ChatGatewaySessionTransportTests {
    @Test func `init normalizes the agent and keeps exact gateway id bytes`() {
        let transport = OpenClawGatewaySessionChatTransport(
            gateway: GatewayNodeSession(),
            agentID: "  Research ",
            gatewayStableID: "gw-A")
        #expect(transport.chatGatewayAgentID == "research")
        #expect(transport.gatewayStableID == "gw-A")
        #expect(transport.outboxRequiresSessionRoutingContract)
        #expect(transport.sessionTarget(for: "main").sessionKey == "agent:research:main")
        #expect(transport.sessionTarget(for: "agent:ops:main").sessionKey == "agent:ops:main")
        let blank = OpenClawGatewaySessionChatTransport(gateway: GatewayNodeSession(), agentID: " ", gatewayStableID: " ")
        #expect(blank.chatGatewayAgentID == nil)
        #expect(blank.gatewayStableID == nil)
        let scoped = transport.scoped(toAgentID: "OPS") as? OpenClawGatewaySessionChatTransport
        #expect(scoped?.chatGatewayAgentID == "ops")
        #expect(scoped?.gatewayStableID == "gw-A")
    }

    @Test func `disconnected transport has no route lease`() async {
        let transport = OpenClawGatewaySessionChatTransport(gateway: GatewayNodeSession())
        guard case let .unavailable(reason, allowsLiveSend) = await transport.acquireOutboxRouteLease() else {
            Issue.record("A disconnected transport must not offer an outbox lease")
            return
        }
        #expect(reason == nil)
        #expect(!allowsLiveSend)
        #expect(await transport.acquireSessionMutationRouteLease() == nil)
        #expect(await transport.acquireSessionSettingsRouteLease() == nil)
        #expect(await transport.acquireNewSessionRouteLease() == nil)
        #expect(await transport.gatewayAdvertisesMethod("chat.send") == nil)
    }

    @Test func `strict mode parks queued replay on gateways without the routing contract`() async throws {
        let session = transportTestSession(capabilities: [])
        let gateway = GatewayNodeSession()
        try await gateway.connectForChatTransportTest(session: session, gatewayID: "gw-a")
        defer { Task { await gateway.disconnect() } }
        let transport = OpenClawGatewaySessionChatTransport(gateway: gateway, gatewayStableID: "gw-a")

        guard case let .unavailable(reason, allowsLiveSend) = await transport.acquireOutboxRouteLease() else {
            Issue.record("Strict mode must not replay without chat-send-routing-contract")
            return
        }
        #expect(reason == OpenClawChatTransportUpgradeMessage.routingContract)
        #expect(allowsLiveSend)

        // Live sends still work and never claim a routing contract the gateway cannot guard.
        let response = try await transport.sendMessage(
            sessionKey: "main",
            agentID: "main",
            expectedSessionRoutingContract: "per-sender|main|main",
            message: "hello",
            thinking: "off",
            idempotencyKey: "live-1",
            attachments: [])
        #expect(response.runId == "run-1")
        let socket = try #require(session.latestSocket)
        let send = try #require(sentParams(socket, method: "chat.send").last)
        #expect(send["expectedSessionRoutingContract"] == nil)
        #expect(send["idempotencyKey"] as? String == "live-1")
    }

    @Test func `strict lease binds sends and history to the captured route`() async throws {
        let session = transportTestSession(capabilities: ["chat-send-routing-contract", "session-settings-cas-v1"])
        let gateway = GatewayNodeSession()
        try await gateway.connectForChatTransportTest(session: session, gatewayID: "gw-a")
        defer { Task { await gateway.disconnect() } }
        let transport = OpenClawGatewaySessionChatTransport(gateway: gateway, gatewayStableID: "gw-a")

        guard case let .available(lease) = await transport.acquireOutboxRouteLease() else {
            Issue.record("A routing-contract gateway must offer an outbox lease")
            return
        }
        #expect(lease.sessionRoutingContract == "per-sender|main|main")
        #expect(lease.supportsSessionSettingsCAS)
        _ = try await lease.sendMessage(
            sessionKey: "agent:main:main",
            agentID: "main",
            expectedSessionSettings: OpenClawChatSessionSettingsExpectation(permissionMode: nil, toolOverrides: nil),
            message: "queued",
            thinking: "off",
            idempotencyKey: "cmd-1",
            attachments: [])
        _ = try await lease.requestHistory(sessionKey: "agent:main:main", agentID: "main")

        let socket = try #require(session.latestSocket)
        let send = try #require(sentParams(socket, method: "chat.send").last)
        #expect(send["expectedSessionRoutingContract"] as? String == "per-sender|main|main")
        #expect(send["idempotencyKey"] as? String == "cmd-1")
        #expect(send.keys.contains("expectedPermissionMode"))
        #expect(sentParams(socket, method: "chat.history").count == 1)

        // Replacing the connection (new endpoint) retires the lease: the queued send must fail
        // as not dispatched instead of reaching the replacement gateway.
        let replacement = transportTestSession(capabilities: ["chat-send-routing-contract"])
        try await gateway.connectForChatTransportTest(
            "ws://replacement.example.invalid",
            session: replacement,
            gatewayID: "gw-a")
        await #expect(throws: OpenClawChatTransportSendError.self) {
            _ = try await lease.sendMessage(
                sessionKey: "agent:main:main",
                agentID: "main",
                message: "stale",
                thinking: "off",
                idempotencyKey: "cmd-2",
                attachments: [])
        }
        let replacementSocket = try #require(replacement.latestSocket)
        #expect(sentParams(replacementSocket, method: "chat.send").isEmpty)
    }

    @Test func `best effort mode replays on one route without a routing contract`() async throws {
        let session = transportTestSession(capabilities: [])
        let gateway = GatewayNodeSession()
        try await gateway.connectForChatTransportTest(session: session, gatewayID: "gw-a")
        defer { Task { await gateway.disconnect() } }
        let transport = OpenClawGatewaySessionChatTransport(
            gateway: gateway,
            gatewayStableID: "gw-a",
            outboxRouteSafety: .bestEffort)
        #expect(!transport.outboxRequiresSessionRoutingContract)

        guard case let .available(lease) = await transport.acquireOutboxRouteLease() else {
            Issue.record("Best-effort mode must offer a route-bound lease")
            return
        }
        #expect(lease.sessionRoutingContract == nil)
        #expect(!lease.supportsSessionSettingsCAS)
        _ = try await lease.sendMessage(
            sessionKey: "main",
            expectedSessionSettings: OpenClawChatSessionSettingsExpectation(permissionMode: nil, toolOverrides: nil),
            message: "queued",
            thinking: "off",
            idempotencyKey: "cmd-1",
            attachments: [])
        let socket = try #require(session.latestSocket)
        let send = try #require(sentParams(socket, method: "chat.send").last)
        #expect(send["expectedSessionRoutingContract"] == nil)
        #expect(send["expectedPermissionMode"] == nil)
        #expect(sentParams(socket, method: "agents.list").isEmpty)
    }

    @Test func `unpinned transport never offers an outbox lease but keeps live sends`() async throws {
        // Default gateways all report `per-sender|main|main`, so the routing-contract fence cannot
        // tell two gateways apart: without a pinned gateway id, queued work must stay parked.
        for safety in [OpenClawGatewaySessionChatTransport.OutboxRouteSafety.strict, .bestEffort] {
            let session = transportTestSession(capabilities: ["chat-send-routing-contract", "session-settings-cas-v1"])
            let gateway = GatewayNodeSession()
            try await gateway.connectForChatTransportTest(session: session, gatewayID: "gw-b")
            defer { Task { await gateway.disconnect() } }
            let transport = OpenClawGatewaySessionChatTransport(gateway: gateway, outboxRouteSafety: safety)

            guard case let .unavailable(reason, allowsLiveSend) = await transport.acquireOutboxRouteLease() else {
                Issue.record("An unpinned transport must not offer an outbox lease (\(safety))")
                return
            }
            #expect(reason == nil)
            #expect(allowsLiveSend)
            let socket = try #require(session.latestSocket)
            #expect(sentParams(socket, method: "agents.list").isEmpty)

            let response = try await transport.sendMessage(
                sessionKey: "main",
                message: "live",
                thinking: "off",
                idempotencyKey: "live-1",
                attachments: [])
            #expect(response.runId == "run-1")
            #expect(sentParams(socket, method: "chat.send").count == 1)
        }
    }

    @Test func `pinned transport refuses reads while connected to another gateway`() async throws {
        let session = transportTestSession(capabilities: ["chat-send-routing-contract"], requestReply: { method, _ in
            switch method {
            case "chat.history": .ok(["sessionKey": "agent:main:main", "messages": []])
            case "health": .ok(["ok": true])
            case "sessions.list": .ok(["sessions": []])
            default: .ok([:])
            }
        })
        let gateway = GatewayNodeSession()
        try await gateway.connectForChatTransportTest(session: session, gatewayID: "gw-b")
        defer { Task { await gateway.disconnect() } }
        let socket = try #require(session.latestSocket)

        let other = OpenClawGatewaySessionChatTransport(gateway: gateway, gatewayStableID: "gw-a")
        await #expect(throws: OpenClawGatewaySessionChatTransportError.differentGateway) {
            _ = try await other.requestHistory(sessionKey: "main")
        }
        await #expect(throws: OpenClawGatewaySessionChatTransportError.differentGateway) {
            _ = try await other.requestHealth(timeoutMs: 1000)
        }
        await #expect(throws: OpenClawGatewaySessionChatTransportError.differentGateway) {
            _ = try await other.listSessions(limit: 10, search: nil, archived: false)
        }
        await #expect(throws: OpenClawGatewaySessionChatTransportError.differentGateway) {
            _ = try await other.requestChatGateway(OpenClawChatGatewayRequests.questionList())
        }
        #expect(sentParams(socket, method: "chat.history").isEmpty)
        #expect(socket.sentFrames(method: "health").isEmpty)
        #expect(sentParams(socket, method: "sessions.list").isEmpty)

        // The owning gateway's transport reads normally, bound to its live route.
        let owner = OpenClawGatewaySessionChatTransport(gateway: gateway, gatewayStableID: "gw-b")
        let history = try await owner.requestHistory(sessionKey: "main")
        #expect(history.messages?.isEmpty != false)
        #expect(try await owner.requestHealth(timeoutMs: 1000))
        #expect(sentParams(socket, method: "chat.history").count == 1)
        #expect(socket.sentFrames(method: "health").count == 1)
    }

    @Test func `pinned transport drops events from another gateway`() async throws {
        let homeSession = transportTestSession(capabilities: [])
        let gateway = GatewayNodeSession()
        try await gateway.connectForChatTransportTest(session: homeSession, gatewayID: "gw-a")
        defer { Task { await gateway.disconnect() } }
        let homeRecorder = GatewayCoreRecorder<String>()
        let home = OpenClawGatewaySessionChatTransport(gateway: gateway, gatewayStableID: "gw-a")
        let homeConsumer = Task {
            for await event in home.events() {
                switch event {
                case .tick: homeRecorder.append("tick")
                case .health(ok: false): homeRecorder.append("offline")
                default: break
                }
            }
        }
        defer { homeConsumer.cancel() }

        // The home subscription is live and delivers its own gateway's frames.
        let homeSocket = try #require(homeSession.latestSocket)
        try await gatewayCoreWaitUntil("home subscribed sessions") {
            !homeSocket.sentFrames(method: "sessions.subscribe").isEmpty
        }
        homeSocket.emit(GatewayCoreFrames.event("tick", payload: ["ts": 1]))
        try await gatewayCoreWaitUntil("home tick delivered") { homeRecorder.values.count == 1 }

        // The shared session switches to gateway B: B's frames reach B's transport only.
        let workSession = transportTestSession(capabilities: [])
        try await gateway.connectForChatTransportTest(
            "ws://work.example.invalid",
            session: workSession,
            gatewayID: "gw-b")
        let workRecorder = GatewayCoreRecorder<String>()
        let work = OpenClawGatewaySessionChatTransport(gateway: gateway, gatewayStableID: "gw-b")
        let workConsumer = Task {
            for await event in work.events() {
                if case .tick = event { workRecorder.append("tick") }
            }
        }
        defer { workConsumer.cancel() }
        let workSocket = try #require(workSession.latestSocket)
        try await gatewayCoreWaitUntil("work subscribed sessions") {
            !workSocket.sentFrames(method: "sessions.subscribe").isEmpty
        }
        workSocket.emit(GatewayCoreFrames.event("tick", payload: ["ts": 2]))
        workSocket.emit(GatewayCoreFrames.event("tick", payload: ["ts": 3]))
        try await gatewayCoreWaitUntil("work ticks delivered") { workRecorder.values.count == 2 }
        // The home transport reports itself offline once and never delivers B's frames.
        try await gatewayCoreWaitUntil("home reported offline") { homeRecorder.values.contains("offline") }
        try await Task.sleep(for: .milliseconds(100))
        #expect(homeRecorder.values == ["tick", "offline"])
    }

    @Test func `gateway stable id must match the connected gateway exactly`() async throws {
        let session = transportTestSession(capabilities: ["chat-send-routing-contract"])
        let gateway = GatewayNodeSession()
        try await gateway.connectForChatTransportTest(session: session, gatewayID: "gw-a")
        defer { Task { await gateway.disconnect() } }

        let other = OpenClawGatewaySessionChatTransport(gateway: gateway, gatewayStableID: "gw-b")
        guard case .unavailable = await other.acquireOutboxRouteLease() else {
            Issue.record("A store bound to another gateway must not flush on this connection")
            return
        }
        await #expect(throws: OpenClawChatTransportSendError.self) {
            _ = try await other.sendMessage(
                sessionKey: "main",
                message: "hello",
                thinking: "off",
                idempotencyKey: "live-1",
                attachments: [])
        }
        let owner = OpenClawGatewaySessionChatTransport(gateway: gateway, gatewayStableID: "gw-a")
        guard case .available = await owner.acquireOutboxRouteLease() else {
            Issue.record("The owning gateway must offer a lease")
            return
        }
    }

    @Test func `events subscribe sessions and report reconnects and route changes`() async throws {
        let session = transportTestSession(capabilities: [])
        let gateway = GatewayNodeSession()
        try await gateway.connectForChatTransportTest(session: session)
        defer { Task { await gateway.disconnect() } }
        let transport = OpenClawGatewaySessionChatTransport(gateway: gateway)
        let recorder = GatewayCoreRecorder<String>()
        let consumer = Task {
            for await event in transport.events() {
                switch event {
                case .tick: recorder.append("tick")
                case .seqGap: recorder.append("seqGap")
                case .routeChanged: recorder.append("routeChanged")
                default: recorder.append("other")
                }
            }
        }
        defer { consumer.cancel() }

        let socket = try #require(session.latestSocket)
        try await gatewayCoreWaitUntil("initial sessions.subscribe") {
            !socket.sentFrames(method: "sessions.subscribe").isEmpty
        }
        socket.emit(GatewayCoreFrames.event("tick", payload: ["ts": 1]))
        try await gatewayCoreWaitUntil("tick delivered") { recorder.values.contains("tick") }

        // Same connection context, new socket: seqGap plus a fresh per-socket subscription.
        socket.emitReceiveFailure()
        try await gatewayCoreWaitUntil("reconnect seqGap") {
            recorder.values.contains("seqGap")
        }
        let reconnected = try #require(session.latestSocket)
        #expect(reconnected !== socket)
        try await gatewayCoreWaitUntil("resubscribed after reconnect") {
            !reconnected.sentFrames(method: "sessions.subscribe").isEmpty
        }

        // A different endpoint is a different connection context: routeChanged.
        let replacement = transportTestSession(capabilities: [])
        try await gateway.connectForChatTransportTest("ws://replacement.example.invalid", session: replacement)
        try await gatewayCoreWaitUntil("route change reported") {
            recorder.values.contains("routeChanged")
        }
        let replacementSocket = try #require(replacement.latestSocket)
        try await gatewayCoreWaitUntil("resubscribed after route change") {
            !replacementSocket.sentFrames(method: "sessions.subscribe").isEmpty
        }
    }

    @Test func `full message reads use chat message get with the target owner`() async throws {
        let session = transportTestSession(capabilities: [], requestReply: { method, _ in
            guard method == "chat.message.get" else { return .ok([:]) }
            return .ok([
                "ok": true,
                "message": ["role": "assistant", "content": [["type": "text", "text": "full body"]], "timestamp": 1],
            ])
        })
        let gateway = GatewayNodeSession()
        try await gateway.connectForChatTransportTest(session: session)
        defer { Task { await gateway.disconnect() } }
        let transport = OpenClawGatewaySessionChatTransport(gateway: gateway, agentID: "research")

        let message = try await transport.requestFullMessage(sessionKey: "main", messageID: "msg-1")
        #expect(message?.content.first?.text == "full body")
        let socket = try #require(session.latestSocket)
        let params = try #require(sentParams(socket, method: "chat.message.get").last)
        #expect(params["sessionKey"] as? String == "agent:research:main")
        #expect(params["messageId"] as? String == "msg-1")
        #expect(params["maxChars"] as? Int == 500_000)
    }

    @Test func `composer catalog maps MCP tools, notices and scope gated mutations`() throws {
        let config = try JSONSerialization.data(withJSONObject: [
            "runtimeConfig": [
                "mcp": ["servers": ["github": ["enabled": true], "linear": ["enabled": false]]],
                "tools": ["web": ["search": ["enabled": false]]],
            ],
        ])
        let tool: [String: Any] = [
            "id": "mcp:github:search", "label": " ", "description": "", "rawDescription": "",
            "source": "mcp", "mcpServer": "github", "mcpToolName": "search", "deniedBySession": true,
        ]
        let tools = try JSONSerialization.data(withJSONObject: [
            "agentId": "main", "profile": "default",
            "groups": [["id": "mcp", "label": "MCP", "source": "mcp", "tools": [tool, tool]]],
            "notices": [["id": "n1", "severity": "warning", "message": "Reconnect GitHub", "servers": ["github"]]],
        ])
        let catalog = OpenClawGatewaySessionComposerCatalog.catalog(
            config: .loaded(config),
            skills: .failed,
            tools: .loaded(tools),
            patchCapability: true,
            settingsContract: true,
            settingsCAS: false,
            canWrite: true,
            canAdmin: false)

        #expect(catalog.connectors.map(\.name) == ["github", "linear"])
        let github = try #require(catalog.connectors.first)
        #expect(github.tools.map(\.name) == ["search"])
        #expect(github.tools.first?.label == "search")
        #expect(github.tools.first?.sessionDenied == true)
        #expect(github.notice == "Reconnect GitHub")
        #expect(catalog.connectors.last?.baseEnabled == false)
        #expect(!catalog.webSearchBaseEnabled)
        #expect(catalog.modelMutationAvailable)
        #expect(!catalog.effortMutationAvailable)
        #expect(catalog.toolOverrideMutationRequiresGatewayUpgrade)
        #expect(!catalog.permissionMutationAvailable)
        #expect(!catalog.skillsAvailable)
        #expect(catalog.loadFailureMessage?.contains("Skills") == true)
        #expect(OpenClawGatewaySessionComposerCatalog.mutationAvailable(methodSupport: nil, allowedByScope: false))
        #expect(!OpenClawGatewaySessionComposerCatalog.mutationAvailable(methodSupport: false, allowedByScope: true))
    }
}
