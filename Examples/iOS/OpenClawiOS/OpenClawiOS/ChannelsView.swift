import SwiftUI
import OpenClawKit

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
                        VStack(alignment: .leading, spacing: 4) {
                            Text(mapping.route)
                                .font(.subheadline.weight(.semibold))
                            Text("agent: \(mapping.agentID)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }

                Section {
                    if appState.pendingPairingRequests.isEmpty {
                        Text("No pending requests. Unknown DM senders receive a pairing code first.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(appState.pendingPairingRequests) { item in
                            VStack(alignment: .leading, spacing: 6) {
                                Text("\(item.channel.rawValue) · \(item.senderID)")
                                    .font(.subheadline.weight(.semibold))
                                Text("code \(item.code) · account \(item.accountID)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                HStack {
                                    Button("Approve") {
                                        Task { await appState.approvePairing(item) }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    Button("Dismiss", role: .destructive) {
                                        Task { await appState.dismissPairing(item) }
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                } header: {
                    Text("Pairing Requests")
                } footer: {
                    Text("Channels default to dmPolicy \"pairing\". Approve a sender here or set dmPolicy/allowFrom in config.")
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
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(item.id)
                                        .font(.headline)
                                    Spacer()
                                    Text(item.status.rawValue)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(statusColor(item.status))
                                }
                                Text("consecutive failures: \(item.consecutiveFailures)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let lastError = item.lastError, !lastError.isEmpty {
                                    Text("last error: \(lastError)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
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
