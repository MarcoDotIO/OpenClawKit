//
//  OpenClawiOSApp.swift
//  OpenClawiOS
//
//  Created by Marcus Arnett on 2/15/26.
//

import AppIntents
import OpenClawAppIntents
import OpenClawKit
import SwiftUI

/// Entry point for the OpenClaw iOS sample application.
@main
struct OpenClawiOSApp: App {
    @StateObject private var appState = OpenClawAppState()

    init() {
        // Opt in to Apple StateReporting (iOS 27+). The SDK owns the `ai.openclaw.*` domains and
        // never reports prompt text, tokens or hosts; on earlier systems this is a no-op.
        OpenClawSystemState.isEnabled = true
        // Register the SDK App Intents backend once, before the system can run an intent.
        OpenClawAppIntents.configure(host: ExampleIntentHost.shared)
        BackgroundContinuationManager.shared.registerTaskHandlers()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .onAppear {
                    OpenClawIntentBridge.shared.bind(self.appState)
                    BackgroundContinuationManager.shared.scheduleInitialTasksIfNeeded()
                    if let sharedPrompt = SharePromptInbox.dequeue() {
                        self.appState.pendingMessage = sharedPrompt.prompt
                    }
                }
        }
    }
}
