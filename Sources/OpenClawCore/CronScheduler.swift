import Foundation
import OpenClawProtocol

/// Definition for a periodic scheduled job (legacy interval API; prefer ``AutomationJob`` with
/// ``CronSchedule/every(everyMs:anchorMs:)``).
public struct CronJob: Sendable, Equatable {
    /// Stable job identifier.
    public let id: String
    /// Run interval in seconds.
    public var intervalSeconds: Int
    /// Whether this job should execute when due.
    public var enabled: Bool
    /// Arbitrary payload passed to scheduler consumers.
    public var payload: String
    /// Next due timestamp.
    public var nextRunAt: Date

    /// Creates a cron job definition.
    /// - Parameters:
    ///   - id: Stable job identifier.
    ///   - intervalSeconds: Run interval in seconds.
    ///   - enabled: Whether job is active.
    ///   - payload: Payload delivered when run.
    ///   - nextRunAt: Next due timestamp.
    public init(
        id: String,
        intervalSeconds: Int,
        enabled: Bool = true,
        payload: String,
        nextRunAt: Date
    ) {
        self.id = id
        self.intervalSeconds = max(1, intervalSeconds)
        self.enabled = enabled
        self.payload = payload
        self.nextRunAt = nextRunAt
    }

    /// The equivalent automation job (an `every` schedule with a `systemEvent` payload).
    public var automationJob: AutomationJob {
        let nextMs = AutomationClock.ms(self.nextRunAt)
        return AutomationJob(
            id: self.id,
            name: self.id,
            enabled: self.enabled,
            schedule: .every(everyMs: Int64(self.intervalSeconds) * 1_000, anchorMs: nextMs),
            payload: .systemEvent(text: self.payload, toolsAllow: nil),
            state: CronJobState(nextRunAtMs: nextMs)
        )
    }
}

/// Execution result emitted for a due cron job.
public struct CronRunResult: Sendable, Equatable {
    /// Executed job identifier.
    public let jobID: String
    /// Payload associated with the job.
    public let payload: String
    /// Timestamp when execution was emitted.
    public let ranAt: Date

    /// Creates a cron run result.
    /// - Parameters:
    ///   - jobID: Executed job identifier.
    ///   - payload: Job payload.
    ///   - ranAt: Emission timestamp.
    public init(jobID: String, payload: String, ranAt: Date) {
        self.jobID = jobID
        self.payload = payload
        self.ranAt = ranAt
    }
}

/// One run handed to an ``AutomationJobExecutor``.
public struct AutomationJobRun: Sendable, Equatable {
    /// Job being run.
    public let job: AutomationJob
    /// Run identifier.
    public let runID: String
    /// Resolved session key (see ``CronScheduler/sessionKey(for:runID:)``).
    public let sessionKey: String
    /// `schedule`, `manual` or `wake`.
    public let trigger: String

    /// Creates a run.
    /// - Parameters:
    ///   - job: Job.
    ///   - runID: Run identifier.
    ///   - sessionKey: Session key.
    ///   - trigger: Trigger.
    public init(job: AutomationJob, runID: String, sessionKey: String, trigger: String) {
        self.job = job
        self.runID = runID
        self.sessionKey = sessionKey
        self.trigger = trigger
    }
}

/// Result reported by an ``AutomationJobExecutor``.
public struct AutomationRunOutcome: Sendable, Equatable {
    /// Status.
    public let status: CronRunStatus
    /// Short summary (for example the agent reply).
    public let summary: String?
    /// Error description.
    public let error: String?

    /// Creates an outcome.
    /// - Parameters:
    ///   - status: Status.
    ///   - summary: Summary.
    ///   - error: Error.
    public init(status: CronRunStatus, summary: String? = nil, error: String? = nil) {
        self.status = status
        self.summary = summary
        self.error = error
    }
}

/// Runs a due job (for example an agent turn on the embedded runtime).
public typealias AutomationJobExecutor = @Sendable (AutomationJobRun) async throws -> AutomationRunOutcome

/// One entry of a job's run log (upstream `CronRunLogEntry` subset).
public struct AutomationRunRecord: Codable, Sendable, Equatable {
    /// Log time in milliseconds.
    public var ts: Int64
    /// Job identifier.
    public var jobId: String
    /// Always `finished`.
    public var action: String
    /// Status.
    public var status: CronRunStatus
    /// Error description.
    public var error: String?
    /// Summary.
    public var summary: String?
    /// Session key.
    public var sessionKey: String?
    /// Run identifier.
    public var runId: String
    /// Run start in milliseconds.
    public var runAtMs: Int64
    /// Duration in milliseconds.
    public var durationMs: Int64
    /// Next scheduled run.
    public var nextRunAtMs: Int64?
    /// Job name.
    public var jobName: String?

    /// Creates a record.
    /// - Parameters:
    ///   - ts: Log time.
    ///   - jobId: Job identifier.
    ///   - status: Status.
    ///   - error: Error.
    ///   - summary: Summary.
    ///   - sessionKey: Session key.
    ///   - runId: Run identifier.
    ///   - runAtMs: Run start.
    ///   - durationMs: Duration.
    ///   - nextRunAtMs: Next run.
    ///   - jobName: Job name.
    public init(
        ts: Int64,
        jobId: String,
        status: CronRunStatus,
        error: String? = nil,
        summary: String? = nil,
        sessionKey: String? = nil,
        runId: String,
        runAtMs: Int64,
        durationMs: Int64,
        nextRunAtMs: Int64? = nil,
        jobName: String? = nil
    ) {
        self.ts = ts
        self.jobId = jobId
        self.action = "finished"
        self.status = status
        self.error = error
        self.summary = summary
        self.sessionKey = sessionKey
        self.runId = runId
        self.runAtMs = runAtMs
        self.durationMs = durationMs
        self.nextRunAtMs = nextRunAtMs
        self.jobName = jobName
    }
}

/// Scheduler status (`cron.status`).
public struct AutomationSchedulerStatus: Codable, Sendable, Equatable {
    /// Whether the timer loop is running.
    public var running: Bool
    /// Number of jobs.
    public var jobs: Int
    /// Enabled jobs.
    public var enabledJobs: Int
    /// Next wake time in milliseconds.
    public var nextWakeAtMs: Int64?
    /// Store path, when persisted.
    public var storePath: String?
}

/// Scheduler for automation jobs (`at`, `every`, `cron` with time zones) plus the legacy interval jobs.
///
/// Automation jobs persist as JSON at `storeURL` and run through the configured
/// ``AutomationJobExecutor`` when due, either from ``start()`` (a timer loop that sleeps until the
/// next due time) or from explicit ``runDueJobs(now:)`` calls. On iOS, tvOS and watchOS an app can
/// only run jobs while active or from a background task: schedule `BGAppRefreshTask` /
/// `BGProcessingTask` for ``nextWakeDate`` and call ``runDueJobs(now:)``; timing is best effort.
public actor CronScheduler {
    private struct Store: Codable {
        var version = 1
        var jobs: [AutomationJob] = []
        var runs: [String: [AutomationRunRecord]] = [:]
    }

    private var jobs: [String: CronJob] = [:]
    private var automationJobs: [String: AutomationJob] = [:]
    private var runLogs: [String: [AutomationRunRecord]] = [:]
    private let storeURL: URL?
    private let now: @Sendable () -> Date
    private let runLogLimit: Int
    private let defaultAgentID: String
    private let defaultTimeZone: TimeZone
    private var executor: AutomationJobExecutor?
    private var changeHandlers: [@Sendable (CronChangedHookEvent) async -> Void] = []
    private var loop: Task<Void, Never>?
    private var running: Set<String> = []

    /// Creates an empty in-memory scheduler.
    public init() {
        self.storeURL = nil
        self.now = { Date() }
        self.runLogLimit = 50
        self.defaultAgentID = "main"
        self.defaultTimeZone = .current
    }

    /// Creates a scheduler for automation jobs.
    /// - Parameters:
    ///   - storeURL: JSON store (for example `<stateDir>/cron/jobs.json`); `nil` keeps jobs in memory.
    ///   - defaultAgentID: Agent used when a job has no `agentId`.
    ///   - defaultTimeZone: Time zone for cron schedules without `tz`.
    ///   - runLogLimit: Run log entries kept per job.
    ///   - now: Clock.
    public init(
        storeURL: URL?,
        defaultAgentID: String = "main",
        defaultTimeZone: TimeZone = .current,
        runLogLimit: Int = 50,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.storeURL = storeURL
        self.defaultAgentID = defaultAgentID
        self.defaultTimeZone = defaultTimeZone
        self.runLogLimit = max(1, runLogLimit)
        self.now = now
    }

    // MARK: - Legacy interval jobs

    /// Adds or replaces a job by identifier.
    /// - Parameter job: Job definition.
    public func addOrUpdate(_ job: CronJob) {
        self.jobs[job.id] = job
    }

    /// Removes a job from the scheduler.
    /// - Parameter id: Job identifier.
    public func remove(id: String) {
        self.jobs.removeValue(forKey: id)
    }

    /// Returns all configured jobs sorted by identifier.
    public func list() -> [CronJob] {
        self.jobs.values.sorted { $0.id < $1.id }
    }

    /// Executes all jobs due at a specific timestamp.
    /// - Parameter now: Reference timestamp (defaults to current time).
    /// - Returns: Results for jobs run during this invocation.
    public func runDue(now: Date = Date()) -> [CronRunResult] {
        var results: [CronRunResult] = []
        for id in self.jobs.keys.sorted() {
            guard var job = self.jobs[id], job.enabled else { continue }
            if job.nextRunAt <= now {
                let result = CronRunResult(jobID: job.id, payload: job.payload, ranAt: now)
                results.append(result)
                job.nextRunAt = now.addingTimeInterval(TimeInterval(job.intervalSeconds))
                self.jobs[id] = job
            }
        }
        return results
    }

    // MARK: - Store

    /// Loads automation jobs and run logs from the store.
    public func load() throws {
        guard let storeURL, FileManager.default.fileExists(atPath: storeURL.path) else { return }
        let store = try JSONDecoder().decode(Store.self, from: Data(contentsOf: storeURL))
        self.automationJobs = Dictionary(store.jobs.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        self.runLogs = store.runs
    }

    /// Saves automation jobs and run logs.
    public func save() throws {
        guard let storeURL else { return }
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let store = Store(jobs: self.automationJobs.values.sorted { $0.id < $1.id }, runs: self.runLogs)
        try encoder.encode(store).write(to: storeURL, options: [.atomic])
    }

    // MARK: - Automation jobs

    /// Sets the executor used for due jobs.
    /// - Parameter executor: Executor.
    public func setExecutor(_ executor: @escaping AutomationJobExecutor) {
        self.executor = executor
    }

    /// Registers a handler for `cron_changed`-style events (added, updated, removed, started, finished).
    /// - Parameter handler: Handler.
    public func onChange(_ handler: @escaping @Sendable (CronChangedHookEvent) async -> Void) {
        self.changeHandlers.append(handler)
    }

    /// Automation jobs sorted by next run (then name).
    /// - Parameter includeDisabled: Include disabled jobs.
    /// - Returns: Jobs.
    public func automationJobList(includeDisabled: Bool = true) -> [AutomationJob] {
        self.automationJobs.values
            .filter { includeDisabled || $0.enabled }
            .sorted { lhs, rhs in
                switch (lhs.state.nextRunAtMs, rhs.state.nextRunAtMs) {
                case let (left?, right?) where left != right: return left < right
                case (nil, _?): return false
                case (_?, nil): return true
                default: return lhs.name == rhs.name ? lhs.id < rhs.id : lhs.name < rhs.name
                }
            }
    }

    /// One automation job.
    /// - Parameter id: Job identifier.
    /// - Returns: The job, if present.
    public func automationJob(id: String) -> AutomationJob? {
        self.automationJobs[id]
    }

    /// Adds a job, computing its next run. Unsupported schedule/payload kinds are rejected.
    /// - Parameter job: Job.
    /// - Returns: The stored job.
    @discardableResult
    public func addJob(_ job: AutomationJob) async throws -> AutomationJob {
        try Self.validate(job)
        var stored = job
        let nowMs = AutomationClock.ms(self.now())
        stored.updatedAtMs = nowMs
        if stored.deleteAfterRun == nil, case .at = stored.schedule { stored.deleteAfterRun = true }
        stored.state.nextRunAtMs = stored.enabled ? stored.nextRunAtMs(after: nowMs - 1, defaultTimeZone: self.defaultTimeZone) : nil
        self.automationJobs[stored.id] = stored
        try self.save()
        await self.notify(action: "added", job: stored)
        self.reschedule()
        return stored
    }

    /// Updates a job in place.
    /// - Parameters:
    ///   - id: Job identifier.
    ///   - mutate: Mutation.
    /// - Returns: The updated job.
    @discardableResult
    public func updateJob(id: String, _ mutate: @Sendable (inout AutomationJob) -> Void) async throws -> AutomationJob {
        guard var job = self.automationJobs[id] else {
            throw OpenClawCoreError.invalidConfiguration("unknown cron job: \(id)")
        }
        mutate(&job)
        job.id = id
        try Self.validate(job)
        let nowMs = AutomationClock.ms(self.now())
        job.updatedAtMs = nowMs
        job.state.nextRunAtMs = job.enabled ? job.nextRunAtMs(after: nowMs - 1, defaultTimeZone: self.defaultTimeZone) : nil
        self.automationJobs[id] = job
        try self.save()
        await self.notify(action: "updated", job: job)
        self.reschedule()
        return job
    }

    /// Removes a job.
    /// - Parameter id: Job identifier.
    /// - Returns: `true` when removed.
    @discardableResult
    public func removeJob(id: String) async throws -> Bool {
        guard let job = self.automationJobs.removeValue(forKey: id) else { return false }
        self.runLogs.removeValue(forKey: id)
        try self.save()
        await self.notify(action: "removed", job: job)
        self.reschedule()
        return true
    }

    /// Run log of a job, newest first.
    /// - Parameters:
    ///   - jobID: Job identifier (`nil` for every job).
    ///   - limit: Maximum entries.
    ///   - offset: Entries to skip.
    /// - Returns: Records.
    public func runs(jobID: String? = nil, limit: Int = 50, offset: Int = 0) -> [AutomationRunRecord] {
        let records = jobID.map { self.runLogs[$0] ?? [] } ?? self.runLogs.values.flatMap { $0 }
        return Array(records.sorted { $0.ts > $1.ts }.dropFirst(max(0, offset)).prefix(max(0, limit)))
    }

    /// Earliest next run among enabled jobs.
    public var nextWakeDate: Date? {
        self.automationJobs.values
            .filter { $0.enabled && $0.isRunnable }
            .compactMap(\.state.nextRunAtMs)
            .min()
            .map { Date(timeIntervalSince1970: Double($0) / 1_000) }
    }

    /// Scheduler status.
    public func status() -> AutomationSchedulerStatus {
        AutomationSchedulerStatus(
            running: self.loop != nil,
            jobs: self.automationJobs.count,
            enabledJobs: self.automationJobs.values.filter(\.enabled).count,
            nextWakeAtMs: self.nextWakeDate.map(AutomationClock.ms),
            storePath: self.storeURL?.path
        )
    }

    /// Session key a run uses: `main` → `agent:<id>:main`, `isolated` → `agent:<id>:cron:<jobId>:<runId>`,
    /// `current` → the job's `sessionKey` (else main), `session:<key>` → `<key>`.
    /// - Parameters:
    ///   - job: Job.
    ///   - runID: Run identifier.
    /// - Returns: Session key.
    public func sessionKey(for job: AutomationJob, runID: String) -> String {
        Self.sessionKey(for: job, runID: runID, defaultAgentID: self.defaultAgentID)
    }

    /// Static form of ``sessionKey(for:runID:)``.
    /// - Parameters:
    ///   - job: Job.
    ///   - runID: Run identifier.
    ///   - defaultAgentID: Agent used when the job has none.
    /// - Returns: Session key.
    public static func sessionKey(for job: AutomationJob, runID: String, defaultAgentID: String = "main") -> String {
        let agent = job.agentId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? job.agentId! : defaultAgentID
        switch job.sessionTarget {
        case .main:
            return "agent:\(agent):main"
        case .isolated:
            return "agent:\(agent):cron:\(job.id):\(runID)"
        case .current:
            return job.sessionKey ?? "agent:\(agent):main"
        case .session(let key):
            return key
        }
    }

    /// Runs one job now.
    /// - Parameters:
    ///   - id: Job identifier.
    ///   - force: Run even when not due (`cron.run mode: force`).
    /// - Returns: The run record, or `nil` when the job was not due.
    @discardableResult
    public func runJob(id: String, force: Bool = true) async throws -> AutomationRunRecord? {
        guard let job = self.automationJobs[id] else {
            throw OpenClawCoreError.invalidConfiguration("unknown cron job: \(id)")
        }
        let nowMs = AutomationClock.ms(self.now())
        if !force {
            guard job.enabled, let next = job.state.nextRunAtMs, next <= nowMs else { return nil }
        }
        return await self.execute(job, trigger: force ? "manual" : "schedule")
    }

    /// Runs every enabled job whose next run is due.
    /// - Parameter now: Reference time (defaults to the scheduler clock).
    /// - Returns: Run records.
    @discardableResult
    public func runDueJobs(now: Date? = nil) async -> [AutomationRunRecord] {
        let nowMs = AutomationClock.ms(now ?? self.now())
        let due = self.automationJobs.values
            .filter { $0.enabled && $0.isRunnable && ($0.state.nextRunAtMs.map { $0 <= nowMs } ?? false) }
            .sorted { ($0.state.nextRunAtMs ?? 0, $0.id) < ($1.state.nextRunAtMs ?? 0, $1.id) }
        var records: [AutomationRunRecord] = []
        for job in due {
            if let record = await self.execute(job, trigger: "schedule") {
                records.append(record)
            }
        }
        return records
    }

    /// Starts the timer loop (sleeps until the next due job, capped at one minute between checks).
    public func start() {
        guard self.loop == nil else { return }
        self.loop = Task.detached { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let delay = await self.secondsUntilNextWake()
                try? await Task.sleep(nanoseconds: UInt64(max(0.05, min(60, delay)) * 1_000_000_000))
                if Task.isCancelled { return }
                await self.runDueJobs()
            }
        }
    }

    /// Stops the timer loop.
    public func stop() {
        self.loop?.cancel()
        self.loop = nil
    }

    // MARK: - Internals

    private func secondsUntilNextWake() -> Double {
        guard let next = self.nextWakeDate else { return 60 }
        return next.timeIntervalSince(self.now())
    }

    private func reschedule() {
        guard self.loop != nil else { return }
        self.loop?.cancel()
        self.loop = nil
        self.start()
    }

    private func execute(_ job: AutomationJob, trigger: String) async -> AutomationRunRecord? {
        guard !self.running.contains(job.id) else { return nil }
        self.running.insert(job.id)
        defer { self.running.remove(job.id) }
        let runID = UUID().uuidString.lowercased()
        let sessionKey = self.sessionKey(for: job, runID: runID)
        let started = self.now()
        let startedMs = AutomationClock.ms(started)
        var current = job
        current.state.runningAtMs = startedMs
        self.automationJobs[job.id] = current
        await self.notify(action: "started", job: current, runID: runID, sessionKey: sessionKey)

        let outcome: AutomationRunOutcome
        if !job.isRunnable {
            outcome = AutomationRunOutcome(status: .skipped, error: "unsupported \(job.schedule.kind)/\(job.payload.kind) job")
        } else if let executor {
            do {
                outcome = try await executor(AutomationJobRun(job: job, runID: runID, sessionKey: sessionKey, trigger: trigger))
            } catch {
                outcome = AutomationRunOutcome(status: .error, error: error.localizedDescription)
            }
        } else {
            outcome = AutomationRunOutcome(status: .skipped, error: "no automation executor is configured")
        }
        let finished = self.now()
        let finishedMs = AutomationClock.ms(finished)
        guard var updated = self.automationJobs[job.id] else { return nil }
        updated.state.runningAtMs = nil
        updated.state.lastRunAtMs = startedMs
        updated.state.lastRunStatus = outcome.status
        updated.state.lastError = outcome.error
        updated.state.lastDurationMs = max(0, finishedMs - startedMs)
        updated.state.consecutiveErrors = outcome.status == .error ? (updated.state.consecutiveErrors ?? 0) + 1 : 0
        updated.state.nextRunAtMs = updated.enabled ? updated.nextRunAtMs(after: finishedMs, defaultTimeZone: self.defaultTimeZone) : nil
        let record = AutomationRunRecord(
            ts: finishedMs,
            jobId: job.id,
            status: outcome.status,
            error: outcome.error,
            summary: outcome.summary,
            sessionKey: sessionKey,
            runId: runID,
            runAtMs: startedMs,
            durationMs: max(0, finishedMs - startedMs),
            nextRunAtMs: updated.state.nextRunAtMs,
            jobName: job.name
        )
        var log = self.runLogs[job.id] ?? []
        log.append(record)
        if log.count > self.runLogLimit { log.removeFirst(log.count - self.runLogLimit) }
        self.runLogs[job.id] = log
        if updated.deleteAfterRun == true, outcome.status == .ok, updated.state.nextRunAtMs == nil {
            self.automationJobs.removeValue(forKey: job.id)
        } else {
            self.automationJobs[job.id] = updated
        }
        try? self.save()
        await self.notify(action: "finished", job: updated, runID: runID, sessionKey: sessionKey, record: record)
        return record
    }

    private func notify(
        action: String,
        job: AutomationJob,
        runID: String? = nil,
        sessionKey: String? = nil,
        record: AutomationRunRecord? = nil
    ) async {
        guard !self.changeHandlers.isEmpty else { return }
        let event = CronChangedHookEvent(
            action: action,
            jobId: job.id,
            job: try? AnyCodable(encoding: job),
            sessionTarget: job.sessionTarget.rawValue,
            agentId: job.agentId,
            runAtMs: record?.runAtMs,
            durationMs: record?.durationMs,
            status: record?.status.rawValue,
            error: record?.error,
            summary: record?.summary,
            sessionKey: sessionKey,
            runId: runID,
            nextRunAtMs: job.state.nextRunAtMs
        )
        for handler in self.changeHandlers {
            await handler(event)
        }
    }

    static func validate(_ job: AutomationJob) throws {
        guard !job.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenClawCoreError.invalidConfiguration("cron job name must be non-empty")
        }
        switch job.schedule {
        case .unsupported(let kind, _):
            throw OpenClawCoreError.invalidConfiguration(
                "schedule kind \"\(kind)\" is not supported by the embedded scheduler; use at, every or cron"
            )
        case .cron(let expr, let tz, _):
            _ = try CronExpression(expr)
            if let tz, TimeZone(identifier: tz) == nil {
                throw OpenClawCoreError.invalidConfiguration("unknown time zone \(tz)")
            }
        case .at(let raw):
            guard AutomationClock.parseAbsoluteTimeMs(raw) != nil else {
                throw OpenClawCoreError.invalidConfiguration("at schedule must be an ISO-8601 time: \(raw)")
            }
        case .every:
            break
        }
        if case .unsupported(let kind, _) = job.payload {
            throw OpenClawCoreError.invalidConfiguration(
                "payload kind \"\(kind)\" is not supported by the embedded scheduler; use systemEvent or agentTurn"
            )
        }
    }
}
