import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import OpenClawKit

@Suite("Provider runtime auth")
struct ProviderRuntimeAuthTests {
    actor MockRuntimeAuthTransport: RuntimeAuthHTTPTransport {
        struct LoggedRequest: Sendable {
            var url: String
            var authorization: String?
            var body: String?
        }

        private var responsesByURL: [String: [HTTPResponseData]] = [:]
        private var loggedRequests: [LoggedRequest] = []

        func enqueue(url: String, response: HTTPResponseData) {
            self.responsesByURL[url, default: []].append(response)
        }

        func data(for request: URLRequest) async throws -> HTTPResponseData {
            let url = request.url?.absoluteString ?? ""
            self.loggedRequests.append(
                LoggedRequest(
                    url: url,
                    authorization: request.value(forHTTPHeaderField: "Authorization"),
                    body: request.httpBody.flatMap { String(data: $0, encoding: .utf8) }
                )
            )
            guard var queued = self.responsesByURL[url], !queued.isEmpty else {
                throw OpenClawCoreError.unavailable("No mock auth response queued for \(url)")
            }
            let next = queued.removeFirst()
            self.responsesByURL[url] = queued
            return next
        }

        func requests() -> [LoggedRequest] {
            self.loggedRequests
        }
    }

    actor MockProviderTransport: OpenAICompatibleHTTPTransport {
        private let body: Data
        private(set) var lastHost: String?
        private(set) var lastAuthorization: String?

        init(body: Data) {
            self.body = body
        }

        func data(for request: URLRequest) async throws -> HTTPResponseData {
            self.lastHost = request.url?.host
            self.lastAuthorization = request.value(forHTTPHeaderField: "Authorization")
            return HTTPResponseData(statusCode: 200, headers: [:], body: self.body)
        }

        func host() -> String? {
            self.lastHost
        }

        func authorization() -> String? {
            self.lastAuthorization
        }
    }

    @Test
    func qwenRuntimeAuthRefreshesExpiredOAuthCredential() async throws {
        let transport = MockRuntimeAuthTransport()
        await transport.enqueue(
            url: "https://chat.qwen.ai/api/v1/oauth2/token",
            response: HTTPResponseData(
                statusCode: 200,
                headers: [:],
                body: Data("""
                {
                  "access_token": "qwen-a2",
                  "refresh_token": "qwen-r2",
                  "expires_in": 3600
                }
                """.utf8)
            )
        )
        let resolver = RuntimeProviderAuthResolver(transport: transport, now: { 1_000_000 })

        let resolution = try await resolver.resolve(
            providerID: "qwen-portal",
            credential: .oauth(
                OAuthAuthProfileCredential(
                    provider: "qwen-portal",
                    accessToken: "qwen-a1",
                    refreshToken: "qwen-r1",
                    expires: 999_000,
                    email: "qwen@example.com"
                )
            )
        )

        #expect(resolution.persistCredential)
        if case .oauth(let credential) = resolution.credential {
            #expect(credential.accessToken == "qwen-a2")
            #expect(credential.refreshToken == "qwen-r2")
            #expect(credential.expires == 4_600_000)
            #expect(credential.clientID == "f0304373b74a44d2b584a3fb70ca9e56")
        } else {
            Issue.record("Expected refreshed OAuth credential")
        }

        let requests = await transport.requests()
        #expect(requests.count == 1)
        #expect(requests.first?.body?.contains("grant_type=refresh_token") == true)
    }

    @Test
    func githubCopilotRuntimeAuthExchangesGitHubTokenAndCachesResult() async throws {
        let transport = MockRuntimeAuthTransport()
        await transport.enqueue(
            url: "https://api.github.com/copilot_internal/v2/token",
            response: HTTPResponseData(
                statusCode: 200,
                headers: [:],
                body: Data("""
                {
                  "token": "copilot-token;proxy-ep=https://proxy.contoso.test;",
                  "expires_at": 7200
                }
                """.utf8)
            )
        )
        let resolver = RuntimeProviderAuthResolver(transport: transport, now: { 1_000_000 })
        let credential = AuthProfileCredential.token(
            TokenAuthProfileCredential(provider: "github-copilot", token: "ghu_123", email: "dev@example.com")
        )

        let first = try await resolver.resolve(providerID: "github-copilot", credential: credential)
        let second = try await resolver.resolve(providerID: "github-copilot", credential: credential)

        if case .token(let firstCredential) = first.credential {
            #expect(firstCredential.token == "copilot-token;proxy-ep=https://proxy.contoso.test;")
            #expect(firstCredential.expires == 7_200_000)
        } else {
            Issue.record("Expected exchanged token credential")
        }
        #expect(first.metadata["provider.baseURL"] == "https://api.contoso.test")
        #expect(second.metadata["provider.baseURL"] == "https://api.contoso.test")
        let requests = await transport.requests()
        #expect(requests.count == 1)
        #expect(requests.first?.authorization == "Bearer ghu_123")
    }

    @Test
    func routerWritesBackRefreshedQwenCredentialsBeforeRequest() async throws {
        let tempRoot = FileManager().temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let credentialStore = FileCredentialStore(fileURL: tempRoot.appendingPathComponent("credentials.json"))
        let authProfileStore = AuthProfileStore(
            fileURL: tempRoot.appendingPathComponent("profiles.json"),
            credentialStore: credentialStore
        )
        let profileID = "qwen-portal:work"
        try await authProfileStore.setCredential(
            .oauth(
                OAuthAuthProfileCredential(
                    provider: "qwen-portal",
                    accessToken: "qwen-a0",
                    refreshToken: "qwen-r1",
                    expires: 999_000
                )
            ),
            for: profileID
        )

        let authTransport = MockRuntimeAuthTransport()
        await authTransport.enqueue(
            url: "https://chat.qwen.ai/api/v1/oauth2/token",
            response: HTTPResponseData(
                statusCode: 200,
                headers: [:],
                body: Data("""
                {
                  "access_token": "qwen-a2",
                  "refresh_token": "qwen-r2",
                  "expires_in": 1800
                }
                """.utf8)
            )
        )
        let resolver = RuntimeProviderAuthResolver(transport: authTransport, now: { 1_000_000 })
        let providerTransport = MockProviderTransport(
            body: Data("""
            {
              "choices": [
                { "index": 0, "message": { "role": "assistant", "content": "hello from qwen" } }
              ],
              "model": "coder-model"
            }
            """.utf8)
        )
        let provider = QwenPortalModelProvider(
            configuration: ProviderServiceConfig(
                enabled: true,
                apiStyle: .openAICompletions,
                authMode: .oauthToken,
                modelID: "coder-model",
                baseURL: "https://portal.qwen.ai/v1",
                chatCompletionsPath: "chat/completions"
            ),
            transport: providerTransport
        )
        let router = ModelRouter(
            defaultProviderID: "qwen-portal",
            providers: [provider],
            authConfig: AuthConfig(
                profiles: [profileID: AuthProfileConfig(provider: "qwen-portal", mode: .oauth)],
                order: ["qwen-portal": [profileID]]
            ),
            authProfileStore: authProfileStore,
            runtimeAuthResolver: resolver
        )

        let response = try await router.generate(
            ModelGenerationRequest(sessionKey: "main", prompt: "hello", providerID: "qwen-portal")
        )

        #expect(response.text == "hello from qwen")
        #expect(await providerTransport.authorization() == "Bearer qwen-a2")
        let resolved = try await authProfileStore.resolvedCredential(for: profileID)
        if case .oauth(let credential)? = resolved {
            #expect(credential.accessToken == "qwen-a2")
            #expect(credential.refreshToken == "qwen-r2")
            #expect(credential.expires == 2_800_000)
        } else {
            Issue.record("Expected refreshed OAuth credential to be persisted")
        }
    }

    @Test
    func routerAppliesGitHubCopilotBaseURLOverrideDuringTokenExchange() async throws {
        let tempRoot = FileManager().temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let credentialStore = FileCredentialStore(fileURL: tempRoot.appendingPathComponent("credentials.json"))
        let authProfileStore = AuthProfileStore(
            fileURL: tempRoot.appendingPathComponent("profiles.json"),
            credentialStore: credentialStore
        )
        let profileID = "github-copilot:github"
        try await authProfileStore.setCredential(
            .token(
                TokenAuthProfileCredential(
                    provider: "github-copilot",
                    token: "ghu_123",
                    email: "dev@example.com"
                )
            ),
            for: profileID
        )

        let authTransport = MockRuntimeAuthTransport()
        await authTransport.enqueue(
            url: "https://api.github.com/copilot_internal/v2/token",
            response: HTTPResponseData(
                statusCode: 200,
                headers: [:],
                body: Data("""
                {
                  "token": "copilot-token;proxy-ep=https://proxy.contoso.test;",
                  "expires_at": 7200
                }
                """.utf8)
            )
        )
        let resolver = RuntimeProviderAuthResolver(transport: authTransport, now: { 1_000_000 })
        let providerTransport = MockProviderTransport(
            body: Data("""
            {
              "choices": [
                { "index": 0, "message": { "role": "assistant", "content": "hello from copilot" } }
              ],
              "model": "gpt-5"
            }
            """.utf8)
        )
        let provider = GitHubCopilotModelProvider(
            configuration: ProviderServiceConfig(
                enabled: true,
                apiStyle: .openAICompletions,
                authMode: .bearerToken,
                modelID: "gpt-5",
                baseURL: "https://api.githubcopilot.com",
                chatCompletionsPath: "chat/completions"
            ),
            transport: providerTransport
        )
        let router = ModelRouter(
            defaultProviderID: "github-copilot",
            providers: [provider],
            authConfig: AuthConfig(
                profiles: [profileID: AuthProfileConfig(provider: "github-copilot", mode: .token)],
                order: ["github-copilot": [profileID]]
            ),
            authProfileStore: authProfileStore,
            runtimeAuthResolver: resolver
        )

        let response = try await router.generate(
            ModelGenerationRequest(sessionKey: "main", prompt: "hello", providerID: "github-copilot")
        )

        #expect(response.text == "hello from copilot")
        #expect(await providerTransport.authorization() == "Bearer copilot-token;proxy-ep=https://proxy.contoso.test;")
        #expect(await providerTransport.host() == "api.contoso.test")
        let resolved = try await authProfileStore.resolvedCredential(for: profileID)
        if case .token(let credential)? = resolved {
            #expect(credential.token == "ghu_123")
            #expect(credential.expires == nil)
        } else {
            Issue.record("Expected stored GitHub token to remain unchanged")
        }
    }

    @Test
    func interactiveAuthCatalogIncludesBrowserAndDeviceCodeFlows() {
        let codex = InteractiveAuthFlowCatalog.descriptor(for: "openai-codex")
        #expect(codex?.kind == .browserOAuth)
        #expect(codex?.callbackURL?.absoluteString == "http://127.0.0.1:1455/oauth-callback")

        let copilot = InteractiveAuthFlowCatalog.descriptor(for: "github-copilot")
        #expect(copilot?.kind == .deviceCode)
        #expect(copilot?.clientID == "Iv1.b507a08c87ecfe98")
    }
}
