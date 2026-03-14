import Foundation

/// Definition for a periodic scheduled job.
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

/// Actor that tracks scheduled jobs and emits due run results.
public actor CronScheduler {
    private var jobs: [String: CronJob] = [:]

    /// Creates an empty scheduler.
    public init() {}

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
}
