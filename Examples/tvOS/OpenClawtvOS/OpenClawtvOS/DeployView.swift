import SwiftUI

/// Deployment control panel for credentials, personality, and lifecycle actions.
struct DeployView: View {
    @EnvironmentObject private var appState: OpenClawAppState

    var body: some View {
        NavigationStack {
            Form {
                Section("Deployment Status") {
                    Text(appState.statusText)
                        .font(.title3)
                    Text(appState.deploymentState.rawValue.capitalized)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Credentials") {
                    NavigationLink("Messaging Channels") {
                        Form {
                            SecureField("Discord Bot Token", text: $appState.discordBotToken)
                            TextField("Discord Channel ID", text: $appState.discordChannelID)
                            SecureField("Telegram Bot Token", text: $appState.telegramBotToken)
                            TextField("Telegram Chat ID (optional)", text: $appState.telegramChatID)
                            SecureField("Slack Bot Token", text: $appState.slackBotToken)
                            SecureField("Slack App Token (optional)", text: $appState.slackAppToken)
                            SecureField("Slack Signing Secret (optional)", text: $appState.slackSigningSecret)
                            TextField("Slack Default Channel ID (optional)", text: $appState.slackChannelID)
                            SecureField("Google Chat Bearer Token", text: $appState.googleChatBearerToken)
                            SecureField("Google Chat Verification Token (optional)", text: $appState.googleChatVerificationToken)
                            TextField("Google Chat Space ID (optional)", text: $appState.googleChatSpaceID)
                            TextField("Signal Service URL", text: $appState.signalServiceURL)
                            TextField("Signal Account ID (optional)", text: $appState.signalAccountID)
                            SecureField("Signal Auth Token (optional)", text: $appState.signalAuthToken)
                            TextField("Signal Default Recipient (optional)", text: $appState.signalRecipient)
                            TextField("Teams Bot App ID", text: $appState.msteamsBotAppID)
                            SecureField("Teams Bot App Password", text: $appState.msteamsBotAppPassword)
                            TextField("Teams Tenant ID (optional)", text: $appState.msteamsTenantID)
                            TextField("Teams Conversation ID (optional)", text: $appState.msteamsConversationID)
                            TextField("Teams Service URL", text: $appState.msteamsServiceURL)
                            SecureField("WebChat Shared Secret (optional)", text: $appState.webchatSharedSecret)
                        }
                        .navigationTitle("Messaging Channels")
                    }

                    NavigationLink("Provider (\(appState.selectedProvider.displayName))") {
                        Form {
                            switch appState.selectedProvider {
                            case .openAI:
                                SecureField("OpenAI API Key", text: $appState.openAIAPIKey)
                            case .openAICompatible:
                                SecureField("OpenAI-Compatible API Key", text: $appState.openAICompatibleAPIKey)
                                TextField("OpenAI-Compatible Base URL", text: $appState.openAICompatibleBaseURL)
                            case .anthropic:
                                SecureField("Anthropic API Key", text: $appState.anthropicAPIKey)
                            case .gemini:
                                SecureField("Gemini API Key", text: $appState.geminiAPIKey)
                            case .xai, .openRouter, .groq, .mistral, .cerebras, .moonshot, .liteLLM, .together,
                                .huggingFace, .qianfan, .nvidia, .zai, .minimax, .synthetic, .xiaomi,
                                .cloudflareAIGateway, .vercelAIGateway:
                                SecureField("Provider Service API Key", text: $appState.providerServiceAPIKey)
                                TextField("Provider Service Base URL (optional override)", text: $appState.providerServiceBaseURL)
                            case .minimaxPortal, .githubCopilot, .qwenPortal:
                                SecureField("Provider Service Access Token", text: $appState.providerServiceAccessToken)
                                TextField("Provider Service Base URL (optional override)", text: $appState.providerServiceBaseURL)
                            case .amazonBedrock:
                                TextField("Bedrock Base URL (optional override)", text: $appState.providerServiceBaseURL)
                                TextField("AWS Region", text: $appState.providerServiceRegion)
                                TextField("AWS Profile", text: $appState.providerServiceProfile)
                            case .ollama, .vllm:
                                TextField("Provider Service Base URL (optional override)", text: $appState.providerServiceBaseURL)
                                Text("Selected provider does not require an external API key by default.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            case .foundation, .echo, .local:
                                Text("Selected provider does not require an external API key.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .navigationTitle("Provider Credentials")
                    }
                }

                Section("Model Routing") {
                    Picker("Provider", selection: $appState.selectedProvider) {
                        ForEach(appState.availableProviders) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    TextField("Model ID", text: $appState.selectedModelID)
                    Button("Use Suggested Model") {
                        appState.selectedModelID = appState.selectedProvider.defaultModelID
                    }
                }

                Section("Agent Routing") {
                    TextField("Default Agent ID", text: $appState.defaultAgentID)
                    TextField("Discord Agent ID (optional)", text: $appState.discordAgentID)
                    TextField("WebChat Agent ID (optional)", text: $appState.webchatAgentID)
                }

                Section("Agent Personality") {
                    TextField("Agent Personality", text: $appState.personality, axis: .vertical)
                        .lineLimit(4...10)
                }

                Section {
                    Button("Deploy Agent") {
                        Task {
                            await appState.deploy()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(appState.deploymentState == .starting || appState.deploymentState == .running)

                    Button("Stop Deployment", role: .destructive) {
                        Task {
                            await appState.stopDeployment()
                        }
                    }
                    .disabled(appState.deploymentState == .stopped || appState.deploymentState == .stopping)
                }
            }
            .navigationTitle("Deploy")
            .onChange(of: appState.selectedProvider) { _, newValue in
                if appState.selectedModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    appState.selectedModelID = newValue.defaultModelID
                }
            }
        }
    }
}

#Preview {
    DeployView()
        .environmentObject(OpenClawAppState())
}
