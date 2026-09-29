import CryptoKit
import Foundation
import OpenClawProtocol
import OSLog

/// Avoid ambiguity with the app's own AnyCodable type.
private typealias ProtoAnyCodable = OpenClawProtocol.AnyCodable

/// Last handshake step a connect attempt completed, for connection diagnostics.
public enum GatewayHandshakePhase: String, Sendable {
    /// The WebSocket task was created and resumed.
    case socketOpened
    /// The server `connect.challenge` arrived.
    case challengeReceived
    /// The signed `connect` request was sent.
    case connectSent
    /// hello-ok arrived and the socket was admitted.
    case helloReceived
}

/// A retryable startup `UNAVAILABLE` rejection of the connect request.
private struct GatewayStartupUnavailableConnectError: Error {
    let rejection: GatewayConnectAuthError
    let retryAfterMs: Int
}

/// Actor-isolated WebSocket gateway channel with reconnect, auth, and request tracking behavior.
///
/// Every physical socket is one *connection generation*. Callbacks, sends, and request
/// completions stay bound to the generation that admitted them, so a late failure from a retired
/// socket can never tear down (or leak state into) its replacement. All connect callers share one
/// in-flight attempt; handshake failures back off on the monotonic clock (500 ms doubling to 30 s).
public actor GatewayChannelActor {
    /// Resolves a request deadline: `0` means no client deadline, `nil` means `defaultMs`.
    nonisolated static func resolveRequestTimeoutMs(_ timeoutMs: Double?, defaultMs: Double) -> Double? {
        timeoutMs == 0 ? nil : (timeoutMs ?? defaultMs)
    }

    static let maxStartupUnavailableRetries = 20

    private var supportedProtocols: ClosedRange<Int> {
        Self.supportedProtocols(for: self.connectOptions)
    }

    private let logger = Logger(subsystem: "ai.openclaw", category: "gateway")
    private var task: WebSocketTaskBox?
    private var activeConnectAttemptID: UUID?
    var pending: [String: PendingRequest] = [:]
    private var connected = false
    private var connectAttemptTask: Task<Void, Never>?
    /// Socket ownership epoch. Every callback and send stays bound to the task
    /// that admitted it so a late failure cannot tear down a replacement socket.
    private var connectionGeneration: UInt64 = 0
    private var disconnectedConnectionGeneration: UInt64?
    private var disconnectError: Error?
    private var automaticReconnectRequested = false
    var connectWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var url: URL
    private var token: String?
    private var bootstrapToken: String?
    private var password: String?
    private let authBindingKey: SymmetricKey?
    private let session: WebSocketSessioning
    private var backoffMs: Double = 500
    var connectFailureBackoff = GatewayConnectFailureBackoff()
    private var shouldReconnect = true
    private var lastSeq: Int?
    /// Monotonic time of the last inbound frame (ticks and any other traffic prove liveness).
    private var lastInboundAt: ContinuousClock.Instant?
    private var helloPolicy = GatewayHelloPolicy()
    private var negotiatedProtocol: Int?
    private var lastHello: (generation: UInt64, hello: HelloOk)?
    private var handshakePhase: GatewayHandshakePhase?
    private var lastAuthSource: GatewayAuthSource = .none
    private var lastAuthBinding: (generation: UInt64, binding: GatewayAuthBinding)?
    private var acceptedHTTPBearer: (generation: UInt64, token: String?)?
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    // Remote gateways (tailscale/wan) can take longer to deliver connect.challenge.
    // Connect now requires this nonce before we send device-auth.
    var connectTimeoutSeconds: Double = 30
    var testConnectAttemptFinishedHandler: (@Sendable (UUID) -> Void)?
    #if DEBUG
    var testConnectRunFinishedHandler: (@Sendable () -> Void)?
    var testConnectFailureBackoffWaitHandler: (@Sendable () async throws -> Void)?
    var testRequestResumedHandler: (@Sendable () async -> Void)?
    #endif
    private let connectChallengeTimeoutSeconds: Double = 6.0
    // Some networks will silently drop idle TCP/TLS flows around ~30s. The gateway tick is server->client,
    // but NATs/proxies often require outbound traffic to keep the connection alive.
    private let keepaliveIntervalSeconds: Double = 15.0
    private var watchdogTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?
    private var pendingDeviceTokenRetry = false
    private var deviceTokenRetryBudgetUsed = false
    private var receivedDeviceAuthRoles = Set<String>()
    private var persistedDeviceAuthRoles = Set<String>()
    private var reconnectPausedForAuthFailure = false
    /// Set when a TLS pin mismatch stopped automatic reconnects; cleared by
    /// ``resumeAfterTLSRepair()``.
    private var reconnectPausedForTLSFailure = false
    private var lastTLSFailure: GatewayTLSValidationFailure?
    private var pendingTLSPinRotation: GatewayTLSPinRotationRequest?
    /// Scheduled automatic resume after an `AUTH_RATE_LIMITED` rejection that carried `retryAfterMs`.
    private var rateLimitResumeTask: Task<Void, Never>?
    private var rateLimitRetryAfterMs: Int?
    /// Lifecycle reporter for ``OpenClawStateDomain/gateway`` (drops reports unless
    /// ``OpenClawSystemState/isEnabled`` is set or a reporter is injected).
    private var gatewayStateReporter: OpenClawGatewayStateReporter
    private let defaultRequestTimeoutMs: Double = 15000
    private let extraHeadersProvider: (@Sendable () -> [String: String])?
    /// Fast state admission for clients that must inspect hello before their
    /// first request. General push delivery remains asynchronous.
    private let connectSnapshotAdmissionHandler: (@Sendable (HelloOk, UInt64) async -> Void)?
    private let pushHandler: (@Sendable (GatewayPush, UInt64) async -> Void)?
    private var connectOptions: GatewayConnectOptions?
    private let disconnectHandler: (@Sendable (String, UInt64) async -> Void)?

    /// Operator-supplied proxy credentials (Cloudflare Access-style) ride on the upgrade
    /// request. Read from the provider at connect time so edits apply on the next reconnect
    /// without re-pairing. Values are credentials: never log them.
    private var workerEdgeCredentials: [String: String]?

    /// Creates a gateway channel actor for one endpoint.
    ///
    /// - Parameters:
    ///   - url: Gateway WebSocket URL (`ws://` or `wss://`).
    ///   - token: Explicit shared token.
    ///   - bootstrapToken: Setup-code bootstrap token.
    ///   - password: Gateway password.
    ///   - authBindingKey: Key for ``authBinding(ifCurrentConnectionGeneration:)`` fingerprints.
    ///   - session: WebSocket session (defaults to a plain `URLSession`).
    ///   - connectSnapshotAdmissionHandler: Awaited inside the handshake with hello-ok and its generation.
    ///   - pushHandler: Receives snapshots, events, and sequence gaps with their socket generation.
    ///   - connectOptions: Connect-frame options (defaults to ``GatewayConnectOptions/defaultOperator(displayName:)``).
    ///   - disconnectHandler: Receives the disconnect reason and the retired socket generation.
    ///   - extraHeadersProvider: Custom proxy headers, read on every `wss://` upgrade.
    ///   - stateReporter: Destination for ``OpenClawStateDomain/gateway`` lifecycle reports; `nil`
    ///     uses ``OpenClawSystemState/shared``, which only forwards while ``OpenClawSystemState/isEnabled``.
    public init(
        url: URL,
        token: String?,
        bootstrapToken: String? = nil,
        password: String? = nil,
        authBindingKey: SymmetricKey? = nil,
        session: WebSocketSessionBox? = nil,
        connectSnapshotAdmissionHandler: (@Sendable (HelloOk, UInt64) async -> Void)? = nil,
        pushHandler: (@Sendable (GatewayPush, UInt64) async -> Void)? = nil,
        connectOptions: GatewayConnectOptions? = nil,
        disconnectHandler: (@Sendable (String, UInt64) async -> Void)? = nil,
        extraHeadersProvider: (@Sendable () -> [String: String])? = nil,
        stateReporter: (any OpenClawSystemStateReporting)? = nil)
    {
        self.url = url
        self.token = token
        self.bootstrapToken = bootstrapToken
        self.password = password
        self.authBindingKey = authBindingKey
        self.extraHeadersProvider = extraHeadersProvider
        self.session = session?.session ?? URLSession(configuration: .default)
        self.connectSnapshotAdmissionHandler = connectSnapshotAdmissionHandler
        self.pushHandler = pushHandler
        self.connectOptions = connectOptions
        self.disconnectHandler = disconnectHandler
        self.gatewayStateReporter = OpenClawGatewayStateReporter(
            reporter: stateReporter,
            context: OpenClawGatewayStateContext(url: url, options: connectOptions))
        Task { [weak self] in
            await self?.startWatchdog()
        }
    }

    /// Creates a channel with the pre-2026.3 single-argument push and disconnect callbacks.
    @available(*, deprecated, message: "Use the initializer whose callbacks also receive the socket generation.")
    public init(
        url: URL,
        token: String?,
        bootstrapToken: String? = nil,
        password: String? = nil,
        session: WebSocketSessionBox? = nil,
        pushHandler: (@Sendable (GatewayPush) async -> Void)?,
        connectOptions: GatewayConnectOptions? = nil,
        disconnectHandler: (@Sendable (String) async -> Void)? = nil)
    {
        var generationPushHandler: (@Sendable (GatewayPush, UInt64) async -> Void)?
        if let pushHandler {
            generationPushHandler = { push, _ in await pushHandler(push) }
        }
        var generationDisconnectHandler: (@Sendable (String, UInt64) async -> Void)?
        if let disconnectHandler {
            generationDisconnectHandler = { reason, _ in await disconnectHandler(reason) }
        }
        self.init(
            url: url,
            token: token,
            bootstrapToken: bootstrapToken,
            password: password,
            authBindingKey: nil,
            session: session,
            connectSnapshotAdmissionHandler: nil,
            pushHandler: generationPushHandler,
            connectOptions: connectOptions,
            disconnectHandler: generationDisconnectHandler,
            extraHeadersProvider: nil)
    }

    /// Returns the auth source used for the most recent connect attempt.
    public func authSource() -> GatewayAuthSource {
        self.lastAuthSource
    }

    /// Opaque binding of the credentials the given live socket authenticated with.
    /// - Returns: `nil` unless `expectedGeneration` is the connected, running socket.
    public func authBinding(ifCurrentConnectionGeneration expectedGeneration: UInt64) -> GatewayAuthBinding? {
        guard self.isConnected(connectionGeneration: expectedGeneration),
              self.task?.state == .running,
              self.lastAuthBinding?.generation == expectedGeneration
        else { return nil }
        return self.lastAuthBinding?.binding
    }

    /// Native HTTP adapters reuse the credential accepted by this exact socket,
    /// including stored device tokens that the hello response does not reissue.
    /// - Returns: `nil` for bootstrap/no-auth sockets or when the generation is not current.
    public func httpResourceBearer(ifCurrentConnectionGeneration expectedGeneration: UInt64) -> String? {
        guard self.authBinding(ifCurrentConnectionGeneration: expectedGeneration) != nil,
              self.acceptedHTTPBearer?.generation == expectedGeneration
        else { return nil }
        return self.acceptedHTTPBearer?.token
    }

    /// Protocol version the gateway selected in the most recent hello-ok, or `nil` before any hello.
    ///
    /// Operators negotiate 4; node sessions may negotiate 3 (N-1). Gate v4-only surfaces (chat
    /// `deltaText`, plugin surfaces) on this value.
    public func negotiatedProtocolVersion() -> Int? {
        self.negotiatedProtocol
    }

    /// Transport policy from the most recent hello-ok (upstream defaults before hello).
    public func currentHelloPolicy() -> GatewayHelloPolicy {
        self.helloPolicy
    }

    /// hello-ok of the live socket, or `nil` when disconnected.
    public func currentHello() -> HelloOk? {
        guard let lastHello, self.isConnected(connectionGeneration: lastHello.generation) else { return nil }
        return lastHello.hello
    }

    /// Last handshake phase the most recent connect attempt completed.
    public func currentHandshakePhase() -> GatewayHandshakePhase? {
        self.handshakePhase
    }

    /// Shuts down the socket, cancels reconnect work, and fails any pending requests.
    public func shutdown() async {
        self.shouldReconnect = false
        self.connected = false
        self.acceptedHTTPBearer = nil
        self.activeConnectAttemptID = nil
        self.automaticReconnectRequested = false
        self.connectAttemptTask?.cancel()
        self.connectAttemptTask = nil
        // Invalidate callbacks from the socket before cancellation can deliver
        // its receive completion on another task.
        self.connectionGeneration &+= 1

        self.watchdogTask?.cancel()
        self.watchdogTask = nil

        self.tickTask?.cancel()
        self.tickTask = nil

        self.keepaliveTask?.cancel()
        self.keepaliveTask = nil

        self.rateLimitResumeTask?.cancel()
        self.rateLimitResumeTask = nil

        self.task?.cancel(with: .goingAway, reason: nil)
        self.task = nil
        self.gatewayStateReporter.disconnected()

        self.failPending(NSError(
            domain: "Gateway",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: "gateway channel shutdown"]))

        let waiters = self.connectWaiters
        self.connectWaiters.removeAll()
        for waiter in waiters.values {
            waiter.resume(throwing: NSError(
                domain: "Gateway",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "gateway channel shutdown"]))
        }
    }

    /// Forces a reconnect when the live socket has been silent for more than twice the tick interval.
    ///
    /// Host apps call this when returning to the foreground (for example on `scenePhase == .active`):
    /// a suspended app can resume holding a socket the gateway already dropped.
    /// - Parameter now: Current monotonic time.
    /// - Returns: `true` when a stale socket was retired and a reconnect scheduled.
    @discardableResult
    public func reconnectIfStale(now: ContinuousClock.Instant = ContinuousClock.now) async -> Bool {
        let generation = self.connectionGeneration
        guard self.isConnected(connectionGeneration: generation),
              let last = self.lastInboundAt
        else { return false }
        let toleranceMs = self.helloPolicy.tickIntervalMs * 2
        guard Self.milliseconds(from: last, to: now) > toleranceMs else { return false }
        let error = NSError(
            domain: "Gateway",
            code: 4,
            userInfo: [NSLocalizedDescriptionKey: "gateway connection stale; reconnecting"])
        await self.transitionToDisconnected(
            reason: error.localizedDescription,
            error: error,
            connectionGeneration: generation,
            shouldReconnect: true,
            closeCode: Self.tickTimeoutCloseCode)
        return true
    }

    /// Resets reconnect backoff and reconnects now if the channel is disconnected.
    ///
    /// Call this on network path changes instead of waiting for the 30 s watchdog. It never
    /// overrides an auth-failure pause.
    public func nudgeReconnect() {
        guard self.shouldReconnect, !self.reconnectPausedForAuthFailure, !self.reconnectPausedForTLSFailure else {
            return
        }
        self.backoffMs = 500
        self.connectFailureBackoff.reset()
        guard !self.connected, self.connectAttemptTask == nil else { return }
        Task { [weak self] in
            try? await self?.connect()
        }
    }

    /// Why automatic reconnects are currently stopped, or `nil` while they run.
    public func reconnectPauseReason() -> GatewayReconnectPauseReason? {
        if self.reconnectPausedForTLSFailure { return .tlsPinMismatch }
        if self.reconnectPausedForAuthFailure { return .authFailure }
        return nil
    }

    /// Re-trust request from the TLS pin mismatch that stopped automatic reconnects.
    ///
    /// Present both fingerprints to the user. Only after they confirm, call
    /// ``acceptTLSPinRotation(_:)``, which updates the stored pin (and a ``GatewayTLSPinningSession``'s
    /// in-memory pin) and reconnects.
    /// - Returns: `nil` unless a pin mismatch paused reconnects and the failure carried both fingerprints.
    public func pendingTLSPinRotationRequest() -> GatewayTLSPinRotationRequest? {
        guard self.reconnectPausedForTLSFailure else { return nil }
        return self.pendingTLSPinRotation
    }

    /// Classification of the most recent TLS failure a connect attempt reported, or `nil` when the
    /// last attempt had none.
    public func lastTLSFailureClassification() -> GatewayTLSFailureClassification? {
        self.lastTLSFailure.map(GatewayTLSFailureClassification.init(failure:))
    }

    /// Accepts the pending pin rotation after the user confirmed it, then reconnects.
    ///
    /// With a ``GatewayTLSPinningSession`` or `NetworkConnectionWebSocketSession` the session's
    /// in-memory pin is updated too (``GatewayTLSPinningSession/acceptPinRotation(_:)``); other
    /// sessions only update ``GatewayTLSStore``. Never call this without explicit user confirmation.
    /// - Parameter request: The request from ``pendingTLSPinRotationRequest()``.
    /// - Returns: `false` when `request` is not the pending one or the stored pin changed meanwhile.
    @discardableResult
    public func acceptTLSPinRotation(_ request: GatewayTLSPinRotationRequest) -> Bool {
        guard self.reconnectPausedForTLSFailure, self.pendingTLSPinRotation == request else { return false }
        let accepted = if let pinningSession = self.session as? GatewayTLSPinRotationAccepting {
            pinningSession.acceptPinRotation(request)
        } else {
            GatewayTLSStore.acceptRotation(request)
        }
        guard accepted else { return false }
        self.resumeAfterTLSRepair()
        return true
    }

    /// Clears a TLS pin-mismatch pause and reconnects.
    ///
    /// Call after the user reviewed the certificate (for example after
    /// ``GatewayTLSStore/acceptRotation(_:)``). Never call this automatically.
    public func resumeAfterTLSRepair() {
        guard self.reconnectPausedForTLSFailure else { return }
        self.reconnectPausedForTLSFailure = false
        self.pendingTLSPinRotation = nil
        self.lastTLSFailure = nil
        self.backoffMs = 500
        self.connectFailureBackoff.reset()
        guard self.shouldReconnect, !self.connected, self.connectAttemptTask == nil else { return }
        Task { [weak self] in
            await self?.reconnectAfterPause(context: "gateway reconnect after TLS repair")
        }
    }

    private func startWatchdog() {
        self.watchdogTask?.cancel()
        self.watchdogTask = Task { [weak self] in
            guard let self else { return }
            await self.watchdogLoop()
        }
    }

    private func watchdogLoop() async {
        // Keep nudging reconnect in case exponential backoff stalls.
        while self.shouldReconnect {
            guard await self.sleepUnlessCancelled(nanoseconds: 30 * 1_000_000_000) else { return } // 30s cadence
            guard self.shouldReconnect else { return }
            if self.reconnectPausedForAuthFailure || self.reconnectPausedForTLSFailure { continue }
            if self.connected { continue }
            await self.reconnectAfterPause(context: "gateway watchdog reconnect")
        }
    }

    /// Reconnects once, pausing automatic reconnects when the failure is a non-recoverable auth rejection.
    private func reconnectAfterPause(context: String) async {
        do {
            try await self.connect()
        } catch {
            if self.shouldPauseReconnectAfterAuthFailure(error) {
                self.pauseReconnectAfterAuthFailure(error, context: context)
                return
            }
            let wrapped = self.wrap(error, context: context)
            self.logger.error("\(context, privacy: .public) failed \(wrapped.localizedDescription, privacy: .public)")
        }
    }

    private func pauseReconnectAfterAuthFailure(_ error: Error, context: String) {
        self.reconnectPausedForAuthFailure = true
        let failure = error.localizedDescription
        self.logger.error(
            "\(context, privacy: .public) paused for non-recoverable auth failure \(failure, privacy: .public)")
        self.scheduleRateLimitResumeIfNeeded(error)
    }

    /// `AUTH_RATE_LIMITED` is a pause, not a permanent stop: when the gateway says how long to wait
    /// (`retryAfterMs`), resume once after that delay (clamped to 1 s ... 15 min) instead of looping
    /// pairing requests on every reconnect.
    private func scheduleRateLimitResumeIfNeeded(_ error: Error) {
        guard let authError = error as? GatewayConnectAuthError,
              authError.detail == .authRateLimited,
              let retryAfterMs = self.rateLimitRetryAfterMs, retryAfterMs > 0
        else { return }
        let delayMs = UInt64(min(max(retryAfterMs, 1000), 15 * 60 * 1000))
        self.rateLimitResumeTask?.cancel()
        self.rateLimitResumeTask = Task { [weak self] in
            guard let self else { return }
            guard await self.sleepUnlessCancelled(nanoseconds: delayMs * 1_000_000) else { return }
            await self.resumeAfterRateLimit()
        }
    }

    private func resumeAfterRateLimit() async {
        self.rateLimitResumeTask = nil
        guard self.shouldReconnect, self.reconnectPausedForAuthFailure, !self.reconnectPausedForTLSFailure else {
            return
        }
        self.reconnectPausedForAuthFailure = false
        self.rateLimitRetryAfterMs = nil
        guard !self.connected, self.connectAttemptTask == nil else { return }
        await self.reconnectAfterPause(context: "gateway reconnect after rate limit")
    }

    func currentWorkerEdgeCredentials() -> [String: String]? {
        self.workerEdgeCredentials
    }

    private func makeUpgradeRequest() -> URLRequest {
        self.workerEdgeCredentials = nil
        var request = URLRequest(url: self.url)
        // Custom headers can contain service tokens or Authorization values. Do not even read
        // the provider for cleartext routes, where credentials would be exposed in transit.
        guard self.url.scheme?.lowercased() == "wss" else { return request }
        guard let headers = self.extraHeadersProvider?(), !headers.isEmpty else { return request }
        for (name, value) in GatewayCustomHeaders.sanitized(headers) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let clientID = request.value(forHTTPHeaderField: "CF-Access-Client-Id"),
           let clientSecret = request.value(forHTTPHeaderField: "CF-Access-Client-Secret")
        {
            self.workerEdgeCredentials = ["clientId": clientID, "clientSecret": clientSecret]
        }
        return request
    }

    /// Connects to the gateway if needed and performs the full connect handshake.
    ///
    /// Concurrent callers join one shared attempt. Throws `NSError(domain: "Gateway", code: 6)`
    /// after ``shutdown()``, and `CancellationError` when the caller is cancelled.
    public func connect() async throws {
        try Task.checkCancellation()
        guard self.shouldReconnect else {
            throw NSError(
                domain: "Gateway",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "gateway channel is shut down"])
        }
        if let disconnectError { throw disconnectError }
        if self.connected, self.task?.state == .running {
            return
        }
        if self.connectAttemptTask == nil {
            self.connectAttemptTask = Task { [weak self] in
                await self?.runConnectAttempt()
            }
        }
        try await self.waitForConnectAttempt()
    }

    private func runConnectAttempt() async {
        do {
            try await self.performConnectAttempt()
            self.finishConnectAttempt(error: nil)
        } catch {
            self.finishConnectAttempt(error: error)
        }
        #if DEBUG
        self.testConnectRunFinishedHandler?()
        #endif
    }

    private func waitForConnectAttempt() async throws {
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            do {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    if Task.isCancelled {
                        cont.resume(throwing: CancellationError())
                    } else {
                        self.connectWaiters[waiterID] = cont
                    }
                }
                try Task.checkCancellation()
            } catch {
                try Task.checkCancellation()
                throw error
            }
        } onCancel: {
            Task { await self.cancelConnectWaiter(id: waiterID) }
        }
    }

    private func finishConnectAttempt(error: Error?) {
        self.connectAttemptTask = nil
        let waiters = self.connectWaiters
        self.connectWaiters.removeAll()
        for waiter in waiters.values {
            if let error {
                waiter.resume(throwing: error)
            } else {
                waiter.resume(returning: ())
            }
        }
    }

    private func performConnectAttempt() async throws {
        guard self.shouldReconnect else { throw CancellationError() }
        if let disconnectError { throw disconnectError }
        try await self.waitForConnectFailureBackoff()
        try Task.checkCancellation()
        guard self.shouldReconnect else { throw CancellationError() }
        if let disconnectError { throw disconnectError }
        if self.connected {
            if self.task?.state == .running { return }
            let staleGeneration = self.connectionGeneration
            let staleError = NSError(
                domain: "Gateway",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: "gateway socket stopped before reconnect"])
            // URLSession may publish a terminal task state before its receive
            // failure callback reaches this actor. Retire that generation first
            // so pending requests and native input lifecycle cleanup cannot leak
            // across the replacement socket.
            await self.transitionToDisconnected(
                reason: staleError.localizedDescription,
                error: staleError,
                connectionGeneration: staleGeneration,
                shouldReconnect: false)
            guard self.shouldReconnect else { throw CancellationError() }
        }

        // A gateway still starting its sidecars answers UNAVAILABLE(startup-sidecars). Retry
        // within the caller's handshake budget, without backoff escalation or auth bookkeeping.
        let clock = ContinuousClock()
        let budgetMs = self.connectOptions?.handshakeTimeoutMs.map { Double(max(1, $0)) }
            ?? max(0, self.connectTimeoutSeconds) * 1000
        let deadline = clock.now.advanced(by: .milliseconds(Int64(budgetMs)))
        while true {
            do {
                try await self.performConnectHandshake(deadline: deadline)
                return
            } catch let startup as GatewayStartupUnavailableConnectError {
                let delay = Duration.milliseconds(startup.retryAfterMs)
                guard clock.now.advanced(by: delay) < deadline else {
                    try await self.failConnectAttempt(startup.rejection)
                    return
                }
                self.logger.info("gateway starting; retrying connect in \(startup.retryAfterMs, privacy: .public)ms")
                try await clock.sleep(for: delay)
                try Task.checkCancellation()
                guard self.shouldReconnect else { throw CancellationError() }
            }
        }
    }

    /// Opens one socket and runs the handshake, bounded by `deadline`.
    private func performConnectHandshake(deadline: ContinuousClock.Instant) async throws {
        self.connectionGeneration &+= 1
        let connectionGeneration = self.connectionGeneration
        self.task?.cancel(with: .goingAway, reason: nil)
        let attemptID = UUID()
        self.gatewayStateReporter.context.tlsPinned = self.isTLSPinned()
        self.gatewayStateReporter.connecting(
            backoffMs: self.automaticReconnectRequested ? Int(self.connectFailureBackoff.currentDelayMs) : nil)
        let connectTask = self.session.makeWebSocketTask(request: self.makeUpgradeRequest())
        self.activeConnectAttemptID = attemptID
        self.task = connectTask
        connectTask.resume()
        self.handshakePhase = .socketOpened
        let remainingSeconds = max(0.001, Self.milliseconds(from: ContinuousClock.now, to: deadline) / 1000)
        let connectHello: HelloOk
        do {
            connectHello = try await AsyncTimeout.withTimeout(
                seconds: remainingSeconds,
                // A handshake deadline is a transport failure, just like a URLSession
                // timeout. Keep it typed so endpoint failover can distinguish auth rejection.
                onTimeout: { URLError(.timedOut) },
                operation: {
                    try await self.sendConnect(
                        task: connectTask,
                        attemptID: attemptID,
                        connectionGeneration: connectionGeneration)
                })
            try self.ensureCurrentConnectAttempt(attemptID, task: connectTask)
            try self.requireCurrentConnection(connectionGeneration)
        } catch let startup as GatewayStartupUnavailableConnectError {
            // Quietly retire this never-admitted socket; the caller retries on a fresh generation.
            if self.task?.task === connectTask.task {
                self.task = nil
            }
            self.activeConnectAttemptID = nil
            connectTask.cancel(with: .goingAway, reason: nil)
            throw startup
        } catch {
            try await self.failConnectAttempt(error, connectionGeneration: connectionGeneration)
            return
        }
        self.activeConnectAttemptID = nil
        guard self.connectionGeneration == connectionGeneration,
              self.disconnectedConnectionGeneration != connectionGeneration,
              self.shouldReconnect
        else { throw CancellationError() }
        self.connected = true
        self.automaticReconnectRequested = false
        self.reconnectPausedForAuthFailure = false
        self.backoffMs = 500
        self.connectFailureBackoff.reset()
        self.lastSeq = nil
        self.lastTLSFailure = nil
        self.rateLimitRetryAfterMs = nil
        self.handshakePhase = .helloReceived
        self.gatewayStateReporter.context.protocolVersion = self.negotiatedProtocol ?? GATEWAY_PROTOCOL_VERSION
        self.gatewayStateReporter.context.tlsPinned = self.isTLSPinned()
        self.gatewayStateReporter.connected(pendingRequests: self.pending.count, lastSeq: self.lastSeq)
        self.listen(connectionGeneration: connectionGeneration)
        self.startTickWatchdog(connectionGeneration: connectionGeneration)
        self.startKeepalive(connectionGeneration: connectionGeneration)
        // Snapshot callbacks may resolve a route through currentConnectionGeneration().
        // Publish only after the physical socket is admitted and its receive loop is armed.
        Task { [weak self] in
            await self?.deliverPushIfCurrent(
                .snapshot(connectHello),
                connectionGeneration: connectionGeneration)
        }
    }

    /// Records a failed handshake, retires its socket, and rethrows the wrapped error.
    private func failConnectAttempt(_ error: Error, connectionGeneration: UInt64? = nil) async throws {
        let generation = connectionGeneration ?? self.connectionGeneration
        let wrapped: Error = if let authError = error as? GatewayConnectAuthError {
            authError
        } else {
            self.wrap(error, context: "connect to gateway @ \(self.url.absoluteString)")
        }
        self.connectFailureBackoff.record(
            error: error,
            pendingDeviceTokenRetry: self.pendingDeviceTokenRetry,
            supportedProtocols: self.supportedProtocols)
        let pinMismatch = self.recordTLSFailure(from: wrapped)
        if pinMismatch {
            // A changed certificate must never be retried (or silently re-pinned) behind the
            // user's back: stop automatic reconnects until the host resolves the rotation request.
            self.automaticReconnectRequested = false
        }
        self.reportConnectFailure(wrapped, pinMismatch: pinMismatch)
        await self.transitionToDisconnected(
            reason: "connect failed: \(wrapped.localizedDescription)",
            error: wrapped,
            connectionGeneration: generation,
            shouldReconnect: self.automaticReconnectRequested)
        self.logger.error("gateway ws connect failed \(wrapped.localizedDescription, privacy: .public)")
        throw wrapped
    }

    /// Records a typed TLS failure; a pin mismatch pauses reconnects with a rotation request.
    /// - Returns: `true` when the failure was a pin mismatch.
    private func recordTLSFailure(from error: Error) -> Bool {
        guard let tlsError = error as? GatewayTLSValidationError else {
            self.lastTLSFailure = nil
            return false
        }
        self.lastTLSFailure = tlsError.failure
        guard tlsError.failure.kind == .pinMismatch else { return false }
        self.reconnectPausedForTLSFailure = true
        self.pendingTLSPinRotation = GatewayTLSPinRotationRequest(failure: tlsError.failure)
        return true
    }

    private func reportConnectFailure(_ error: Error, pinMismatch: Bool) {
        let problemKind = GatewayConnectionProblemMapper.map(error: error)?.kind.rawValue
        if pinMismatch {
            self.gatewayStateReporter.failed(problemKind: problemKind)
        } else if self.shouldPauseReconnectAfterAuthFailure(error) {
            self.gatewayStateReporter.authPaused(authDetailCode: (error as? GatewayConnectAuthError)?.detailCodeRaw)
        } else if self.automaticReconnectRequested, self.shouldReconnect {
            self.gatewayStateReporter.reconnecting(
                backoffMs: Int(self.connectFailureBackoff.currentDelayMs),
                pendingRequests: self.pending.count,
                problemKind: problemKind)
        } else if !(error is CancellationError) {
            self.gatewayStateReporter.failed(problemKind: problemKind)
        }
    }

    /// Whether the session enforces a TLS pin (so the state report can say so without the fingerprint).
    private func isTLSPinned() -> Bool {
        (self.session as? GatewayTLSRouteMetadataProviding)?.effectiveTLSFingerprintSHA256 != nil
    }

    private func startKeepalive(connectionGeneration: UInt64) {
        self.keepaliveTask?.cancel()
        self.keepaliveTask = Task { [weak self] in
            guard let self else { return }
            await self.keepaliveLoop(connectionGeneration: connectionGeneration)
        }
    }

    private func keepaliveLoop(connectionGeneration: UInt64) async {
        while self.shouldReconnect {
            guard await self.sleepUnlessCancelled(
                nanoseconds: UInt64(self.keepaliveIntervalSeconds * 1_000_000_000))
            else { return }
            guard self.shouldReconnect else { return }
            guard self.isConnected(connectionGeneration: connectionGeneration) else { return }
            guard let task = self.task else { continue }
            // Best-effort ping keeps NAT/proxy state alive without generating RPC load.
            // The ping is bounded (WebSocketTaskBox.pingTimeout); the tick watchdog owns liveness.
            do {
                try await task.sendPing()
            } catch {
                // Avoid spamming logs; the reconnect paths will surface meaningful errors.
            }
        }
    }

    static func loadDeviceIdentityForConnect(
        includeDeviceIdentity: Bool,
        profile: GatewayDeviceIdentityProfile) async throws -> DeviceIdentity?
    {
        guard includeDeviceIdentity else { return nil }
        // Storage failures surface as connect errors instead of rotating to an unpaired identity.
        // The SQLite-backed store blocks, so it runs on the native-state queue, not on this actor.
        return try await DeviceIdentityStore.loadOrCreatePersistedInBackground(profile: profile)
    }

    private func sendConnect(
        task: WebSocketTaskBox,
        attemptID: UUID,
        connectionGeneration: UInt64) async throws -> HelloOk
    {
        defer { self.testConnectAttemptFinishedHandler?(attemptID) }
        try self.ensureCurrentConnectAttempt(attemptID, task: task)
        try self.requireCurrentConnection(connectionGeneration)
        let platform = InstanceIdentity.platformString
        let primaryLocale = Locale.preferredLanguages.first ?? Locale.current.identifier
        let options = self.connectOptions ?? GatewayConnectOptions.defaultOperator()
        let clientDisplayName = options.clientDisplayName ?? InstanceIdentity.displayName
        let clientId = options.clientId
        let clientMode = options.clientMode
        let role = options.role
        let protocols = self.supportedProtocols
        let deviceIdentityProfile = options.deviceIdentityProfile
        let requestedScopes = options.scopes
        let includeDeviceIdentity = options.includeDeviceIdentity
        let deviceAuthGatewayID = options.deviceAuthGatewayID
        let identity = try await Self.loadDeviceIdentityForConnect(
            includeDeviceIdentity: includeDeviceIdentity,
            profile: deviceIdentityProfile)
        let selectedAuth = self.selectConnectAuth(
            role: role,
            includeDeviceIdentity: includeDeviceIdentity,
            allowStoredDeviceAuth: options.allowStoredDeviceAuth,
            deviceAuthGatewayID: deviceAuthGatewayID,
            deviceIdentityProfile: deviceIdentityProfile,
            deviceId: identity?.deviceId,
            requestedScopes: requestedScopes)
        self.gatewayStateReporter.context.authSource = selectedAuth.authSource.rawValue
        let scopes = self.resolveConnectScopes(
            role: role,
            requestedScopes: requestedScopes,
            scopesAreExplicit: options.scopesAreExplicit,
            selectedAuth: selectedAuth)

        let reqId = UUID().uuidString
        let client = GatewayConnectPayload.makeClient(
            options: options,
            displayName: clientDisplayName,
            platform: platform)
        var params: [String: ProtoAnyCodable] = [
            "minProtocol": ProtoAnyCodable(protocols.lowerBound),
            "maxProtocol": ProtoAnyCodable(protocols.upperBound),
            "client": ProtoAnyCodable(client),
            "caps": ProtoAnyCodable(options.caps),
            "locale": ProtoAnyCodable(primaryLocale),
            "userAgent": ProtoAnyCodable(ProcessInfo.processInfo.operatingSystemVersionString),
            "role": ProtoAnyCodable(role),
            "scopes": ProtoAnyCodable(scopes),
        ]
        options.applyOptionalConnectParams(to: &params)
        self.applyConnectAuth(
            selectedAuth,
            deviceId: identity?.deviceId,
            connectionGeneration: connectionGeneration,
            to: &params)
        let connectChallenge = try await self.waitForConnectChallenge(task: task, attemptID: attemptID)
        // Sign with the server clock so device clock skew cannot expire the proof.
        let signedAtMs = connectChallenge.issuedAtMs
        let connectNonce = connectChallenge.nonce
        try self.ensureCurrentConnectAttempt(attemptID, task: task)
        try self.requireCurrentConnection(connectionGeneration)
        self.handshakePhase = .challengeReceived
        self.gatewayStateReporter.authenticating()
        if includeDeviceIdentity, let identity {
            let deviceAuthFields = GatewayDeviceAuthPayload.Fields(
                deviceId: identity.deviceId,
                client: .init(id: clientId, mode: clientMode),
                role: role,
                scopes: scopes,
                signedAtMs: signedAtMs,
                token: selectedAuth.signatureToken,
                nonce: connectNonce)
            let payload = switch options.deviceProofPayload {
            case .v2Compatible:
                GatewayDeviceAuthPayload.buildConnectCompatibilityPayload(fields: deviceAuthFields)
            case .v3:
                GatewayDeviceAuthPayload.buildV3(
                    fields: deviceAuthFields,
                    platform: platform,
                    deviceFamily: InstanceIdentity.deviceFamily)
            }
            if let device = GatewayDeviceAuthPayload.signedDeviceDictionary(
                payload: payload,
                identity: identity,
                signedAtMs: signedAtMs,
                nonce: connectNonce)
            {
                params["device"] = ProtoAnyCodable(device)
            }
        }

        let frame = RequestFrame(
            type: "req",
            id: reqId,
            method: "connect",
            params: ProtoAnyCodable(params))
        let data = try self.encoder.encode(frame)
        try await task.send(.data(data))
        try self.ensureCurrentConnectAttempt(attemptID, task: task)
        try self.requireCurrentConnection(connectionGeneration)
        self.handshakePhase = .connectSent
        do {
            let response = try await self.waitForConnectResponse(
                reqId: reqId,
                task: task,
                attemptID: attemptID)
            try self.ensureCurrentConnectAttempt(attemptID, task: task)
            try self.requireCurrentConnection(connectionGeneration)
            let outcome = try await self.handleConnectResponse(
                response,
                identity: identity,
                selectedAuth: selectedAuth,
                options: options,
                connectionGeneration: connectionGeneration)
            self.receivedDeviceAuthRoles.formUnion(outcome.receivedRoles)
            self.persistedDeviceAuthRoles.formUnion(outcome.persistedRoles)
            if outcome.persistedRoles.contains(role) {
                // Only a token persisted from this endpoint may unlock stored auth for its role.
                self.connectOptions?.allowStoredDeviceAuth = true
                if selectedAuth.authSource == .bootstrapToken {
                    // The gateway consumed the setup code. Reconnects must use the persisted device
                    // token (or an explicit password) instead of replaying the stale bootstrap token.
                    self.bootstrapToken = nil
                }
            }
            self.pendingDeviceTokenRetry = false
            self.deviceTokenRetryBudgetUsed = false
            return outcome.hello
        } catch let startup as GatewayStartupUnavailableConnectError {
            throw startup
        } catch {
            try self.ensureCurrentConnectAttempt(attemptID, task: task)
            try self.requireCurrentConnection(connectionGeneration)
            let shouldRetryWithDeviceToken = self.shouldRetryWithStoredDeviceToken(
                error: error,
                explicitGatewayToken: self.token.gatewayTrimmedNonEmpty,
                storedToken: selectedAuth.storedToken,
                attemptedDeviceTokenRetry: selectedAuth.authDeviceToken != nil)
            if shouldRetryWithDeviceToken {
                self.pendingDeviceTokenRetry = true
                self.deviceTokenRetryBudgetUsed = true
                self.backoffMs = min(self.backoffMs, 250)
            } else if selectedAuth.authDeviceToken != nil || selectedAuth.authSource == .deviceToken,
                      let identity,
                      self.shouldClearStoredDeviceTokenAfterRetry(error)
            {
                // The gateway rejected the stored device token itself; clear the stale local copy
                // so reconnects fall back to explicit credentials or pairing.
                DeviceAuthStore.clearToken(
                    deviceId: identity.deviceId,
                    role: role,
                    gatewayID: deviceAuthGatewayID,
                    profile: deviceIdentityProfile)
            }
            throw error
        }
    }
}

extension GatewayChannelActor {
    private func requireCurrentConnection(_ connectionGeneration: UInt64) throws {
        guard self.shouldReconnect,
              self.connectionGeneration == connectionGeneration,
              self.disconnectedConnectionGeneration != connectionGeneration
        else { throw CancellationError() }
    }

    static let tickTimeoutCloseCode = URLSessionWebSocketTask.CloseCode(rawValue: 4000) ?? .goingAway

    static func milliseconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Double {
        let components = (end - start).components
        return Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }
}

// MARK: - Authentication

extension GatewayChannelActor {
    private func applyConnectAuth(
        _ selectedAuth: SelectedConnectAuth,
        deviceId: String?,
        connectionGeneration: UInt64,
        to params: inout [String: ProtoAnyCodable])
    {
        if self.pendingDeviceTokenRetry,
           selectedAuth.authDeviceToken != nil || selectedAuth.suppressedDeviceTokenRetry
        {
            self.pendingDeviceTokenRetry = false
        }
        self.lastAuthSource = selectedAuth.authSource
        let authBinding = selectedAuth.makeAuthBinding(key: self.authBindingKey, deviceId: deviceId)
        self.lastAuthBinding = (connectionGeneration, authBinding)
        self.logger.info("gateway connect auth=\(selectedAuth.authSource.rawValue, privacy: .public)")
        if let authToken = selectedAuth.authToken {
            var auth: [String: ProtoAnyCodable] = ["token": ProtoAnyCodable(authToken)]
            if let authDeviceToken = selectedAuth.authDeviceToken {
                auth["deviceToken"] = ProtoAnyCodable(authDeviceToken)
            }
            params["auth"] = ProtoAnyCodable(auth)
        } else if let authBootstrapToken = selectedAuth.authBootstrapToken {
            params["auth"] = ProtoAnyCodable(["bootstrapToken": ProtoAnyCodable(authBootstrapToken)])
        } else if let password = selectedAuth.authPassword {
            params["auth"] = ProtoAnyCodable(["password": ProtoAnyCodable(password)])
        }
    }

    private func selectConnectAuth(
        role: String,
        includeDeviceIdentity: Bool,
        allowStoredDeviceAuth: Bool,
        deviceAuthGatewayID: String?,
        deviceIdentityProfile: GatewayDeviceIdentityProfile,
        deviceId: String?,
        requestedScopes: [String]) -> SelectedConnectAuth
    {
        let explicitToken = self.token.gatewayTrimmedNonEmpty
        let explicitBootstrapToken = self.bootstrapToken.gatewayTrimmedNonEmpty
        let explicitPassword = self.password.gatewayTrimmedNonEmpty
        let storedEntry: DeviceAuthEntry? = if includeDeviceIdentity, allowStoredDeviceAuth, let deviceId {
            DeviceAuthStore.loadToken(
                deviceId: deviceId,
                role: role,
                gatewayID: deviceAuthGatewayID,
                profile: deviceIdentityProfile)
        } else {
            nil
        }
        let storedToken = storedEntry?.token
        let storedScopes = storedEntry?.scopes ?? []
        let requestedScopesExceedStoredToken = Self.requestedScopesExceedStoredToken(
            role: role,
            requestedScopes: requestedScopes,
            storedToken: storedToken,
            storedScopes: storedScopes)
        let suppressedDeviceTokenRetry =
            includeDeviceIdentity && self.pendingDeviceTokenRetry &&
            requestedScopesExceedStoredToken && storedToken != nil && explicitToken != nil
        // Scope upgrades must be judged from the requested scopes. A stale
        // device-token retry carries the old grant and is rejected before pairing repair.
        let shouldUseDeviceRetryToken =
            includeDeviceIdentity && self.pendingDeviceTokenRetry &&
            !requestedScopesExceedStoredToken && storedToken != nil && explicitToken != nil &&
            self.isTrustedDeviceRetryEndpoint()
        let authToken =
            explicitToken ??
            // A freshly scanned setup code should force the bootstrap pairing path instead of
            // silently reusing an older stored device token.
            (includeDeviceIdentity && explicitPassword == nil && explicitBootstrapToken == nil
                ? storedToken
                : nil)
        let authBootstrapToken =
            authToken == nil && explicitPassword == nil ? explicitBootstrapToken : nil
        let authDeviceToken = shouldUseDeviceRetryToken ? storedToken : nil
        let authSource: GatewayAuthSource = if authDeviceToken != nil || (explicitToken == nil && authToken != nil) {
            .deviceToken
        } else if authToken != nil {
            .sharedToken
        } else if authBootstrapToken != nil {
            .bootstrapToken
        } else if explicitPassword != nil {
            .password
        } else {
            .none
        }
        return SelectedConnectAuth(
            authToken: authToken,
            authBootstrapToken: authBootstrapToken,
            authDeviceToken: authDeviceToken,
            authPassword: explicitPassword,
            signatureToken: authToken ?? authBootstrapToken,
            storedToken: storedToken,
            storedScopes: storedEntry?.scopes,
            authSource: authSource,
            suppressedDeviceTokenRetry: suppressedDeviceTokenRetry)
    }

    nonisolated static func _test_requestedScopesExceedStoredToken(
        role: String,
        requestedScopes: [String],
        storedToken: String?,
        storedScopes: [String]) -> Bool
    {
        self.requestedScopesExceedStoredToken(
            role: role,
            requestedScopes: requestedScopes,
            storedToken: storedToken,
            storedScopes: storedScopes)
    }

    nonisolated private static func requestedScopesExceedStoredToken(
        role: String,
        requestedScopes: [String],
        storedToken: String?,
        storedScopes: [String]) -> Bool
    {
        storedToken != nil && !storedScopes.isEmpty &&
            !self.storedDeviceTokenScopesAllow(
                role: role,
                requestedScopes: requestedScopes,
                storedScopes: storedScopes)
    }

    nonisolated private static func storedDeviceTokenScopesAllow(
        role: String,
        requestedScopes: [String],
        storedScopes: [String]) -> Bool
    {
        let requested = self.normalizedScopeList(requestedScopes)
        if requested.isEmpty {
            return true
        }
        let allowed = self.normalizedScopeList(storedScopes)
        if allowed.isEmpty {
            return false
        }
        let allowedSet = Set(allowed)
        let normalizedRole = role.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedRole != "operator" {
            let prefix = "\(normalizedRole)."
            return requested.allSatisfy { scope in
                scope.hasPrefix(prefix) && allowedSet.contains(scope)
            }
        }
        return requested.allSatisfy { scope in
            self.operatorScopeSatisfied(scope, granted: allowedSet)
        }
    }

    nonisolated private static func normalizedScopeList(_ scopes: [String]) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for scope in scopes {
            let trimmed = scope.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || seen.contains(trimmed) {
                continue
            }
            seen.insert(trimmed)
            out.append(trimmed)
        }
        return out
    }

    nonisolated private static func operatorScopeSatisfied(_ scope: String, granted: Set<String>) -> Bool {
        if !scope.hasPrefix("operator.") {
            return false
        }
        if granted.contains("operator.admin") {
            return true
        }
        if scope == "operator.read" {
            return granted.contains("operator.read") || granted.contains("operator.write")
        }
        if scope == "operator.write" {
            return granted.contains("operator.write")
        }
        return granted.contains(scope)
    }

    private func shouldPersistBootstrapHandoffTokens() -> Bool {
        guard self.lastAuthSource == .bootstrapToken else { return false }
        // Setup codes intentionally allow plaintext WebSocket bootstrap on local networks
        // for QR pairing. Persist the resulting server-bounded device token so reconnects do not
        // fall back to auth=none after the single-use bootstrap token is cleared. Public cleartext
        // routes and non-routable hosts never persist handoff tokens.
        return Self.allowsBootstrapHandoffPersistence(url: self.url)
    }

    /// Transport rule for persisting bootstrap handoff tokens: TLS, loopback, or cleartext LAN only
    /// (``GatewayTransportSecurityPolicy/evaluate(url:)`` is `.ok` or `.warnCleartextLAN`).
    nonisolated static func allowsBootstrapHandoffPersistence(url: URL) -> Bool {
        switch GatewayTransportSecurityPolicy.evaluate(url: url) {
        case .ok, .warnCleartextLAN:
            true
        case .requireTLS, .rejectNonRoutable:
            false
        }
    }

    nonisolated static func filteredBootstrapHandoffScopes(role: String, scopes: [String]) -> [String]? {
        let normalizedRole = role.trimmingCharacters(in: .whitespacesAndNewlines)
        switch normalizedRole {
        case "node":
            return []
        case "operator":
            let allowedOperatorScopes: Set = [
                "operator.admin",
                "operator.approvals",
                "operator.questions",
                "operator.read",
                "operator.talk.secrets",
                "operator.write",
            ]
            return Array(Set(scopes.filter { allowedOperatorScopes.contains($0) })).sorted()
        default:
            return nil
        }
    }

    private func resolveConnectScopes(
        role: String,
        requestedScopes: [String],
        scopesAreExplicit: Bool,
        selectedAuth: SelectedConnectAuth) -> [String]
    {
        if selectedAuth.authSource == .bootstrapToken,
           let filteredScopes = Self.filteredBootstrapHandoffScopes(role: role, scopes: requestedScopes)
        {
            return filteredScopes
        }
        if selectedAuth.authSource == .deviceToken,
           !scopesAreExplicit,
           let storedScopes = selectedAuth.storedScopes,
           !storedScopes.isEmpty
        {
            return storedScopes
        }
        return requestedScopes
    }

    @discardableResult
    private func persistBootstrapHandoffToken(
        deviceId: String,
        role: String,
        token: String,
        scopes: [String],
        deviceAuthGatewayID: String?,
        deviceIdentityProfile: GatewayDeviceIdentityProfile) -> Bool
    {
        guard let filteredScopes = Self.filteredBootstrapHandoffScopes(role: role, scopes: scopes) else {
            return false
        }
        return DeviceAuthStore.storeTokenResult(
            deviceId: deviceId,
            role: role,
            token: token,
            scopes: filteredScopes,
            gatewayID: deviceAuthGatewayID,
            profile: deviceIdentityProfile).persisted
    }

    private func persistIssuedDeviceToken(
        authSource: GatewayAuthSource,
        deviceId: String,
        role: String,
        token: String,
        scopes: [String],
        deviceAuthGatewayID: String?,
        deviceIdentityProfile: GatewayDeviceIdentityProfile) -> Bool
    {
        if authSource == .bootstrapToken {
            guard self.shouldPersistBootstrapHandoffTokens() else {
                return false
            }
            return self.persistBootstrapHandoffToken(
                deviceId: deviceId,
                role: role,
                token: token,
                scopes: scopes,
                deviceAuthGatewayID: deviceAuthGatewayID,
                deviceIdentityProfile: deviceIdentityProfile)
        }
        return DeviceAuthStore.storeTokenResult(
            deviceId: deviceId,
            role: role,
            token: token,
            scopes: scopes,
            gatewayID: deviceAuthGatewayID,
            profile: deviceIdentityProfile).persisted
    }

    private func handleConnectResponse(
        _ res: ResponseFrame,
        identity: DeviceIdentity?,
        selectedAuth: SelectedConnectAuth,
        options: GatewayConnectOptions,
        connectionGeneration: UInt64) async throws
        -> (receivedRoles: Set<String>, persistedRoles: Set<String>, hello: HelloOk)
    {
        let role = options.role
        let deviceAuthGatewayID = options.deviceAuthGatewayID
        let deviceIdentityProfile = options.deviceIdentityProfile
        if res.ok == false {
            let error = res.error
            let details = gatewayErrorDetails(error)
            let rejection = GatewayConnectAuthError(
                message: error?.message ?? "gateway connect failed",
                details: details)
            self.rateLimitRetryAfterMs = rejection.detail == .authRateLimited
                ? gatewayIntValue(details["retryAfterMs"])
                : nil
            if let error, error.isStartupUnavailable {
                throw GatewayStartupUnavailableConnectError(
                    rejection: rejection,
                    retryAfterMs: error.startupRetryAfterMs ?? GATEWAY_STARTUP_RETRY_AFTER_MS)
            }
            throw rejection
        }
        guard let payload = res.payload else {
            throw NSError(
                domain: "Gateway",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "connect failed (missing payload)"])
        }
        let ok = try GatewayHelloDecoding.decode(payload)
        self.helloPolicy = ok.gatewayPolicy
        self.negotiatedProtocol = ok._protocol
        self.lastHello = (connectionGeneration, ok)
        let auth = ok.auth
        var receivedRoles = Set<String>()
        var persistedRoles = Set<String>()
        if let deviceToken = auth["deviceToken"]?.stringValue {
            let authRole = auth["role"]?.stringValue ?? role
            receivedRoles.insert(authRole)
            let helloScopes = auth["scopes"]?.arrayValue?.compactMap(\.stringValue) ?? []
            let sameStoredToken = authRole == role && deviceToken == selectedAuth.storedToken
            // Hello scopes describe this socket. Reissuing the stored token must not narrow its reusable grant.
            let scopes = sameStoredToken ? (selectedAuth.storedScopes ?? helloScopes) : helloScopes
            if let identity, options.allowsDeviceAuthPersistence, self.persistIssuedDeviceToken(
                authSource: self.lastAuthSource,
                deviceId: identity.deviceId,
                role: authRole,
                token: deviceToken,
                scopes: scopes,
                deviceAuthGatewayID: deviceAuthGatewayID,
                deviceIdentityProfile: deviceIdentityProfile)
            {
                persistedRoles.insert(authRole)
            }
        }
        if let tokenEntries = auth["deviceTokens"]?.arrayValue {
            for entry in tokenEntries {
                guard let rawEntry = entry.dictionaryValue,
                      let deviceToken = rawEntry["deviceToken"]?.stringValue,
                      let authRole = rawEntry["role"]?.stringValue
                else {
                    continue
                }
                let scopes = rawEntry["scopes"]?.arrayValue?.compactMap(\.stringValue) ?? []
                receivedRoles.insert(authRole)
                if let identity, options.allowsDeviceAuthPersistence, self.shouldPersistBootstrapHandoffTokens(),
                   self.persistBootstrapHandoffToken(
                       deviceId: identity.deviceId,
                       role: authRole,
                       token: deviceToken,
                       scopes: scopes,
                       deviceAuthGatewayID: deviceAuthGatewayID,
                       deviceIdentityProfile: deviceIdentityProfile)
                {
                    persistedRoles.insert(authRole)
                }
            }
        }
        self.acceptedHTTPBearer = (connectionGeneration, selectedAuth.httpResourceBearer(hello: ok, role: role))
        self.lastInboundAt = ContinuousClock.now
        // Keep arbitrary push/lifecycle callbacks off the connect critical path.
        // Clients needing immediate hello state get a dedicated short admission.
        if self.connectionGeneration == connectionGeneration,
           self.disconnectedConnectionGeneration != connectionGeneration
        {
            await self.connectSnapshotAdmissionHandler?(ok, connectionGeneration)
        }
        return (receivedRoles, persistedRoles, ok)
    }

    private func deliverPushIfCurrent(
        _ push: GatewayPush,
        connectionGeneration: UInt64) async
    {
        guard self.connectionGeneration == connectionGeneration,
              self.disconnectedConnectionGeneration != connectionGeneration
        else { return }
        await self.pushHandler?(push, connectionGeneration)
    }

    /// Roles for which hello-ok issued device tokens (`received`) and those durably stored (`persisted`).
    ///
    /// Missing issuance and failed storage need different recovery guidance. Only persisted roles
    /// may authorize reconnecting with stored device credentials.
    public func currentDeviceAuthRoles() -> (received: Set<String>, persisted: Set<String>) {
        (self.receivedDeviceAuthRoles, self.persistedDeviceAuthRoles)
    }
}

// MARK: - Messages and liveness

extension GatewayChannelActor {
    private func listen(connectionGeneration: UInt64) {
        guard self.isConnected(connectionGeneration: connectionGeneration) else { return }
        self.task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case let .failure(err):
                Task {
                    await self.handleReceiveFailure(
                        err,
                        connectionGeneration: connectionGeneration)
                }
            case let .success(msg):
                Task {
                    await self.handle(msg, connectionGeneration: connectionGeneration)
                    await self.listen(connectionGeneration: connectionGeneration)
                }
            }
        }
    }

    private func handleReceiveFailure(
        _ err: Error,
        connectionGeneration: UInt64) async
    {
        guard self.connectionGeneration == connectionGeneration,
              self.disconnectedConnectionGeneration != connectionGeneration
        else { return }
        let wrapped = self.wrap(err, context: "gateway receive")
        self.logger.error("gateway ws receive failed \(wrapped.localizedDescription, privacy: .public)")
        self.gatewayStateReporter.reconnecting(
            backoffMs: Int(self.backoffMs),
            pendingRequests: self.pending.count,
            problemKind: GatewayConnectionProblemMapper.map(error: wrapped)?.kind.rawValue)
        await self.transitionToDisconnected(
            reason: "receive failed: \(wrapped.localizedDescription)",
            error: wrapped,
            connectionGeneration: connectionGeneration,
            shouldReconnect: true)
    }

    private func transitionToDisconnected(
        reason: String,
        error: Error,
        connectionGeneration: UInt64,
        shouldReconnect: Bool,
        closeCode: URLSessionWebSocketTask.CloseCode = .goingAway) async
    {
        guard self.connectionGeneration == connectionGeneration,
              self.disconnectedConnectionGeneration != connectionGeneration
        else { return }

        // Claim this socket's transition before cancellation can deliver another
        // receive failure. Only the owner notifies lifecycle cleanup or reconnects.
        self.disconnectedConnectionGeneration = connectionGeneration
        self.connected = false
        self.acceptedHTTPBearer = nil
        self.activeConnectAttemptID = nil
        if shouldReconnect {
            self.automaticReconnectRequested = true
        }
        let disconnectedTask = self.task
        self.task = nil
        disconnectedTask?.cancel(with: closeCode, reason: nil)
        // Refuse reconnect until cleanup finishes, retaining the cause so callers
        // can distinguish a retryable transport loss from an authoritative rejection.
        self.disconnectError = error
        // Lifecycle callbacks may be awaiting an RPC on this same socket. Release
        // those continuations before the callback barrier, or disconnect cycles.
        self.failPending(error)
        await self.disconnectHandler?(reason, connectionGeneration)
        self.disconnectError = nil

        guard self.automaticReconnectRequested,
              self.shouldReconnect,
              self.connectionGeneration == connectionGeneration
        else { return }
        Task { [weak self] in
            await self?.scheduleReconnect(after: connectionGeneration)
        }
    }

    private func isConnected(connectionGeneration: UInt64) -> Bool {
        self.connected &&
            self.connectionGeneration == connectionGeneration &&
            self.disconnectedConnectionGeneration != connectionGeneration
    }

    private func handle(
        _ msg: URLSessionWebSocketTask.Message,
        connectionGeneration: UInt64) async
    {
        guard self.isConnected(connectionGeneration: connectionGeneration) else { return }
        guard let data = self.decodeMessageData(msg) else { return }
        self.lastInboundAt = ContinuousClock.now
        guard let frame = try? self.decoder.decode(GatewayFrame.self, from: data) else {
            self.logger.error("gateway decode failed")
            return
        }
        switch frame {
        case let .res(res):
            self.finishRequest(id: res.id, result: .success(.res(res)))
        case let .event(evt):
            if evt.event == "connect.challenge" { return }
            if evt.event == "tick" {
                // Volatile and coalesced by the reporter (at most one update per second).
                self.gatewayStateReporter.update(OpenClawGatewayVolatileState(lastSeq: evt.seq, lastTickAt: Date()))
            }
            if let seq = evt.seq {
                if let last = lastSeq, seq > last + 1 {
                    await self.pushHandler?(
                        .seqGap(expected: last + 1, received: seq),
                        connectionGeneration)
                    // The gap callback can suspend for UI/state recovery. A socket
                    // loss during that hop must not admit the old socket's event
                    // under the replacement connection's fresh lifecycle epoch.
                    guard self.isConnected(connectionGeneration: connectionGeneration) else { return }
                }
                self.lastSeq = seq
            }
            await self.pushHandler?(.event(evt), connectionGeneration)
        default:
            break
        }
    }

    private func waitForConnectChallenge(
        task: WebSocketTaskBox,
        attemptID: UUID) async throws -> GatewayConnectChallenge
    {
        try await AsyncTimeout.withTimeout(
            seconds: self.connectChallengeTimeoutSeconds,
            onTimeout: { URLError(.timedOut) },
            operation: { [weak self] in
                guard let self else { throw CancellationError() }
                while true {
                    let msg = try await task.receive()
                    try await self.ensureCurrentConnectAttempt(attemptID, task: task)
                    guard let data = self.decodeMessageData(msg) else { continue }
                    guard let frame = try? self.decoder.decode(GatewayFrame.self, from: data) else { continue }
                    if case let .event(evt) = frame, evt.event == "connect.challenge" {
                        guard let payload = evt.payload?.dictionaryValue,
                              let challenge = GatewayConnectChallengeSupport.challenge(from: payload)
                        else {
                            throw ConnectChallengeError.invalid
                        }
                        return challenge
                    }
                }
            })
    }

    private func waitForConnectResponse(
        reqId: String,
        task: WebSocketTaskBox,
        attemptID: UUID) async throws -> ResponseFrame
    {
        while true {
            let msg = try await task.receive()
            try self.ensureCurrentConnectAttempt(attemptID, task: task)
            guard let data = self.decodeMessageData(msg) else { continue }
            guard let frame = try? self.decoder.decode(GatewayFrame.self, from: data) else {
                throw NSError(
                    domain: "Gateway",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "connect failed (invalid response)"])
            }
            if case let .res(res) = frame, res.id == reqId {
                return res
            }
        }
    }

    private func isCurrentConnectAttempt(_ attemptID: UUID, task candidate: WebSocketTaskBox) -> Bool {
        guard self.activeConnectAttemptID == attemptID, let task = self.task else { return false }
        return task.task === candidate.task
    }

    private func ensureCurrentConnectAttempt(_ attemptID: UUID, task candidate: WebSocketTaskBox) throws {
        // A timed-out handshake can finish after a retry installs another socket.
        // Every post-await step must still own its logical attempt and physical socket.
        try Task.checkCancellation()
        guard self.isCurrentConnectAttempt(attemptID, task: candidate) else { throw CancellationError() }
    }

    nonisolated private func decodeMessageData(_ msg: URLSessionWebSocketTask.Message) -> Data? {
        switch msg {
        case let .data(data): data
        case let .string(text): text.data(using: .utf8)
        @unknown default: nil
        }
    }

    private func startTickWatchdog(connectionGeneration: UInt64) {
        self.tickTask?.cancel()
        self.tickTask = Task { [weak self] in
            guard let self else { return }
            await self.watchTicks(connectionGeneration: connectionGeneration)
        }
    }

    private func watchTicks(connectionGeneration: UInt64) async {
        let tolerance = self.helloPolicy.tickIntervalMs * 2
        while self.isConnected(connectionGeneration: connectionGeneration) {
            guard await self.sleepUnlessCancelled(nanoseconds: UInt64(tolerance * 1_000_000)) else { return }
            guard self.isConnected(connectionGeneration: connectionGeneration) else { return }
            if let last = self.lastInboundAt {
                let delta = Self.milliseconds(from: last, to: ContinuousClock.now)
                if delta > tolerance {
                    self.logger.error("gateway tick missed; reconnecting")
                    self.gatewayStateReporter.reconnecting(
                        backoffMs: Int(self.backoffMs),
                        pendingRequests: self.pending.count)
                    let error = NSError(
                        domain: "Gateway",
                        code: 4,
                        userInfo: [NSLocalizedDescriptionKey: "gateway tick missed; reconnecting"])
                    await self.transitionToDisconnected(
                        reason: error.localizedDescription,
                        error: error,
                        connectionGeneration: connectionGeneration,
                        shouldReconnect: true,
                        closeCode: Self.tickTimeoutCloseCode)
                    return
                }
            }
        }
    }

    private func scheduleReconnect(after connectionGeneration: UInt64) async {
        guard self.shouldReconnect else { return }
        guard !self.reconnectPausedForAuthFailure, !self.reconnectPausedForTLSFailure else { return }
        guard self.automaticReconnectRequested else { return }
        guard self.connectionGeneration == connectionGeneration,
              self.disconnectedConnectionGeneration == connectionGeneration
        else { return }
        let delay = self.backoffMs / 1000
        self.backoffMs = min(self.backoffMs * 2, 30000)
        guard await self.sleepUnlessCancelled(nanoseconds: UInt64(delay * 1_000_000_000)) else { return }
        guard self.shouldReconnect else { return }
        guard !self.reconnectPausedForAuthFailure, !self.reconnectPausedForTLSFailure else { return }
        guard self.automaticReconnectRequested else { return }
        guard self.connectionGeneration == connectionGeneration,
              self.disconnectedConnectionGeneration == connectionGeneration
        else { return }
        do {
            try await self.connect()
        } catch {
            if self.shouldPauseReconnectAfterAuthFailure(error) {
                self.pauseReconnectAfterAuthFailure(error, context: "gateway reconnect")
                return
            }
            let wrapped = self.wrap(error, context: "gateway reconnect")
            self.logger.error("gateway reconnect failed \(wrapped.localizedDescription, privacy: .public)")
            // connect() transfers retry ownership to the generation that failed.
            // This task must not start a second backoff loop for the same socket.
        }
    }

    private func shouldRetryWithStoredDeviceToken(
        error: Error,
        explicitGatewayToken: String?,
        storedToken: String?,
        attemptedDeviceTokenRetry: Bool) -> Bool
    {
        if self.deviceTokenRetryBudgetUsed {
            return false
        }
        if attemptedDeviceTokenRetry {
            return false
        }
        guard explicitGatewayToken != nil, storedToken != nil else {
            return false
        }
        guard self.isTrustedDeviceRetryEndpoint() else {
            return false
        }
        guard let authError = error as? GatewayConnectAuthError else {
            return false
        }
        return authError.canRetryWithDeviceToken ||
            authError.detail == .authTokenMismatch
    }

    private func shouldPauseReconnectAfterAuthFailure(_ error: Error) -> Bool {
        guard let authError = error as? GatewayConnectAuthError else {
            return false
        }
        if authError.pauseReconnectOverride == true || authError.isNonRecoverable {
            return true
        }
        if authError.detail == .authTokenMismatch,
           self.deviceTokenRetryBudgetUsed, !self.pendingDeviceTokenRetry
        {
            return true
        }
        return false
    }

    private func shouldClearStoredDeviceTokenAfterRetry(_ error: Error) -> Bool {
        guard let authError = error as? GatewayConnectAuthError else {
            return false
        }
        return authError.detail == .authDeviceTokenMismatch
    }

    private func isTrustedDeviceRetryEndpoint() -> Bool {
        guard let host = self.url.host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !host.isEmpty
        else {
            return false
        }
        if Self.isTrustedDeviceRetryLoopbackHost(host) {
            return true
        }
        if self.url.scheme?.lowercased() == "wss",
           let trust = self.session as? GatewayDeviceTokenRetryTrustProviding
        {
            return trust.allowsDeviceTokenRetryAuth
        }
        return false
    }

    /// Strict loopback check: wildcard binds (`0.0.0.0`, `::`) and hostname prefixes such as
    /// `127.example.com` never qualify.
    nonisolated static func isTrustedDeviceRetryLoopbackHost(_ host: String) -> Bool {
        var normalized = host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if normalized.hasSuffix(".") {
            normalized.removeLast()
        }
        if let zoneIndex = normalized.firstIndex(of: "%") {
            normalized = String(normalized[..<zoneIndex])
        }
        if normalized.isEmpty || normalized == "0.0.0.0" || normalized == "::" {
            return false
        }
        return LoopbackHost.isLoopbackHost(normalized)
    }

    nonisolated private func sleepUnlessCancelled(nanoseconds: UInt64) async -> Bool {
        do {
            try await Task.sleep(nanoseconds: nanoseconds)
        } catch {
            return false
        }
        return !Task.isCancelled
    }
}

// MARK: - Requests

extension GatewayChannelActor {
    /// Sends a request frame and waits for the matching response payload.
    ///
    /// Connects first when needed. A retryable startup `UNAVAILABLE` (gateway sidecars still
    /// starting) is retried while the timeout budget remains.
    /// - Parameters:
    ///   - method: Gateway method.
    ///   - params: Request params.
    ///   - timeoutMs: Client deadline; `nil` uses 15 s and `0` leaves the deadline to the gateway.
    /// - Returns: The encoded response payload (empty when the gateway returns none).
    public func request(
        method: String,
        params: [String: AnyCodable]?,
        timeoutMs: Double? = nil) async throws -> Data
    {
        try await self.performRequest(
            method: method,
            params: params,
            timeoutMs: timeoutMs,
            expectedProfileID: nil,
            boundGeneration: nil)
    }

    /// Sends a request bound to a gateway user profile (`expectedProfileId`).
    ///
    /// Requires the gateway to advertise `profile-binding-v1`; otherwise throws
    /// ``GatewayRequestError/profileBindingUnsupported(method:)`` without sending. The id is the
    /// opaque 1-128 character profile id from `users.self`, compared exactly. A rejected request
    /// surfaces ``GatewayResponseError/expectedProfileMismatch``: keep the original idempotency
    /// key and reconcile earlier acknowledgements before retrying.
    public func request(
        method: String,
        params: [String: AnyCodable]?,
        timeoutMs: Double? = nil,
        expectedProfileID: String) async throws -> Data
    {
        try await self.performRequest(
            method: method,
            params: params,
            timeoutMs: timeoutMs,
            expectedProfileID: expectedProfileID,
            boundGeneration: nil)
    }

    /// Sends a request only on an already-connected physical socket. Unlike
    /// the unbound request above, a stale generation never reconnects.
    /// - Throws: `CancellationError` when `expectedGeneration` is no longer the live socket.
    public func request(
        method: String,
        params: [String: AnyCodable]?,
        timeoutMs: Double? = nil,
        ifCurrentConnectionGeneration expectedGeneration: UInt64) async throws -> Data
    {
        try await self.performRequest(
            method: method,
            params: params,
            timeoutMs: timeoutMs,
            expectedProfileID: nil,
            boundGeneration: expectedGeneration)
    }

    /// The generation is usable as a lease only while its socket is live.
    public func currentConnectionGeneration() -> UInt64? {
        let generation = self.connectionGeneration
        guard self.isConnected(connectionGeneration: generation),
              self.task?.state == .running
        else { return nil }
        return generation
    }

    private func requestTarget(boundGeneration: UInt64?) async throws -> (task: WebSocketTaskBox, generation: UInt64) {
        if let boundGeneration {
            guard self.isConnected(connectionGeneration: boundGeneration),
                  let task = self.task,
                  task.state == .running
            else { throw CancellationError() }
            return (task, boundGeneration)
        }
        try Task.checkCancellation()
        try await self.connectOrThrow(context: "gateway connect")
        try Task.checkCancellation()
        let connectionGeneration = self.connectionGeneration
        guard self.isConnected(connectionGeneration: connectionGeneration),
              let task = self.task,
              task.state == .running
        else {
            throw NSError(
                domain: "Gateway",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "gateway socket unavailable"])
        }
        return (task, connectionGeneration)
    }

    private func performRequest(
        method: String,
        params: [String: AnyCodable]?,
        timeoutMs: Double?,
        expectedProfileID: String?,
        boundGeneration: UInt64?) async throws -> Data
    {
        let budgetMs = Self.resolveRequestTimeoutMs(timeoutMs, defaultMs: self.defaultRequestTimeoutMs)
        let clock = ContinuousClock()
        let start = clock.now
        var startupRetries = 0
        while true {
            let target = try await self.requestTarget(boundGeneration: boundGeneration)
            let remainingMs = budgetMs.map { max(1, $0 - Self.milliseconds(from: start, to: clock.now)) }
            do {
                return try await self.request(
                    method: method,
                    params: params,
                    timeoutMs: remainingMs ?? 0,
                    expectedProfileID: expectedProfileID,
                    task: target.task,
                    connectionGeneration: target.generation)
            } catch let error as GatewayResponseError {
                guard let delayMs = error.startupRetryAfterMs,
                      startupRetries < Self.maxStartupUnavailableRetries
                else { throw error }
                if let budgetMs, Self.milliseconds(from: start, to: clock.now) + Double(delayMs) >= budgetMs {
                    throw error
                }
                startupRetries += 1
                self.logger.info("gateway starting; retrying \(method, privacy: .public) in \(delayMs, privacy: .public)ms")
                try await clock.sleep(for: .milliseconds(delayMs))
            }
        }
    }

    private func request(
        method: String,
        params: [String: AnyCodable]?,
        timeoutMs: Double?,
        expectedProfileID: String?,
        task: WebSocketTaskBox,
        connectionGeneration: UInt64) async throws -> Data
    {
        if let expectedProfileID {
            let length = expectedProfileID.utf16.count
            guard length >= 1, length <= 128 else { throw GatewayRequestError.invalidExpectedProfileID }
            guard self.lastHello?.generation == connectionGeneration,
                  self.lastHello?.hello.supportsServerCapability(.profileBinding) == true
            else { throw GatewayRequestError.profileBindingUnsupported(method: method) }
        }
        // Zero leaves terminal-operation deadlines to the Gateway owner.
        let effectiveTimeout = Self.resolveRequestTimeoutMs(timeoutMs, defaultMs: self.defaultRequestTimeoutMs)
        let payload = try self.encodeRequest(
            method: method,
            params: params,
            expectedProfileID: expectedProfileID,
            kind: "request")
        let cancellationGate = GatewayRequestCancellationGate()
        let response: GatewayFrame
        do {
            response = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<GatewayFrame, Error>) in
                    guard !cancellationGate.isCancelled else {
                        cont.resume(throwing: CancellationError())
                        return
                    }
                    var request = PendingRequest(continuation: cont)
                    if let effectiveTimeout {
                        request.timeoutTask = Task { [weak self] in
                            guard let self else { return }
                            guard await self.sleepUnlessCancelled(
                                nanoseconds: UInt64(effectiveTimeout * 1_000_000))
                            else { return }
                            let error = NSError(
                                domain: "Gateway",
                                code: 5,
                                userInfo: [NSLocalizedDescriptionKey:
                                    "gateway request timed out after \(Int(effectiveTimeout))ms"])
                            await self.finishRequest(id: payload.id, result: .failure(error))
                        }
                    }
                    self.pending[payload.id] = request
                    let transportLifetime = request.transportLifetime
                    Task {
                        guard !cancellationGate.isCancelled else {
                            self.finishRequest(id: payload.id, result: .failure(CancellationError()))
                            return
                        }
                        do {
                            try await task.sendRequest(.data(payload.data), lifetime: transportLifetime)
                        } catch is CancellationError {
                            // Cancellation owns only this request. Treating it as socket loss
                            // starts disconnect cleanup and can reject an immediate safe retry.
                            self.finishRequest(id: payload.id, result: .failure(CancellationError()))
                        } catch {
                            let wrapped = self.wrap(error, context: "gateway send \(method)")
                            await self.transitionToDisconnected(
                                reason: "send failed: \(wrapped.localizedDescription)",
                                error: wrapped,
                                connectionGeneration: connectionGeneration,
                                shouldReconnect: true)
                        }
                    }
                }
            } onCancel: {
                cancellationGate.cancel()
                Task { await self.finishRequest(id: payload.id, result: .failure(CancellationError())) }
            }
        } catch {
            #if DEBUG
            if let testRequestResumedHandler {
                await testRequestResumedHandler()
            }
            #endif
            try Task.checkCancellation()
            throw error
        }
        #if DEBUG
        if let testRequestResumedHandler {
            await testRequestResumedHandler()
        }
        #endif
        try Task.checkCancellation()
        guard case let .res(res) = response else {
            throw NSError(domain: "Gateway", code: 2, userInfo: [NSLocalizedDescriptionKey: "unexpected frame"])
        }
        if res.ok == false {
            let code = res.error?.code
            let msg = res.error?.message
            let details = gatewayErrorDetails(res.error)
            throw GatewayResponseError(method: method, code: code, message: msg, details: details)
        }
        if let payload = res.payload {
            // Encode back to JSON with Swift's encoder to preserve types and avoid ObjC bridging exceptions.
            return try self.encoder.encode(payload)
        }
        return Data() // Should not happen, but tolerate empty payloads.
    }

    /// Sends a fire-and-forget command frame over the gateway socket, connecting first when needed.
    public func send(method: String, params: [String: AnyCodable]?) async throws {
        try Task.checkCancellation()
        try await self.connectOrThrow(context: "gateway connect")
        try Task.checkCancellation()
        try await self.send(
            method: method,
            params: params,
            connectionGeneration: self.connectionGeneration)
    }

    /// Sends only on the socket generation that decoded the owning work. Unlike
    /// the unbound send above, this never reconnects: a stale invoke result must
    /// be dropped instead of crossing onto a replacement socket.
    /// - Throws: `CancellationError` when `expectedGeneration` is no longer the live socket.
    public func send(
        method: String,
        params: [String: AnyCodable]?,
        ifCurrentConnectionGeneration expectedGeneration: UInt64) async throws
    {
        guard self.isConnected(connectionGeneration: expectedGeneration) else {
            throw CancellationError()
        }
        try await self.send(
            method: method,
            params: params,
            connectionGeneration: expectedGeneration)
    }

    private func send(
        method: String,
        params: [String: AnyCodable]?,
        connectionGeneration: UInt64) async throws
    {
        try Task.checkCancellation()
        let payload = try self.encodeRequest(method: method, params: params, expectedProfileID: nil, kind: "send")
        guard let task = self.task else {
            throw NSError(
                domain: "Gateway",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "gateway socket unavailable"])
        }
        do {
            try Task.checkCancellation()
            try await task.send(.data(payload.data))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let wrapped = self.wrap(error, context: "gateway send \(method)")
            await self.transitionToDisconnected(
                reason: "send failed: \(wrapped.localizedDescription)",
                error: wrapped,
                connectionGeneration: connectionGeneration,
                shouldReconnect: true)
            throw wrapped
        }
    }

    /// Wrap low-level URLSession/WebSocket errors with context so UI can surface them.
    private func wrap(_ error: Error, context: String) -> Error {
        if error is CancellationError ||
            error is GatewayConnectAuthError ||
            error is GatewayResponseError ||
            error is GatewayDecodingError ||
            error is GatewayRequestError ||
            error is GatewayTLSValidationError
        {
            return error
        }
        if let urlError = error as? URLError {
            if let failure = (self.session as? GatewayTLSFailureProviding)?.consumeLastTLSFailure() {
                return GatewayTLSValidationError(failure: failure, context: context)
            }
            if let failure = self.synthesizedTLSFailure(for: urlError) {
                return GatewayTLSValidationError(failure: failure, context: context)
            }
            let desc = urlError.localizedDescription.isEmpty ? "cancelled" : urlError.localizedDescription
            return NSError(
                domain: URLError.errorDomain,
                code: urlError.errorCode,
                userInfo: [NSLocalizedDescriptionKey: "\(context): \(desc)"])
        }
        let ns = error as NSError
        let desc = ns.localizedDescription.isEmpty ? "unknown" : ns.localizedDescription
        return NSError(domain: ns.domain, code: ns.code, userInfo: [NSLocalizedDescriptionKey: "\(context): \(desc)"])
    }

    /// Typed evidence for a certificate rejection reported by a plain `URLSession` (no pinning
    /// session to supply fingerprints), classified with ``GatewayTLSFailureClassification``.
    /// Handshake failures without a certificate decision stay transport errors.
    private func synthesizedTLSFailure(for urlError: URLError) -> GatewayTLSValidationFailure? {
        let reason: GatewayTLSTrustFailureReason
        switch GatewayTLSFailureClassification(error: urlError) {
        case .untrustedChain?: reason = .untrustedChain
        case .hostnameMismatch?: reason = .hostnameMismatch
        case .expired?: reason = .expired
        case .pinMismatch?, .handshakeFailed?, nil: return nil
        }
        return GatewayTLSValidationFailure(
            kind: .untrustedCertificate,
            host: self.url.host ?? "",
            storeKey: nil,
            expectedFingerprint: nil,
            observedFingerprint: nil,
            systemTrustOk: false,
            port: self.url.port,
            trustFailureReason: reason)
    }

    private func connectOrThrow(context: String) async throws {
        do {
            try await self.connect()
        } catch {
            throw self.wrap(error, context: context)
        }
    }

    private func encodeRequest(
        method: String,
        params: [String: AnyCodable]?,
        expectedProfileID: String?,
        kind: String) throws -> (id: String, data: Data)
    {
        let id = UUID().uuidString
        // Encode request using the generated models to avoid JSONSerialization/ObjC bridging pitfalls.
        let paramsObject: ProtoAnyCodable? = params.map { ProtoAnyCodable($0) }
        let frame = RequestFrame(
            type: "req",
            id: id,
            method: method,
            params: paramsObject,
            expectedprofileid: expectedProfileID)
        let data: Data
        do {
            data = try self.encoder.encode(frame)
        } catch {
            let failure = error.localizedDescription
            self.logger.error(
                "gateway \(kind) encode failed \(method, privacy: .public) error=\(failure, privacy: .public)")
            throw error
        }
        // Honor the advertised frame ceiling locally. Values below 1 KiB cannot be a real
        // gateway limit (a connect frame alone is larger), so they are treated as unset.
        let maximumBytes = self.helloPolicy.maxPayloadBytes
        if maximumBytes >= 1024, data.count > maximumBytes {
            throw GatewayRequestError.payloadTooLarge(method: method, bytes: data.count, maximumBytes: maximumBytes)
        }
        return (id: id, data: data)
    }

    private func failPending(_ error: Error) {
        for id in Array(self.pending.keys) {
            self.finishRequest(id: id, result: .failure(error))
        }
    }

    private func finishRequest(id: String, result: Result<GatewayFrame, Error>) {
        guard let request = self.pending.removeValue(forKey: id) else { return }
        // A deadline belongs to its pending request, including after caller cancellation or disconnect.
        request.timeoutTask?.cancel()
        request.transportLifetime.finish()
        request.continuation.resume(with: result)
    }

    private func cancelConnectWaiter(id: UUID) {
        guard let waiter = self.connectWaiters.removeValue(forKey: id) else { return }
        waiter.resume(throwing: CancellationError())
    }
}

// Intentionally no `GatewayChannel` wrapper: the app should use the single shared `GatewayConnection`.
