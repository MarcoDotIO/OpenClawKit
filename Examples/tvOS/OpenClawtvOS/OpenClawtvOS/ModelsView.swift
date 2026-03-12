import OpenClawKit
import SwiftUI

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
                    Button("Use Suggested Model") {
                        appState.selectedModelID = appState.selectedProvider.defaultModelID
                    }
                }

                if appState.selectedProvider == .local {
                    Section("Local Runtime") {
                        TextField("Runtime ID", text: $appState.localRuntime)
                        TextField("Primary Model Path", text: $appState.localModelPath)
                        TextField("Fallback Paths (comma/newline separated)", text: $appState.localFallbackModelPaths, axis: .vertical)
                            .lineLimit(2...4)

                        NavigationLink("Advanced Local Settings") {
                            Form {
                                Section("Hardware & Streaming") {
                                    Toggle("Use Metal", isOn: $appState.localUseMetal)
                                    Toggle("Stream Tokens", isOn: $appState.localStreamTokens)
                                    Toggle("Allow Cancellation", isOn: $appState.localAllowCancellation)
                                }
                                Section("Limits") {
                                    adjustableIntRow(
                                        title: "Context Window",
                                        value: $appState.localContextWindow,
                                        range: 256...32768,
                                        step: 256
                                    )
                                    adjustableIntRow(
                                        title: "Max Tokens",
                                        value: $appState.localMaxTokens,
                                        range: 1...8192,
                                        step: 32
                                    )
                                    adjustableIntRow(
                                        title: "Timeout (ms)",
                                        value: $appState.localRequestTimeoutMs,
                                        range: 1_000...600_000,
                                        step: 500
                                    )
                                }
                                Section("Sampling") {
                                    adjustableDoubleRow(
                                        title: "Temperature",
                                        value: $appState.localTemperature,
                                        range: 0...2,
                                        step: 0.05
                                    )
                                    adjustableDoubleRow(
                                        title: "Top P",
                                        value: $appState.localTopP,
                                        range: 0.05...1,
                                        step: 0.05
                                    )
                                    adjustableIntRow(
                                        title: "Top K",
                                        value: $appState.localTopK,
                                        range: 1...200,
                                        step: 1
                                    )
                                }
                            }
                            .navigationTitle("Advanced Local Settings")
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
                            VStack(alignment: .leading, spacing: 5) {
                                Text("\(row.providerID) • \(row.modelID)")
                                    .font(.headline)
                                Text("calls: \(row.calls), failures: \(row.failures), avg latency: \(row.averageLatencyMs) ms")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("Models")
        }
    }

    @ViewBuilder
    private func adjustableIntRow(
        title: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int
    ) -> some View {
        HStack {
            Text("\(title): \(value.wrappedValue)")
            Spacer()
            Button("−") {
                value.wrappedValue = max(range.lowerBound, value.wrappedValue - step)
            }
            .buttonStyle(.bordered)
            Button("+") {
                value.wrappedValue = min(range.upperBound, value.wrappedValue + step)
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private func adjustableDoubleRow(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        HStack {
            Text("\(title): \(value.wrappedValue, format: .number.precision(.fractionLength(2)))")
            Spacer()
            Button("−") {
                value.wrappedValue = max(range.lowerBound, value.wrappedValue - step)
            }
            .buttonStyle(.bordered)
            Button("+") {
                value.wrappedValue = min(range.upperBound, value.wrappedValue + step)
            }
            .buttonStyle(.bordered)
        }
    }
}

#Preview {
    ModelsView()
        .environmentObject(OpenClawAppState())
}
