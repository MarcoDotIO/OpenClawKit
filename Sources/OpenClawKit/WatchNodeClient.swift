import Foundation

/// Latest network path characteristics observed by a direct Watch node transport.
public struct OpenClawWatchNodeNetworkMetrics: Sendable, Equatable {
    /// Whether the last request used cellular.
    public let isCellular: Bool
    /// Whether the last request used an expensive interface.
    public let isExpensive: Bool
    /// Whether the last request used a constrained (Low Data Mode) interface.
    public let isConstrained: Bool

    /// Creates metrics.
    public init(isCellular: Bool, isExpensive: Bool, isConstrained: Bool) {
        self.isCellular = isCellular
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
    }
}

/// HTTP transport used by ``OpenClawWatchNodeClient`` (injectable for tests).
public protocol OpenClawWatchNodeHTTPTransport: Sendable {
    /// Sends one request and returns the body and HTTP response.
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// `URLSession` transport: ephemeral, waits for connectivity, refuses redirects, `https` only.
///
/// Certificates are evaluated by the system trust store; there is no pinning or self-signed support.
public final class OpenClawWatchNodeURLSessionTransport: OpenClawWatchNodeHTTPTransport, @unchecked Sendable {
    private let session: URLSession
    private let delegate: MetricsDelegate

    /// Creates a transport; nil `configuration` uses an ephemeral configuration that waits for
    /// connectivity with 30 s request and 35 s resource timeouts.
    public init(configuration: URLSessionConfiguration? = nil) {
        let resolved = configuration ?? {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.waitsForConnectivity = true
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 35
            return configuration
        }()
        let delegate = MetricsDelegate()
        self.delegate = delegate
        self.session = URLSession(configuration: resolved, delegate: delegate, delegateQueue: nil)
    }

    deinit {
        self.session.finishTasksAndInvalidate()
    }

    /// Sends a request; non-`https` URLs are refused before any network access.
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard request.url?.scheme?.lowercased() == "https" else {
            throw OpenClawWatchNodeError.insecureEndpoint
        }
        let (data, response) = try await self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenClawWatchNodeError.invalidResponse("not an HTTP response")
        }
        return (data, http)
    }

    /// Metrics of the most recently finished request.
    public func latestNetworkMetrics() -> OpenClawWatchNodeNetworkMetrics? {
        self.delegate.snapshot()
    }

    private final class MetricsDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var latest: OpenClawWatchNodeNetworkMetrics?

        func snapshot() -> OpenClawWatchNodeNetworkMetrics? {
            self.lock.withLock { self.latest }
        }

        func urlSession(_: URLSession, task _: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
            guard let transaction = metrics.transactionMetrics.last else { return }
            let snapshot = OpenClawWatchNodeNetworkMetrics(
                isCellular: transaction.isCellular,
                isExpensive: transaction.isExpensive,
                isConstrained: transaction.isConstrained)
            self.lock.withLock { self.latest = snapshot }
        }

        func urlSession(
            _: URLSession,
            task _: URLSessionTask,
            willPerformHTTPRedirection _: HTTPURLResponse,
            newRequest _: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void)
        {
            // A redirect could move the bearer session token to another origin.
            completionHandler(nil)
        }
    }
}

/// Standalone Talk access issued by a voice setup (see ``OpenClawWatchTalkSupport``).
public struct OpenClawWatchNodeVoiceAccess: Sendable, Equatable {
    /// Credential owner id of the direct Watch configuration.
    public let gatewayID: String
    /// `wss://` endpoints for the operator connection, in connection order.
    public let webSocketURLs: [URL]
    /// Stored operator device token (scopes exactly ``OpenClawWatchNodeConnectResponse/voiceScopes``).
    public let operatorToken: DeviceAuthEntry
}

/// Direct Apple Watch node client over signed HTTPS long-poll (`/api/nodes/watch/*`).
///
/// Lifecycle:
/// 1. The iPhone sends a ``OpenClawWatchNodeSetupMessage`` over WatchConnectivity; pass it to
///    ``install(_:)``. The setup must name a trusted `wss://` endpoint; the client polls the matching
///    `https://` origin.
/// 2. Call ``start()`` when the app becomes active and ``stop()`` when it leaves the foreground: the
///    client polls only while the app is active and reconnects on the next ``start()``.
/// 3. The first connect presents the one-time bootstrap token, stores the issued node device token in
///    ``DeviceAuthStore`` (scoped to ``OpenClawWatchNodeConfiguration/gatewayID``), and deletes the bootstrap
///    token from the stored configuration. Later connects present the device token.
/// 4. When the Gateway invalidates the session (for example after the device is revoked), polls fail with
///    HTTP 401 and the client reconnects; a revoked device token keeps failing until a new setup arrives.
///
/// The declared surface is fixed: `device.info`, `device.status`, `system.notify`, and the
/// `notifications` permission. The identity is ``DeviceIdentityStore``'s persisted identity for the
/// configured profile.
public actor OpenClawWatchNodeClient {
    /// Connection state.
    public enum State: Sendable, Equatable {
        /// No configuration is installed.
        case notConfigured
        /// Configured but not running.
        case idle
        /// Connecting to an endpoint.
        case connecting(endpoint: String)
        /// Connected and polling.
        case connected(endpoint: String, nodeId: String?)
        /// Every endpoint failed; retrying after the retry delay.
        case waitingToRetry(message: String)
    }

    private struct ActiveSession: Equatable {
        let baseURL: URL
        let token: String
    }

    private let store: any OpenClawWatchNodeConfigurationStoring
    private let handler: any OpenClawWatchNodeCommandHandling
    private let transport: any OpenClawWatchNodeHTTPTransport
    private let profile: GatewayDeviceIdentityProfile
    private let clientInfo: @Sendable () async -> OpenClawWatchNodeClientInfo
    private let retryDelay: Duration
    private let now: @Sendable () -> Int64
    private let stateContinuation: AsyncStream<State>.Continuation

    private var configuration: OpenClawWatchNodeConfiguration?
    private var generation = 0
    private var activeSession: ActiveSession?
    private var inFlight: [UUID: Task<(Data, HTTPURLResponse), any Error>] = [:]
    private var runTask: Task<Void, Never>?
    private var runToken: UUID?
    private var isRunning = false

    /// Current state.
    public private(set) var state: State
    /// State changes, newest last (buffers the 16 most recent).
    nonisolated public let states: AsyncStream<State>

    /// Creates a client and loads any installed configuration from `store`.
    ///
    /// - Parameters:
    ///   - handler: Command handler (on watchOS, ``OpenClawWatchNodeCommandRouter/watchDefault(transport:notifier:isConnected:)``).
    ///   - store: Configuration persistence (Keychain by default).
    ///   - transport: HTTP transport (``OpenClawWatchNodeURLSessionTransport`` by default).
    ///   - profile: Device identity profile that owns the node identity and tokens.
    ///   - clientInfo: Connect metadata provider (``OpenClawWatchNodeClientInfo/current(bundle:)`` by default).
    ///   - retryDelay: Delay after every endpoint failed.
    ///   - now: Clock in milliseconds since the Unix epoch.
    public init(
        handler: any OpenClawWatchNodeCommandHandling,
        store: any OpenClawWatchNodeConfigurationStoring = OpenClawWatchNodeKeychainConfigurationStore(),
        transport: any OpenClawWatchNodeHTTPTransport = OpenClawWatchNodeURLSessionTransport(),
        profile: GatewayDeviceIdentityProfile = .primary,
        clientInfo: @escaping @Sendable () async -> OpenClawWatchNodeClientInfo = { .current() },
        retryDelay: Duration = .seconds(3),
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) })
    {
        self.handler = handler
        self.store = store
        self.transport = transport
        self.profile = profile
        self.clientInfo = clientInfo
        self.retryDelay = retryDelay
        self.now = now
        let configuration = store.loadConfiguration()
        if let setupSentAtMs = configuration?.setupSentAtMs, setupSentAtMs > store.lastAcceptedSetupSentAtMs() {
            store.saveLastAcceptedSetupSentAtMs(setupSentAtMs)
        }
        self.configuration = configuration
        let initial: State = configuration == nil ? .notConfigured : .idle
        self.state = initial
        let (stream, continuation) = AsyncStream<State>.makeStream(bufferingPolicy: .bufferingNewest(16))
        self.states = stream
        self.stateContinuation = continuation
        continuation.yield(initial)
    }

    deinit {
        self.runTask?.cancel()
        self.stateContinuation.finish()
    }

    /// Installed configuration, if any.
    public var currentConfiguration: OpenClawWatchNodeConfiguration? {
        self.configuration
    }

    /// Whether a session is connected.
    public var isConnected: Bool {
        if case .connected = self.state { return self.activeSession != nil }
        return false
    }

    /// Installs a setup from the iPhone and restarts a running connection with it.
    ///
    /// A new setup can narrow an old grant, so the operator (voice) token for the Gateway is cleared until
    /// the new bootstrap handoff completes; switching Gateways clears the previous Gateway's tokens.
    ///
    /// - Throws: ``OpenClawWatchNodeError/expiredSetup`` outside the setup window,
    ///   ``OpenClawWatchNodeError/staleSetup`` for a replayed or older setup,
    ///   ``OpenClawWatchNodeError/insecureEndpoint`` without a trusted `https` endpoint, and
    ///   ``OpenClawWatchNodeError/configurationStorageFailed`` when the Keychain write fails.
    @discardableResult
    public func install(_ setup: OpenClawWatchNodeSetupMessage) async throws -> OpenClawWatchNodeConfiguration {
        let configuration = try self.validatedConfiguration(for: setup)
        // Retire the previous grants before publishing the new setup, so a handoff for the new setup
        // can never race this cleanup.
        if let identity = try? await DeviceIdentityStore.loadOrCreatePersistedInBackground(profile: self.profile) {
            if let previous = self.configuration, !previous.gatewayID.utf8.elementsEqual(configuration.gatewayID.utf8) {
                await self.clearCredentials(deviceId: identity.deviceId, gatewayID: previous.gatewayID)
            }
            await DeviceAuthStore.clearTokenInBackground(
                deviceId: identity.deviceId,
                role: "operator",
                gatewayID: configuration.gatewayID,
                profile: self.profile)
        }
        // Another setup may have been installed while the cleanup ran.
        _ = try self.validatedConfiguration(for: setup)
        guard self.store.saveConfiguration(configuration) else {
            throw OpenClawWatchNodeError.configurationStorageFailed
        }
        self.store.saveLastAcceptedSetupSentAtMs(setup.sentAtMs)
        self.retireCurrentConnection()
        self.configuration = configuration
        if !self.isRunning { self.setState(.idle) }
        return configuration
    }

    private func validatedConfiguration(
        for setup: OpenClawWatchNodeSetupMessage) throws -> OpenClawWatchNodeConfiguration
    {
        guard setup.type == .directNodeSetup, setup.isFresh(nowMs: self.now()) else {
            throw OpenClawWatchNodeError.expiredSetup
        }
        let newestInstalled = self.configuration?.setupSentAtMs ?? 0
        guard setup.sentAtMs > max(self.store.lastAcceptedSetupSentAtMs(), newestInstalled) else {
            throw OpenClawWatchNodeError.staleSetup
        }
        guard let configuration = OpenClawWatchNodeConfiguration(setup: setup) else {
            throw OpenClawWatchNodeError.insecureEndpoint
        }
        return configuration
    }

    /// Forgets the configuration and its tokens, and stops polling.
    public func forget() async {
        self.stopRunning()
        if let configuration,
           let identity = try? await DeviceIdentityStore.loadOrCreatePersistedInBackground(profile: self.profile)
        {
            await self.clearCredentials(deviceId: identity.deviceId, gatewayID: configuration.gatewayID)
        }
        self.store.deleteConfiguration()
        self.configuration = nil
        self.setState(.notConfigured)
    }

    /// Starts polling in a background task (call when the app becomes active).
    public func start() {
        guard self.runTask == nil else { return }
        let token = UUID()
        self.runToken = token
        self.runTask = Task { [weak self] in
            await self?.run()
            await self?.runEnded(token)
        }
    }

    /// Stops polling and disconnects the session (call when the app leaves the foreground).
    public func stop() {
        self.stopRunning()
        self.setState(self.configuration == nil ? .notConfigured : .idle)
    }

    /// Connects and polls until the calling task is cancelled or the configuration is forgotten.
    ///
    /// ``start()`` runs this in its own task; hosts that manage their own tasks may call it directly.
    /// Only one loop runs at a time; a second concurrent call returns immediately.
    public func run() async {
        guard !self.isRunning else { return }
        self.isRunning = true
        defer { self.isRunning = false }
        while !Task.isCancelled {
            guard let configuration = self.configuration else {
                self.setState(.notConfigured)
                return
            }
            let generation = self.generation
            var lastError: (any Error)?
            for baseURL in configuration.httpsBaseURLs {
                // Re-read per endpoint: a completed bootstrap handoff removes the one-time token.
                guard self.isCurrent(generation), let current = self.configuration else { break }
                do {
                    try await self.connectAndPoll(configuration: current, baseURL: baseURL, generation: generation)
                    break
                } catch {
                    if Task.isCancelled || !self.isCurrent(generation) { break }
                    lastError = error
                }
            }
            if Task.isCancelled { return }
            // A new setup or a forget retired this attempt: restart with the current configuration.
            guard self.isCurrent(generation) else { continue }
            self.setState(.waitingToRetry(
                message: lastError?.localizedDescription ?? String(localized: "No usable Gateway endpoint")))
            do {
                try await Task.sleep(for: self.retryDelay)
            } catch {
                return
            }
        }
    }

    /// Standalone Talk access, when a voice setup completed for the installed configuration.
    public func voiceAccess() async -> OpenClawWatchNodeVoiceAccess? {
        guard let configuration, !configuration.hasBootstrapCredential,
              let identity = try? await DeviceIdentityStore.loadOrCreatePersistedInBackground(profile: self.profile),
              let credential = await DeviceAuthStore.loadTokenInBackground(
                  deviceId: identity.deviceId,
                  role: "operator",
                  gatewayID: configuration.gatewayID,
                  profile: self.profile),
              credential.scopes == OpenClawWatchNodeConnectResponse.voiceScopes
        else { return nil }
        return OpenClawWatchNodeVoiceAccess(
            gatewayID: configuration.gatewayID,
            webSocketURLs: configuration.voiceWebSocketURLs,
            operatorToken: credential)
    }

    // MARK: - Connection

    private func connectAndPoll(
        configuration: OpenClawWatchNodeConfiguration,
        baseURL: URL,
        generation: Int) async throws
    {
        try self.requireCurrent(generation)
        self.setState(.connecting(endpoint: baseURL.absoluteString))
        let identity: DeviceIdentity
        do {
            identity = try await DeviceIdentityStore.loadOrCreatePersistedInBackground(profile: self.profile)
        } catch {
            throw OpenClawWatchNodeError.identityUnavailable(error.localizedDescription)
        }
        let storedToken = await DeviceAuthStore.loadTokenInBackground(
            deviceId: identity.deviceId,
            role: OpenClawWatchNodeHTTP.role,
            gatewayID: configuration.gatewayID,
            profile: self.profile)?.token
        let bootstrapToken = configuration.link.bootstrapToken
        let response: OpenClawWatchNodeConnectResponse
        let usedBootstrap: Bool
        if let bootstrapToken {
            do {
                response = try await self.establishSession(
                    identity: identity, baseURL: baseURL, credential: .bootstrap(bootstrapToken))
                usedBootstrap = true
            } catch let error as OpenClawWatchNodeError where error.isUnauthorized {
                guard let storedToken else { throw error }
                response = try await self.establishSession(
                    identity: identity, baseURL: baseURL, credential: .device(storedToken))
                usedBootstrap = false
            }
        } else if let storedToken {
            response = try await self.establishSession(
                identity: identity, baseURL: baseURL, credential: .device(storedToken))
            usedBootstrap = false
        } else {
            throw OpenClawWatchNodeError.missingCredential
        }
        let session = ActiveSession(baseURL: baseURL, token: response.sessionToken)
        // A successful bootstrap response has already consumed the one-time code. Finish that durable
        // handoff across stop/cancellation, but never let an obsolete attempt overwrite a newer setup.
        do {
            guard configuration.isSameInstallation(as: self.configuration) else { throw CancellationError() }
            guard usedBootstrap || response.voiceCredential == nil else {
                throw OpenClawWatchNodeError.voiceRequiresNewSetup
            }
            try await self.storeIssuedCredentials(response, identity: identity, gatewayID: configuration.gatewayID)
            if bootstrapToken != nil {
                try self.finishCredentialHandoff(configuration)
            }
            try self.requireCurrent(generation)
        } catch {
            self.sendDisconnect(session)
            throw error
        }
        self.activeSession = session
        self.setState(.connected(endpoint: baseURL.absoluteString, nodeId: response.nodeId))
        do {
            try await self.pollLoop(session: session, generation: generation)
        } catch {
            self.releaseActiveSession(session)
            throw error
        }
        self.releaseActiveSession(session)
    }

    private func pollLoop(session: ActiveSession, generation: Int) async throws {
        while self.isCurrent(generation) {
            let pollData = try await self.request(.poll, baseURL: session.baseURL, token: session.token)
            try self.requireCurrent(generation)
            let poll: OpenClawWatchNodePollResponse = try Self.decode(pollData)
            guard let invoke = poll.event?.invokeRequest else { continue }
            let response = await self.handler.handle(invoke.bridgeRequest)
            try self.requireCurrent(generation)
            let result = try OpenClawWatchNodeInvokeResult(response: response)
            _ = try await self.request(.result, baseURL: session.baseURL, token: session.token, body: result)
            try self.requireCurrent(generation)
        }
    }

    private func establishSession(
        identity: DeviceIdentity,
        baseURL: URL,
        credential: OpenClawWatchNodeCredential) async throws -> OpenClawWatchNodeConnectResponse
    {
        let challengeData = try await self.request(.challenge, baseURL: baseURL, token: nil)
        let challenge: OpenClawWatchNodeChallenge = try Self.decode(challengeData)
        let notificationsAuthorized = await self.handler.notificationsAuthorized()
        let client = await self.clientInfo()
        let params = try OpenClawWatchNodeConnectRequest.signed(
            identity: identity,
            challenge: challenge,
            credential: credential,
            client: client,
            notificationsAuthorized: notificationsAuthorized,
            fallbackNowMs: self.now())
        let connectData = try await self.request(.connect, baseURL: baseURL, token: nil, body: params)
        return try Self.decode(connectData)
    }

    private func storeIssuedCredentials(
        _ response: OpenClawWatchNodeConnectResponse,
        identity: DeviceIdentity,
        gatewayID: String) async throws
    {
        let profile = self.profile
        guard await DeviceAuthStore.storeTokenPersistedInBackground(
            deviceId: identity.deviceId,
            role: OpenClawWatchNodeHTTP.role,
            token: response.deviceToken,
            scopes: [],
            gatewayID: gatewayID,
            profile: profile)
        else {
            throw OpenClawWatchNodeError.credentialStorageFailed
        }
        if let voice = response.voiceCredential {
            let stored = await DeviceAuthStore.storeTokenPersistedInBackground(
                deviceId: identity.deviceId,
                role: voice.role,
                token: voice.deviceToken,
                scopes: voice.scopes,
                gatewayID: gatewayID,
                profile: profile)
            guard stored else { throw OpenClawWatchNodeError.voiceSetupIncomplete }
        }
    }

    private func finishCredentialHandoff(_ configuration: OpenClawWatchNodeConfiguration) throws {
        let sanitized = configuration.withoutBootstrapToken()
        guard self.store.saveConfiguration(sanitized) else {
            throw OpenClawWatchNodeError.configurationStorageFailed
        }
        self.configuration = sanitized
    }

    private func clearCredentials(deviceId: String, gatewayID: String) async {
        for role in [OpenClawWatchNodeHTTP.role, "operator"] {
            await DeviceAuthStore.clearTokenInBackground(
                deviceId: deviceId, role: role, gatewayID: gatewayID, profile: self.profile)
        }
    }

    // MARK: - Requests

    private func request(
        _ endpoint: OpenClawWatchNodeHTTP.Endpoint,
        baseURL: URL,
        token: String?,
        body: (any Encodable)? = nil) async throws -> Data
    {
        let request = try Self.makeRequest(endpoint, baseURL: baseURL, token: token, body: body)
        let (data, response) = try await self.perform(request)
        guard (200..<300).contains(response.statusCode) else {
            let detail = String(bytes: data.prefix(1024), encoding: .utf8) ?? ""
            throw OpenClawWatchNodeError.http(status: response.statusCode, detail: detail)
        }
        return data
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let id = UUID()
        let transport = self.transport
        let task = Task { try await transport.send(request) }
        self.inFlight[id] = task
        defer { self.inFlight[id] = nil }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func makeRequest(
        _ endpoint: OpenClawWatchNodeHTTP.Endpoint,
        baseURL: URL,
        token: String?,
        body: (any Encodable)?) throws -> URLRequest
    {
        let url = OpenClawWatchNodeHTTP.url(for: endpoint, baseURL: baseURL)
        guard url.scheme?.lowercased() == "https" else { throw OpenClawWatchNodeError.insecureEndpoint }
        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method
        request.timeoutInterval = endpoint.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private static func decode<Value: Decodable>(_ data: Data) throws -> Value {
        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            throw OpenClawWatchNodeError.invalidResponse(String(describing: Value.self))
        }
    }

    // MARK: - Lifecycle helpers

    private func isCurrent(_ generation: Int) -> Bool {
        !Task.isCancelled && generation == self.generation && self.configuration != nil
    }

    private func requireCurrent(_ generation: Int) throws {
        guard self.isCurrent(generation) else { throw CancellationError() }
    }

    private func retireCurrentConnection() {
        self.generation &+= 1
        if let session = self.activeSession {
            self.activeSession = nil
            self.sendDisconnect(session)
        }
        for task in self.inFlight.values {
            task.cancel()
        }
    }

    private func stopRunning() {
        self.runTask?.cancel()
        self.runTask = nil
        self.runToken = nil
        self.retireCurrentConnection()
    }

    private func runEnded(_ token: UUID) {
        guard self.runToken == token else { return }
        self.runTask = nil
        self.runToken = nil
    }

    private func releaseActiveSession(_ session: ActiveSession) {
        guard self.activeSession == session else { return }
        self.activeSession = nil
        self.sendDisconnect(session)
    }

    private func sendDisconnect(_ session: ActiveSession) {
        let transport = self.transport
        // Unstructured on purpose: the disconnect must outlive a cancelled poll loop.
        Task.detached {
            guard let request = try? Self.makeRequest(
                .disconnect, baseURL: session.baseURL, token: session.token, body: nil)
            else { return }
            _ = try? await transport.send(request)
        }
    }

    private func setState(_ state: State) {
        guard self.state != state else { return }
        self.state = state
        self.stateContinuation.yield(state)
    }
}
