import Foundation
import OpenClawKit

// Ported from upstream OpenClaw 2026.9.6 `ChatSessionManagementViews.swift` (batch mutation model only).

/// Multi-select session action.
enum ChatSessionBatchAction: Sendable, Equatable {
    case pin
    case unpin
    case archive
    case delete
}

/// Outcome of a batch session mutation.
struct ChatSessionBatchResult: Sendable, Equatable {
    let succeededKeys: [String]
    let errorsByKey: [String: String]
}

/// Client-side batch validation failures.
enum ChatSessionBatchValidationError: LocalizedError {
    case cannotArchive
    case cannotDelete
    case attachmentOwnerPinned

    var errorDescription: String? {
        switch self {
        case .cannotArchive:
            String(localized: "This thread cannot be archived while it is active or running.")
        case .cannotDelete:
            String(localized: "The main thread cannot be deleted.")
        case .attachmentOwnerPinned:
            String(localized: "Remove attachments or wait for delivery before archiving or deleting this thread.")
        }
    }
}

/// Runs one operation per key with bounded concurrency, reporting results in key order.
enum ChatSessionBatchMutationRunner {
    static func run(
        keys: [String],
        maxConcurrent: Int = 4,
        operation: @escaping @Sendable (String) async throws -> Void) async -> ChatSessionBatchResult
    {
        guard !keys.isEmpty else {
            return ChatSessionBatchResult(succeededKeys: [], errorsByKey: [:])
        }
        let limit = max(1, min(maxConcurrent, keys.count))
        var succeeded: [(Int, String)] = []
        var failures: [String: String] = [:]
        await withTaskGroup(of: (Int, String, String?).self) { group in
            var nextIndex = 0
            while nextIndex < limit {
                let index = nextIndex
                let key = keys[index]
                group.addTask {
                    do {
                        try await operation(key)
                        return (index, key, nil)
                    } catch {
                        return (index, key, error.localizedDescription)
                    }
                }
                nextIndex += 1
            }
            while let (index, key, error) = await group.next() {
                if let error {
                    failures[key] = error
                } else {
                    succeeded.append((index, key))
                }
                if nextIndex < keys.count {
                    let pendingIndex = nextIndex
                    let pendingKey = keys[pendingIndex]
                    group.addTask {
                        do {
                            try await operation(pendingKey)
                            return (pendingIndex, pendingKey, nil)
                        } catch {
                            return (pendingIndex, pendingKey, error.localizedDescription)
                        }
                    }
                    nextIndex += 1
                }
            }
        }
        return ChatSessionBatchResult(
            succeededKeys: succeeded.sorted { $0.0 < $1.0 }.map(\.1),
            errorsByKey: failures)
    }
}
