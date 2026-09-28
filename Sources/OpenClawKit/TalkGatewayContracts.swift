import Foundation

// Typed Talk vocabulary for the protocol v4 Talk surface (OpenClaw 2026.9.6
// packages/gateway-protocol/src/schema/channels.ts). The generated protocol models keep these
// fields as `AnyCodable`/`String`; these enums give Swift callers the shared vocabulary.

/// Talk session shape (`mode`), shared by `talk.catalog`, `talk.session.create`, and `talk.client.create`.
public enum TalkMode: String, Codable, Sendable, CaseIterable {
    /// Speech-to-speech realtime provider session.
    case realtime
    /// Speech-to-text turns answered with text-to-speech.
    case sttTTS = "stt-tts"
    /// Transcription only; pair with ``TalkBrain/none``.
    case transcription
}

/// Talk transport family (`transport`); clients branch on it to choose the setup flow.
public enum TalkTransport: String, Codable, Sendable, CaseIterable {
    /// Client-owned WebRTC provider session (`talk.client.create`).
    case webrtc
    /// Client-owned provider WebSocket session (`talk.client.create`).
    case providerWebsocket = "provider-websocket"
    /// Gateway-owned relay: PCM streams through `talk.session.appendAudio` and `talk.event`.
    case gatewayRelay = "gateway-relay"
    /// Gateway-managed room (for example LiveKit) joined by URL and token.
    case managedRoom = "managed-room"

    /// Whether the app itself opens the provider connection (WebRTC or provider WebSocket).
    public var isClientOwned: Bool {
        self == .webrtc || self == .providerWebsocket
    }
}

/// How a Talk session delegates reasoning and tool use to the agent runtime (`brain`).
public enum TalkBrain: String, Codable, Sendable, CaseIterable {
    /// The realtime model consults the OpenClaw agent through `openclaw_agent_consult`.
    case agentConsult = "agent-consult"
    /// The realtime model calls tools directly.
    case directTools = "direct-tools"
    /// No agent involvement (transcription-only clients).
    case none
}

/// Agent control actions accepted from Talk clients (`talk.session.steer`, `talk.client.steer`).
public enum TalkAgentControlMode: String, Codable, Sendable, CaseIterable {
    /// Report run status.
    case status
    /// Steer the active run.
    case steer
    /// Cancel the active run.
    case cancel
    /// Queue a follow-up.
    case followup
}

/// Stable `talk.event` event types emitted across providers and transports.
public enum TalkEventType: String, Codable, Sendable, CaseIterable {
    /// Session started.
    case sessionStarted = "session.started"
    /// Provider session ready.
    case sessionReady = "session.ready"
    /// Session closed.
    case sessionClosed = "session.closed"
    /// Session error.
    case sessionError = "session.error"
    /// Session replaced (voice switch or reconnect).
    case sessionReplaced = "session.replaced"
    /// Turn started.
    case turnStarted = "turn.started"
    /// Turn ended.
    case turnEnded = "turn.ended"
    /// Turn cancelled (barge-in or explicit cancellation).
    case turnCancelled = "turn.cancelled"
    /// Capture started.
    case captureStarted = "capture.started"
    /// Capture stopped.
    case captureStopped = "capture.stopped"
    /// Capture cancelled.
    case captureCancelled = "capture.cancelled"
    /// One-shot capture.
    case captureOnce = "capture.once"
    /// Input audio delta.
    case inputAudioDelta = "input.audio.delta"
    /// Input audio committed.
    case inputAudioCommitted = "input.audio.committed"
    /// Transcript delta.
    case transcriptDelta = "transcript.delta"
    /// Transcript finalized.
    case transcriptDone = "transcript.done"
    /// Output text delta.
    case outputTextDelta = "output.text.delta"
    /// Output text finalized.
    case outputTextDone = "output.text.done"
    /// Output audio started.
    case outputAudioStarted = "output.audio.started"
    /// Output audio delta.
    case outputAudioDelta = "output.audio.delta"
    /// Output audio finished.
    case outputAudioDone = "output.audio.done"
    /// Tool call requested.
    case toolCall = "tool.call"
    /// Tool call progress.
    case toolProgress = "tool.progress"
    /// Tool call result.
    case toolResult = "tool.result"
    /// Tool call error.
    case toolError = "tool.error"
    /// Usage metrics.
    case usageMetrics = "usage.metrics"
    /// Latency metrics.
    case latencyMetrics = "latency.metrics"
    /// Health changed.
    case healthChanged = "health.changed"

    /// Whether events of this type must carry a `turnId` for client-side stream correlation.
    public var isTurnScoped: Bool {
        switch self {
        case .turnStarted, .turnEnded, .turnCancelled, .inputAudioDelta, .inputAudioCommitted,
             .transcriptDelta, .transcriptDone, .outputTextDelta, .outputTextDone,
             .outputAudioStarted, .outputAudioDelta, .outputAudioDone,
             .toolCall, .toolProgress, .toolResult, .toolError:
            return true
        default:
            return false
        }
    }

    /// Whether events of this type must carry a `captureId`.
    public var isCaptureScoped: Bool {
        switch self {
        case .captureStarted, .captureStopped, .captureCancelled, .captureOnce:
            return true
        default:
            return false
        }
    }
}

/// Gateway method names of the protocol v4 Talk and TTS surface.
///
/// `talk.realtime.session` was removed upstream in favor of `talk.session.*` (gateway relay) and
/// `talk.client.*` (client-owned transports).
public enum TalkGatewayMethod: String, Sendable, CaseIterable {
    /// Talk modes, transports, brains, and provider readiness (`TalkCatalogParams` → `TalkCatalogResult`).
    case catalog = "talk.catalog"
    /// Talk configuration (`TalkConfigParams` → `TalkConfigResult`).
    case config = "talk.config"
    /// Toggles Talk mode (`TalkModeParams`).
    case mode = "talk.mode"
    /// Talk-provider TTS (`TalkSpeakParams` → `TalkSpeakResult`).
    case speak = "talk.speak"
    /// Creates a client-owned session (`TalkClientCreateParams` → `TalkClientCreateResult`).
    case clientCreate = "talk.client.create"
    /// Records a client-side transcript line (`TalkClientTranscriptParams`).
    case clientTranscript = "talk.client.transcript"
    /// Closes a client-owned session (`TalkClientCloseParams`).
    case clientClose = "talk.client.close"
    /// Forwards a provider tool call to the agent (`TalkClientToolCallParams` → `TalkClientToolCallResult`).
    case clientToolCall = "talk.client.toolCall"
    /// Steers the agent from a client-owned session (`TalkClientSteerParams`).
    case clientSteer = "talk.client.steer"
    /// Creates a gateway-owned session (`TalkSessionCreateParams` → `TalkSessionCreateResult`).
    case sessionCreate = "talk.session.create"
    /// Appends PCM input audio to a relay (`TalkSessionAppendAudioParams`).
    case sessionAppendAudio = "talk.session.appendAudio"
    /// Cancels relay output (`TalkSessionCancelOutputParams` → `TalkSessionCancelOutputResult`).
    case sessionCancelOutput = "talk.session.cancelOutput"
    /// Acknowledges a playback mark (`TalkSessionAcknowledgeMarkParams`).
    case sessionAcknowledgeMark = "talk.session.acknowledgeMark"
    /// Submits a tool result to the provider (`TalkSessionSubmitToolResultParams`).
    case sessionSubmitToolResult = "talk.session.submitToolResult"
    /// Steers the agent from a relay session (`TalkSessionSteerParams` → `TalkAgentControlResult`).
    case sessionSteer = "talk.session.steer"
    /// Closes a gateway-owned session (`TalkSessionCloseParams` → `TalkSessionOkResult`).
    case sessionClose = "talk.session.close"
    /// Reads the realtime voice selection (`TalkVoiceGetParams` → `TalkVoiceSelection`).
    case voiceGet = "talk.voice.get"
    /// Requests a realtime voice change (`TalkVoiceSetParams` → `TalkVoiceSetResult`).
    case voiceSet = "talk.voice.set"
    /// Completes a negotiated voice change (`TalkVoiceCompleteParams`).
    case voiceComplete = "talk.voice.complete"
    /// One-shot TTS through the configured TTS chain (`TtsSpeakParams` → `TtsSpeakResult`).
    case ttsSpeak = "tts.speak"
}

/// Gateway event names of the Talk surface.
public enum TalkGatewayEventName: String, Sendable, CaseIterable {
    /// Talk session event (relay audio, transcripts, tool calls, lifecycle).
    case event = "talk.event"
    /// Talk mode toggled.
    case mode = "talk.mode"
    /// Negotiated realtime voice change (`TalkVoiceChangeEvent`).
    case voiceChange = "talk.voice.change"
}

/// SDK defaults for realtime Talk.
public enum TalkRealtimeDefaults {
    /// Default OpenAI realtime model for client-owned sessions when none is configured.
    ///
    /// Gateway-relay sessions omit the model so the gateway's configured default applies.
    /// GPT-Live models are audio-only; use this model when the camera is needed.
    public static let openAIModel = "gpt-realtime-2.1"
    /// Relay PCM16 sample rate in Hz when `talk.session.create` omits the audio contract.
    public static let relaySampleRateHz = 24000
    /// Relay audio encoding for input and output.
    public static let relayAudioEncoding = "pcm16"
}
