import SwiftUI
import OpenClawKit
#if canImport(UIKit)
import UIKit
#endif

/// Model/provider control panel including local runtime tuning options.
struct ModelsView: View {
    @EnvironmentObject private var appState: OpenClawAppState

    var body: some View {
        NavigationStack {
            Form {
                Section("Active Provider") {
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

                if appState.selectedProvider == .local {
                    Section("Local Runtime") {
                        TextField("Runtime ID", text: $appState.localRuntime)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Primary Model Path", text: $appState.localModelPath)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Fallback Paths (comma/newline separated)", text: $appState.localFallbackModelPaths, axis: .vertical)
                            .lineLimit(2...4)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                        DisclosureGroup("Advanced Local Settings") {
                            Stepper("Context Window: \(appState.localContextWindow)", value: $appState.localContextWindow, in: 256...32768, step: 256)
                            Stepper("Top K: \(appState.localTopK)", value: $appState.localTopK, in: 1...200)
                            Stepper("Max Tokens: \(appState.localMaxTokens)", value: $appState.localMaxTokens, in: 1...8192, step: 32)
                            Stepper("Timeout (ms): \(appState.localRequestTimeoutMs)", value: $appState.localRequestTimeoutMs, in: 1_000...600_000, step: 500)

                            VStack(alignment: .leading, spacing: 8) {
                                Text("Temperature: \(appState.localTemperature, format: .number.precision(.fractionLength(2)))")
                                Slider(value: $appState.localTemperature, in: 0...2, step: 0.05)
                            }
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Top P: \(appState.localTopP, format: .number.precision(.fractionLength(2)))")
                                Slider(value: $appState.localTopP, in: 0.05...1, step: 0.05)
                            }

                            Toggle("Use Metal", isOn: $appState.localUseMetal)
                            Toggle("Stream Tokens", isOn: $appState.localStreamTokens)
                            Toggle("Allow Cancellation", isOn: $appState.localAllowCancellation)
                        }
                    }
                }

                Section("Observed Model Usage") {
                    let rows = appState.usageSnapshot?.models ?? []
                    if rows.isEmpty {
                        ContentUnavailableView(
                            "No Model Usage",
                            systemImage: "chart.bar.xaxis",
                            description: Text("No model usage recorded yet.")
                        )
                    } else {
                        ForEach(rows, id: \.providerID) { row in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(row.providerID) • \(row.modelID)")
                                    .font(.subheadline.weight(.semibold))
                                Text("calls: \(row.calls), failures: \(row.failures), avg latency: \(row.averageLatencyMs) ms")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Models")
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
    ModelsView()
        .environmentObject(OpenClawAppState())
}
