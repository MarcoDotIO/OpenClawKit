#if canImport(AppIntents)
import AppIntents

/// Registers the OpenClaw intents and entities with the host app's App Intents metadata.
///
/// Verified with Xcode 27.1 (iOS app at a 17.0 deployment target): linking the `OpenClawAppIntents`
/// product is enough for the app's `Metadata.appintents` to contain the SDK intents, entities and
/// queries, including the OS 27 execution targets, because Xcode merges static-library metadata.
/// Declaring an app-level `AppIntentsPackage` that includes this package is still recommended for
/// older toolchains and for apps that re-export the SDK from their own framework.
///
/// App Shortcuts must be declared by the app itself (one `AppShortcutsProvider` per app), for example:
/// ```swift
/// struct AppIntentsPackageRoot: AppIntentsPackage {
///     static var includedPackages: [any AppIntentsPackage.Type] { [OpenClawAppIntentsPackage.self] }
/// }
///
/// struct AppShortcuts: AppShortcutsProvider {
///     static var appShortcuts: [AppShortcut] {
///         AppShortcut(
///             intent: StartOpenClawTalkIntent(),
///             phrases: ["Start live voice with \(.applicationName)"],
///             shortTitle: "Start Live Voice",
///             systemImageName: "waveform")
///         AppShortcut(
///             intent: AskOpenClawIntent(),
///             phrases: ["Ask \(.applicationName)"],
///             shortTitle: "Ask OpenClaw",
///             systemImageName: "message")
///     }
/// }
/// ```
public struct OpenClawAppIntentsPackage: AppIntentsPackage {}
#endif
