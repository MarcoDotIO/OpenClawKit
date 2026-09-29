import Foundation
import OpenClawProtocol
import Testing
@testable import OpenClawKit

/// In-memory ``TalkGatewayRequesting`` that records requests and answers from a script.
actor RecordingTalkGateway: TalkGatewayRequesting {
    struct Request: Sendable {
        let method: String
        let params: [String: AnyCodable]?
        let timeoutMs: Double
    }

    private var requests: [Request] = []
    private var responses: [String: Data] = [:]
    private var failures: [String: any Error] = [:]
    private let events = AsyncStream<EventFrame>.makeStream()

    init(responses: [String: String] = [:]) {
        self.responses = responses.mapValues { Data($0.utf8) }
    }

    func respond(to method: String, with json: String) {
        self.responses[method] = Data(json.utf8)
    }

    func fail(_ method: String, with error: any Error) {
        self.failures[method] = error
    }

    func talkRequest(method: String, params: [String: AnyCodable]?, timeoutMs: Double) async throws -> Data {
        self.requests.append(Request(method: method, params: params, timeoutMs: timeoutMs))
        if let failure = self.failures[method] { throw failure }
        return self.responses[method] ?? Data(#"{"ok":true}"#.utf8)
    }

    nonisolated func talkServerEvents(bufferingNewest: Int) async -> AsyncStream<EventFrame> {
        self.events.stream
    }

    func methods() -> [String] {
        self.requests.map(\.method)
    }

    func last() -> Request? {
        self.requests.last
    }

    func all() -> [Request] {
        self.requests
    }
}

private actor TalkRouteFlag {
    private var current = true

    func expire() {
        self.current = false
    }

    func value() -> Bool {
        self.current
    }
}

@Suite("Talk gateway client")
struct TalkGatewayClientTests {
    @Test("catalog and config decode typed results and project the talk snapshot")
    func catalogAndConfig() async throws {
        let gateway = RecordingTalkGateway(responses: [
            "talk.catalog": """
            {"modes":["realtime","stt-tts"],"transports":["gateway-relay"],"brains":["agent-consult"],
             "speech":{},"transcription":{},"realtime":{"activeProvider":"openai"}}
            """,
            "talk.config": """
            {"config":{"talk":{"resolved":{"provider":"elevenlabs","config":{"voiceId":"v-1"}},
             "realtime":{"provider":"openai","transport":"gateway-relay"}}}}
            """,
        ])
        let client = TalkGatewayClient(gateway)

        let catalog = try await client.catalog(provider: "openai")
        #expect(catalog.modes.compactMap(\.stringValue) == ["realtime", "stt-tts"])
        #expect(catalog.realtime["activeProvider"]?.stringValue == "openai")
        #expect(await gateway.last()?.params?["provider"]?.stringValue == "openai")
        #expect(await gateway.last()?.params?["model"] == nil)

        let snapshot = try await client.configSnapshot(
            defaultProvider: "system",
            defaultSilenceTimeoutMs: 700,
            includeSecrets: true)
        #expect(snapshot.activeProvider == "elevenlabs")
        #expect(snapshot.providerConfig?["voiceId"]?.stringValue == "v-1")
        #expect(snapshot.realtime.talkTransport == .gatewayRelay)
        #expect(await gateway.last()?.method == "talk.config")
        #expect(await gateway.last()?.params?["includeSecrets"]?.boolValue == true)

        _ = try await client.config()
        #expect(await gateway.last()?.params?.isEmpty == true)
    }

    @Test("speech wrappers send typed params with the synthesis timeout")
    func speechWrappers() async throws {
        let gateway = RecordingTalkGateway(responses: [
            "talk.speak": #"{"audioBase64":"AQID","provider":"elevenlabs","outputFormat":"pcm_24000"}"#,
            "tts.speak": #"{"audioBase64":"BAUG","provider":"openai","outputFormat":"mp3_44100_128","mimeType":"audio/mpeg"}"#,
        ])
        let client = TalkGatewayClient(gateway)

        let talkAudio = try await client.synthesizeTalkSpeech(TalkGatewaySpeechRequest(
            text: "Hello",
            voiceId: "voice-1",
            directive: TalkDirective(voiceId: "override", speed: 1.1, rateWPM: 180, language: "en")))
        #expect(talkAudio.data == Data([1, 2, 3]))
        #expect(talkAudio.provider == "elevenlabs")
        #expect(talkAudio.playbackMode == .pcm(sampleRate: 24000))
        let speak = try #require(await gateway.last())
        #expect(speak.method == "talk.speak")
        #expect(speak.timeoutMs == TalkGatewayClient.speechTimeoutMs)
        #expect(speak.params?["text"]?.stringValue == "Hello")
        #expect(speak.params?["voiceId"]?.stringValue == "override")
        #expect(speak.params?["rateWpm"]?.intValue == 180)
        #expect(speak.params?["speed"]?.doubleValue == 1.1)
        #expect(speak.params?["language"]?.stringValue == "en")
        #expect(speak.params?["stability"] == nil)

        let messageAudio = try await client.synthesizeMessageSpeech(text: "Read this")
        #expect(messageAudio.data == Data([4, 5, 6]))
        #expect(messageAudio.playbackMode == .buffered)
        #expect(await gateway.last()?.method == "tts.speak")
        #expect(await gateway.last()?.params?["text"]?.stringValue == "Read this")
    }

    @Test("empty synthesized audio throws")
    func emptyAudioThrows() async {
        let gateway = RecordingTalkGateway(responses: [
            "talk.speak": #"{"audioBase64":"","provider":"elevenlabs"}"#,
        ])
        await #expect(throws: TalkGatewayClientError.emptyAudio(method: "talk.speak")) {
            _ = try await TalkGatewayClient(gateway).synthesizeTalkSpeech(TalkGatewaySpeechRequest(text: "Hi"))
        }
    }

    @Test("session wrappers use the v4 method names and wire keys")
    func sessionWrappers() async throws {
        let gateway = RecordingTalkGateway(responses: [
            "talk.session.create": """
            {"sessionId":"s-1","mode":"transcription","transport":"gateway-relay","brain":"none","relaySessionId":"r-1"}
            """,
            "talk.session.cancelOutput": #"{"ok":true,"status":"applied","turnId":"t-1"}"#,
            "talk.client.create": """
            {"provider":"openai","transport":"webrtc","voiceSessionId":"v-1","clientSecret":"ephemeral"}
            """,
        ])
        let client = TalkGatewayClient(gateway)

        let created = try await client.createTranscriptionSession(sessionKey: "main", language: "en")
        #expect(created.relaysessionid == "r-1")
        let create = try #require(await gateway.last())
        #expect(create.method == "talk.session.create")
        #expect(create.timeoutMs == TalkGatewayClient.createTimeoutMs)
        #expect(create.params?["mode"]?.stringValue == "transcription")
        #expect(create.params?["transport"]?.stringValue == "gateway-relay")
        #expect(create.params?["brain"]?.stringValue == "none")
        #expect(create.params?["sessionKey"]?.stringValue == "main")

        try await client.appendAudio(sessionId: "r-1", audio: Data([1, 2]), timestampMs: 12.6)
        let append = try #require(await gateway.last())
        #expect(append.method == "talk.session.appendAudio")
        #expect(append.params?["audioBase64"]?.stringValue == Data([1, 2]).base64EncodedString())
        #expect(append.params?["timestamp"]?.doubleValue == 13)

        let cancelled = try await client.cancelOutput(sessionId: "r-1", turnId: "t-1", reason: "user")
        #expect(cancelled.status?.stringValue == "applied")
        try await client.closeSession(sessionId: "r-1")
        #expect(await gateway.last()?.params?["sessionId"]?.stringValue == "r-1")

        let clientSession = try await client.createClientSession(TalkClientCreateParams(
            sessionkey: "main",
            provider: "openai",
            transport: AnyCodable(TalkTransport.webrtc.rawValue)))
        guard case let .webrtc(webrtc) = clientSession else {
            Issue.record("Expected a WebRTC client session")
            return
        }
        #expect(webrtc.voicesessionid == "v-1")
        try await client.closeClientSession(sessionKey: "main", voiceSessionId: "v-1")
        try await client.completeVoiceChange(TalkVoiceCompleteParams(changeid: "c-1", outcome: AnyCodable("ready")))
        try await client.setMode(enabled: true, phase: "listening")

        #expect(await gateway.methods() == [
            "talk.session.create",
            "talk.session.appendAudio",
            "talk.session.cancelOutput",
            "talk.session.close",
            "talk.client.create",
            "talk.client.close",
            "talk.voice.complete",
            "talk.mode",
        ])
    }

    @Test("a closed session with ok false throws")
    func closeRejectsNotOK() async {
        let gateway = RecordingTalkGateway(responses: ["talk.session.close": #"{"ok":false}"#])
        await #expect(throws: URLError.self) {
            try await TalkGatewayClient(gateway).closeSession(sessionId: "r-1")
        }
    }

    @Test("requests on a replaced connection throw cancellation instead of retargeting")
    func staleConnectionRequestsThrowCancellation() async throws {
        let gateway = RecordingTalkGateway()
        let route = TalkRouteFlag()
        let client = TalkGatewayClient(gateway, isCurrent: { await route.value() })

        try await client.closeSession(sessionId: "r-1")
        await route.expire()
        await #expect(throws: CancellationError.self) {
            try await client.closeSession(sessionId: "r-2")
        }
        #expect(await gateway.methods() == ["talk.session.close"])
    }

    @Test("talk vocabulary matches the upstream schema")
    func talkVocabularyMatchesSchema() {
        #expect(TalkMode.allCases.map(\.rawValue) == ["realtime", "stt-tts", "transcription"])
        #expect(TalkTransport.allCases.map(\.rawValue) == ["webrtc", "provider-websocket", "gateway-relay", "managed-room"])
        #expect(TalkTransport.allCases.filter(\.isClientOwned) == [.webrtc, .providerWebsocket])
        #expect(TalkBrain.allCases.map(\.rawValue) == ["agent-consult", "direct-tools", "none"])
        #expect(TalkAgentControlMode.allCases.map(\.rawValue) == ["status", "steer", "cancel", "followup"])
        #expect(TalkEventType.allCases.count == 28)
        #expect(TalkEventType.allCases.filter(\.isTurnScoped).count == 16)
        #expect(TalkEventType.allCases.filter(\.isCaptureScoped).count == 4)
        #expect(TalkEventType(rawValue: "output.audio.delta") == .outputAudioDelta)
        #expect(TalkGatewayEventName.voiceChange.rawValue == "talk.voice.change")
    }

    @Test("every talk method name exists in the pinned gateway method catalog")
    func talkMethodsExistInCatalog() {
        for method in TalkGatewayMethod.allCases {
            #expect(GatewayMethodCatalog.byName[method.rawValue] != nil, "\(method.rawValue)")
        }
        #expect(GatewayMethodCatalog.byName["talk.realtime.session"] == nil)
    }

    @Test("PCM sample rates parse from provider output formats")
    func pcmSampleRatesParse() {
        #expect(TalkSpeechOutputFormat.pcmSampleRate(from: "pcm_24000") == 24000)
        #expect(TalkSpeechOutputFormat.pcmSampleRate(from: " PCM-16000 ") == 16000)
        #expect(TalkSpeechOutputFormat.pcmSampleRate(from: "pcm") == nil)
        #expect(TalkSpeechOutputFormat.pcmSampleRate(from: "mp3_44100_128") == nil)
        #expect(TalkSpeechOutputFormat.pcmSampleRate(from: nil) == nil)
        #expect(TalkGatewaySpeechAudio(data: Data([1]), provider: "x", outputFormat: "ulaw_8000").playbackMode
            == .unsupportedRaw(codec: "ulaw_8000"))
        #expect(TalkGatewaySpeechAudio(data: Data([1]), provider: "x", outputFormat: nil).playbackMode == .buffered)
    }
}
