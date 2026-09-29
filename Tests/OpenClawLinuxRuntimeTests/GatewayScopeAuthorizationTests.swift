import Foundation
import Testing
import OpenClawCore
import OpenClawGateway
import OpenClawModels
import OpenClawProtocol
@testable import OpenClawAgents

/// Per-request scope policy of dynamic methods, unclassified methods, node pairing approval and
/// connection-bound event delivery (2026.3.0 FX1 review fixes).
@Suite("Gateway scope authorization")
struct GatewayScopeAuthorizationTests {
    typealias Harness = GatewayServerTestHarness

    static let noScopes = GatewayConnectionContext(connectionID: "none", scopes: [])
    static let reader = GatewayConnectionContext(connectionID: "reader", scopes: ["operator.read"])
    static let pairer = GatewayConnectionContext(connectionID: "pairer", scopes: ["operator.pairing"])
    static let writer = GatewayConnectionContext(connectionID: "writer", scopes: ["operator.write"])
    static let admin = GatewayConnectionContext(connectionID: "admin", scopes: ["operator.admin"])

    static func missingScope(_ response: ResponseFrame) -> String? {
        guard response.ok == false, response.error?.code == ErrorCode.forbidden.rawValue else { return nil }
        return response.error?.details?.dictionaryValue?["missingScope"]?.stringValue
    }

    /// Requests every restricted context must be refused, with the scope each one needs.
    static let dangerousRequests: [(String, [String: AnyCodable])] = [
        ("sessions.delete", ["key": AnyCodable("agent:main:main")]),
        ("agent", ["message": AnyCodable("run rm -rf"), "idempotencyKey": AnyCodable("x")]),
        ("sessions.create", ["key": AnyCodable("agent:main:new")]),
        ("sessions.patch", ["key": AnyCodable("agent:main:main"), "sandboxMode": AnyCodable("off")]),
    ]

    @Test
    func dynamicMethodsFailClosedForRestrictedConnectionsOnBuiltinsAndRuntimeHandlers() async throws {
        let (bare, _) = Harness.bareServer("scope-bare", handlers: GatewayServerHandlers(runAgent: { request in
            GatewayAgentExecution(runID: request.idempotencyKey ?? "run", task: Task { GatewayAgentWaitResult(runID: "run", status: "ok") })
        }))
        let stack = await Harness.runtimeStack("scope-runtime", turns: [], fallback: ScriptedToolProvider.text("done"))
        _ = await stack.store.resolveOrCreate(sessionKey: "agent:main:main", defaultAgentID: "main", route: nil)
        for server in [bare, stack.server] {
            for connection in [Self.noScopes, Self.reader, Self.pairer] {
                for (method, params) in Self.dangerousRequests {
                    let response = await Harness.call(server, method, params, connection: connection)
                    let missing = Self.missingScope(response)
                    #expect(missing != nil, "\(method) must be refused for \(connection.scopes)")
                }
            }
        }
        #expect(await stack.store.recordForKey("agent:main:main") != nil)
        #expect(await stack.runtime.activeRunIDs().isEmpty)
    }

    @Test
    func writeScopeRunsAgentsButNeedsAdminForResetsDeletesAndAdminPatchFields() async throws {
        let stack = await Harness.runtimeStack("scope-write", turns: [], fallback: ScriptedToolProvider.text("done"))
        _ = await stack.store.resolveOrCreate(sessionKey: "agent:main:main", defaultAgentID: "main", route: nil)
        let server = stack.server

        let run = await Harness.call(server, "agent", ["message": AnyCodable("hi"), "idempotencyKey": AnyCodable("w1")], connection: Self.writer)
        #expect(run.ok)
        let reset = await Harness.call(server, "agent", ["message": AnyCodable("/reset now"), "idempotencyKey": AnyCodable("w2")], connection: Self.writer)
        #expect(Self.missingScope(reset) == "operator.admin")
        let newCommand = await Harness.call(server, "agent", ["message": AnyCodable("/NEW"), "idempotencyKey": AnyCodable("w3")], connection: Self.writer)
        #expect(Self.missingScope(newCommand) == "operator.admin")

        let delete = await Harness.call(server, "sessions.delete", ["key": AnyCodable("agent:main:main")], connection: Self.writer)
        #expect(Self.missingScope(delete) == "operator.admin")
        let requiredScopes = delete.error?.details?.dictionaryValue?["requiredScopes"]?.arrayValue?.compactMap(\.stringValue)
        #expect(requiredScopes == ["operator.admin"])
        // An archived-only delete is write-scoped; the handler then rejects the unarchived session.
        let archivedOnly = await Harness.call(
            server, "sessions.delete", ["key": AnyCodable("agent:main:main"), "archivedOnly": AnyCodable(true)], connection: Self.writer
        )
        #expect(archivedOnly.error?.code == ErrorCode.invalidRequest.rawValue)

        let label = await Harness.call(server, "sessions.patch", ["key": AnyCodable("agent:main:main"), "label": AnyCodable("Work")], connection: Self.writer)
        #expect(label.ok)
        for field in ["sandboxMode", "execNode", "toolOverrides", "verboseLevel"] {
            let value: AnyCodable = field == "toolOverrides" ? AnyCodable(["mcpServers": AnyCodable([String: AnyCodable]())]) : AnyCodable("off")
            let patch = await Harness.call(server, "sessions.patch", ["key": AnyCodable("agent:main:main"), field: value], connection: Self.writer)
            #expect(Self.missingScope(patch) == "operator.admin", "\(field) must need operator.admin")
        }
        let full = await Harness.call(
            server, "sessions.patch", ["key": AnyCodable("agent:main:main"), "permissionMode": AnyCodable("full")], connection: Self.writer
        )
        #expect(Self.missingScope(full) == "operator.admin")
        #expect(await stack.store.recordForKey("agent:main:main")?.sandboxMode == nil)

        let create = await Harness.call(
            server, "sessions.create", ["key": AnyCodable("agent:main:plain"), "label": AnyCodable("Plain")], connection: Self.writer
        )
        #expect(create.ok)
        let createSandbox = await Harness.call(
            server, "sessions.create", ["key": AnyCodable("agent:main:sbx"), "sandboxMode": AnyCodable("off")], connection: Self.writer
        )
        #expect(Self.missingScope(createSandbox) == "operator.admin")
        let incognito = await Harness.call(
            server, "sessions.create", ["key": AnyCodable("agent:main:dashboard:incognito-1")], connection: Self.writer
        )
        #expect(Self.missingScope(incognito) == "operator.admin")

        // Admin passes every dynamic rule.
        let adminDelete = await Harness.call(server, "sessions.delete", ["key": AnyCodable("agent:main:plain")], connection: Self.admin)
        #expect(adminDelete.ok)
    }

    @Test
    func narrowSessionScopesAndDynamicRulesMirrorUpstream() {
        let sessionsReader = GatewayConnectionContext(scopes: ["operator.sessions.read"])
        let sessionsWriter = GatewayConnectionContext(scopes: ["operator.sessions.write"])
        func authorize(_ method: String, _ params: [String: AnyCodable], _ connection: GatewayConnectionContext) -> GatewayMethodError? {
            GatewayMethodScopePolicy.authorizationError(
                method: method,
                descriptor: GatewayMethodCatalog.byName[method],
                params: AnyCodable(params),
                connection: connection
            )
        }
        #expect(authorize("sessions.list", [:], sessionsReader) == nil)
        #expect(authorize("chat.history", ["sessionKey": AnyCodable("main")], sessionsReader) == nil)
        #expect(authorize("chat.send", [:], sessionsReader) != nil)
        #expect(authorize("chat.send", [:], sessionsWriter) == nil)
        #expect(authorize("sessions.patch", ["key": AnyCodable("main"), "label": AnyCodable("x")], sessionsWriter) == nil)
        #expect(authorize("sessions.patch", ["key": AnyCodable("main"), "sandboxMode": AnyCodable("off")], sessionsWriter) != nil)
        #expect(authorize("question.list", [:], sessionsWriter) == nil)
        #expect(authorize("config.get", [:], sessionsWriter) != nil)

        #expect(GatewayMethodScopePolicy.requiredOperatorScopes(forDynamicMethod: "talk.config", params: AnyCodable(["includeSecrets": AnyCodable(true)]))
            == ["operator.read", "operator.talk.secrets"])
        #expect(GatewayMethodScopePolicy.requiredOperatorScopes(forDynamicMethod: "node.invoke", params: AnyCodable(["command": AnyCodable("fs.listDir")]))
            == ["operator.admin"])
        #expect(GatewayMethodScopePolicy.requiredOperatorScopes(forDynamicMethod: "fs.listDir", params: AnyCodable(["nodeId": AnyCodable("n")]))
            == ["operator.admin"])
        #expect(GatewayMethodScopePolicy.requiredOperatorScopes(forDynamicMethod: "environments.list", params: AnyCodable(["runtimeId": AnyCodable("r")]))
            == ["operator.write"])
        let bootstrap = AnyCodable(["bootstrapCommandOwner": AnyCodable(true)])
        #expect(GatewayMethodScopePolicy.requiredOperatorScopes(forDynamicMethod: "channels.pairing.approve", params: bootstrap)
            == ["operator.pairing", "operator.admin"])
        #expect(GatewayMethodScopePolicy.requiredOperatorScopes(forDynamicMethod: "some.future.method", params: nil) == ["operator.write"])
        #expect(GatewayMethodScopePolicy.isAgentSessionResetCommand("/reset"))
        #expect(GatewayMethodScopePolicy.isAgentSessionResetCommand("/New please"))
        #expect(GatewayMethodScopePolicy.isAgentSessionResetCommand("/newer") == false)
        #expect(GatewayMethodScopePolicy.isAgentSessionResetCommand(" /reset") == false)

        #expect(Self.noScopes.allows(scope: "dynamic") == false)
        #expect(Self.writer.allows(scope: "dynamic") == false)
        #expect(Self.admin.allows(scope: "dynamic"))
    }

    @Test
    func methodsRegisteredWithoutAnyDescriptorRequireAdmin() async throws {
        let (server, _) = Harness.bareServer("scope-unclassified")
        await server.register(method: "host.custom.echo", descriptor: nil) { _ in AnyCodable(["ok": AnyCodable(true)]) }
        let refused = await Harness.call(server, "host.custom.echo", connection: Self.reader)
        #expect(Self.missingScope(refused) == "operator.admin")
        let node = await Harness.call(server, "host.custom.echo", connection: GatewayConnectionContext(role: "node", scopes: []))
        #expect(node.error?.code == ErrorCode.invalidRequest.rawValue)
        #expect(await Harness.call(server, "host.custom.echo", connection: Self.admin).ok)
        // An explicit descriptor keeps its own scope.
        await server.register(
            method: "host.custom.read",
            descriptor: GatewayMethodDescriptor(name: "host.custom.read", scope: "operator.read", since: "sdk")
        ) { _ in nil }
        #expect(await Harness.call(server, "host.custom.read", connection: Self.reader).ok)
    }

    @Test
    func nodePairApprovalRequiresTheScopesTheDeclaredCommandsNeed() async throws {
        let (server, _) = Harness.bareServer("scope-node-pair")
        let pairing = server.nodePairing
        let runner = await pairing.request(nodeID: "mac-1", commands: ["system.run", "canvas.present"])
        let canvas = await pairing.request(nodeID: "ipad-1", commands: ["canvas.present"])
        let plain = await pairing.request(nodeID: "watch-1")

        let refused = await Harness.call(server, "node.pair.approve", ["requestId": AnyCodable(runner.requestID)], connection: Self.pairer)
        #expect(Self.missingScope(refused) == "operator.admin")
        #expect(refused.error?.details?.dictionaryValue?["requiredScopes"]?.arrayValue?.compactMap(\.stringValue) == ["operator.pairing", "operator.admin"])
        #expect(await pairing.list().pending.contains { $0.requestID == runner.requestID })

        let pairWriter = GatewayConnectionContext(scopes: ["operator.pairing", "operator.write"])
        #expect(Self.missingScope(await Harness.call(server, "node.pair.approve", ["requestId": AnyCodable(runner.requestID)], connection: pairWriter))
            == "operator.admin")
        #expect(Self.missingScope(await Harness.call(server, "node.pair.approve", ["requestId": AnyCodable(canvas.requestID)], connection: Self.pairer))
            == "operator.write")
        #expect(await Harness.call(server, "node.pair.approve", ["requestId": AnyCodable(canvas.requestID)], connection: pairWriter).ok)
        #expect(await Harness.call(server, "node.pair.approve", ["requestId": AnyCodable(plain.requestID)], connection: Self.pairer).ok)
        #expect(await Harness.call(server, "node.pair.approve", ["requestId": AnyCodable(runner.requestID)], connection: Self.admin).ok)
        #expect(await pairing.pairedNode("mac-1")?.commands == ["system.run", "canvas.present"])
        #expect(await pairing.list().pending.isEmpty)
    }

    @Test
    func connectionBoundEventsFollowRoleScopesAndSessionSubscriptions() async throws {
        let (server, _) = Harness.bareServer("scope-events")
        let node = GatewayConnectionContext(connectionID: "ev-node", role: "node", scopes: [])
        let pairer = GatewayConnectionContext(connectionID: "ev-pairer", scopes: ["operator.pairing"])
        let reader = GatewayConnectionContext(connectionID: "ev-reader", scopes: ["operator.read"])
        let admin = GatewayConnectionContext(connectionID: "ev-admin", scopes: ["operator.admin"])
        var streams: [String: AsyncStream<EventFrame>] = [:]
        for context in [node, pairer, reader, admin] {
            await server.connectionOpened(context)
            streams[context.connectionID] = await server.events(filter: .connection(context.connectionID))
        }
        let unregistered = await server.events(filter: .connection("ev-unknown"))
        _ = await Harness.call(server, "sessions.subscribe", connection: admin)

        for event in ["chat", "agent", "presence", "exec.approval.requested", "node.pair.resolved", "sessions.changed", "sdk.custom", "plugin.demo"] {
            await server.broadcast(event: event, payload: AnyCodable(["sessionKey": AnyCodable("main")]))
        }
        await server.broadcast(event: "tick", payload: AnyCodable(["ts": AnyCodable(1)]))

        func received(_ id: String) async throws -> [String] {
            let stream = try #require(streams[id])
            return await Harness.collect(stream) { frames in frames.contains { $0.event == "tick" } }.map(\.event)
        }
        let nodeEvents = try await received("ev-node")
        let pairerEvents = try await received("ev-pairer")
        let readerEvents = try await received("ev-reader")
        let adminEvents = try await received("ev-admin")
        #expect(nodeEvents == ["tick"])
        #expect(pairerEvents == ["node.pair.resolved", "tick"])
        // sessions.changed needs sessions.subscribe; approvals need operator.approvals.
        #expect(readerEvents.filter { $0 != "presence" } == ["chat", "agent", "tick"])
        #expect(readerEvents.contains("presence"))
        #expect(adminEvents.filter { $0 != "presence" } == [
            "chat", "agent", "exec.approval.requested", "node.pair.resolved", "sessions.changed", "sdk.custom", "plugin.demo", "tick",
        ])
        #expect(await Harness.collect(unregistered, timeoutMs: 200) { _ in false }.isEmpty)

        #expect(GatewayEventFilter.hasEventScope(GatewayConnectionContext(scopes: ["operator.write"]), event: "plugin.demo"))
        #expect(GatewayEventFilter.hasEventScope(GatewayConnectionContext(scopes: ["operator.approvals"]), event: "openclaw.approval.requested"))
        #expect(GatewayEventFilter.hasEventScope(nil, event: "tick") == false)
    }
}
