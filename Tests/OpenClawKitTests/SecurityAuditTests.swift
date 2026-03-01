import Foundation
import Testing
@testable import OpenClawKit

@Suite("Security audit")
struct SecurityAuditTests {
    @Test
    func auditFindsRiskyDefaultsAndPlaintextSecrets() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclawkit-security-audit-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configURL = root.appendingPathComponent("config.json", isDirectory: false)
        try """
        {
          "openAI": { "apiKey": "plaintext-key" },
          "discord": { "botToken": "plaintext-token" }
        }
        """.write(to: configURL, atomically: true, encoding: .utf8)
        #if !os(Windows)
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o666))], ofItemAtPath: configURL.path)
        #endif

        let config = OpenClawConfig(
            gateway: GatewayConfig(authMode: "none"),
            channels: ChannelsConfig(
                discord: DiscordChannelConfig(enabled: true, botToken: "token", mentionOnly: false),
                telegram: TelegramChannelConfig(enabled: true, botToken: "token", mentionOnly: false),
                slack: SlackChannelConfig(
                    enabled: true,
                    botToken: "slack-bot-token",
                    appToken: "slack-app-token",
                    signingSecret: "slack-signing-secret",
                    mentionOnly: false
                ),
                googleChat: GoogleChatChannelConfig(
                    enabled: true,
                    bearerToken: "googlechat-bearer",
                    verificationToken: nil
                ),
                signal: SignalChannelConfig(
                    enabled: true,
                    serviceURL: "http://signal.example.com",
                    authToken: "signal-token"
                ),
                msteams: MicrosoftTeamsChannelConfig(
                    enabled: true,
                    botAppPassword: "teams-password",
                    mentionOnly: false
                ),
                webchat: WebChatChannelConfig(enabled: true, sharedSecret: nil)
            ),
            routing: RoutingConfig(
                defaultSessionKey: "shared",
                includeChannelID: false,
                includeAccountID: false,
                includePeerID: false
            ),
            models: ModelsConfig(
                local: LocalModelConfig(enabled: true, modelPath: nil),
                providers: [
                    "openrouter": ProviderServiceConfig(
                        enabled: true,
                        apiStyle: .openAICompletions,
                        authMode: .none,
                        modelID: "anthropic/claude-sonnet-4-5",
                        baseURL: "https://openrouter.ai/api/v1",
                        chatCompletionsPath: "chat/completions"
                    ),
                    "amazon-bedrock": ProviderServiceConfig(
                        enabled: true,
                        apiStyle: .bedrockConverse,
                        authMode: .awsSDK,
                        modelID: "anthropic.claude-3-5-sonnet",
                        apiKey: "AWS_PROFILE",
                        baseURL: "https://bedrock-runtime.us-east-1.amazonaws.com"
                    ),
                    "qwen-portal": ProviderServiceConfig(
                        enabled: true,
                        apiStyle: .openAICompletions,
                        authMode: .oauthToken,
                        modelID: "coder-model",
                        accessToken: "qwen-oauth-token",
                        baseURL: "https://portal.qwen.ai/v1",
                        chatCompletionsPath: "chat/completions"
                    ),
                ]
            )
        )

        let report = SecurityAuditRunner.run(
            options: SecurityAuditOptions(
                config: config,
                configFileURL: configURL,
                statePaths: [root]
            )
        )

        #expect(report.highestSeverity == .error)
        #expect(report.findings.contains(where: { $0.id == "gateway.auth-mode-unsafe" }))
        #expect(report.findings.contains(where: { $0.id == "routing.shared-session" }))
        #expect(report.findings.contains(where: { $0.id == "secrets.config.plaintext" }))
        #expect(report.findings.contains(where: { $0.id == "channels.slack.mention-only-disabled" }))
        #expect(report.findings.contains(where: { $0.id == "channels.msteams.mention-only-disabled" }))
        #expect(report.findings.contains(where: { $0.id == "channels.googlechat.verification-token-missing" }))
        #expect(report.findings.contains(where: { $0.id == "channels.webchat.shared-secret-missing" }))
        #expect(report.findings.contains(where: { $0.id == "channels.signal.insecure-service-url" }))
        #expect(report.findings.contains(where: { $0.id == "models.providers.openrouter.auth-none" }))
        #expect(report.findings.contains(where: { $0.id == "models.providers.amazon-bedrock.region-missing" }))
        #expect(
            report.findings
                .first(where: { $0.id == "secrets.config.plaintext" })?
                .detail.contains("models.providers.qwen-portal.accessToken") == true
        )
        #expect(report.findings.contains(where: { $0.id.starts(with: "plaintext.file.") }))
        #expect(report.count(for: SecurityAuditSeverity.warning) >= 1)
    }

    @Test
    func auditTreatsLocalAuthNoneProviderServicesAsSafe() {
        let config = OpenClawConfig(
            models: ModelsConfig(
                providers: [
                    "ollama": ProviderServiceConfig(
                        enabled: true,
                        apiStyle: .ollama,
                        authMode: .none,
                        modelID: "llama3.3",
                        baseURL: "http://127.0.0.1:11434/v1",
                        chatCompletionsPath: "chat/completions"
                    ),
                    "litellm": ProviderServiceConfig(
                        enabled: true,
                        apiStyle: .openAICompletions,
                        authMode: .none,
                        modelID: "gpt-4.1-mini",
                        baseURL: "http://localhost:4000/v1",
                        chatCompletionsPath: "chat/completions"
                    ),
                    "vllm": ProviderServiceConfig(
                        enabled: true,
                        apiStyle: .openAICompletions,
                        authMode: .none,
                        modelID: "qwen2.5-coder-32b-instruct",
                        baseURL: "http://127.0.0.1:8000/v1",
                        chatCompletionsPath: "chat/completions"
                    ),
                ]
            )
        )
        let report = SecurityAuditRunner.run(
            options: SecurityAuditOptions(config: config)
        )

        #expect(report.findings.contains(where: { $0.id == "models.providers.ollama.auth-none" }) == false)
        #expect(report.findings.contains(where: { $0.id == "models.providers.litellm.auth-none" }) == false)
        #expect(report.findings.contains(where: { $0.id == "models.providers.vllm.auth-none" }) == false)
    }

    @Test
    func auditDetectsProviderServiceAPIKeysAndAccessTokensInPlaintextConfig() {
        let config = OpenClawConfig(
            models: ModelsConfig(
                providers: [
                    "openrouter": ProviderServiceConfig(
                        enabled: true,
                        apiStyle: .openAICompletions,
                        authMode: .apiKey,
                        modelID: "anthropic/claude-sonnet-4-5",
                        apiKey: "openrouter-key",
                        baseURL: "https://openrouter.ai/api/v1",
                        chatCompletionsPath: "chat/completions"
                    ),
                    "qwen-portal": ProviderServiceConfig(
                        enabled: true,
                        apiStyle: .openAICompletions,
                        authMode: .oauthToken,
                        modelID: "coder-model",
                        accessToken: "qwen-token",
                        baseURL: "https://portal.qwen.ai/v1",
                        chatCompletionsPath: "chat/completions"
                    ),
                ]
            )
        )
        let report = SecurityAuditRunner.run(
            options: SecurityAuditOptions(config: config)
        )
        let plaintextDetail = report.findings.first(where: { $0.id == "secrets.config.plaintext" })?.detail ?? ""

        #expect(plaintextDetail.contains("models.providers.openrouter.apiKey"))
        #expect(plaintextDetail.contains("models.providers.qwen-portal.accessToken"))
    }

    @Test
    func auditIsCleanForHardenedConfig() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclawkit-security-audit-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configURL = root.appendingPathComponent("config.json", isDirectory: false)
        try "{}".write(to: configURL, atomically: true, encoding: .utf8)
        #if !os(Windows)
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o700))], ofItemAtPath: root.path)
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: configURL.path)
        #endif

        let report = SecurityAuditRunner.run(
            options: SecurityAuditOptions(
                config: OpenClawConfig(),
                configFileURL: configURL,
                statePaths: [root]
            )
        )

        #expect(report.findings.isEmpty)
        #expect(report.highestSeverity == .info)
        #expect(report.hasBlockingFindings == false)
    }

    @Test
    func sdkAuditPublishesDiagnosticsEvents() async {
        let sdk = OpenClawSDK.shared
        let pipeline = RuntimeDiagnosticsPipeline(eventLimit: 50)
        let report = await sdk.runSecurityAudit(
            options: SecurityAuditOptions(
                config: OpenClawConfig(gateway: GatewayConfig(authMode: "none"))
            ),
            diagnosticsPipeline: pipeline
        )

        #expect(report.findings.contains(where: { $0.id == "gateway.auth-mode-unsafe" }))
        let events = await pipeline.recentEvents(limit: 50)
        #expect(events.contains(where: { $0.subsystem == "security" && $0.name == "audit.completed" }))
        #expect(events.contains(where: { $0.subsystem == "security" && $0.name == "audit.finding" }))
    }

    @Test
    func auditFlagsReplayLedgerIntegrityTampering() throws {
        let signer = HMACReplayLedgerSigner(secret: Data("test-ledger-secret".utf8))
        let event1 = ReplayEvent(
            sequenceNumber: 0,
            subsystem: "runtime",
            name: "run.started",
            runID: "run-ledger",
            sessionKey: "session-ledger"
        )
        let envelope1 = try ReplayLedgerVerifier.signedEnvelope(
            for: event1,
            previousEventHash: nil,
            signer: signer
        )
        let event2 = ReplayEvent(
            sequenceNumber: 1,
            subsystem: "runtime",
            name: "run.completed",
            runID: "run-ledger",
            sessionKey: "session-ledger"
        )
        var envelope2 = try ReplayLedgerVerifier.signedEnvelope(
            for: event2,
            previousEventHash: envelope1.eventHash,
            signer: signer
        )
        envelope2.event = ReplayEvent(
            schemaVersion: envelope2.event.schemaVersion,
            eventID: envelope2.event.eventID,
            sequenceNumber: envelope2.event.sequenceNumber,
            subsystem: envelope2.event.subsystem,
            name: "run.failed",
            runID: envelope2.event.runID,
            sessionKey: envelope2.event.sessionKey,
            occurredAt: envelope2.event.occurredAt,
            metadata: envelope2.event.metadata,
            payload: envelope2.event.payload
        )

        let report = SecurityAuditRunner.run(
            options: SecurityAuditOptions(
                replayLedgerEnvelopes: [envelope1, envelope2],
                requireReplayLedgerSignatureVerification: true
            ),
            replayLedgerSigner: signer
        )
        #expect(report.replayLedgerIntegrity?.isValid == false)
        #expect(report.findings.contains(where: { $0.id == "replay.ledger.integrity.invalid" }))
        #expect(report.hasBlockingFindings == true)
    }
}
