import Foundation
import OpenClawCore
import OpenClawProtocol

/// Browser-request handler injected into the in-process gateway server.
public typealias GatewayBrowserRequestHandler = @Sendable (GatewayBrowserRequestParams) async throws -> GatewayBrowserResponse

/// Agent-run handler injected into the in-process gateway server.
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
    /// Handler used to start an agent run.
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
    ]

    private enum MethodImplementation: Sendable {
        case builtin(BuiltinMethod)
        case custom(GatewayMethodHandler)
    }

    private struct MethodEntry: Sendable {
        let descriptor: GatewayMethodDescriptor?
        let implementation: MethodImplementation
    }

    let sessionStore: SessionStore
    let secretVault: GatewaySecretVault
    let defaultAgentID: String
    let handlers: GatewayServerHandlers
    var agentRuns: [String: Task<GatewayAgentWaitResult, Error>] = [:]
    private var methods: [String: MethodEntry]
    private var resolvers: [GatewayMethodResolver] = []
    private var eventSubscribers: [UUID: AsyncStream<EventFrame>.Continuation] = [:]
    private var eventSequence = 0

    /// Creates an in-process gateway server with session, secret, and runtime handlers.
    /// - Parameters:
    ///   - sessionStore: Store backing `sessions.*`.
    ///   - secretVault: Vault backing `secrets.*` and `secrets.store.*`.
    ///   - defaultAgentID: Agent id assigned to sessions created by `sessions.patch`.
    ///   - handlers: Runtime handlers for agent runs, models, skills and browser requests.
    public init(
        sessionStore: SessionStore,
        secretVault: GatewaySecretVault,
        defaultAgentID: String = "main",
        handlers: GatewayServerHandlers = GatewayServerHandlers()
    ) {
        self.sessionStore = sessionStore
        self.secretVault = secretVault
        self.defaultAgentID = defaultAgentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "main" : defaultAgentID
        self.handlers = handlers
        var methods: [String: MethodEntry] = [:]
        for (name, builtin) in Self.builtinMethods {
            methods[name] = MethodEntry(descriptor: Self.defaultDescriptor(for: name), implementation: .builtin(builtin))
        }
        self.methods = methods
    }

    // MARK: - Registration

    /// Registers (or replaces) the handler for `method`, including built-in methods.
    ///
    /// Names are trimmed; an empty name is ignored.
    /// - Parameters:
    ///   - method: Wire method name.
    ///   - descriptor: Method metadata; `nil` uses the upstream catalog (or SDK extension) descriptor
    ///     when one exists, otherwise the method is unscoped.
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

    /// Adds a resolver consulted for methods without a registered handler, in insertion order.
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

    // MARK: - Events

    /// Subscribes to events emitted by method handlers (and ``broadcast(event:payload:)``).
    /// - Parameter limit: Number of undelivered events buffered per subscriber.
    /// - Returns: Stream of event frames; cancel iteration to unsubscribe.
    public func events(bufferingNewest limit: Int = 256) -> AsyncStream<EventFrame> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<EventFrame>.makeStream(bufferingPolicy: .bufferingNewest(max(1, limit)))
        self.eventSubscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeEventSubscriber(id) }
        }
        return stream
    }

    /// Emits an event to every subscriber with the next sequence number.
    /// - Parameters:
    ///   - event: Event name (see ``GatewayEventName``).
    ///   - payload: Optional event payload.
    /// - Returns: The emitted frame.
    @discardableResult
    public func broadcast(event: String, payload: AnyCodable? = nil) -> EventFrame {
        self.eventSequence += 1
        let frame = EventFrame(type: "event", event: event, payload: payload, seq: self.eventSequence)
        for continuation in self.eventSubscribers.values {
            continuation.yield(frame)
        }
        return frame
    }

    private func removeEventSubscriber(_ id: UUID) {
        self.eventSubscribers.removeValue(forKey: id)
    }

    nonisolated private func makeEventEmitter() -> GatewayEventEmitter {
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
        do {
            if let descriptor, let denial = Self.authorizationError(method: request.method, descriptor: descriptor, connection: connection) {
                throw denial
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

    /// Mirrors upstream `authorizeGatewayMethod`: `health` is always reachable, node-scoped methods
    /// require the node role and every other method the operator role (`INVALID_REQUEST
    /// "unauthorized role: …"`), and operator scopes are checked against the connection grants
    /// (`FORBIDDEN` with `MISSING_SCOPE` details). `dynamic` methods resolve their scope in the handler.
    static func authorizationError(
        method: String,
        descriptor: GatewayMethodDescriptor,
        connection: GatewayConnectionContext
    ) -> GatewayMethodError? {
        if method == "health" {
            return nil
        }
        let role = connection.role.trimmingCharacters(in: .whitespacesAndNewlines)
        let requiresNodeRole = descriptor.scope == "node"
        guard role == (requiresNodeRole ? "node" : "operator") else {
            return .invalidRequest("unauthorized role: \(role)")
        }
        if requiresNodeRole || connection.allows(scope: descriptor.scope) {
            return nil
        }
        return .missingScope(descriptor.scope)
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
