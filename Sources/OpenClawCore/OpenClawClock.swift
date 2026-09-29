import Foundation

/// Shared millisecond clock for SDK-owned timestamps.
///
/// SDK-owned epoch-millisecond timestamps are `Int64`: on watchOS `arm64_32`, `Int` is 32 bits and
/// `Int(Date().timeIntervalSince1970 * 1000)` traps (current epoch milliseconds exceed `Int32.max`).
/// Use these helpers instead of converting through `Int`.
public enum OpenClawClock {
    /// Current time in milliseconds since the Unix epoch.
    /// - Returns: Epoch milliseconds, rounded to the nearest millisecond.
    public static func nowMs() -> Int64 {
        self.ms(Date())
    }

    /// Milliseconds since the Unix epoch for a date.
    /// - Parameter date: Date to convert.
    /// - Returns: Epoch milliseconds, rounded to the nearest millisecond (clamped to the `Int64` range).
    public static func ms(_ date: Date) -> Int64 {
        let milliseconds = (date.timeIntervalSince1970 * 1_000).rounded()
        guard milliseconds.isFinite else {
            return milliseconds < 0 ? Int64.min : Int64.max
        }
        if milliseconds >= Double(Int64.max) {
            return Int64.max
        }
        if milliseconds <= Double(Int64.min) {
            return Int64.min
        }
        return Int64(milliseconds)
    }

    /// Date for epoch milliseconds.
    /// - Parameter milliseconds: Epoch milliseconds.
    /// - Returns: The date.
    public static func date(fromMs milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    }
}
