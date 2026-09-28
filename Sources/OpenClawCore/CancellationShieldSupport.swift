import Foundation

/// Runs cleanup work that must finish even when the calling task is cancelled.
///
/// Use it for short cleanup RPCs issued from cancellation paths (for example `chat.abort`
/// from an intent's cancel handler, or a node invoke result sent after a timeout race): a
/// cancelled caller would otherwise throw `CancellationError` before the frame is sent.
///
/// The operation runs in an unstructured task, which does not inherit the caller's cancellation;
/// awaiting its value does not cancel it either. Never shield long-lived receive or keepalive loops.
///
/// Swift 6.4's `withTaskCancellationShield` (OS 27) is intentionally not used yet: with the
/// package's iOS 17 / macOS 14 / tvOS 17 / watchOS 10 deployment floors the compiler emits strong
/// (non-weak) references to `swift_task_cancellationShieldPush`/`Pop` in `libswift_Concurrency`,
/// which would fail to bind at launch on OS versions before 27 even behind `#available`.
/// Switch to the shield once the floors reach 27 or the toolchain weak-links those symbols.
public enum CancellationShieldSupport {
    /// Runs `operation` shielded from the caller's cancellation.
    /// - Parameter operation: Cleanup work to complete.
    /// - Returns: The operation's value.
    public static func run<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T) async throws -> T
    {
        try await Task {
            try await operation()
        }.value
    }
}
