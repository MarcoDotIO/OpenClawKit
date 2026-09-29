import Foundation
import Testing
@testable import OpenClawKit

/// Records requests and answers them from canned JSON keyed by method.
final class RecordingGatewaySender: GatewayRequestSending, GatewayNodeRequestSending, GatewayNodeEventSending,
    @unchecked Sendable
{
    struct Call: Sendable {
        let method: String
        let params: [String: AnyCodable]?
        let paramsJSON: String?
    }

    private let lock = NSLock()
    private var responses: [String: Result<String, any Error>] = [:]
    private(set) var calls: [Call] = []
    private(set) var events: [(event: String, payloadJSON: String?)] = []

    func respond(_ method: String, json: String) {
        self.lock.withLock { self.responses[method] = .success(json) }
    }

    func fail(_ method: String, with error: any Error) {
        self.lock.withLock { self.responses[method] = .failure(error) }
    }

    func request(method: String, params: [String: AnyCodable]?, timeoutMs: Double?) async throws -> Data {
        let response = self.lock.withLock {
            self.calls.append(Call(method: method, params: params, paramsJSON: nil))
            return self.responses[method]
        }
        switch response {
        case let .success(json): return Data(json.utf8)
        case let .failure(error): throw error
        case nil: return Data("{}".utf8)
        }
    }

    func sendNodeRequest(method: String, paramsJSON: String?, timeoutSeconds: Int) async throws -> Data {
        let response = self.lock.withLock {
            self.calls.append(Call(method: method, params: nil, paramsJSON: paramsJSON))
            return self.responses[method]
        }
        switch response {
        case let .success(json): return Data(json.utf8)
        case let .failure(error): throw error
        case nil: return Data("{}".utf8)
        }
    }

    func sendNodeEvent(event: String, payloadJSON: String?) async {
        self.lock.withLock { self.events.append((event, payloadJSON)) }
    }

    var lastCall: Call? {
        self.lock.withLock { self.calls.last }
    }

    var sentEvents: [(event: String, payloadJSON: String?)] {
        self.lock.withLock { self.events }
    }
}

struct GatewayOperatorRPCTests {
    @Test func `tools invoke sends camelCase params and decodes approval results`() async throws {
        let sender = RecordingGatewaySender()
        sender.respond("tools.invoke", json: #"""
        {"ok":false,"toolName":"exec","requiresApproval":true,"approvalId":"appr-1"}
        """#)
        let client = GatewayOperatorClient(sender: sender)
        let result = try await client.invokeTool(ToolsInvokeParams(
            name: "exec",
            args: ["command": AnyCodable("ls")],
            sessionkey: "agent:main:main",
            idempotencykey: "idem-1"))

        #expect(result.requiresapproval == true)
        #expect(result.approvalid == "appr-1")
        let call = try #require(sender.lastCall)
        #expect(call.method == "tools.invoke")
        #expect(call.params?["sessionKey"]?.stringValue == "agent:main:main")
        #expect(call.params?["idempotencyKey"]?.stringValue == "idem-1")
        #expect(call.params?["args"]?.dictionaryValue?["command"]?.stringValue == "ls")
    }

    @Test func `artifact downloads resolve inline bytes and URLs`() throws {
        let artifact = #"{"id":"a1","type":"file","title":"report.txt","download":{"mode":"bytes"}}"#
        let inline = try JSONDecoder().decode(
            ArtifactsDownloadResult.self,
            from: Data(#"{"artifact":\#(artifact),"encoding":"base64","data":"aGVsbG8="}"#.utf8))
        #expect(try GatewayOperatorClient.content(of: inline) == .inline(Data("hello".utf8)))

        let remote = try JSONDecoder().decode(
            ArtifactsDownloadResult.self,
            from: Data(#"{"artifact":\#(artifact),"url":"https://gw.example/a1","expiresAt":"soon"}"#.utf8))
        #expect(try GatewayOperatorClient.content(of: remote) == .url(URL(string: "https://gw.example/a1")!, expiresAt: "soon"))

        let broken = try JSONDecoder().decode(
            ArtifactsDownloadResult.self,
            from: Data(#"{"artifact":\#(artifact),"encoding":"base64","data":"***"}"#.utf8))
        #expect(throws: GatewayRPCClientError.self) { _ = try GatewayOperatorClient.content(of: broken) }
    }

    @Test func `plugin session actions distinguish success and failure`() async throws {
        let sender = RecordingGatewaySender()
        let client = GatewayOperatorClient(sender: sender)
        let params = PluginsSessionActionParams(pluginid: "p", actionid: "a", sessionkey: "s")

        sender.respond("plugins.sessionAction", json: #"{"ok":true,"result":{"n":1},"continueAgent":false}"#)
        guard case let .success(success) = try await client.sessionAction(params) else {
            Issue.record("Expected success")
            return
        }
        #expect(success.result?.dictionaryValue?["n"]?.intValue == 1)

        sender.respond("plugins.sessionAction", json: #"{"ok":false,"error":"nope","code":"DENIED"}"#)
        guard case let .failure(failure) = try await client.sessionAction(params) else {
            Issue.record("Expected failure")
            return
        }
        #expect(failure.error == "nope")
        #expect(failure.code == "DENIED")
        #expect(sender.lastCall?.params?["pluginId"]?.stringValue == "p")
    }

    @Test func `tasks and environments round-trip their params`() async throws {
        let sender = RecordingGatewaySender()
        let client = GatewayOperatorClient(sender: sender)
        sender.respond("tasks.cancel", json: #"{"found":true,"cancelled":true}"#)
        let cancelled = try await client.cancelTask(taskId: "t-1", reason: "user")
        #expect(cancelled.cancelled)
        #expect(sender.lastCall?.params?["taskId"]?.stringValue == "t-1")
        #expect(sender.lastCall?.params?["reason"]?.stringValue == "user")

        sender.respond("environments.list", json: #"{"environments":[]}"#)
        #expect(try await client.listEnvironments().environments.isEmpty)

        sender.respond("node.pair.remove", json: #"{"ok":true}"#)
        try await client.removePairedNode(nodeId: "node-7")
        #expect(sender.lastCall?.method == "node.pair.remove")
        #expect(sender.lastCall?.params?["nodeId"]?.stringValue == "node-7")
    }

    @Test func `gateway identity and push test use their wire shapes`() async throws {
        let sender = RecordingGatewaySender()
        let client = GatewayOperatorClient(sender: sender)
        sender.respond("gateway.identity.get", json: #"{"deviceId":"gw-1","publicKey":"pk"}"#)
        #expect(try await client.gatewayIdentity() == GatewayRelayIdentity(deviceId: "gw-1", publicKey: "pk"))
        #expect(sender.lastCall?.params?.isEmpty == true)

        sender.respond("push.test", json: #"""
        {"ok":true,"status":200,"tokenSuffix":"abcd","topic":"com.example","environment":"sandbox","transport":"direct"}
        """#)
        let result = try await client.pushTest(nodeId: "n1", environment: .sandbox)
        #expect(result.status == 200)
        #expect(sender.lastCall?.params?["environment"]?.stringValue == "sandbox")
        #expect(throws: GatewayRPCClientError.self) { _ = try GatewayAPNsEnvironment.validated("") }
        #expect(try GatewayAPNsEnvironment.validated(nil) == nil)
        #expect(try GatewayAPNsEnvironment.validated(" Production ") == .production)
    }

    @Test func `pending exec approvals expose reviewer metadata`() async throws {
        let sender = RecordingGatewaySender()
        sender.respond("exec.approval.list", json: #"""
        [
          {"id":"a1","createdAtMs":1800000000000,"expiresAtMs":1800000060000,"approvalKind":"exec",
           "request":{"command":"rm -rf build","warningText":"Deletes files","unavailableDecisions":["allow-always"],
                      "commandSpans":[{"startIndex":0,"endIndex":2}],"approvalReviewerDeviceIds":["dev-1"]}},
          {"id":"a2","createdAtMs":1800000000000,"expiresAtMs":1800000060000,"request":{"command":"ls"}}
        ]
        """#)
        let client = GatewayOperatorClient(sender: sender)
        let all = try await client.listPendingExecApprovals()
        #expect(all.map(\.id) == ["a1", "a2"])
        let mine = try await client.listPendingExecApprovals(targetingDeviceId: "dev-1")
        let approval = try #require(mine.first)
        #expect(mine.count == 1)
        #expect(approval.createdAtMs == 1_800_000_000_000)
        #expect(approval.commandText == "rm -rf build")
        #expect(approval.warningText == "Deletes files")
        #expect(approval.availableDecisions == [.allowOnce, .deny])
        #expect(approval.commandSpans == [0..<2])
    }

    @Test func `conflicting approval resolves surface a typed error`() async throws {
        let sender = RecordingGatewaySender()
        let client = GatewayOperatorClient(sender: sender)
        sender.respond("exec.approval.resolve", json: #"{"ok":true}"#)
        try await client.resolveExecApproval(id: "a1", decision: .allowOnce)
        #expect(sender.lastCall?.params?["decision"]?.stringValue == "allow-once")

        sender.fail("exec.approval.resolve", with: GatewayResponseError(
            method: "exec.approval.resolve",
            code: "INVALID_REQUEST",
            message: "approval already resolved",
            details: ["reason": AnyCodable("APPROVAL_ALREADY_RESOLVED")]))
        await #expect(throws: ExecApprovalResolveError.alreadyResolved(id: "a1")) {
            try await client.resolveExecApproval(id: "a1", decision: .deny)
        }
    }

    @Test func `session compaction failures throw the gateway reason`() async throws {
        let sender = RecordingGatewaySender()
        let client = GatewayOperatorClient(sender: sender)
        sender.respond("sessions.compact", json: #"{"ok":false,"reason":"busy"}"#)
        do {
            try await client.compactSession(SessionsCompactParams(key: "agent:main:main"))
            Issue.record("Expected failure")
        } catch {
            #expect(error.localizedDescription == "busy")
        }
        sender.respond("users.prefs.get", json: ##"{"status":"ok","entries":{"ui.accent":"#AABBCC"}}"##)
        #expect(try await client.profileAccentHex() == "#aabbcc")
        #expect(sender.lastCall?.params?["keys"]?.arrayValue?.first?.stringValue == "ui.accent")
    }

    @Test func `malformed responses raise typed decode errors`() async {
        let sender = RecordingGatewaySender()
        sender.respond("tasks.get", json: #"{"nope":true}"#)
        let client = GatewayOperatorClient(sender: sender)
        await #expect(throws: GatewayRPCClientError.self) {
            _ = try await client.getTask(taskId: "t")
        }
    }
}
