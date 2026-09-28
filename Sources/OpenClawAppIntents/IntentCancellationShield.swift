import Foundation

/// Runs cleanup work (for example `chat.abort`) so it still completes when the caller was cancelled.
///
/// Uses `withTaskCancellationShield` on OS 27 (Swift 6.4) and an unstructured task, which does not
/// inherit cancellation, elsewhere. Local to this module until a shared helper lands in OpenClawCore.
enum IntentCancellationShield {
    static func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        #if compiler(>=6.4)
        if #available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *) {
            return try await withTaskCancellationShield {
                try await operation()
            }
        }
        #endif
        return try await Task {
            try await operation()
        }.value
    }
}
