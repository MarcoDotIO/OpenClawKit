import Foundation
import OpenClawKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Observable app state coordinating deployment and chat flows in the iOS example.
@MainActor
final class OpenClawAppState: ObservableObject {
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

    /// User-selectable provider choices surfaced in deploy settings.
    enum DeployProvider: String, Codable, CaseIterable, Identifiable, Sendable {
        case echo
        case openAI
        case openAICompatible
        case anthropic
        case gemini
        case foundation
        case local

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
            }
        }
    }

    /// Persisted chat message model used by local transcript storage.
    struct ChatMessage: Identifiable, Codable, Sendable, Equatable {
        let id: UUID
        let role: MessageRole
        let text: String
        let createdAt: Date

        /// Creates a chat message.
        /// - Parameters:
        ///   - id: Stable message identifier.
        ///   - role: Message role label.
        ///   - text: Message text.
        ///   - createdAt: Creation timestamp.
        init(id: UUID = UUID(), role: MessageRole, text: String, createdAt: Date = Date()) {
            self.id = id
            self.role = role
            self.text = text
            self.createdAt = createdAt
        }
    }

    /// Render model for a discovered skill row in the iOS app.
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

    /// Render model for one staged chat attachment.
    struct PendingAttachment: Identifiable, Sendable, Equatable {
        let id: UUID
        let fileName: String
        let mimeType: String
        let data: Data

        var byteCount: Int {
            self.data.count
        }

        var byteCountLabel: String {
            ByteCountFormatter.string(fromByteCount: Int64(self.byteCount), countStyle: .file)
        }

        var mediaAttachment: MediaAttachment {
            MediaAttachment(
                id: self.id,
                mimeType: self.mimeType,
                data: self.data,
                fileName: self.fileName
            )
        }
    }

    /// Render model for channel health rows.
    struct ChannelHealthItem: Identifiable, Sendable, Equatable {
        let id: String
        let status: ChannelHealthStatus
        let consecutiveFailures: Int
        let lastError: String?
        let lastSuccessAt: Date?
        let lastFailureAt: Date?
    }

    /// Render model for route mapping previews.
    struct RouteMappingItem: Identifiable, Sendable, Equatable {
        let id: String
        let route: String
        let agentID: String
    }

    /// Persisted deployment settings loaded/saved between launches.
    struct PersistedSettings: Codable, Sendable {
        var discordBotToken: String
        var discordChannelID: String
        var telegramBotToken: String
        var telegramChatID: String
        var openAIAPIKey: String
        var openAICompatibleAPIKey: String
        var openAICompatibleBaseURL: String
        var anthropicAPIKey: String
        var geminiAPIKey: String
        var selectedProvider: DeployProvider
        var selectedModelID: String
        var localRuntime: String
        var localModelPath: String
        var localFallbackModelPaths: String
        var localContextWindow: Int
        var localTemperature: Double
        var localTopP: Double
        var localTopK: Int
        var localMaxTokens: Int
        var localUseMetal: Bool
        var localStreamTokens: Bool
        var localAllowCancellation: Bool
        var localRequestTimeoutMs: Int
        var defaultAgentID: String
        var discordAgentID: String
        var webchatAgentID: String
        var personality: String

        init(
            discordChannelID: String,
            openAICompatibleBaseURL: String,
            selectedProvider: DeployProvider,
            selectedModelID: String,
            localRuntime: String,
            localModelPath: String,
            localFallbackModelPaths: String,
            localContextWindow: Int,
            localTemperature: Double,
            localTopP: Double,
            localTopK: Int,
            localMaxTokens: Int,
            localUseMetal: Bool,
            localStreamTokens: Bool,
            localAllowCancellation: Bool,
            localRequestTimeoutMs: Int,
            defaultAgentID: String,
            discordAgentID: String,
            webchatAgentID: String,
            personality: String,
            discordBotToken: String = "",
            telegramBotToken: String = "",
            telegramChatID: String = "",
            openAIAPIKey: String = "",
            openAICompatibleAPIKey: String = "",
            anthropicAPIKey: String = "",
            geminiAPIKey: String = ""
        ) {
            self.discordBotToken = discordBotToken
            self.discordChannelID = discordChannelID
            self.telegramBotToken = telegramBotToken
            self.telegramChatID = telegramChatID
            self.openAIAPIKey = openAIAPIKey
            self.openAICompatibleAPIKey = openAICompatibleAPIKey
            self.openAICompatibleBaseURL = openAICompatibleBaseURL
            self.anthropicAPIKey = anthropicAPIKey
            self.geminiAPIKey = geminiAPIKey
            self.selectedProvider = selectedProvider
            self.selectedModelID = selectedModelID
            self.localRuntime = localRuntime
            self.localModelPath = localModelPath
            self.localFallbackModelPaths = localFallbackModelPaths
            self.localContextWindow = localContextWindow
            self.localTemperature = localTemperature
            self.localTopP = localTopP
            self.localTopK = localTopK
            self.localMaxTokens = localMaxTokens
            self.localUseMetal = localUseMetal
            self.localStreamTokens = localStreamTokens
            self.localAllowCancellation = localAllowCancellation
            self.localRequestTimeoutMs = localRequestTimeoutMs
            self.defaultAgentID = defaultAgentID
            self.discordAgentID = discordAgentID
            self.webchatAgentID = webchatAgentID
            self.personality = personality
        }

        private enum CodingKeys: String, CodingKey {
            case discordChannelID
            case telegramChatID
            case openAICompatibleBaseURL
            case selectedProvider
            case selectedModelID
            case localRuntime
            case localModelPath
            case localFallbackModelPaths
            case localContextWindow
            case localTemperature
            case localTopP
            case localTopK
            case localMaxTokens
            case localUseMetal
            case localStreamTokens
            case localAllowCancellation
            case localRequestTimeoutMs
            case defaultAgentID
            case discordAgentID
            case webchatAgentID
            case personality
        }

        private enum LegacySecretCodingKeys: String, CodingKey {
            case discordBotToken
            case telegramBotToken
            case openAIAPIKey
            case openAICompatibleAPIKey
            case anthropicAPIKey
            case geminiAPIKey
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.discordChannelID = try container.decodeIfPresent(String.self, forKey: .discordChannelID) ?? ""
            self.telegramChatID = try container.decodeIfPresent(String.self, forKey: .telegramChatID) ?? ""
            self.openAICompatibleBaseURL = try container.decodeIfPresent(String.self, forKey: .openAICompatibleBaseURL) ?? "https://api.openai.com/v1"
            self.selectedProvider = try container.decodeIfPresent(DeployProvider.self, forKey: .selectedProvider) ?? .openAI
            self.selectedModelID = try container.decodeIfPresent(String.self, forKey: .selectedModelID) ?? self.selectedProvider.defaultModelID
            self.localRuntime = try container.decodeIfPresent(String.self, forKey: .localRuntime) ?? "llmfarm"
            self.localModelPath = try container.decodeIfPresent(String.self, forKey: .localModelPath) ?? ""
            self.localFallbackModelPaths = try container.decodeIfPresent(String.self, forKey: .localFallbackModelPaths) ?? ""
            self.localContextWindow = max(256, try container.decodeIfPresent(Int.self, forKey: .localContextWindow) ?? 4096)
            self.localTemperature = try container.decodeIfPresent(Double.self, forKey: .localTemperature) ?? 0.7
            self.localTopP = try container.decodeIfPresent(Double.self, forKey: .localTopP) ?? 0.95
            self.localTopK = max(1, try container.decodeIfPresent(Int.self, forKey: .localTopK) ?? 40)
            self.localMaxTokens = max(1, try container.decodeIfPresent(Int.self, forKey: .localMaxTokens) ?? 512)
            self.localUseMetal = try container.decodeIfPresent(Bool.self, forKey: .localUseMetal) ?? true
            self.localStreamTokens = try container.decodeIfPresent(Bool.self, forKey: .localStreamTokens) ?? true
            self.localAllowCancellation = try container.decodeIfPresent(Bool.self, forKey: .localAllowCancellation) ?? true
            self.localRequestTimeoutMs = max(1, try container.decodeIfPresent(Int.self, forKey: .localRequestTimeoutMs) ?? 60_000)
            self.defaultAgentID = try container.decodeIfPresent(String.self, forKey: .defaultAgentID) ?? "main"
            self.discordAgentID = try container.decodeIfPresent(String.self, forKey: .discordAgentID) ?? ""
            self.webchatAgentID = try container.decodeIfPresent(String.self, forKey: .webchatAgentID) ?? ""
            self.personality = try container.decodeIfPresent(String.self, forKey: .personality) ?? ""

            let legacy = try decoder.container(keyedBy: LegacySecretCodingKeys.self)
            self.discordBotToken = try legacy.decodeIfPresent(String.self, forKey: .discordBotToken) ?? ""
            self.telegramBotToken = try legacy.decodeIfPresent(String.self, forKey: .telegramBotToken) ?? ""
            self.openAIAPIKey = try legacy.decodeIfPresent(String.self, forKey: .openAIAPIKey) ?? ""
            self.openAICompatibleAPIKey = try legacy.decodeIfPresent(String.self, forKey: .openAICompatibleAPIKey) ?? ""
            self.anthropicAPIKey = try legacy.decodeIfPresent(String.self, forKey: .anthropicAPIKey) ?? ""
            self.geminiAPIKey = try legacy.decodeIfPresent(String.self, forKey: .geminiAPIKey) ?? ""
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(self.discordChannelID, forKey: .discordChannelID)
            try container.encode(self.telegramChatID, forKey: .telegramChatID)
            try container.encode(self.openAICompatibleBaseURL, forKey: .openAICompatibleBaseURL)
            try container.encode(self.selectedProvider, forKey: .selectedProvider)
            try container.encode(self.selectedModelID, forKey: .selectedModelID)
            try container.encode(self.localRuntime, forKey: .localRuntime)
            try container.encode(self.localModelPath, forKey: .localModelPath)
            try container.encode(self.localFallbackModelPaths, forKey: .localFallbackModelPaths)
            try container.encode(self.localContextWindow, forKey: .localContextWindow)
            try container.encode(self.localTemperature, forKey: .localTemperature)
            try container.encode(self.localTopP, forKey: .localTopP)
            try container.encode(self.localTopK, forKey: .localTopK)
            try container.encode(self.localMaxTokens, forKey: .localMaxTokens)
            try container.encode(self.localUseMetal, forKey: .localUseMetal)
            try container.encode(self.localStreamTokens, forKey: .localStreamTokens)
            try container.encode(self.localAllowCancellation, forKey: .localAllowCancellation)
            try container.encode(self.localRequestTimeoutMs, forKey: .localRequestTimeoutMs)
            try container.encode(self.defaultAgentID, forKey: .defaultAgentID)
            try container.encode(self.discordAgentID, forKey: .discordAgentID)
            try container.encode(self.webchatAgentID, forKey: .webchatAgentID)
            try container.encode(self.personality, forKey: .personality)
        }
    }

    /// Secret values that may need secure-store migration.
    private struct SecretSnapshot: Sendable, Equatable {
        var discordBotToken: String
        var telegramBotToken: String
        var openAIAPIKey: String
        var openAICompatibleAPIKey: String
        var anthropicAPIKey: String
        var geminiAPIKey: String

        static let empty = SecretSnapshot(
            discordBotToken: "",
            telegramBotToken: "",
            openAIAPIKey: "",
            openAICompatibleAPIKey: "",
            anthropicAPIKey: "",
            geminiAPIKey: ""
        )

        var legacySecretsByStoreKey: [String: String] {
            [
                SecretStoreKey.discordBotToken: self.discordBotToken,
                SecretStoreKey.telegramBotToken: self.telegramBotToken,
                SecretStoreKey.openAIAPIKey: self.openAIAPIKey,
                SecretStoreKey.openAICompatibleAPIKey: self.openAICompatibleAPIKey,
                SecretStoreKey.anthropicAPIKey: self.anthropicAPIKey,
                SecretStoreKey.geminiAPIKey: self.geminiAPIKey,
            ]
        }

        var containsAnySecret: Bool {
            !self.discordBotToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                !self.telegramBotToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                !self.openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                !self.openAICompatibleAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                !self.anthropicAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                !self.geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Stable secret keys used by the credential store.
    private enum SecretStoreKey {
        static let discordBotToken = "channels.discord.botToken"
        static let telegramBotToken = "channels.telegram.botToken"
        static let openAIAPIKey = "models.openai.apiKey"
        static let openAICompatibleAPIKey = "models.openaiCompatible.apiKey"
        static let anthropicAPIKey = "models.anthropic.apiKey"
        static let geminiAPIKey = "models.gemini.apiKey"

        static let ordered: [String] = [
            discordBotToken,
            telegramBotToken,
            openAIAPIKey,
            openAICompatibleAPIKey,
            anthropicAPIKey,
            geminiAPIKey,
        ]
    }

    @Published var discordBotToken: String = ""
    @Published var discordChannelID: String = ""
    @Published var telegramBotToken: String = ""
    @Published var telegramChatID: String = ""
    @Published var openAIAPIKey: String = ""
    @Published var openAICompatibleAPIKey: String = ""
    @Published var openAICompatibleBaseURL: String = "https://api.openai.com/v1"
    @Published var anthropicAPIKey: String = ""
    @Published var geminiAPIKey: String = ""
    @Published var selectedProvider: DeployProvider = .openAI
    @Published var selectedModelID: String = DeployProvider.openAI.defaultModelID
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
    @Published private(set) var pendingAttachments: [PendingAttachment] = []

    @Published private(set) var deploymentState: DeploymentState = .stopped
    @Published private(set) var statusText: String = "Not deployed"
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var latestSummary: String = ""
    @Published private(set) var skillItems: [SkillItem] = []
    @Published private(set) var channelHealthItems: [ChannelHealthItem] = []
    @Published private(set) var diagnosticEvents: [RuntimeDiagnosticEvent] = []
    @Published private(set) var usageSnapshot: RuntimeUsageSnapshot?
    @Published private(set) var activeRetryPolicy: ChannelSendRetryPolicy = ChannelSendRetryPolicy()
    @Published private(set) var latestIntentGraph: IntentGraph?
    @Published private(set) var liveActivityStatusText: String = "Idle"

    /// Returns whether runtime deployment is actively running.
    var isDeployed: Bool {
        self.deploymentState == .running
    }

    /// Returns whether there are staged media attachments waiting to be sent.
    var hasPendingAttachments: Bool {
        !self.pendingAttachments.isEmpty
    }

    /// All available provider selections rendered by deploy UI.
    var availableProviders: [DeployProvider] {
        DeployProvider.allCases
    }

    /// User-invocable skills rendered in the chat skill picker.
    var selectableSkillItems: [SkillItem] {
        self.skillItems
            .filter(\.userInvocable)
            .sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    /// Route mapping preview used by Channels tab.
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

    /// Most recent skill invocation summary derived from diagnostics events.
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
    private let liveActivityCoordinator = AgentRunLiveActivityCoordinator()

    private let stateRoot: URL
    private let workspaceURL: URL
    private let configURL: URL
    private let sessionsURL: URL
    private let messagesURL: URL
    private let settingsURL: URL
    private let credentialsFallbackURL: URL
    private let conversationMemoryURL: URL
    private let automationRulesURL: URL
    private let credentialStore: any CredentialStore
    private let sharedConversationSessionKey = "shared"
    private let maxPendingAttachmentBytes = 10 * 1024 * 1024
    private let maxPendingAttachmentCount = 4

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
    private var legacySecrets: SecretSnapshot = .empty
    private var secretsHydrated = false
    private var lastLiveActivityProcessedAt = Date.distantPast

    /// Creates and initializes app state from persisted local storage.
    init() {
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ??
            URL(fileURLWithPath: NSTemporaryDirectory())
        self.stateRoot = docs.appendingPathComponent("OpenClawDemo", isDirectory: true)
        self.workspaceURL = self.stateRoot.appendingPathComponent("workspace", isDirectory: true)
        self.configURL = self.stateRoot.appendingPathComponent("config.json")
        self.sessionsURL = self.stateRoot.appendingPathComponent("sessions.json")
        self.messagesURL = self.stateRoot.appendingPathComponent("chat-messages.json")
        self.settingsURL = self.stateRoot.appendingPathComponent("deploy-settings.json")
        self.credentialsFallbackURL = self.stateRoot.appendingPathComponent("credentials.json")
        self.conversationMemoryURL = self.stateRoot.appendingPathComponent("conversation-memory.json")
        self.automationRulesURL = self.stateRoot.appendingPathComponent("automation-rules.json")
        self.credentialStore = CredentialStoreFactory.makeDefault(
            fallbackFileURL: self.credentialsFallbackURL,
            keychainService: "io.marcodotio.openclawkit.examples.ios.credentials"
        )

        self.loadPersistedSettings()
        self.loadPersistedMessages()
        Task {
            await self.loadSecureSecretsAndMigrateLegacy()
        }
    }

    /// Starts runtime deployment using current credentials and settings.
    func deploy() async {
        guard self.deploymentState != .starting, self.deploymentState != .running else { return }
        self.deploymentState = .starting
        self.statusText = "Starting deployment..."

        do {
            try FileManager.default.createDirectory(at: self.stateRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: self.workspaceURL, withIntermediateDirectories: true)
            if !self.secretsHydrated {
                await self.loadSecureSecretsAndMigrateLegacy()
            }
            try await self.persistSecretsToSecureStore()
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
            let modelsConfig = try self.makeModelsConfig()
            let agentsConfig = self.makeAgentsConfig()

            let config = OpenClawConfig(
                agents: agentsConfig,
                channels: ChannelsConfig(discord: discordConfig, telegram: telegramConfig),
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
        await self.liveActivityCoordinator.stopAll()

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
        BackgroundContinuationManager.shared.bindAutomationTickHandler(nil)
        self.skillItems = []
        self.channelHealthItems = []
        self.diagnosticEvents = []
        self.usageSnapshot = nil
        self.activeRetryPolicy = ChannelSendRetryPolicy()
        self.latestIntentGraph = nil
        self.liveActivityStatusText = "Idle"
        self.lastLiveActivityProcessedAt = Date.distantPast
        self.pendingAttachments = []
        self.deploymentState = .stopped
        self.statusText = "Deployment stopped."
    }

    /// Builds model config from current deploy-provider selections.
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

    /// Builds model config from current deploy-provider selections.
    private func makeModelsConfig() throws -> ModelsConfig {
        let selectedModelID = normalized(self.selectedModelID) ?? self.selectedProvider.defaultModelID

        switch self.selectedProvider {
        case .echo:
            return ModelsConfig(
                defaultProviderID: EchoModelProvider.defaultID
            )
        case .openAI:
            guard let apiKey = normalized(self.openAIAPIKey) else {
                throw OpenClawCoreError.invalidConfiguration("OpenAI API key is required for OpenAI provider")
            }
            return ModelsConfig(
                defaultProviderID: OpenAIModelProvider.providerID,
                openAI: OpenAIModelConfig(
                    enabled: true,
                    modelID: selectedModelID,
                    apiKey: apiKey
                )
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
                anthropic: AnthropicModelConfig(
                    enabled: true,
                    modelID: selectedModelID,
                    apiKey: apiKey
                )
            )
        case .gemini:
            guard let apiKey = normalized(self.geminiAPIKey) else {
                throw OpenClawCoreError.invalidConfiguration("Gemini API key is required for Gemini provider")
            }
            return ModelsConfig(
                defaultProviderID: GeminiModelProvider.providerID,
                gemini: GeminiModelConfig(
                    enabled: true,
                    modelID: selectedModelID,
                    apiKey: apiKey
                )
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
            let configuredModelPath = normalized(self.localModelPath)
            return ModelsConfig(
                defaultProviderID: LocalModelProvider.providerID,
                local: LocalModelConfig(
                    enabled: true,
                    runtime: normalized(self.localRuntime) ?? "llmfarm",
                    modelPath: configuredModelPath,
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
        }
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
        BackgroundContinuationManager.shared.bindAutomationTickHandler { [weak self] in
            await self?.runProactiveAutomationTick()
        }
    }

    /// Executes one proactive automation tick from app/background hooks.
    private func runProactiveAutomationTick() async {
        guard let automationRunner else {
            return
        }
        let outcomes = await automationRunner.runDueAutomations()
        guard !outcomes.isEmpty else {
            return
        }
        let succeeded = outcomes.filter(\.succeeded).count
        let failed = outcomes.count - succeeded
        self.statusText = "Automation tick: \(succeeded) succeeded, \(failed) failed."
    }

    /// Sends the currently drafted message if non-empty.
    func sendPendingMessage() async {
        let text = self.pendingMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let staged = self.pendingAttachments.map(\.mediaAttachment)
        guard !text.isEmpty || !staged.isEmpty else { return }
        self.pendingMessage = ""
        self.pendingAttachments = []
        let normalizedText = text.isEmpty ? "Analyze the attached media and summarize the key details." : text
        await self.sendMessage(self.composePrompt(normalizedText), attachments: staged)
    }

    /// Stages one attachment for the next chat request.
    @discardableResult
    func stageAttachment(data: Data, mimeType: String, fileName: String? = nil) -> Bool {
        guard !data.isEmpty else {
            self.statusText = "Attachment was empty."
            return false
        }
        guard data.count <= self.maxPendingAttachmentBytes else {
            self.statusText = "Attachment exceeds 10 MB limit."
            return false
        }
        guard self.pendingAttachments.count < self.maxPendingAttachmentCount else {
            self.statusText = "Maximum attachment count reached (4)."
            return false
        }

        let trimmedName = fileName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedName: String
        if trimmedName.isEmpty {
            resolvedName = "attachment-\(self.pendingAttachments.count + 1)"
        } else {
            resolvedName = trimmedName
        }
        let trimmedMimeType = mimeType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let resolvedMimeType = trimmedMimeType.isEmpty ? "application/octet-stream" : trimmedMimeType
        let attachment = PendingAttachment(
            id: UUID(),
            fileName: resolvedName,
            mimeType: resolvedMimeType,
            data: data
        )
        self.pendingAttachments.append(attachment)
        self.statusText = "Attached \(resolvedName) (\(attachment.byteCountLabel))."
        return true
    }

    /// Imports one attachment file URL and stages it for the next send.
    @discardableResult
    func importAttachment(from fileURL: URL) -> Bool {
        let didAccess = fileURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let inferredMimeType = Self.mimeType(for: fileURL)
            return self.stageAttachment(
                data: data,
                mimeType: inferredMimeType,
                fileName: fileURL.lastPathComponent
            )
        } catch {
            self.statusText = "Unable to import attachment."
            return false
        }
    }

    /// Removes one staged attachment by identifier.
    func removePendingAttachment(id: UUID) {
        self.pendingAttachments.removeAll(where: { $0.id == id })
    }

    /// Clears all staged attachments.
    func clearPendingAttachments() {
        self.pendingAttachments = []
    }

    /// Executes a quick ask through the SDK intent-graph run API.
    /// - Parameters:
    ///   - prompt: User input prompt.
    ///   - focusNodeKind: Optional node-kind focus for graph summary.
    /// - Returns: Assistant output text.
    func quickAskUsingIntentGraph(
        _ prompt: String,
        focusNodeKind: IntentGraphNodeKind? = nil
    ) async -> String {
        guard self.deploymentState == .running else {
            return "Deploy the agent before using Quick Ask."
        }
        guard let runtime else {
            return "OpenClaw runtime is unavailable."
        }

        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            return "Prompt is empty."
        }

        self.appendMessage(.init(role: .user, text: trimmedPrompt))
        do {
            let request = AgentRunRequest(
                sessionKey: self.sharedConversationSessionKey,
                prompt: trimmedPrompt,
                modelProviderID: self.selectedProvider.providerID,
                workspaceRootPath: self.workspaceURL.path
            )
            let graphRun = try await self.sdk.runIntentGraph(
                request,
                runtime: runtime,
                timeoutMs: max(1, self.localRequestTimeoutMs)
            )
            self.latestIntentGraph = graphRun.graph

            let summary = Self.intentGraphSummary(
                for: graphRun.graph,
                focusNodeKind: focusNodeKind
            )
            let assistantText = summary.isEmpty ? graphRun.result.output : "\(graphRun.result.output)\n\n\(summary)"
            self.appendMessage(.init(role: .assistant, text: assistantText))
            await self.refreshObservabilityState()
            return assistantText
        } catch {
            let failure = "Quick Ask failed: \(error.localizedDescription)"
            self.appendMessage(.init(role: .system, text: failure))
            return failure
        }
    }

    /// Builds a graph summary without executing a model response.
    /// - Parameters:
    ///   - prompt: User input prompt.
    ///   - focusNodeKind: Optional node-kind focus for graph summary.
    /// - Returns: Graph summary text.
    func previewIntentGraphSummary(
        for prompt: String,
        focusNodeKind: IntentGraphNodeKind? = nil
    ) async -> String {
        guard self.deploymentState == .running else {
            return "Deploy the agent before previewing intent graph."
        }
        guard let runtime else {
            return "OpenClaw runtime is unavailable."
        }

        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            return "Prompt is empty."
        }

        let request = AgentRunRequest(
            sessionKey: self.sharedConversationSessionKey,
            prompt: trimmedPrompt,
            modelProviderID: self.selectedProvider.providerID,
            workspaceRootPath: self.workspaceURL.path
        )
        let graph = await self.sdk.makeIntentGraph(for: request, runtime: runtime)
        self.latestIntentGraph = graph
        return Self.intentGraphSummary(for: graph, focusNodeKind: focusNodeKind)
    }

    /// Sends a chat message through the active auto-reply engine.
    /// - Parameter text: User input message text.
    func sendMessage(_ text: String, attachments: [MediaAttachment] = []) async {
        guard let replyEngine, self.deploymentState == .running else {
            self.statusText = "Deploy the agent before sending messages."
            return
        }

        self.appendMessage(.init(role: .user, text: Self.composeUserTimelineText(text, attachments: attachments)))
        do {
            let outbound = try await replyEngine.process(
                InboundMessage(
                    channel: .webchat,
                    peerID: "ios-local-user",
                    text: text,
                    attachments: attachments
                )
            )
            self.appendMessage(.init(role: .assistant, text: outbound.text))
        } catch {
            self.appendMessage(.init(role: .system, text: "Error: \(error.localizedDescription)"))
        }
        await self.refreshObservabilityState()
    }

    private func composePrompt(_ text: String) -> String {
        guard let selected = normalized(self.selectedSkillName),
              self.selectableSkillItems.contains(where: { $0.name == selected })
        else {
            return text
        }
        return "/\(selected) \(text)"
    }

    /// Builds user-visible timeline text with staged attachment summary.
    private static func composeUserTimelineText(_ text: String, attachments: [MediaAttachment]) -> String {
        guard !attachments.isEmpty else {
            return text
        }
        let names = attachments
            .compactMap { attachment in
                let trimmed = attachment.fileName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? nil : trimmed
            }
        let suffix: String
        if names.isEmpty {
            suffix = "[Attachments] \(attachments.count) item(s)"
        } else {
            suffix = "[Attachments] \(names.joined(separator: ", "))"
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return suffix
        }
        return "\(text)\n\(suffix)"
    }

    /// Resolves MIME type from URL extension/type metadata.
    private static func mimeType(for fileURL: URL) -> String {
        if let type = UTType(filenameExtension: fileURL.pathExtension),
           let mimeType = type.preferredMIMEType,
           !mimeType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return mimeType
        }
        return "application/octet-stream"
    }

    /// Builds a compact human-readable summary for an intent graph.
    private static func intentGraphSummary(
        for graph: IntentGraph,
        focusNodeKind: IntentGraphNodeKind?
    ) -> String {
        var components: [String] = [
            "Intent Graph: \(graph.nodes.count) nodes, \(graph.edges.count) edges",
        ]
        if let focusNodeKind {
            let matchingCount = graph.nodes.filter { $0.kind == focusNodeKind }.count
            components.append("focus '\(focusNodeKind.rawValue)' matches \(matchingCount)")
        }
        return components.joined(separator: " • ")
    }

    /// Starts background summary scheduler polling loop.
    private func startSummaryLoop() {
        self.summaryTask?.cancel()
        self.summaryTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let due = await self.summaryScheduler.runDue()
                if !due.isEmpty {
                    await self.summarizeChatMemory()
                }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    /// Forces an immediate refresh of diagnostics, channels, and discovered skills.
    func refreshObservabilityNow() async {
        await self.refreshObservabilityState()
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
            await self.syncLiveActivities(with: self.diagnosticEvents)
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
                    lastError: snapshot.lastError,
                    lastSuccessAt: snapshot.lastSuccessAt,
                    lastFailureAt: snapshot.lastFailureAt
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

    /// Streams unprocessed runtime events into Live Activities updates.
    private func syncLiveActivities(with events: [RuntimeDiagnosticEvent]) async {
        let sorted = events.sorted { lhs, rhs in
            lhs.occurredAt < rhs.occurredAt
        }
        var latestProcessed = self.lastLiveActivityProcessedAt

        for event in sorted {
            guard event.subsystem == "runtime" else {
                continue
            }
            guard event.occurredAt > latestProcessed else {
                continue
            }
            await self.liveActivityCoordinator.handle(event: event)
            latestProcessed = event.occurredAt
            self.updateLiveActivityStatus(from: event)
        }

        self.lastLiveActivityProcessedAt = latestProcessed
    }

    /// Updates status text mirrored in the Deploy tab for live activity lifecycle.
    private func updateLiveActivityStatus(from event: RuntimeDiagnosticEvent) {
        guard let runID = event.runID, !runID.isEmpty else {
            return
        }
        let shortRunID = String(runID.prefix(8))
        switch event.name {
        case "run.started":
            self.liveActivityStatusText = "Active run: \(shortRunID)"
        case "run.completed":
            self.liveActivityStatusText = "Completed run: \(shortRunID)"
        case "run.failed":
            self.liveActivityStatusText = "Failed run: \(shortRunID)"
        default:
            break
        }
    }

    /// Resolves preferred entrypoint hint from skill frontmatter keys.
    private static func skillEntrypointHint(for skill: SkillDefinition) -> String? {
        for key in ["entrypoint", "script", "run"] {
            if let value = skill.frontmatter[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return nil
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

    /// Appends a message to timeline and persists transcript.
    /// - Parameter message: Message to append.
    private func appendMessage(_ message: ChatMessage) {
        self.messages.append(message)
        self.persistMessages()
    }

    /// Loads persisted transcript messages from disk.
    private func loadPersistedMessages() {
        guard let data = try? Data(contentsOf: self.messagesURL),
              let decoded = try? self.decoder.decode([ChatMessage].self, from: data)
        else {
            return
        }
        self.messages = decoded
    }

    /// Persists transcript messages to local storage.
    private func persistMessages() {
        do {
            let data = try self.encoder.encode(self.messages)
            try data.write(to: self.messagesURL, options: [.atomic])
        } catch {
            self.statusText = "Warning: failed to save chat history."
        }
    }

    /// Loads persisted deployment settings from disk.
    private func loadPersistedSettings() {
        guard let data = try? Data(contentsOf: self.settingsURL),
              let settings = try? self.decoder.decode(PersistedSettings.self, from: data)
        else {
            return
        }
        self.legacySecrets = SecretSnapshot(
            discordBotToken: settings.discordBotToken,
            telegramBotToken: settings.telegramBotToken,
            openAIAPIKey: settings.openAIAPIKey,
            openAICompatibleAPIKey: settings.openAICompatibleAPIKey,
            anthropicAPIKey: settings.anthropicAPIKey,
            geminiAPIKey: settings.geminiAPIKey
        )
        self.applySecretSnapshot(self.legacySecrets)
        self.discordChannelID = settings.discordChannelID
        self.telegramChatID = settings.telegramChatID
        self.openAICompatibleBaseURL = settings.openAICompatibleBaseURL
        self.selectedProvider = settings.selectedProvider
        self.selectedModelID = settings.selectedModelID
        self.localRuntime = settings.localRuntime
        self.localModelPath = settings.localModelPath
        self.localFallbackModelPaths = settings.localFallbackModelPaths
        self.localContextWindow = settings.localContextWindow
        self.localTemperature = settings.localTemperature
        self.localTopP = settings.localTopP
        self.localTopK = settings.localTopK
        self.localMaxTokens = settings.localMaxTokens
        self.localUseMetal = settings.localUseMetal
        self.localStreamTokens = settings.localStreamTokens
        self.localAllowCancellation = settings.localAllowCancellation
        self.localRequestTimeoutMs = settings.localRequestTimeoutMs
        self.defaultAgentID = settings.defaultAgentID
        self.discordAgentID = settings.discordAgentID
        self.webchatAgentID = settings.webchatAgentID
        self.personality = settings.personality
        if self.selectedModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.selectedModelID = self.selectedProvider.defaultModelID
        }
        if self.defaultAgentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.defaultAgentID = "main"
        }
    }

    /// Persists deployment settings to local storage.
    private func persistSettings() throws {
        let settings = PersistedSettings(
            discordChannelID: self.discordChannelID,
            openAICompatibleBaseURL: self.openAICompatibleBaseURL,
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
            personality: self.personality,
            telegramBotToken: self.telegramBotToken,
            telegramChatID: self.telegramChatID
        )
        try FileManager.default.createDirectory(at: self.stateRoot, withIntermediateDirectories: true)
        let data = try self.encoder.encode(settings)
        try data.write(to: self.settingsURL, options: [.atomic])
    }

    /// Loads secure-store secrets and migrates any legacy plaintext values.
    private func loadSecureSecretsAndMigrateLegacy() async {
        do {
            let secureSecrets = try await self.readSecretsFromSecureStore()
            let legacyMap = self.legacySecrets.legacySecretsByStoreKey
            let hadLegacyPlaintext = self.legacySecrets.containsAnySecret
            let migration = CredentialSecretMigration.resolve(
                secureStoreSecrets: secureSecrets,
                legacySecrets: legacyMap
            )

            for key in SecretStoreKey.ordered {
                guard let value = migration.valuesToPersist[key] else {
                    continue
                }
                try await self.credentialStore.saveSecret(value, for: key)
            }
            self.applySecrets(fromResolvedMap: migration.resolvedSecrets)
            self.secretsHydrated = true

            if hadLegacyPlaintext {
                self.legacySecrets = .empty
                try self.persistSettings()
            }
        } catch {
            self.secretsHydrated = true
            self.statusText = "Warning: failed to load secure credentials."
        }
    }

    /// Persists in-memory secrets into secure storage.
    private func persistSecretsToSecureStore() async throws {
        try await self.writeSecret(self.discordBotToken, for: SecretStoreKey.discordBotToken)
        try await self.writeSecret(self.telegramBotToken, for: SecretStoreKey.telegramBotToken)
        try await self.writeSecret(self.openAIAPIKey, for: SecretStoreKey.openAIAPIKey)
        try await self.writeSecret(self.openAICompatibleAPIKey, for: SecretStoreKey.openAICompatibleAPIKey)
        try await self.writeSecret(self.anthropicAPIKey, for: SecretStoreKey.anthropicAPIKey)
        try await self.writeSecret(self.geminiAPIKey, for: SecretStoreKey.geminiAPIKey)
    }

    /// Writes or deletes one secret in the secure store based on current value.
    private func writeSecret(_ value: String, for key: String) async throws {
        if let nonEmpty = normalized(value) {
            try await self.credentialStore.saveSecret(nonEmpty, for: key)
        } else {
            try await self.credentialStore.deleteSecret(for: key)
        }
    }

    /// Reads all known secrets from secure storage.
    private func readSecretsFromSecureStore() async throws -> [String: String] {
        var secrets: [String: String] = [:]
        for key in SecretStoreKey.ordered {
            guard let value = try await self.credentialStore.loadSecret(for: key),
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                continue
            }
            secrets[key] = value
        }
        return secrets
    }

    /// Applies resolved secret map values onto published UI state.
    private func applySecrets(fromResolvedMap map: [String: String]) {
        let snapshot = SecretSnapshot(
            discordBotToken: map[SecretStoreKey.discordBotToken] ?? "",
            telegramBotToken: map[SecretStoreKey.telegramBotToken] ?? "",
            openAIAPIKey: map[SecretStoreKey.openAIAPIKey] ?? "",
            openAICompatibleAPIKey: map[SecretStoreKey.openAICompatibleAPIKey] ?? "",
            anthropicAPIKey: map[SecretStoreKey.anthropicAPIKey] ?? "",
            geminiAPIKey: map[SecretStoreKey.geminiAPIKey] ?? ""
        )
        self.applySecretSnapshot(snapshot)
    }

    /// Applies a snapshot of secret values onto published fields.
    private func applySecretSnapshot(_ snapshot: SecretSnapshot) {
        self.discordBotToken = snapshot.discordBotToken
        self.telegramBotToken = snapshot.telegramBotToken
        self.openAIAPIKey = snapshot.openAIAPIKey
        self.openAICompatibleAPIKey = snapshot.openAICompatibleAPIKey
        self.anthropicAPIKey = snapshot.anthropicAPIKey
        self.geminiAPIKey = snapshot.geminiAPIKey
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

    /// Syncs iOS example project skills into the app sandbox workspace.
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

    /// Resolves the iOS example `skills` directory from bundle or source tree.
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
