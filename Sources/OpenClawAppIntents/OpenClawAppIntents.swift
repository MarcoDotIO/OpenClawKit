import Foundation
import OpenClawKit

/// Namespace for the OpenClaw App Intents integration.
///
/// `OpenClawAppIntents` provides reusable App Intents entities (``OpenClawSessionAppEntity``,
/// ``OpenClawAgentAppEntity``) and intents (``AskOpenClawIntent``, ``StartOpenClawTalkIntent``,
/// ``AbortOpenClawRunIntent`` and, on OS 27, the long-running ``RunOpenClawTaskIntent``) for apps
/// that embed OpenClawKit. The module is Apple-only.
///
/// Host app setup:
/// 1. Call ``configure(host:)`` at launch with ``GatewayOpenClawIntentHost``,
///    ``EmbeddedOpenClawIntentHost`` or your own ``OpenClawIntentHost``.
/// 2. Declare an `AppIntentsPackage` in the app target whose `includedPackages` contains
///    ``OpenClawAppIntentsPackage``, so the app's App Intents metadata includes the SDK types.
/// 3. Keep the app's single `AppShortcutsProvider` in the app target and reference the SDK intents
///    there (the SDK cannot declare App Shortcuts for the host).
public enum OpenClawAppIntents {
    /// Release of OpenClawKit that introduced this module surface.
    public static let moduleVersion = "2026.3.0"

    /// Whether this build compiled the experimental model-delegation surface.
    ///
    /// The surface is built on the underscored AppIntents 27 `_ModelDelegationIntent` API and is
    /// only compiled when the package trait `ExperimentalAppleModelDelegation` is enabled, for example
    /// `.package(url: "https://github.com/MarcoDotIO/OpenClawKit", from: "2026.3.0",
    /// traits: [.defaults, "ExperimentalAppleModelDelegation"])`. The trait is off by default.
    public static var isExperimentalModelDelegationEnabled: Bool {
        #if ExperimentalAppleModelDelegation
        return true
        #else
        return false
        #endif
    }
}
