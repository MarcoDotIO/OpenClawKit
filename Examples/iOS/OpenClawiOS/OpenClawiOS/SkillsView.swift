import SwiftUI

/// Skills browser and invocation status view.
struct SkillsView: View {
    @EnvironmentObject private var appState: OpenClawAppState

    var body: some View {
        NavigationStack {
            List {
                Section("Invocation Status") {
                    Text(appState.latestSkillInvocationSummary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("Refresh Skills and Metrics") {
                        Task { await appState.refreshObservabilityNow() }
                    }
                }

                Section("WASM Showcase") {
                    Text(appState.wasmShowcaseStatusText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("wasm-showcase-status-label")
                    if !appState.wasmShowcaseOutputPreview.isEmpty {
                        Text(appState.wasmShowcaseOutputPreview)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Button(appState.wasmShowcaseRunning ? "Running WASM Smoke Test..." : "Run WASM Smoke Test") {
                        Task {
                            await appState.runWASMShowcase()
                        }
                    }
                    .disabled(appState.wasmShowcaseRunning)
                    .accessibilityIdentifier("skills-wasm-smoke-test-button")
                }

                Section("Discovered Skills") {
                    if appState.skillItems.isEmpty {
                        ContentUnavailableView(
                            "No Skills Discovered",
                            systemImage: "wand.and.stars.slash",
                            description: Text("Ensure your workspace contains valid skill definitions.")
                        )
                    } else {
                        ForEach(appState.skillItems) { skill in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(skill.name)
                                    .font(.headline)
                                Text(skill.summary)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                HStack {
                                    Text(skill.source)
                                    Text("env: \(skill.primaryEnv)")
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)

                                HStack(spacing: 8) {
                                    Label(
                                        skill.userInvocable ? "User Invocable" : "Not User Invocable",
                                        systemImage: skill.userInvocable ? "person.fill.checkmark" : "person.fill.xmark"
                                    )
                                    Label(
                                        skill.requiresExplicitInvocation ? "Explicit Only" : "Inference Enabled",
                                        systemImage: skill.requiresExplicitInvocation ? "hand.raised.fill" : "sparkles"
                                    )
                                }
                                .font(.caption2)
                                .foregroundStyle(.secondary)

                                if let entrypoint = skill.entrypoint {
                                    Text("Entrypoint: \(entrypoint)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Skills")
        }
    }
}

#Preview {
    SkillsView()
        .environmentObject(OpenClawAppState())
}
