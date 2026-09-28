import Foundation

/// Metrics aggregated by `health.summary`.
public enum HealthSummaryMetric: String, Sendable, CaseIterable {
    /// Step count (cumulative sum).
    case stepCount
    /// Asleep time (merged sleep-analysis intervals).
    case sleep
    /// Resting heart rate (discrete average).
    case restingHeartRate
    /// Workouts (count and total duration).
    case workouts
}

/// Workout aggregate for one window.
public struct HealthWorkoutAggregate: Sendable, Equatable {
    /// Number of workouts that started in the window.
    public var count: Int
    /// Total workout duration in seconds.
    public var duration: TimeInterval

    /// Creates a workout aggregate.
    public init(count: Int, duration: TimeInterval) {
        self.count = count
        self.duration = duration
    }
}

/// Aggregate-only health queries behind `health.summary` (the HealthKit adapter is
/// ``HealthKitSummaryQuerying``; tests inject fakes).
public protocol HealthSummaryQuerying: Sendable {
    /// Total steps in the window, or `nil` without data.
    func stepCount(in range: DateInterval) async throws -> Int?
    /// Average resting heart rate in beats per minute, or `nil` without data.
    func restingHeartRateBpm(in range: DateInterval) async throws -> Double?
    /// Asleep intervals overlapping the window (may overlap each other).
    func asleepIntervals(in range: DateInterval) async throws -> [DateInterval]
    /// Workouts that started in the window, or `nil` without any.
    func workouts(in range: DateInterval) async throws -> HealthWorkoutAggregate?
    /// Earliest readable date per metric when the user granted only limited (time-bounded) access.
    /// Metrics without a limit are omitted. Implementations without the API return `[:]`.
    func earliestAuthorizedDates() async throws -> [HealthSummaryMetric: Date]
}

/// Builds privacy-bounded `health.summary` payloads: today-only aggregates, never raw samples,
/// sources or metadata.
public actor HealthSummaryService {
    /// Error when the user has not opted in to health summaries on this device.
    public static let disabledError = OpenClawNodeError(
        code: .unavailable,
        message: "HEALTH_ACCESS_DISABLED: enable Apple Health Summaries in the app settings")

    private let querying: any HealthSummaryQuerying
    private let isEnabled: @Sendable () -> Bool
    private let now: @Sendable () -> Date
    private let calendar: Calendar

    /// Creates a service.
    ///
    /// - Parameters:
    ///   - querying: Health data source.
    ///   - isEnabled: Whether the user opted in (for example ``HealthSummaryAuthorization/isEnabled``).
    ///   - calendar: Calendar that defines "today" (current time zone by default).
    ///   - now: Clock.
    public init(
        querying: any HealthSummaryQuerying,
        isEnabled: @escaping @Sendable () -> Bool,
        calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = { Date() })
    {
        self.querying = querying
        self.isEnabled = isEnabled
        self.calendar = calendar
        self.now = now
    }

    /// Returns the summary for `params.period`, or throws ``disabledError`` when not opted in.
    ///
    /// When the user granted limited access that starts after the window began, the metric's window is
    /// clamped to the authorized start, and a metric whose authorized start is after "now" is reported
    /// as `nil` (unreadable) instead of zero.
    public func summary(params: OpenClawHealthSummaryParams) async throws -> OpenClawHealthSummaryPayload {
        guard self.isEnabled() else { throw Self.disabledError }

        let range = Self.dateRange(now: self.now(), calendar: self.calendar)
        let earliest = try await self.querying.earliestAuthorizedDates()
        func window(_ metric: HealthSummaryMetric) -> DateInterval? {
            Self.clampedRange(range, earliestAuthorized: earliest[metric])
        }

        var stepCount: Int?
        if let stepRange = window(.stepCount) {
            stepCount = try await self.querying.stepCount(in: stepRange)
        }
        var sleepDuration: TimeInterval?
        if let sleepRange = window(.sleep) {
            let intervals = try await self.querying.asleepIntervals(in: sleepRange)
            sleepDuration = Self.mergedDuration(intervals: intervals, clippedTo: sleepRange)
        }
        var restingHeartRate: Double?
        if let heartRange = window(.restingHeartRate) {
            restingHeartRate = try await self.querying.restingHeartRateBpm(in: heartRange)
        }
        var workouts: HealthWorkoutAggregate?
        if let workoutRange = window(.workouts) {
            workouts = try await self.querying.workouts(in: workoutRange)
        }
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = self.calendar.timeZone

        return OpenClawHealthSummaryPayload(
            period: params.period,
            startISO: formatter.string(from: range.start),
            endISO: formatter.string(from: range.end),
            timeZoneIdentifier: self.calendar.timeZone.identifier,
            stepCount: stepCount,
            sleepDurationMinutes: sleepDuration.map(Self.roundedMinutes),
            restingHeartRateBpm: restingHeartRate.map { ($0 * 10).rounded() / 10 },
            workoutCount: workouts?.count,
            workoutDurationMinutes: workouts.map { Self.roundedMinutes($0.duration) })
    }

    /// Start of the current calendar day through `now`.
    public static func dateRange(now: Date, calendar: Calendar) -> DateInterval {
        let startOfToday = calendar.startOfDay(for: now)
        return DateInterval(start: startOfToday, end: now)
    }

    /// Total length of the union of `intervals` clipped to `range`, so overlapping sleep stages and
    /// sources never count a minute twice; `nil` when nothing overlaps.
    public static func mergedDuration(intervals: [DateInterval], clippedTo range: DateInterval) -> TimeInterval? {
        let clipped = intervals.compactMap { interval -> DateInterval? in
            let start = max(interval.start, range.start)
            let end = min(interval.end, range.end)
            return end > start ? DateInterval(start: start, end: end) : nil
        }.sorted { $0.start < $1.start }
        guard var current = clipped.first else { return nil }

        var duration: TimeInterval = 0
        for interval in clipped.dropFirst() {
            if interval.start <= current.end {
                current = DateInterval(start: current.start, end: max(current.end, interval.end))
            } else {
                duration += current.duration
                current = interval
            }
        }
        return duration + current.duration
    }

    /// `range` clamped to start no earlier than `earliestAuthorized`; `nil` when nothing in the range
    /// is readable.
    public static func clampedRange(_ range: DateInterval, earliestAuthorized: Date?) -> DateInterval? {
        guard let earliestAuthorized, earliestAuthorized > range.start else { return range }
        guard earliestAuthorized < range.end else { return nil }
        return DateInterval(start: earliestAuthorized, end: range.end)
    }

    private static func roundedMinutes(_ seconds: TimeInterval) -> Int {
        Int((seconds / 60).rounded())
    }
}
