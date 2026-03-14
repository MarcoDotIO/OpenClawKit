import Foundation

/// Clamp helpers for capture duration and frame-rate values.
public enum CaptureRateLimits {
    /// Clamps a capture duration into the allowed range.
    public static func clampDurationMs(
        _ ms: Int?,
        defaultMs: Int = 10_000,
        minMs: Int = 250,
        maxMs: Int = 60_000) -> Int
    {
        let value = ms ?? defaultMs
        return min(maxMs, max(minMs, value))
    }

    /// Clamps an FPS value into the allowed range.
    public static func clampFps(
        _ fps: Double?,
        defaultFps: Double = 10,
        minFps: Double = 1,
        maxFps: Double) -> Double
    {
        let value = fps ?? defaultFps
        guard value.isFinite else { return defaultFps }
        return min(maxFps, max(minFps, value))
    }
}
