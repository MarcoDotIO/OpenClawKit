//
//  OpenClawtvOSApp.swift
//  OpenClawtvOS
//
//  Created by Marcus Arnett on 3/2/26.
//

import SwiftUI

@main
struct OpenClawtvOSApp: App {
    @StateObject private var appState = OpenClawAppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
        }
    }
}
