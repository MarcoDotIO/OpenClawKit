import Foundation
import OpenClawKit
import SwiftUI
import Combine

/// Observable app state coordinating deployment and chat flows in the tvOS example.
@MainActor
final class OpenClawAppState: ObservableObject {
    private static func preferredDefaultProvider() -> DeployProvider {
        FoundationModelsProvider.runtimeAvailability().isAvailable ? .foundation : .openAI
    }

    /// Deployment lifecycle states for the sample app.
    enum DeploymentState: String, Sendable {
        case stopped
        case starting
        case running
        case stopping
        case failed
    }

    /// Message role labels rendered by the sample chat timeline.
    enum MessageRole: String, Codable, Sendable {
        case user
        case assistant
        case system
    }

    /// Provider service defaults used for generic provider integrations.
    struct ProviderServicePreset: Sendable {
        let baseURL: String
        let apiStyle: ProviderServiceAPIStyle
        let authMode: ProviderServiceAuthMode
    }

    /// User-selectable provider choices surfaced in deploy settings.
    enum DeployProvider: String, Codable, CaseIterable, Identifiable, Sendable {
        case echo
        case openAI
        case openAICompatible
        case anthropic
        case gemini
        case foundation
        case local
        case xai
        case openRouter
        case groq
        case mistral
        case cerebras
        case moonshot
        case liteLLM
        case together
        case huggingFace
        case qianfan
        case nvidia
        case zai
        case minimax
        case minimaxPortal
        case synthetic
        case xiaomi
        case cloudflareAIGateway
        case vercelAIGateway
        case amazonBedrock
        case githubCopilot
        case ollama
        case vllm
        case qwenPortal

        var id: String { self.rawValue }

        var providerID: String {
            switch self {
            case .echo:
                return EchoModelProvider.defaultID
            case .openAI:
                return OpenAIModelProvider.providerID
            case .openAICompatible:
                return OpenAICompatibleModelProvider.providerID
            case .anthropic:
                return AnthropicModelProvider.providerID
            case .gemini:
                return GeminiModelProvider.providerID
            case .foundation:
                return FoundationModelsProvider.providerID
            case .local:
                return LocalModelProvider.providerID
            case .xai:
                return XAIModelProvider.providerID
            case .openRouter:
                return OpenRouterModelProvider.providerID
            case .groq:
                return GroqModelProvider.providerID
            case .mistral:
                return MistralModelProvider.providerID
            case .cerebras:
                return CerebrasModelProvider.providerID
            case .moonshot:
                return MoonshotModelProvider.providerID
            case .liteLLM:
                return LiteLLMModelProvider.providerID
            case .together:
                return TogetherModelProvider.providerID
            case .huggingFace:
                return HuggingFaceModelProvider.providerID
            case .qianfan:
                return QianfanModelProvider.providerID
            case .nvidia:
                return NVIDIAModelProvider.providerID
            case .zai:
                return ZAIModelProvider.providerID
            case .minimax:
                return MinimaxModelProvider.providerID
            case .minimaxPortal:
                return MinimaxPortalModelProvider.providerID
            case .synthetic:
                return SyntheticModelProvider.providerID
            case .xiaomi:
                return XiaomiModelProvider.providerID
            case .cloudflareAIGateway:
                return CloudflareAIGatewayModelProvider.providerID
            case .vercelAIGateway:
                return VercelAIGatewayModelProvider.providerID
            case .amazonBedrock:
                return BedrockConverseModelProvider.providerID
            case .githubCopilot:
                return GitHubCopilotModelProvider.providerID
            case .ollama:
                return OllamaModelProvider.providerID
            case .vllm:
                return VLLMModelProvider.providerID
            case .qwenPortal:
                return QwenPortalModelProvider.providerID
            }
        }

        var displayName: String {
            switch self {
            case .echo:
                return "Echo (offline placeholder)"
            case .openAI:
                return "OpenAI"
            case .openAICompatible:
                return "OpenAI Compatible"
            case .anthropic:
                return "Anthropic"
            case .gemini:
                return "Google Gemini"
            case .foundation:
                return "Apple Foundation Models"
            case .local:
                return "Local (LLMFarm runtime)"
            case .xai:
                return "xAI (Grok)"
            case .openRouter:
                return "OpenRouter"
            case .groq:
                return "Groq"
            case .mistral:
                return "Mistral"
            case .cerebras:
                return "Cerebras"
            case .moonshot:
                return "Moonshot"
            case .liteLLM:
                return "LiteLLM"
            case .together:
                return "Together AI"
            case .huggingFace:
                return "Hugging Face Inference"
            case .qianfan:
                return "Qianfan"
            case .nvidia:
                return "NVIDIA"
            case .zai:
                return "Z.AI"
            case .minimax:
                return "MiniMax"
            case .minimaxPortal:
                return "MiniMax Portal"
            case .synthetic:
                return "Synthetic"
            case .xiaomi:
                return "Xiaomi"
            case .cloudflareAIGateway:
                return "Cloudflare AI Gateway"
            case .vercelAIGateway:
                return "Vercel AI Gateway"
            case .amazonBedrock:
                return "Amazon Bedrock"
            case .githubCopilot:
                return "GitHub Copilot"
            case .ollama:
                return "Ollama"
            case .vllm:
                return "vLLM"
            case .qwenPortal:
                return "Qwen Portal"
            }
        }

        var defaultModelID: String {
            switch self {
            case .echo:
                return "echo-1"
            case .openAI, .openAICompatible:
                return "gpt-4.1-mini"
            case .anthropic:
                return "claude-3-5-haiku-latest"
            case .gemini:
                return "gemini-2.0-flash"
            case .foundation:
                return "apple-foundation-default"
            case .local:
                return "local-default"
            case .xai:
                return "grok-3-mini"
            case .openRouter:
                return "anthropic/claude-sonnet-4-5"
            case .groq:
                return "llama-3.3-70b-versatile"
            case .mistral:
                return "mistral-large-latest"
            case .cerebras:
                return "zai-glm-4.7"
            case .moonshot:
                return "kimi-k2.5"
            case .liteLLM:
                return "gpt-4.1-mini"
            case .together:
                return "meta-llama/Llama-3.3-70B-Instruct-Turbo"
            case .huggingFace:
                return "deepseek-ai/DeepSeek-R1"
            case .qianfan:
                return "deepseek-v3.2"
            case .nvidia:
                return "nvidia/llama-3.1-nemotron-70b-instruct"
            case .zai:
                return "glm-4.7"
            case .minimax, .minimaxPortal:
                return "MiniMax-M2.1"
            case .synthetic:
                return "hf:MiniMaxAI/MiniMax-M2.1"
            case .xiaomi:
                return "mimo-v2-flash"
            case .cloudflareAIGateway:
                return "claude-3-5-sonnet-latest"
            case .vercelAIGateway:
                return "anthropic/claude-opus-4.6"
            case .amazonBedrock:
                return "anthropic.claude-3-5-sonnet"
            case .githubCopilot:
                return "gpt-5"
            case .ollama:
                return "llama3.3"
            case .vllm:
                return "qwen2.5-coder-32b-instruct"
            case .qwenPortal:
                return "coder-model"
            }
        }

        var providerServicePreset: ProviderServicePreset? {
            switch self {
            case .xai:
                return .init(baseURL: "https://api.x.ai/v1", apiStyle: .openAICompletions, authMode: .apiKey)
            case .openRouter:
                return .init(baseURL: "https://openrouter.ai/api/v1", apiStyle: .openAICompletions, authMode: .apiKey)
            case .groq:
                return .init(baseURL: "https://api.groq.com/openai/v1", apiStyle: .openAICompletions, authMode: .apiKey)
            case .mistral:
                return .init(baseURL: "https://api.mistral.ai/v1", apiStyle: .openAICompletions, authMode: .apiKey)
            case .cerebras:
                return .init(baseURL: "https://api.cerebras.ai/v1", apiStyle: .openAICompletions, authMode: .apiKey)
            case .moonshot:
                return .init(baseURL: "https://api.moonshot.ai/v1", apiStyle: .openAICompletions, authMode: .apiKey)
            case .liteLLM:
                return .init(baseURL: "http://127.0.0.1:4000/v1", apiStyle: .openAICompletions, authMode: .apiKey)
            case .together:
                return .init(baseURL: "https://api.together.xyz/v1", apiStyle: .openAICompletions, authMode: .apiKey)
            case .huggingFace:
                return .init(baseURL: "https://router.huggingface.co/v1", apiStyle: .openAICompletions, authMode: .apiKey)
            case .qianfan:
                return .init(baseURL: "https://qianfan.baidubce.com/v2", apiStyle: .openAICompletions, authMode: .apiKey)
            case .nvidia:
                return .init(baseURL: "https://integrate.api.nvidia.com/v1", apiStyle: .openAICompletions, authMode: .apiKey)
            case .zai:
                return .init(baseURL: "https://api.z.ai/api/paas/v4", apiStyle: .openAICompletions, authMode: .apiKey)
            case .minimax:
                return .init(baseURL: "https://api.minimax.io/anthropic", apiStyle: .anthropicMessages, authMode: .apiKey)
            case .minimaxPortal:
                return .init(baseURL: "https://api.minimax.io/anthropic", apiStyle: .anthropicMessages, authMode: .oauthToken)
            case .synthetic:
                return .init(baseURL: "https://api.synthetic.new/anthropic", apiStyle: .anthropicMessages, authMode: .apiKey)
            case .xiaomi:
                return .init(baseURL: "https://api.xiaomimimo.com/anthropic", apiStyle: .anthropicMessages, authMode: .apiKey)
            case .cloudflareAIGateway:
                return .init(baseURL: "https://gateway.ai.cloudflare.com/v1", apiStyle: .anthropicMessages, authMode: .apiKey)
            case .vercelAIGateway:
                return .init(baseURL: "https://ai-gateway.vercel.sh/v1", apiStyle: .anthropicMessages, authMode: .apiKey)
            case .githubCopilot:
                return .init(baseURL: "https://api.githubcopilot.com", apiStyle: .openAICompletions, authMode: .bearerToken)
            case .ollama:
                return .init(baseURL: "http://127.0.0.1:11434/v1", apiStyle: .ollama, authMode: .none)
            case .vllm:
                return .init(baseURL: "http://127.0.0.1:8000/v1", apiStyle: .openAICompletions, authMode: .none)
            case .qwenPortal:
                return .init(baseURL: "https://portal.qwen.ai/v1", apiStyle: .openAICompletions, authMode: .oauthToken)
            default:
                return nil
            }
        }
    }

    /// Persisted chat message model used by local transcript storage.
    struct ChatMessage: Identifiable, Codable, Sendable, Equatable {
        let id: UUID
        let role: MessageRole
        let text: String
        let attachments: [MediaAttachment]?
        let createdAt: Date

        init(id: UUID = UUID(), role: MessageRole, text: String, attachments: [MediaAttachment]? = nil, createdAt: Date = Date()) {
            self.id = id
            self.role = role
            self.text = text
            self.attachments = attachments
            self.createdAt = createdAt
        }
    }

    /// Render model for a discovered skill row in the tvOS app.
    struct SkillItem: Identifiable, Sendable, Equatable {
        let id: String
        let name: String
        let summary: String
        let source: String
        let primaryEnv: String
        let requiresExplicitInvocation: Bool
        let userInvocable: Bool
        let entrypoint: String?
    }

    /// Render model for channel health rows.
    struct ChannelHealthItem: Identifiable, Sendable, Equatable {
        let id: String
        let status: ChannelHealthStatus
        let consecutiveFailures: Int
        let lastError: String?
    }

    /// Render model for route mapping previews.
    struct RouteMappingItem: Identifiable, Sendable, Equatable {
        let id: String
        let route: String
        let agentID: String
    }

    /// Persisted deployment settings loaded/saved between launches.
    struct PersistedSettings: Codable, Sendable {
        var discordBotToken: String?
        var discordChannelID: String?
        var telegramBotToken: String?
        var telegramChatID: String?
        var slackBotToken: String?
        var slackAppToken: String?
        var slackSigningSecret: String?
        var slackChannelID: String?
        var googleChatBearerToken: String?
        var googleChatVerificationToken: String?
        var googleChatSpaceID: String?
        var signalServiceURL: String?
        var signalAccountID: String?
        var signalAuthToken: String?
        var signalRecipient: String?
        var msteamsBotAppID: String?
        var msteamsBotAppPassword: String?
        var msteamsTenantID: String?
        var msteamsConversationID: String?
        var msteamsServiceURL: String?
        var webchatSharedSecret: String?
        var openAIAPIKey: String?
        var openAICompatibleAPIKey: String?
        var openAICompatibleBaseURL: String?
        var anthropicAPIKey: String?
        var geminiAPIKey: String?
        var providerServiceAPIKey: String?
        var providerServiceAccessToken: String?
        var providerServiceBaseURL: String?
        var providerServiceRegion: String?
        var providerServiceProfile: String?
        var selectedProvider: DeployProvider?
        var selectedModelID: String?
        var localRuntime: String?
        var localModelPath: String?
        var localFallbackModelPaths: String?
        var localContextWindow: Int?
        var localTemperature: Double?
        var localTopP: Double?
        var localTopK: Int?
        var localMaxTokens: Int?
        var localUseMetal: Bool?
        var localStreamTokens: Bool?
        var localAllowCancellation: Bool?
        var localRequestTimeoutMs: Int?
        var defaultAgentID: String?
        var discordAgentID: String?
        var webchatAgentID: String?
        var personality: String?
    }

    @Published var discordBotToken: String = ""
    @Published var discordChannelID: String = ""
    @Published var telegramBotToken: String = ""
    @Published var telegramChatID: String = ""
    @Published var slackBotToken: String = ""
    @Published var slackAppToken: String = ""
    @Published var slackSigningSecret: String = ""
    @Published var slackChannelID: String = ""
    @Published var googleChatBearerToken: String = ""
    @Published var googleChatVerificationToken: String = ""
    @Published var googleChatSpaceID: String = ""
    @Published var signalServiceURL: String = "http://127.0.0.1:8080"
    @Published var signalAccountID: String = ""
    @Published var signalAuthToken: String = ""
    @Published var signalRecipient: String = ""
    @Published var msteamsBotAppID: String = ""
    @Published var msteamsBotAppPassword: String = ""
    @Published var msteamsTenantID: String = ""
    @Published var msteamsConversationID: String = ""
    @Published var msteamsServiceURL: String = "https://smba.trafficmanager.net/teams/"
    @Published var webchatSharedSecret: String = ""
    @Published var openAIAPIKey: String = ""
    @Published var openAICompatibleAPIKey: String = ""
    @Published var openAICompatibleBaseURL: String = "https://api.openai.com/v1"
    @Published var anthropicAPIKey: String = ""
    @Published var geminiAPIKey: String = ""
    @Published var providerServiceAPIKey: String = ""
    @Published var providerServiceAccessToken: String = ""
    @Published var providerServiceBaseURL: String = ""
    @Published var providerServiceRegion: String = "us-east-1"
    @Published var providerServiceProfile: String = "default"
    @Published var selectedProvider: DeployProvider = OpenClawAppState.preferredDefaultProvider()
    @Published var selectedModelID: String = OpenClawAppState.preferredDefaultProvider().defaultModelID
    @Published var localRuntime: String = "llmfarm"
    @Published var localModelPath: String = ""
    @Published var localFallbackModelPaths: String = ""
    @Published var localContextWindow: Int = 4096
    @Published var localTemperature: Double = 0.7
    @Published var localTopP: Double = 0.95
    @Published var localTopK: Int = 40
    @Published var localMaxTokens: Int = 512
    @Published var localUseMetal: Bool = true
    @Published var localStreamTokens: Bool = true
    @Published var localAllowCancellation: Bool = true
    @Published var localRequestTimeoutMs: Int = 60_000
    @Published var defaultAgentID: String = "main"
    @Published var discordAgentID: String = ""
    @Published var webchatAgentID: String = ""
    @Published var personality: String = ""
    @Published var pendingMessage: String = ""
    @Published var selectedSkillName: String = ""

    @Published private(set) var deploymentState: DeploymentState = .stopped
    @Published private(set) var statusText: String = "Not deployed"
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var latestSummary: String = ""
    @Published private(set) var skillItems: [SkillItem] = []
    @Published private(set) var channelHealthItems: [ChannelHealthItem] = []
    @Published private(set) var diagnosticEvents: [RuntimeDiagnosticEvent] = []
    @Published private(set) var usageSnapshot: RuntimeUsageSnapshot?
    @Published private(set) var activeRetryPolicy: ChannelSendRetryPolicy = ChannelSendRetryPolicy()

    var isDeployed: Bool {
        self.deploymentState == .running
    }

    var availableProviders: [DeployProvider] {
        DeployProvider.allCases
    }

    var selectableSkillItems: [SkillItem] {
        self.skillItems
            .filter(\.userInvocable)
            .sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    var routeMappings: [RouteMappingItem] {
        let defaultID = normalized(self.defaultAgentID) ?? "main"
        var rows: [RouteMappingItem] = [
            RouteMappingItem(id: "default", route: "default", agentID: defaultID),
        ]
        if let discordAgentID = normalized(self.discordAgentID) {
            rows.append(
                RouteMappingItem(
                    id: ChannelID.discord.rawValue,
                    route: AgentsConfig.routeKey(channel: ChannelID.discord.rawValue),
                    agentID: discordAgentID
                )
            )
        }
        if let webchatAgentID = normalized(self.webchatAgentID) {
            rows.append(
                RouteMappingItem(
                    id: ChannelID.webchat.rawValue,
                    route: AgentsConfig.routeKey(channel: ChannelID.webchat.rawValue),
                    agentID: webchatAgentID
                )
            )
        }
        return rows
    }

    var latestSkillInvocationSummary: String {
        guard let event = self.diagnosticEvents.reversed().first(where: {
            $0.subsystem == "channel" && $0.name == "skill.invoked"
        }) else {
            return "No skill invocation observed in this session yet."
        }
        let skillName = event.metadata["skillName"] ?? "unknown"
        let durationMs = event.metadata["durationMs"] ?? "n/a"
        let executor = event.metadata["executorID"] ?? "unknown"
        return "\(skillName) (\(durationMs) ms via \(executor))"
    }

    private let sdk = OpenClawSDK.shared
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let summaryScheduler = CronScheduler()
    private let memoryIndex = MemoryIndex()

    private let stateRoot: URL
    private let workspaceURL: URL
    private let configURL: URL
    private let sessionsURL: URL
    private let messagesURL: URL
    private let settingsURL: URL
    private let conversationMemoryURL: URL
    private let automationRulesURL: URL
    private let sharedConversationSessionKey = "shared"

    private var webchatAdapter: InMemoryChannelAdapter?
    private var discordAdapter: DiscordChannelAdapter?
    private var telegramAdapter: TelegramChannelAdapter?
    private var channelRegistry: ChannelRegistry?
    private var runtime: EmbeddedAgentRuntime?
    private var replyEngine: AutoReplyEngine?
    private var conversationMemoryStore: ConversationMemoryStore?
    private var automationRuleStore: AutomationRuleStore?
    private var automationRunner: AutomationRunner?
    private var diagnosticsPipeline: RuntimeDiagnosticsPipeline?
    private var summaryTask: Task<Void, Never>?
    private var observabilityTask: Task<Void, Never>?

    init() {
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ??
            URL(fileURLWithPath: NSTemporaryDirectory())
        self.stateRoot = docs.appendingPathComponent("OpenClawtvOSDemo", isDirectory: true)
        self.workspaceURL = self.stateRoot.appendingPathComponent("workspace", isDirectory: true)
        self.configURL = self.stateRoot.appendingPathComponent("config.json")
        self.sessionsURL = self.stateRoot.appendingPathComponent("sessions.json")
        self.messagesURL = self.stateRoot.appendingPathComponent("chat-messages.json")
        self.settingsURL = self.stateRoot.appendingPathComponent("deploy-settings.json")
        self.conversationMemoryURL = self.stateRoot.appendingPathComponent("conversation-memory.json")
        self.automationRulesURL = self.stateRoot.appendingPathComponent("automation-rules.json")

        self.loadPersistedSettings()
        self.loadPersistedMessages()
    }

    /// Starts runtime deployment using current credentials and settings.
    func deploy() async {
        guard self.deploymentState != .starting, self.deploymentState != .running else { return }
        self.deploymentState = .starting
        self.statusText = "Starting deployment..."

        do {
            try FileManager.default.createDirectory(at: self.stateRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: self.workspaceURL, withIntermediateDirectories: true)
            try self.persistBootstrapFiles()
            try self.syncExampleSkillsIntoWorkspace()

            let discordConfig = DiscordChannelConfig(
                enabled: !self.discordBotToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                    !self.discordChannelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                botToken: normalized(self.discordBotToken),
                defaultChannelID: normalized(self.discordChannelID),
                pollIntervalMs: 2_000,
                mentionOnly: true
            )
            let telegramConfig = TelegramChannelConfig(
                enabled: !self.telegramBotToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                botToken: normalized(self.telegramBotToken),
                defaultChatID: normalized(self.telegramChatID),
                pollIntervalMs: 2_000,
                mentionOnly: true
            )
            let slackConfig = SlackChannelConfig(
                enabled: !self.slackBotToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                botToken: normalized(self.slackBotToken),
                appToken: normalized(self.slackAppToken),
                signingSecret: normalized(self.slackSigningSecret),
                defaultChannelID: normalized(self.slackChannelID),
                mentionOnly: true
            )
            let googleChatConfig = GoogleChatChannelConfig(
                enabled: !self.googleChatBearerToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                bearerToken: normalized(self.googleChatBearerToken),
                verificationToken: normalized(self.googleChatVerificationToken),
                defaultSpaceID: normalized(self.googleChatSpaceID)
            )
            let signalConfig = SignalChannelConfig(
                enabled: !self.signalAuthToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                serviceURL: normalized(self.signalServiceURL) ?? "http://127.0.0.1:8080",
                accountID: normalized(self.signalAccountID),
                authToken: normalized(self.signalAuthToken),
                defaultRecipient: normalized(self.signalRecipient)
            )
            let msteamsConfig = MicrosoftTeamsChannelConfig(
                enabled: !self.msteamsBotAppID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                    !self.msteamsBotAppPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                botAppID: normalized(self.msteamsBotAppID),
                botAppPassword: normalized(self.msteamsBotAppPassword),
                tenantID: normalized(self.msteamsTenantID),
                defaultConversationID: normalized(self.msteamsConversationID),
                serviceURL: normalized(self.msteamsServiceURL) ?? "https://smba.trafficmanager.net/teams/",
                mentionOnly: true
            )
            let webchatConfig = WebChatChannelConfig(
                enabled: false,
                sharedSecret: normalized(self.webchatSharedSecret)
            )
            let modelsConfig = try self.makeModelsConfig()
            let agentsConfig = self.makeAgentsConfig()

            let config = OpenClawConfig(
                agents: agentsConfig,
                channels: ChannelsConfig(
                    discord: discordConfig,
                    telegram: telegramConfig,
                    slack: slackConfig,
                    googleChat: googleChatConfig,
                    signal: signalConfig,
                    msteams: msteamsConfig,
                    webchat: webchatConfig
                ),
                routing: RoutingConfig(
                    defaultSessionKey: self.sharedConversationSessionKey,
                    includeChannelID: false,
                    includeAccountID: false,
                    includePeerID: false
                ),
                models: modelsConfig
            )

            try await self.sdk.saveConfig(config, to: self.configURL)
            try self.persistSettings()

            let sessionStore = SessionStore(fileURL: self.sessionsURL)
            try await sessionStore.load()
            let conversationMemoryStore = ConversationMemoryStore(fileURL: self.conversationMemoryURL)
            try await conversationMemoryStore.load()

            let channelRegistry = ChannelRegistry()
            let webchat = InMemoryChannelAdapter(id: .webchat)
            await channelRegistry.register(webchat)
            try await webchat.start()

            let diagnosticsPipeline = self.sdk.makeDiagnosticsPipeline(eventLimit: 600)
            let diagnosticsSink = await diagnosticsPipeline.sink()
            let runtime = EmbeddedAgentRuntime(diagnosticsSink: diagnosticsSink)
            try await self.registerSelectedModelProvider(on: runtime, using: config.models)
            let replyEngine = AutoReplyEngine(
                config: config,
                sessionStore: sessionStore,
                channelRegistry: channelRegistry,
                runtime: runtime,
                conversationMemoryStore: conversationMemoryStore,
                diagnosticsSink: diagnosticsSink
            )

            if discordConfig.enabled {
                let discord = DiscordChannelAdapter(config: discordConfig)
                await discord.setInboundHandler { [replyEngine] inbound in
                    _ = try? await replyEngine.process(inbound)
                }
                await channelRegistry.register(discord)
                try await discord.start()
                self.discordAdapter = discord
            } else {
                self.discordAdapter = nil
            }

            if telegramConfig.enabled {
                let telegram = TelegramChannelAdapter(config: telegramConfig)
                await telegram.setInboundHandler { [replyEngine] inbound in
                    _ = try? await replyEngine.process(inbound)
                }
                await channelRegistry.register(telegram)
                try await telegram.start()
                self.telegramAdapter = telegram
            } else {
                self.telegramAdapter = nil
            }

            self.webchatAdapter = webchat
            self.channelRegistry = channelRegistry
            self.runtime = runtime
            self.replyEngine = replyEngine
            self.conversationMemoryStore = conversationMemoryStore
            self.diagnosticsPipeline = diagnosticsPipeline
            try await self.configureAutomationLayer(
                runtime: runtime,
                diagnosticsSink: diagnosticsSink
            )

            await self.summaryScheduler.addOrUpdate(
                CronJob(
                    id: "chat-summary",
                    intervalSeconds: 60,
                    payload: "summary",
                    nextRunAt: Date().addingTimeInterval(60)
                )
            )
            self.startSummaryLoop()
            self.startObservabilityLoop()
            await self.refreshObservabilityState()

            self.deploymentState = .running
            let activeChannels = [
                self.discordAdapter != nil ? "Discord" : nil,
                self.telegramAdapter != nil ? "Telegram" : nil,
                "local chat",
            ]
                .compactMap { $0 }
                .joined(separator: " + ")
            self.statusText = "Deployment running (\(activeChannels), provider: \(self.selectedProvider.displayName))."
        } catch {
            self.deploymentState = .failed
            self.statusText = "Deployment failed: \(error.localizedDescription)"
        }
    }

    /// Stops deployment and tears down adapter/runtime resources.
    func stopDeployment() async {
        guard self.deploymentState == .running || self.deploymentState == .failed else { return }
        self.deploymentState = .stopping
        self.statusText = "Stopping deployment..."

        self.summaryTask?.cancel()
        self.summaryTask = nil
        self.observabilityTask?.cancel()
        self.observabilityTask = nil

        if let discordAdapter {
            await discordAdapter.stop()
        }
        if let telegramAdapter {
            await telegramAdapter.stop()
        }
        if let webchatAdapter {
            await webchatAdapter.stop()
        }

        self.discordAdapter = nil
        self.telegramAdapter = nil
        self.webchatAdapter = nil
        self.channelRegistry = nil
        self.runtime = nil
        self.replyEngine = nil
        self.conversationMemoryStore = nil
        self.automationRuleStore = nil
        self.automationRunner = nil
        self.diagnosticsPipeline = nil
        self.skillItems = []
        self.channelHealthItems = []
        self.diagnosticEvents = []
        self.usageSnapshot = nil
        self.activeRetryPolicy = ChannelSendRetryPolicy()
        self.deploymentState = .stopped
        self.statusText = "Deployment stopped."
    }

    /// Sends the currently drafted message if non-empty.
    func sendPendingMessage() async {
        let text = self.pendingMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        self.pendingMessage = ""
        await self.sendMessage(text, prompt: self.composePrompt(text))
    }

    /// Sends a chat message through the active auto-reply engine.
    /// - Parameters:
    ///   - text: User input message text.
    ///   - prompt: The text to actually send to the model provider.
    ///   - attachments: Optional media attachments.
    func sendMessage(_ text: String, prompt: String, attachments: [MediaAttachment] = []) async {
        guard let replyEngine, self.deploymentState == .running else {
            self.statusText = "Deploy the agent before sending messages."
            return
        }

        self.appendMessage(.init(role: .user, text: text, attachments: attachments))
        do {
            let outbound = try await replyEngine.process(
                InboundMessage(
                    channel: .webchat,
                    peerID: "tvos-local-user",
                    text: prompt,
                    attachments: attachments
                )
            )
            self.appendMessage(.init(role: .assistant, text: outbound.text))
        } catch {
            self.appendMessage(.init(role: .system, text: "Error: \(error.localizedDescription)"))
        }
        await self.refreshObservabilityState()
    }

    /// Sends a chat message through the active auto-reply engine.
    /// - Parameter text: User input message text.
    func sendMessage(_ text: String, attachments: [MediaAttachment] = []) async {
        await self.sendMessage(text, prompt: self.composePrompt(text), attachments: attachments)
    }

    func refreshObservabilityNow() async {
        await self.refreshObservabilityState()
    }

    /// Builds model config from current deploy-provider selections.
    private func makeModelsConfig() throws -> ModelsConfig {
        let selectedModelID = normalized(self.selectedModelID) ?? self.selectedProvider.defaultModelID

        func resolveProviderServiceBaseURL(_ fallback: String) -> String {
            normalized(self.providerServiceBaseURL) ?? fallback
        }

        switch self.selectedProvider {
        case .echo:
            return ModelsConfig(defaultProviderID: EchoModelProvider.defaultID)
        case .openAI:
            guard let apiKey = normalized(self.openAIAPIKey) else {
                throw OpenClawCoreError.invalidConfiguration("OpenAI API key is required for OpenAI provider")
            }
            return ModelsConfig(
                defaultProviderID: OpenAIModelProvider.providerID,
                openAI: OpenAIModelConfig(enabled: true, modelID: selectedModelID, apiKey: apiKey)
            )
        case .openAICompatible:
            guard let apiKey = normalized(self.openAICompatibleAPIKey) else {
                throw OpenClawCoreError.invalidConfiguration("API key is required for OpenAI-compatible provider")
            }
            return ModelsConfig(
                defaultProviderID: OpenAICompatibleModelProvider.providerID,
                openAICompatible: OpenAICompatibleModelConfig(
                    enabled: true,
                    modelID: selectedModelID,
                    apiKey: apiKey,
                    baseURL: normalized(self.openAICompatibleBaseURL) ?? "https://api.openai.com/v1"
                )
            )
        case .anthropic:
            guard let apiKey = normalized(self.anthropicAPIKey) else {
                throw OpenClawCoreError.invalidConfiguration("Anthropic API key is required for Anthropic provider")
            }
            return ModelsConfig(
                defaultProviderID: AnthropicModelProvider.providerID,
                anthropic: AnthropicModelConfig(enabled: true, modelID: selectedModelID, apiKey: apiKey)
            )
        case .gemini:
            guard let apiKey = normalized(self.geminiAPIKey) else {
                throw OpenClawCoreError.invalidConfiguration("Gemini API key is required for Gemini provider")
            }
            return ModelsConfig(
                defaultProviderID: GeminiModelProvider.providerID,
                gemini: GeminiModelConfig(enabled: true, modelID: selectedModelID, apiKey: apiKey)
            )
        case .foundation:
            return ModelsConfig(
                defaultProviderID: FoundationModelsProvider.providerID,
                foundation: FoundationModelConfig(enabled: true, preferredModelID: selectedModelID)
            )
        case .local:
            let fallbackPaths = self.localFallbackModelPaths
                .split(whereSeparator: { $0 == "," || $0.isNewline })
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return ModelsConfig(
                defaultProviderID: LocalModelProvider.providerID,
                local: LocalModelConfig(
                    enabled: true,
                    runtime: normalized(self.localRuntime) ?? "llmfarm",
                    modelPath: normalized(self.localModelPath),
                    contextWindow: max(256, self.localContextWindow),
                    temperature: self.localTemperature,
                    topP: self.localTopP,
                    topK: max(1, self.localTopK),
                    useMetal: self.localUseMetal,
                    streamTokens: self.localStreamTokens,
                    allowCancellation: self.localAllowCancellation,
                    requestTimeoutMs: max(1, self.localRequestTimeoutMs),
                    fallbackModelPaths: fallbackPaths,
                    runtimeOptions: [:],
                    maxTokens: max(1, self.localMaxTokens)
                )
            )
        case .amazonBedrock:
            let region = normalized(self.providerServiceRegion) ?? "us-east-1"
            let profile = normalized(self.providerServiceProfile) ?? "default"
            let config = ProviderServiceConfig(
                enabled: true,
                apiStyle: .bedrockConverse,
                authMode: .awsSDK,
                modelID: selectedModelID,
                baseURL: resolveProviderServiceBaseURL("https://bedrock-runtime.\(region).amazonaws.com"),
                region: region,
                profile: profile
            )
            return ModelsConfig(
                defaultProviderID: BedrockConverseModelProvider.providerID,
                providers: [BedrockConverseModelProvider.providerID: ModelProviderConfig(legacyService: config)]
            )
        default:
            guard let preset = self.selectedProvider.providerServicePreset else {
                throw OpenClawCoreError.invalidConfiguration("Unsupported provider preset")
            }
            var config = ProviderServiceConfig(
                enabled: true,
                apiStyle: preset.apiStyle,
                authMode: preset.authMode,
                modelID: selectedModelID,
                baseURL: resolveProviderServiceBaseURL(preset.baseURL),
                chatCompletionsPath: "chat/completions",
                messagesPath: "messages"
            )
            switch preset.authMode {
            case .apiKey:
                guard let key = normalized(self.providerServiceAPIKey) else {
                    throw OpenClawCoreError.invalidConfiguration(
                        "API key is required for \(self.selectedProvider.displayName) provider"
                    )
                }
                config.apiKey = key
            case .bearerToken, .oauthToken:
                guard let token = normalized(self.providerServiceAccessToken) else {
                    throw OpenClawCoreError.invalidConfiguration(
                        "Access token is required for \(self.selectedProvider.displayName) provider"
                    )
                }
                config.accessToken = token
            case .none, .awsSDK:
                break
            }
            return ModelsConfig(
                defaultProviderID: self.selectedProvider.providerID,
                providers: [self.selectedProvider.providerID: ModelProviderConfig(legacyService: config)]
            )
        }
    }

    /// Builds agents config from current route mapping selections.
    private func makeAgentsConfig() -> AgentsConfig {
        let resolvedDefaultAgentID = normalized(self.defaultAgentID) ?? "main"
        var routeAgentMap: [String: String] = [:]

        if let discordAgentID = normalized(self.discordAgentID) {
            routeAgentMap[AgentsConfig.routeKey(channel: ChannelID.discord.rawValue)] = discordAgentID
        }
        if let webchatAgentID = normalized(self.webchatAgentID) {
            routeAgentMap[AgentsConfig.routeKey(channel: ChannelID.webchat.rawValue)] = webchatAgentID
        }

        var agentIDs: Set<String> = [resolvedDefaultAgentID]
        if let discordAgentID = normalized(self.discordAgentID) {
            agentIDs.insert(discordAgentID)
        }
        if let webchatAgentID = normalized(self.webchatAgentID) {
            agentIDs.insert(webchatAgentID)
        }

        return AgentsConfig(
            defaultAgentID: resolvedDefaultAgentID,
            workspaceRoot: self.workspaceURL.path,
            agentIDs: agentIDs.sorted(),
            routeAgentMap: routeAgentMap
        )
    }

    /// Registers and activates currently selected model provider on runtime.
    private func registerSelectedModelProvider(
        on runtime: EmbeddedAgentRuntime,
        using models: ModelsConfig
    ) async throws {
        switch self.selectedProvider {
        case .echo:
            try await runtime.setDefaultModelProviderID(EchoModelProvider.defaultID)
        case .openAI:
            await runtime.registerModelProvider(OpenAIModelProvider(configuration: models.openAI))
            try await runtime.setDefaultModelProviderID(OpenAIModelProvider.providerID)
        case .openAICompatible:
            await runtime.registerModelProvider(OpenAICompatibleModelProvider(configuration: models.openAICompatible))
            try await runtime.setDefaultModelProviderID(OpenAICompatibleModelProvider.providerID)
        case .anthropic:
            await runtime.registerModelProvider(AnthropicModelProvider(configuration: models.anthropic))
            try await runtime.setDefaultModelProviderID(AnthropicModelProvider.providerID)
        case .gemini:
            await runtime.registerModelProvider(GeminiModelProvider(configuration: models.gemini))
            try await runtime.setDefaultModelProviderID(GeminiModelProvider.providerID)
        case .foundation:
            await runtime.registerModelProvider(FoundationModelsProvider())
            try await runtime.setDefaultModelProviderID(FoundationModelsProvider.providerID)
        case .local:
            await runtime.registerModelProvider(
                LocalModelProvider(
                    configuration: models.local,
                    engine: StubLocalModelEngine()
                )
            )
            try await runtime.setDefaultModelProviderID(LocalModelProvider.providerID)
        case .amazonBedrock:
            guard let config = models.legacyProviderServiceConfig(for: BedrockConverseModelProvider.providerID) else {
                throw OpenClawCoreError.invalidConfiguration("Missing Bedrock provider service config")
            }
            await runtime.registerModelProvider(BedrockConverseModelProvider(configuration: config))
            try await runtime.setDefaultModelProviderID(BedrockConverseModelProvider.providerID)
        default:
            let providerID = self.selectedProvider.providerID
            guard let config = models.legacyProviderServiceConfig(for: providerID) else {
                throw OpenClawCoreError.invalidConfiguration("Missing provider service config for '\(providerID)'")
            }
            switch config.apiStyle {
            case .anthropicMessages:
                await runtime.registerModelProvider(
                    ProviderServiceAnthropicModelProvider(
                        id: providerID,
                        configuration: config
                    )
                )
            case .bedrockConverse:
                await runtime.registerModelProvider(BedrockConverseModelProvider(configuration: config))
            default:
                await runtime.registerModelProvider(
                    ProviderServiceOpenAIModelProvider(
                        id: providerID,
                        configuration: config
                    )
                )
            }
            try await runtime.setDefaultModelProviderID(providerID)
        }
    }

    /// Configures proactive automation rule storage and runtime runner.
    private func configureAutomationLayer(
        runtime: EmbeddedAgentRuntime,
        diagnosticsSink: RuntimeDiagnosticSink?
    ) async throws {
        let store = AutomationRuleStore(fileURL: self.automationRulesURL)
        try await store.load()
        if (await store.allRules()).isEmpty {
            await store.upsert(
                AutomationRule(
                    name: "Periodic planning pulse",
                    sessionKey: self.sharedConversationSessionKey,
                    prompt: "Summarize pending user tasks, identify blockers, and propose the next best action.",
                    modelProviderID: self.selectedProvider.providerID,
                    trigger: AutomationTrigger(intervalSeconds: 1_800)
                )
            )
            try await store.save()
        }

        let runner = AutomationRunner(
            runtime: runtime,
            ruleStore: store,
            diagnosticsSink: diagnosticsSink
        )
        self.automationRuleStore = store
        self.automationRunner = runner
    }

    /// Starts background summary scheduler polling loop.
    private func startSummaryLoop() {
        self.summaryTask?.cancel()
        self.summaryTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                _ = await self.automationRunner?.runDueAutomations()
                let due = await self.summaryScheduler.runDue()
                if !due.isEmpty {
                    await self.summarizeChatMemory()
                }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    /// Starts background observability polling loop.
    private func startObservabilityLoop() {
        self.observabilityTask?.cancel()
        self.observabilityTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refreshObservabilityState()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    /// Updates diagnostics snapshots, channel health, and skill inventory.
    private func refreshObservabilityState() async {
        if let diagnosticsPipeline = self.diagnosticsPipeline {
            self.usageSnapshot = await diagnosticsPipeline.usageSnapshot()
            self.diagnosticEvents = await diagnosticsPipeline.recentEvents(limit: 120)
        }

        if let channelRegistry = self.channelRegistry {
            let policy = await channelRegistry.retryPolicy()
            let snapshots = await channelRegistry.allHealthSnapshots()
            self.activeRetryPolicy = policy
            self.channelHealthItems = snapshots.map { snapshot in
                ChannelHealthItem(
                    id: snapshot.channelID.rawValue,
                    status: snapshot.status,
                    consecutiveFailures: snapshot.consecutiveFailures,
                    lastError: snapshot.lastError
                )
            }
        }

        let registry = SkillRegistry(workspaceRoot: self.workspaceURL)
        if let skills = try? await registry.loadSkills() {
            self.skillItems = skills.map { skill in
                SkillItem(
                    id: skill.name,
                    name: skill.name,
                    summary: skill.description.isEmpty ? "No description" : skill.description,
                    source: skill.source.rawValue,
                    primaryEnv: skill.metadata.primaryEnv ?? "unknown",
                    requiresExplicitInvocation: skill.invocation.requiresExplicitInvocation,
                    userInvocable: skill.invocation.userInvocable,
                    entrypoint: Self.skillEntrypointHint(for: skill)
                )
            }
            if let selected = normalized(self.selectedSkillName),
               !self.selectableSkillItems.contains(where: { $0.name == selected })
            {
                self.selectedSkillName = ""
            }
        }
    }

    /// Summarizes recent transcript entries into memory index state.
    private func summarizeChatMemory() async {
        let recent = self.messages.suffix(20)
        guard !recent.isEmpty else { return }
        let summary = recent
            .map { "[\($0.role.rawValue)] \($0.text)" }
            .joined(separator: "\n")

        let document = MemoryDocument(
            id: "summary-\(Int(Date().timeIntervalSince1970))",
            source: .systemNote,
            text: summary
        )
        await self.memoryIndex.upsert(document)
        if let store = self.conversationMemoryStore {
            await store.appendAssistantTurn(
                sessionKey: self.sharedConversationSessionKey,
                channel: "webchat",
                accountID: nil,
                peerID: "summary",
                text: "Summary snapshot:\n\(summary)"
            )
            try? await store.save()
        }
        self.latestSummary = summary
    }

    private func composePrompt(_ text: String) -> String {
        guard let selected = normalized(self.selectedSkillName),
              self.selectableSkillItems.contains(where: { $0.name == selected })
        else {
            return text
        }
        return "/\(selected) \(text)"
    }

    private static func skillEntrypointHint(for skill: SkillDefinition) -> String? {
        for key in ["entrypoint", "script", "run"] {
            if let value = skill.frontmatter[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func appendMessage(_ message: ChatMessage) {
        self.messages.append(message)
        self.persistMessages()
    }

    private func loadPersistedMessages() {
        guard let data = try? Data(contentsOf: self.messagesURL),
              let decoded = try? self.decoder.decode([ChatMessage].self, from: data)
        else {
            return
        }
        self.messages = decoded
    }

    private func persistMessages() {
        do {
            let data = try self.encoder.encode(self.messages)
            try data.write(to: self.messagesURL, options: [.atomic])
        } catch {
            self.statusText = "Warning: failed to save chat history."
        }
    }

    private func loadPersistedSettings() {
        guard let data = try? Data(contentsOf: self.settingsURL),
              let settings = try? self.decoder.decode(PersistedSettings.self, from: data)
        else {
            return
        }

        self.discordBotToken = settings.discordBotToken ?? ""
        self.discordChannelID = settings.discordChannelID ?? ""
        self.telegramBotToken = settings.telegramBotToken ?? ""
        self.telegramChatID = settings.telegramChatID ?? ""
        self.slackBotToken = settings.slackBotToken ?? ""
        self.slackAppToken = settings.slackAppToken ?? ""
        self.slackSigningSecret = settings.slackSigningSecret ?? ""
        self.slackChannelID = settings.slackChannelID ?? ""
        self.googleChatBearerToken = settings.googleChatBearerToken ?? ""
        self.googleChatVerificationToken = settings.googleChatVerificationToken ?? ""
        self.googleChatSpaceID = settings.googleChatSpaceID ?? ""
        self.signalServiceURL = settings.signalServiceURL ?? "http://127.0.0.1:8080"
        self.signalAccountID = settings.signalAccountID ?? ""
        self.signalAuthToken = settings.signalAuthToken ?? ""
        self.signalRecipient = settings.signalRecipient ?? ""
        self.msteamsBotAppID = settings.msteamsBotAppID ?? ""
        self.msteamsBotAppPassword = settings.msteamsBotAppPassword ?? ""
        self.msteamsTenantID = settings.msteamsTenantID ?? ""
        self.msteamsConversationID = settings.msteamsConversationID ?? ""
        self.msteamsServiceURL = settings.msteamsServiceURL ?? "https://smba.trafficmanager.net/teams/"
        self.webchatSharedSecret = settings.webchatSharedSecret ?? ""
        self.openAIAPIKey = settings.openAIAPIKey ?? ""
        self.openAICompatibleAPIKey = settings.openAICompatibleAPIKey ?? ""
        self.openAICompatibleBaseURL = settings.openAICompatibleBaseURL ?? "https://api.openai.com/v1"
        self.anthropicAPIKey = settings.anthropicAPIKey ?? ""
        self.geminiAPIKey = settings.geminiAPIKey ?? ""
        self.providerServiceAPIKey = settings.providerServiceAPIKey ?? ""
        self.providerServiceAccessToken = settings.providerServiceAccessToken ?? ""
        self.providerServiceBaseURL = settings.providerServiceBaseURL ?? ""
        self.providerServiceRegion = settings.providerServiceRegion ?? "us-east-1"
        self.providerServiceProfile = settings.providerServiceProfile ?? "default"
        self.selectedProvider = settings.selectedProvider ?? Self.preferredDefaultProvider()
        self.selectedModelID = settings.selectedModelID ?? self.selectedProvider.defaultModelID
        self.localRuntime = settings.localRuntime ?? "llmfarm"
        self.localModelPath = settings.localModelPath ?? ""
        self.localFallbackModelPaths = settings.localFallbackModelPaths ?? ""
        self.localContextWindow = settings.localContextWindow ?? 4096
        self.localTemperature = settings.localTemperature ?? 0.7
        self.localTopP = settings.localTopP ?? 0.95
        self.localTopK = settings.localTopK ?? 40
        self.localMaxTokens = settings.localMaxTokens ?? 512
        self.localUseMetal = settings.localUseMetal ?? true
        self.localStreamTokens = settings.localStreamTokens ?? true
        self.localAllowCancellation = settings.localAllowCancellation ?? true
        self.localRequestTimeoutMs = settings.localRequestTimeoutMs ?? 60_000
        self.defaultAgentID = settings.defaultAgentID ?? "main"
        self.discordAgentID = settings.discordAgentID ?? ""
        self.webchatAgentID = settings.webchatAgentID ?? ""
        self.personality = settings.personality ?? ""
    }

    private func persistSettings() throws {
        let settings = PersistedSettings(
            discordBotToken: self.discordBotToken,
            discordChannelID: self.discordChannelID,
            telegramBotToken: self.telegramBotToken,
            telegramChatID: self.telegramChatID,
            slackBotToken: self.slackBotToken,
            slackAppToken: self.slackAppToken,
            slackSigningSecret: self.slackSigningSecret,
            slackChannelID: self.slackChannelID,
            googleChatBearerToken: self.googleChatBearerToken,
            googleChatVerificationToken: self.googleChatVerificationToken,
            googleChatSpaceID: self.googleChatSpaceID,
            signalServiceURL: self.signalServiceURL,
            signalAccountID: self.signalAccountID,
            signalAuthToken: self.signalAuthToken,
            signalRecipient: self.signalRecipient,
            msteamsBotAppID: self.msteamsBotAppID,
            msteamsBotAppPassword: self.msteamsBotAppPassword,
            msteamsTenantID: self.msteamsTenantID,
            msteamsConversationID: self.msteamsConversationID,
            msteamsServiceURL: self.msteamsServiceURL,
            webchatSharedSecret: self.webchatSharedSecret,
            openAIAPIKey: self.openAIAPIKey,
            openAICompatibleAPIKey: self.openAICompatibleAPIKey,
            openAICompatibleBaseURL: self.openAICompatibleBaseURL,
            anthropicAPIKey: self.anthropicAPIKey,
            geminiAPIKey: self.geminiAPIKey,
            providerServiceAPIKey: self.providerServiceAPIKey,
            providerServiceAccessToken: self.providerServiceAccessToken,
            providerServiceBaseURL: self.providerServiceBaseURL,
            providerServiceRegion: self.providerServiceRegion,
            providerServiceProfile: self.providerServiceProfile,
            selectedProvider: self.selectedProvider,
            selectedModelID: self.selectedModelID,
            localRuntime: self.localRuntime,
            localModelPath: self.localModelPath,
            localFallbackModelPaths: self.localFallbackModelPaths,
            localContextWindow: self.localContextWindow,
            localTemperature: self.localTemperature,
            localTopP: self.localTopP,
            localTopK: self.localTopK,
            localMaxTokens: self.localMaxTokens,
            localUseMetal: self.localUseMetal,
            localStreamTokens: self.localStreamTokens,
            localAllowCancellation: self.localAllowCancellation,
            localRequestTimeoutMs: self.localRequestTimeoutMs,
            defaultAgentID: self.defaultAgentID,
            discordAgentID: self.discordAgentID,
            webchatAgentID: self.webchatAgentID,
            personality: self.personality
        )
        try FileManager.default.createDirectory(at: self.stateRoot, withIntermediateDirectories: true)
        let data = try self.encoder.encode(settings)
        try data.write(to: self.settingsURL, options: [.atomic])
    }

    /// Persists personality text as workspace bootstrap context.
    private func persistBootstrapFiles() throws {
        try FileManager.default.createDirectory(at: self.workspaceURL, withIntermediateDirectories: true)
        let soulURL = self.workspaceURL.appendingPathComponent("SOUL.md")
        let trimmed = self.personality.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if FileManager.default.fileExists(atPath: soulURL.path) {
                try FileManager.default.removeItem(at: soulURL)
            }
            return
        }
        try trimmed.write(to: soulURL, atomically: true, encoding: .utf8)
    }

    /// Syncs bundled example skills into the app sandbox workspace.
    private func syncExampleSkillsIntoWorkspace() throws {
        guard let sourceSkillsRoot = Self.resolveExampleSkillsRoot(),
              FileManager.default.fileExists(atPath: sourceSkillsRoot.path)
        else {
            return
        }

        let destinationSkillsRoot = self.workspaceURL.appendingPathComponent("skills", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationSkillsRoot, withIntermediateDirectories: true)
        let sourceEntries = try FileManager.default.contentsOfDirectory(
            at: sourceSkillsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for sourceEntry in sourceEntries {
            guard (try? sourceEntry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }
            let destinationEntry = destinationSkillsRoot.appendingPathComponent(sourceEntry.lastPathComponent)
            if FileManager.default.fileExists(atPath: destinationEntry.path) {
                try FileManager.default.removeItem(at: destinationEntry)
            }
            try FileManager.default.copyItem(at: sourceEntry, to: destinationEntry)
        }
    }

    /// Resolves the tvOS example `skills` directory from bundle or source tree.
    private static func resolveExampleSkillsRoot() -> URL? {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("skills", isDirectory: true),
           FileManager.default.fileExists(atPath: bundled.path)
        {
            return bundled
        }

        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("skills", isDirectory: true)
        if FileManager.default.fileExists(atPath: sourceRoot.path) {
            return sourceRoot
        }
        return nil
    }
}

/// Returns a trimmed value or `nil` when empty.
private func normalized(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}
