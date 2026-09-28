import CryptoKit
import Foundation
import OpenClawCore
#if compiler(>=6.4) && canImport(StateReporting)
import StateReporting
#endif

/// System state domains that OpenClawKit reports to the Apple StateReporting framework.
///
/// The SDK owns every `ai.openclaw.*` domain. Host apps must not register these domain names with
/// `StateReporter` themselves: StateReporting keeps one reporter per domain, and requesting an
/// existing domain with different metadata types is a fatal error.
public enum OpenClawStateDomain: String, Sendable, CaseIterable {
    /// Gateway WebSocket connection lifecycle (connecting, authenticating, connected, ...).
    case gateway = "ai.openclaw.gateway"
    /// A node-role `node.invoke.request` currently being executed.
    case nodeInvoke = "ai.openclaw.node.invoke"
    /// Embedded or gateway agent run lifecycle.
    case agentRun = "ai.openclaw.agent.run"
    /// Talk mode (listening, thinking, speaking).
    case talk = "ai.openclaw.talk"
    /// Configuration health (loaded, invalid, migrated, ...).
    case config = "ai.openclaw.config"
}

/// A framework-agnostic metadata value reported alongside a system state.
///
/// Values map one-to-one onto StateReporting's `ReportableMetadataValue`. Never put prompt or
/// message text, tokens, passwords, URLs, hosts, or phone numbers into state metadata.
public enum OpenClawStateValue: Sendable, Hashable {
    /// A short, non-sensitive string such as a role or state reason.
    case string(String)
    /// An integer counter or identifier-free number.
    case int(Int)
    /// A floating-point measurement.
    case double(Double)
    /// A boolean flag (reported as an integer by StateReporting).
    case bool(Bool)
    /// A timestamp.
    case date(Date)
}

extension OpenClawStateValue: ExpressibleByStringLiteral {
    /// Creates a string value from a literal.
    public init(stringLiteral value: String) {
        self = .string(value)
    }
}

extension OpenClawStateValue: ExpressibleByIntegerLiteral {
    /// Creates an integer value from a literal.
    public init(integerLiteral value: Int) {
        self = .int(value)
    }
}

extension OpenClawStateValue: ExpressibleByBooleanLiteral {
    /// Creates a boolean value from a literal.
    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }
}

extension OpenClawStateValue: ExpressibleByFloatLiteral {
    /// Creates a floating-point value from a literal.
    public init(floatLiteral value: Double) {
        self = .double(value)
    }
}

/// Metadata dictionary reported with a state transition or volatile update.
public typealias OpenClawStateMetadata = [String: OpenClawStateValue]

/// Sink for OpenClaw system state reports.
///
/// Callers never need `#available`: the shared implementation forwards to StateReporting on
/// iOS/macOS/tvOS/watchOS/visionOS 27 and is a no-op everywhere else. Inject a custom reporter
/// (for example a recording fake in tests) wherever an API accepts one.
public protocol OpenClawSystemStateReporting: Sendable {
    /// Reports a transition of `domain` to a new state.
    /// - Parameters:
    ///   - domain: SDK-owned state domain.
    ///   - label: New state label, or `nil` when the domain has no active state.
    ///   - stable: Metadata that identifies the state; reporting the same label and stable metadata
    ///     again is a no-op for the system.
    ///   - volatile: Metadata that may change while the state is active; discarded on the next transition.
    func reportTransition(
        _ domain: OpenClawStateDomain,
        to label: String?,
        stable: OpenClawStateMetadata,
        volatile: OpenClawStateMetadata)

    /// Reports updated volatile metadata for the current state of `domain`.
    /// - Parameters:
    ///   - domain: SDK-owned state domain.
    ///   - volatile: Replacement volatile metadata.
    func reportVolatileUpdate(_ domain: OpenClawStateDomain, _ volatile: OpenClawStateMetadata)
}

extension OpenClawSystemStateReporting {
    /// Reports a transition without metadata.
    /// - Parameters:
    ///   - domain: SDK-owned state domain.
    ///   - label: New state label, or `nil` when the domain has no active state.
    public func reportTransition(_ domain: OpenClawStateDomain, to label: String?) {
        self.reportTransition(domain, to: label, stable: [:], volatile: [:])
    }
}

/// Reporter that drops every report.
public struct NoopSystemStateReporter: OpenClawSystemStateReporting {
    /// Creates a no-op reporter.
    public init() {}

    /// Ignores the transition.
    public func reportTransition(
        _ domain: OpenClawStateDomain,
        to label: String?,
        stable: OpenClawStateMetadata,
        volatile: OpenClawStateMetadata)
    {}

    /// Ignores the volatile update.
    public func reportVolatileUpdate(_ domain: OpenClawStateDomain, _ volatile: OpenClawStateMetadata) {}
}

/// Reporter decorator that coalesces volatile updates per domain.
///
/// StateReporting rate-limits (and does not log) calls that arrive faster than user-interaction
/// timescales, so this wrapper forwards at most one volatile update per domain per
/// `minimumInterval`. The latest suppressed update is kept and flushed before the next
/// transition of that domain, on the next update after the interval, or by ``flushPendingUpdates()``.
public final class CoalescingSystemStateReporter: OpenClawSystemStateReporting, @unchecked Sendable {
    private let base: any OpenClawSystemStateReporting
    private let minimumInterval: TimeInterval
    private let now: @Sendable () -> Date
    private let scheduleTrailingFlush: Bool
    private let lock = NSLock()
    private var lastVolatileAt: [OpenClawStateDomain: Date] = [:]
    private var pendingVolatile: [OpenClawStateDomain: OpenClawStateMetadata] = [:]
    private var scheduledFlush: Set<OpenClawStateDomain> = []

    /// Creates a coalescing reporter.
    /// - Parameters:
    ///   - base: Reporter that receives the coalesced reports.
    ///   - minimumInterval: Minimum time between forwarded volatile updates for one domain.
    ///   - scheduleTrailingFlush: When true, a suppressed update is also flushed once the interval
    ///     elapses, even if no further report arrives.
    ///   - now: Clock used to measure the interval (injectable for tests).
    public init(
        wrapping base: any OpenClawSystemStateReporting,
        minimumInterval: TimeInterval = 1,
        scheduleTrailingFlush: Bool = true,
        now: @escaping @Sendable () -> Date = { Date() })
    {
        self.base = base
        self.minimumInterval = max(0, minimumInterval)
        self.scheduleTrailingFlush = scheduleTrailingFlush
        self.now = now
    }

    /// Flushes any pending volatile update of `domain`, then forwards the transition.
    public func reportTransition(
        _ domain: OpenClawStateDomain,
        to label: String?,
        stable: OpenClawStateMetadata,
        volatile: OpenClawStateMetadata)
    {
        let pending: OpenClawStateMetadata? = self.lock.withLock {
            let pending = self.pendingVolatile.removeValue(forKey: domain)
            self.lastVolatileAt[domain] = volatile.isEmpty ? nil : self.now()
            return pending
        }
        if let pending {
            self.base.reportVolatileUpdate(domain, pending)
        }
        self.base.reportTransition(domain, to: label, stable: stable, volatile: volatile)
    }

    /// Forwards the update immediately, or keeps it as the pending update when the domain reported
    /// a volatile update less than `minimumInterval` ago.
    public func reportVolatileUpdate(_ domain: OpenClawStateDomain, _ volatile: OpenClawStateMetadata) {
        let current = self.now()
        enum Decision { case forward, hold(schedule: TimeInterval?) }
        let decision: Decision = self.lock.withLock {
            if let last = self.lastVolatileAt[domain], current.timeIntervalSince(last) < self.minimumInterval {
                self.pendingVolatile[domain] = volatile
                guard self.scheduleTrailingFlush, !self.scheduledFlush.contains(domain) else {
                    return .hold(schedule: nil)
                }
                self.scheduledFlush.insert(domain)
                return .hold(schedule: self.minimumInterval - current.timeIntervalSince(last))
            }
            self.pendingVolatile[domain] = nil
            self.lastVolatileAt[domain] = current
            return .forward
        }
        switch decision {
        case .forward:
            self.base.reportVolatileUpdate(domain, volatile)
        case let .hold(delay):
            guard let delay else { return }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
                self?.flush(domain)
            }
        }
    }

    /// Forwards every pending (suppressed) volatile update now.
    public func flushPendingUpdates() {
        let pending: [OpenClawStateDomain: OpenClawStateMetadata] = self.lock.withLock {
            let pending = self.pendingVolatile
            self.pendingVolatile.removeAll()
            let current = self.now()
            for domain in pending.keys {
                self.lastVolatileAt[domain] = current
            }
            return pending
        }
        for (domain, volatile) in pending.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            self.base.reportVolatileUpdate(domain, volatile)
        }
    }

    private func flush(_ domain: OpenClawStateDomain) {
        let pending: OpenClawStateMetadata? = self.lock.withLock {
            self.scheduledFlush.remove(domain)
            guard let pending = self.pendingVolatile.removeValue(forKey: domain) else { return nil }
            self.lastVolatileAt[domain] = self.now()
            return pending
        }
        if let pending {
            self.base.reportVolatileUpdate(domain, pending)
        }
    }
}

/// Reporter used by ``OpenClawSystemState/shared``: drops reports unless reporting is enabled.
struct GatedSystemStateReporter: OpenClawSystemStateReporting {
    let base: any OpenClawSystemStateReporting

    func reportTransition(
        _ domain: OpenClawStateDomain,
        to label: String?,
        stable: OpenClawStateMetadata,
        volatile: OpenClawStateMetadata)
    {
        guard OpenClawSystemState.isEnabled else { return }
        self.base.reportTransition(
            domain,
            to: label,
            stable: OpenClawSystemState.sanitized(stable),
            volatile: OpenClawSystemState.sanitized(volatile))
    }

    func reportVolatileUpdate(_ domain: OpenClawStateDomain, _ volatile: OpenClawStateMetadata) {
        guard OpenClawSystemState.isEnabled else { return }
        self.base.reportVolatileUpdate(domain, OpenClawSystemState.sanitized(volatile))
    }
}

/// Entry point for OpenClaw's system state reporting (Apple StateReporting, OS 27).
///
/// Reporting is opt-in: set ``isEnabled`` to `true` (for example at app launch) to forward SDK state
/// to the system. The SDK registers exactly one `StateReporter` per ``OpenClawStateDomain`` and
/// always uses the same metadata type for both generic parameters, because StateReporting traps
/// when an existing domain is requested with different types. Host apps must not register
/// `ai.openclaw.*` domains themselves.
///
/// Components that are not wired to StateReporting directly can call the domain helpers
/// (``OpenClawGatewayStateReporter``, ``OpenClawNodeInvokeStateReporter``,
/// ``OpenClawTalkStateReporter``, ``OpenClawConfigStateReporter``) or pipe runtime diagnostics
/// through ``diagnosticSink(reporter:forwardingTo:)``.
public enum OpenClawSystemState {
    private static let enabledStorage = OpenClawLockedValue(false)

    /// Whether ``shared`` forwards reports to the system. Defaults to `false` (opt-in).
    public static var isEnabled: Bool {
        get { self.enabledStorage.value }
        set { self.enabledStorage.value = newValue }
    }

    /// Shared reporter: StateReporting on OS 27 (coalesced, sanitized, gated by ``isEnabled``),
    /// otherwise a no-op.
    public static let shared: any OpenClawSystemStateReporting = GatedSystemStateReporter(
        base: CoalescingSystemStateReporter(wrapping: Self.makePlatformReporter()))

    /// Whether the running OS provides StateReporting (OS 27 and later) in this build.
    public static var isSystemReportingAvailable: Bool {
        #if compiler(>=6.4) && canImport(StateReporting)
        if #available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *) {
            return true
        }
        #endif
        return false
    }

    /// Resolves an injected reporter, falling back to ``shared``.
    /// - Parameter reporter: Explicit reporter, or `nil` for the shared one.
    /// - Returns: The reporter to use.
    public static func resolve(_ reporter: (any OpenClawSystemStateReporting)?) -> any OpenClawSystemStateReporting {
        reporter ?? self.shared
    }

    /// Returns a runtime diagnostics sink that maps agent-run events onto ``OpenClawStateDomain/agentRun``.
    ///
    /// Mapping (subsystem `runtime`): `run.started` → `running`, `model.call.started` → `modelCall`,
    /// `tool.call.started`/`tool.started` → `toolRunning`, `model.call.completed` → `finalizing`,
    /// `run.completed` → no state, `run.failed` → `failed`. `model.stream.chunk` becomes a coalesced
    /// volatile update. Stable metadata carries the run id, an 8-byte hash of the session key (session
    /// keys embed channel peer ids), and provider/model ids; error text is never forwarded.
    /// - Parameters:
    ///   - reporter: Destination reporter.
    ///   - next: Optional sink that receives every event after it is mapped.
    /// - Returns: A sink suitable for `EmbeddedAgentRuntime` or `RuntimeDiagnosticsPipeline` chaining.
    public static func diagnosticSink(
        reporter: any OpenClawSystemStateReporting = OpenClawSystemState.shared,
        forwardingTo next: RuntimeDiagnosticSink? = nil) -> RuntimeDiagnosticSink
    {
        let mapper = OpenClawAgentRunStateMapper(reporter: reporter)
        return { event in
            mapper.handle(event)
            await next?(event)
        }
    }

    /// Returns the first 8 bytes (16 hex characters) of the SHA-256 digest of a session key.
    /// - Parameter sessionKey: Raw session key.
    /// - Returns: Hex digest prefix safe to report.
    public static func sessionKeyHash(_ sessionKey: String) -> String {
        let digest = SHA256.hash(data: Data(sessionKey.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Drops metadata entries that could carry secrets or personal data.
    ///
    /// Removes keys that name credentials, message content, or addresses (`token`, `password`,
    /// `secret`, `prompt`, `message`, `url`, `host`, `phone`, `email`, ...) and string values that
    /// look like URLs or bearer credentials, and truncates long strings to 64 characters.
    /// - Parameter metadata: Candidate metadata.
    /// - Returns: Sanitized metadata.
    public static func sanitized(_ metadata: OpenClawStateMetadata) -> OpenClawStateMetadata {
        guard !metadata.isEmpty else { return metadata }
        var result: OpenClawStateMetadata = [:]
        for (key, value) in metadata {
            let lowered = key.lowercased()
            if Self.sensitiveKeys.contains(lowered)
                || Self.sensitiveKeyFragments.contains(where: { lowered.contains($0) })
            {
                continue
            }
            if case let .string(text) = value {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let loweredText = trimmed.lowercased()
                if loweredText.contains("://") || loweredText.hasPrefix("bearer ") || trimmed.contains("@") {
                    continue
                }
                result[key] = .string(trimmed.count > 64 ? String(trimmed.prefix(64)) : trimmed)
            } else {
                result[key] = value
            }
        }
        return result
    }

    private static let sensitiveKeyFragments: [String] = [
        "token", "password", "passwd", "secret", "credential", "cookie", "authorization",
        "prompt", "message", "url", "host", "phone", "email", "address",
    ]

    private static let sensitiveKeys: Set<String> = ["text", "content", "body", "error", "reason"]

    static func makePlatformReporter() -> any OpenClawSystemStateReporting {
        #if compiler(>=6.4) && canImport(StateReporting)
        if #available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *) {
            return AppleSystemStateReporter()
        }
        #endif
        return NoopSystemStateReporter()
    }
}

/// Maps `runtime` diagnostics events onto the agent-run state domain.
struct OpenClawAgentRunStateMapper: Sendable {
    let reporter: any OpenClawSystemStateReporting

    func handle(_ event: RuntimeDiagnosticEvent) {
        guard event.subsystem == "runtime" else { return }
        switch event.name {
        case "run.started":
            self.transition(event, to: "running")
        case "model.call.started":
            self.transition(event, to: "modelCall")
        case "tool.call.started", "tool.started":
            self.transition(event, to: "toolRunning")
        case "tool.call.completed", "tool.completed":
            self.transition(event, to: "modelCall")
        case "model.call.completed":
            self.transition(event, to: "finalizing")
        case "run.completed":
            self.reporter.reportTransition(.agentRun, to: nil, stable: [:], volatile: [:])
        case "run.failed":
            var volatile: OpenClawStateMetadata = [:]
            if let timedOut = event.metadata["timedOut"]?.trimmingCharacters(in: .whitespaces).lowercased() {
                volatile["timedOut"] = .bool(timedOut == "true")
            }
            self.transition(event, to: "failed", volatile: volatile)
        case "model.stream.chunk":
            var volatile: OpenClawStateMetadata = ["lastChunkAt": .date(event.occurredAt)]
            if let index = event.metadata["chunkIndex"].flatMap({ Int($0) }) {
                volatile["chunkIndex"] = .int(index)
            }
            self.reporter.reportVolatileUpdate(.agentRun, volatile)
        default:
            break
        }
    }

    static func stableMetadata(for event: RuntimeDiagnosticEvent) -> OpenClawStateMetadata {
        var stable: OpenClawStateMetadata = [:]
        if let runID = Self.nonEmpty(event.runID) {
            stable["runId"] = .string(runID)
        }
        if let sessionKey = Self.nonEmpty(event.sessionKey) {
            stable["sessionKeyHash"] = .string(OpenClawSystemState.sessionKeyHash(sessionKey))
        }
        if let providerID = Self.nonEmpty(event.metadata["providerID"]) {
            stable["providerID"] = .string(providerID)
        }
        if let modelID = Self.nonEmpty(event.metadata["modelID"]) {
            stable["modelID"] = .string(modelID)
        }
        return stable
    }

    private func transition(_ event: RuntimeDiagnosticEvent, to label: String, volatile: OpenClawStateMetadata = [:]) {
        var volatile = volatile
        if let latency = event.metadata["latencyMs"].flatMap({ Int($0) }) {
            volatile["latencyMs"] = .int(latency)
        }
        self.reporter.reportTransition(
            .agentRun,
            to: label,
            stable: Self.stableMetadata(for: event),
            volatile: volatile)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

/// Small lock-protected value box (the package floors predate `Synchronization.Mutex`).
final class OpenClawLockedValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        self.storage = value
    }

    var value: Value {
        get { self.lock.withLock { self.storage } }
        set { self.lock.withLock { self.storage = newValue } }
    }

    @discardableResult
    func withValue<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        try self.lock.withLock { try body(&self.storage) }
    }
}

#if compiler(>=6.4) && canImport(StateReporting)
/// StateReporting metadata built from an ``OpenClawStateMetadata`` dictionary.
///
/// The SDK uses this single type for both the stable and volatile generic parameters of every
/// OpenClaw `StateReporter`.
@available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
public struct OpenClawReportableMetadata: ReportableMetadata, Sendable {
    /// Reported key/value pairs.
    public let metadataDictionary: [String: ReportableMetadataValue]

    /// Creates metadata from raw StateReporting values.
    /// - Parameter metadataDictionary: Key/value pairs.
    public init(metadataDictionary: [String: ReportableMetadataValue]) {
        self.metadataDictionary = metadataDictionary
    }

    /// Converts framework-agnostic metadata.
    /// - Parameter metadata: OpenClaw metadata values.
    public init(_ metadata: OpenClawStateMetadata) {
        var dictionary: [String: ReportableMetadataValue] = [:]
        for (key, value) in metadata {
            switch value {
            case let .string(text):
                dictionary[key] = ReportableMetadataValue(text)
            case let .int(number):
                dictionary[key] = ReportableMetadataValue(number)
            case let .double(number):
                dictionary[key] = ReportableMetadataValue(number)
            case let .bool(flag):
                dictionary[key] = ReportableMetadataValue(flag)
            case let .date(date):
                dictionary[key] = ReportableMetadataValue(date)
            }
        }
        self.metadataDictionary = dictionary
    }
}

/// ``OpenClawSystemStateReporting`` implementation backed by StateReporting (OS 27).
///
/// Creates one `StateReporter<OpenClawReportableMetadata, OpenClawReportableMetadata>` per domain on
/// first use. Creating several instances is safe: StateReporting returns the same reporter for a
/// domain as long as the metadata types match, which this type guarantees.
@available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
public final class AppleSystemStateReporter: OpenClawSystemStateReporting, @unchecked Sendable {
    /// Concrete reporter type registered for every OpenClaw domain.
    public typealias DomainReporter = StateReporter<OpenClawReportableMetadata, OpenClawReportableMetadata>

    private let lock = NSLock()
    private var reporters: [OpenClawStateDomain: DomainReporter] = [:]

    /// Creates a StateReporting-backed reporter.
    public init() {}

    /// Returns (creating on first use) the system reporter for `domain`.
    /// - Parameter domain: SDK-owned domain.
    /// - Returns: The registered `StateReporter`.
    public func reporter(for domain: OpenClawStateDomain) -> DomainReporter {
        self.lock.withLock {
            if let existing = self.reporters[domain] {
                return existing
            }
            let created = DomainReporter.reporter(
                for: domain.rawValue,
                stableMetadata: OpenClawReportableMetadata.self,
                volatileMetadata: OpenClawReportableMetadata.self)
            self.reporters[domain] = created
            return created
        }
    }

    /// Forwards the transition to StateReporting.
    public func reportTransition(
        _ domain: OpenClawStateDomain,
        to label: String?,
        stable: OpenClawStateMetadata,
        volatile: OpenClawStateMetadata)
    {
        self.reporter(for: domain).reportTransition(
            to: label,
            stableMetadata: stable.isEmpty ? nil : OpenClawReportableMetadata(stable),
            volatileMetadata: volatile.isEmpty ? nil : OpenClawReportableMetadata(volatile))
    }

    /// Forwards the volatile update to StateReporting.
    public func reportVolatileUpdate(_ domain: OpenClawStateDomain, _ volatile: OpenClawStateMetadata) {
        self.reporter(for: domain).reportVolatileMetadataUpdate(
            volatile.isEmpty ? nil : OpenClawReportableMetadata(volatile))
    }
}
#endif
