//
//  ContentView.swift
//  OpenClawiOS
//
//  Created by Marcus Arnett on 2/15/26.
//

import SwiftUI

/// Root sample view that hosts deploy and chat flows.
struct ContentView: View {
    @EnvironmentObject private var appState: OpenClawAppState

    var body: some View {
        TabView {
            DeployView()
                .tabItem {
                    Label("Deploy", systemImage: "antenna.radiowaves.left.and.right")
                }

            ChatView()
                .tabItem {
                    Label("Chat", systemImage: "message")
                }
                .badge(appState.isDeployed ? nil : "!")

            ModelsView()
                .tabItem {
                    Label("Models", systemImage: "cpu")
                }

            SkillsView()
                .tabItem {
                    Label("Skills", systemImage: "wand.and.stars")
                }

            ChannelsView()
                .tabItem {
                    Label("Channels", systemImage: "bolt.horizontal.circle")
                }

            // Remote gateway chat over OpenClawGatewaySessionChatTransport (listed under More on iPhone).
            GatewayChatView()
                .tabItem {
                    Label("Gateway", systemImage: "network")
                }

            DiagnosticsView()
                .tabItem {
                    Label("Diagnostics", systemImage: "waveform.path.ecg")
                }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(OpenClawAppState())
}
