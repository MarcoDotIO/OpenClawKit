import Foundation
import OpenClawProtocol
import Testing
@testable import OpenClawKit

private actor RecordingSessionsSender: GatewayRequestSending {
    private(set) var calls: [(method: String, params: [String: AnyCodable])] = []
    private let responses: [String: String]

    init(responses: [String: String]) {
        self.responses = responses
    }

    func request(method: String, params: [String: AnyCodable]?, timeoutMs: Double?) async throws -> Data {
        self.calls.append((method, params ?? [:]))
        return Data((self.responses[method] ?? "{}").utf8)
    }
}

private func approvalEvent(_ name: String, id: String, command: String? = nil) -> EventFrame {
    var payload: [String: AnyCodable] = ["id": AnyCodable(id)]
    if let command {
        payload["request"] = AnyCodable(["command": AnyCodable(command)])
        payload["createdAtMs"] = AnyCodable(1_800_000_000_000)
        payload["expiresAtMs"] = AnyCodable(1_800_000_060_000)
    }
    return EventFrame(type: "event", event: name, payload: AnyCodable(payload), seq: nil, stateversion: nil)
}

@Suite("Gateway sessions client")
struct GatewaySessionsClientTests {
    @Test
    func permissionModePatchNeverSendsRetiredExecFields() async throws {
        let sender = RecordingSessionsSender(responses: [
            "sessions.patch": #"{"ok":true,"key":"agent:main:main","entry":{"permissionMode":"workspace"}}"#,
        ])
        let client = GatewaySessionsClient(sender: sender)
        let outcome = try await client.setPermissionMode(sessionKey: "agent:main:main", mode: .workspace)
        #expect(outcome.key == "agent:main:main")
        #expect(outcome.permissionMode == .workspace)

        _ = try await client.setPermissionMode(sessionKey: "agent:main:main", mode: nil, expectedMode: .some(.guarded))
        let calls = await sender.calls
        #expect(calls.map(\.method) == ["sessions.patch", "sessions.patch"])
        #expect(calls[0].params["permissionMode"]?.stringValue == "workspace")
        #expect(calls[0].params["expectedPermissionMode"] == nil)
        #expect(calls[1].params["permissionMode"] == AnyCodable.nullValue)
        #expect(calls[1].params["expectedPermissionMode"]?.stringValue == "guarded")
        for call in calls {
            #expect(call.params["execSecurity"] == nil)
            #expect(call.params["execAsk"] == nil)
            #expect(call.params["key"]?.stringValue == "agent:main:main")
        }
    }

    @Test
    func approvalBackfillNeitherLosesNorResurrectsRacingApprovals() async throws {
        let sender = RecordingSessionsSender(responses: [
            "exec.approval.list": #"""
            [{"id":"a-listed","request":{"command":"ls"},"createdAtMs":1800000000000,"expiresAtMs":1800000060000},
             {"id":"a-resolved","request":{"command":"rm"},"createdAtMs":1800000000000,"expiresAtMs":1800000060000}]
            """#,
        ])
        let backfill = GatewayApprovalBackfill(kind: .exec)
        // Events that arrive between hello-ok and the list response.
        #expect(await backfill.ingest(approvalEvent("exec.approval.requested", id: "a-live", command: "git status")))
        #expect(await backfill.ingest(approvalEvent("exec.approval.resolved", id: "a-resolved")))
        #expect(await backfill.ingest(approvalEvent("plugin.approval.requested", id: "p-1")) == false)

        try await backfill.backfill(using: sender)
        #expect(await backfill.pendingIDs == ["a-listed", "a-live"])
        let commands = await backfill.pendingExecApprovals.compactMap(\.commandText)
        #expect(commands == ["ls", "git status"])

        await backfill.ingest(approvalEvent("exec.approval.resolved", id: "a-live"))
        #expect(await backfill.pendingIDs == ["a-listed"])
        #expect(await sender.calls.map(\.method) == ["exec.approval.list"])
    }

    @Test
    func pluginBackfillAcceptsAnEnvelopedList() async throws {
        let sender = RecordingSessionsSender(responses: [
            "plugin.approval.list": #"{"approvals":[{"id":"p-1","title":"Allow"}]}"#,
        ])
        let backfill = GatewayApprovalBackfill(kind: .plugin)
        try await backfill.backfill(using: sender)
        #expect(await backfill.pendingIDs == ["p-1"])
        #expect(GatewayApprovalBackfill.Kind.plugin.resolvedEvent == "plugin.approval.resolved")
    }
}
