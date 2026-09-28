import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import OpenClawCore
@testable import OpenClawModels
import OpenClawProtocol

@Suite("Provider runtime policies")
struct ProviderRuntimePolicyTests {
    // MARK: - Reasoning effort

    @Test
    func reasoningEffortResolutionMatchesUpstreamFamilies() {
        func resolve(
            _ level: ThinkLevel,
            _ model: ModelDefinitionConfig?,
            _ id: String,
            provider: String = "openai",
            api: ModelAPI = .openAIResponses
        ) -> String? {
            ReasoningEffortResolver.resolve(thinkingLevel: level, model: model, modelID: id, providerID: provider, api: api)
        }
        let gpt54 = ModelDefinitionConfig(id: "gpt-5.4", reasoning: true)
        #expect(resolve(.max, gpt54, "gpt-5.4") == "xhigh")
        #expect(resolve(.ultra, gpt54, "gpt-5.4") == "xhigh")
        #expect(resolve(.off, gpt54, "gpt-5.4") == "none")
        #expect(resolve(.adaptive, gpt54, "gpt-5.4") == "medium")
        #expect(resolve(.minimal, gpt54, "gpt-5.4") == "low")

        let astra = ModelDefinitionConfig(id: "gpt-6-astra", reasoning: true)
        #expect(resolve(.off, astra, "gpt-6-astra") == nil)
        #expect(resolve(.max, astra, "gpt-6-astra") == "max")
        #expect(resolve(.max, astra, "gpt-6-astra", api: .openAICompletions) == "xhigh")
        #expect(resolve(.max, astra, "gpt-6-astra", provider: "openrouter") == "xhigh")

        let sol = ModelDefinitionConfig(id: "gpt-5.6-sol-2026-05-01", reasoning: true)
        #expect(resolve(.max, sol, sol.id) == "max")
        #expect(resolve(.minimal, sol, sol.id) == "low")

        let codexMini = ModelDefinitionConfig(id: "gpt-5.1-codex-mini", reasoning: true)
        #expect(resolve(.high, codexMini, codexMini.id) == "medium")
        #expect(resolve(.high, ModelDefinitionConfig(id: "gpt-5-pro", reasoning: true), "gpt-5-pro") == "high")
        #expect(resolve(.low, ModelDefinitionConfig(id: "gpt-5-pro", reasoning: true), "gpt-5-pro") == "high")
        #expect(resolve(.minimal, ModelDefinitionConfig(id: "gpt-5", reasoning: true), "gpt-5") == "minimal")

        let cohere = ModelDefinitionConfig(
            id: "command-a-plus-05-2026",
            reasoning: true,
            compat: ModelCompatConfig(
                supportedReasoningEfforts: ["none", "high"],
                reasoningEffortMap: ["minimal": "high", "low": "high", "medium": "high", "high": "high", "off": "none"]
            )
        )
        #expect(resolve(.medium, cohere, cohere.id, provider: "cohere", api: .openAICompletions) == "high")
        #expect(resolve(.off, cohere, cohere.id, provider: "cohere", api: .openAICompletions) == "none")

        let noEffort = ModelDefinitionConfig(id: "x", reasoning: true, compat: ModelCompatConfig(supportsReasoningEffort: false))
        #expect(resolve(.high, noEffort, "x", provider: "custom", api: .openAICompletions) == nil)
        #expect(resolve(.high, ModelDefinitionConfig(id: "plain"), "plain") == nil)
        // Unknown models pass explicit efforts through but omit "off".
        #expect(resolve(.high, nil, "vendor-model", provider: "custom", api: .openAICompletions) == "high")
        #expect(resolve(.off, nil, "vendor-model", provider: "custom", api: .openAICompletions) == nil)
    }

    @Test
    func thinkingLevelMapNullClampsAndProviderNativeValuesKeepCase() {
        let meta = ModelDefinitionConfig(
            id: "muse-spark-1.3",
            reasoning: true,
            compat: ModelCompatConfig(supportedReasoningEfforts: ["minimal", "low", "medium", "high", "xhigh"]),
            thinkingLevelMap: ModelThinkingLevelMap(["off": "minimal", "xhigh": nil])
        )
        let resolve = { (level: ThinkLevel) in
            ReasoningEffortResolver.resolve(thinkingLevel: level, model: meta, modelID: meta.id, providerID: "meta", api: .openAIResponses)
        }
        #expect(resolve(.off) == "minimal")
        #expect(resolve(.xhigh) == "high")
        let native = ModelDefinitionConfig(
            id: "vendor",
            reasoning: true,
            compat: ModelCompatConfig(supportedReasoningEfforts: ["Turbo"], reasoningEffortMap: ["high": "Turbo"])
        )
        #expect(ReasoningEffortResolver.resolve(thinkingLevel: .high, model: native, modelID: "vendor", providerID: "v", api: .openAICompletions) == "Turbo")
        #expect(ModelReasoningEffortValue(rawValue: "High") == .standard(.high))
        #expect(ModelReasoningEffortValue(rawValue: "Turbo").rawValue == "Turbo")
    }

    @Test
    func temperatureSupportFollowsModelFamilies() {
        #expect(!ReasoningEffortResolver.supportsTemperature(modelID: "gpt-5.6-terra", compat: nil, api: .openAIResponses))
        #expect(!ReasoningEffortResolver.supportsTemperature(modelID: "gpt-6-sol", compat: nil, api: .openAIResponses))
        #expect(ReasoningEffortResolver.supportsTemperature(modelID: "gpt-6-sol", compat: nil, api: .azureOpenAIResponses))
        #expect(ReasoningEffortResolver.supportsTemperature(modelID: "gpt-4.1", compat: nil, api: .openAICompletions))
        #expect(ReasoningEffortResolver.supportsTemperature(modelID: "gpt-5.6", compat: ModelCompatConfig(supportsTemperature: true), api: nil))
    }

    // MARK: - Responses payload policy

    @Test
    func responsesPayloadPolicyByEndpointClass() {
        func policy(_ provider: String, _ base: String?, api: ModelAPI = .openAIResponses, compat: ModelCompatConfig? = nil) -> OpenAIResponsesPayloadPolicy {
            OpenAIResponsesPayloadPolicy.resolve(providerID: provider, api: api, baseURL: base, compat: compat)
        }
        let platform = policy("openai", "https://api.openai.com/v1")
        #expect(platform.endpointClass == .openAIPublic)
        #expect(platform.usesInstructionsField)
        #expect(platform.allowsStore)
        #expect(platform.allowsServiceTier)
        #expect(!platform.shouldStripPromptCache)
        #expect(!platform.shouldStripInputStatus)

        let chatGPT = policy("openai", "https://chatgpt.com/backend-api/codex", api: .openAIChatGPTResponses)
        #expect(chatGPT.endpointClass == .openAIChatGPT)
        #expect(chatGPT.usesInstructionsField)
        #expect(!chatGPT.allowsStore)
        #expect(chatGPT.allowsServiceTier)

        let xai = policy("xai", "https://api.x.ai/v1")
        #expect(xai.endpointClass == .xaiNative)
        #expect(xai.usesInstructionsField)
        #expect(!xai.allowsServiceTier)

        let azure = policy("azure-openai-responses", "https://res.openai.azure.com/openai/v1", api: .azureOpenAIResponses)
        #expect(azure.endpointClass == .azureOpenAI)
        #expect(azure.allowsStore)
        #expect(!azure.usesInstructionsField)

        #expect(policy("openai", nil).endpointClass == .default)
        #expect(policy("openai", nil).usesInstructionsField)

        let meta = policy("meta", "https://api.meta.ai/v1")
        #expect(meta.endpointClass == .custom)
        #expect(!meta.usesInstructionsField)
        #expect(!meta.allowsStore)
        #expect(meta.shouldStripPromptCache)
        #expect(meta.shouldStripInputStatus)

        #expect(policy("meta", "https://api.meta.ai/v1", compat: ModelCompatConfig(supportsInstructions: true)).usesInstructionsField)
        #expect(!policy("meta", "https://api.meta.ai/v1", compat: ModelCompatConfig(supportsPromptCacheKey: true)).shouldStripPromptCache)
        #expect(policy("openai", "https://api.openai.com/v1", compat: ModelCompatConfig(supportsPromptCacheKey: false)).shouldStripPromptCache)
        #expect(policy("openai", "https://api.openai.com/v1", compat: ModelCompatConfig(supportsStore: false)).shouldStripStore)
    }

    @Test
    func responsesThirdPartyRouteEmbedsSystemPromptAndStripsStatus() async throws {
        let transport = ContractV2StubTransport(body: #"{"output_text":"ok","status":"completed"}"#)
        let provider = OpenAIResponsesModelProvider(
            id: "meta",
            configuration: ProviderServiceConfig(enabled: true, modelID: "muse-spark-1.3", apiKey: "k", baseURL: "https://api.meta.ai/v1"),
            transport: transport
        )
        _ = try await provider.generate(
            ModelGenerationRequest(
                sessionKey: "s",
                prompt: "",
                systemPrompt: "System rules.",
                policy: ModelGenerationPolicy(promptCache: ModelPromptCachePolicy(enabled: true, longRetention: true)),
                messages: [.user("hi"), .assistant("hello"), .user("again")]
            )
        )
        let body = try #require(await transport.lastBodyObject())
        #expect(body["instructions"] == nil)
        let input = try #require(body["input"]?.arrayValue)
        #expect(input.first?.wireString("role") == "system")
        #expect(input.first?[wireKey: "content"]?.arrayValue?.first?.wireString("text") == "System rules.")
        #expect(input.allSatisfy { $0[wireKey: "status"] == nil })
        #expect(body["store"] == nil)
        #expect(body["prompt_cache_key"] == nil)
        #expect(body["prompt_cache_retention"] == nil)
    }

    @Test
    func responsesNativeRouteSendsPromptCacheAndSessionHeader() async throws {
        let transport = ContractV2StubTransport(body: #"{"output_text":"ok","status":"completed"}"#)
        let provider = OpenAIResponsesModelProvider(
            id: "openai",
            configuration: ProviderServiceConfig(enabled: true, modelID: "gpt-5.4", apiKey: "k", baseURL: "https://api.openai.com/v1"),
            transport: transport
        )
        _ = try await provider.generate(
            ModelGenerationRequest(
                sessionKey: "session-42",
                prompt: "hi",
                policy: ModelGenerationPolicy(temperature: 0.5, promptCache: ModelPromptCachePolicy(enabled: true, longRetention: true))
            )
        )
        let body = try #require(await transport.lastBodyObject())
        #expect(body["prompt_cache_key"]?.stringValue == "session-42")
        #expect(body["prompt_cache_retention"]?.stringValue == "24h")
        #expect(body["temperature"]?.doubleValue == 0.5)
        #expect(await transport.lastRequest()?.value(forHTTPHeaderField: "session_id") == "session-42")
    }

    @Test
    func responsesDropsTemperatureForGPT56AndRaisesMinimalEffortWithWebSearch() async throws {
        let transport = ContractV2StubTransport(body: #"{"output_text":"ok","status":"completed"}"#)
        let config = ModelProviderConfig(
            enabled: true,
            baseURL: "https://api.openai.com/v1",
            apiKey: "k",
            api: .openAIResponses,
            models: [ModelDefinitionConfig(id: "gpt-5", reasoning: true)]
        )
        let provider = OpenAIResponsesModelProvider(
            id: "openai",
            configuration: config.legacyServiceConfig(providerID: "openai"),
            transport: transport,
            runtime: ModelProviderRuntimeContext(providerConfig: config, api: .openAIResponses)
        )
        _ = try await provider.generate(
            ModelGenerationRequest(
                sessionKey: "s",
                prompt: "search",
                policy: ModelGenerationPolicy(thinkingLevel: .minimal),
                tools: [ModelToolDefinition(name: "web_search")]
            )
        )
        #expect(await transport.lastBodyObject()?["reasoning"]?.wireString("effort") == "low")

        _ = try await provider.generate(
            ModelGenerationRequest(sessionKey: "s", prompt: "x", modelID: "gpt-5.6-terra", policy: ModelGenerationPolicy(temperature: 0.2))
        )
        #expect(await transport.lastBodyObject()?["temperature"] == nil)
    }

    @Test
    func azureResponsesUsesAPIVersionAndAPIKeyHeader() async throws {
        let transport = ContractV2StubTransport(body: #"{"output_text":"ok","status":"completed"}"#)
        let config = ModelProviderConfig(
            enabled: true,
            baseURL: "https://res.openai.azure.com/openai/v1",
            apiKey: "azure-key",
            api: .azureOpenAIResponses,
            models: [ModelDefinitionConfig(id: "gpt-5.4")],
            apiVersion: "2026-04-01-preview"
        )
        let provider = OpenAIResponsesModelProvider(
            id: "azure-openai-responses",
            configuration: config.legacyServiceConfig(providerID: "azure-openai-responses"),
            transport: transport,
            runtime: ModelProviderRuntimeContext(providerConfig: config, api: .azureOpenAIResponses)
        )
        _ = try await provider.generate(ModelGenerationRequest(sessionKey: "s", prompt: "hi"))
        let request = try #require(await transport.lastRequest())
        #expect(request.url?.absoluteString == "https://res.openai.azure.com/openai/v1/responses?api-version=2026-04-01-preview")
        #expect(request.value(forHTTPHeaderField: "api-key") == "azure-key")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    // MARK: - Fast mode

    @Test
    func fastModeAutoTurnsOffAfterTheWindow() {
        let model = ModelDefinitionConfig(id: "m", params: ["fastMode": AnyCodable("auto"), "fast_seconds": AnyCodable(30)])
        let now = Date()
        let fresh = ModelGenerationRequest(sessionKey: "s", prompt: "", policy: ModelGenerationPolicy(runStartedAt: now.addingTimeInterval(-10)))
        let stale = ModelGenerationRequest(sessionKey: "s", prompt: "", policy: ModelGenerationPolicy(runStartedAt: now.addingTimeInterval(-45)))
        #expect(FastModeResolution.resolve(request: fresh, configured: nil, model: model, now: now) == true)
        #expect(FastModeResolution.resolve(request: stale, configured: nil, model: model, now: now) == false)
        let sessionOff = ModelGenerationRequest(sessionKey: "s", prompt: "", policy: ModelGenerationPolicy(fastModeSetting: .off))
        #expect(FastModeResolution.resolve(request: sessionOff, configured: true, model: model, now: now) == false)
        #expect(FastModeResolution.resolve(request: ModelGenerationRequest(sessionKey: "s", prompt: ""), configured: nil) == nil)
        #expect(ModelGenerationPolicy(fastModeSetting: .auto).fastMode == nil)
        #expect(ModelGenerationPolicy(fastMode: true).fastModeSetting == .on)
    }

    @Test
    func fastModeSupportQueries() {
        func supports(_ provider: String, _ model: String, _ api: ModelAPI, _ base: String?, _ auth: ModelFastModeSupport.AuthMode) -> Bool? {
            ModelFastModeSupport.supportsFastMode(provider: provider, model: model, api: api, baseURL: base, authMode: auth)
        }
        let platform = "https://api.openai.com/v1"
        #expect(supports("openai", "gpt-5.4", .openAIResponses, platform, .apiKey) == true)
        #expect(supports("openai", "gpt-5.4", .openAICompletions, platform, .apiKey) == false)
        #expect(supports("anthropic", "claude-opus-5", .anthropicMessages, nil, .apiKey) == true)
        #expect(supports("anthropic", "claude-opus-5", .anthropicMessages, nil, .oauth) == false)
        #expect(supports("anthropic", "claude-sonnet-5", .anthropicMessages, nil, .apiKey) == false)
        #expect(supports("xai", "grok-4", .openAIResponses, nil, .apiKey) == true)
        #expect(supports("groq", "llama", .openAICompletions, nil, .apiKey) == nil)
    }

    @Test
    func anthropicNativeFastModeSendsSpeedAndBeta() async throws {
        let transport = ContractV2StubTransport(body: #"{"content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn"}"#)
        let provider = AnthropicModelProvider(
            configuration: AnthropicModelConfig(enabled: true, modelID: "claude-opus-5", fastMode: true, apiKey: "sk-ant", baseURL: "https://api.anthropic.com"),
            transport: transport
        )
        _ = try await provider.generate(ModelGenerationRequest(sessionKey: "s", prompt: "hi", policy: ModelGenerationPolicy(temperature: 0.4)))
        let body = try #require(await transport.lastBodyObject())
        #expect(body["speed"]?.stringValue == "fast")
        #expect(body["service_tier"] == nil)
        // Opus 5 rejects caller sampling parameters.
        #expect(body["temperature"] == nil)
        let beta = try #require(await transport.lastRequest()?.value(forHTTPHeaderField: "anthropic-beta"))
        #expect(beta.contains("fast-mode-2026-02-01"))
    }

    @Test
    func xaiAndMiniMaxFastModeSwapModels() async throws {
        let xaiTransport = ContractV2StubTransport(body: #"{"choices":[{"message":{"role":"assistant","content":"ok"}}]}"#)
        let xai = XAIModelProvider(
            configuration: ProviderServiceConfig(enabled: true, modelID: "grok-3", fastMode: true, apiKey: "k", baseURL: "https://api.x.ai/v1"),
            transport: xaiTransport
        )
        _ = try await xai.generate(ModelGenerationRequest(sessionKey: "s", prompt: "hi"))
        #expect(await xaiTransport.lastBodyObject()?["model"]?.stringValue == "grok-3-fast")

        let minimaxTransport = ContractV2StubTransport(body: #"{"content":[{"type":"text","text":"ok"}]}"#)
        let minimax = MinimaxModelProvider(
            configuration: ProviderServiceConfig(
                enabled: true,
                apiStyle: .anthropicMessages,
                modelID: "MiniMax-M2.7",
                apiKey: "k",
                baseURL: "https://api.minimax.io/anthropic"
            ),
            transport: minimaxTransport
        )
        _ = try await minimax.generate(ModelGenerationRequest(sessionKey: "s", prompt: "hi", policy: ModelGenerationPolicy(fastMode: true)))
        #expect(await minimaxTransport.lastBodyObject()?["model"]?.stringValue == "MiniMax-M2.7-highspeed")
    }

    // MARK: - Anthropic thinking and betas

    @Test
    func claudeIdentityNormalizesIDs() {
        #expect(ClaudeModelIdentity(modelID: "anthropic/claude-opus-5.5").isOpus55)
        #expect(ClaudeModelIdentity(modelID: "us.anthropic.claude-opus-4-8-v1:0").supportsFastMode)
        #expect(ClaudeModelIdentity(modelID: "opus").isOpus5)
        #expect(ClaudeModelIdentity(modelID: "claude-sonnet-4-5").supportsPriorityTier)
        #expect(!ClaudeModelIdentity(modelID: "claude-sonnet-5").supportsPriorityTier)
        #expect(ClaudeModelIdentity(modelID: "gateway/claude-fable-5-1").requiresMandatoryAdaptiveThinking)
        #expect(ClaudeModelIdentity(modelID: "my-alias", params: ["canonicalModelId": AnyCodable("claude-sonnet-4-6")]).supports1MContext)
        #expect(BedrockClaudeSamplingContract.rejectsTemperature(modelID: "global.anthropic.claude-opus-4-7-v1:0"))
        #expect(!BedrockClaudeSamplingContract.rejectsTemperature(modelID: "anthropic.claude-3-5-sonnet"))
    }

    @Test
    func anthropicThinkingModesByModel() {
        func plan(_ id: String, _ level: ThinkLevel?, reasoning: Bool = true) -> AnthropicMessagesWire.ThinkingPlan {
            AnthropicMessagesWire.thinkingPlan(
                request: ModelGenerationRequest(sessionKey: "s", prompt: "", policy: ModelGenerationPolicy(thinkingLevel: level)),
                model: ModelDefinitionConfig(id: id, reasoning: reasoning),
                identity: ClaudeModelIdentity(modelID: id)
            )
        }
        let mandatory = plan("claude-opus-5-5", nil, reasoning: false)
        #expect(mandatory.thinking?["type"] as? String == "adaptive")
        #expect(mandatory.outputEffort == "medium")
        #expect(plan("claude-opus-5-5", .max).outputEffort == "max")

        let adaptive = plan("claude-sonnet-4-6", .high)
        #expect(adaptive.thinking?["type"] as? String == "adaptive")
        #expect(adaptive.thinking?["display"] as? String == "summarized")
        #expect(adaptive.outputEffort == "high")
        #expect(plan("claude-sonnet-4-6", .xhigh).outputEffort == "high")
        #expect(plan("claude-opus-4-8", .xhigh).outputEffort == "xhigh")

        let budget = plan("claude-3-7-sonnet-latest", .high)
        #expect(budget.thinking?["type"] as? String == "enabled")
        #expect(budget.thinking?["budget_tokens"] as? Int == 1_024)
        #expect(plan("claude-sonnet-5", .off).thinking?["type"] as? String == "disabled")
        #expect(plan("claude-sonnet-5", nil).thinking == nil)
    }

    @Test
    func anthropicOAuthBetasAndToolChoiceWithThinking() async throws {
        let transport = ContractV2StubTransport(body: #"{"content":[{"type":"text","text":"ok"}]}"#)
        let provider = ProviderServiceAnthropicModelProvider(
            id: "anthropic",
            configuration: ProviderServiceConfig(
                enabled: true,
                apiStyle: .anthropicMessages,
                authMode: .oauthToken,
                modelID: "claude-sonnet-4-6",
                accessToken: "sk-ant-oat-123",
                baseURL: "https://api.anthropic.com/v1",
                headers: ["anthropic-beta": "context-1m-2025-08-07,custom-beta"]
            ),
            transport: transport
        )
        _ = try await provider.generate(
            ModelGenerationRequest(
                sessionKey: "s",
                prompt: "hi",
                policy: ModelGenerationPolicy(temperature: 0.3, thinkingLevel: .medium),
                tools: [ModelToolDefinition(name: "t")],
                toolChoice: .required
            )
        )
        let request = try #require(await transport.lastRequest())
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-ant-oat-123")
        let beta = try #require(request.value(forHTTPHeaderField: "anthropic-beta"))
        #expect(beta.hasPrefix("claude-code-20250219,oauth-2025-04-20,fine-grained-tool-streaming-2025-05-14"))
        #expect(beta.contains("custom-beta"))
        #expect(!beta.contains("context-1m"))
        let body = try #require(await transport.lastBodyObject())
        // Thinking forces auto tool choice and drops temperature.
        #expect(body["tool_choice"]?.wireString("type") == "auto")
        #expect(body["temperature"] == nil)
        #expect(body["thinking"]?.wireString("type") == "adaptive")
    }

    @Test
    func anthropicPromptCacheMarkers() async throws {
        let transport = ContractV2StubTransport(body: #"{"content":[{"type":"text","text":"ok"}]}"#)
        let provider = AnthropicModelProvider(
            configuration: AnthropicModelConfig(enabled: true, modelID: "claude-haiku-4-5", apiKey: "k", baseURL: "https://api.anthropic.com"),
            transport: transport
        )
        _ = try await provider.generate(
            ModelGenerationRequest(
                sessionKey: "s",
                prompt: "",
                systemPrompt: "Cache me.",
                policy: ModelGenerationPolicy(promptCache: ModelPromptCachePolicy(enabled: true, longRetention: true)),
                messages: [.user("first"), .assistant("reply"), .user("second")],
                tools: [ModelToolDefinition(name: "a"), ModelToolDefinition(name: "b")]
            )
        )
        let body = try #require(await transport.lastBodyObject())
        let system = try #require(body["system"]?.arrayValue?.first)
        #expect(system[wireKey: "cache_control"]?.wireString("type") == "ephemeral")
        #expect(system[wireKey: "cache_control"]?.wireString("ttl") == "1h")
        #expect(body["tools"]?.arrayValue?.last?[wireKey: "cache_control"] != nil)
        #expect(body["tools"]?.arrayValue?.first?[wireKey: "cache_control"] == nil)
        let lastMessage = try #require(body["messages"]?.arrayValue?.last)
        #expect(lastMessage[wireKey: "content"]?.arrayValue?.last?[wireKey: "cache_control"] != nil)
    }

    // MARK: - Chat Completions compat shaping

    @Test
    func chatCompletionsCompatShaping() async throws {
        func body(
            provider: String = "custom",
            base: String = "https://llm.example/v1",
            model: ModelDefinitionConfig,
            request: ModelGenerationRequest
        ) async throws -> [String: AnyCodable] {
            let transport = ContractV2StubTransport(body: #"{"choices":[{"message":{"role":"assistant","content":"ok"}}]}"#)
            let config = ModelProviderConfig(enabled: true, baseURL: base, apiKey: "k", models: [model])
            let engine = ProviderServiceOpenAIModelProvider(
                id: provider,
                configuration: config.legacyServiceConfig(providerID: provider),
                transport: transport,
                runtime: ModelProviderRuntimeContext(providerConfig: config, api: .openAICompletions)
            )
            _ = try await engine.generate(request)
            return try #require(await transport.lastBodyObject())
        }
        let transcript = ModelGenerationRequest(
            sessionKey: "s",
            prompt: "",
            systemPrompt: "Sys",
            policy: ModelGenerationPolicy(maxTokens: 256, thinkingLevel: .high),
            messages: [
                .user(content: [.text("a"), .text("b")]),
                .assistant(content: [.thinking("mull", signature: nil), .toolCall(ModelToolCall(id: "c1", name: "t", argumentsJSON: "{}"))]),
                .toolResult(ModelToolResult(toolCallID: "c1", toolName: "t", content: [.text("r")])),
                .user("next"),
            ]
        )
        let nvidia = try await body(
            provider: "nvidia",
            base: "https://integrate.api.nvidia.com/v1",
            model: ModelDefinitionConfig(
                id: "n",
                reasoning: true,
                compat: ModelCompatConfig(
                    supportsDeveloperRole: true,
                    maxTokensField: .maxCompletionTokens,
                    requiresToolResultName: true,
                    requiresAssistantAfterToolResult: true,
                    requiresStringContent: true
                )
            ),
            request: transcript
        )
        let messages = try #require(nvidia["messages"]?.arrayValue)
        #expect(messages.first?.wireString("role") == "developer")
        #expect(nvidia["max_completion_tokens"]?.intValue == 256)
        #expect(messages.first(where: { $0.wireString("role") == "tool" })?.wireString("name") == "t")
        #expect(messages.map { $0.wireString("role") } == ["developer", "user", "assistant", "tool", "assistant", "user"])
        #expect(nvidia["reasoning_effort"]?.stringValue == "high")

        let zai = try await body(
            provider: "zai",
            base: "https://api.z.ai/api/paas/v4",
            model: ModelDefinitionConfig(id: "glm", reasoning: true),
            request: transcript
        )
        #expect(zai["thinking"]?.wireString("type") == "enabled")
        #expect(zai["thinking"]?[wireKey: "clear_thinking"]?.boolValue == false)
        #expect(zai["max_tokens"]?.intValue == 256)
        #expect(zai["reasoning_effort"] == nil)

        let qwen = try await body(
            model: ModelDefinitionConfig(id: "q", reasoning: true, compat: ModelCompatConfig(thinkingFormat: .qwenChatTemplate)),
            request: transcript
        )
        #expect(qwen["chat_template_kwargs"]?[wireKey: "enable_thinking"]?.boolValue == true)
        #expect(qwen["chat_template_kwargs"]?[wireKey: "preserve_thinking"]?.boolValue == true)

        let deepseek = try await body(
            provider: "deepseek",
            base: "https://api.deepseek.com",
            model: ModelDefinitionConfig(id: "deepseek-reasoner", reasoning: true),
            request: transcript
        )
        #expect(deepseek["thinking"]?.wireString("type") == "enabled")
        let deepseekAssistant = try #require(deepseek["messages"]?.arrayValue?.first { $0.wireString("role") == "assistant" })
        #expect(deepseekAssistant.wireString("reasoning_content") == "mull")

        let together = try await body(
            provider: "together",
            base: "https://api.together.xyz/v1",
            model: ModelDefinitionConfig(id: "t", reasoning: true),
            request: transcript
        )
        #expect(together["reasoning"]?[wireKey: "enabled"]?.boolValue == true)

        let openrouter = try await body(
            provider: "openrouter",
            base: "https://openrouter.ai/api/v1",
            model: ModelDefinitionConfig(
                id: "o",
                reasoning: true,
                compat: ModelCompatConfig(openRouterRouting: ["order": AnyCodable([AnyCodable("anthropic")])])
            ),
            request: transcript
        )
        #expect(openrouter["reasoning"]?.wireString("effort") == "high")
        #expect(openrouter["reasoning_effort"] == nil)
        #expect(openrouter["provider"]?[wireKey: "order"]?.arrayValue?.first?.stringValue == "anthropic")

        let vercel = try await body(
            provider: "vercel-ai-gateway",
            base: "https://ai-gateway.vercel.sh/v1",
            model: ModelDefinitionConfig(id: "v", compat: ModelCompatConfig(vercelGatewayRouting: ["only": AnyCodable([AnyCodable("bedrock")])])),
            request: ModelGenerationRequest(sessionKey: "s", prompt: "hi")
        )
        #expect(vercel["providerOptions"]?[wireKey: "gateway"]?[wireKey: "only"]?.arrayValue?.first?.stringValue == "bedrock")

        let longcat = try await body(
            provider: "longcat",
            model: ModelDefinitionConfig(
                id: "LongCat-2.0",
                reasoning: true,
                compat: ModelCompatConfig(thinkingFormat: .deepseek, requiresReasoningContentOnAssistantMessages: true)
            ),
            request: ModelGenerationRequest(
                sessionKey: "s",
                prompt: "",
                policy: ModelGenerationPolicy(thinkingLevel: .low),
                messages: [.user("a"), .assistant("b"), .user("c")]
            )
        )
        let longcatAssistant = try #require(longcat["messages"]?.arrayValue?.first { $0.wireString("role") == "assistant" })
        #expect(longcatAssistant[wireKey: "reasoning_content"]?.stringValue == "")
    }

    @Test
    func nativeGPT56ToolsForceNoneEffort() async throws {
        let transport = ContractV2StubTransport(body: #"{"choices":[{"message":{"role":"assistant","content":"ok"}}]}"#)
        let config = ModelProviderConfig(
            enabled: true,
            baseURL: "https://api.openai.com/v1",
            apiKey: "k",
            models: [ModelDefinitionConfig(id: "gpt-5.6-sol", reasoning: true)]
        )
        let provider = OpenAIModelProvider(
            configuration: OpenAIModelConfig(enabled: true, modelID: "gpt-5.6-sol", apiKey: "k"),
            transport: transport,
            runtime: ModelProviderRuntimeContext(providerConfig: config, api: .openAICompletions)
        )
        _ = try await provider.generate(
            ModelGenerationRequest(
                sessionKey: "s",
                prompt: "x",
                policy: ModelGenerationPolicy(temperature: 0.7, thinkingLevel: .high),
                tools: [ModelToolDefinition(name: "t")]
            )
        )
        let body = try #require(await transport.lastBodyObject())
        #expect(body["reasoning_effort"]?.stringValue == "none")
        #expect(body["temperature"] == nil)
        #expect(body["store"]?.boolValue == false)
    }

    // MARK: - Endpoints and routing

    @Test
    func endpointURLRules() {
        #expect(AnthropicMessagesWire.messagesURL(baseURL: "https://api.anthropic.com", messagesPath: "messages") == "https://api.anthropic.com/v1/messages")
        #expect(AnthropicMessagesWire.messagesURL(baseURL: "https://api.anthropic.com/v1/", messagesPath: "messages") == "https://api.anthropic.com/v1/messages")
        #expect(AnthropicMessagesWire.messagesURL(baseURL: "https://api.minimax.io/anthropic", messagesPath: "messages") == "https://api.minimax.io/anthropic/v1/messages")
        #expect(AnthropicMessagesWire.messagesURL(baseURL: "https://proxy.example", messagesPath: "custom/messages") == "https://proxy.example/custom/messages")
        #expect(AnthropicMessagesWire.messagesURL(baseURL: "", messagesPath: "messages") == "https://api.anthropic.com/v1/messages")
        #expect(OllamaChatWire.chatURL(baseURL: "http://127.0.0.1:11434/v1") == "http://127.0.0.1:11434/api/chat")
        #expect(OllamaChatWire.chatURL(baseURL: "https://ollama.com/") == "https://ollama.com/api/chat")

        #expect(OpenAIRouteResolution.classify(baseURL: "https://api.openai.com/v1") == .platform)
        #expect(OpenAIRouteResolution.classify(baseURL: "https://chatgpt.com/backend-api/codex/v1/") == .chatGPT)
        #expect(OpenAIRouteResolution.classify(baseURL: "http://chatgpt.com/backend-api") == .invalid)
        #expect(OpenAIRouteResolution.classify(baseURL: "https://api.openai.com:8443/v1") == .invalid)
        #expect(OpenAIRouteResolution.classify(baseURL: "https://api.openai.com/v2") == .invalid)
        #expect(OpenAIRouteResolution.classify(baseURL: "https://proxy.example/v1") == .custom)
        #expect(OpenAIRouteResolution.classify(baseURL: nil) == .unresolved)
        #expect(OpenAIRouteResolution.canonicalizeChatGPTBaseURL("https://chatgpt.com/backend-api/v1") == OpenAIRouteResolution.chatGPTBaseURL)
        #expect(OpenAIRouteResolution.chatGPTResponsesURL(baseURL: "https://chatgpt.com/backend-api") == "https://chatgpt.com/backend-api/codex/responses")
        #expect(OpenAIRouteResolution.normalizeModelID("GPT-5.4-Codex") == "gpt-5.4")
        #expect(ModelProviderEndpointClass.resolve(baseURL: "http://localhost:4000") == .local)
        #expect(ModelProviderEndpointClass.resolve(baseURL: "https://x.cognitiveservices.azure.com") == .azureOpenAI)
    }

    @Test
    func factoryRoutesPerModelAPIAndBaseURL() throws {
        let config = ModelProviderConfig(
            enabled: true,
            baseURL: "https://api.individual.githubcopilot.com",
            auth: .token,
            api: .openAIResponses,
            models: [
                ModelDefinitionConfig(id: "gpt-5.4"),
                ModelDefinitionConfig(id: "claude-sonnet-5", api: .anthropicMessages),
                ModelDefinitionConfig(id: "gemini-3.6-flash", api: .openAICompletions, baseURL: "https://gemini.proxy.example/v1"),
            ],
            apiKeyInput: .string("gh")
        )
        #expect(RoutingModelProvider.needsRouting(config))
        let provider = try ModelProviderFactory.makeProvider(providerID: "github-copilot", config: config)
        let routing = try #require(provider as? RoutingModelProvider)
        #expect(routing.id == "github-copilot")
        #expect(routing.route(forModelID: "claude-sonnet-5").api == .anthropicMessages)
        #expect(routing.route(forModelID: "claude-sonnet-5").baseURL == "https://api.individual.githubcopilot.com")
        #expect(routing.route(forModelID: "gemini-3.6-flash").baseURL == "https://gemini.proxy.example/v1")
        #expect(routing.route(forModelID: "gpt-5.4").api == .openAIResponses)
        #expect(routing.capabilities.supportsTools)

        let flat = ModelProviderConfig(enabled: true, baseURL: "https://api.groq.com/openai/v1", apiKey: "k", models: [ModelDefinitionConfig(id: "a")])
        #expect(!RoutingModelProvider.needsRouting(flat))
        #expect(try ModelProviderFactory.makeProvider(providerID: "groq", config: flat) is ProviderServiceOpenAIModelProvider)
    }

    @Test
    func factorySkipsUnknownAPIsAndFillsCatalogBaseURL() throws {
        let unknown = try JSONDecoder().decode(
            ModelProviderConfig.self,
            from: Data(#"{"baseUrl":"https://x.example","api":"future-api","models":[{"id":"m"}]}"#.utf8)
        )
        #expect(throws: OpenClawCoreError.self) {
            _ = try ModelProviderFactory.makeProvider(providerID: "future", config: unknown)
        }
        let known = ModelProviderConfig(enabled: true, baseURL: "https://api.groq.com/openai/v1", apiKey: "k", models: [ModelDefinitionConfig(id: "m")])
        let result = ModelProviderFactory.makeProviders(from: ["future": unknown, "groq": known])
        #expect(result.providers.map(\.id) == ["groq"])
        #expect(result.skipped["future"]?.contains("future-api") == true)

        let overlay = try JSONDecoder().decode(ModelProviderConfig.self, from: Data(#"{"apiKey":"sk","models":[{"id":"claude-haiku-4-5"}]}"#.utf8))
        let anthropic = try ModelProviderFactory.makeProvider(providerID: "anthropic", config: overlay)
        #expect(anthropic.id == "anthropic")
    }
}
