#if canImport(HealthKit) && !os(tvOS)
import Foundation
import HealthKit

/// Opt-in state and authorization for Apple Health summaries.
///
/// Host apps need the HealthKit entitlement and `NSHealthShareUsageDescription`. Show your own
/// disclosure first, then call ``enable(isCurrent:)``; declare `health.summary` and capability `health`
/// only while ``isEnabled`` (see ``declaredCommands`` / ``declaredCapabilities``). The gateway also
/// requires `gateway.nodes.commands.allow: ["health.summary"]`; the command is never default-allowed.
public enum HealthSummaryAuthorization {
    /// `UserDefaults.standard` key recording the user's explicit opt-in.
    public static let enabledKey = "health.summary.enabled"

    /// Whether HealthKit data is available on this device.
    public static var isAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    /// Whether the user opted in and HealthKit is available.
    public static var isEnabled: Bool {
        self.isAvailable && UserDefaults.standard.bool(forKey: self.enabledKey)
    }

    /// Commands to advertise in `connect.commands` (empty unless enabled).
    public static var declaredCommands: [String] {
        self.isEnabled ? [OpenClawHealthCommand.summary.rawValue] : []
    }

    /// Capabilities to advertise in `connect.caps` (empty unless enabled).
    public static var declaredCapabilities: [String] {
        self.isEnabled ? [OpenClawCapability.health.rawValue] : []
    }

    /// Read-only types: workouts, step count, sleep analysis and resting heart rate.
    public static var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = [HKWorkoutType.workoutType()]
        if let steps = HKObjectType.quantityType(forIdentifier: .stepCount) {
            types.insert(steps)
        }
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
            types.insert(sleep)
        }
        if let restingHeartRate = HKObjectType.quantityType(forIdentifier: .restingHeartRate) {
            types.insert(restingHeartRate)
        }
        return types
    }

    /// Requests read authorization and records the opt-in. Call after the app's own disclosure.
    ///
    /// HealthKit never reveals read denial, so the flag records only the user's sharing choice.
    @MainActor
    public static func enable(isCurrent: @MainActor () -> Bool = { true }) async throws {
        guard self.isAvailable else {
            throw OpenClawNodeError(code: .unavailable, message: "HEALTH_UNAVAILABLE: Health data is unavailable on this device")
        }
        let store = HKHealthStore()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            // The async HealthKit overlay leaves the main actor before starting the OS request.
            guard !Task.isCancelled, isCurrent() else {
                continuation.resume(throwing: CancellationError())
                return
            }
            store.requestAuthorization(toShare: [], read: self.readTypes) { [store] success, error in
                defer { withExtendedLifetime(store) {} }
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: NSError(
                        domain: HKErrorDomain,
                        code: HKError.Code.errorAuthorizationNotDetermined.rawValue))
                }
            }
        }
        guard !Task.isCancelled, isCurrent() else { throw CancellationError() }
        UserDefaults.standard.set(true, forKey: self.enabledKey)
    }

    /// Withdraws the opt-in (the system Health permission stays under the user's control in Settings).
    public static func disable() {
        UserDefaults.standard.removeObject(forKey: self.enabledKey)
    }
}

/// HealthKit-backed ``HealthSummaryQuerying``.
public struct HealthKitSummaryQuerying: HealthSummaryQuerying, @unchecked Sendable {
    private let healthStore: HKHealthStore

    /// Creates a querying adapter over a health store.
    public init(healthStore: HKHealthStore = HKHealthStore()) {
        self.healthStore = healthStore
    }

    /// Cumulative step count.
    public func stepCount(in range: DateInterval) async throws -> Int? {
        guard let type = HKObjectType.quantityType(forIdentifier: .stepCount) else { return nil }
        let statistics = try await HKStatisticsQueryDescriptor(
            predicate: Self.quantityPredicate(type: type, range: range),
            options: .cumulativeSum).result(for: self.healthStore)
        return statistics?.sumQuantity().map { Int($0.doubleValue(for: .count()).rounded()) }
    }

    /// Discrete-average resting heart rate.
    public func restingHeartRateBpm(in range: DateInterval) async throws -> Double? {
        guard let type = HKObjectType.quantityType(forIdentifier: .restingHeartRate) else { return nil }
        let statistics = try await HKStatisticsQueryDescriptor(
            predicate: Self.quantityPredicate(type: type, range: range),
            options: .discreteAverage).result(for: self.healthStore)
        let beatsPerMinute = HKUnit.count().unitDivided(by: .minute())
        return statistics?.averageQuantity()?.doubleValue(for: beatsPerMinute)
    }

    /// Asleep-stage sleep-analysis intervals.
    public func asleepIntervals(in range: DateInterval) async throws -> [DateInterval] {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: range.start, end: range.end, options: [])
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: type, predicate: predicate)],
            sortDescriptors: [],
            limit: nil)
        let samples = try await descriptor.result(for: self.healthStore)
        return samples.compactMap { sample -> DateInterval? in
            guard let value = HKCategoryValueSleepAnalysis(rawValue: sample.value),
                  HKCategoryValueSleepAnalysis.allAsleepValues.contains(value),
                  sample.endDate > sample.startDate
            else { return nil }
            return DateInterval(start: sample.startDate, end: sample.endDate)
        }
    }

    /// Workouts that started in the window.
    public func workouts(in range: DateInterval) async throws -> HealthWorkoutAggregate? {
        let predicate = HKQuery.predicateForSamples(withStart: range.start, end: range.end, options: .strictStartDate)
        let descriptor = HKSampleQueryDescriptor(predicates: [.workout(predicate)], sortDescriptors: [], limit: nil)
        let samples = try await descriptor.result(for: self.healthStore)
        guard !samples.isEmpty else { return nil }
        return HealthWorkoutAggregate(count: samples.count, duration: samples.reduce(0) { $0 + $1.duration })
    }

    /// Limited-access start dates from `HKHealthStore.earliestAuthorizedSampleDate(for:)` on OS 27+;
    /// empty on earlier systems.
    public func earliestAuthorizedDates() async throws -> [HealthSummaryMetric: Date] {
        #if compiler(>=6.4)
        if #available(iOS 27.0, watchOS 27.0, macOS 27.0, visionOS 27.0, *) {
            let typesByMetric = Self.typesByMetric()
            let dates = try await self.healthStore.earliestAuthorizedSampleDate(for: Set(typesByMetric.values))
            var result: [HealthSummaryMetric: Date] = [:]
            for (metric, type) in typesByMetric {
                if let date = dates[type] {
                    result[metric] = date
                }
            }
            return result
        }
        #endif
        return [:]
    }

    static func typesByMetric() -> [HealthSummaryMetric: HKObjectType] {
        var types: [HealthSummaryMetric: HKObjectType] = [.workouts: HKObjectType.workoutType()]
        if let steps = HKObjectType.quantityType(forIdentifier: .stepCount) {
            types[.stepCount] = steps
        }
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
            types[.sleep] = sleep
        }
        if let heartRate = HKObjectType.quantityType(forIdentifier: .restingHeartRate) {
            types[.restingHeartRate] = heartRate
        }
        return types
    }

    private static func quantityPredicate(
        type: HKQuantityType,
        range: DateInterval) -> HKSamplePredicate<HKQuantitySample>
    {
        let predicate = HKQuery.predicateForSamples(withStart: range.start, end: range.end, options: [])
        return .quantitySample(type: type, predicate: predicate)
    }
}

extension HealthSummaryService {
    /// A service backed by HealthKit and gated by ``HealthSummaryAuthorization/isEnabled``.
    public static func healthKit(healthStore: HKHealthStore = HKHealthStore()) -> HealthSummaryService {
        HealthSummaryService(
            querying: HealthKitSummaryQuerying(healthStore: healthStore),
            isEnabled: { HealthSummaryAuthorization.isEnabled })
    }
}
#endif
