import Foundation
import OpenClawKit

/// Namespace for the OpenClaw App Intents integration.
///
/// `OpenClawAppIntents` provides reusable App Intents entities and intents (ask, run, talk, and
/// abort) for apps that embed OpenClawKit. The module is Apple-only.
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
