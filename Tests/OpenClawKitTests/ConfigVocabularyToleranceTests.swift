import Foundation
import Testing
@testable import OpenClawKit

@Suite("Config vocabulary tolerance (2026.9.6)")
struct ConfigVocabularyToleranceTests {
    private static let upstreamShapedConfig = """
    {
      "agents": {
        "thinkingLevel": "galaxy-brain",
        "verboseLevel": "full",
        "execHost": "auto",
        "execSecurity": "paranoid",
        "execAsk": "on-miss"
      },
      "auth": {
        "profiles": {
          "bedrock": { "provider": "amazon-bedrock", "mode": "aws-sdk" },
          "passkey": { "provider": "future", "mode": "passkey" },
          "anthropic": { "provider": "anthropic", "mode": "api_key" }
        }
      },
      "secrets": {
        "providers": {
          "shared": { "source": "store" },
          "hsm": { "source": "hsm", "slot": 3 },
          "local-env": { "source": "env" }
        },
        "defaults": { "env": "default", "store": "shared" }
      },
      "gateway": { "bind": "0.0.0.0", "mode": "hybrid-cloud" },
      "runtime": { "adaptiveRouting": { "objective": "vibes" } },
      "models": {
        "mode": "overlay",
        "providers": {
          "codex": {
            "api": "openai-codex-responses",
            "models": [
              {
                "id": "gpt-5.5",
                "input": ["text", "image", "video", "audio", "document", "hologram"],
                "compat": { "thinkingFormat": "qwen-chat-template", "maxTokensField": "max_output_tokens" }
              },
              { "name": "missing id" }
            ]
          },
          "legacy-openai": { "api": "openai" },
          "future": { "api": "future-api", "auth": "passkey" },
          "vertex": { "api": "google-vertex", "auth": "oauth" },
          "odd-compat": { "api": "openai-completions", "models": [{ "id": "m", "compat": { "thinkingFormat": "mystery" } }] }
        }
      }
    }
    """

    @Test
    func unknownValuesNeverFailTheWholeConfig() throws {
        let (config, issues) = try ConfigDecodeIssueCollector.decode(
            OpenClawConfig.self,
            from: Data(Self.upstreamShapedConfig.utf8)
        )

        #expect(config.agents.thinkingLevel == nil)
        #expect(config.agents.verboseLevel == .full)
        #expect(config.agents.execHost == .auto)
        #expect(config.agents.execSecurity == nil)
        #expect(config.agents.execAsk == .onMiss)

        #expect(config.auth.profiles["bedrock"]?.mode == .awsSDK)
        #expect(config.auth.profiles["anthropic"]?.mode == .apiKey)
        // Unknown auth modes are kept raw (never selected) instead of dropping the profile.
        #expect(config.auth.profiles["passkey"]?.isModeRecognized == false)

        #expect(config.secrets.providers["shared"] == .store(StoreSecretProviderConfig()))
        #expect(config.secrets.providers["local-env"]?.source == .env)
        #expect(config.secrets.providers["hsm"] == nil)
        #expect(config.secrets.defaults.providerAlias(for: .store) == "shared")

        #expect(config.gateway.bind == .lan)
        #expect(config.gateway.mode == .local)
        #expect(config.runtime.adaptiveRouting.objective == .balanced)

        #expect(config.models.mode == .merge)
        let codex = try #require(config.models.providers["codex"])
        #expect(codex.api == .openAIChatGPTResponses)
        #expect(codex.models.count == 1)
        let model = try #require(codex.models.first)
        #expect(model.input == [.text, .image, .video, .audio, .document])
        #expect(model.compat?.thinkingFormat == .qwenChatTemplate)
        #expect(model.compat?.maxTokensField == nil)
        #expect(config.models.providers["legacy-openai"]?.api == .openAICompletions)
        #expect(config.models.providers["future"]?.api == nil)
        #expect(config.models.providers["future"]?.auth == nil)
        #expect(config.models.providers["vertex"]?.api == .googleVertex)
        #expect(config.models.providers["odd-compat"]?.models.first?.compat?.thinkingFormat == nil)

        let byPath = Dictionary(grouping: issues, by: \.path)
        #expect(byPath["agents.thinkingLevel"]?.first?.kind == .unknownEnumValue)
        #expect(byPath["agents.execSecurity"]?.first?.kind == .unknownEnumValue)
        #expect(byPath["auth.profiles.passkey.mode"] != nil)
        #expect(byPath["secrets.providers.hsm.source"] != nil)
        #expect(byPath["gateway.mode"]?.first?.kind == .unknownEnumValue)
        #expect(byPath["runtime.adaptiveRouting.objective"]?.first?.kind == .unknownEnumValue)
        #expect(byPath["models.mode"]?.first?.kind == .unknownEnumValue)
        #expect(byPath["models.providers.codex.api"]?.first?.kind == .legacyKey)
        #expect(byPath["models.providers.codex.api"]?.first?.message.contains("openai-chatgpt-responses") == true)
        #expect(byPath["models.providers.legacy-openai.api"]?.first?.kind == .legacyKey)
        #expect(byPath["models.providers.future.api"]?.first?.kind == .unknownEnumValue)
        #expect(byPath["models.providers.future.auth"]?.first?.kind == .unknownEnumValue)
        #expect(byPath["models.providers.codex.models[0].input[5]"]?.first?.kind == .unknownEnumValue)
        #expect(byPath["models.providers.codex.models[0].compat.maxTokensField"]?.first?.kind == .unknownEnumValue)
        #expect(byPath["models.providers.codex.models[1].id"]?.first?.kind == .invalidValue)
        #expect(byPath["models.providers.odd-compat.models[0].compat.thinkingFormat"] != nil)
    }

    @Test
    func decodingWithoutACollectorIsStillLenient() throws {
        let config = try JSONDecoder().decode(OpenClawConfig.self, from: Data(Self.upstreamShapedConfig.utf8))
        #expect(config.agents.execHost == .auto)
        #expect(config.models.providers["codex"]?.api == .openAIChatGPTResponses)
    }

    @Test
    func modelAPIVocabularyMatchesUpstreamModelDataAPIs() throws {
        #expect(ModelAPI.allCases.map(\.rawValue).sorted() == [
            "anthropic-messages",
            "azure-openai-responses",
            "bedrock-converse-stream",
            "github-copilot",
            "google-generative-ai",
            "google-vertex",
            "ollama",
            "openai-chatgpt-responses",
            "openai-completions",
            "openai-responses",
            "pi-messages",
        ])
        #expect(ModelAPI(normalizing: " OpenAI-Codex-Responses ") == .openAIChatGPTResponses)
        #expect(ModelAPI(normalizing: "openai") == .openAICompletions)
        #expect(ModelAPI(normalizing: "future-api") == nil)
        #expect(
            ModelAPI.legacyValidationMessage(for: "openai-codex-responses")
                == #""openai-codex-responses" is a removed api id; use "openai-chatgpt-responses""#
        )
        #expect(ModelAPI.legacyValidationMessage(for: "openai-responses") == nil)

        let decoded = try JSONDecoder().decode(ModelAPI.self, from: Data(#""openai-codex-responses""#.utf8))
        #expect(decoded == .openAIChatGPTResponses)
        let encoded = try JSONEncoder().encode(decoded)
        #expect(String(decoding: encoded, as: UTF8.self) == #""openai-chatgpt-responses""#)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ModelAPI.self, from: Data(#""future-api""#.utf8))
        }
    }

    @Test
    func providerFactoryRoutesNewModelAPIs() throws {
        let vertex = try ModelProviderFactory.makeProvider(
            providerID: "vertex-custom",
            config: ModelProviderConfig(enabled: true, api: .googleVertex, models: [ModelDefinitionConfig(id: "gemini")])
        )
        #expect(vertex is GoogleGenerativeAIModelProvider)
        for api in [ModelAPI.openAIChatGPTResponses, .azureOpenAIResponses] {
            let provider = try ModelProviderFactory.makeProvider(
                providerID: "responses-custom",
                config: ModelProviderConfig(enabled: true, api: api, models: [ModelDefinitionConfig(id: "gpt")])
            )
            #expect(provider is OpenAIResponsesModelProvider)
        }
        #expect(throws: OpenClawCoreError.self) {
            _ = try ModelProviderFactory.makeProvider(
                providerID: "pi-custom",
                config: ModelProviderConfig(enabled: true, api: .piMessages, models: [ModelDefinitionConfig(id: "pi")])
            )
        }
    }

    @Test
    func storeSecretRefsUseTheEnvironmentIDGrammar() {
        #expect(SecretRef(source: .store, id: "OPENAI_API_KEY").validationError() == nil)
        #expect(SecretRef(source: .store, id: "openai/api-key").validationError()?.contains("Store SecretRef") == true)
        #expect(SecretDefaultsConfig().providerAlias(for: .store) == DEFAULT_SECRET_PROVIDER_ALIAS)
    }

    @Test
    func secretStoreProviderRoundTrips() throws {
        let config = SecretsConfig(providers: ["shared": .store(StoreSecretProviderConfig())])
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(SecretsConfig.self, from: data)
        #expect(decoded.providers["shared"]?.source == .store)
        #expect(decoded.defaultProviderAlias(for: .store) == "shared")
    }

    @Test(arguments: [
        ("0.0.0.0", GatewayBindMode.lan),
        ("::", .lan),
        ("[::]", .lan),
        ("*", .lan),
        ("127.0.0.1", .loopback),
        ("localhost", .loopback),
        ("::1", .loopback),
        ("[::1]", .loopback),
        (" Tailnet ", .tailnet),
        ("custom", .custom),
    ])
    func gatewayBindAcceptsHostAliases(raw: String, expected: GatewayBindMode) throws {
        let decoded = try JSONDecoder().decode(GatewayBindMode.self, from: Data("\"\(raw)\"".utf8))
        #expect(decoded == expected)
    }

    @Test
    func unknownGatewayBindFallsBackToHostDerivation() throws {
        let config = try JSONDecoder().decode(
            GatewayConfig.self,
            from: Data(#"{"host": "127.0.0.1", "bind": "everywhere"}"#.utf8)
        )
        #expect(config.bind == .loopback)
    }

    @Test
    func execModeProjectionsMatchUpstreamExecApprovalsCore() {
        #expect(ExecMode.from(security: .deny, ask: .always) == .deny)
        #expect(ExecMode.from(security: .allowlist, ask: .off) == .allowlist)
        #expect(ExecMode.from(security: .allowlist, ask: .onMiss) == .ask)
        #expect(ExecMode.from(security: .allowlist, ask: .always) == .ask)
        #expect(ExecMode.from(security: .full, ask: .off) == .full)
        #expect(ExecMode.from(security: .full, ask: .onMiss) == .full)
        #expect(ExecMode.from(security: .full, ask: .always) == .ask)

        #expect(ExecMode.exact(security: .allowlist, ask: .always) == nil)
        #expect(ExecMode.exact(security: .full, ask: .onMiss) == nil)
        #expect(ExecMode.exact(security: .full, ask: .off) == .full)

        #expect(ExecMode.deny.policy == ExecModePolicy(security: .deny, ask: .off))
        #expect(ExecMode.allowlist.policy == ExecModePolicy(security: .allowlist, ask: .off))
        #expect(ExecMode.ask.policy == ExecModePolicy(security: .allowlist, ask: .onMiss))
        #expect(ExecMode.auto.policy == ExecModePolicy(security: .allowlist, ask: .onMiss, autoReview: true))
        #expect(ExecMode.full.policy == ExecModePolicy(security: .full, ask: .off))

        #expect(ExecMode.normalize(" AUTO ") == .auto)
        #expect(ExecMode.normalize("yolo") == nil)
        for mode in ExecMode.allCases where mode != .auto {
            #expect(ExecMode.from(security: mode.policy.security, ask: mode.policy.ask) == mode)
        }
    }

    @Test
    func awsSDKAuthProfilesHaveNoStoredCredential() throws {
        let decoded = try JSONDecoder().decode(
            AuthProfileConfig.self,
            from: Data(#"{"provider": "amazon-bedrock", "mode": "aws-sdk"}"#.utf8)
        )
        #expect(decoded.mode == .awsSDK)
        let encoded = try JSONEncoder().encode(decoded)
        #expect(String(decoding: encoded, as: UTF8.self).contains(#""aws-sdk""#))
    }
}
