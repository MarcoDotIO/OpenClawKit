import Foundation
import OpenClawProtocol

/// Epoch milliseconds as `Int64` (never `Int`: millisecond timestamps overflow 32-bit `Int` on watchOS).
func gatewayNowMs() -> Int64 {
    Int64((Date().timeIntervalSince1970 * 1000).rounded(.down))
}

/// Time-bounded response cache for gateway requests that carry an idempotency key
/// (`agent`, `tools.invoke`, `sessions.send`, …).
///
/// A retry with the same key within ``ttlMs`` returns the first response instead of repeating the
/// side effect; concurrent requests with the same key share one in-flight operation. Failed
/// operations are not cached, so a retry after an error runs again. Entries are scoped by the
/// caller-chosen key (prefix it with the method name).
public actor GatewayIdempotencyCache {
    private struct Entry {
        let task: Task<AnyCodable?, Error>
        let createdAtMs: Int64
    }

    /// Default retention used by the in-process server (10 minutes, an SDK choice).
    public static let defaultTTLMs: Int64 = 10 * 60 * 1000

    /// Retention of a cached response in milliseconds.
    public let ttlMs: Int64
    /// Maximum number of cached keys; the oldest entries are evicted first.
    public let capacity: Int

    private let clock: @Sendable () -> Int64
    private var entries: [String: Entry] = [:]
    private var order: [String] = []

    /// Creates a cache.
    /// - Parameters:
    ///   - ttlMs: Retention in milliseconds.
    ///   - capacity: Maximum number of cached keys.
    ///   - clock: Epoch-millisecond clock (injectable for tests).
    public init(
        ttlMs: Int64 = GatewayIdempotencyCache.defaultTTLMs,
        capacity: Int = 1024,
        clock: @escaping @Sendable () -> Int64 = { Int64((Date().timeIntervalSince1970 * 1000).rounded(.down)) }
    ) {
        self.ttlMs = max(1, ttlMs)
        self.capacity = max(1, capacity)
        self.clock = clock
    }

    /// Runs `operation` once per key within the retention window.
    ///
    /// Without a key (`nil` or blank) the operation always runs.
    /// - Parameters:
    ///   - key: Idempotency key.
    ///   - operation: Side-effecting operation producing the response payload.
    /// - Returns: The (possibly cached) response payload.
    /// - Throws: The operation's error; failures are not cached.
    public func run(
        key: String?,
        _ operation: @escaping @Sendable () async throws -> AnyCodable?
    ) async throws -> AnyCodable? {
        guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            return try await operation()
        }
        self.prune()
        if let entry = self.entries[key] {
            return try await entry.task.value
        }
        let task = Task { try await operation() }
        self.entries[key] = Entry(task: task, createdAtMs: self.clock())
        self.order.append(key)
        self.evictOverflow()
        do {
            return try await task.value
        } catch {
            self.forget(key)
            throw error
        }
    }

    /// Cached response for a key, when a completed operation is still retained.
    /// - Parameter key: Idempotency key.
    /// - Returns: The cached payload, or `nil`.
    public func cachedValue(for key: String) async -> AnyCodable? {
        self.prune()
        guard let entry = self.entries[key] else { return nil }
        return try? await entry.task.value
    }

    /// Removes one key.
    /// - Parameter key: Idempotency key.
    public func forget(_ key: String) {
        self.entries[key] = nil
        self.order.removeAll { $0 == key }
    }

    /// Number of retained keys (diagnostics).
    public var count: Int {
        self.entries.count
    }

    private func prune() {
        let cutoff = self.clock() - self.ttlMs
        let expired = self.entries.filter { $0.value.createdAtMs < cutoff }.map(\.key)
        guard !expired.isEmpty else { return }
        for key in expired {
            self.entries[key] = nil
        }
        let expiredSet = Set(expired)
        self.order.removeAll { expiredSet.contains($0) }
    }

    private func evictOverflow() {
        while self.order.count > self.capacity {
            let oldest = self.order.removeFirst()
            self.entries[oldest] = nil
        }
    }
}
