import Foundation

/// Helpers for resuming throwing continuations with optional errors.
public enum ThrowingContinuationSupport {
    /// Resumes a `Void` continuation by either returning or throwing.
    public static func resumeVoid(_ continuation: CheckedContinuation<Void, Error>, error: Error?) {
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume(returning: ())
        }
    }
}
