import Foundation

/// Health node commands.
///
/// `health.summary` is on the gateway's dangerous-command list: it is never default-allowed and
/// needs `gateway.nodes.commands.allow: ["health.summary"]` in addition to the node declaring it.
public enum OpenClawHealthCommand: String, Codable, Sendable {
    /// `health.summary`: privacy-bounded aggregate health metrics.
    case summary = "health.summary"
}

/// Time window a health summary covers.
public enum OpenClawHealthSummaryPeriod: String, Codable, Sendable, CaseIterable {
    /// The current calendar day in the node's time zone.
    case today
}

/// Params for `health.summary`.
public struct OpenClawHealthSummaryParams: Codable, Sendable, Equatable {
    /// Requested period.
    public var period: OpenClawHealthSummaryPeriod

    /// Creates health summary params.
    public init(period: OpenClawHealthSummaryPeriod) {
        self.period = period
    }
}

/// Aggregate-only health summary payload. Never carries raw samples, sources or metadata; a `nil`
/// metric means "unavailable or not authorized", not zero.
public struct OpenClawHealthSummaryPayload: Codable, Sendable, Equatable {
    /// Period the summary covers.
    public var period: OpenClawHealthSummaryPeriod
    /// ISO 8601 start of the window.
    public var startISO: String
    /// ISO 8601 end of the window.
    public var endISO: String
    /// Time zone used to compute the window.
    public var timeZoneIdentifier: String
    /// Total step count.
    public var stepCount: Int?
    /// Asleep duration in minutes (overlapping samples merged).
    public var sleepDurationMinutes: Int?
    /// Average resting heart rate in beats per minute, rounded to 0.1.
    public var restingHeartRateBpm: Double?
    /// Number of workouts.
    public var workoutCount: Int?
    /// Total workout duration in minutes.
    public var workoutDurationMinutes: Int?

    /// Creates a health summary payload.
    public init(
        period: OpenClawHealthSummaryPeriod,
        startISO: String,
        endISO: String,
        timeZoneIdentifier: String,
        stepCount: Int?,
        sleepDurationMinutes: Int?,
        restingHeartRateBpm: Double?,
        workoutCount: Int?,
        workoutDurationMinutes: Int?)
    {
        self.period = period
        self.startISO = startISO
        self.endISO = endISO
        self.timeZoneIdentifier = timeZoneIdentifier
        self.stepCount = stepCount
        self.sleepDurationMinutes = sleepDurationMinutes
        self.restingHeartRateBpm = restingHeartRateBpm
        self.workoutCount = workoutCount
        self.workoutDurationMinutes = workoutDurationMinutes
    }
}
