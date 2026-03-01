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

                Section("Credentials") {
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
                    case .foundation, .echo, .local:
                        Text("Selected provider does not require an external API key.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
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
