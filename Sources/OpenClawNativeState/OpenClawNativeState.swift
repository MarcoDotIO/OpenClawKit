import Foundation

/// Namespace for the OpenClaw native state store.
///
/// `OpenClawNativeState` owns the shared SQLite state database (`state/openclaw.sqlite`) that
/// Apple clients use for device identity, device auth tokens, exec approvals, and other durable
/// runtime state. It is built on the system SQLite3 library and CryptoKit and has no third-party
/// dependencies. The module is Apple-only.
///
/// The schema is the upstream OpenClaw state schema (version ``OpenClawNativeStateSQLite/supportedSchemaVersion``):
/// native code bootstraps canonical tables into a fresh version-zero database, and shares a
/// Node-owned (versioned) database with the OpenClaw gateway/CLI without ever migrating it.
public enum OpenClawNativeState {
    /// Release of OpenClawKit that introduced this module surface.
    public static let moduleVersion = "2026.3.0"
}

/// Dedicated serial queue for blocking native-state work.
///
/// Every ``OpenClawNativeStateSQLite`` call is synchronous and may wait on SQLite busy timeouts or
/// coordinator locks (up to 30 s for first-time identity creation). Running that work directly on
/// a Swift concurrency cooperative thread (for example inside an actor method) can starve the
/// pool. ``run(_:)`` executes the work on one process-wide serial dispatch queue and resumes the
/// caller when it finishes; serial execution also removes in-process lock contention between
/// native stores.
///
/// Task-local values are not visible on the queue. Capture anything task-scoped before calling.
public enum OpenClawNativeStateQueue {
    private static let queue = DispatchQueue(label: "ai.openclaw.native-state.io")

    /// Runs blocking `work` on the native-state queue and returns its result.
    ///
    /// - Parameter work: Synchronous work, typically a native-state store call.
    /// - Returns: The value produced by `work`.
    /// - Throws: Any error thrown by `work`.
    public static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
            self.queue.async {
                continuation.resume(with: Result { try work() })
            }
        }
    }
}
