import Foundation
import OpenClawProtocol

/// Minimal gateway request surface that the Talk helpers depend on.
///
/// Keeping Talk on this small seam (instead of a concrete connection type) lets hosts route Talk
/// over any gateway connection and keeps tests transport-free. OpenClawKit conforms
/// ``GatewayNodeSession`` in `TalkGatewayRequesting+GatewayNodeSession.swift`.
public protocol TalkGatewayRequesting: Sendable {
    /// Sends one request and returns the raw JSON response payload.
    /// - Parameters:
    ///   - method: Gateway method name.
    ///   - params: JSON object parameters, or `nil`.
    ///   - timeoutMs: Request timeout in milliseconds.
    func talkRequest(method: String, params: [String: AnyCodable]?, timeoutMs: Double) async throws -> Data

    /// Subscribes to server event frames.
    /// - Parameter bufferingNewest: Number of newest events retained for a slow consumer.
    func talkServerEvents(bufferingNewest: Int) async -> AsyncStream<EventFrame>
}

/// Errors thrown by ``TalkGatewayClient``.
public enum TalkGatewayClientError: Error, Equatable, Sendable {
    /// Request parameters could not be encoded as a JSON object.
    case invalidParams(method: String)
    /// The gateway returned audio that was missing or not base64.
    case emptyAudio(method: String)
}

extension TalkGatewayClientError: LocalizedError {
    /// Human-readable description.
    public var errorDescription: String? {
        switch self {
        case let .invalidParams(method):
            "Failed to encode \(method) request"
        case let .emptyAudio(method):
            "Gateway \(method) returned empty audio"
        }
    }
}

/// Typed client for the protocol v4 Talk and TTS gateway methods.
///
/// Every request first checks `isCurrent`: Talk cleanup (for example `talk.session.close`) must
/// go out on the connection that created the session, never through a replacement connection,
/// so a stale route throws `CancellationError` instead of retargeting.
public struct TalkGatewayClient: Sendable {
    /// Default timeout for control requests, in milliseconds.
    public static let defaultTimeoutMs: Double = 8000
    /// Timeout for `talk.session.create` / `talk.client.create`, in milliseconds.
    public static let createTimeoutMs: Double = 20000
    /// Timeout for `talk.speak` / `tts.speak` synthesis, in milliseconds.
    public static let speechTimeoutMs: Double = 125_000

    /// Underlying gateway connection.
    public let gateway: any TalkGatewayRequesting
    private let isCurrent: @Sendable () async -> Bool

    /// Creates a client.
    /// - Parameters:
    ///   - gateway: Gateway connection.
    ///   - isCurrent: Whether the originating connection is still current; defaults to always.
    public init(_ gateway: any TalkGatewayRequesting, isCurrent: @escaping @Sendable () async -> Bool = { true }) {
        self.gateway = gateway
        self.isCurrent = isCurrent
    }

    // MARK: - Catalog and config

    /// Reads Talk modes, transports, brains, and speech/transcription/realtime provider readiness.
    ///
    /// Use it to populate provider and transport pickers rather than hard-coding lists.
    /// - Parameters:
    ///   - provider: Optional provider filter.
    ///   - model: Optional model filter.
    public func catalog(provider: String? = nil, model: String? = nil) async throws -> TalkCatalogResult {
        try await self.request(
            .catalog,
            params: TalkCatalogParams(provider: provider, model: model),
            as: TalkCatalogResult.self)
    }

    /// Reads Talk configuration (`talk.config`).
    /// - Parameter includeSecrets: Request provider secrets (needs `operator.talk.secrets`).
    public func config(includeSecrets: Bool = false) async throws -> TalkConfigResult {
        try await self.request(
            .config,
            params: TalkConfigParams(includesecrets: includeSecrets ? true : nil),
            as: TalkConfigResult.self)
    }

    /// Reads `talk.config` and projects its `talk` section into a ``TalkConfigSnapshot``.
    /// - Parameters:
    ///   - defaultProvider: Provider used for legacy (non-normalized) payloads.
    ///   - defaultSilenceTimeoutMs: Fallback silence timeout.
    ///   - includeSecrets: Request provider secrets.
    public func configSnapshot(
        defaultProvider: String,
        defaultSilenceTimeoutMs: Int,
        includeSecrets: Bool = false) async throws -> TalkConfigSnapshot
    {
        let result = try await self.config(includeSecrets: includeSecrets)
        return TalkConfigSnapshot(
            result.config["talk"]?.dictionaryValue,
            defaultProvider: defaultProvider,
            defaultSilenceTimeoutMs: defaultSilenceTimeoutMs)
    }

    /// Toggles Talk mode on the gateway (`talk.mode`).
    /// - Parameters:
    ///   - enabled: Whether Talk mode is on.
    ///   - phase: Optional phase marker (`listening`, `thinking`, `speaking`).
    public func setMode(enabled: Bool, phase: String? = nil) async throws {
        _ = try await self.send(.mode, params: TalkModeParams(enabled: enabled, phase: phase))
    }

    // MARK: - Speech

    /// Synthesizes speech with the Talk-mode provider (`talk.speak`).
    /// - Parameter params: Text and provider voice tuning.
    public func speak(_ params: TalkSpeakParams) async throws -> TalkSpeakResult {
        try await self.request(.speak, params: params, as: TalkSpeakResult.self, timeoutMs: Self.speechTimeoutMs)
    }

    /// Synthesizes playable speech for an assistant message through the gateway TTS chain (`tts.speak`).
    /// - Parameter text: Message text.
    public func ttsSpeak(text: String) async throws -> TtsSpeakResult {
        try await self.request(
            .ttsSpeak,
            params: TtsSpeakParams(text: text),
            as: TtsSpeakResult.self,
            timeoutMs: Self.speechTimeoutMs)
    }

    // MARK: - Client-owned sessions (WebRTC / provider WebSocket)

    /// Creates a client-owned realtime session; the app then opens the provider connection itself.
    /// - Parameter params: Session key, provider, model, voice, transport, and capabilities.
    public func createClientSession(_ params: TalkClientCreateParams) async throws -> TalkClientCreateResult {
        try await self.request(
            .clientCreate,
            params: params,
            as: TalkClientCreateResult.self,
            timeoutMs: Self.createTimeoutMs)
    }

    /// Closes a client-owned session (`talk.client.close`).
    public func closeClientSession(sessionKey: String, voiceSessionId: String) async throws {
        _ = try await self.send(
            .clientClose,
            params: TalkClientCloseParams(sessionkey: sessionKey, voicesessionid: voiceSessionId))
    }

    /// Records one client-side transcript line (`talk.client.transcript`).
    public func recordClientTranscript(_ params: TalkClientTranscriptParams) async throws {
        _ = try await self.send(.clientTranscript, params: params)
    }

    /// Forwards a provider tool call to the agent (`talk.client.toolCall`); consult calls
    /// acknowledge on acceptance and complete through the `chat` event of the returned run id.
    public func clientToolCall(_ params: TalkClientToolCallParams) async throws -> TalkClientToolCallResult {
        try await self.request(.clientToolCall, params: params, as: TalkClientToolCallResult.self, timeoutMs: 30000)
    }

    /// Steers the agent from a client-owned session (`talk.client.steer`).
    /// - Returns: The raw agent control result.
    public func clientSteer(_ params: TalkClientSteerParams) async throws -> AnyCodable {
        try await self.request(.clientSteer, params: params, as: AnyCodable.self, timeoutMs: 30000)
    }

    // MARK: - Gateway-owned sessions (relay, transcription, managed room)

    /// Creates a gateway-owned session (`talk.session.create`).
    /// - Parameter params: Mode, transport, brain, provider, and tuning.
    public func createSession(_ params: TalkSessionCreateParams) async throws -> TalkSessionCreateResult {
        try await self.request(
            .sessionCreate,
            params: params,
            as: TalkSessionCreateResult.self,
            timeoutMs: Self.createTimeoutMs)
    }

    /// Creates a transcription-only relay (mode `transcription`, transport `gateway-relay`, brain `none`).
    /// - Parameters:
    ///   - sessionKey: Chat session key.
    ///   - provider: Optional transcription provider.
    ///   - language: Optional BCP-47 language.
    public func createTranscriptionSession(
        sessionKey: String?,
        provider: String? = nil,
        language: String? = nil) async throws -> TalkSessionCreateResult
    {
        try await self.createSession(TalkSessionCreateParams(
            sessionkey: sessionKey,
            provider: provider,
            language: language,
            mode: AnyCodable(TalkMode.transcription.rawValue),
            transport: AnyCodable(TalkTransport.gatewayRelay.rawValue),
            brain: AnyCodable(TalkBrain.none.rawValue)))
    }

    /// Appends PCM16 input audio to a relay (`talk.session.appendAudio`).
    /// - Parameters:
    ///   - sessionId: Relay session id.
    ///   - audio: Little-endian PCM16 mono samples at the relay input rate.
    ///   - timestampMs: Capture timestamp; rounded to whole milliseconds as providers require.
    public func appendAudio(sessionId: String, audio: Data, timestampMs: Double? = nil) async throws {
        _ = try await self.send(
            .sessionAppendAudio,
            params: TalkSessionAppendAudioParams(
                sessionid: sessionId,
                audiobase64: audio.base64EncodedString(),
                timestamp: timestampMs?.rounded()))
    }

    /// Cancels relay output for a turn (`talk.session.cancelOutput`).
    public func cancelOutput(
        sessionId: String,
        turnId: String? = nil,
        reason: String? = nil) async throws -> TalkSessionCancelOutputResult
    {
        try await self.request(
            .sessionCancelOutput,
            params: TalkSessionCancelOutputParams(sessionid: sessionId, turnid: turnId, reason: reason),
            as: TalkSessionCancelOutputResult.self)
    }

    /// Steers the agent from a relay session (`talk.session.steer`).
    /// - Returns: The raw agent control result.
    public func steerSession(_ params: TalkSessionSteerParams) async throws -> AnyCodable {
        try await self.request(.sessionSteer, params: params, as: AnyCodable.self, timeoutMs: 30000)
    }

    /// Closes a gateway-owned session (`talk.session.close`).
    public func closeSession(sessionId: String) async throws {
        let result = try await self.request(
            .sessionClose,
            params: TalkSessionCloseParams(sessionid: sessionId),
            as: TalkSessionOkResult.self)
        guard result.ok else { throw URLError(.badServerResponse) }
    }

    // MARK: - Voice selection

    /// Reads the realtime voice selection (`talk.voice.get`).
    public func voice(sessionKey: String? = nil, voiceSessionId: String? = nil) async throws -> TalkVoiceSelection {
        try await self.request(
            .voiceGet,
            params: TalkVoiceGetParams(sessionkey: sessionKey, voicesessionid: voiceSessionId),
            as: TalkVoiceSelection.self)
    }

    /// Requests a realtime voice change (`talk.voice.set`); the gateway answers with `talk.voice.change`.
    public func setVoice(
        _ voice: String,
        sessionKey: String? = nil,
        voiceSessionId: String? = nil) async throws -> TalkVoiceSetResult
    {
        try await self.request(
            .voiceSet,
            params: TalkVoiceSetParams(sessionkey: sessionKey, voicesessionid: voiceSessionId, voice: voice),
            as: TalkVoiceSetResult.self)
    }

    /// Completes a negotiated voice change (`talk.voice.complete`).
    public func completeVoiceChange(_ params: TalkVoiceCompleteParams) async throws {
        _ = try await self.send(.voiceComplete, params: params)
    }

    // MARK: - Plumbing

    /// Sends a typed request and decodes the typed response.
    /// - Parameters:
    ///   - method: Talk method.
    ///   - params: Encodable parameters (encoded as a JSON object).
    ///   - type: Response type.
    ///   - timeoutMs: Request timeout.
    public func request<Params: Encodable, Response: Decodable>(
        _ method: TalkGatewayMethod,
        params: Params,
        as type: Response.Type,
        timeoutMs: Double = TalkGatewayClient.defaultTimeoutMs) async throws -> Response
    {
        let data = try await self.send(method, params: params, timeoutMs: timeoutMs)
        return try JSONDecoder().decode(type, from: data)
    }

    @discardableResult
    private func send(
        _ method: TalkGatewayMethod,
        params: some Encodable,
        timeoutMs: Double = TalkGatewayClient.defaultTimeoutMs) async throws -> Data
    {
        guard let object = try AnyCodable(encoding: params).dictionaryValue else {
            throw TalkGatewayClientError.invalidParams(method: method.rawValue)
        }
        guard await self.isCurrent() else { throw CancellationError() }
        let data = try await self.gateway.talkRequest(method: method.rawValue, params: object, timeoutMs: timeoutMs)
        guard await self.isCurrent() else { throw CancellationError() }
        return data
    }
}
