import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Deployment control panel for credentials, personality, and lifecycle actions.
struct DeployView: View {
    @EnvironmentObject private var appState: OpenClawAppState

    var body: some View {
        NavigationStack {
            Form {
                Section("Deployment Status") {
                    Text(appState.statusText)
                        .font(.subheadline)
                    Text(appState.deploymentState.rawValue.capitalized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Live Activity") {
                    Text(appState.liveActivityStatusText)
                        .font(.subheadline)
                        .accessibilityIdentifier("live-activity-status-text")
                    Text("Shows lock-screen progress state for long-running runs.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Credentials") {
                    DisclosureGroup("Messaging Channels") {
                        SecureField("Discord Bot Token", text: $appState.discordBotToken)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Discord Channel ID", text: $appState.discordChannelID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Telegram Bot Token", text: $appState.telegramBotToken)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Telegram Chat ID (optional)", text: $appState.telegramChatID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Slack Bot Token", text: $appState.slackBotToken)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Slack App Token (optional)", text: $appState.slackAppToken)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Slack Signing Secret (optional)", text: $appState.slackSigningSecret)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Slack Default Channel ID (optional)", text: $appState.slackChannelID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Google Chat Bearer Token", text: $appState.googleChatBearerToken)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Google Chat Verification Token (optional)", text: $appState.googleChatVerificationToken)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Google Chat Space ID (optional)", text: $appState.googleChatSpaceID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Signal Service URL", text: $appState.signalServiceURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Signal Account ID (optional)", text: $appState.signalAccountID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Signal Auth Token (optional)", text: $appState.signalAuthToken)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Signal Default Recipient (optional)", text: $appState.signalRecipient)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Teams Bot App ID", text: $appState.msteamsBotAppID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Teams Bot App Password", text: $appState.msteamsBotAppPassword)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Teams Tenant ID (optional)", text: $appState.msteamsTenantID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Teams Conversation ID (optional)", text: $appState.msteamsConversationID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Teams Service URL", text: $appState.msteamsServiceURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("WebChat Shared Secret (optional)", text: $appState.webchatSharedSecret)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    DisclosureGroup("Model Provider (\(appState.selectedProvider.displayName))") {
                        switch appState.selectedProvider {
                        case .openAI:
                            SecureField("OpenAI API Key", text: $appState.openAIAPIKey)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        case .openAICompatible:
                            SecureField("OpenAI-Compatible API Key", text: $appState.openAICompatibleAPIKey)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            TextField("OpenAI-Compatible Base URL", text: $appState.openAICompatibleBaseURL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        case .anthropic:
                            SecureField("Anthropic API Key", text: $appState.anthropicAPIKey)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        case .gemini:
                            SecureField("Gemini API Key", text: $appState.geminiAPIKey)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        case .xai, .openRouter, .groq, .mistral, .cerebras, .moonshot, .liteLLM, .together,
                            .huggingFace, .qianfan, .nvidia, .zai, .minimax, .synthetic, .xiaomi,
                            .cloudflareAIGateway, .vercelAIGateway:
                            SecureField("Provider Service API Key", text: $appState.providerServiceAPIKey)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            TextField("Provider Service Base URL (optional override)", text: $appState.providerServiceBaseURL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        case .minimaxPortal, .githubCopilot, .qwenPortal:
                            SecureField("Provider Service Access Token", text: $appState.providerServiceAccessToken)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            TextField("Provider Service Base URL (optional override)", text: $appState.providerServiceBaseURL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        case .amazonBedrock:
                            TextField("Bedrock Base URL (optional override)", text: $appState.providerServiceBaseURL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            TextField("AWS Region", text: $appState.providerServiceRegion)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            TextField("AWS Profile", text: $appState.providerServiceProfile)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        case .ollama, .vllm:
                            TextField("Provider Service Base URL (optional override)", text: $appState.providerServiceBaseURL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            Text("Selected provider does not require an external API key by default.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        case .foundation, .echo, .local:
                            Text("Selected provider does not require an external API key.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Model Routing") {
                    Picker("Provider", selection: $appState.selectedProvider) {
                        ForEach(appState.availableProviders) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    TextField("Model ID", text: $appState.selectedModelID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Use Suggested Model") {
                        appState.selectedModelID = appState.selectedProvider.defaultModelID
                    }
                }

                Section("Agent Routing") {
                    TextField("Default Agent ID", text: $appState.defaultAgentID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Discord Agent ID (optional)", text: $appState.discordAgentID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Webchat Agent ID (optional)", text: $appState.webchatAgentID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("Agent Personality") {
                    TextEditor(text: $appState.personality)
                        .frame(minHeight: 120)
                }

                Section {
                    Button("Deploy Agent") {
                        Task {
                            await appState.deploy()
                        }
                    }
                    .disabled(appState.deploymentState == .starting || appState.deploymentState == .running)

                    Button("Stop Deployment", role: .destructive) {
                        Task {
                            await appState.stopDeployment()
                        }
                    }
                    .disabled(appState.deploymentState == .stopped || appState.deploymentState == .stopping)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Deploy")
            .onChange(of: appState.selectedProvider) { _, newValue in
                if appState.selectedModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    appState.selectedModelID = newValue.defaultModelID
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        self.dismissKeyboard()
                    }
                }
            }
        }
    }

    private func dismissKeyboard() {
        #if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }
}

#Preview {
    DeployView()
        .environmentObject(OpenClawAppState())
}
