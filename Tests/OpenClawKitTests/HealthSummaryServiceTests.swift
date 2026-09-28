import Foundation
import Testing
@testable import OpenClawKit

private struct FakeHealthQuerying: HealthSummaryQuerying {
    var steps: Int? = 4321
    var restingHeartRate: Double? = 58.46
    var sleep: [DateInterval] = []
    var workouts: HealthWorkoutAggregate? = HealthWorkoutAggregate(count: 2, duration: 45 * 60 + 20)
    var earliest: [HealthSummaryMetric: Date] = [:]
    let recorder = RangeRecorder()

    func stepCount(in range: DateInterval) async throws -> Int? {
        self.recorder.record(.stepCount, range)
        return self.steps
    }

    func restingHeartRateBpm(in range: DateInterval) async throws -> Double? {
        self.recorder.record(.restingHeartRate, range)
        return self.restingHeartRate
    }

    func asleepIntervals(in range: DateInterval) async throws -> [DateInterval] {
        self.recorder.record(.sleep, range)
        return self.sleep
    }

    func workouts(in range: DateInterval) async throws -> HealthWorkoutAggregate? {
        self.recorder.record(.workouts, range)
        return self.workouts
    }

    func earliestAuthorizedDates() async throws -> [HealthSummaryMetric: Date] {
        self.earliest
    }
}

private final class RangeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var ranges: [HealthSummaryMetric: DateInterval] = [:]

    func record(_ metric: HealthSummaryMetric, _ range: DateInterval) {
        self.lock.withLock { self.ranges[metric] = range }
    }

    func range(_ metric: HealthSummaryMetric) -> DateInterval? {
        self.lock.withLock { self.ranges[metric] }
    }
}

struct HealthSummaryServiceTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Oslo")!
        return calendar
    }

    private var now: Date {
        // 2026-09-28 14:30 in Oslo (UTC+2).
        Date(timeIntervalSince1970: 1_790_598_600)
    }

    @Test func `disabled summaries fail without querying`() async {
        let fake = FakeHealthQuerying()
        let service = HealthSummaryService(querying: fake, isEnabled: { false })
        await #expect(throws: HealthSummaryService.disabledError) {
            _ = try await service.summary(params: OpenClawHealthSummaryParams(period: .today))
        }
        #expect(fake.recorder.range(.stepCount) == nil)
    }

    @Test func `summary aggregates today only with merged sleep`() async throws {
        let startOfDay = self.calendar.startOfDay(for: self.now)
        var fake = FakeHealthQuerying()
        fake.sleep = [
            DateInterval(start: startOfDay.addingTimeInterval(-3600), end: startOfDay.addingTimeInterval(3600)),
            DateInterval(start: startOfDay.addingTimeInterval(1800), end: startOfDay.addingTimeInterval(7200)),
            DateInterval(start: startOfDay.addingTimeInterval(10_800), end: startOfDay.addingTimeInterval(11_400)),
        ]
        let service = HealthSummaryService(
            querying: fake,
            isEnabled: { true },
            calendar: self.calendar,
            now: { self.now })
        let payload = try await service.summary(params: OpenClawHealthSummaryParams(period: .today))

        #expect(payload.period == .today)
        #expect(payload.timeZoneIdentifier == "Europe/Oslo")
        #expect(payload.startISO == "2026-09-28T00:00:00+02:00")
        #expect(payload.stepCount == 4321)
        // [00:00, 02:00] merged plus [03:00, 03:10], clipped to today: 130 minutes.
        #expect(payload.sleepDurationMinutes == 130)
        #expect(payload.restingHeartRateBpm == 58.5)
        #expect(payload.workoutCount == 2)
        #expect(payload.workoutDurationMinutes == 45)
        #expect(fake.recorder.range(.stepCount)?.start == startOfDay)
    }

    @Test func `limited access clamps windows and hides unreadable metrics`() async throws {
        let startOfDay = self.calendar.startOfDay(for: self.now)
        var fake = FakeHealthQuerying()
        fake.earliest = [
            .stepCount: startOfDay.addingTimeInterval(8 * 3600),
            .restingHeartRate: self.now.addingTimeInterval(3600),
        ]
        let service = HealthSummaryService(
            querying: fake,
            isEnabled: { true },
            calendar: self.calendar,
            now: { self.now })
        let payload = try await service.summary(params: OpenClawHealthSummaryParams(period: .today))

        #expect(fake.recorder.range(.stepCount)?.start == startOfDay.addingTimeInterval(8 * 3600))
        #expect(payload.stepCount == 4321)
        // Authorized only from the future: unreadable, so nil instead of zero, and never queried.
        #expect(payload.restingHeartRateBpm == nil)
        #expect(fake.recorder.range(.restingHeartRate) == nil)
        #expect(fake.recorder.range(.sleep)?.start == startOfDay)
    }

    @Test func `range helpers merge and clamp intervals`() {
        let range = DateInterval(start: Date(timeIntervalSince1970: 0), duration: 100)
        #expect(HealthSummaryService.mergedDuration(intervals: [], clippedTo: range) == nil)
        #expect(HealthSummaryService.mergedDuration(
            intervals: [
                DateInterval(start: Date(timeIntervalSince1970: 10), duration: 20),
                DateInterval(start: Date(timeIntervalSince1970: 20), duration: 20),
                DateInterval(start: Date(timeIntervalSince1970: 90), duration: 50),
            ],
            clippedTo: range) == 40)
        #expect(HealthSummaryService.clampedRange(range, earliestAuthorized: nil) == range)
        #expect(HealthSummaryService.clampedRange(range, earliestAuthorized: Date(timeIntervalSince1970: -5)) == range)
        #expect(HealthSummaryService.clampedRange(range, earliestAuthorized: Date(timeIntervalSince1970: 40))?.duration == 60)
        #expect(HealthSummaryService.clampedRange(range, earliestAuthorized: Date(timeIntervalSince1970: 100)) == nil)
    }

    @Test func `payload encodes the upstream wire keys`() throws {
        let payload = OpenClawHealthSummaryPayload(
            period: .today,
            startISO: "s",
            endISO: "e",
            timeZoneIdentifier: "UTC",
            stepCount: 1,
            sleepDurationMinutes: nil,
            restingHeartRateBpm: nil,
            workoutCount: nil,
            workoutDurationMinutes: nil)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
        #expect(Set(object.keys) == ["period", "startISO", "endISO", "timeZoneIdentifier", "stepCount"])
    }
}
