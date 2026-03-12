import OpenClawKit
import SwiftUI

/// Channel health and route mapping view.
struct ChannelsView: View {
    @EnvironmentObject private var appState: OpenClawAppState

    var body: some View {
        NavigationStack {
            List {
                Section("Retry Policy") {
                    Text("Attempts: \(appState.activeRetryPolicy.maxAttempts)")
                    Text("Initial Backoff: \(appState.activeRetryPolicy.initialBackoffMs) ms")
                    Text("Max Backoff: \(appState.activeRetryPolicy.maxBackoffMs) ms")
                    Text("Multiplier: \(appState.activeRetryPolicy.backoffMultiplier, format: .number.precision(.fractionLength(1)))")
                }

                Section("Route Mapping Preview") {
                    ForEach(appState.routeMappings) { mapping in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(mapping.route)
                                .font(.headline)
                            Text("agent: \(mapping.agentID)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 3)
                    }
                }

                Section("Channel Health") {
                    if appState.channelHealthItems.isEmpty {
                        ContentUnavailableView(
                            "No Channels Active",
                            systemImage: "bolt.horizontal.circle.fill",
                            description: Text("Deploy the agent to see channel health.")
                        )
                    } else {
                        ForEach(appState.channelHealthItems) { item in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(item.id)
                                        .font(.title3.weight(.semibold))
                                    Spacer()
                                    Text(item.status.rawValue)
                                        .font(.footnote.weight(.bold))
                                        .foregroundStyle(statusColor(item.status))
                                }
                                Text("consecutive failures: \(item.consecutiveFailures)")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                if let lastError = item.lastError, !lastError.isEmpty {
                                    Text("last error: \(lastError)")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("Channels")
            .toolbar {
                Button("Refresh") {
                    Task { await appState.refreshObservabilityNow() }
                }
            }
        }
    }

    private func statusColor(_ status: ChannelHealthStatus) -> Color {
        switch status {
        case .healthy:
            return .green
        case .degraded:
            return .orange
        case .offline:
            return .red
        }
    }
}

#Preview {
    ChannelsView()
        .environmentObject(OpenClawAppState())
}
