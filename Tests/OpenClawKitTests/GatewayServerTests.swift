import Foundation
import Testing
@testable import OpenClawKit

@Suite("Gateway server")
struct GatewayServerTests {
    final class BrowserRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var lastRequest: GatewayBrowserRequestParams?

        func record(_ request: GatewayBrowserRequestParams) {
            self.lock.lock()
            self.lastRequest = request
            self.lock.unlock()
        }
    }

    struct StaticProvider: ModelProvider {
        let id: String
        let text: String

        func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
            _ = request
            return ModelGenerationResponse(text: self.text, providerID: self.id, modelID: "static-model")
        }
    }

    @Test
    func gatewayServerTracksSessionsSecretsAndBrowserGuards() async throws {
        let root = try self.makeTempDirectory(named: "gateway-server-core")
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionStore = SessionStore(fileURL: root.appendingPathComponent("sessions.json"))
        let credentialStore = FileCredentialStore(fileURL: root.appendingPathComponent("credentials.json"))
        let secretVault = GatewaySecretVault(
            credentialStore: credentialStore,
            indexURL: root.appendingPathComponent("secret-index.json")
        )
        let recorder = BrowserRecorder()
        let server = GatewayServer(
            sessionStore: sessionStore,
            secretVault: secretVault,
            handlers: GatewayServerHandlers(
                browserRequest: { params in
                    recorder.record(params)
                    return GatewayBrowserResponse(
                        status: 200,
                        body: AnyCodable([
                            "method": AnyCodable(params.method),
                            "path": AnyCodable(params.path),
                        ])
                    )
                }
            )
        )

        let patched = try await self.request(
            server,
            method: "sessions.patch",
            params: GatewaySessionPatchParams(
                key: "main",
                label: "Primary Session",
                modelOverride: "openai/gpt-5.4",
                thinkingLevel: "adaptive",
                sendPolicy: "allow"
            ),
            as: GatewaySessionMutationResult.self
        )
        #expect(patched.ok == true)
        #expect(patched.session?.label == "Primary Session")
        #expect(patched.session?.thinkingLevel == "adaptive")
        #expect(patched.session?.sendPolicy == "allow")

        let listed = try await self.request(server, method: "sessions.list", as: GatewaySessionListResult.self)
        #expect(listed.sessions.count == 1)
        #expect(listed.sessions.first?.key == "main")

        let fetched = try await self.request(
            server,
            method: "sessions.get",
            params: GatewaySessionGetParams(key: "main"),
            as: GatewaySessionGetResult.self
        )
        #expect(fetched.session?.modelOverride == "openai/gpt-5.4")

        let reset = try await self.request(
            server,
            method: "sessions.reset",
            params: GatewaySessionKeyParams(key: "main"),
            as: GatewaySessionMutationResult.self
        )
        #expect(reset.session?.label == nil)
        #expect(reset.session?.modelOverride == nil)

        let setSecret = try await self.request(
            server,
            method: "secrets.set",
            params: GatewaySecretSetParams(key: "openai", value: "top-secret"),
            as: GatewaySecretMutationResult.self
        )
        #expect(setSecret.key == "openai")

        let secretList = try await self.request(server, method: "secrets.list", as: GatewaySecretsListResult.self)
        #expect(secretList.secrets.map(\.key) == ["openai"])

        let deletedSecret = try await self.request(
            server,
            method: "secrets.delete",
            params: GatewaySecretDeleteParams(key: "openai"),
            as: GatewaySecretMutationResult.self
        )
        #expect(deletedSecret.deleted == true)

        let browserResult = try await self.request(
            server,
            method: "browser.request",
            params: GatewayBrowserRequestParams(
                method: "get",
                path: "/tabs",
                query: ["profile": "default"],
                workspaceRoot: root.path,
                spawnedWorkspaceRoot: root.appendingPathComponent("spawned").path
            ),
            as: GatewayBrowserResponse.self
        )
        #expect(browserResult.status == 200)
        #expect(recorder.lastRequest?.method == "GET")
        #expect(recorder.lastRequest?.workspaceRoot == nil)
        #expect(recorder.lastRequest?.spawnedWorkspaceRoot == nil)

        let blocked = await self.rawRequest(
            server,
            method: "browser.request",
            params: GatewayBrowserRequestParams(method: "POST", path: "/profiles")
        )
        #expect(blocked.ok == false)
        #expect(blocked.error?.code == .invalidRequest)

        let unsupported = await self.rawRequest(server, method: "unsupported.method", params: EmptyPayload())
        #expect(unsupported.ok == false)
        #expect(unsupported.error?.code == .invalidRequest)

        let deletedSession = try await self.request(
            server,
            method: "sessions.delete",
            params: GatewaySessionKeyParams(key: "main"),
            as: GatewaySessionMutationResult.self
        )
        #expect(deletedSession.deleted == true)
    }

    @Test
    func gatewayServerSupportsAgentRunWaitTimeoutAndCleanup() async throws {
        let root = try self.makeTempDirectory(named: "gateway-server-agent")
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionStore = SessionStore(fileURL: root.appendingPathComponent("sessions.json"))
        let secretVault = GatewaySecretVault(
            credentialStore: FileCredentialStore(fileURL: root.appendingPathComponent("credentials.json"))
        )
        let server = GatewayServer(
            sessionStore: sessionStore,
            secretVault: secretVault,
            handlers: GatewayServerHandlers(
                runAgent: { params in
                    let runID = UUID().uuidString
                    let sleepMs = params.timeoutMs ?? 0
                    return GatewayAgentExecution(
                        runID: runID,
                        task: Task {
                            if sleepMs > 0 {
                                try await Task.sleep(nanoseconds: UInt64(sleepMs) * 1_000_000)
                            }
                            return GatewayAgentWaitResult(
                                runID: runID,
                                status: "ok",
                                sessionKey: params.sessionKey,
                                output: params.prompt ?? params.message
                            )
                        }
                    )
                }
            )
        )

        let accepted = try await self.request(
            server,
            method: "agent.run",
            params: GatewayAgentRequest(sessionKey: "main", prompt: "first"),
            as: GatewayAgentAccepted.self
        )
        #expect(!accepted.runID.isEmpty)

        let waited = try await self.request(
            server,
            method: "agent.wait",
            params: GatewayAgentWaitParams(runID: accepted.runID, timeoutMs: 5_000),
            as: GatewayAgentWaitResult.self
        )
        #expect(waited.status == "ok")
        #expect(waited.output == "first")

        let missingAfterCleanup = await self.rawRequest(
            server,
            method: "agent.wait",
            params: GatewayAgentWaitParams(runID: accepted.runID, timeoutMs: 10)
        )
        #expect(missingAfterCleanup.ok == false)
        #expect(missingAfterCleanup.error?.code == .unavailable)

        let slow = try await self.request(
            server,
            method: "agent",
            params: GatewayAgentRequest(sessionKey: "main", prompt: "slow", timeoutMs: 80),
            as: GatewayAgentAccepted.self
        )

        let timedOut = try await self.request(
            server,
            method: "agent.wait",
            params: GatewayAgentWaitParams(runID: slow.runID, timeoutMs: 1),
            as: GatewayAgentWaitResult.self
        )
        #expect(timedOut.status == "timeout")

        let eventuallyCompleted = try await self.request(
            server,
            method: "agent.wait",
            params: GatewayAgentWaitParams(runID: slow.runID, timeoutMs: 1_000),
            as: GatewayAgentWaitResult.self
        )
        #expect(eventuallyCompleted.status == "ok")
        #expect(eventuallyCompleted.output == "slow")
    }

    @Test
    func gatewayServerCoversValidationDefaultsAndFallbackErrors() async throws {
        let root = try self.makeTempDirectory(named: "gateway-server-validation")
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionStore = SessionStore(fileURL: root.appendingPathComponent("sessions.json"))
        let credentialStore = FileCredentialStore(fileURL: root.appendingPathComponent("credentials.json"))
        let secretVault = GatewaySecretVault(credentialStore: credentialStore)
        let defaultServer = GatewayServer(
            sessionStore: sessionStore,
            secretVault: secretVault,
            defaultAgentID: "   "
        )

        let fallbackSession = try await self.request(
            defaultServer,
            method: "sessions.patch",
            params: GatewaySessionPatchParams(key: "fallback"),
            as: GatewaySessionMutationResult.self
        )
        #expect(fallbackSession.session?.agentID == "main")

        let invalidSessionKey = await self.rawRequest(
            defaultServer,
            method: "sessions.patch",
            params: GatewaySessionPatchParams(key: "   ")
        )
        #expect(invalidSessionKey.ok == false)
        #expect(invalidSessionKey.error?.code == .invalidRequest)

        let invalidPayload = await defaultServer.handle(
            RequestFrame(
                type: "req",
                id: UUID().uuidString,
                method: "sessions.get",
                params: AnyCodable(["key": AnyCodable(1)])
            )
        )
        #expect(invalidPayload.ok == false)
        #expect(invalidPayload.error?.code == .invalidRequest)

        let missingReset = try await self.request(
            defaultServer,
            method: "sessions.reset",
            params: GatewaySessionKeyParams(key: "missing"),
            as: GatewaySessionMutationResult.self
        )
        #expect(missingReset.session == nil)

        let missingDelete = try await self.request(
            defaultServer,
            method: "sessions.delete",
            params: GatewaySessionKeyParams(key: "missing"),
            as: GatewaySessionMutationResult.self
        )
        #expect(missingDelete.deleted == false)

        let unavailableModels = await self.rawRequest(defaultServer, method: "models.list", params: EmptyPayload())
        #expect(unavailableModels.ok == false)
        #expect(unavailableModels.error?.code == .unavailable)

        let unavailableSkills = await self.rawRequest(defaultServer, method: "skills.list", params: EmptyPayload())
        #expect(unavailableSkills.ok == false)
        #expect(unavailableSkills.error?.code == .unavailable)

        let unavailableInvoke = await self.rawRequest(
            defaultServer,
            method: "skills.invoke",
            params: GatewaySkillInvokeParams(name: "hello", input: "world")
        )
        #expect(unavailableInvoke.ok == false)
        #expect(unavailableInvoke.error?.code == .unavailable)

        let unavailableAgent = await self.rawRequest(
            defaultServer,
            method: "agent.run",
            params: GatewayAgentRequest(sessionKey: "fallback", prompt: "hello")
        )
        #expect(unavailableAgent.ok == false)
        #expect(unavailableAgent.error?.code == .unavailable)

        let unavailableBrowser = await self.rawRequest(
            defaultServer,
            method: "browser.request",
            params: GatewayBrowserRequestParams(method: "GET", path: "/ok")
        )
        #expect(unavailableBrowser.ok == false)
        #expect(unavailableBrowser.error?.code == .unavailable)

        let invalidBrowserMethod = await self.rawRequest(
            GatewayServer(
                sessionStore: sessionStore,
                secretVault: secretVault,
                handlers: GatewayServerHandlers(
                    browserRequest: { _ in GatewayBrowserResponse(status: 200) }
                )
            ),
            method: "browser.request",
            params: GatewayBrowserRequestParams(method: "PUT", path: "/ok")
        )
        #expect(invalidBrowserMethod.ok == false)
        #expect(invalidBrowserMethod.error?.code == .invalidRequest)

        let invalidBrowserPath = await self.rawRequest(
            GatewayServer(
                sessionStore: sessionStore,
                secretVault: secretVault,
                handlers: GatewayServerHandlers(
                    browserRequest: { _ in GatewayBrowserResponse(status: 200) }
                )
            ),
            method: "browser.request",
            params: GatewayBrowserRequestParams(method: "GET", path: "missing-slash")
        )
        #expect(invalidBrowserPath.ok == false)
        #expect(invalidBrowserPath.error?.code == .invalidRequest)

        let permissiveProfileRead = try await self.request(
            GatewayServer(
                sessionStore: sessionStore,
                secretVault: secretVault,
                handlers: GatewayServerHandlers(
                    browserRequest: { params in
                        GatewayBrowserResponse(
                            status: 200,
                            body: AnyCodable(["path": AnyCodable(params.path)])
                        )
                    }
                )
            ),
            method: "browser.request",
            params: GatewayBrowserRequestParams(method: "GET", path: "/profiles/default"),
            as: GatewayBrowserResponse.self
        )
        #expect(permissiveProfileRead.status == 200)

        let unknownErrorServer = GatewayServer(
            sessionStore: sessionStore,
            secretVault: secretVault,
            handlers: GatewayServerHandlers(
                listModels: {
                    throw NSError(domain: "GatewayServerTests", code: 9)
                }
            )
        )
        let unknownErrorResponse = await self.rawRequest(unknownErrorServer, method: "models.list", params: EmptyPayload())
        #expect(unknownErrorResponse.ok == false)
        #expect(unknownErrorResponse.error?.code == .unavailable)
    }

    @Test
    func gatewayServerNormalizesSessionControlsAndAgentWaitWithoutTimeout() async throws {
        let root = try self.makeTempDirectory(named: "gateway-server-controls")
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionStore = SessionStore(fileURL: root.appendingPathComponent("sessions.json"))
        let credentialStore = FileCredentialStore(fileURL: root.appendingPathComponent("credentials.json"))
        let server = GatewayServer(
            sessionStore: sessionStore,
            secretVault: GatewaySecretVault(credentialStore: credentialStore),
            handlers: GatewayServerHandlers(
                runAgent: { params in
                    let runID = UUID().uuidString
                    return GatewayAgentExecution(
                        runID: runID,
                        task: Task {
                            if params.prompt == "explode" {
                                throw OpenClawCoreError.unavailable("boom")
                            }
                            return GatewayAgentWaitResult(
                                runID: runID,
                                status: params.prompt == "error" ? "error" : "ok",
                                sessionKey: params.sessionKey,
                                output: params.prompt,
                                error: params.prompt == "error" ? "provider failure" : nil
                            )
                        }
                    )
                }
            )
        )

        let patched = try await self.request(
            server,
            method: "sessions.patch",
            params: GatewaySessionPatchParams(
                key: "controls",
                agentID: "assistant",
                label: "   ",
                modelOverride: "  openai/gpt-5.4  ",
                thinkingLevel: "x-high",
                verboseLevel: "everything",
                reasoningLevel: "visible",
                responseUsage: "session",
                elevatedLevel: "approve",
                groupActivation: "mentions",
                sendPolicy: "deny",
                execHost: "gateway",
                execSecurity: "allow-list",
                execAsk: "on_miss",
                execNode: "  node-20  "
            ),
            as: GatewaySessionMutationResult.self
        )
        #expect(patched.session?.agentID == "assistant")
        #expect(patched.session?.label == nil)
        #expect(patched.session?.modelOverride == "openai/gpt-5.4")
        #expect(patched.session?.thinkingLevel == "xhigh")
        #expect(patched.session?.verboseLevel == "full")
        #expect(patched.session?.reasoningLevel == "on")
        #expect(patched.session?.responseUsage == "full")
        #expect(patched.session?.elevatedLevel == "ask")
        #expect(patched.session?.groupActivation == "mention")
        #expect(patched.session?.sendPolicy == "deny")
        #expect(patched.session?.execHost == "gateway")
        #expect(patched.session?.execSecurity == "allowlist")
        #expect(patched.session?.execAsk == "on-miss")
        #expect(patched.session?.execNode == "node-20")

        let sandboxPatch = try await self.request(
            server,
            method: "sessions.patch",
            params: GatewaySessionPatchParams(
                key: "controls",
                groupActivation: "always",
                execHost: "sandbox",
                execSecurity: "deny",
                execAsk: "off"
            ),
            as: GatewaySessionMutationResult.self
        )
        #expect(sandboxPatch.session?.groupActivation == "always")
        #expect(sandboxPatch.session?.execHost == "sandbox")
        #expect(sandboxPatch.session?.execSecurity == "deny")
        #expect(sandboxPatch.session?.execAsk == "off")

        let nodePatch = try await self.request(
            server,
            method: "sessions.patch",
            params: GatewaySessionPatchParams(
                key: "controls",
                execHost: "node",
                execSecurity: "full",
                execAsk: "always"
            ),
            as: GatewaySessionMutationResult.self
        )
        #expect(nodePatch.session?.execHost == "node")
        #expect(nodePatch.session?.execSecurity == "full")
        #expect(nodePatch.session?.execAsk == "always")

        let invalidPatch = try await self.request(
            server,
            method: "sessions.patch",
            params: GatewaySessionPatchParams(
                key: "controls",
                label: "Primary",
                groupActivation: "sometimes",
                sendPolicy: "maybe",
                execHost: "remote",
                execSecurity: "strict",
                execAsk: "later",
                execNode: "   "
            ),
            as: GatewaySessionMutationResult.self
        )
        #expect(invalidPatch.session?.label == "Primary")
        #expect(invalidPatch.session?.groupActivation == nil)
        #expect(invalidPatch.session?.sendPolicy == nil)
        #expect(invalidPatch.session?.execHost == nil)
        #expect(invalidPatch.session?.execSecurity == nil)
        #expect(invalidPatch.session?.execAsk == nil)
        #expect(invalidPatch.session?.execNode == nil)

        let completedRun = try await self.request(
            server,
            method: "agent.run",
            params: GatewayAgentRequest(sessionKey: "controls", prompt: "done"),
            as: GatewayAgentAccepted.self
        )
        let completedWait = try await self.request(
            server,
            method: "agent.wait",
            params: GatewayAgentWaitParams(runID: completedRun.runID),
            as: GatewayAgentWaitResult.self
        )
        #expect(completedWait.status == "ok")
        #expect(completedWait.output == "done")

        let erroredRun = try await self.request(
            server,
            method: "agent.run",
            params: GatewayAgentRequest(sessionKey: "controls", prompt: "error"),
            as: GatewayAgentAccepted.self
        )
        let erroredWait = try await self.request(
            server,
            method: "agent.wait",
            params: GatewayAgentWaitParams(runID: erroredRun.runID),
            as: GatewayAgentWaitResult.self
        )
        #expect(erroredWait.status == "error")
        #expect(erroredWait.error == "provider failure")

        let explodedRun = try await self.request(
            server,
            method: "agent.run",
            params: GatewayAgentRequest(sessionKey: "controls", prompt: "explode"),
            as: GatewayAgentAccepted.self
        )
        let explodedWait = await self.rawRequest(
            server,
            method: "agent.wait",
            params: GatewayAgentWaitParams(runID: explodedRun.runID)
        )
        #expect(explodedWait.ok == false)
        #expect(explodedWait.error?.code == .unavailable)
    }

    @Test
    func gatewaySecretVaultPersistsAndValidatesKeys() async throws {
        let root = try self.makeTempDirectory(named: "gateway-secret-vault")
        defer { try? FileManager.default.removeItem(at: root) }

        let credentialsURL = root.appendingPathComponent("credentials.json")
        let indexedVault = GatewaySecretVault(
            credentialStore: FileCredentialStore(fileURL: credentialsURL),
            indexURL: root.appendingPathComponent("metadata").appendingPathComponent("secret-index.json")
        )
        try await indexedVault.setSecret("secret", for: " openai ")
        #expect(await indexedVault.listSecretKeys() == ["openai"])

        let reloaded = GatewaySecretVault(
            credentialStore: FileCredentialStore(fileURL: credentialsURL),
            indexURL: root.appendingPathComponent("metadata").appendingPathComponent("secret-index.json")
        )
        #expect(await reloaded.listSecretKeys() == ["openai"])
        #expect(try await reloaded.deleteSecret(for: "openai") == true)
        #expect(try await reloaded.deleteSecret(for: "openai") == false)

        let ephemeral = GatewaySecretVault(
            credentialStore: FileCredentialStore(fileURL: root.appendingPathComponent("ephemeral.json"))
        )
        try await ephemeral.setSecret("value", for: "temp")
        #expect(await ephemeral.listSecretKeys() == ["temp"])
        #expect(try await ephemeral.deleteSecret(for: "temp") == true)

        do {
            try await ephemeral.setSecret("value", for: "   ")
            Issue.record("Expected empty secret key validation failure")
        } catch {
            #expect(String(describing: error).contains("must not be empty"))
        }
    }

    @Test
    func sdkGatewayServerSupportsCatalogSkillsAndRuntimeHandlers() async throws {
        let root = try self.makeTempDirectory(named: "gateway-server-sdk")
        defer { try? FileManager.default.removeItem(at: root) }

        let skillRoot = root.appendingPathComponent("skills").appendingPathComponent("hello")
        let skillFile = skillRoot.appendingPathComponent("SKILL.md")
        let scriptFile = skillRoot.appendingPathComponent("scripts").appendingPathComponent("hello.sh")
        try FileManager.default.createDirectory(at: scriptFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        #!/usr/bin/env sh
        printf 'skill:%s' "$1"
        """.write(to: scriptFile, atomically: true, encoding: .utf8)
        try """
        ---
        name: hello
        description: hello skill
        entrypoint: scripts/hello.sh
        ---

        Hello skill body.
        """.write(to: skillFile, atomically: true, encoding: .utf8)

        let router = ModelRouter()
        await router.register(StaticProvider(id: "openai", text: "runtime-output"))
        await router.register(StaticProvider(id: "github-copilot", text: "copilot-output"))
        try await router.setDefaultProviderID("openai")

        let runtime = EmbeddedAgentRuntime(modelRouter: router)
        let sessionStore = SessionStore(fileURL: root.appendingPathComponent("sessions.json"))
        let credentialStore = FileCredentialStore(fileURL: root.appendingPathComponent("credentials.json"))
        let server = OpenClawSDK.shared.makeGatewayServer(
            sessionStore: sessionStore,
            credentialStore: credentialStore,
            modelRouter: router,
            runtime: runtime,
            workspaceRoot: root
        )

        let client = GatewayClient(
            socketFactory: { LoopbackGatewaySocket(server: server) }
        )
        try await client.connect(to: GatewayEndpoint(url: URL(string: "ws://127.0.0.1:18789")!))
        defer {
            Task {
                await client.disconnect()
            }
        }

        let models: GatewayModelsListResult = try await client.request("models.list")
        let providerIDs = Set(models.models.map(\.providerID))
        #expect(providerIDs.contains("openai"))
        #expect(providerIDs.contains("github-copilot"))

        let skills: GatewaySkillsListResult = try await client.request("skills.list")
        #expect(skills.skills.map(\.name).contains("hello"))

        let invocation: GatewaySkillInvokeResult = try await client.request(
            "skills.invoke",
            params: GatewaySkillInvokeParams(name: "hello", input: "world")
        )
        #expect(invocation.output == "skill:world")

        let accepted: GatewayAgentAccepted = try await client.request(
            "agent.run",
            params: GatewayAgentRequest(
                sessionKey: "main",
                prompt: "ping",
                modelProviderID: "openai"
            )
        )
        let completed: GatewayAgentWaitResult = try await client.request(
            "agent.wait",
            params: GatewayAgentWaitParams(runID: accepted.runID, timeoutMs: 5_000)
        )
        #expect(completed.status == "ok")
        #expect(completed.output == "runtime-output")
    }

    private func rawRequest<P: Encodable>(
        _ server: GatewayServer,
        method: String,
        params: P
    ) async -> ResponseFrame {
        let payload = try? GatewayPayloadCodec.encode(params)
        return await server.handle(
            RequestFrame(
                type: "req",
                id: UUID().uuidString,
                method: method,
                params: payload
            )
        )
    }

    private func request<P: Encodable, T: Decodable>(
        _ server: GatewayServer,
        method: String,
        params: P,
        as type: T.Type = T.self
    ) async throws -> T {
        let response = await self.rawRequest(server, method: method, params: params)
        guard response.ok else {
            throw GatewayTransportError.remote(try #require(response.error))
        }
        return try GatewayPayloadCodec.decode(type, from: response.payload)
    }

    private func request<T: Decodable>(
        _ server: GatewayServer,
        method: String,
        as type: T.Type = T.self
    ) async throws -> T {
        try await self.request(server, method: method, params: EmptyPayload(), as: type)
    }

    private func makeTempDirectory(named name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
