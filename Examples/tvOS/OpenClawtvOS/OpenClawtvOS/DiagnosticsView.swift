import OpenClawKit
import SwiftUI

/// Runtime diagnostics and usage timeline view.
struct DiagnosticsView: View {
    @EnvironmentObject private var appState: OpenClawAppState

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    var body: some View {
        NavigationStack {
            Group {
                if appState.usageSnapshot == nil && appState.diagnosticEvents.isEmpty {
                    ContentUnavailableView(
                        "No Diagnostics",
                        systemImage: "waveform.path.ecg",
                        description: Text("Deploy the agent to start capturing runtime diagnostic events.")
                    )
                } else {
                    List {
                        Section("Usage Snapshot") {
                            if let snapshot = appState.usageSnapshot {
                                Text("runs: \(snapshot.runsStarted) started / \(snapshot.runsCompleted) completed / \(snapshot.runsFailed) failed")
                                Text("avg run latency: \(snapshot.averageRunLatencyMs) ms")
                                Text("model calls: \(snapshot.modelCalls), failures: \(snapshot.modelFailures)")
                                Text("skills invoked: \(snapshot.skillInvocations)")
                                Text("channel deliveries: \(snapshot.channelDeliveriesSent) sent / \(snapshot.channelDeliveriesFailed) failed")
                            }
                        }

                        Section("Recent Events") {
                            ForEach(Array(appState.diagnosticEvents.reversed().enumerated()), id: \.offset) { _, event in
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text("\(event.subsystem).\(event.name)")
                                            .font(.footnote.weight(.semibold))
                                        Spacer()
                                        Text(Self.formatter.string(from: event.occurredAt))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    if let runID = event.runID, !runID.isEmpty {
                                        Text("run: \(runID)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    if let sessionKey = event.sessionKey, !sessionKey.isEmpty {
                                        Text("session: \(sessionKey)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    if !event.metadata.isEmpty {
                                        Text(event.metadata
                                            .sorted(by: { $0.key < $1.key })
                                            .map { "\($0.key)=\($0.value)" }
                                            .joined(separator: ", "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(4)
                                    }
                                }
                                .padding(.vertical, 3)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Diagnostics")
            .toolbar {
                Button("Refresh") {
                    Task { await appState.refreshObservabilityNow() }
                }
            }
        }
    }
}

#Preview {
    DiagnosticsView()
        .environmentObject(OpenClawAppState())
}
