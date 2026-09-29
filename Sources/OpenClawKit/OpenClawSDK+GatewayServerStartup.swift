import Foundation

/// How ``OpenClawSDK/startGatewayServer(sessionStore:credentialStore:modelRouter:runtime:workspaceRoot:secretIndexURL:browserRequestHandler:options:startup:)``
/// wires an embedded gateway server.
public struct OpenClawGatewayServerStartupOptions: Sendable, Equatable {
    /// Registers the runtime's gateway handlers and bridges its events into the server's event
    /// stream (`EmbeddedAgentRuntime.attach(to:options:)`). Default `true`.
    public var attachRuntime: Bool
    /// Bridging options passed to the runtime attach.
    public var agentOptions: AgentGatewayOptions
    /// Answers gated methods with the retryable startup `UNAVAILABLE` error while the runtime
    /// attaches and the startup closure runs (`GatewayServer.runStartup(gating:_:)`). Default `true`.
    public var gatesStartup: Bool
    /// Methods to gate; `nil` gates every catalog method marked `startupGated`.
    public var gatedMethods: Set<String>?

    /// Creates startup options.
    /// - Parameters:
    ///   - attachRuntime: Whether to attach the runtime to the server.
    ///   - agentOptions: Runtime bridging options.
    ///   - gatesStartup: Whether to gate methods during startup.
    ///   - gatedMethods: Methods to gate (`nil` = catalog `startupGated` methods).
    public init(
        attachRuntime: Bool = true,
        agentOptions: AgentGatewayOptions = AgentGatewayOptions(),
        gatesStartup: Bool = true,
        gatedMethods: Set<String>? = nil)
    {
        self.attachRuntime = attachRuntime
        self.agentOptions = agentOptions
        self.gatesStartup = gatesStartup
        self.gatedMethods = gatedMethods
    }
}

extension OpenClawSDK {
    /// Creates an in-process gateway server like
    /// ``makeGatewayServer(sessionStore:credentialStore:modelRouter:runtime:workspaceRoot:secretIndexURL:browserRequestHandler:)``
    /// and starts it: by default the runtime is attached (its session, chat, approval and question
    /// handlers are registered and its events are broadcast) and `startup` runs, all while gated
    /// methods answer the retryable startup `UNAVAILABLE` error, so connected clients retry instead of
    /// failing against a half-started server.
    /// - Parameters:
    ///   - sessionStore: Session store used for session control-plane methods.
    ///   - credentialStore: Secret store used by `secrets.*` methods.
    ///   - modelRouter: Model router used by `models.list` and runtime-backed agent runs.
    ///   - runtime: Optional preconfigured runtime; one is created from `modelRouter` otherwise.
    ///   - workspaceRoot: Optional workspace root used by `skills.*` methods.
    ///   - secretIndexURL: Optional persisted index path for secret-key metadata.
    ///   - browserRequestHandler: Optional browser proxy handler used by `browser.request`.
    ///   - options: Attach and startup-gating options.
    ///   - startup: Extra startup work (for example registering module handlers or loading stores).
    /// - Returns: The started server.
    /// - Throws: Rethrows `startup`'s error; startup gating is lifted either way.
    public func startGatewayServer(
        sessionStore: SessionStore,
        credentialStore: any CredentialStore,
        modelRouter: ModelRouter = ModelRouter(),
        runtime: EmbeddedAgentRuntime? = nil,
        workspaceRoot: URL? = nil,
        secretIndexURL: URL? = nil,
        browserRequestHandler: GatewayBrowserRequestHandler? = nil,
        options: OpenClawGatewayServerStartupOptions = OpenClawGatewayServerStartupOptions(),
        startup: (@Sendable (GatewayServer) async throws -> Void)? = nil) async throws -> GatewayServer
    {
        let resolvedRuntime = runtime ?? EmbeddedAgentRuntime(modelRouter: modelRouter)
        let server = self.makeGatewayServer(
            sessionStore: sessionStore,
            credentialStore: credentialStore,
            modelRouter: modelRouter,
            runtime: resolvedRuntime,
            workspaceRoot: workspaceRoot,
            secretIndexURL: secretIndexURL,
            browserRequestHandler: browserRequestHandler)
        let body: @Sendable () async throws -> Void = {
            if options.attachRuntime {
                await resolvedRuntime.attach(to: server, options: options.agentOptions)
            }
            try await startup?(server)
        }
        if options.gatesStartup {
            try await server.runStartup(gating: options.gatedMethods, body)
        } else {
            try await body()
        }
        return server
    }
}
