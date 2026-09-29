import Foundation
import OpenClawCore

/// Overflow-safe time arithmetic for durations that callers, gateway clients or the model control.
///
/// Timeouts arrive unclamped from gateway params, hook approval requests and tool arguments; plain
/// `UInt64(ms) * 1_000_000` or `now + timeout` traps on absurd values, and `Int(Int64)` traps on
/// watchOS `arm64_32`, where `Int` is 32-bit. Every conversion here saturates instead.
enum RuntimeTime {
    /// Longest delay the runtime schedules (about 146 years). Larger requests saturate here: the
    /// dispatch timer takes a signed 64-bit delta, so `UInt64.max` would wrap negative and fire at once.
    static let maxSleepNanoseconds: UInt64 = 1 << 62

    /// Nanoseconds for a millisecond delay (`0` for non-positive values), saturating at
    /// ``maxSleepNanoseconds``.
    /// - Parameter milliseconds: Delay in milliseconds.
    /// - Returns: Delay in nanoseconds.
    static func sleepNanoseconds(milliseconds: Int64) -> UInt64 {
        guard milliseconds > 0 else { return 0 }
        let (nanoseconds, overflow) = UInt64(milliseconds).multipliedReportingOverflow(by: 1_000_000)
        return overflow ? Self.maxSleepNanoseconds : min(nanoseconds, Self.maxSleepNanoseconds)
    }

    /// Nanoseconds for a millisecond delay, saturating like the `Int64` overload.
    /// - Parameter milliseconds: Delay in milliseconds.
    /// - Returns: Delay in nanoseconds.
    static func sleepNanoseconds(milliseconds: Int) -> UInt64 {
        Self.sleepNanoseconds(milliseconds: Int64(milliseconds))
    }

    /// `now + milliseconds`, saturating at `Int64.max` / `Int64.min`.
    /// - Parameters:
    ///   - now: Start time (ms).
    ///   - milliseconds: Offset (ms).
    /// - Returns: The deadline (ms).
    static func deadline(_ now: Int64, plusMilliseconds milliseconds: Int64) -> Int64 {
        let (sum, overflow) = now.addingReportingOverflow(milliseconds)
        guard overflow else { return sum }
        return milliseconds > 0 ? .max : .min
    }

    /// Non-negative elapsed milliseconds since `startedAt`, clamped into `Int` (32-bit on watchOS).
    /// - Parameters:
    ///   - startedAt: Start time (ms).
    ///   - now: Current time (ms).
    /// - Returns: Elapsed milliseconds.
    static func elapsedMilliseconds(since startedAt: Int64, now: Int64 = SessionTranscriptClock.nowMs()) -> Int {
        let (difference, overflow) = now.subtractingReportingOverflow(startedAt)
        if overflow {
            return startedAt < 0 ? Int.max : 0
        }
        return Int(clamping: max(0, difference))
    }

    /// Non-negative elapsed milliseconds since a `Date`, clamped into `Int`.
    /// - Parameter date: Start date.
    /// - Returns: Elapsed milliseconds.
    static func elapsedMilliseconds(since date: Date) -> Int {
        let milliseconds = Date().timeIntervalSince(date) * 1_000
        guard milliseconds.isFinite, milliseconds > 0 else { return 0 }
        return milliseconds >= Double(Int.max) ? Int.max : Int(milliseconds)
    }

    /// A finite, integral `Int` for a model- or caller-supplied number, clamped into `range`.
    /// - Parameters:
    ///   - value: Raw number (`nil`, NaN and infinities yield `nil`).
    ///   - range: Accepted range.
    /// - Returns: The clamped value, or `nil`.
    static func clampedInt(_ value: Double?, to range: ClosedRange<Int>) -> Int? {
        guard let value, value.isFinite else { return nil }
        let truncated = value.rounded(.towardZero)
        if truncated <= Double(range.lowerBound) {
            return range.lowerBound
        }
        if truncated >= Double(range.upperBound) {
            return range.upperBound
        }
        return Int(truncated)
    }
}
