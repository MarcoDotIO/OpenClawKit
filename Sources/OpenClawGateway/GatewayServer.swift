import Foundation
import OpenClawCore
import OpenClawProtocol

/// Browser-request handler injected into the in-process gateway server.
public typealias GatewayBrowserRequestHandler = @Sendable (GatewayBrowserRequestParams) async throws -> GatewayBrowserResponse

/// Agent-run handler injected into the in-process gateway server.
///
/// Receives the normalized request: legacy SDK payloads and upstream `AgentParams` (`agent`) both
/// arrive as ``GatewayAgentRequest`` with the upstream fields (`agentID`, `sessionID`, `thinking`,
/// `extraSystemPrompt`, `idempotencyKey`, …) filled when present.
public typealias GatewayAgentRunHandler = @Sendable (GatewayAgentRequest) async throws -> GatewayAgentExecution

/// Models-list handler injected into the in-process gateway server.
public typealias GatewayModelsListHandler = @Sendable () async throws -> [GatewayModelCatalogEntry]

/// Skills-list handler injected into the in-process gateway server.
public typealias GatewaySkillsListHandler = @Sendable () async throws -> [GatewaySkillDescriptor]

/// Skill-invoke handler injected into the in-process gateway server.
public typealias GatewaySkillInvokeHandler = @Sendable (GatewaySkillInvokeParams) async throws -> GatewaySkillInvokeResult

/// Long-running agent execution tracked by the gateway server.
public struct GatewayAgentExecution: Sendable {
    /// Stable run identifier exposed through `agent.wait`.
    public let runID: String
    /// Task that resolves once the agent run finishes.
    public let task: Task<GatewayAgentWaitResult, Error>

    /// Creates a tracked gateway agent execution.
    public init(runID: String, task: Task<GatewayAgentWaitResult, Error>) {
        self.runID = runID
        self.task = task
    }
}

/// Closure-backed handlers used by `GatewayServer` for higher-level runtime features.
public struct GatewayServerHandlers: Sendable {
    /// Handler used to start an agent run (`agent`, `agent.run`, and the built-in `sessions.send`).
    public let runAgent: GatewayAgentRunHandler
    /// Handler used to list models.
    public let listModels: GatewayModelsListHandler
    /// Handler used to list skills.
    public let listSkills: GatewaySkillsListHandler
    /// Handler used to invoke a skill.
    public let invokeSkill: GatewaySkillInvokeHandler
    /// Optional browser proxy handler.
    public let browserRequest: GatewayBrowserRequestHandler?

    /// Creates a set of closure-backed gateway server handlers.
    public init(
        runAgent: @escaping GatewayAgentRunHandler = { _ in
            throw OpenClawCoreError.unavailable("Agent execution is not configured for this gateway server")
        },
        listModels: @escaping GatewayModelsListHandler = {
            throw OpenClawCoreError.unavailable("Model catalog is not configured for this gateway server")
        },
        listSkills: @escaping GatewaySkillsListHandler = {
            throw OpenClawCoreError.unavailable("Skill listing is not configured for this gateway server")
        },
        invokeSkill: @escaping GatewaySkillInvokeHandler = { _ in
            throw OpenClawCoreError.unavailable("Skill invocation is not configured for this gateway server")
        },
        browserRequest: GatewayBrowserRequestHandler? = nil
    ) {
        self.runAgent = runAgent
        self.listModels = listModels
        self.listSkills = listSkills
        self.invokeSkill = invokeSkill
        self.browserRequest = browserRequest
    }
}

/// In-process gateway dispatcher that fronts sessions, secrets, and injected runtime handlers.
///
/// Dispatch is table-driven:
/// 1. Methods registered with ``register(method:descriptor:handler:)`` (and the built-in handlers,
///    which live in the same table and can be replaced or removed).
/// 2. Resolvers added with ``addMethodResolver(_:)`` (dynamic sources such as plugin registries).
/// 3. Any other upstream core method from ``GatewayMethodCatalog``: params are validated against the
///    generated `<Method>Params` model (`INVALID_REQUEST` on mismatch), then the request answers
///    `UNAVAILABLE` because nothing in-process implements it.
/// 4. Methods upstream removed since the previous pin, and unknown methods, answer `INVALID_REQUEST`.
///
/// Before invoking a handler the server authorizes the connection like upstream: node-scoped methods
/// require the node role and all others the operator role (`INVALID_REQUEST "unauthorized role: …"`),
/// and the descriptor scope is checked against the connection's grants
/// (``GatewayConnectionContext/allows(scope:)``), answering `FORBIDDEN` with `MISSING_SCOPE` details.
/// `dynamic` methods (`agent`, `sessions.create/patch/delete`, `node.invoke`, …) derive their scopes
/// from the request params (``GatewayMethodScopePolicy``) and fail closed; a method registered
/// without any descriptor requires `operator.admin`.
/// While startup is pending (``beginStartup(gating:)``), startup-gated methods then answer the
/// retryable startup `UNAVAILABLE` error (`details.reason == "startup-sidecars"`).
///
/// Events: handlers emit through ``GatewayMethodRequest/events``; hosts use ``broadcast(event:payload:)``
/// or ``emit(event:encoding:)``. Every frame carries a server-global monotonic `seq`. Subscribe with
/// ``events(filter:bufferingNewest:)``; ``LoopbackGatewaySocket`` subscribes per connection so
/// `session.message`/`session.tool` only reach connections that called `sessions.messages.subscribe`.
public actor GatewayServer: GatewayMethodRegistrar {
    /// Methods served in-process that are OpenClawKit extensions rather than upstream core methods.
    ///
    /// `browser.request` is plugin-owned upstream (extensions/browser); the others have no upstream
    /// equivalent (`secrets.store.*` is the upstream secrets surface).
    public static let sdkExtensionMethods: Set<String> = [
        "agent.run",
        "skills.list",
        "skills.invoke",
        "secrets.list",
        "secrets.set",
        "secrets.delete",
        "browser.request",
    ]

    /// Descriptors used for ``sdkExtensionMethods`` (scopes mirror the closest upstream method).
    public static let sdkExtensionDescriptors: [String: GatewayMethodDescriptor] = [
        "agent.run": GatewayMethodDescriptor(name: "agent.run", family: "sdk-agent", scope: "operator.write", since: "sdk"),
        "skills.list": GatewayMethodDescriptor(name: "skills.list", family: "sdk-skills", scope: "operator.read", since: "sdk"),
        "skills.invoke": GatewayMethodDescriptor(name: "skills.invoke", family: "sdk-skills", scope: "operator.write", since: "sdk"),
        "secrets.list": GatewayMethodDescriptor(name: "secrets.list", family: "sdk-secrets", scope: "operator.admin", since: "sdk"),
        "secrets.set": GatewayMethodDescriptor(name: "secrets.set", family: "sdk-secrets", scope: "operator.admin", since: "sdk"),
        "secrets.delete": GatewayMethodDescriptor(name: "secrets.delete", family: "sdk-secrets", scope: "operator.admin", since: "sdk"),
        "browser.request": GatewayMethodDescriptor(name: "browser.request", family: "browser", scope: "operator.admin", since: "sdk"),
    ]

    enum BuiltinMethod: Sendable {
        case agentRun
        case agentWait
        case sessionsList
        case sessionsGet
        case sessionsPatch
        case sessionsReset
        case sessionsDelete
        case sessionsCreate
        case sessionsSend
        case sessionsAbort
        case sessionsSubscribe
        case sessionsMessagesSubscribe
        case sessionsMessagesUnsubscribe
        case sessionsGroupsList
        case sessionsGroupsDefaults
        case sessionsGroupsPut
        case sessionsGroupsRename
        case sessionsGroupsUpdate
        case sessionsGroupsDelete
        case modelsList
        case skillsList
        case skillsInvoke
        case secretsList
        case secretsSet
        case secretsDelete
        case secretsStoreList
        case secretsStoreSet
        case secretsStoreDelete
        case browserRequest
        case systemPresence
        case nodeList
        case nodePairList
        case nodePairApprove
        case nodePairReject
        case nodePairRemove
        case nodeRename
    }

    static let builtinMethods: [String: BuiltinMethod] = [
        "agent": .agentRun,
        "agent.run": .agentRun,
        "agent.wait": .agentWait,
        "sessions.list": .sessionsList,
        "sessions.get": .sessionsGet,
        "sessions.patch": .sessionsPatch,
        "sessions.reset": .sessionsReset,
        "sessions.delete": .sessionsDelete,
        "sessions.create": .sessionsCreate,
        "sessions.send": .sessionsSend,
        "sessions.abort": .sessionsAbort,
        "sessions.subscribe": .sessionsSubscribe,
        "sessions.messages.subscribe": .sessionsMessagesSubscribe,
        "sessions.messages.unsubscribe": .sessionsMessagesUnsubscribe,
        "sessions.groups.list": .sessionsGroupsList,
        "sessions.groups.defaults": .sessionsGroupsDefaults,
        "sessions.groups.put": .sessionsGroupsPut,
        "sessions.groups.rename": .sessionsGroupsRename,
        "sessions.groups.update": .sessionsGroupsUpdate,
        "sessions.groups.delete": .sessionsGroupsDelete,
        "models.list": .modelsList,
        "skills.list": .skillsList,
        "skills.invoke": .skillsInvoke,
        "secrets.list": .secretsList,
        "secrets.set": .secretsSet,
        "secrets.delete": .secretsDelete,
        "secrets.store.list": .secretsStoreList,
        "secrets.store.set": .secretsStoreSet,
        "secrets.store.delete": .secretsStoreDelete,
        "browser.request": .browserRequest,
        "system-presence": .systemPresence,
        "node.list": .nodeList,
        "node.pair.list": .nodePairList,
        "node.pair.approve": .nodePairApprove,
        "node.pair.reject": .nodePairReject,
        "node.pair.remove": .nodePairRemove,
        "node.rename": .nodeRename,
    ]

    private enum MethodImplementation: Sendable {
        case builtin(BuiltinMethod)
        case custom(GatewayMethodHandler)
    }

    private struct MethodEntry: Sendable {
        let descriptor: GatewayMethodDescriptor?
        let implementation: MethodImplementation
    }

    /// Metadata of an active agent run started through the built-in `agent`/`sessions.send` handlers.
    struct TrackedRun: Sendable {
        let sessionKey: String
        let agentID: String
        let startedAt: Int64
        /// Start order (breaks `startedAt` ties within one millisecond).
        let order: Int
        /// Identity of this tracking (a later run reusing the run id gets a new token).
        let token: UUID
        /// Whether `sessions.abort` already cancelled the run (it stays tracked until it finishes).
        var aborted = false
    }

    /// One event subscription.
    struct EventSubscriber {
        let continuation: AsyncStream<EventFrame>.Continuation
        let filter: GatewayEventFilter
    }

    /// Presence of one open connection.
    struct ConnectionPresence: Sendable {
        let context: GatewayConnectionContext
        let onlineSince: Int64
        var lastActivityAt: Int64
    }

    let sessionStore: SessionStore
    let secretVault: GatewaySecretVault
    let defaultAgentID: String
    let handlers: GatewayServerHandlers
    /// Custom session group catalog backing `sessions.groups.*`.
    nonisolated public let sessionGroups: GatewaySessionGroupCatalog
    /// Node pairing records backing `node.pair.*`, `node.list` and `node.rename`.
    nonisolated public let nodePairing: GatewayNodePairingStore
    let agentIdempotency = GatewayIdempotencyCache()
    /// Tasks of the active built-in runs (finished runs move to ``completedRuns``).
    var agentRuns: [String: Task<GatewayAgentWaitResult, Error>] = [:]
    var trackedRuns: [String: TrackedRun] = [:]
    var runOrder = 0
    /// One `agent.wait` caller suspended on an active built-in run.
    struct RunWaiter {
        let continuation: CheckedContinuation<GatewayAgentWaitResult, Never>
        /// Wait deadline timer, cancelled when the run finishes first.
        let timeout: Task<Void, Never>?
    }

    /// `agent.wait` callers suspended on an active built-in run.
    var runWaiters: [String: [UUID: RunWaiter]] = [:]
    /// Terminal results of recently finished built-in runs (newest ``completedRunLimit``).
    var completedRuns: [String: GatewayAgentWaitResult] = [:]
    var completedRunOrder: [String] = []
    /// Finished built-in runs whose results stay available to late `agent.wait` calls.
    static let completedRunLimit = 256
    private var methods: [String: MethodEntry]
    private var resolvers: [GatewayMethodResolver] = []
    var eventSubscribers: [UUID: EventSubscriber] = [:]
    var eventSequence = 0
    /// Connections subscribed to `sessions.changed` via `sessions.subscribe`.
    var sessionEventConnections: Set<String> = []
    /// Session keys each connection subscribed to via `sessions.messages.subscribe`.
    var messageSubscriptions: [String: Set<String>] = [:]
    var connections: [String: ConnectionPresence] = [:]
    /// Methods answering the startup `UNAVAILABLE` error; `nil` once startup completed.
    var startupGatedMethods: Set<String>?
    var startupGatesEveryDescriptor = false

    /// Creates an in-process gateway server with session, secret, and runtime handlers.
    /// - Parameters:
    ///   - sessionStore: Store backing `sessions.*`.
    ///   - secretVault: Vault backing `secrets.*` and `secrets.store.*`.
    ///   - defaultAgentID: Agent id assigned to sessions created by `sessions.patch`.
    ///   - handlers: Runtime handlers for agent runs, models, skills and browser requests.
    ///   - sessionGroups: Catalog backing `sessions.groups.*` (in-memory by default).
    ///   - nodePairing: Store backing `node.pair.*` (in-memory by default).
    ///   - startupPending: Start with startup-gated methods unavailable until ``completeStartup()``.
    public init(
        sessionStore: SessionStore,
        secretVault: GatewaySecretVault,
        defaultAgentID: String = "main",
        handlers: GatewayServerHandlers = GatewayServerHandlers(),
        sessionGroups: GatewaySessionGroupCatalog = GatewaySessionGroupCatalog(),
        nodePairing: GatewayNodePairingStore = GatewayNodePairingStore(),
        startupPending: Bool = false
    ) {
        self.sessionStore = sessionStore
        self.secretVault = secretVault
        self.defaultAgentID = defaultAgentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "main" : defaultAgentID
        self.handlers = handlers
        self.sessionGroups = sessionGroups
        self.nodePairing = nodePairing
        var methods: [String: MethodEntry] = [:]
        for (name, builtin) in Self.builtinMethods {
            methods[name] = MethodEntry(descriptor: Self.defaultDescriptor(for: name), implementation: .builtin(builtin))
        }
        self.methods = methods
        if startupPending {
            self.startupGatedMethods = []
            self.startupGatesEveryDescriptor = true
        }
    }

    // MARK: - Registration

    /// Registers (or replaces) the handler for `method`, including built-in methods.
    ///
    /// Names are trimmed; an empty name is ignored.
    /// - Parameters:
    ///   - method: Wire method name.
    ///   - descriptor: Method metadata; `nil` uses the upstream catalog (or SDK extension) descriptor
    ///     when one exists, otherwise the method requires `operator.admin` (upstream default-deny).
    ///   - handler: Handler invoked for each request.
    public func register(method: String, descriptor: GatewayMethodDescriptor?, handler: @escaping GatewayMethodHandler) {
        let name = method.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        self.methods[name] = MethodEntry(
            descriptor: descriptor ?? Self.defaultDescriptor(for: name),
            implementation: .custom(handler)
        )
    }

    /// Removes the handler for `method` (built-in or registered).
    ///
    /// Afterwards the method falls through to resolvers and the catalog fallback.
    /// - Parameter method: Wire method name.
    /// - Returns: `true` when a handler was removed.
    @discardableResult
    public func unregister(method: String) -> Bool {
        self.methods.removeValue(forKey: method.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
    }

    /// Returns a handler invoking the built-in implementation of `method`, so a module can register
    /// a wrapper that falls back to it (for example `agent.wait` for runs the module does not own).
    /// - Parameter method: Wire method name.
    /// - Returns: The built-in handler, or `nil` when `method` has no built-in implementation.
    public func builtinHandler(for method: String) -> GatewayMethodHandler? {
        guard let builtin = Self.builtinMethods[method] else { return nil }
        return { [weak self] request in
            guard let self else {
                throw GatewayMethodError.unavailable("gateway server is no longer available")
            }
            return try await self.invokeBuiltin(builtin, request: request)
        }
    }

    /// Adds a resolver consulted for methods without a registered handler, in insertion order.
    ///
    /// A resolved method that has a catalog or SDK extension descriptor is authorized like a
    /// registered one; for any other method the resolved handler must authorize the request itself
    /// (as `PluginRegistry.gatewayHandler(for:)` does with the plugin's descriptor).
    /// - Parameter resolver: Resolver returning a handler, or `nil` to pass.
    public func addMethodResolver(_ resolver: @escaping GatewayMethodResolver) {
        self.resolvers.append(resolver)
    }

    /// Returns the sorted names of every method with an in-process handler (diagnostics).
    ///
    /// This is the SDK analogue of hello-ok `features.methods` before advertise filtering.
    public func supportedMethods() -> [String] {
        self.methods.keys.sorted()
    }

    /// Returns the sorted names of handled methods that should be advertised in hello-ok `features.methods`.
    ///
    /// Methods whose descriptor sets `advertised: false` (for example `sessions.get`) are omitted.
    public func advertisedMethods() -> [String] {
        self.methods
            .filter { $0.value.descriptor?.advertised ?? true }
            .map(\.key)
            .sorted()
    }

    /// Returns the descriptor the server uses for `method` (registration, SDK extension, or catalog).
    /// - Parameter method: Wire method name.
    /// - Returns: Descriptor when one is known.
    public func methodDescriptor(for method: String) -> GatewayMethodDescriptor? {
        self.methods[method]?.descriptor ?? Self.defaultDescriptor(for: method)
    }

    nonisolated func makeEventEmitter() -> GatewayEventEmitter {
        GatewayEventEmitter { [weak self] event, payload in
            await self?.broadcast(event: event, payload: payload)
        }
    }

    // MARK: - Dispatch

    /// Dispatches one gateway request frame from a trusted in-process caller.
    /// - Parameter request: Raw request frame.
    /// - Returns: Encoded response frame.
    public func handle(_ request: RequestFrame) async -> ResponseFrame {
        await self.handle(request, connection: .inProcess)
    }

    /// Dispatches one gateway request frame on behalf of a connection.
    /// - Parameters:
    ///   - request: Raw request frame.
    ///   - connection: Connection identity and grants used for scope checks and handler context.
    /// - Returns: Encoded response frame.
    public func handle(_ request: RequestFrame, connection: GatewayConnectionContext) async -> ResponseFrame {
        let entry = self.methods[request.method]
        let descriptor = entry?.descriptor ?? Self.defaultDescriptor(for: request.method)
        let context = GatewayMethodRequest(
            id: request.id,
            method: request.method,
            rawParams: request.params,
            descriptor: descriptor,
            connection: connection,
            events: self.makeEventEmitter()
        )
        self.touchConnection(connection.connectionID)
        do {
            // Registered methods are always authorized (a registration without any descriptor
            // requires operator.admin); resolver-served methods without a descriptor authorize in
            // the resolver's handler.
            if descriptor != nil || entry != nil,
               let denial = Self.authorizationError(method: request.method, descriptor: descriptor, params: request.params, connection: connection)
            {
                throw denial
            }
            // Startup gating follows authorization (upstream server-methods.ts): stores may not be
            // loaded yet, so a handler could otherwise answer with a misleading non-retryable error.
            if let gated = self.startupGateError(method: request.method, descriptor: descriptor) {
                throw gated
            }
            let payload: AnyCodable?
            if let entry {
                payload = try await self.invoke(entry.implementation, request: context)
            } else if let handler = await self.resolveHandler(for: request.method) {
                payload = try await handler(context)
            } else {
                return Self.errorResponse(id: request.id, shape: Self.fallbackError(for: context).errorShape)
            }
            return ResponseFrame(type: "res", id: request.id, ok: true, payload: payload, error: nil)
        } catch {
            return Self.errorResponse(id: request.id, shape: GatewayMethodError.errorShape(for: error))
        }
    }

    private func resolveHandler(for method: String) async -> GatewayMethodHandler? {
        for resolver in self.resolvers {
            if let handler = await resolver(method) {
                return handler
            }
        }
        return nil
    }

    private func invoke(_ implementation: MethodImplementation, request: GatewayMethodRequest) async throws -> AnyCodable? {
        switch implementation {
        case .custom(let handler):
            return try await handler(request)
        case .builtin(let builtin):
            return try await self.invokeBuiltin(builtin, request: request)
        }
    }

    /// Mirrors upstream `authorizeGatewayMethod` (see ``GatewayMethodScopePolicy/authorizationError(method:descriptor:params:connection:)``):
    /// `health` is always reachable, node-scoped methods require the node role and every other method
    /// the operator role (`INVALID_REQUEST "unauthorized role: …"`), and operator scopes, including the
    /// per-request scopes of `dynamic` methods, are checked against the connection grants (`FORBIDDEN`
    /// with `MISSING_SCOPE` details). A registered method without a descriptor requires `operator.admin`.
    static func authorizationError(
        method: String,
        descriptor: GatewayMethodDescriptor?,
        params: AnyCodable?,
        connection: GatewayConnectionContext
    ) -> GatewayMethodError? {
        GatewayMethodScopePolicy.authorizationError(method: method, descriptor: descriptor, params: params, connection: connection)
    }

    /// Error for a method without any in-process handler.
    static func fallbackError(for request: GatewayMethodRequest) -> GatewayMethodError {
        let method = request.method
        if let descriptor = GatewayMethodCatalog.byName[method] {
            do {
                _ = try GatewayMethodCatalog.validateParams(method: method, payload: request.rawParams)
            } catch {
                return .invalidParams(method: method, underlying: error)
            }
            return .unavailable("\(method) is known (since \(descriptor.since)) but is not configured for this gateway server")
        }
        if GatewayMethodCatalog.removedSincePreviousPin.contains(method) {
            return .invalidRequest("unknown method: \(method) (removed upstream in OpenClaw \(GatewayMethodCatalog.upstreamVersion))")
        }
        return .invalidRequest("unknown method: \(method)")
    }

    static func defaultDescriptor(for method: String) -> GatewayMethodDescriptor? {
        GatewayMethodCatalog.byName[method] ?? Self.sdkExtensionDescriptors[method]
    }

    static func errorResponse(id: String, shape: ErrorShape) -> ResponseFrame {
        ResponseFrame(type: "res", id: id, ok: false, payload: nil, error: shape)
    }
}
