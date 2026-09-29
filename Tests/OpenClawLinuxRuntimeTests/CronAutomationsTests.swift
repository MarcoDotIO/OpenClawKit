import Foundation
import Testing
import OpenClawAgents
import OpenClawCore
import OpenClawGateway
import OpenClawProtocol

@Suite("Cron expressions, scheduler, automations tool and cron RPC")
struct CronAutomationsTests {
    actor Recorder {
        private(set) var runs: [AutomationJobRun] = []
        func append(_ run: AutomationJobRun) { self.runs.append(run) }
    }

    private static func utc(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: text)!
    }

    @Test
    func parsesFieldsNamesAndVixieDaySemantics() throws {
        let expression = try CronExpression("*/15 9-17 * jan,mar-apr mon-fri")
        #expect(expression.minutes == [0, 15, 30, 45])
        #expect(expression.hours == Array(9...17))
        #expect(expression.months == [1, 3, 4])
        #expect(expression.daysOfWeek == [1, 2, 3, 4, 5])
        #expect(try CronExpression("0 0 * * 7").daysOfWeek == [0])
        #expect(try CronExpression("@daily").minutes == [0])
        let either = try CronExpression("0 0 13 * 5")
        #expect(either.matchesDay(day: 13, month: 1, weekday: 2))
        #expect(either.matchesDay(day: 2, month: 1, weekday: 5))
        #expect(!either.matchesDay(day: 2, month: 1, weekday: 2))
        #expect(throws: OpenClawCoreError.self) { _ = try CronExpression("61 * * * *") }
        #expect(throws: OpenClawCoreError.self) { _ = try CronExpression("* * *") }
        #expect(throws: OpenClawCoreError.self) { _ = try CronExpression("*/0 * * * *") }
    }

    @Test
    func nextFireIsDSTSafeInNewYork() throws {
        let newYork = try #require(TimeZone(identifier: "America/New_York"))
        // Spring forward 2026-03-08: 02:30 does not exist and fires at the 03:00 EDT transition.
        let gap = try CronExpression("30 2 * * *")
        #expect(gap.nextDate(after: Self.utc("2026-03-08T05:00:00Z"), in: newYork) == Self.utc("2026-03-08T07:00:00Z"))
        #expect(gap.nextDate(after: Self.utc("2026-03-08T07:00:00Z"), in: newYork) == Self.utc("2026-03-09T06:30:00Z"))
        // Fall back 2026-11-01: 01:30 happens twice and fires once (first instant, EDT).
        let repeated = try CronExpression("30 1 * * *")
        let first = try #require(repeated.nextDate(after: Self.utc("2026-11-01T04:00:00Z"), in: newYork))
        #expect(first == Self.utc("2026-11-01T05:30:00Z"))
        #expect(repeated.nextDate(after: first, in: newYork) == Self.utc("2026-11-02T06:30:00Z"))
        // Weekday business hours.
        let weekday = try CronExpression("0 9 * * 1-5")
        #expect(weekday.nextDate(after: Self.utc("2026-09-26T12:00:00Z"), in: newYork) == Self.utc("2026-09-28T13:00:00Z"))
        #expect(try CronExpression("0 0 30 2 *").nextDate(after: Date(), in: newYork, horizonYears: 2) == nil)
    }

    @Test
    func everyAtAndStaggerSchedules() throws {
        let every = AutomationJob(
            name: "e",
            createdAtMs: 1_000,
            schedule: .every(everyMs: 60_000, anchorMs: 10_000),
            payload: .systemEvent(text: "x", toolsAllow: nil)
        )
        #expect(every.nextRunAtMs(after: 5_000) == 10_000)
        #expect(every.nextRunAtMs(after: 10_000) == 70_000)
        #expect(every.nextRunAtMs(after: 69_999) == 70_000)
        let past = AutomationJob(name: "a", schedule: .at("2020-01-01T00:00:00Z"), payload: .systemEvent(text: "x", toolsAllow: nil))
        #expect(past.nextRunAtMs(after: AutomationClock.nowMs()) == 1_577_836_800_000)
        #expect(AutomationClock.parseAbsoluteTimeMs("2026-01-01T10:00:00.250+01:00") == 1_767_258_000_250)
        #expect(AutomationClock.parseAbsoluteTimeMs("2026-01-01") == 1_767_225_600_000)
        #expect(AutomationClock.parseAbsoluteTimeMs("nope") == nil)
        let stagger = AutomationJob.staggerOffset(jobID: "job-1", staggerMs: 60_000)
        #expect(stagger == AutomationJob.staggerOffset(jobID: "job-1", staggerMs: 60_000))
        #expect((0..<60_000).contains(stagger))
        let cron = AutomationJob(
            id: "job-1",
            name: "c",
            schedule: .cron(expr: "0 * * * *", tz: "UTC", staggerMs: 60_000),
            payload: .systemEvent(text: "x", toolsAllow: nil)
        )
        let next = try #require(cron.nextRunAtMs(after: 1_767_225_600_000))
        #expect(next == 1_767_225_600_000 + 3_600_000 + stagger || next == 1_767_225_600_000 + stagger)
    }

    @Test
    func wireShapesRoundTripIncludingUnsupportedKinds() throws {
        let json = """
        {"id":"j1","name":"stream job","enabled":true,"createdAtMs":1,"updatedAtMs":2,
         "schedule":{"kind":"stream","command":["tail","-f","x"]},
         "payload":{"kind":"script","script":"return 1"},
         "sessionTarget":"session:agent:main:custom","wakeMode":"next-heartbeat",
         "state":{"nextRunAtMs":5,"lastRunStatus":"ok"},
         "delivery":{"mode":"announce"}}
        """
        let job = try JSONDecoder().decode(AutomationJob.self, from: Data(json.utf8))
        #expect(job.schedule.kind == "stream")
        #expect(job.payload.kind == "script")
        #expect(job.sessionTarget == .session("agent:main:custom"))
        #expect(job.wakeMode == .nextHeartbeat)
        #expect(!job.isRunnable)
        #expect(job.extra["delivery"] != nil)
        let again = try JSONDecoder().decode(AutomationJob.self, from: JSONEncoder().encode(job))
        #expect(again == job)
        let wire = try JSONDecoder().decode(OpenClawProtocol.CronJob.self, from: JSONEncoder().encode(job))
        #expect(wire.nextrunatms == 5)
        #expect(wire.schedule.dictionaryValue?["kind"]?.stringValue == "stream")
    }

    @Test
    func schedulerRunsDueJobsPersistsAndResolvesSessions() async throws {
        let root = try RuntimeExtTestSupport.temporaryDirectory("cron")
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("cron/jobs.json")
        let recorder = Recorder()
        let scheduler = CronScheduler(storeURL: storeURL, defaultAgentID: "main")
        await scheduler.setExecutor { run in
            await recorder.append(run)
            return AutomationRunOutcome(status: .ok, summary: "done")
        }
        let isolated = try await scheduler.addJob(AutomationJob(
            id: "iso", name: "isolated", agentId: "ops",
            schedule: .at("2020-01-01T00:00:00Z"),
            payload: .agentTurn(CronAgentTurnPayload(message: "check servers")),
            sessionTarget: .isolated
        ))
        #expect(isolated.deleteAfterRun == true)
        #expect(isolated.state.nextRunAtMs == 1_577_836_800_000)
        _ = try await scheduler.addJob(AutomationJob(
            id: "rec", name: "recurring",
            schedule: .every(everyMs: 3_600_000, anchorMs: 0),
            payload: .systemEvent(text: "tick", toolsAllow: nil)
        ))
        await #expect(throws: OpenClawCoreError.self) {
            _ = try await scheduler.addJob(AutomationJob(
                name: "bad",
                schedule: .unsupported(kind: "on-exit", raw: [:]),
                payload: .systemEvent(text: "x", toolsAllow: nil)
            ))
        }
        await #expect(throws: OpenClawCoreError.self) {
            _ = try await scheduler.addJob(AutomationJob(
                name: "badtz",
                schedule: .cron(expr: "* * * * *", tz: "Mars/Olympus", staggerMs: nil),
                payload: .systemEvent(text: "x", toolsAllow: nil)
            ))
        }

        let records = await scheduler.runDueJobs()
        #expect(records.map(\.jobId) == ["iso"])
        let run = try #require(await recorder.runs.first)
        #expect(run.sessionKey.hasPrefix("agent:ops:cron:iso:"))
        #expect(run.sessionKey == "agent:ops:cron:iso:\(run.runID)")
        #expect(await scheduler.automationJob(id: "iso") == nil)

        let forced = try #require(try await scheduler.runJob(id: "rec", force: true))
        #expect(forced.status == .ok && forced.summary == "done")
        #expect(await recorder.runs.last?.sessionKey == "agent:main:main")
        #expect(try await scheduler.runJob(id: "rec", force: false) == nil)
        #expect(await scheduler.runs(jobID: "rec").count == 1)
        #expect(await scheduler.nextWakeDate != nil)

        let reloaded = CronScheduler(storeURL: storeURL)
        try await reloaded.load()
        #expect(await reloaded.automationJobList().map(\.id) == ["rec"])
        #expect(await reloaded.runs(jobID: "rec").first?.status == .ok)
        #expect(CronScheduler.sessionKey(
            for: AutomationJob(
                name: "c",
                sessionKey: "chat:1",
                schedule: .every(everyMs: 1, anchorMs: nil),
                payload: .systemEvent(text: "x", toolsAllow: nil),
                sessionTarget: .current
            ),
            runID: "r"
        ) == "chat:1")
    }

    @Test
    func automationsToolManagesJobsAndCronAliasResolves() async throws {
        let scheduler = CronScheduler(storeURL: nil)
        await scheduler.setExecutor { _ in AutomationRunOutcome(status: .ok) }
        let registry = AgentToolRegistry(tools: [AutomationsTool(scheduler: scheduler)])
        #expect(AgentToolRegistry.canonicalName("cron") == "automations")
        let context = AgentToolInvocationContext(sessionKey: "agent:main:chat", agentID: "main")

        let added = try await registry.invoke(AgentToolCall(name: "cron", arguments: [
            "action": AnyCodable("add"),
            "job": AnyCodable([
                "name": AnyCodable("standup"),
                "schedule": AnyCodable(["kind": AnyCodable("cron"), "expr": AnyCodable("0 9 * * 1-5"), "tz": AnyCodable("America/New_York")]),
                "payload": AnyCodable(["kind": AnyCodable("agentTurn"), "message": AnyCodable("Post the standup")]),
                "sessionTarget": AnyCodable("current"),
            ]),
        ]), context: context)
        #expect(!added.isError, "\(added.output.text)")
        let jobID = try #require(added.value.dictionaryValue?["id"]?.stringValue)
        #expect(added.value.dictionaryValue?["sessionKey"]?.stringValue == "agent:main:chat")

        let listed = try await registry.invoke(AgentToolCall(name: "automations", arguments: ["action": AnyCodable("list")]), context: context)
        #expect(listed.value.dictionaryValue?["total"]?.intValue == 1)

        let updated = try await registry.invoke(AgentToolCall(name: "automations", arguments: [
            "action": AnyCodable("update"), "jobId": AnyCodable(jobID),
            "job": AnyCodable(["enabled": AnyCodable(false), "payload": AnyCodable(["message": AnyCodable("Post it now")])]),
        ]), context: context)
        #expect(updated.value.dictionaryValue?["enabled"]?.boolValue == false)
        #expect(updated.value.dictionaryValue?["payload"]?.dictionaryValue?["message"]?.stringValue == "Post it now")

        let ran = try await registry.invoke(
            AgentToolCall(name: "automations", arguments: ["action": AnyCodable("run"), "jobId": AnyCodable(jobID), "runMode": AnyCodable("force")]),
            context: context
        )
        #expect(ran.value.dictionaryValue?["status"]?.stringValue == "ok")
        let runs = try await registry.invoke(
            AgentToolCall(name: "automations", arguments: ["action": AnyCodable("runs"), "jobId": AnyCodable(jobID)]),
            context: context
        )
        #expect(runs.value.dictionaryValue?["runs"]?.arrayValue?.count == 1)

        let unsupported = try await registry.invoke(AgentToolCall(name: "automations", arguments: [
            "action": AnyCodable("add"),
            "job": AnyCodable(["name": AnyCodable("x"), "schedule": AnyCodable(["kind": AnyCodable("on-exit"), "command": AnyCodable("sleep 1")]),
                               "payload": AnyCodable(["kind": AnyCodable("systemEvent"), "text": AnyCodable("x")])]),
        ]), context: context)
        #expect(unsupported.isError)
        #expect(unsupported.output.text.contains("on-exit"))

        let nextCheck = try await registry.invoke(
            AgentToolCall(name: "automations", arguments: ["action": AnyCodable("next_check"), "in": AnyCodable("15m")]),
            context: context
        )
        #expect(nextCheck.value.dictionaryValue?["schedule"]?.dictionaryValue?["kind"]?.stringValue == "at")
        #expect(AutomationJobDraft.parseDurationMs("2h") == 7_200_000)

        let removed = try await registry.invoke(
            AgentToolCall(name: "automations", arguments: ["action": AnyCodable("remove"), "jobId": AnyCodable(jobID)]),
            context: context
        )
        #expect(removed.value.dictionaryValue?["removed"]?.boolValue == true)
    }

    @Test
    func cronRPCsAddListRunAndRejectUnsupported() async throws {
        let root = try RuntimeExtTestSupport.temporaryDirectory("cron-rpc")
        defer { try? FileManager.default.removeItem(at: root) }
        let scheduler = CronScheduler(storeURL: nil)
        await scheduler.setExecutor { _ in AutomationRunOutcome(status: .ok, summary: "ran") }
        let server = RuntimeExtTestSupport.makeGatewayServer(root: root)
        await registerCronGatewayMethods(on: server, scheduler: scheduler)
        let events = await server.events()

        let add = await RuntimeExtTestSupport.call(server, "cron.add", params: [
            "name": AnyCodable("hourly"),
            "schedule": AnyCodable(["kind": AnyCodable("every"), "everyMs": AnyCodable(3_600_000)]),
            "payload": AnyCodable(["kind": AnyCodable("systemEvent"), "text": AnyCodable("tick")]),
            "sessionTarget": AnyCodable("main"),
            "wakeMode": AnyCodable("now"),
        ])
        #expect(add.ok, "\(String(describing: add.error))")
        let id = try #require(add.payload?.dictionaryValue?["id"]?.stringValue)
        var iterator = events.makeAsyncIterator()
        let event = await iterator.next()
        #expect(event?.event == "cron")

        let list = await RuntimeExtTestSupport.call(server, "cron.list", params: [:])
        #expect(list.payload?.dictionaryValue?["total"]?.intValue == 1)
        let run = await RuntimeExtTestSupport.call(server, "cron.run", params: ["id": AnyCodable(id), "mode": AnyCodable("force")])
        #expect(run.payload?.dictionaryValue?["ran"]?.boolValue == true)
        let runs = await RuntimeExtTestSupport.call(server, "cron.runs", params: ["id": AnyCodable(id)])
        #expect(runs.payload?.dictionaryValue?["entries"]?.arrayValue?.first?.dictionaryValue?["summary"]?.stringValue == "ran")
        let update = await RuntimeExtTestSupport.call(
            server,
            "cron.update",
            params: ["jobId": AnyCodable(id), "patch": AnyCodable(["description": AnyCodable("hourly tick")])]
        )
        #expect(update.payload?.dictionaryValue?["description"]?.stringValue == "hourly tick")
        let status = await RuntimeExtTestSupport.call(server, "cron.status", params: [:])
        #expect(status.payload?.dictionaryValue?["jobs"]?.intValue == 1)

        let unsupported = await RuntimeExtTestSupport.call(server, "cron.add", params: [
            "name": AnyCodable("cmd"),
            "schedule": AnyCodable(["kind": AnyCodable("every"), "everyMs": AnyCodable(1_000)]),
            "payload": AnyCodable(["kind": AnyCodable("command"), "argv": AnyCodable(["ls"])]),
            "sessionTarget": AnyCodable("isolated"),
            "wakeMode": AnyCodable("now"),
        ])
        #expect(unsupported.error?.code == ErrorCode.invalidRequest.rawValue)
        let missing = await RuntimeExtTestSupport.call(server, "cron.get", params: ["id": AnyCodable("nope")])
        #expect(missing.error?.code == ErrorCode.invalidRequest.rawValue)
        let scratch = await RuntimeExtTestSupport.call(server, "cron.scratch.get", params: ["id": AnyCodable(id)])
        #expect(scratch.error?.code == ErrorCode.unavailable.rawValue)
        let remove = await RuntimeExtTestSupport.call(server, "cron.remove", params: ["id": AnyCodable(id)])
        #expect(remove.payload?.dictionaryValue?["removed"]?.boolValue == true)
    }

    @Test
    func intervalRulesAdaptToJobsAndLegacyIntervalJobsStillRun() async throws {
        let rule = AutomationRule(name: "digest", sessionKey: "main", prompt: "Summarize", trigger: AutomationTrigger(intervalSeconds: 600))
        let job = try #require(rule.automationJob)
        #expect(job.schedule == .every(everyMs: 600_000, anchorMs: nil))
        #expect(job.sessionTarget == .session("main"))
        #expect(AutomationRule(
            name: "evt",
            sessionKey: "m",
            prompt: "p",
            trigger: AutomationTrigger(diagnosticEventSubsystem: "runtime", eventName: "x")
        ).automationJob == nil)

        let scheduler = CronScheduler()
        await scheduler.addOrUpdate(OpenClawCore.CronJob(id: "legacy", intervalSeconds: 60, payload: "run", nextRunAt: Date().addingTimeInterval(-1)))
        #expect(await scheduler.runDue().map(\.jobID) == ["legacy"])
        #expect(OpenClawCore.CronJob(id: "l", intervalSeconds: 5, payload: "p", nextRunAt: Date()).automationJob.schedule.kind == "every")
    }
}
