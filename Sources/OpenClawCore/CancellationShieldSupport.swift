import Foundation

/// Runs cleanup work that must finish even when the calling task is cancelled.
///
/// Use it for short cleanup RPCs issued from cancellation paths (for example `chat.abort`
/// from an intent's cancel handler, or a node invoke result sent after a timeout race): a
/// cancelled caller would otherwise throw `CancellationError` before the frame is sent.
///
/// On Swift 6.4 toolchains running iOS/macOS/tvOS/watchOS/visionOS 27 the operation runs inside
/// `withTaskCancellationShield`, so `Task.isCancelled` stays `false` for its duration. Everywhere
/// else (older OS versions, older compilers, Linux) it runs in an unstructured task, which does
/// not inherit the caller's cancellation. Never shield long-lived receive or keepalive loops.
public enum CancellationShieldSupport {
    /// Test hook that forces the pre-27 fallback path.
    @TaskLocal static var forcesFallback = false

    /// Runs `operation` shielded from the caller's cancellation.
    /// - Parameter operation: Cleanup work to complete.
    /// - Returns: The operation's value.
    public static func run<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T) async throws -> T
    {
        #if compiler(>=6.4) && canImport(Darwin)
        if !self.forcesFallback {
            if #available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *) {
                return try await withTaskCancellationShield {
                    try await operation()
                }
            }
        }
        #endif
        // An unstructured task does not inherit cancellation, and awaiting its value does not
        // cancel it, so the cleanup completes even when the caller was cancelled.
        return try await Task {
            try await operation()
        }.value
    }
}
