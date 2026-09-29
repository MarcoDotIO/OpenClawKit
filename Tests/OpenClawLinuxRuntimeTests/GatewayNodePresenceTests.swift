import Foundation
import Testing
import OpenClawCore
import OpenClawGateway
import OpenClawProtocol

/// Presence (`system-presence`, `presence` events), node pairing (`node.pair.*`, `node.list`,
/// `node.rename`) and `mcp.authLogin` on the in-process server.
@Suite("Gateway node pairing and presence")
struct GatewayNodePresenceTests {
    private typealias Harness = GatewayServerTestHarness

    @Test
    func loopbackConnectionsShowUpInPresence() async throws {
        let (server, _) = Harness.bareServer("presence")
        let events = await server.events(filter: .only(.presence))
        let connection = GatewayConnectionContext(
            connectionID: "ios-1",
            scopes: [GatewayConnectionContext.operatorReadScope],
            clientID: "openclaw-ios",
            clientMode: "ui",
            clientVersion: "2026.3.0",
            platform: "ios",
            displayName: "iPhone",
            instanceID: "inst-1"
        )
        let client = GatewayClient(socketFactory: { LoopbackGatewaySocket(server: server, connection: connection) })
        try await client.connect(to: GatewayEndpoint(url: URL(string: "ws://127.0.0.1:18789")!))
        let response = try await client.send(method: "system-presence")
        let entries = try #require(response.payload?.arrayValue)
        let entry = try #require(entries.first?.dictionaryValue)
        #expect(entry["clientId"] == AnyCodable("openclaw-ios"))
        #expect(entry["platform"] == AnyCodable("ios"))
        #expect(entry["host"] == AnyCodable("iPhone"))
        #expect(entry["roles"] == AnyCodable([AnyCodable("operator")]))
        #expect(entry["ts"]?.int64Value != nil)
        #expect(entry["onlineSince"]?.int64Value != nil)

        await client.disconnect()
        let frames = await Harness.collect(events) { $0.count >= 2 }
        #expect(frames.first?.payload?.dictionaryValue?["presence"]?.arrayValue?.count == 1)
        #expect(frames.last?.payload?.dictionaryValue?["presence"]?.arrayValue?.isEmpty == true)
        #expect(await server.presenceEntries().isEmpty)
    }

    @Test
    func nodePairingLifecycle() async throws {
        let (server, _) = Harness.bareServer("nodes")
        let events = await server.events(filter: .only(.nodePairResolved))
        let request = await server.nodePairing.request(nodeID: "node-1", displayName: "Mac", platform: "macos", caps: ["canvas"])
        let listed = try Harness.payload(await Harness.call(server, "node.pair.list"))
        #expect(listed["pending"]?.arrayValue?.first?.dictionaryValue?["requestId"] == AnyCodable(request.requestID))
        #expect(listed["pending"]?.arrayValue?.first?.dictionaryValue?["ts"]?.int64Value != nil)

        let approved = try Harness.payload(await Harness.call(server, "node.pair.approve", ["requestId": AnyCodable(request.requestID)]))
        #expect(approved["node"]?.dictionaryValue?["nodeId"] == AnyCodable("node-1"))
        #expect(approved["node"]?.dictionaryValue?["approvedAtMs"]?.int64Value != nil)
        let renamed = try Harness.payload(await Harness.call(server, "node.rename", ["nodeId": AnyCodable("node-1"), "displayName": AnyCodable("Studio")]))
        #expect(renamed["displayName"] == AnyCodable("Studio"))
        let nodes = try Harness.payload(await Harness.call(server, "node.list"))
        #expect(nodes["nodes"]?.arrayValue?.first?.dictionaryValue?["displayName"] == AnyCodable("Studio"))
        #expect(nodes["nodes"]?.arrayValue?.first?.dictionaryValue?["paired"] == AnyCodable(true))

        let removed = try Harness.payload(await Harness.call(server, "node.pair.remove", ["nodeId": AnyCodable("node-1")]))
        #expect(removed["nodeId"] == AnyCodable("node-1"))
        let again = await Harness.call(server, "node.pair.remove", ["nodeId": AnyCodable("node-1")])
        #expect(again.error?.errorCode == .invalidRequest)
        #expect(again.error?.message == "unknown nodeId")

        let second = await server.nodePairing.request(nodeID: "node-2")
        let rejected = try Harness.payload(await Harness.call(server, "node.pair.reject", ["requestId": AnyCodable(second.requestID)]))
        #expect(rejected["nodeId"] == AnyCodable("node-2"))
        #expect(await Harness.call(server, "node.pair.approve", ["requestId": AnyCodable("missing")]).error?.message == "unknown requestId")

        let frames = await Harness.collect(events) { $0.count >= 3 }
        #expect(frames.compactMap { $0.payload?.dictionaryValue?["decision"]?.stringValue } == ["approved", "removed", "rejected"])

        // Pairing scope is enforced before dispatch.
        let reader = GatewayConnectionContext(scopes: [GatewayConnectionContext.operatorReadScope])
        #expect(await Harness.call(server, "node.pair.list", connection: reader).error?.errorCode == .forbidden)
    }

    @Test
    func nodePairingStorePersists() async throws {
        let url = Harness.temporaryRoot("nodes-persist").appendingPathComponent("nodes.json")
        let store = GatewayNodePairingStore(fileURL: url)
        let request = await store.request(nodeID: "n", displayName: "Node")
        _ = await store.approve(requestID: request.requestID)
        let reloaded = GatewayNodePairingStore(fileURL: url)
        #expect(await reloaded.pairedNode("n")?.displayName == "Node")
        #expect(await reloaded.list().pending.isEmpty)
    }

    actor SignInLog {
        private(set) var servers: [String] = []
        func record(_ server: String) { self.servers.append(server) }
    }

    struct SignInFailure: Error, LocalizedError {
        var errorDescription: String? { "browser closed" }
    }

    @Test
    func mcpAuthLoginRunsTheSignInHandler() async throws {
        let (server, _) = Harness.bareServer("mcp-auth")
        let log = SignInLog()
        await registerMCPAuthLoginGatewayMethod(on: server) { name in
            switch name {
            case "docs": await log.record(name)
            case "broken": throw SignInFailure()
            default: throw GatewayMCPAuthLoginError.unsupportedServer(name)
            }
        }
        let done = try Harness.payload(await Harness.call(server, "mcp.authLogin", ["sessionId": AnyCodable("w1"), "serverName": AnyCodable("docs")]))
        let result = try GatewayPayloadCodec.decode(WizardStartResult.self, from: AnyCodable(done))
        #expect(result.sessionid == "w1")
        #expect(result.done)
        #expect(result.status == AnyCodable("done"))
        #expect(await log.servers == ["docs"])

        let failed = try Harness.payload(await Harness.call(server, "mcp.authLogin", ["sessionId": AnyCodable("w2"), "serverName": AnyCodable("broken")]))
        #expect(failed["status"] == AnyCodable("error"))
        #expect(failed["error"] == AnyCodable("browser closed"))

        let unsupported = await Harness.call(server, "mcp.authLogin", ["sessionId": AnyCodable("w3"), "serverName": AnyCodable("stdio")])
        #expect(unsupported.error?.errorCode == .invalidRequest)
        #expect(unsupported.error?.message.contains("cannot use operator browser sign-in") == true)

        let writer = GatewayConnectionContext(scopes: [GatewayConnectionContext.operatorWriteScope])
        let denied = await Harness.call(server, "mcp.authLogin", ["sessionId": AnyCodable("w4"), "serverName": AnyCodable("docs")], connection: writer)
        #expect(denied.error?.errorCode == .forbidden)
        #expect(await Harness.call(server, "mcp.authLogin", ["sessionId": AnyCodable("w5")]).error?.errorCode == .invalidRequest)
    }
}
