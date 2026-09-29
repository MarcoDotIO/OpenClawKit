//
//  OpenClawtvOSApp.swift
//  OpenClawtvOS
//
//  Created by Marcus Arnett on 3/2/26.
//

import OpenClawAppIntents
import OpenClawKit
import SwiftUI

@main
struct OpenClawtvOSApp: App {
    @StateObject private var appState = OpenClawAppState()

    init() {
        // Opt in to Apple StateReporting (tvOS 27+); a no-op on earlier systems.
        OpenClawSystemState.isEnabled = true
        // Register the SDK App Intents backend once, before the system can run an intent.
        OpenClawAppIntents.configure(host: ExampleIntentHost.shared)
        BackgroundRefreshManager.shared.register()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .task {
                    await BackgroundRefreshManager.shared.scheduleRefresh()
                }
        }
    }
}
