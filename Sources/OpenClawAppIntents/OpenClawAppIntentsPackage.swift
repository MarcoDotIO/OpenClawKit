#if canImport(AppIntents)
import AppIntents

/// Registers the OpenClaw intents and entities with the host app's App Intents metadata.
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
