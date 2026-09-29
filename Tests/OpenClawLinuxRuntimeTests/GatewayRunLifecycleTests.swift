import Foundation
import Testing
import OpenClawCore
@testable import OpenClawGateway
import OpenClawModels
import OpenClawProtocol
@testable import OpenClawAgents

/// Built-in run tracking, client timeouts, pagination cursors, run-id collisions and
/// `progressCard.put` validation (2026.3.0 FX1 review fixes).
@Suite("Gateway run lifecycle")
struct GatewayRunLifecycleTests {
    typealias Harness = GatewayServerTestHarness

    enum RunFailure: Error, LocalizedError {
        case exploded
        var errorDescription: String? { "exploded" }
    }

    /// Bare server whose `runAgent` handler runs `body` for each run (run id = idempotency key).
    static func bareServer(_ name: String, body: @escaping @Sendable (GatewayAgentRequest) async throws -> GatewayAgentWaitResult) -> GatewayServer {
        Harness.bareServer(name, handlers: GatewayServerHandlers(runAgent: { request in
            let runID = request.idempotencyKey ?? UUID().uuidString
            return GatewayAgentExecution(runID: runID, task: Task { try await body(request) })
        })).0
    }

    static func ok(_ request: GatewayAgentRequest) -> GatewayAgentWaitResult {
        GatewayAgentWaitResult(runID: request.idempotencyKey ?? "", status: "ok", sessionKey: request.sessionKey, output: request.message)
    }

    // MARK: - Built-in agent.wait / sessions.abort

    @Test
    func builtinAgentWaitTimesOutWithoutWaitingForTheRun() async throws {
        let server = Self.bareServer("lifecycle-wait-timeout") { request in
            try await Task.sleep(nanoseconds: 10_000_000_000)
            return Self.ok(request)
        }
        let accepted = try Harness.payload(await Harness.call(server, "agent", ["message": AnyCodable("slow"), "idempotencyKey": AnyCodable("slow-1")]))
        #expect(accepted["runId"] == AnyCodable("slow-1"))
        let started = Date()
        let waited = try Harness.payload(await Harness.call(server, "agent.wait", ["runId": AnyCodable("slow-1"), "timeoutMs": AnyCodable(50)]))
        #expect(waited["status"] == AnyCodable("timeout"))
        // Well before the 10 s run ends (generous margin for loaded CI machines).
        #expect(Date().timeIntervalSince(started) < 5)
        // The run keeps being tracked after a timed-out wait.
        #expect(await server.trackedRuns["slow-1"] != nil)
        let aborted = try Harness.payload(await Harness.call(server, "sessions.abort", ["runId": AnyCodable("slow-1")]))
        #expect(aborted["status"] == AnyCodable("aborted"))
        let final = try Harness.payload(await Harness.call(server, "agent.wait", ["runId": AnyCodable("slow-1"), "timeoutMs": AnyCodable(5_000)]))
        #expect(final["status"] == AnyCodable("error"))
        #expect(final["error"] == AnyCodable("aborted"))
    }

    @Test
    func failingAndFinishedBuiltinRunsAreReportedAndEvicted() async throws {
        let server = Self.bareServer("lifecycle-evict") { request in
            if request.message == "explode" {
                throw RunFailure.exploded
            }
            return Self.ok(request)
        }
        _ = await Harness.call(server, "agent", ["message": AnyCodable("explode"), "idempotencyKey": AnyCodable("boom-1")])
        let failed = try Harness.payload(await Harness.call(server, "agent.wait", ["runId": AnyCodable("boom-1"), "timeoutMs": AnyCodable(5_000)]))
        #expect(failed["status"] == AnyCodable("error"))
        #expect(failed["error"] == AnyCodable("exploded"))
        #expect(failed["endedAt"] != nil)

        // A run nobody waits on leaves the active tables when it finishes.
        _ = await Harness.call(server, "sessions.send", [
            "key": AnyCodable("agent:main:quick"), "message": AnyCodable("quick"), "idempotencyKey": AnyCodable("quick-1"),
        ])
        for _ in 0..<200 where await server.completedRuns["quick-1"] == nil {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(await server.agentRuns.isEmpty)
        #expect(await server.trackedRuns.isEmpty)
        let abortByKey = try Harness.payload(await Harness.call(server, "sessions.abort", ["key": AnyCodable("agent:main:quick")]))
        #expect(abortByKey["status"] == AnyCodable("no-active-run"))
        #expect(abortByKey["abortedRunId"] == AnyCodable.nullValue)
        let abortByID = try Harness.payload(await Harness.call(server, "sessions.abort", ["runId": AnyCodable("boom-1")]))
        #expect(abortByID["status"] == AnyCodable("no-active-run"))
        let late = try Harness.payload(await Harness.call(server, "agent.wait", ["runId": AnyCodable("quick-1")]))
        #expect(late["status"] == AnyCodable("ok"))
        #expect(late["output"] == AnyCodable("quick"))
    }

    // MARK: - Client timeouts

    @Test
    func hugeClientTimeoutsClampInsteadOfTrapping() async throws {
        let bare = Self.bareServer("lifecycle-timeouts-bare") { request in Self.ok(request) }
        let upstreamSeconds = await Harness.call(bare, "agent", [
            "message": AnyCodable("hi"), "idempotencyKey": AnyCodable("t-1"), "timeout": AnyCodable(9_223_372_036_854_775),
        ])
        #expect(upstreamSeconds.ok)
        let hugeWait = try Harness.payload(await Harness.call(bare, "agent.wait", ["runId": AnyCodable("t-1"), "timeoutMs": AnyCodable(Int.max)]))
        #expect(hugeWait["status"] == AnyCodable("ok"))

        let stack = await Harness.runtimeStack("lifecycle-timeouts", turns: [], fallback: ScriptedToolProvider.text("done"))
        let sent = try Harness.payload(await Harness.call(stack.server, "sessions.send", [
            "key": AnyCodable("agent:main:main"), "message": AnyCodable("hi"), "timeoutMs": AnyCodable(100_000_000_000_000),
        ]))
        let runID = try #require(sent["runId"]?.stringValue)
        let waited = try Harness.payload(await Harness.call(stack.server, "agent.wait", ["runId": AnyCodable(runID), "timeoutMs": AnyCodable(Int.max)]))
        #expect(waited["status"] == AnyCodable("ok"))
        #expect(await Harness.call(stack.server, "agent", [
            "message": AnyCodable("hi"), "idempotencyKey": AnyCodable("t-2"), "timeoutMs": AnyCodable(Int64.max),
        ]).ok)

        let question = await Harness.call(stack.server, "question.request", [
            "questions": AnyCodable([AnyCodable([
                "questionId": AnyCodable("q1"),
                "header": AnyCodable("Proceed"),
                "question": AnyCodable("Proceed?"),
                "options": AnyCodable([AnyCodable(["label": AnyCodable("Yes")]), AnyCodable(["label": AnyCodable("No")])]),
            ])]),
            "timeoutMs": AnyCodable(Int64.max),
        ])
        #expect(question.ok, "\(String(describing: question.error))")
        let exec = try Harness.payload(await Harness.call(stack.server, "exec.approval.request", [
            "command": AnyCodable("ls"), "twoPhase": AnyCodable(true), "timeoutMs": AnyCodable(Int64.max),
        ]))
        let expiresAt = try #require(exec["expiresAtMs"]?.int64Value)
        let createdAt = try #require(exec["createdAtMs"]?.int64Value)
        #expect(expiresAt - createdAt > 0)
        #expect(expiresAt - createdAt <= GatewayTimeouts.maxTimeoutMs)
        let pluginTooLong = await Harness.call(stack.server, "plugin.approval.request", [
            "title": AnyCodable("Run?"), "twoPhase": AnyCodable(true), "timeoutMs": AnyCodable(600_001),
        ])
        #expect(pluginTooLong.error?.code == ErrorCode.invalidRequest.rawValue)

        #expect(GatewayTimeouts.clampedMilliseconds(AnyCodable(1e300)) == GatewayTimeouts.maxTimeoutMs)
        #expect(GatewayTimeouts.clampedMilliseconds(AnyCodable(-5)) == 0)
        #expect(GatewayTimeouts.clampedMilliseconds(AnyCodable("5")) == nil)
        #expect(GatewayTimeouts.nanoseconds(milliseconds: Int64.max) == UInt64(Int64.max))
        #expect(GatewayTimeouts.nanoseconds(milliseconds: Int64.max / 1_000_000) == UInt64(Int64.max / 1_000_000) * 1_000_000)
        #expect(GatewayTimeouts.nanoseconds(milliseconds: -1) == 0)
    }

    // MARK: - Pagination cursors

    @Test
    func malformedCursorsAreRejectedAndHugeOnesDoNotOverflow() async throws {
        let stack = await Harness.runtimeStack("lifecycle-cursors", turns: [], fallback: ScriptedToolProvider.text("done"))
        let ledger = TaskLedger()
        await ledger.attach(to: stack.server, runtime: stack.runtime)
        let sent = try Harness.payload(await Harness.call(stack.server, "sessions.send", [
            "key": AnyCodable("agent:main:main"), "message": AnyCodable("hi"),
        ]))
        let runID = try #require(sent["runId"]?.stringValue)
        _ = await Harness.call(stack.server, "agent.wait", ["runId": AnyCodable(runID), "timeoutMs": AnyCodable(5_000)])
        let task = await ledger.create(kind: .tool, sessionKey: "agent:main:main")

        for method in ["tasks.list", "approval.history"] {
            for cursor in ["-1", "abc"] {
                let refused = await Harness.call(stack.server, method, ["cursor": AnyCodable(cursor)])
                #expect(refused.error?.code == ErrorCode.invalidRequest.rawValue, "\(method) cursor \(cursor)")
            }
            for cursor in ["9223372036854775807", "9223372036854775000"] {
                let empty = await Harness.call(stack.server, method, ["cursor": AnyCodable(cursor)])
                #expect(empty.ok, "\(method) cursor \(cursor)")
            }
        }
        let history = { (cursor: String) async in
            await Harness.call(stack.server, "tasks.history", ["taskId": AnyCodable(task.id), "cursor": AnyCodable(cursor)])
        }
        #expect(await history("-1").error?.code == ErrorCode.invalidRequest.rawValue)
        #expect(await history("9223372036854775807").ok)
        #expect(await history("9223372036854775000").ok)
        let firstPage = try Harness.payload(await Harness.call(stack.server, "tasks.history", [
            "taskId": AnyCodable(task.id), "limit": AnyCodable(1),
        ]))
        #expect(firstPage["messages"]?.arrayValue?.count == 1)
        #expect(firstPage["nextCursor"] == AnyCodable("1"))

        // Library APIs clamp instead of trapping.
        #expect(await ledger.list(cursor: "-1").tasks.count == 1)
        #expect(await stack.runtime.approvals.history(cursor: "-1").items.isEmpty)
        #expect(GatewayOffsetCursor.page(cursor: "2", count: 5, pageSize: Int.max).map { [$0.start, $0.end] } == [2, 5])
        #expect(GatewayOffsetCursor.page(cursor: "9223372036854775000", count: 5, pageSize: 200) == nil)
    }

    // MARK: - Run ids

    @Test
    func reusedIdempotencyKeysDoNotStartASecondRunUnderTheSameID() async throws {
        let stack = await Harness.runtimeStack("lifecycle-run-ids", turns: [
            { _ in
                try await Task.sleep(nanoseconds: 3_000_000_000)
                return ModelGenerationResponse(text: "first", providerID: "scripted")
            },
        ], fallback: ScriptedToolProvider.text("later"))
        let chat = try Harness.payload(await Harness.call(stack.server, "chat.send", [
            "sessionKey": AnyCodable("agent:main:a"), "message": AnyCodable("one"), "idempotencyKey": AnyCodable("msg-1"),
        ]))
        #expect(chat["runId"] == AnyCodable("msg-1"))
        let otherSession = try Harness.payload(await Harness.call(stack.server, "sessions.send", [
            "key": AnyCodable("agent:main:b"), "message": AnyCodable("two"), "idempotencyKey": AnyCodable("msg-1"),
        ]))
        #expect(otherSession["status"] == AnyCodable("in_flight"))
        #expect(otherSession["runStarted"] == AnyCodable(false))
        let agent = try Harness.payload(await Harness.call(stack.server, "agent", [
            "message": AnyCodable("three"), "idempotencyKey": AnyCodable("msg-1"),
        ]))
        #expect(agent["status"] == AnyCodable("in_flight"))
        #expect(await stack.runtime.activeRunIDs() == ["msg-1"])
        let waited = try Harness.payload(await Harness.call(stack.server, "agent.wait", ["runId": AnyCodable("msg-1"), "timeoutMs": AnyCodable(5_000)]))
        #expect(waited["output"] == AnyCodable("first"))
    }

    // MARK: - progressCard.put

    @Test
    func progressCardPutRejectsMistypedParamsAndKeepsTheCard() async throws {
        let stack = await Harness.runtimeStack("lifecycle-progress", turns: [])
        let cards = ProgressCardStore()
        await cards.attach(to: stack.server, runtime: stack.runtime)
        let put = await Harness.call(stack.server, "progressCard.put", [
            "sessionKey": AnyCodable("agent:main:main"),
            "plan": AnyCodable([AnyCodable(["step": AnyCodable("a"), "status": AnyCodable("pending")])]),
        ])
        #expect(put.ok)
        let invalid: [[String: AnyCodable]] = [
            ["plan": AnyCodable([AnyCodable(["step": AnyCodable("a")])])],
            ["plan": AnyCodable("not an array")],
            ["plan": AnyCodable([AnyCodable(["step": AnyCodable(1), "status": AnyCodable("pending")])])],
            ["plan": AnyCodable([AnyCodable(["step": AnyCodable("a"), "status": AnyCodable("done")])])],
            ["markdown": AnyCodable(5)],
            ["expectedRevision": AnyCodable("1")],
        ]
        for extra in invalid {
            var params: [String: AnyCodable] = ["sessionKey": AnyCodable("agent:main:main")]
            params.merge(extra) { _, new in new }
            let response = await Harness.call(stack.server, "progressCard.put", params)
            #expect(response.error?.code == ErrorCode.invalidRequest.rawValue, "\(extra)")
        }
        let card = try #require(await cards.card(sessionKey: "agent:main:main"))
        #expect(card.revision == 1)
        #expect(card.steps == [AgentProgressStep(step: "a", status: "pending")])
    }
}
