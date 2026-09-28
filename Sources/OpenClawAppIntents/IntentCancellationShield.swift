import Foundation

/// Runs cleanup work (for example `chat.abort`) so it still completes when the caller was cancelled.
///
/// The work runs in an unstructured task, which does not inherit the caller's cancellation.
///
/// `withTaskCancellationShield` (Swift 6.4, OS 27) is deliberately not used: its inlined body
/// strongly references `swift_task_cancellationShieldPush`/`Pop` in `libswift_Concurrency`, which
/// iOS 26.4 and earlier do not export, so an app at the package's iOS 17 floor would fail to launch
/// on those systems even though the call sits behind `#available`.
enum IntentCancellationShield {
    static func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await Task {
            try await operation()
        }.value
    }
}
