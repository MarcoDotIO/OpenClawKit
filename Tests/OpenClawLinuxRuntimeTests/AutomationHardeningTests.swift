import Foundation
import Testing
import OpenClawAgents
@testable import OpenClawCore
import OpenClawProtocol

@Suite("Automation scheduler and hook gate hardening", .timeLimit(.minutes(1)))
struct AutomationHardeningTests {
    private static func utc(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    private static let event = CronPayload.systemEvent(text: "x", toolsAllow: nil)

    // MARK: - Scheduler loop

    @Test
    func editingJobsFromARunningJobDoesNotCancelIt() async throws {
        let scheduler = CronScheduler()
        await scheduler.setExecutor { run in
            if run.job.name == "check-in" {
                // An agent turn scheduling its next check-in and editing its own job.
                _ = try await scheduler.addJob(AutomationJob(name: "next", schedule: .every(everyMs: 3_600_000, anchorMs: nil), payload: Self.event))
                _ = try await scheduler.updateJob(id: run.job.id) { $0.description = "edited" }
                try await Task.sleep(nanoseconds: 200_000_000)
                try Task.checkCancellation()
            }
            return AutomationRunOutcome(status: .ok)
        }
        let at = ISO8601DateFormatter().string(from: Date())
        let job = try await scheduler.addJob(AutomationJob(name: "check-in", schedule: .at(at), payload: Self.event))
        await scheduler.start()
        try await waitUntil("check-in run recorded") { await !scheduler.runs(jobID: job.id).isEmpty }
        let records = await scheduler.runs(jobID: job.id)
        await scheduler.stop()
        #expect(records.count == 1)
        #expect(records.first?.status == .ok, "the in-flight run was not cancelled: \(records.first?.error ?? "")")
        let next = await scheduler.automationJobList().first { $0.name == "next" }
        #expect(next?.state.nextRunAtMs != nil)
    }

    @Test
    func addingAJobWakesTheSleepingLoop() async throws {
        let scheduler = CronScheduler()
        await scheduler.setExecutor { _ in AutomationRunOutcome(status: .ok) }
        // No jobs: the loop sleeps for its idle cap until a job change wakes it. The cap is past the
        // suite's time limit, so a loop that is not woken fails as a hang instead of running the job
        // late.
        await scheduler._test_setMaximumSleepSeconds(3_600)
        await scheduler.start()
        try await Task.sleep(nanoseconds: 100_000_000)
        let at = ISO8601DateFormatter().string(from: Date().addingTimeInterval(1))
        let job = try await scheduler.addJob(AutomationJob(name: "soon", schedule: .at(at), payload: Self.event))
        try await waitUntil("job run after the wake") { await !scheduler.runs(jobID: job.id).isEmpty }
        let records = await scheduler.runs(jobID: job.id)
        await scheduler.stop()
        #expect(records.first?.status == .ok)
    }

    @Test
    func runningJobsAreNotDueAgain() async throws {
        let scheduler = CronScheduler()
        let gate = AsyncGate()
        await scheduler.setExecutor { _ in
            await gate.wait()
            return AutomationRunOutcome(status: .ok)
        }
        let job = try await scheduler.addJob(AutomationJob(name: "slow", schedule: .every(everyMs: 60_000, anchorMs: 0), payload: Self.event))
        let running = Task { try await scheduler.runJob(id: job.id) }
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(await scheduler.nextWakeDate == nil, "a running job does not keep the loop busy-polling")
        #expect(await scheduler.runDueJobs(now: Date().addingTimeInterval(3_600)).isEmpty)
        await gate.open()
        _ = try await running.value
    }

    // MARK: - every schedules never trap

    @Test
    func everyScheduleArithmeticIsBoundedAndNonTrapping() async throws {
        for everyMs: Int64 in [0, -5] {
            let job = AutomationJob(name: "bad", schedule: .every(everyMs: everyMs, anchorMs: nil), payload: Self.event)
            #expect(job.nextRunAtMs(after: 1_800_000_000_000) == nil)
            await #expect(throws: OpenClawCoreError.self) { _ = try await CronScheduler().addJob(job) }
        }
        let huge = AutomationJob(name: "huge", schedule: .every(everyMs: Int64.max, anchorMs: 1), payload: Self.event)
        #expect(huge.nextRunAtMs(after: 1_800_000_000_000) == nil)
        await #expect(throws: OpenClawCoreError.self) { _ = try await CronScheduler().addJob(huge) }
        let ancient = AutomationJob(name: "ancient", schedule: .every(everyMs: 60_000, anchorMs: Int64.min), payload: Self.event)
        #expect(ancient.nextRunAtMs(after: 1_800_000_000_000) == nil)
        await #expect(throws: OpenClawCoreError.self) { _ = try await CronScheduler().addJob(ancient) }
        let stagger = AutomationJob(name: "stagger", schedule: .cron(expr: "0 * * * *", tz: "UTC", staggerMs: Int64.max), payload: Self.event)
        _ = stagger.nextRunAtMs(after: Int64.min + 1)
        await #expect(throws: OpenClawCoreError.self) { _ = try await CronScheduler().addJob(stagger) }

        let ok = AutomationJob(name: "ok", schedule: .every(everyMs: AutomationClock.maxTimestampMs, anchorMs: 0), payload: Self.event)
        #expect(ok.nextRunAtMs(after: 1_800_000_000_000) == AutomationClock.maxTimestampMs)
        _ = try await CronScheduler().addJob(ok)
    }

    @Test(arguments: [
        #"{"kind":"every","everyMs":9223372036854775807}"#,
        #"{"kind":"every","everyMs":0}"#,
        #"{"kind":"every","everyMs":1000,"anchorMs":-1}"#,
        #"{"kind":"every","everyMs":1000,"anchorMs":9223372036854775807}"#,
        #"{"kind":"cron","expr":"0 * * * *","staggerMs":9223372036854775807}"#,
    ])
    func outOfRangeSchedulesAreRejectedWhenDecoding(json: String) {
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(CronSchedule.self, from: Data(json.utf8))
        }
    }

    @Test
    func modelSuppliedDurationsNeverTrap() {
        for raw in ["inf", "infs", "1e300", "1e300s", "nan", "-5m", "0.0000001s", "1e17d"] {
            #expect(AutomationJobDraft.parseDurationMs(raw) == nil, "\(raw) is rejected")
        }
        #expect(AutomationJobDraft.parseDurationMs("15m") == 900_000)
        #expect(AutomationJobDraft.parseDurationMs("1.5s") == 1_500)
        #expect(AutomationJobDraft.parseDurationMs("90") == 90_000)
        #expect(AutomationClock.durationMs(.infinity) == nil)
        #expect(AutomationClock.durationMs(Double(AutomationClock.maxTimestampMs)) == AutomationClock.maxTimestampMs)
        let rule = AutomationRule(name: "r", sessionKey: "s", prompt: "p", trigger: AutomationTrigger(intervalSeconds: Int.max))
        guard case .every(let everyMs, _)? = rule.automationJob?.schedule else {
            Issue.record("interval rules map to every schedules")
            return
        }
        #expect(everyMs == AutomationClock.maxTimestampMs)
    }

    // MARK: - Six-field cron expressions

    @Test
    func sixFieldExpressionsCarrySeconds() throws {
        let everyFive = try CronExpression("0 */5 * * * *")
        #expect(everyFive.seconds == [0])
        #expect(everyFive.minutes == Array(stride(from: 0, through: 55, by: 5)))
        #expect(try CronExpression("*/5 * * * *").seconds == [0])
        let weekday = try CronExpression("30 0 9 * * 1-5")
        #expect(weekday.seconds == [30])
        let newYork = try #require(TimeZone(identifier: "America/New_York"))
        #expect(weekday.nextDate(after: Self.utc("2026-09-26T12:00:00Z"), in: newYork) == Self.utc("2026-09-28T13:00:30Z"))
        let everySecond = try CronExpression("* * * * * *")
        let utc = try #require(TimeZone(identifier: "UTC"))
        let reference = Self.utc("2026-01-01T00:00:00Z").addingTimeInterval(0.5)
        #expect(everySecond.nextDate(after: reference, in: utc) == Self.utc("2026-01-01T00:00:01Z"))
        // Late in the day the search skips earlier wall-clock times instead of resolving ~86k candidates.
        let started = Date()
        #expect(everySecond.nextDate(after: Self.utc("2026-01-01T23:59:59Z"), in: utc) == Self.utc("2026-01-02T00:00:00Z"))
        #expect(Date().timeIntervalSince(started) < 1)
        // Spring-forward gap: 02:30:15 does not exist and fires at the 03:00:00 EDT transition.
        let gap = try CronExpression("15 30 2 * * *")
        #expect(gap.nextDate(after: Self.utc("2026-03-08T05:00:00Z"), in: newYork) == Self.utc("2026-03-08T07:00:00Z"))
        #expect(throws: OpenClawCoreError.self) { _ = try CronExpression("0 0 0 * * * *") }
        #expect(throws: OpenClawCoreError.self) { _ = try CronExpression("60 * * * * *") }
    }

    @Test
    func upstreamStoresWithoutRunsLoadAndInvalidJobsSurfaceAnError() async throws {
        let root = try RuntimeExtTestSupport.temporaryDirectory("cron-import")
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("jobs.json")
        let json = """
        {"version":1,"jobs":[
          {"id":"six","name":"six","enabled":true,"createdAtMs":1,"updatedAtMs":1,
           "schedule":{"kind":"cron","expr":"0 */5 * * * *","tz":"UTC"},
           "payload":{"kind":"systemEvent","text":"hi"},"sessionTarget":"main","wakeMode":"now","state":{}},
          {"id":"bad","name":"bad","enabled":true,"createdAtMs":1,"updatedAtMs":1,
           "schedule":{"kind":"cron","expr":"not a cron"},
           "payload":{"kind":"systemEvent","text":"hi"},"sessionTarget":"main","wakeMode":"now","state":{"nextRunAtMs":5}}
        ]}
        """
        try json.write(to: storeURL, atomically: true, encoding: .utf8)
        let scheduler = CronScheduler(storeURL: storeURL, defaultTimeZone: TimeZone(identifier: "UTC")!)
        try await scheduler.load()
        let jobs = await scheduler.automationJobList()
        #expect(jobs.count == 2)
        let bad = try #require(jobs.first { $0.id == "bad" })
        #expect(bad.state.nextRunAtMs == nil)
        #expect(bad.state.lastError?.contains("cron") == true)
        let six = try #require(jobs.first { $0.id == "six" })
        #expect(six.state.lastError == nil)
        #expect(six.nextRunAtMs(after: AutomationClock.ms(Self.utc("2026-01-01T00:01:00Z"))) == AutomationClock.ms(Self.utc("2026-01-01T00:05:00Z")))
    }

    // MARK: - before_agent_run gate fails closed

    @Test(arguments: [
        AnyCodable.nullValue,
        AnyCodable("block"),
        AnyCodable(["outcome": AnyCodable("block"), "reason": AnyCodable(403)]),
        AnyCodable(["outcome": AnyCodable("block")]),
        AnyCodable(["outcome": AnyCodable("block"), "reason": AnyCodable("  ")]),
        AnyCodable(["outcome": AnyCodable("block"), "reason": AnyCodable("r"), "message": AnyCodable(false)]),
        AnyCodable(["outcome": AnyCodable("block"), "reason": AnyCodable("r"), "extra": AnyCodable(1)]),
        AnyCodable(["outcome": AnyCodable(1)]),
        AnyCodable(["outcome": AnyCodable("pass"), "x": AnyCodable(1)]),
        AnyCodable([AnyCodable]()),
    ])
    func malformedGateDecisionsBlock(payload: AnyCodable) async {
        let hooks = HookRegistry()
        await hooks.register(.beforeAgentRun) { _ in HookResult(payload: payload) }
        let decision = await hooks.runBeforeAgentRun(BeforeAgentRunEvent(prompt: "hi"))
        #expect(decision == .block(reason: InputGateDecision.invalidDecisionReason))
    }

    @Test
    func wellFormedGateDecisionsAreKept() async throws {
        let hooks = HookRegistry()
        await hooks.register(.beforeAgentRun) { _ in HookResult(payload: nil) }
        await hooks.register(.beforeAgentRun) { _ in HookResult(payload: AnyCodable(["outcome": AnyCodable("pass")])) }
        #expect(await hooks.runBeforeAgentRun(BeforeAgentRunEvent(prompt: "hi")) == .pass)
        await hooks.register(.beforeAgentRun) { _ in
            HookResult(payload: AnyCodable([
                "outcome": AnyCodable("block"), "reason": AnyCodable("policy"), "message": AnyCodable("No"),
                "metadata": AnyCodable(["rule": AnyCodable("r1")]),
            ]))
        }
        let blocked = await hooks.runBeforeAgentRun(BeforeAgentRunEvent(prompt: "hi"))
        #expect(blocked == .block(reason: "policy", message: "No", category: nil, metadata: ["rule": AnyCodable("r1")]))
        let roundTrip = try JSONDecoder().decode(InputGateDecision.self, from: JSONEncoder().encode(blocked))
        #expect(roundTrip == blocked)
    }
}

/// One-shot async gate for tests.
actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !self.isOpen else { return }
        await withCheckedContinuation { self.waiters.append($0) }
    }

    func open() {
        self.isOpen = true
        let waiters = self.waiters
        self.waiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
