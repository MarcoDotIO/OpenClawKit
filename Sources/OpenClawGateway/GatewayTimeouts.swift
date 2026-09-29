import Foundation
import OpenClawProtocol

/// Bounds for client-supplied gateway timeouts.
///
/// Upstream clamps timer delays to `MAX_TIMER_TIMEOUT_MS` (the largest JavaScript timer delay);
/// the in-process server applies the same bound at the request boundary, so huge `timeoutMs`
/// values mean "wait as long as possible" instead of overflowing millisecond-to-nanosecond or
/// deadline arithmetic. The bound also fits a 32-bit `Int` (watchOS `arm64_32`).
public enum GatewayTimeouts {
    /// Largest accepted timeout in milliseconds (upstream `MAX_TIMER_TIMEOUT_MS`, about 24.8 days).
    public static let maxTimeoutMs: Int64 = 2_147_000_000

    /// Clamps a timeout to `0...maxTimeoutMs`.
    /// - Parameter milliseconds: Timeout in milliseconds.
    /// - Returns: The clamped timeout, or `nil` when `milliseconds` is `nil`.
    public static func clamped(_ milliseconds: Int64?) -> Int64? {
        milliseconds.map { min(max($0, 0), Self.maxTimeoutMs) }
    }

    /// Clamps a timeout to `0...maxTimeoutMs`.
    /// - Parameter milliseconds: Timeout in milliseconds.
    /// - Returns: The clamped timeout, or `nil` when `milliseconds` is `nil`.
    public static func clamped(_ milliseconds: Int?) -> Int? {
        milliseconds.map { Int(Self.clamped(Int64($0)) ?? 0) }
    }

    /// Reads a millisecond timeout param and clamps it to `0...maxTimeoutMs`.
    ///
    /// Integers and finite numbers are accepted (fractions round down); values beyond `Int64` or
    /// the bound clamp to ``maxTimeoutMs`` instead of being dropped. Other types answer `nil`.
    /// - Parameter value: Raw param value.
    /// - Returns: The clamped timeout, or `nil` when absent or not a number.
    public static func clampedMilliseconds(_ value: AnyCodable?) -> Int64? {
        guard let value else { return nil }
        if let int64 = value.int64Value {
            return Self.clamped(int64)
        }
        guard let double = value.doubleValue, double.isFinite else { return nil }
        if double <= 0 {
            return 0
        }
        if double >= Double(Self.maxTimeoutMs) {
            return Self.maxTimeoutMs
        }
        return Int64(double.rounded(.down))
    }

    /// ``clampedMilliseconds(_:)`` as an `Int` (always representable, even on 32-bit platforms).
    /// - Parameter value: Raw param value.
    /// - Returns: The clamped timeout, or `nil` when absent or not a number.
    public static func clampedIntMilliseconds(_ value: AnyCodable?) -> Int? {
        Self.clampedMilliseconds(value).map { Int($0) }
    }

    /// Converts milliseconds to nanoseconds, saturating instead of trapping.
    /// - Parameter milliseconds: Duration in milliseconds (negative values count as `0`).
    /// - Returns: Nanoseconds, capped at `UInt64.max`.
    public static func nanoseconds(milliseconds: Int64) -> UInt64 {
        let (value, overflow) = UInt64(clamping: milliseconds).multipliedReportingOverflow(by: 1_000_000)
        return overflow ? .max : value
    }

    /// Converts milliseconds to nanoseconds, saturating instead of trapping.
    /// - Parameter milliseconds: Duration in milliseconds (negative values count as `0`).
    /// - Returns: Nanoseconds, capped at `UInt64.max`.
    public static func nanoseconds(milliseconds: Int) -> UInt64 {
        Self.nanoseconds(milliseconds: Int64(milliseconds))
    }
}
