//
//  ContentView.swift
//  OpenClawtvOS
//
//  Created by Marcus Arnett on 3/2/26.
//

import SwiftUI

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
