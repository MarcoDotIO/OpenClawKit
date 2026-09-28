// Listen (message text-to-speech) ships on iOS, macOS, visionOS and tvOS; not on watchOS.
#if !os(watchOS)
import Foundation
import OpenClawKit

extension OpenClawChatSpeechClip {
    /// Wraps gateway `tts.speak` audio, deriving a container file-extension hint from the provider output format
    /// (for example `mp3_44100_128` → `mp3`) so the buffered player can parse the clip.
    /// - Parameter gatewayAudio: Audio returned by ``TalkGatewayClient/synthesizeMessageSpeech(text:)``.
    public init(gatewayAudio: TalkGatewaySpeechAudio) {
        self.init(
            data: gatewayAudio.data,
            outputFormat: gatewayAudio.outputFormat,
            mimeType: nil,
            fileExtension: Self.containerExtension(outputFormat: gatewayAudio.outputFormat))
    }

    static func containerExtension(outputFormat: String?) -> String? {
        let format = outputFormat?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard !format.isEmpty else { return nil }
        let codec = format.split(whereSeparator: { $0 == "_" || $0 == "-" }).first.map(String.init) ?? format
        switch codec {
        case "mp3", "mpeg": return "mp3"
        case "wav", "wave", "riff": return "wav"
        case "aac", "m4a", "mp4": return "m4a"
        case "flac": return "flac"
        case "opus", "ogg": return "ogg"
        default: return nil
        }
    }
}

extension OpenClawChatSpeechController {
    /// Speech synthesis backed by the gateway's `tts.speak` method (the configured cloud TTS provider).
    ///
    /// Failures (no provider configured, empty audio, headerless PCM) make the controller fall back to the
    /// on-device `AVSpeechSynthesizer` voice. The in-process `GatewayServer` routes `talk.speak`, not `tts.speak`,
    /// so local-only hosts get the on-device voice.
    /// - Parameter client: Talk gateway client bound to the chat's connection.
    /// - Returns: A synthesis closure for ``init(synthesize:)``.
    public static func gatewaySpeechSynthesis(_ client: TalkGatewayClient) -> OpenClawChatSpeechSynthesis {
        { text in
            try await OpenClawChatSpeechClip(gatewayAudio: client.synthesizeMessageSpeech(text: text))
        }
    }

    /// Speech synthesis over any Talk-capable gateway connection (for example `GatewayNodeSession`).
    /// - Parameter gateway: Gateway connection.
    /// - Returns: A synthesis closure for ``init(synthesize:)``.
    public static func gatewaySpeechSynthesis(_ gateway: any TalkGatewayRequesting) -> OpenClawChatSpeechSynthesis {
        self.gatewaySpeechSynthesis(TalkGatewayClient(gateway))
    }

    /// Synthesis that always uses the on-device voice (no gateway round trip).
    public static let onDeviceSpeechSynthesis: OpenClawChatSpeechSynthesis = { _ in
        throw OnDeviceSpeechOnly()
    }
}

/// Signals the controller to skip gateway audio and speak with the on-device voice.
private struct OnDeviceSpeechOnly: Error {}
#endif
