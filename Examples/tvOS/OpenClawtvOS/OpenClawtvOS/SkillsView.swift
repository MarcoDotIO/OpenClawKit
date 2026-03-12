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

                Section("Discovered Skills") {
                    if appState.skillItems.isEmpty {
                        ContentUnavailableView(
                            "No Skills Discovered",
                            systemImage: "wand.and.stars.slash",
                            description: Text("Ensure your workspace contains valid skill definitions.")
                        )
                    } else {
                        ForEach(appState.skillItems) { skill in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(skill.name)
                                    .font(.title3.weight(.semibold))
                                Text(skill.summary)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                HStack {
                                    Text(skill.source)
                                    Text("env: \(skill.primaryEnv)")
                                }
                                .font(.footnote)
                                .foregroundStyle(.secondary)

                                HStack(spacing: 10) {
                                    Label(
                                        skill.userInvocable ? "User Invocable" : "Not User Invocable",
                                        systemImage: skill.userInvocable ? "person.fill.checkmark" : "person.fill.xmark"
                                    )
                                    Label(
                                        skill.requiresExplicitInvocation ? "Explicit Only" : "Inference Enabled",
                                        systemImage: skill.requiresExplicitInvocation ? "hand.raised.fill" : "sparkles"
                                    )
                                }
                                .font(.footnote)
                                .foregroundStyle(.secondary)

                                if let entrypoint = skill.entrypoint {
                                    Text("Entrypoint: \(entrypoint)")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 6)
                        }
                    }
                }
            }
            .navigationTitle("Skills")
        }
    }
}

#Preview {
    SkillsView()
        .environmentObject(OpenClawAppState())
}
