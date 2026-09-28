#if canImport(AVFAudio) && (os(iOS) || os(macOS) || os(visionOS))
import AVFAudio
import Foundation
import OpenClawProtocol
import OSLog

/// One encoded microphone frame delivered by a ``RealtimeTalkAudioCapturing`` implementation.
public struct RealtimeTalkAudioFrame: Sendable {
    /// Little-endian PCM16 mono samples at the relay's input sample rate.
    public let data: Data
    /// Capture timestamp in milliseconds (monotonic, typically `systemUptime * 1000`).
    public let timestampMs: Double
    /// Linear RMS amplitude (0...1) of the captured audio, used for barge-in and input meters.
    public let rms: Float

    /// Creates a microphone frame.
    /// - Parameters:
    ///   - data: Little-endian PCM16 mono samples.
    ///   - timestampMs: Capture timestamp in milliseconds.
    ///   - rms: Linear RMS amplitude (0...1).
    public init(data: Data, timestampMs: Double, rms: Float) {
        self.data = data
        self.timestampMs = timestampMs
        self.rms = rms
    }
}

/// Converts float microphone buffers into the relay's PCM16 mono wire format.
public enum RealtimeTalkPCM16Encoder {
    /// Linearly resamples, downmixes every channel to mono, clamps, and encodes little-endian Int16.
    ///
    /// Safe to call from realtime audio tap threads.
    /// - Parameters:
    ///   - buffer: Float32 PCM buffer (deinterleaved or interleaved).
    ///   - inputSampleRate: Sample rate of `buffer` in Hz.
    ///   - targetSampleRate: Relay input sample rate in Hz (24 kHz by default).
    /// - Returns: Encoded bytes, or empty data for degenerate input.
    nonisolated public static func encode(
        buffer: AVAudioPCMBuffer,
        inputSampleRate: Double,
        targetSampleRate: Double) -> Data
    {
        guard let channelData = buffer.floatChannelData,
              buffer.frameLength > 0,
              inputSampleRate > 0,
              targetSampleRate > 0
        else { return Data() }
        let frameCount = Int(buffer.frameLength)
        let channelCount = max(1, Int(buffer.format.channelCount))
        let interleaved = buffer.format.isInterleaved
        return self.encode(
            frameCount: frameCount,
            channelCount: channelCount,
            inputSampleRate: inputSampleRate,
            targetSampleRate: targetSampleRate)
        { frame, channel in
            interleaved
                ? channelData[0][(frame * channelCount) + channel]
                : channelData[channel][frame]
        }
    }

    /// Shared resampling/downmix kernel; `sample(frame, channel)` reads one float sample.
    nonisolated static func encode(
        frameCount: Int,
        channelCount: Int,
        inputSampleRate: Double,
        targetSampleRate: Double,
        sample: (Int, Int) -> Float) -> Data
    {
        guard frameCount > 0, channelCount > 0, inputSampleRate > 0, targetSampleRate > 0 else { return Data() }
        let outputCount = max(1, Int((Double(frameCount) * targetSampleRate / inputSampleRate).rounded(.down)))
        var data = Data(capacity: outputCount * MemoryLayout<Int16>.size)
        for index in 0..<outputCount {
            let sourcePosition = Double(index) * inputSampleRate / targetSampleRate
            let lower = min(frameCount - 1, Int(sourcePosition.rounded(.down)))
            let upper = min(frameCount - 1, lower + 1)
            let fraction = Float(sourcePosition - Double(lower))
            var mixed: Float = 0
            for channel in 0..<channelCount {
                let lowerSample = sample(lower, channel)
                mixed += lowerSample + ((sample(upper, channel) - lowerSample) * fraction)
            }
            let clamped = max(-1, min(1, mixed / Float(channelCount)))
            var intSample = Int16((clamped * Float(Int16.max)).rounded()).littleEndian
            withUnsafeBytes(of: &intSample) { data.append(contentsOf: $0) }
        }
        return data
    }
}

#if compiler(>=6.4)
@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
extension RealtimeTalkPCM16Encoder {
    /// Encodes a Sendable read-only float buffer (AVFAudio 27 `installAudioTap` delivery).
    ///
    /// Reads the buffer through its `Span` channel views, without unsafe pointers.
    /// - Parameters:
    ///   - buffer: Float32 read-only PCM buffer; other sample formats encode as empty data.
    ///   - inputSampleRate: Sample rate of `buffer` in Hz.
    ///   - targetSampleRate: Relay input sample rate in Hz.
    /// - Returns: Little-endian PCM16 mono bytes.
    nonisolated public static func encode(
        buffer: AVReadOnlyAudioPCMBuffer,
        inputSampleRate: Double,
        targetSampleRate: Double) -> Data
    {
        let frameCount = buffer.frameLength
        let channelCount = max(1, Int(buffer.format.channelCount))
        guard frameCount > 0, inputSampleRate > 0, targetSampleRate > 0 else { return Data() }
        let interleaved = buffer.format.isInterleaved
        // Gather each channel into a contiguous array; Span views cannot escape the switch.
        var channels: [[Float]] = []
        let bufferCount = interleaved ? 1 : channelCount
        for channel in 0..<bufferCount {
            guard case let .float(samples) = buffer.channelData(channel) else { return Data() }
            let expected = interleaved ? frameCount * channelCount : frameCount
            guard samples.count >= expected else { return Data() }
            var copy = [Float](repeating: 0, count: expected)
            for index in 0..<expected {
                copy[index] = samples[index]
            }
            channels.append(copy)
        }
        return self.encode(
            frameCount: frameCount,
            channelCount: channelCount,
            inputSampleRate: inputSampleRate,
            targetSampleRate: targetSampleRate)
        { frame, channel in
            interleaved ? channels[0][(frame * channelCount) + channel] : channels[channel][frame]
        }
    }
}
#endif

/// Microphone source for ``RealtimeTalkRelaySession``.
@MainActor
public protocol RealtimeTalkAudioCapturing: AnyObject {
    /// Whether microphone frames are dropped while relay audio plays (speaker echo guard).
    var suppressesInputDuringOutput: Bool { get }

    /// Starts capture and delivers PCM16 frames at `targetSampleRate`.
    /// - Parameters:
    ///   - targetSampleRate: Relay input sample rate in Hz.
    ///   - onAudio: Called from the audio thread with each encoded frame.
    ///   - onFailure: Called on the main actor when capture becomes unavailable.
    func start(
        targetSampleRate: Double,
        onAudio: @escaping @Sendable (RealtimeTalkAudioFrame) -> Void,
        onFailure: @escaping @MainActor (String) -> Void) throws

    /// Stops capture; later frames must not be delivered.
    func stop()
}

/// Gateway plumbing the relay session needs: event subscription, requests, and route currency.
///
/// Build one from any ``TalkGatewayRequesting`` connection with
/// ``RealtimeTalkRelayTransport/gateway(_:isCurrent:)``, or inject closures in tests.
public struct RealtimeTalkRelayTransport: Sendable {
    /// Subscribes to server events with the given newest-first buffer size.
    public let subscribeServerEvents: @Sendable (Int) async -> AsyncStream<EventFrame>
    /// Sends one gateway request `(method, params, timeoutMs)` and returns the response payload.
    public let request: @Sendable (String, [String: AnyCodable]?, Double) async throws -> Data
    /// Whether the connection that created the session is still the current route.
    public let isCurrent: @Sendable () async -> Bool

    /// Creates a transport from closures.
    /// - Parameters:
    ///   - subscribeServerEvents: Event subscription factory.
    ///   - request: Request sender.
    ///   - isCurrent: Route-currency probe; defaults to always current.
    public init(
        subscribeServerEvents: @escaping @Sendable (Int) async -> AsyncStream<EventFrame>,
        request: @escaping @Sendable (String, [String: AnyCodable]?, Double) async throws -> Data,
        isCurrent: @escaping @Sendable () async -> Bool = { true })
    {
        self.subscribeServerEvents = subscribeServerEvents
        self.request = request
        self.isCurrent = isCurrent
    }
}

/// A user-visible realtime Talk problem, classified for host fallback decisions.
public struct RealtimeTalkRelayIssue: Equatable, Sendable {
    /// Stable issue code (`realtime_unavailable`, `audio_input_unavailable`, `realtime_output_cancel_failed`).
    public let code: String
    /// Human-readable message (trimmed).
    public let message: String
    /// Realtime provider id, when known.
    public let provider: String?
    /// Realtime model id, when known.
    public let model: String?
    /// Transport name (`gateway-relay`).
    public let transport: String?
    /// Lifecycle phase (`connect`, `audio-input`, `output-playback`, `output-cancel`).
    public let phase: String?

    /// Creates an issue.
    /// - Parameters:
    ///   - code: Stable issue code.
    ///   - message: Human-readable message; surrounding whitespace is trimmed.
    ///   - provider: Realtime provider id.
    ///   - model: Realtime model id.
    ///   - transport: Transport name.
    ///   - phase: Lifecycle phase.
    public init(
        code: String = "realtime_unavailable",
        message: String,
        provider: String? = nil,
        model: String? = nil,
        transport: String? = nil,
        phase: String? = nil)
    {
        self.code = code
        self.message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        self.provider = provider
        self.model = model
        self.transport = transport
        self.phase = phase
    }
}

/// A partial or final transcript line from the realtime relay.
public struct RealtimeTalkTranscript: Equatable, Sendable {
    /// Speaker role (`user` or `assistant`).
    public let role: String
    /// Transcript text.
    public let text: String
    /// Whether the provider finalized this line.
    public let isFinal: Bool

    /// Creates a transcript line.
    /// - Parameters:
    ///   - role: Speaker role.
    ///   - text: Transcript text.
    ///   - isFinal: Whether the line is final.
    public init(role: String, text: String, isFinal: Bool) {
        self.role = role
        self.text = text
        self.isFinal = isFinal
    }
}

/// Why a ready relay session ended; hosts use it to choose recovery.
public enum RealtimeTalkRelayTermination: Equatable, Sendable {
    /// The gateway closed the relay, with its reason when provided.
    case remoteClose(reason: String?)
    /// A non-barge-in output cancellation (user, pause) ended the provider session.
    case outputCancelled(reason: String)
    /// The gateway event stream ended after the relay became ready.
    case eventStreamEnded
    /// The microphone failed or fell behind.
    case audioInputFailed(message: String)
    /// `talk.session.cancelOutput` failed, leaving remote output ownership unknown.
    case outputCancellationFailed
    /// Relay audio overflowed the bounded playback buffer or playback failed.
    case outputPlaybackOverflow
}

private enum RealtimeAudioSendOutcome {
    case sent, inactive, saturated, failed(String)
}

private actor RealtimeAudioSender {
    private let request: @Sendable (String, [String: AnyCodable]?, Double) async throws -> Data
    private var relaySessionId: String?
    private var pendingSends = 0
    private let maxPendingSends = 4

    init(
        relaySessionId: String,
        request: @escaping @Sendable (String, [String: AnyCodable]?, Double) async throws -> Data)
    {
        self.relaySessionId = relaySessionId
        self.request = request
    }

    func close() {
        self.relaySessionId = nil
    }

    func send(_ data: Data, timestampMs: Double) async -> RealtimeAudioSendOutcome {
        guard !Task.isCancelled, let relaySessionId else { return .inactive }
        guard self.pendingSends < self.maxPendingSends else { return .saturated }
        self.pendingSends += 1
        defer { self.pendingSends -= 1 }
        // The Gateway carries this straight into the provider's media timeline, and OpenAI rejects
        // a `conversation.item.truncate` whose `audio_end_ms` is not an integer -- a fractional
        // timestamp here kills the session on the first barge-in.
        let payload: [String: AnyCodable] = [
            "sessionId": AnyCodable(relaySessionId),
            "audioBase64": AnyCodable(data.base64EncodedString()),
            "timestamp": AnyCodable(timestampMs.rounded()),
        ]
        do {
            try Task.checkCancellation()
            let response = try await self.request("talk.session.appendAudio", payload, 8000)
            try Task.checkCancellation()
            _ = try JSONDecoder().decode(TalkSessionOkResult.self, from: response)
            return .sent
        } catch {
            return Task.isCancelled ? .inactive : .failed(error.localizedDescription)
        }
    }
}

/// Gateway-relay realtime Talk session (`talk.session.*` with transport `gateway-relay`).
///
/// The session creates a relay (`talk.session.create`, mode `realtime`, brain `agent-consult`),
/// streams microphone PCM16 through `talk.session.appendAudio`, plays relay audio from
/// `talk.event` payloads, forwards agent tool calls (`talk.client.toolCall` /
/// `talk.session.submitToolResult`), supports barge-in through `talk.session.cancelOutput`,
/// and closes the relay on teardown. Realtime requires OpenAI Platform API-key auth on the
/// gateway; `openai-codex` OAuth has no public realtime transport.
///
/// Startup failures throw; a lost gateway route throws an `NSError` in domain
/// `RealtimeTalkRelay` with code 7 so the host can fall back (never a `CancellationError`).
@MainActor
public final class RealtimeTalkRelaySession {
    private static let agentControlToolName = "openclaw_agent_control"

    /// Relay creation options.
    public struct Options: Sendable {
        /// Chat session key the realtime run consults.
        public let sessionKey: String
        /// Requested realtime provider; `nil` lets the gateway pick.
        public let provider: String?
        /// Requested realtime model; `nil` keeps the gateway-owned default.
        public let model: String?
        /// Requested realtime voice.
        public let voice: String?
        /// Whether this client handles `talk.voice.change` replacement (capability `voice-selection`).
        public let supportsVoiceSelection: Bool
        /// Voice change id when this session replaces another during a voice switch.
        public let voiceChangeId: String?

        /// Creates relay options.
        /// - Parameters:
        ///   - sessionKey: Chat session key.
        ///   - provider: Requested provider.
        ///   - model: Requested model.
        ///   - voice: Requested voice.
        ///   - supportsVoiceSelection: Advertise the `voice-selection` capability.
        ///   - voiceChangeId: Voice change id for replacement sessions.
        public init(
            sessionKey: String,
            provider: String?,
            model: String?,
            voice: String?,
            supportsVoiceSelection: Bool = false,
            voiceChangeId: String? = nil)
        {
            self.sessionKey = sessionKey
            self.provider = provider
            self.model = model
            self.voice = voice
            self.supportsVoiceSelection = supportsVoiceSelection
            self.voiceChangeId = voiceChangeId
        }
    }

    private struct ToolCallStartResponse: Decodable {
        let runId: String?
        let idempotencyKey: String?
    }

    private struct ChatCompletionResult {
        let text: String?
        let failed: Bool
    }

    private struct RelayChatEvent: Decodable {
        let runId: String?
        let state: String?
        let message: AnyCodable?
    }

    private enum StartupWaitResult {
        case ready
        case failed(RealtimeTalkRelayIssue)
        case cancelled
    }

    /// Startup abandons for two very different reasons and callers must not treat them alike.
    /// Local cancellation is caller-initiated and stays silent; a lost Gateway route is an
    /// external failure the runtime has to see, or Talk reports listening with no relay behind it.
    private enum LifecycleStatus {
        case current
        case cancelledLocally
        case routeLost
    }

    nonisolated private static let expectedInputEncoding = "pcm16"
    nonisolated private static let expectedOutputEncoding = "pcm16"
    nonisolated private static let defaultSampleRateHz = 24000
    nonisolated private static let bargeInRmsThreshold: Float = 0.08
    nonisolated private static let bargeInCooldownMs: Double = 900
    nonisolated private static let minOutputBeforeBargeInMs: Double = 250
    nonisolated private static let startupReadyTimeoutSeconds = 12
    /// At the protocol's 20 ms cadence this bounds queued relay audio to 640 ms / 30,720 bytes.
    /// Overflow terminates the session so recovery replaces a lagging playback path.
    nonisolated private static let maxBufferedOutputChunks = 32

    private let transport: RealtimeTalkRelayTransport
    private let audioCapture: any RealtimeTalkAudioCapturing
    private let options: Options
    private let pcmPlayer: PCMStreamingAudioPlaying
    private let logger = Logger(subsystem: "ai.openclaw", category: "talk.realtime.relay")
    private let onStatus: (String) -> Void
    private let onIssue: (RealtimeTalkRelayIssue) -> Void
    private let onTermination: (RealtimeTalkRelayTermination) -> Void
    private let onSpeakingChanged: (Bool) -> Void
    private let onInputLevel: (Double) -> Void
    private let onOutputLevel: (Double?) -> Void
    private let onTranscript: (RealtimeTalkTranscript) -> Void
    /// Talk-domain state reporter (listening / thinking / speaking / idle).
    private let talkStateReporter: OpenClawTalkStateReporter
    private var reportedTalkState: OpenClawTalkStateLabel?
    /// Playback-time-aligned envelope of the assistant PCM the relay schedules;
    /// drives the speaking waveform with real audio instead of a synthetic pulse.
    private var outputEnvelope: PCMPlaybackEnvelope?

    private var relaySessionId: String?
    private var serverClose: (sessionId: String, task: Task<Void, Error>)?
    private var hasReceivedReady = false
    private var hasReceivedFailure = false
    private var startupIssue: RealtimeTalkRelayIssue?
    private var startupWaiter: CheckedContinuation<StartupWaitResult, Never>?
    private var pendingPreRelayEvents: [EventFrame] = []
    private var inputSampleRateHz = Double(RealtimeTalkRelaySession.defaultSampleRateHz)
    private var outputSampleRateHz = Double(RealtimeTalkRelaySession.defaultSampleRateHz)
    private var supportsBargeIn: Bool? = true
    private var eventTask: Task<Void, Never>?
    private var toolCallTasks: [UUID: Task<Void, Never>] = [:]
    private var audioSendTasks: [UUID: Task<Void, Never>] = [:]
    private var outputTask: Task<Void, Never>?
    private var outputContinuation: AsyncThrowingStream<Data, Error>.Continuation?
    /// Provider deltas may span any number of frames; retain only the partial tail so the
    /// AsyncStream's 32 slots always contain bounded 20 ms PCM chunks.
    private var pendingOutputAudio = Data()
    private var outputSessionId = 0
    private var pendingPlaybackMarks: [String] = []
    private var audioSender: RealtimeAudioSender?
    private var isInputPaused = false
    private var isOutputPaused = false
    private var audioCaptureGeneration: UInt64 = 0
    private var isClosed = false
    private var lifecycleGeneration: UInt64 = 0
    private var outputCancellationGeneration: UInt64 = 0
    private var isOutputPlaying = false
    private var outputIdentity: OutputIdentity?
    private var suppressedOutputIdentity: OutputIdentity?
    private var awaitingOutputClear = false
    private var cancelledOutputTurnId: String?
    private var terminalOutputCancellationReason: String?
    private var outputCancellationTask: Task<Void, Never>?
    private var outputStartedAtMs: Double?
    private var lastBargeInAtMs: Double = 0
    private var micLogFrameCount = 0
    private var micLogByteCount = 0
    private var micLogMaxRms: Float = 0
    private var lastMicLogAtMs: Double = 0
    private var suppressedEchoFrameCount = 0
    private var suppressedEchoByteCount = 0
    private var suppressedEchoMaxRms: Float = 0
    private var lastSuppressedEchoLogAtMs: Double = 0
    private var outputAudioChunkCount = 0
    private var outputAudioByteCount = 0

    /// Gateway relay session id while the session is open (the voice session id for voice switching).
    public var voiceSessionId: String? {
        self.relaySessionId
    }

    /// Whether the relay reported `ready` and has not failed or closed.
    public var isReady: Bool {
        !self.isClosed && self.hasReceivedReady && !self.hasReceivedFailure && self.relaySessionId != nil
    }

    /// Creates a relay session. Call ``start()`` to connect.
    /// - Parameters:
    ///   - transport: Gateway plumbing.
    ///   - options: Relay creation options.
    ///   - audioCapture: Microphone source (``AVAudioEngineRealtimeTalkAudioCapture`` by default in hosts).
    ///   - pcmPlayer: Relay output player (``RealtimePCMStreamingAudioPlayer`` in hosts).
    ///   - onStatus: Short status lines for UI.
    ///   - onIssue: Classified problems.
    ///   - onTermination: Terminal reason once a ready session ends.
    ///   - onSpeakingChanged: Assistant output playing state.
    ///   - onInputLevel: Normalized microphone level.
    ///   - onOutputLevel: Normalized output level, `nil` when idle.
    ///   - onTranscript: Partial and final transcript lines.
    ///   - stateReporter: Destination for ``OpenClawStateDomain/talk`` reports; `nil` uses
    ///     ``OpenClawSystemState/shared`` (forwards only while ``OpenClawSystemState/isEnabled``).
    public init(
        transport: RealtimeTalkRelayTransport,
        options: Options,
        audioCapture: any RealtimeTalkAudioCapturing,
        pcmPlayer: PCMStreamingAudioPlaying,
        onStatus: @escaping (String) -> Void,
        onIssue: @escaping (RealtimeTalkRelayIssue) -> Void = { _ in },
        onTermination: @escaping (RealtimeTalkRelayTermination) -> Void = { _ in },
        onSpeakingChanged: @escaping (Bool) -> Void,
        onInputLevel: @escaping (Double) -> Void = { _ in },
        onOutputLevel: @escaping (Double?) -> Void = { _ in },
        onTranscript: @escaping (RealtimeTalkTranscript) -> Void = { _ in },
        stateReporter: (any OpenClawSystemStateReporting)? = nil)
    {
        self.transport = transport
        self.audioCapture = audioCapture
        self.options = options
        self.pcmPlayer = pcmPlayer
        self.onStatus = onStatus
        self.onIssue = onIssue
        self.onTermination = onTermination
        self.onSpeakingChanged = onSpeakingChanged
        self.onInputLevel = onInputLevel
        self.onOutputLevel = onOutputLevel
        self.onTranscript = onTranscript
        self.talkStateReporter = OpenClawTalkStateReporter(reporter: stateReporter)
    }

    /// Creates the relay, starts the microphone, and waits (up to 12 s) for the provider to be ready.
    ///
    /// Returns silently when ``stop()`` cancels startup locally.
    /// - Throws: A startup failure, or `NSError(domain: "RealtimeTalkRelay", code: 7)` when the
    ///   gateway route was replaced before startup finished.
    public func start() async throws {
        self.lifecycleGeneration &+= 1
        let lifecycleGeneration = self.lifecycleGeneration
        self.isClosed = false
        self.hasReceivedReady = false
        self.hasReceivedFailure = false
        self.supportsBargeIn = nil
        self.startupIssue = nil
        self.startupWaiter = nil
        self.pendingPreRelayEvents.removeAll()
        self.onStatus("Connecting realtime…")
        let eventStream = await self.transport.subscribeServerEvents(200)
        switch await self.lifecycleStatus(lifecycleGeneration) {
        case .current: break
        case .cancelledLocally: return
        case .routeLost: throw Self.gatewayRouteLostError()
        }
        self.startEventPump(stream: eventStream, lifecycleGeneration: lifecycleGeneration)
        do {
            let result = try await self.createRelaySession()
            let createdRelaySessionId = self.nonEmpty(result.relaysessionid)
            let statusAfterCreate = await self.lifecycleStatus(lifecycleGeneration)
            if statusAfterCreate != .current {
                if let relaySessionId = createdRelaySessionId {
                    try? await self.beginServerClose(relaySessionId: relaySessionId).value
                }
                if statusAfterCreate == .routeLost {
                    throw Self.gatewayRouteLostError()
                }
                return
            }
            if let startupIssue {
                if let relaySessionId = createdRelaySessionId {
                    try? await self.beginServerClose(relaySessionId: relaySessionId).value
                }
                throw Self.startupFailureError(startupIssue)
            }
            guard let relaySessionId = createdRelaySessionId else {
                throw NSError(domain: "RealtimeTalkRelay", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: String(
                        localized: "Gateway did not return a realtime relay session",
                        bundle: OpenClawKitResources.bundle),
                ])
            }
            self.relaySessionId = relaySessionId
            let supportsBargeIn = await self.resolveSupportsBargeIn(result)
            switch await self.lifecycleStatus(lifecycleGeneration) {
            case .current: break
            case .cancelledLocally: return
            case .routeLost: throw Self.gatewayRouteLostError()
            }
            self.supportsBargeIn = supportsBargeIn
            self.audioSender = RealtimeAudioSender(
                relaySessionId: relaySessionId,
                request: self.transport.request)
            self.configureAudioContract(result.audio)
            try self.startMicrophonePump(lifecycleGeneration: lifecycleGeneration)
            self.onStatus("Waiting for realtime…")
            await self.drainPendingPreRelayEvents(lifecycleGeneration: lifecycleGeneration)
            switch await self.lifecycleStatus(lifecycleGeneration) {
            case .current: break
            case .cancelledLocally: return
            case .routeLost: throw Self.gatewayRouteLostError()
            }
            switch await self.waitForStartupResult(
                timeoutSeconds: Self.startupReadyTimeoutSeconds,
                lifecycleGeneration: lifecycleGeneration)
            {
            case .ready, .cancelled:
                return
            case let .failed(issue):
                throw NSError(domain: "RealtimeTalkRelay", code: 6, userInfo: [
                    NSLocalizedDescriptionKey: issue.message,
                ])
            }
        } catch {
            // A lost route must still surface: swallowing here would discard both the original
            // failure and the route loss, leaving the runtime with nothing to fall back from.
            if await self.lifecycleStatus(lifecycleGeneration) == .cancelledLocally { return }
            let createdRelaySessionId = self.relaySessionId
            self.close(sendClose: false)
            if let createdRelaySessionId {
                try? await self.beginServerClose(relaySessionId: createdRelaySessionId).value
            }
            throw error
        }
    }

    /// Stops capture and playback and closes the relay (`talk.session.close`) without waiting.
    public func stop() {
        self.close(sendClose: true)
    }

    /// Stops and waits for the `talk.session.close` response.
    ///
    /// The close event precedes transcript persistence; replacements must wait for the RPC response.
    public func stopAndWait() async throws {
        self.stop()
        try await self.serverClose?.task.value
    }

    private func updateStatus(_ status: String, talkState: OpenClawTalkStateLabel) {
        self.onStatus(status)
        // Playback owns `speaking`; a status line never downgrades it.
        if self.reportedTalkState != .speaking {
            self.reportTalkState(talkState)
        }
    }

    private func updateSpeaking(_ speaking: Bool) {
        self.onSpeakingChanged(speaking)
        if speaking {
            self.reportTalkState(.speaking)
        } else if self.reportedTalkState == .speaking {
            self.reportTalkState(self.isClosed ? nil : .listening)
        }
    }

    private func reportTalkState(_ label: OpenClawTalkStateLabel?) {
        guard self.reportedTalkState != label else { return }
        self.reportedTalkState = label
        self.talkStateReporter.report(label, provider: label == .speaking ? self.options.provider : nil)
    }

    private func close(sendClose: Bool) {
        guard !self.isClosed else { return }
        self.isClosed = true
        self.lifecycleGeneration &+= 1
        self.finishStartupWait(.cancelled)
        self.stopMicrophonePump()
        self.eventTask?.cancel()
        self.eventTask = nil
        for task in self.toolCallTasks.values {
            task.cancel()
        }
        self.pendingPlaybackMarks.removeAll()
        let audioSender = self.audioSender
        self.audioSender = nil
        Task { await audioSender?.close() }
        self.retireOutputCancellation()
        self.cancelledOutputTurnId = nil
        self.terminalOutputCancellationReason = nil
        self.isOutputPaused = false
        self.stopOutputPlayback()
        if sendClose, let relaySessionId = self.relaySessionId {
            self.beginServerClose(relaySessionId: relaySessionId)
        }
        self.relaySessionId = nil
        self.updateSpeaking(false)
        self.reportTalkState(nil)
    }

    /// Deliberately not a `CancellationError`: the runtime treats those as caller-initiated and
    /// returns silently, while any other error routes Talk to its native fallback.
    nonisolated private static func gatewayRouteLostError() -> NSError {
        NSError(domain: "RealtimeTalkRelay", code: 7, userInfo: [
            NSLocalizedDescriptionKey: String(
                localized: "Gateway connection was replaced before realtime startup finished",
                bundle: OpenClawKitResources.bundle),
        ])
    }

    nonisolated private static func startupFailureError(_ issue: RealtimeTalkRelayIssue) -> NSError {
        NSError(domain: "RealtimeTalkRelay", code: 6, userInfo: [
            NSLocalizedDescriptionKey: issue.message,
        ])
    }

    @discardableResult
    private func beginServerClose(relaySessionId: String) -> Task<Void, Error> {
        if let serverClose, serverClose.sessionId == relaySessionId {
            return serverClose.task
        }
        let task = Task { [transport] in
            let payload = ["sessionId": AnyCodable(relaySessionId)]
            let response = try await transport.request("talk.session.close", payload, 8000)
            let result = try JSONDecoder().decode(TalkSessionOkResult.self, from: response)
            guard result.ok else { throw URLError(.badServerResponse) }
        }
        self.serverClose = (relaySessionId, task)
        return task
    }

    /// Pauses or resumes microphone streaming without closing the relay.
    /// - Parameter paused: `true` stops capture; `false` restarts it.
    /// - Throws: When capture cannot restart; input then stays paused.
    public func setInputPaused(_ paused: Bool) throws {
        guard self.isInputPaused != paused else { return }
        self.isInputPaused = paused
        if paused {
            self.stopMicrophonePump()
            self.onInputLevel(0)
        } else if !self.isClosed, self.relaySessionId != nil {
            do {
                try self.startMicrophonePump(lifecycleGeneration: self.lifecycleGeneration)
            } catch {
                self.isInputPaused = true
                throw error
            }
        }
    }

    /// Pauses or resumes relay output; pausing cancels the playing turn (`reason: "pause"`).
    /// - Parameter paused: Whether relay audio should be dropped.
    public func setOutputPaused(_ paused: Bool) {
        guard self.isOutputPaused != paused else { return }
        self.isOutputPaused = paused
        if paused, self.isOutputPlaying {
            self.cancelOutput(reason: "pause")
        }
    }

    private func createRelaySession() async throws -> TalkSessionCreateResult {
        var payload: [String: AnyCodable] = [
            "sessionKey": AnyCodable(self.options.sessionKey),
            "mode": AnyCodable(TalkMode.realtime.rawValue),
            "transport": AnyCodable(TalkTransport.gatewayRelay.rawValue),
            "brain": AnyCodable(TalkBrain.agentConsult.rawValue),
        ]
        if let provider = self.nonEmpty(self.options.provider) {
            payload["provider"] = AnyCodable(provider)
        }
        if let model = self.nonEmpty(self.options.model) {
            payload["model"] = AnyCodable(model)
        }
        if let voice = self.nonEmpty(self.options.voice) {
            payload["voice"] = AnyCodable(voice)
        }
        if self.options.supportsVoiceSelection {
            payload["capabilities"] = AnyCodable([AnyCodable("voice-selection")])
        }
        if let voiceChangeId = self.nonEmpty(self.options.voiceChangeId) {
            payload["voiceChangeId"] = AnyCodable(voiceChangeId)
        }
        let response = try await self.transport.request("talk.session.create", payload, 20000)
        return try JSONDecoder().decode(TalkSessionCreateResult.self, from: response)
    }

    private func configureAudioContract(_ raw: AnyCodable?) {
        guard let audio = raw?.dictionaryValue else { return }
        let inputEncoding = audio["inputEncoding"]?.stringValue ?? Self.expectedInputEncoding
        let outputEncoding = audio["outputEncoding"]?.stringValue ?? Self.expectedOutputEncoding
        if inputEncoding != Self.expectedInputEncoding || outputEncoding != Self.expectedOutputEncoding {
            let message = "unexpected realtime relay audio contract input=\(inputEncoding) output=\(outputEncoding)"
            self.logger.warning("\(message, privacy: .public)")
        }
        self.inputSampleRateHz = audio["inputSampleRateHz"]?.doubleValue
            ?? Double(Self.defaultSampleRateHz)
        self.outputSampleRateHz = audio["outputSampleRateHz"]?.doubleValue
            ?? Double(Self.defaultSampleRateHz)
    }

    private func resolveSupportsBargeIn(_ session: TalkSessionCreateResult) async -> Bool? {
        var payload: [String: AnyCodable] = [:]
        if let provider = self.nonEmpty(session.provider ?? self.options.provider) {
            payload["provider"] = AnyCodable(provider)
        }
        if let model = self.nonEmpty(session.model ?? self.options.model) {
            payload["model"] = AnyCodable(model)
        }
        // A talk-only client may create sessions without permission to read the catalog.
        // Unknown capability leaves interruption ownership with the provider.
        guard let response = try? await self.transport.request("talk.catalog", payload, 8000),
              let catalog = try? JSONDecoder().decode(TalkCatalogResult.self, from: response)
        else { return nil }
        let provider = (payload["provider"]?.stringValue
            ?? catalog.realtime["activeProvider"]?.stringValue)?.lowercased()
        let entry = catalog.realtime["providers"]?.arrayValue?.first {
            guard let entry = $0.dictionaryValue, let provider else { return false }
            return entry["id"]?.stringValue?.lowercased() == provider ||
                entry["aliases"]?.arrayValue?.contains { $0.stringValue?.lowercased() == provider } == true
        }?.dictionaryValue
        return entry?["supportsBargeIn"]?.boolValue ?? true
    }

    private func startEventPump(stream: AsyncStream<EventFrame>, lifecycleGeneration: UInt64) {
        self.eventTask?.cancel()
        self.eventTask = Task { [weak self] in
            for await event in stream {
                if Task.isCancelled { return }
                await self?.handleGatewayEvent(event, lifecycleGeneration: lifecycleGeneration)
            }
            guard !Task.isCancelled else { return }
            await self?.handleEventStreamEnded(lifecycleGeneration: lifecycleGeneration)
        }
    }
}

extension RealtimeTalkRelaySession {
    private func handleEventStreamEnded(lifecycleGeneration: UInt64) async {
        guard self.isCurrentLifecycleLocally(lifecycleGeneration) else { return }
        self.logger.debug("talk realtime: event stream ended")
        guard self.hasReceivedReady else {
            guard !self.hasReceivedFailure else { return }
            let issue = RealtimeTalkRelayIssue(
                message: String(
                    localized: "Realtime connection ended before it became ready.",
                    bundle: OpenClawKitResources.bundle),
                provider: self.options.provider,
                model: self.options.model,
                transport: TalkTransport.gatewayRelay.rawValue,
                phase: "connect")
            self.hasReceivedFailure = true
            self.startupIssue = issue
            self.onIssue(issue)
            self.onStatus(issue.message)
            self.finishStartupWait(.failed(issue))
            return
        }
        self.onStatus("Ready")
        self.close(sendClose: false)
        self.onTermination(.eventStreamEnded)
    }

    private func handleGatewayEvent(_ event: EventFrame, lifecycleGeneration: UInt64) async {
        guard self.isCurrentLifecycleLocally(lifecycleGeneration) else { return }
        guard event.event == "talk.event",
              let payload = event.payload?.dictionaryValue
        else { return }
        guard let relaySessionId else {
            self.pendingPreRelayEvents.append(event)
            if self.pendingPreRelayEvents.count > 200 {
                self.pendingPreRelayEvents.removeFirst(self.pendingPreRelayEvents.count - 200)
            }
            return
        }
        if payload["relaySessionId"]?.stringValue != relaySessionId {
            return
        }
        guard let type = payload["type"]?.stringValue else { return }
        switch type {
        case "ready":
            self.hasReceivedReady = true
            self.finishStartupWait(.ready)
            self.updateStatus("Listening (Realtime)", talkState: .listening)
        case "audio":
            self.handleOutputAudio(payload)
        case "audioDone":
            self.handleOutputAudioDone(payload)
        case "clear":
            self.handleOutputClear(payload)
        case "mark":
            self.handlePlaybackMark(payload)
        case "transcript":
            self.handleTranscriptEvent(payload)
        case "toolCall":
            self.startToolCall(payload, lifecycleGeneration: lifecycleGeneration)
        case "error":
            let message = payload["message"]?.stringValue
                ?? String(localized: "Realtime failed", bundle: OpenClawKitResources.bundle)
            let issue = Self.issue(
                payload: payload,
                fallbackMessage: message,
                fallbackProvider: self.options.provider,
                fallbackModel: self.options.model)
            self.logger.error("talk realtime: error=\(Self.safeLogMessage(message), privacy: .public)")
            self.hasReceivedFailure = true
            self.startupIssue = issue
            self.onIssue(issue)
            self.finishStartupWait(.failed(issue))
            self.onStatus(message)
        case "close":
            self.handleRelayClose(payload)
        default:
            return
        }
    }

    private func handleRelayClose(_ payload: [String: AnyCodable]) {
        self.logger.debug("talk realtime: close")
        if self.hasReceivedReady {
            self.onStatus("Ready")
            let reason = self.nonEmpty(payload["reason"]?.stringValue)
            let talkEvent = payload["talkEvent"]?.dictionaryValue
            let closedByOutputCancel = talkEvent?["type"]?.stringValue == "session.closed" &&
                talkEvent?["payload"]?.dictionaryValue?["reason"]?.stringValue == "output-cancelled"
            let termination: RealtimeTalkRelayTermination =
                if closedByOutputCancel, let cancellationReason = self.terminalOutputCancellationReason {
                    .outputCancelled(reason: cancellationReason)
                } else {
                    .remoteClose(reason: reason)
                }
            self.close(sendClose: false)
            self.onTermination(termination)
        } else if !self.hasReceivedFailure {
            let issue = RealtimeTalkRelayIssue(
                message: String(
                    localized: "Realtime closed before it became ready.",
                    bundle: OpenClawKitResources.bundle),
                provider: self.options.provider,
                model: self.options.model,
                transport: TalkTransport.gatewayRelay.rawValue,
                phase: "connect")
            self.onIssue(issue)
            self.startupIssue = issue
            self.finishStartupWait(.failed(issue))
            self.onStatus("Realtime failed before connecting")
        }
    }

    private func handleOutputClear(_ payload: [String: AnyCodable]) {
        let clearIdentity = OutputIdentity(payload)
        // Provider clears retire playback; only turn.cancelled acknowledges turn cancellation.
        let clearsSuppressed = self.awaitingOutputClear &&
            payload["talkEvent"]?.dictionaryValue?["type"]?.stringValue == "turn.cancelled" &&
            self.suppressedOutputIdentity?.relation(to: clearIdentity) == .same
        if clearsSuppressed {
            self.awaitingOutputClear = false
            if self.outputCancellationTask == nil { self.retireOutputCancellation() }
        }
        let currentMatches = clearIdentity.isEmpty() || self.outputIdentity?.relation(to: clearIdentity) == .same
        guard clearsSuppressed || currentMatches else { return }
        let marks = self.takePendingPlaybackMarks()
        // Cancellation already published the stopped state. A later clear with no
        // active output only retires the fence; it must not emit a duplicate callback.
        if self.isOutputPlaying || self.outputIdentity != nil {
            self.stopOutputPlayback()
        }
        self.acknowledgePlaybackMarks(marks)
    }

    private func waitForStartupResult(
        timeoutSeconds: Int,
        lifecycleGeneration: UInt64) async -> StartupWaitResult
    {
        if self.isClosed { return .cancelled }
        if self.hasReceivedReady { return .ready }
        if let startupIssue { return .failed(startupIssue) }
        return await withCheckedContinuation { continuation in
            if self.isClosed {
                continuation.resume(returning: .cancelled)
                return
            }
            self.startupWaiter = continuation
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeoutSeconds)) * 1_000_000_000)
                self?.timeoutStartupWaiterIfNeeded(lifecycleGeneration: lifecycleGeneration)
            }
        }
    }

    private func drainPendingPreRelayEvents(lifecycleGeneration: UInt64) async {
        let pendingEvents = self.pendingPreRelayEvents
        self.pendingPreRelayEvents.removeAll()
        for event in pendingEvents {
            guard self.isCurrentLifecycleLocally(lifecycleGeneration) else { return }
            await self.handleGatewayEvent(event, lifecycleGeneration: lifecycleGeneration)
        }
    }

    private func finishStartupWait(_ result: StartupWaitResult) {
        guard let waiter = self.startupWaiter else { return }
        self.startupWaiter = nil
        waiter.resume(returning: result)
    }

    private func timeoutStartupWaiterIfNeeded(lifecycleGeneration: UInt64) {
        guard self.lifecycleGeneration == lifecycleGeneration,
              !self.isClosed,
              self.startupWaiter != nil,
              !self.hasReceivedReady,
              self.startupIssue == nil
        else {
            return
        }
        let issue = RealtimeTalkRelayIssue(
            message: String(
                localized: "Realtime did not become ready in time.",
                bundle: OpenClawKitResources.bundle),
            provider: self.options.provider,
            model: self.options.model,
            transport: TalkTransport.gatewayRelay.rawValue,
            phase: "connect")
        self.hasReceivedFailure = true
        self.startupIssue = issue
        self.onIssue(issue)
        self.onStatus(issue.message)
        self.finishStartupWait(.failed(issue))
    }

    private static func issue(
        payload: [String: AnyCodable],
        fallbackMessage: String,
        fallbackProvider: String?,
        fallbackModel: String?) -> RealtimeTalkRelayIssue
    {
        let provider = payload["provider"]?.stringValue ?? fallbackProvider
        let model = payload["model"]?.stringValue ?? fallbackModel
        let transport = payload["transport"]?.stringValue ?? TalkTransport.gatewayRelay.rawValue
        let phase = payload["phase"]?.stringValue
        return RealtimeTalkRelayIssue(
            message: fallbackMessage,
            provider: provider,
            model: model,
            transport: transport,
            phase: phase)
    }

    private func recordOutputAudioChunk(byteCount: Int) {
        self.outputAudioChunkCount += 1
        self.outputAudioByteCount += byteCount
        guard self.outputAudioChunkCount == 1 || self.outputAudioChunkCount % 20 == 0 else { return }
        self.logger.debug(
            "talk realtime audio: chunks=\(self.outputAudioChunkCount) bytes=\(self.outputAudioByteCount)")
    }

    private func markOutputAudioStarted(nowMs: Double) {
        if !self.isOutputPlaying {
            self.outputStartedAtMs = nowMs
        }
        self.isOutputPlaying = true
    }

    private func handleInputLevelDuringOutput(_ rms: Float, timestampMs: Double) {
        guard self.isOutputPlaying else { return }
        guard rms >= Self.bargeInRmsThreshold else { return }
        if let outputStartedAtMs,
           timestampMs - outputStartedAtMs < Self.minOutputBeforeBargeInMs
        {
            return
        }
        guard timestampMs - self.lastBargeInAtMs >= Self.bargeInCooldownMs else { return }
        self.lastBargeInAtMs = timestampMs
        self.cancelOutput(reason: "barge-in")
    }

    private func handleTranscriptEvent(_ payload: [String: AnyCodable]) {
        let isFinal = payload["final"]?.boolValue == true
        let role = payload["role"]?.stringValue ?? ""
        let text = payload["text"]?.stringValue ?? ""
        let charCount = text.count
        self.logger.debug(
            "talk realtime transcript: role=\(role.isEmpty ? "unknown" : role) final=\(isFinal) chars=\(charCount)")
        self.onTranscript(RealtimeTalkTranscript(role: role, text: text, isFinal: isFinal))
        guard isFinal else { return }
        if role == "user" {
            self.updateStatus("Thinking…", talkState: .thinking)
        } else if role == "assistant" {
            self.updateStatus("Listening (Realtime)", talkState: .listening)
        }
    }

    private func handleToolCall(_ payload: [String: AnyCodable], lifecycleGeneration: UInt64) async {
        guard let relaySessionId,
              let callId = payload["callId"]?.stringValue,
              let name = payload["name"]?.stringValue
        else { return }
        self.updateStatus("Thinking…", talkState: .thinking)
        do {
            if name == Self.agentControlToolName {
                try await self.handleAgentControlToolCall(
                    callId: callId,
                    relaySessionId: relaySessionId,
                    args: payload["args"],
                    lifecycleGeneration: lifecycleGeneration)
                return
            }
            let completionStream = await self.transport.subscribeServerEvents(200)
            try await self.ensureCurrentLifecycle(lifecycleGeneration)
            let startPayload: [String: AnyCodable] = [
                "sessionKey": AnyCodable(self.options.sessionKey),
                "callId": AnyCodable(callId),
                "name": AnyCodable(name),
                "args": payload["args"] ?? AnyCodable([String: AnyCodable]()),
                "relaySessionId": AnyCodable(relaySessionId),
            ]
            let startResponse = try await self.requestJSON(
                method: "talk.client.toolCall",
                payload: startPayload,
                decodeAs: ToolCallStartResponse.self,
                timeoutSeconds: 30,
                lifecycleGeneration: lifecycleGeneration)
            guard let runId = startResponse.runId ?? startResponse.idempotencyKey else {
                throw NSError(domain: "RealtimeTalkRelay", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: String(
                        localized: "Realtime tool call did not return a run id",
                        bundle: OpenClawKitResources.bundle),
                ])
            }
            let completion = await self.waitForChatCompletion(
                runId: runId,
                stream: completionStream,
                timeoutSeconds: 120)
            try await self.ensureCurrentLifecycle(lifecycleGeneration)
            let result: [String: AnyCodable] = completion.failed
                ? ["error": AnyCodable("OpenClaw tool call failed")]
                : ["text": AnyCodable(completion.text ?? "OpenClaw finished with no text.")]
            try await self.submitToolResult(
                callId: callId,
                result: result,
                lifecycleGeneration: lifecycleGeneration)
            try await self.ensureCurrentLifecycle(lifecycleGeneration)
            self.updateStatus("Listening (Realtime)", talkState: .listening)
        } catch {
            guard await self.isCurrentLifecycle(lifecycleGeneration) else { return }
            let errorResult: [String: AnyCodable] = [
                "error": AnyCodable(error.localizedDescription),
            ]
            try? await self.submitToolResult(
                callId: callId,
                result: errorResult,
                lifecycleGeneration: lifecycleGeneration)
            guard await self.isCurrentLifecycle(lifecycleGeneration) else { return }
            self.updateStatus("Listening (Realtime)", talkState: .listening)
        }
    }

    private func startToolCall(_ payload: [String: AnyCodable], lifecycleGeneration: UInt64) {
        let taskID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.toolCallTasks.removeValue(forKey: taskID) }
            await self.handleToolCall(payload, lifecycleGeneration: lifecycleGeneration)
        }
        self.toolCallTasks[taskID] = task
    }

    private func handleAgentControlToolCall(
        callId: String,
        relaySessionId: String,
        args: AnyCodable?,
        lifecycleGeneration: UInt64) async throws
    {
        let controlArgs = args?.dictionaryValue ?? [:]
        var payload: [String: AnyCodable] = [
            "sessionId": AnyCodable(relaySessionId),
            "sessionKey": AnyCodable(self.options.sessionKey),
            "text": AnyCodable(
                controlArgs["text"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "status"),
        ]
        if let mode = controlArgs["mode"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           !mode.isEmpty
        {
            payload["mode"] = AnyCodable(mode)
        }
        let response = try await self.requestJSON(
            method: "talk.session.steer",
            payload: payload,
            decodeAs: AnyCodable.self,
            timeoutSeconds: 30,
            lifecycleGeneration: lifecycleGeneration)
        try await self.ensureCurrentLifecycle(lifecycleGeneration)
        let result = response.dictionaryValue ?? [
            "result": response,
        ]
        try await self.submitToolResult(
            callId: callId,
            result: result,
            lifecycleGeneration: lifecycleGeneration)
        try await self.ensureCurrentLifecycle(lifecycleGeneration)
        self.updateStatus("Listening (Realtime)", talkState: .listening)
    }

    private func submitToolResult(
        callId: String,
        result: [String: AnyCodable],
        lifecycleGeneration: UInt64) async throws
    {
        guard let relaySessionId else { return }
        let payload: [String: AnyCodable] = [
            "sessionId": AnyCodable(relaySessionId),
            "callId": AnyCodable(callId),
            "result": AnyCodable(result),
        ]
        _ = try await self.requestJSON(
            method: "talk.session.submitToolResult",
            payload: payload,
            decodeAs: TalkSessionOkResult.self,
            timeoutSeconds: 30,
            lifecycleGeneration: lifecycleGeneration)
    }

    private func waitForChatCompletion(
        runId: String,
        stream: AsyncStream<EventFrame>,
        timeoutSeconds: Int) async -> ChatCompletionResult
    {
        await withTaskGroup(of: ChatCompletionResult.self) { group in
            group.addTask {
                for await event in stream {
                    if Task.isCancelled {
                        return ChatCompletionResult(text: nil, failed: true)
                    }
                    guard event.event == "chat",
                          let payload = event.payload,
                          let chatEvent = try? GatewayPayloadDecoding.decode(payload, as: RelayChatEvent.self),
                          chatEvent.runId == runId
                    else { continue }
                    if chatEvent.state == "final" {
                        return ChatCompletionResult(
                            text: Self.assistantText(from: chatEvent.message),
                            failed: false)
                    }
                    if chatEvent.state == "aborted" || chatEvent.state == "error" {
                        return ChatCompletionResult(text: nil, failed: true)
                    }
                }
                return ChatCompletionResult(text: nil, failed: true)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds) * 1_000_000_000)
                return ChatCompletionResult(text: nil, failed: true)
            }
            let result = await group.next() ?? ChatCompletionResult(text: nil, failed: true)
            group.cancelAll()
            return result
        }
    }

    private func requestJSON<T: Decodable>(
        method: String,
        payload: [String: AnyCodable],
        decodeAs type: T.Type,
        timeoutSeconds: Int,
        lifecycleGeneration: UInt64) async throws -> T
    {
        try await self.ensureCurrentLifecycle(lifecycleGeneration)
        let response = try await self.transport.request(method, payload, Double(timeoutSeconds * 1000))
        try await self.ensureCurrentLifecycle(lifecycleGeneration)
        return try JSONDecoder().decode(type, from: response)
    }

    private func lifecycleStatus(_ lifecycleGeneration: UInt64) async -> LifecycleStatus {
        guard self.isCurrentLifecycleLocally(lifecycleGeneration) else { return .cancelledLocally }
        let routeIsCurrent = await self.transport.isCurrent()
        guard self.isCurrentLifecycleLocally(lifecycleGeneration) else { return .cancelledLocally }
        return routeIsCurrent ? .current : .routeLost
    }

    private func isCurrentLifecycle(_ lifecycleGeneration: UInt64) async -> Bool {
        await self.lifecycleStatus(lifecycleGeneration) == .current
    }

    private func isCurrentLifecycleLocally(_ lifecycleGeneration: UInt64) -> Bool {
        !Task.isCancelled && !self.isClosed && self.lifecycleGeneration == lifecycleGeneration
    }

    private func ensureCurrentLifecycle(_ lifecycleGeneration: UInt64) async throws {
        try Task.checkCancellation()
        guard await self.isCurrentLifecycle(lifecycleGeneration) else { throw CancellationError() }
    }

    private func ensureOutputPlaybackStarted() {
        guard self.outputContinuation == nil, self.outputTask == nil else { return }
        self.outputSessionId += 1
        let sessionId = self.outputSessionId
        let envelope = self.outputEnvelope ?? PCMPlaybackEnvelope { [weak self] level in
            self?.onOutputLevel(level)
        }
        envelope.begin(sampleRate: self.outputSampleRateHz)
        self.outputEnvelope = envelope
        let stream = AsyncThrowingStream<Data, Error>(
            bufferingPolicy: .bufferingOldest(Self.maxBufferedOutputChunks))
        { continuation in self.outputContinuation = continuation }
        self.outputTask = Task { [weak self] in
            guard let self else { return }
            guard self.outputSessionId == sessionId, !self.isClosed, !Task.isCancelled else { return }
            let result = await self.pcmPlayer.play(stream: stream, sampleRate: self.outputSampleRateHz)
            guard self.outputSessionId == sessionId else { return }
            self.outputTask = nil
            self.outputContinuation = nil
            if !result.finished {
                if let interruptedAt = result.interruptedAt {
                    self.logger.info("realtime output interrupted at \(interruptedAt, privacy: .public)s")
                }
                self.handleOutputPlaybackFailure(
                    String(
                        localized: "Realtime audio playback failed. Reconnecting…",
                        bundle: OpenClawKitResources.bundle))
                return
            }
            self.markOutputPlaybackFinished()
        }
    }

    private func finishOutputPlaybackStream() {
        guard let continuation = self.outputContinuation else { return }
        if !self.pendingOutputAudio.isEmpty {
            let trailingFrame = self.pendingOutputAudio
            self.pendingOutputAudio.removeAll(keepingCapacity: true)
            guard self.yieldOutputAudioFrame(trailingFrame) else { return }
        }
        continuation.finish()
        self.outputContinuation = nil
    }

    private func markOutputPlaybackFinished() {
        // Only drained playback completes output; elapsed time cannot prove the
        // device finished queued audio. Publish the terminal transition once.
        guard self.isOutputPlaying else { return }
        self.isOutputPlaying = false
        self.outputIdentity = nil
        self.outputStartedAtMs = nil
        self.outputEnvelope?.cancel()
        self.updateSpeaking(false)
        self.acknowledgePlaybackMarks(self.takePendingPlaybackMarks())
    }

    private func takePendingPlaybackMarks() -> [String] {
        let marks = self.pendingPlaybackMarks
        self.pendingPlaybackMarks.removeAll()
        return marks
    }

    private func handlePlaybackMark(_ payload: [String: AnyCodable]) {
        guard let markName = payload["markName"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !markName.isEmpty
        else { return }
        if self.isOutputPlaying {
            self.pendingPlaybackMarks.append(markName)
        } else {
            self.acknowledgePlaybackMarks([markName])
        }
    }

    private func acknowledgePlaybackMarks(_ marks: [String]) {
        guard !marks.isEmpty,
              let relaySessionId = self.relaySessionId
        else { return }
        for markName in marks {
            Task { [transport, logger] in
                let payload: [String: AnyCodable] = [
                    "sessionId": AnyCodable(relaySessionId),
                    "markName": AnyCodable(markName),
                ]
                do {
                    _ = try await transport.request("talk.session.acknowledgeMark", payload, 8000)
                } catch {
                    let message = Self.safeLogMessage(error.localizedDescription)
                    logger.warning(
                        "talk realtime: mark acknowledgement failed=\(message, privacy: .public)")
                }
            }
        }
    }

    private func stopOutputPlayback() {
        self.outputSessionId += 1
        self.outputContinuation?.finish()
        self.outputContinuation = nil
        self.pendingOutputAudio.removeAll(keepingCapacity: true)
        self.outputTask?.cancel()
        self.outputTask = nil
        _ = self.pcmPlayer.stop()
        self.isOutputPlaying = false
        self.outputIdentity = nil
        self.outputStartedAtMs = nil
        self.outputEnvelope?.cancel()
        self.updateSpeaking(false)
    }

    nonisolated private static func safeLogMessage(_ value: String) -> String {
        let singleLine = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        if singleLine.count <= 180 {
            return singleLine
        }
        return String(singleLine.prefix(180)) + "..."
    }

    private func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    nonisolated private static func assistantText(from message: AnyCodable?) -> String? {
        guard let message else { return nil }
        if let text = message.stringValue {
            return self.trimmed(text)
        }
        guard let object = message.dictionaryValue else { return nil }
        if let role = self.trimmed(object["role"]?.stringValue), role.lowercased() != "assistant" {
            return nil
        }
        guard let content = object["content"] else { return nil }
        if let text = content.stringValue {
            return self.trimmed(text)
        }
        let parts = content.arrayValue?.compactMap { part -> String? in
            if let text = part.stringValue { return self.trimmed(text) }
            return self.trimmed(part.dictionaryValue?["text"]?.stringValue)
        } ?? []
        return self.trimmed(parts.joined(separator: "\n"))
    }

    nonisolated private static func trimmed(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension RealtimeTalkRelaySession {
    private struct OutputIdentity {
        enum Relation {
            case same
            case different
            case unknown
        }

        let turnId: String?
        init(_ payload: [String: AnyCodable]) {
            let turnId = payload["talkEvent"]?.dictionaryValue?["turnId"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            self.turnId = turnId?.isEmpty == false ? turnId : nil
        }

        func isEmpty() -> Bool {
            self.turnId == nil
        }

        func relation(to other: OutputIdentity) -> Relation {
            if self.isEmpty() || other.isEmpty() {
                return self.isEmpty() == other.isEmpty() ? .same : .different
            }
            if let turnId, let otherTurnId = other.turnId {
                return turnId == otherTurnId ? .same : .different
            }
            return .unknown
        }
    }

    /// Cancels the playing assistant turn (`talk.session.cancelOutput`) and fences its late audio.
    ///
    /// Barge-in cancellation is ignored when the provider owns interruptions (catalog
    /// `supportsBargeIn == false` or unknown).
    /// - Parameter reason: `user` (default), `pause`, or `barge-in`.
    /// - Returns: `true` when a cancellation was issued.
    @discardableResult
    public func cancelOutput(reason: String = "user") -> Bool {
        guard reason != "barge-in" || self.supportsBargeIn == true else { return false }
        guard let relaySessionId,
              let outputIdentity = self.outputIdentity,
              let turnId = outputIdentity.turnId
        else { return false }
        self.outputCancellationGeneration &+= 1
        let cancellationGeneration = self.outputCancellationGeneration
        self.outputCancellationTask?.cancel()
        self.terminalOutputCancellationReason = reason == "barge-in" ? nil : reason
        self.suppressedOutputIdentity = outputIdentity
        self.cancelledOutputTurnId = outputIdentity.turnId
        self.awaitingOutputClear = true
        self.stopOutputPlayback()
        self.outputCancellationTask = Task { [weak self, transport] in
            let payload: [String: AnyCodable] = [
                "sessionId": AnyCodable(relaySessionId),
                "reason": AnyCodable(reason),
                "turnId": AnyCodable(turnId),
            ]
            do {
                let response = try await transport.request("talk.session.cancelOutput", payload, 8000)
                let result = try JSONDecoder().decode(TalkSessionCancelOutputResult.self, from: response)
                guard result.ok else { throw URLError(.badServerResponse) }
                guard let self, self.isCurrentOutputCancellation(cancellationGeneration) else { return }
                switch result.status?.stringValue {
                case "stale", "idle":
                    self.terminalOutputCancellationReason = nil
                    self.acknowledgePlaybackMarks(self.takePendingPlaybackMarks())
                    self.retireOutputCancellation()
                case nil, "applied":
                    guard result.turnid == nil || result.turnid == turnId else {
                        throw URLError(.badServerResponse)
                    }
                    if self.awaitingOutputClear {
                        self.outputCancellationTask = nil
                    } else {
                        self.retireOutputCancellation()
                    }
                default:
                    throw URLError(.badServerResponse)
                }
            } catch {
                guard let self, self.isCurrentOutputCancellation(cancellationGeneration) else { return }
                let issue = RealtimeTalkRelayIssue(
                    code: "realtime_output_cancel_failed",
                    message: String(
                        format: String(
                            localized: "Realtime output cancellation failed: %@",
                            bundle: OpenClawKitResources.bundle),
                        error.localizedDescription),
                    provider: self.options.provider,
                    model: self.options.model,
                    transport: TalkTransport.gatewayRelay.rawValue,
                    phase: "output-cancel")
                self.onIssue(issue)
                self.onStatus(issue.message)
                // A failed current cancellation leaves remote output ownership unknown.
                // Keep the fence until terminal teardown makes late audio impossible.
                self.close(sendClose: true)
                self.onTermination(.outputCancellationFailed)
            }
        }
        return true
    }

    private func isCurrentOutputCancellation(_ generation: UInt64) -> Bool {
        generation == self.outputCancellationGeneration && !self.isClosed
    }

    private func handleOutputAudio(_ payload: [String: AnyCodable]) {
        guard !self.isOutputPaused else { return }
        let incomingIdentity = OutputIdentity(payload)
        guard let incomingTurnId = incomingIdentity.turnId else {
            self.handleOutputPlaybackOverflow()
            return
        }
        guard !self.awaitingOutputClear else { return }
        if let cancelledOutputTurnId {
            if incomingTurnId == cancelledOutputTurnId {
                return
            }
        }
        guard let base64 = payload["audioBase64"]?.stringValue else { return }
        guard let data = Data(base64Encoded: base64) else {
            self.handleOutputPlaybackOverflow()
            return
        }
        self.terminalOutputCancellationReason = nil
        if let currentIdentity = self.outputIdentity,
           currentIdentity.relation(to: incomingIdentity) == .different
        {
            let marks = self.takePendingPlaybackMarks()
            self.stopOutputPlayback()
            self.acknowledgePlaybackMarks(marks)
        } else if self.outputContinuation == nil, self.outputTask != nil {
            self.stopOutputPlayback()
        }
        self.outputIdentity = incomingIdentity
        self.recordOutputAudioChunk(byteCount: data.count)
        self.markOutputAudioStarted(nowMs: ProcessInfo.processInfo.systemUptime * 1000)
        self.updateSpeaking(true)
        self.ensureOutputPlaybackStarted()
        self.bufferOutputAudio(data)
    }

    private func bufferOutputAudio(_ data: Data) {
        let frameByteCount = max(2, Int((self.outputSampleRateHz * 0.02).rounded()) * 2)
        var offset = data.startIndex
        if !self.pendingOutputAudio.isEmpty {
            let fillCount = min(frameByteCount - self.pendingOutputAudio.count, data.count)
            let fillEnd = data.index(offset, offsetBy: fillCount)
            self.pendingOutputAudio.append(data[offset..<fillEnd])
            offset = fillEnd
            if self.pendingOutputAudio.count == frameByteCount {
                let frame = self.pendingOutputAudio
                self.pendingOutputAudio.removeAll(keepingCapacity: true)
                guard self.yieldOutputAudioFrame(frame) else { return }
            }
        }
        while data.distance(from: offset, to: data.endIndex) >= frameByteCount {
            let frameEnd = data.index(offset, offsetBy: frameByteCount)
            let frame = Data(data[offset..<frameEnd])
            offset = frameEnd
            guard self.yieldOutputAudioFrame(frame) else { return }
        }
        if offset < data.endIndex {
            self.pendingOutputAudio.append(data[offset...])
        }
    }

    private func yieldOutputAudioFrame(_ data: Data) -> Bool {
        guard let continuation = self.outputContinuation else { return false }
        switch continuation.yield(data) {
        case .enqueued:
            self.outputEnvelope?.append(data)
            return true
        case .dropped:
            self.handleOutputPlaybackOverflow()
            return false
        case .terminated:
            return false
        @unknown default:
            self.handleOutputPlaybackOverflow()
            return false
        }
    }

    private func handleOutputAudioDone(_ payload: [String: AnyCodable]) {
        let incomingIdentity = OutputIdentity(payload)
        if !incomingIdentity.isEmpty(),
           let outputIdentity,
           outputIdentity.relation(to: incomingIdentity) != .same
        {
            return
        }
        self.finishOutputPlaybackStream()
    }

    private func handleOutputPlaybackOverflow() {
        self.handleOutputPlaybackFailure(
            String(
                localized: "Realtime audio playback fell behind. Reconnecting…",
                bundle: OpenClawKitResources.bundle))
    }

    private func handleOutputPlaybackFailure(_ message: String) {
        guard !self.isClosed else { return }
        let issue = RealtimeTalkRelayIssue(
            message: message,
            provider: self.options.provider,
            model: self.options.model,
            transport: TalkTransport.gatewayRelay.rawValue,
            phase: "output-playback")
        self.onIssue(issue)
        self.onStatus(message)
        self.close(sendClose: true)
        self.onTermination(.outputPlaybackOverflow)
    }

    private func retireOutputCancellation() {
        self.outputCancellationGeneration &+= 1
        self.outputCancellationTask?.cancel()
        self.outputCancellationTask = nil
        self.suppressedOutputIdentity = nil
        self.awaitingOutputClear = false
    }
}

extension RealtimeTalkRelaySession {
    private func startMicrophonePump(lifecycleGeneration: UInt64) throws {
        self.stopMicrophonePump()
        guard !self.isInputPaused else { return }
        let audioCaptureGeneration = self.audioCaptureGeneration
        try self.audioCapture.start(
            targetSampleRate: self.inputSampleRateHz,
            onAudio: { [weak self] frame in
                Task { @MainActor [weak self] in
                    _ = self?.enqueueMicrophoneFrame(
                        frame.data,
                        timestampMs: frame.timestampMs,
                        rms: frame.rms,
                        lifecycleGeneration: lifecycleGeneration,
                        audioCaptureGeneration: audioCaptureGeneration)
                }
            },
            onFailure: { [weak self] message in
                self?.handleAudioInputFailure(
                    message,
                    lifecycleGeneration: lifecycleGeneration,
                    audioCaptureGeneration: audioCaptureGeneration)
            })
    }

    private func handleAudioInputFailure(
        _ message: String,
        lifecycleGeneration: UInt64,
        audioCaptureGeneration: UInt64)
    {
        guard !self.isClosed, self.isCurrentLifecycleLocally(lifecycleGeneration),
              self.audioCaptureGeneration == audioCaptureGeneration
        else { return }
        let issue = RealtimeTalkRelayIssue(
            code: "audio_input_unavailable",
            message: message,
            provider: self.options.provider,
            model: self.options.model,
            transport: TalkTransport.gatewayRelay.rawValue,
            phase: "audio-input")
        self.logger.error("talk realtime microphone failed: \(Self.safeLogMessage(message), privacy: .public)")
        self.onIssue(issue)
        self.onStatus(message)
        self.close(sendClose: true)
        self.onTermination(.audioInputFailed(message: message))
    }

    @discardableResult
    private func enqueueMicrophoneFrame(
        _ encoded: Data,
        timestampMs: Double,
        rms: Float,
        lifecycleGeneration: UInt64,
        audioCaptureGeneration: UInt64) -> Task<Void, Never>?
    {
        guard self.isCurrentLifecycleLocally(lifecycleGeneration),
              self.audioCaptureGeneration == audioCaptureGeneration,
              !self.isInputPaused, self.suppressedOutputIdentity == nil,
              let audioSender = self.audioSender
        else { return nil }
        self.recordMicrophoneFrame(byteCount: encoded.count, rms: rms, timestampMs: timestampMs)
        // Continuous providers own interruptions and need input throughout playback.
        if self.isOutputPlaying, self.supportsBargeIn == true {
            if self.audioCapture.suppressesInputDuringOutput {
                self.recordSuppressedOutputEchoFrame(
                    byteCount: encoded.count,
                    rms: rms,
                    timestampMs: timestampMs)
                return nil
            }
            if rms >= Self.bargeInRmsThreshold {
                self.handleInputLevelDuringOutput(rms, timestampMs: timestampMs)
            }
        }

        let taskID = UUID()
        let task = Task { @MainActor [weak self, audioSender] in
            guard let self else { return }
            defer { self.audioSendTasks.removeValue(forKey: taskID) }
            guard self.isCurrentLifecycleLocally(lifecycleGeneration),
                  self.audioCaptureGeneration == audioCaptureGeneration,
                  !self.isInputPaused, self.suppressedOutputIdentity == nil
            else { return }
            switch await audioSender.send(encoded, timestampMs: timestampMs) {
            case .sent, .inactive:
                return
            case .saturated:
                self.handleAudioInputFailure(
                    String(
                        localized: "Realtime audio input fell behind. Reconnecting…",
                        bundle: OpenClawKitResources.bundle),
                    lifecycleGeneration: lifecycleGeneration,
                    audioCaptureGeneration: audioCaptureGeneration)
            case let .failed(message):
                self.handleAudioInputFailure(
                    String(
                        format: String(
                            localized: "Realtime audio failed: %@",
                            bundle: OpenClawKitResources.bundle),
                        message),
                    lifecycleGeneration: lifecycleGeneration,
                    audioCaptureGeneration: audioCaptureGeneration)
            }
        }
        self.audioSendTasks[taskID] = task
        return task
    }

    private func recordMicrophoneFrame(byteCount: Int, rms: Float, timestampMs: Double) {
        guard !self.isClosed else { return }
        self.onInputLevel(TalkAudioLevel.normalized(rms: Double(rms)))
        self.micLogFrameCount += 1
        self.micLogByteCount += byteCount
        self.micLogMaxRms = max(self.micLogMaxRms, rms)
        guard timestampMs - self.lastMicLogAtMs >= 1000 else { return }
        self.lastMicLogAtMs = timestampMs
        let maxRms = String(format: "%.4f", Double(self.micLogMaxRms))
        self.logger.debug(
            "talk realtime mic: buffers=\(self.micLogFrameCount) bytes=\(self.micLogByteCount) maxRms=\(maxRms)")
        self.micLogFrameCount = 0
        self.micLogByteCount = 0
        self.micLogMaxRms = 0
    }

    private func recordSuppressedOutputEchoFrame(byteCount: Int, rms: Float, timestampMs: Double) {
        self.suppressedEchoFrameCount += 1
        self.suppressedEchoByteCount += byteCount
        self.suppressedEchoMaxRms = max(self.suppressedEchoMaxRms, rms)
        guard timestampMs - self.lastSuppressedEchoLogAtMs >= 1000 else { return }
        self.lastSuppressedEchoLogAtMs = timestampMs
        let maxRms = String(format: "%.4f", Double(self.suppressedEchoMaxRms))
        let frames = self.suppressedEchoFrameCount
        let bytes = self.suppressedEchoByteCount
        self.logger.debug(
            "talk realtime mic suppressed during output: buffers=\(frames) bytes=\(bytes) maxRms=\(maxRms)")
        self.suppressedEchoFrameCount = 0
        self.suppressedEchoByteCount = 0
        self.suppressedEchoMaxRms = 0
    }

    private func stopMicrophonePump() {
        self.audioCaptureGeneration &+= 1
        for task in self.audioSendTasks.values {
            task.cancel()
        }
        self.audioSendTasks.removeAll()
        self.audioCapture.stop()
    }
}

#if DEBUG
extension RealtimeTalkRelaySession {
    // Package tests drive a relay session without a live gateway handshake.
    func _test_setRelaySessionId(_ relaySessionId: String) {
        self.relaySessionId = relaySessionId
    }

    // Package tests inject gateway events without a live socket.
    func _test_handleGatewayEvent(_ event: EventFrame) async {
        await self.handleGatewayEvent(event, lifecycleGeneration: self.lifecycleGeneration)
    }

    // Package tests end the event stream deterministically.
    func _test_handleEventStreamEnded() async {
        await self.handleEventStreamEnded(lifecycleGeneration: self.lifecycleGeneration)
    }

    // Package tests observe startup cancellation without waiting out the timeout.
    func _test_waitForStartupCancelled(timeoutSeconds: Int) async -> Bool {
        if case .cancelled = await self.waitForStartupResult(
            timeoutSeconds: timeoutSeconds,
            lifecycleGeneration: self.lifecycleGeneration)
        {
            return true
        }
        return false
    }

    // Package tests await in-flight tool calls before asserting.
    func _test_waitForToolCalls() async {
        let tasks = self.toolCallTasks.values
        for task in tasks {
            await task.value
        }
    }

    // Package tests capture the exact owned cancellation before replacement or stop.
    func _test_outputCancellationTask() -> Task<Void, Never>? {
        self.outputCancellationTask
    }

    // Package tests start output playback without decoding real audio.
    func _test_markOutputAudioStarted(nowMs: Double) {
        self.markOutputAudioStarted(nowMs: nowMs)
    }

    // Package tests finish playback without a real player callback.
    func _test_markOutputPlaybackFinished() {
        self.markOutputPlaybackFinished()
    }

    // Package tests observe barge-in timing state.
    func _test_outputStartedAtMs() -> Double? {
        self.outputStartedAtMs
    }

    // Package tests observe playback state without exposing it publicly.
    func _test_isOutputPlaying() -> Bool {
        self.isOutputPlaying
    }

    // Package tests exercise the audio sender without a started session.
    func _test_prepareAudioSender(relaySessionId: String) {
        self.isClosed = false
        self.audioSender = RealtimeAudioSender(
            relaySessionId: relaySessionId,
            request: self.transport.request)
    }

    // Package tests enqueue frames without a live capture device.
    func _test_enqueueMicrophoneFrame(
        _ data: Data,
        timestampMs: Double = 1) -> Task<Void, Never>?
    {
        self.enqueueMicrophoneFrame(
            data,
            timestampMs: timestampMs,
            rms: 0.01,
            lifecycleGeneration: self.lifecycleGeneration,
            audioCaptureGeneration: self.audioCaptureGeneration)
    }

    // Package tests start the pump to observe capture failure handling.
    func _test_startMicrophonePump() throws {
        try self.startMicrophonePump(lifecycleGeneration: self.lifecycleGeneration)
    }
}
#endif
#endif
