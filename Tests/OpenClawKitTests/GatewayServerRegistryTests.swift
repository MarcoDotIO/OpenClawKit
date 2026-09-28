import Foundation
import OpenClawCore
import OpenClawGateway
import OpenClawProtocol
import Testing

@Suite("Gateway server registry", .serialized)
struct GatewayServerRegistryTests {
    // MARK: - Catalog

    @Test
    func catalogSnapshotMatchesPinnedUpstream() {
        #expect(GatewayMethodCatalog.upstreamVersion == "2026.9.6")
        #expect(GatewayMethodCatalog.upstreamCommit == "eb377ac59e")
        #expect(GatewayMethodCatalog.descriptors.count == 482)
        #expect(GatewayMethodCatalog.byName.count == 482)
        #expect(GatewayMethodCatalog.descriptors.filter { !$0.advertised }.count == 22)
        #expect(GatewayMethodCatalog.removedSincePreviousPin == [
            "node.canvas.capability.refresh",
            "node.pair.request",
            "node.pair.verify",
            "sessions.compaction.branch",
            "sessions.compaction.get",
            "sessions.compaction.list",
            "sessions.compaction.restore",
            "sessions.unsubscribe",
            "talk.realtime.session",
        ])
        #expect(GatewayMethodCatalog.removedSincePreviousPin.isDisjoint(with: Set(GatewayMethodCatalog.byName.keys)))
        #expect(GatewayEventName.allCases.count == 64)
        #expect(GatewayEventName.sessionMessage.rawValue == "session.message")
        #expect(GatewayServerCapabilityName.allCases.count == 21)
        #expect(GatewayClientID.macosApp.rawValue == "openclaw-macos")
        #expect(GatewayClientID.iosApp.rawValue == "openclaw-ios")
        #expect(GatewayClientID.watchosApp.rawValue == "openclaw-watchos")
        #expect(GatewayClientMode.allCases.count == 8)
        #expect(GatewayClientCapability.allCases.count == 17)

        let sessionsGet = GatewayMethodCatalog.byName["sessions.get"]
        #expect(sessionsGet?.advertised == false)
        #expect(sessionsGet?.scope == "operator.read")
        #expect(GatewayMethodCatalog.byName["config.patch"]?.controlPlaneWrite == true)
        #expect(GatewayMethodCatalog.byName["models.list"]?.startupGated == true)
        #expect(GatewayMethodCatalog.byName["approval.get"]?.family == nil)
    }

    @Test
    func catalogValidatesTypedParams() throws {
        #expect(try GatewayMethodCatalog.validateParams(method: "sessions.abort", payload: AnyCodable(["key": AnyCodable("main")])))
        #expect(throws: (any Error).self) {
            try GatewayMethodCatalog.validateParams(method: "sessions.send", payload: AnyCodable([String: AnyCodable]()))
        }
        #expect(try GatewayMethodCatalog.validateParams(method: "health", payload: nil) == false)
        #expect(try GatewayMethodCatalog.validateParams(method: "not.a.method", payload: nil) == false)
    }

    @Test
    func sdkExtensionMethodsAreDescribedAndNotUpstreamCore() {
        for method in GatewayServer.sdkExtensionMethods {
            #expect(GatewayServer.sdkExtensionDescriptors[method]?.name == method)
            #expect(GatewayMethodCatalog.byName[method] == nil)
        }
        #expect(Set(GatewayServer.sdkExtensionDescriptors.keys) == GatewayServer.sdkExtensionMethods)
    }

    @Test
    func catalogMethodsAreKnownOrUnknownConsistently() async throws {
        let (server, root) = try self.makeServer(named: "catalog-consistency")
        defer { try? FileManager.default.removeItem(at: root) }

        let handled = Set(await server.supportedMethods())
        for descriptor in GatewayMethodCatalog.descriptors where !handled.contains(descriptor.name) {
            let response = await server.handle(Self.frame(descriptor.name, params: [:]))
            #expect(response.ok == false)
            let expected: ErrorCode
            if descriptor.scope == "node" {
                // Node-role methods reject the in-process operator connection before dispatch.
                expected = .invalidRequest
            } else if (try? GatewayMethodCatalog.validateParams(method: descriptor.name, payload: AnyCodable([String: AnyCodable]()))) != nil {
                expected = .unavailable
            } else {
                expected = .invalidRequest
            }
            #expect(response.error?.errorCode == expected, "\(descriptor.name) answered \(response.error?.code ?? "ok")")
        }

        for removed in GatewayMethodCatalog.removedSincePreviousPin {
            let response = await server.handle(Self.frame(removed, params: [:]))
            #expect(response.error?.errorCode == .invalidRequest)
            #expect(response.error?.message.contains("removed upstream") == true)
        }

        let unknown = await server.handle(Self.frame("newer.unknown.method", params: [:]))
        #expect(unknown.error?.errorCode == .invalidRequest)
        #expect(unknown.error?.message == "unknown method: newer.unknown.method")
    }

    // MARK: - Registration API

    @Test
    func registeredHandlersOverrideBuiltinsAndCatalogFallback() async throws {
        let (server, root) = try self.makeServer(named: "registration")
        defer { try? FileManager.default.removeItem(at: root) }

        let unavailable = await server.handle(Self.frame("health", params: [:]))
        #expect(unavailable.error?.errorCode == .unavailable)

        await server.register(method: "health") { request in
            #expect(request.descriptor?.scope == "operator.read")
            #expect(request.connection == .inProcess)
            return AnyCodable(["ok": AnyCodable(true), "method": AnyCodable(request.method)])
        }
        let health = await server.handle(Self.frame("health", params: [:]))
        #expect(health.ok == true)
        #expect(health.payload?.dictionaryValue?["method"] == AnyCodable("health"))
        #expect(await server.supportedMethods().contains("health"))

        await server.register(method: "sessions.list") { _ in AnyCodable(["sessions": AnyCodable([AnyCodable]())]) }
        let overridden = await server.handle(Self.frame("sessions.list", params: [:]))
        #expect(overridden.payload == AnyCodable(["sessions": AnyCodable([AnyCodable]())]))

        #expect(await server.unregister(method: "sessions.list"))
        #expect(await server.unregister(method: "sessions.list") == false)
        let removedBuiltin = await server.handle(Self.frame("sessions.list", params: [:]))
        #expect(removedBuiltin.error?.errorCode == .unavailable)

        await server.register(method: "   ") { _ in nil }
        #expect(await server.supportedMethods().contains("") == false)
    }

    @Test
    func typedRegistrationValidatesParamsAndEncodesResponses() async throws {
        let (server, root) = try self.makeServer(named: "typed-registration")
        defer { try? FileManager.default.removeItem(at: root) }

        await server.register(method: "sessions.abort", params: SessionsAbortParams.self) { params, _ in
            GatewayAgentWaitResult(runID: params.runid ?? "none", status: "aborted", sessionKey: params.key)
        }
        let ok = await server.handle(Self.frame("sessions.abort", params: ["key": AnyCodable("main"), "runId": AnyCodable("run-7")]))
        let decoded = try GatewayPayloadCodec.decode(GatewayAgentWaitResult.self, from: ok.payload)
        #expect(decoded.runID == "run-7")
        #expect(decoded.sessionKey == "main")

        let invalid = await server.handle(Self.frame("sessions.abort", params: ["key": AnyCodable(42)]))
        #expect(invalid.error?.errorCode == .invalidRequest)
        #expect(invalid.error?.message.hasPrefix("invalid sessions.abort params") == true)
    }

    @Test
    func typedErrorsMapToUpstreamErrorShapes() async throws {
        let (server, root) = try self.makeServer(named: "typed-errors")
        defer { try? FileManager.default.removeItem(at: root) }

        await server.register(method: "sdk.approval") { _ in
            throw GatewayMethodError.approvalNotFound("approval expired")
        }
        await server.register(method: "sdk.retry") { _ in
            throw GatewayMethodError.unavailable(
                "warming up",
                retryable: true,
                retryAfterMs: 250,
                details: AnyCodable(["reason": AnyCodable(GATEWAY_STARTUP_UNAVAILABLE_REASON)])
            )
        }
        await server.register(method: "sdk.config") { _ in
            throw OpenClawCoreError.invalidConfiguration("bad input")
        }
        await server.register(method: "sdk.other") { _ in
            throw CancellationError()
        }

        let approval = await server.handle(Self.frame("sdk.approval", params: [:]))
        #expect(approval.error?.errorCode == .approvalNotFound)
        #expect(approval.error?.message == "approval expired")

        let retry = try #require(await server.handle(Self.frame("sdk.retry", params: [:])).error)
        #expect(retry.errorCode == .unavailable)
        #expect(retry.retryable == true)
        #expect(retry.retryafterms == 250)
        #expect(retry.isStartupUnavailable)
        #expect(retry.startupRetryAfterMs == 250)

        let config = await server.handle(Self.frame("sdk.config", params: [:]))
        #expect(config.error?.errorCode == .invalidRequest)

        let other = await server.handle(Self.frame("sdk.other", params: [:]))
        #expect(other.error?.errorCode == .unavailable)
    }

    @Test
    func resolversServeDynamicMethodsBeforeUnknownFallback() async throws {
        let (server, root) = try self.makeServer(named: "resolvers")
        defer { try? FileManager.default.removeItem(at: root) }

        await server.addMethodResolver { method in
            guard method == "plugin.demo.echo" else { return nil }
            return { request in AnyCodable(request.params) }
        }
        let echoed = await server.handle(Self.frame("plugin.demo.echo", params: ["value": AnyCodable(3)]))
        #expect(echoed.ok == true)
        #expect(echoed.payload == AnyCodable(["value": AnyCodable(3)]))

        let unknown = await server.handle(Self.frame("plugin.demo.missing", params: [:]))
        #expect(unknown.error?.errorCode == .invalidRequest)
    }

    @Test
    func scopeChecksFollowUpstreamOperatorImplications() async throws {
        let (server, root) = try self.makeServer(named: "scopes")
        defer { try? FileManager.default.removeItem(at: root) }

        let reader = GatewayConnectionContext(role: "operator", scopes: ["operator.read"], clientID: GatewayClientID.iosApp.rawValue)
        let listed = await server.handle(Self.frame("sessions.list", params: [:]), connection: reader)
        #expect(listed.ok == true)

        let denied = try #require(await server.handle(
            Self.frame("secrets.store.set", params: ["name": AnyCodable("API_KEY"), "value": AnyCodable("x"), "kind": AnyCodable("secret")]),
            connection: reader
        ).error)
        #expect(denied.errorCode == .forbidden)
        #expect(denied.message == "missing scope: operator.admin")
        guard case .missingScope(let details)? = denied.typedDetails else {
            Issue.record("Expected MISSING_SCOPE details")
            return
        }
        #expect(details.missingscope == "operator.admin")
        #expect(details.requiredscopes == ["operator.admin"])

        let node = GatewayConnectionContext(role: "node", scopes: [])
        let nodeCallingOperator = await server.handle(Self.frame("sessions.list", params: [:]), connection: node)
        #expect(nodeCallingOperator.error?.errorCode == .invalidRequest)
        #expect(nodeCallingOperator.error?.message == "unauthorized role: node")
        let nodeMethod = await server.handle(Self.frame("node.invoke.result", params: [:]), connection: node)
        #expect(nodeMethod.error?.message.hasPrefix("unauthorized role") != true)
        let operatorCallingNode = await server.handle(Self.frame("node.invoke.result", params: [:]))
        #expect(operatorCallingNode.error?.message == "unauthorized role: operator")
        let unscopedHealth = await server.handle(Self.frame("health", params: [:]), connection: GatewayConnectionContext(role: "node"))
        #expect(unscopedHealth.error?.errorCode == .unavailable)

        let writer = GatewayConnectionContext(scopes: ["operator.write"])
        #expect(writer.allows(scope: "operator.read"))
        #expect(writer.allows(scope: "operator.talk"))
        #expect(writer.allows(scope: "operator.sessions.read"))
        #expect(writer.allows(scope: "operator.admin") == false)
        #expect(GatewayConnectionContext(scopes: ["operator.read"]).allows(scope: "operator.sessions.read"))
        #expect(GatewayConnectionContext(scopes: ["operator.admin"]).allows(scope: "operator.pairing"))
        #expect(GatewayConnectionContext(scopes: ["operator.admin"]).allows(scope: "node") == false)
        #expect(GatewayConnectionContext(role: "node", scopes: []).allows(scope: "node"))
        #expect(GatewayConnectionContext(role: "node", scopes: ["operator.admin"]).allows(scope: "operator.read") == false)
        #expect(GatewayConnectionContext(scopes: []).allows(scope: "dynamic"))

        let connect = ConnectParams(
            minprotocol: 4,
            maxprotocol: 4,
            client: [
                "id": AnyCodable("openclaw-ios"),
                "mode": AnyCodable("ui"),
                "version": AnyCodable("2026.3.0"),
                "platform": AnyCodable("ios"),
            ],
            role: "operator",
            scopes: ["operator.read"]
        )
        let context = GatewayConnectionContext(connect: connect, connectionID: "conn-1", deviceID: "device-1")
        #expect(context.clientID == "openclaw-ios")
        #expect(context.clientMode == "ui")
        #expect(context.platform == "ios")
        #expect(context.deviceID == "device-1")
        #expect(context.scopes == ["operator.read"])
    }

    // MARK: - Events

    @Test
    func handlersEmitEventsToSubscribersAndLoopbackClients() async throws {
        let (server, root) = try self.makeServer(named: "events")
        defer { try? FileManager.default.removeItem(at: root) }

        await server.register(method: "sdk.notify") { request in
            await request.events.emit(.sessionsChanged, payload: AnyCodable(["key": AnyCodable("main")]))
            return nil
        }

        let stream = await server.events()
        var iterator = stream.makeAsyncIterator()
        let response = await server.handle(Self.frame("sdk.notify", params: [:]))
        #expect(response.ok == true)
        #expect(response.payload == nil)
        let frame = await iterator.next()
        #expect(frame?.event == "sessions.changed")
        #expect(frame?.seq == 1)
        #expect(frame?.payload == AnyCodable(["key": AnyCodable("main")]))

        let recorder = EventRecorder()
        let client = GatewayClient(
            socketFactory: { LoopbackGatewaySocket(server: server) },
            onEvent: { event in await recorder.record(event) }
        )
        try await client.connect(to: GatewayEndpoint(url: URL(string: "ws://127.0.0.1:18789")!))
        _ = try await client.send(method: "sdk.notify")
        let delivered = await recorder.waitForEvents(count: 1)
        await client.disconnect()
        #expect(delivered.first?.event == "sessions.changed")
        #expect(delivered.first?.seq == 2)
    }

    // MARK: - Built-in handlers

    @Test
    func secretsStoreRoundTripsUpstreamShapes() async throws {
        let (server, root) = try self.makeServer(named: "secrets-store")
        defer { try? FileManager.default.removeItem(at: root) }

        let admin = GatewayConnectionContext(scopes: ["operator.admin"], clientID: "openclaw-macos", displayName: "Ada's Mac")
        let setEnv = await server.handle(
            Self.frame("secrets.store.set", params: ["name": AnyCodable("REGION"), "value": AnyCodable("eu-west-1"), "kind": AnyCodable("env")]),
            connection: admin
        )
        let mutation = try GatewayPayloadCodec.decode(SecretsStoreMutationResult.self, from: setEnv.payload)
        #expect(mutation.ok == true)
        #expect(mutation.reloaded == false)

        _ = await server.handle(Self.frame("secrets.store.set", params: [
            "name": AnyCodable("OPENAI_API_KEY"),
            "value": AnyCodable("sk-test"),
            "kind": AnyCodable("secret"),
            "allowedHosts": AnyCodable(["api.openai.com"]),
        ]))
        _ = await server.handle(Self.frame("secrets.set", params: ["key": AnyCodable("legacy"), "value": AnyCodable("v")]))

        let listed = await server.handle(Self.frame("secrets.store.list", params: [:]))
        let result = try GatewayPayloadCodec.decode(SecretsStoreListResult.self, from: listed.payload)
        #expect(result.entries.count == 2)
        for entry in result.entries {
            switch entry {
            case .env(let env):
                #expect(env.name == "REGION")
                #expect(env.value == "eu-west-1")
                #expect(env.scopekind == "team")
                #expect(env.updatedby == "Ada's Mac")
                #expect(env.createdatms > 0)
            case .secret(let secret):
                #expect(secret.name == "OPENAI_API_KEY")
                #expect(secret.allowedhosts == ["api.openai.com"])
                #expect(secret.updatedby == "gateway-client")
            }
        }
        let rawEntries = listed.payload?.dictionaryValue?["entries"]?.arrayValue ?? []
        #expect(rawEntries.allSatisfy { $0.dictionaryValue?["kind"] == AnyCodable("env") || $0.dictionaryValue?["value"] == nil })

        let legacyList = try GatewayPayloadCodec.decode(
            GatewaySecretsListResult.self,
            from: await server.handle(Self.frame("secrets.list", params: [:])).payload
        )
        #expect(legacyList.secrets.map(\.key) == ["OPENAI_API_KEY", "REGION", "legacy"])

        let invalidName = await server.handle(Self.frame("secrets.store.set", params: [
            "name": AnyCodable("lowercase"), "value": AnyCodable("x"), "kind": AnyCodable("env"),
        ]))
        #expect(invalidName.error?.errorCode == .invalidRequest)
        let invalidKind = await server.handle(Self.frame("secrets.store.set", params: [
            "name": AnyCodable("VALID"), "value": AnyCodable("x"), "kind": AnyCodable("file"),
        ]))
        #expect(invalidKind.error?.errorCode == .invalidRequest)
        let tooLarge = await server.handle(Self.frame("secrets.store.set", params: [
            "name": AnyCodable("BIG"), "value": AnyCodable(String(repeating: "x", count: 64 * 1024 + 1)), "kind": AnyCodable("env"),
        ]))
        #expect(tooLarge.error?.errorCode == .invalidRequest)

        let deleted = await server.handle(Self.frame("secrets.store.delete", params: ["name": AnyCodable("REGION")]))
        #expect(deleted.ok == true)
        let afterDelete = try GatewayPayloadCodec.decode(
            SecretsStoreListResult.self,
            from: await server.handle(Self.frame("secrets.store.list", params: [:])).payload
        )
        #expect(afterDelete.entries.count == 1)
    }

    @Test
    func secretVaultPersistsMetadataAndReadsLegacyIndexes() async throws {
        let root = try Self.makeTempDirectory(named: "secret-vault-metadata")
        defer { try? FileManager.default.removeItem(at: root) }

        let indexURL = root.appendingPathComponent("secret-index.json")
        try Data(#"{"version":1,"keys":["legacy"]}"#.utf8).write(to: indexURL)
        let credentials = FileCredentialStore(fileURL: root.appendingPathComponent("credentials.json"))
        let vault = GatewaySecretVault(credentialStore: credentials, indexURL: indexURL)
        #expect(await vault.listSecretKeys() == ["legacy"])
        #expect(await vault.metadata(for: "legacy")?.kind == .secret)

        try await vault.setSecret("value", for: "TOKEN", kind: .env, allowedHosts: ["ignored.example"], updatedBy: "tester")
        let reloaded = GatewaySecretVault(credentialStore: credentials, indexURL: indexURL)
        let metadata = try #require(await reloaded.metadata(for: "TOKEN"))
        #expect(metadata.kind == .env)
        #expect(metadata.allowedHosts == nil)
        #expect(metadata.updatedBy == "tester")
        #expect(try await reloaded.loadSecret(for: "TOKEN") == "value")
        #expect(await reloaded.listSecretKeys() == ["TOKEN", "legacy"])
    }

    @Test
    func builtinHandlersAcceptUpstreamWireShapes() async throws {
        let root = try Self.makeTempDirectory(named: "upstream-wire")
        defer { try? FileManager.default.removeItem(at: root) }

        let captured = RequestRecorder()
        let server = GatewayServer(
            sessionStore: SessionStore(fileURL: root.appendingPathComponent("sessions.json")),
            secretVault: GatewaySecretVault(credentialStore: FileCredentialStore(fileURL: root.appendingPathComponent("credentials.json"))),
            handlers: GatewayServerHandlers(
                runAgent: { params in
                    await captured.record(params)
                    let runID = "run-\(params.sessionKey)"
                    return GatewayAgentExecution(
                        runID: runID,
                        task: Task { GatewayAgentWaitResult(runID: runID, status: "ok", sessionKey: params.sessionKey, output: params.message) }
                    )
                },
                listModels: {
                    [GatewayModelCatalogEntry(providerID: "openai", modelID: "gpt-5.5", displayName: "GPT-5.5", api: "responses")]
                }
            )
        )

        // Upstream AgentParams: message + idempotencyKey, timeout in seconds, no legacy sessionKey.
        let accepted = await server.handle(Self.frame("agent", params: [
            "message": AnyCodable("hello"),
            "idempotencyKey": AnyCodable("idem-1"),
            "agentId": AnyCodable("main"),
            "provider": AnyCodable("openai"),
            "model": AnyCodable("gpt-5.5"),
            "timeout": AnyCodable(30),
        ]))
        #expect(accepted.payload?.dictionaryValue?["runId"] == AnyCodable("run-main"))
        #expect(accepted.payload?.dictionaryValue?["runID"] == nil)
        let upstreamRequest = try #require(await captured.last)
        #expect(upstreamRequest.sessionKey == "main")
        #expect(upstreamRequest.message == "hello")
        #expect(upstreamRequest.modelProviderID == "openai")
        #expect(upstreamRequest.modelID == "gpt-5.5")
        #expect(upstreamRequest.timeoutMs == 30_000)

        // Legacy request enriched with upstream-only keys.
        _ = await server.handle(Self.frame("agent.run", params: [
            "sessionKey": AnyCodable("legacy"),
            "prompt": AnyCodable("hi"),
            "message": AnyCodable("hi"),
            "idempotencyKey": AnyCodable("idem-2"),
            "model": AnyCodable("gpt-5.5-mini"),
        ]))
        #expect(await captured.last?.sessionKey == "legacy")
        #expect(await captured.last?.modelID == "gpt-5.5-mini")

        let missing = await server.handle(Self.frame("agent", params: ["idempotencyKey": AnyCodable("idem-3")]))
        #expect(missing.error?.errorCode == .invalidRequest)

        // agent.wait accepts the upstream `runId` key and the legacy `runID` key.
        let upstreamWait = await server.handle(Self.frame("agent.wait", params: ["runId": AnyCodable("run-main"), "timeoutMs": AnyCodable(1_000)]))
        #expect(upstreamWait.payload?.dictionaryValue?["status"] == AnyCodable("ok"))
        #expect(upstreamWait.payload?.dictionaryValue?["runId"] == AnyCodable("run-main"))
        let legacyWait = await server.handle(Self.frame("agent.wait", params: ["runID": AnyCodable("run-legacy")]))
        #expect(try GatewayPayloadCodec.decode(GatewayAgentWaitResult.self, from: legacyWait.payload).output == "hi")

        // sessions.patch accepts upstream `agentId`/`model`/`fastMode` and null clears.
        _ = await server.handle(Self.frame("sessions.patch", params: [
            "key": AnyCodable("main"),
            "agentId": AnyCodable("worker"),
            "model": AnyCodable("openai/gpt-5.5"),
            "label": AnyCodable("Main"),
            "fastMode": AnyCodable(true),
        ]))
        let patched = try GatewayPayloadCodec.decode(
            GatewaySessionMutationResult.self,
            from: await server.handle(Self.frame("sessions.patch", params: [
                "key": AnyCodable("main"),
                "label": AnyCodable.nullValue,
            ])).payload
        )
        #expect(patched.session?.agentID == "worker")
        #expect(patched.session?.modelOverride == "openai/gpt-5.5")
        #expect(patched.session?.label == nil)

        // models.list rows decode with both the legacy and the upstream result models.
        let models = await server.handle(Self.frame("models.list", params: [:]))
        let legacyModels = try GatewayPayloadCodec.decode(GatewayModelsListResult.self, from: models.payload)
        let upstreamModels = try GatewayPayloadCodec.decode(ModelsListResult.self, from: models.payload)
        #expect(legacyModels.models.first?.providerID == "openai")
        #expect(upstreamModels.models.first?.id == "gpt-5.5")
        #expect(upstreamModels.models.first?.name == "GPT-5.5")
        #expect(upstreamModels.models.first?.provider == "openai")
    }

    @Test
    func supportedAndAdvertisedMethodsReflectTheTable() async throws {
        let (server, root) = try self.makeServer(named: "advertised")
        defer { try? FileManager.default.removeItem(at: root) }

        let supported = await server.supportedMethods()
        #expect(supported == supported.sorted())
        #expect(Set(supported).isSuperset(of: GatewayServer.sdkExtensionMethods))
        #expect(Set(supported).isSuperset(of: ["agent", "agent.wait", "sessions.list", "sessions.get", "models.list", "secrets.store.list"]))

        let advertised = await server.advertisedMethods()
        #expect(advertised.contains("sessions.list"))
        #expect(advertised.contains("sessions.get") == false)
        #expect(await server.methodDescriptor(for: "agent.run")?.since == "sdk")
        #expect(await server.methodDescriptor(for: "tasks.list")?.scope == "operator.read")
        #expect(await server.methodDescriptor(for: "nope") == nil)
    }

    @Test
    func transportRetriesStartupUnavailableResponses() async throws {
        let (server, root) = try self.makeServer(named: "startup-retry")
        defer { try? FileManager.default.removeItem(at: root) }

        let attempts = AttemptCounter()
        await server.register(method: "sdk.startup") { _ in
            if await attempts.increment() < 3 {
                throw GatewayMethodError.unavailable(
                    "gateway starting",
                    retryable: true,
                    retryAfterMs: 1,
                    details: AnyCodable(["reason": AnyCodable(GATEWAY_STARTUP_UNAVAILABLE_REASON)])
                )
            }
            return AnyCodable(["ok": AnyCodable(true)])
        }

        let client = GatewayClient(socketFactory: { LoopbackGatewaySocket(server: server) })
        try await client.connect(to: GatewayEndpoint(url: URL(string: "ws://127.0.0.1:18789")!))
        let response = try await client.send(method: "sdk.startup")
        #expect(response.ok == true)
        #expect(await attempts.value == 3)
        await client.disconnect()

        let impatient = GatewayClient(socketFactory: { LoopbackGatewaySocket(server: server) }, startupUnavailableRetryLimit: 0)
        try await impatient.connect(to: GatewayEndpoint(url: URL(string: "ws://127.0.0.1:18789")!))
        await attempts.reset()
        do {
            let _: EmptyPayload = try await impatient.request("sdk.startup")
            Issue.record("Expected a startup-unavailable error")
        } catch GatewayTransportError.remote(let shape) {
            #expect(shape.isStartupUnavailable)
            #expect(shape.startupRetryAfterMs == 100)
        }
        await impatient.disconnect()
    }

    // MARK: - Helpers

    private func makeServer(named name: String) throws -> (GatewayServer, URL) {
        let root = try Self.makeTempDirectory(named: name)
        let server = GatewayServer(
            sessionStore: SessionStore(fileURL: root.appendingPathComponent("sessions.json")),
            secretVault: GatewaySecretVault(
                credentialStore: FileCredentialStore(fileURL: root.appendingPathComponent("credentials.json")),
                indexURL: root.appendingPathComponent("secret-index.json")
            )
        )
        return (server, root)
    }

    private static func frame(_ method: String, params: [String: AnyCodable]) -> RequestFrame {
        RequestFrame(type: "req", id: UUID().uuidString, method: method, params: AnyCodable(params))
    }

    private static func makeTempDirectory(named name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gateway-registry-\(name)", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

private actor EventRecorder {
    private var events: [EventFrame] = []

    func record(_ event: EventFrame) {
        self.events.append(event)
    }

    func waitForEvents(count: Int) async -> [EventFrame] {
        for _ in 0..<200 where self.events.count < count {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return self.events
    }
}

private actor RequestRecorder {
    private(set) var last: GatewayAgentRequest?

    func record(_ request: GatewayAgentRequest) {
        self.last = request
    }
}

private actor AttemptCounter {
    private(set) var value = 0

    func increment() -> Int {
        self.value += 1
        return self.value
    }

    func reset() {
        self.value = 0
    }
}
