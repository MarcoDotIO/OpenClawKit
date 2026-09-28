import Foundation

/// How an Apple Watch app can run Talk. Metadata only: the SDK ships no Watch media stack.
public enum OpenClawWatchTalkTransport: String, Codable, Sendable, CaseIterable {
    /// Talk relayed through the paired iPhone (`watch.app.command` `start-talk`/`stop-talk`, status in
    /// ``OpenClawWatchAppSnapshotMessage``). Fully supported by the SDK contracts.
    case iPhoneRelay = "iphone-relay"
    /// One-turn "Talk to Claw": Watch dictation, text relayed through the iPhone as a durable
    /// ``OpenClawWatchChatDeliveryCommand``, and system-voice readback. Fully supported by the SDK contracts.
    case dictationTurn = "dictation-turn"
    /// Experimental standalone Watch Talk: native WebRTC/Opus over UDP with Gateway-owned call control
    /// (`gateway-control-v1`). Not implemented by the SDK (see ``OpenClawWatchTalkSupport``).
    case watchStandalone = "watch-standalone"

    /// Whether the SDK implements the transport end to end (contracts plus client).
    public var isImplementedBySDK: Bool {
        self != .watchStandalone
    }
}

/// Metadata for experimental standalone Apple Watch Talk (upstream 2026.9.2+).
///
/// Upstream's Watch app runs Talk without the iPhone: it creates a client-owned session with
/// `talk.client.create` (`capabilities: ["gateway-control-v1"]`) over an operator connection authorized by
/// the voice credential from a voice setup (``OpenClawWatchNodeConnectResponse/voiceScopes``), streams Opus
/// audio over WebRTC/UDP from a Rust staticlib (`apps/shared/OpenClawWatchRTC`), and leaves tools and
/// transcripts to the Gateway, which uses its configured realtime provider. There is no relay fallback:
/// unsupported configurations fail visibly.
///
/// The SDK keeps this metadata-only. It does not vendor the WebRTC staticlib (its own toolchain, out of
/// scope for a SwiftPM library), and standalone voice needs UDP plus an active audio session that watchOS
/// grants only to apps that own one. Apps use these constants to gate their UI, and the generated
/// `TalkClientCreateParams`/`TalkSessionCreateParams` models to talk to the Gateway if they bring their own
/// media stack. ``OpenClawWatchNodeClient/voiceAccess()`` exposes the stored voice credential.
public enum OpenClawWatchTalkSupport {
    /// Talk session capability that selects Gateway-owned call control.
    public static let gatewayControlCapability = "gateway-control-v1"
    /// Gateway method that creates the client-owned standalone session.
    public static let createMethod = "talk.client.create"
    /// Gateway method that closes it.
    public static let closeMethod = "talk.client.close"
    /// `device.pair.setupCode` bootstrap profile that also issues the voice operator credential.
    public static let voiceBootstrapProfile = "voice-node"
    /// Operator scopes of the voice credential.
    public static let voiceScopes = OpenClawWatchNodeConnectResponse.voiceScopes

    /// Transports this SDK build supports on the current platform.
    ///
    /// Standalone Talk is never included; iPhone-relayed transports are included on every platform so
    /// iPhone hosts can advertise them to their Watch app.
    public static var supportedTransports: [OpenClawWatchTalkTransport] {
        OpenClawWatchTalkTransport.allCases.filter(\.isImplementedBySDK)
    }
}
