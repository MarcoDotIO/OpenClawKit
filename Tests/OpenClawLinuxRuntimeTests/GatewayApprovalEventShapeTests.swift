import Foundation
import Testing
import OpenClawCore
import OpenClawGateway
import OpenClawModels
import OpenClawProtocol
@testable import OpenClawAgents

/// Approval event wire shapes and ordering (2026.3.0 FX1 review fix).
@Suite("Gateway approval event shapes", .timeLimit(.minutes(1)))
struct GatewayApprovalEventShapeTests {
    typealias Harness = GatewayServerTestHarness

    @Test
    func approvalEventsUseTheUpstreamRequestedAndResolvedShapes() async throws {
        let stack = await Harness.runtimeStack("robust-approval-events", turns: [])
        let events = await stack.server.events(filter: .only(["exec.approval.requested", "exec.approval.resolved", "openclaw.approval.requested"]))
        let requested = try Harness.payload(await Harness.call(stack.server, "exec.approval.request", [
            "command": AnyCodable("git push --force"),
            "host": AnyCodable("gateway"),
            "warningText": AnyCodable("Rewrites history"),
            "unavailableDecisions": AnyCodable([AnyCodable("allow-always")]),
            "twoPhase": AnyCodable(true),
        ]))
        let id = try #require(requested["id"]?.stringValue)
        _ = await Harness.call(stack.server, "exec.approval.resolve", [
            "id": AnyCodable(id), "decision": AnyCodable("allow-once"), "reviewer": AnyCodable(["channel": AnyCodable("slack"), "senderId": AnyCodable("u1")]),
        ])
        let frames = try await Harness.collect(events, "exec.approval.resolved") { frames in frames.contains { $0.event == "exec.approval.resolved" } }
        #expect(frames.map(\.event) == ["exec.approval.requested", "exec.approval.resolved"])

        let requestedEvent = try #require(frames.first { $0.event == "exec.approval.requested" }?.payload?.dictionaryValue)
        #expect(requestedEvent["id"] == AnyCodable(id))
        #expect(requestedEvent["approvalKind"] == AnyCodable("exec"))
        #expect(requestedEvent["createdAtMs"] != nil)
        #expect(requestedEvent["expiresAtMs"] != nil)
        #expect(requestedEvent["presentation"] == nil)
        let request = try #require(requestedEvent["request"]?.dictionaryValue)
        #expect(request["command"] == AnyCodable("git push --force"))
        #expect(request["host"] == AnyCodable("gateway"))
        #expect(request["warningText"] == AnyCodable("Rewrites history"))
        #expect(request["unavailableDecisions"] == AnyCodable([AnyCodable("allow-always")]))

        let resolvedEvent = try #require(frames.first { $0.event == "exec.approval.resolved" }?.payload?.dictionaryValue)
        #expect(resolvedEvent["id"] == AnyCodable(id))
        #expect(resolvedEvent["decision"] == AnyCodable("allow-once"))
        #expect(resolvedEvent["resolvedBy"] == AnyCodable("slack:u1"))
        #expect(resolvedEvent["ts"]?.int64Value != nil)
        #expect(resolvedEvent["request"]?.dictionaryValue?["command"] == AnyCodable("git push --force"))

        // The list rows and the live events share one shape.
        _ = try Harness.payload(await Harness.call(stack.server, "exec.approval.request", [
            "command": AnyCodable("ls"), "twoPhase": AnyCodable(true),
        ]))
        let rows = try #require(await Harness.call(stack.server, "exec.approval.list").payload?.arrayValue)
        #expect(rows.first?.dictionaryValue?["request"]?.dictionaryValue?["command"] == AnyCodable("ls"))
        #expect(rows.first?.dictionaryValue?["approvalKind"] == AnyCodable("exec"))

        // System-agent approvals use the upstream `openclaw.approval.*` family.
        let systemAgent = await stack.runtime.approvals.request(
            presentation: AgentApprovalPresentation(kind: .systemAgent, title: "Update config?", allowedDecisions: [.allowOnce, .deny])
        )
        #expect(AgentGatewayApprovalEvents.eventName(for: systemAgent) == "openclaw.approval.requested")
        _ = await stack.runtime.approvals.cancel(id: systemAgent.id)
        let cancelled = try #require(await stack.runtime.approvals.get(id: systemAgent.id))
        #expect(AgentGatewayApprovalEvents.eventName(for: cancelled) == "openclaw.approval.resolved")
        #expect(AgentGatewayApprovalEvents.resolvedPayload(cancelled)["terminalStatus"] == AnyCodable("cancelled"))
        #expect(AgentGatewayApprovalEvents.resolvedPayload(cancelled)["decision"] == AnyCodable("deny"))
    }
}
