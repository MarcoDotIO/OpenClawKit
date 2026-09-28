import Foundation

/// Normalized projection of a gateway `talk` config payload (`talk.config` → `config.talk`).
public struct TalkConfigSnapshot: Sendable {
    /// Selected speech provider (the resolved provider, or `defaultProvider` for legacy payloads).
    public let activeProvider: String
    /// Provider-specific config for ``activeProvider``, when a selection was made.
    public let providerConfig: [String: AnyCodable]?
    /// Whether the selection came from the gateway's normalized `resolved` block.
    public let normalizedPayload: Bool
    /// `true` when a talk payload was present but no provider could be selected
    /// (normalized payload without `talk.resolved`); hosts should log and ignore it.
    public let missingResolvedPayload: Bool
    /// Voice aliases (`voiceAliases`) with lower-cased keys and trimmed values.
    public let voiceAliases: [String: String]
    /// Whether user speech interrupts assistant playback, when configured.
    public let interruptOnSpeech: Bool?
    /// Silence timeout in milliseconds.
    public let silenceTimeoutMs: Int
    /// Normalized speech recognition locale (`speechLocale`).
    public let speechLocaleID: String?
    /// Realtime (`talk.realtime`) projection.
    public let realtime: TalkRealtimeConfigSnapshot

    /// Projects a talk payload.
    /// - Parameters:
    ///   - talk: The `talk` object from `talk.config`, or `nil`.
    ///   - defaultProvider: Provider for legacy flat payloads.
    ///   - defaultSilenceTimeoutMs: Fallback silence timeout.
    ///   - allowLegacyFallback: Whether legacy flat payloads map onto `defaultProvider`.
    public init(
        _ talk: [String: AnyCodable]?,
        defaultProvider: String,
        defaultSilenceTimeoutMs: Int,
        allowLegacyFallback: Bool = true)
    {
        let selection = TalkConfigParsing.selectProviderConfig(
            talk, defaultProvider: defaultProvider, allowLegacyFallback: allowLegacyFallback)
        self.activeProvider = selection?.provider ?? defaultProvider
        self.providerConfig = selection?.config
        self.normalizedPayload = selection?.normalizedPayload == true
        self.missingResolvedPayload = talk != nil && selection == nil
        self.voiceAliases = TalkVoiceAliases.normalizedMap(selection?.config["voiceAliases"])
        self.interruptOnSpeech = talk?["interruptOnSpeech"]?.boolValue
        self.silenceTimeoutMs = TalkConfigParsing.resolvedSilenceTimeoutMs(talk, fallback: defaultSilenceTimeoutMs)
        self.speechLocaleID = TalkConfigParsing.resolvedSpeechLocaleID(talk)
        self.realtime = TalkRealtimeConfigSnapshot(talk?["realtime"]?.dictionaryValue)
    }
}

/// Normalized projection of `talk.realtime`.
public struct TalkRealtimeConfigSnapshot: Sendable {
    /// Realtime provider: `realtime.provider`, else the only key in `realtime.providers`.
    public let provider: String?
    /// Provider config: exact key, then case-insensitive match, then the only entry.
    public let providerConfig: [String: AnyCodable]?
    /// Model: `realtime.model`, else the provider config's `model`.
    public let modelId: String?
    /// Voice: `realtime.voice`, else the provider config's `voice`.
    public let voice: String?
    /// Speaker voice: `speakerVoice` then `voice`, top level first, then the provider config.
    public let speakerVoice: String?
    /// Lower-cased mode (`realtime`, `stt-tts`, `transcription`).
    public let mode: String?
    /// Lower-cased transport (`webrtc`, `provider-websocket`, `gateway-relay`, `managed-room`).
    public let transport: String?
    /// Lower-cased brain (`agent-consult`, `direct-tools`, `none`).
    public let brain: String?
    /// Lower-cased consult routing (`provider-direct`, `force-agent-consult`).
    public let consultRouting: String?
    /// Extra instructions appended to the built-in consult guidance (`talk.realtime.instructions`).
    public let instructions: String?

    init(_ realtime: [String: AnyCodable]?) {
        let providers = realtime?["providers"]?.dictionaryValue
        let provider = TalkConfigParsing.firstNonEmptyString(realtime, keys: ["provider"])
            ?? TalkConfigParsing.singleRealtimeProviderID(providers)
        let providerConfig = TalkConfigParsing.realtimeProviderConfig(providers: providers, provider: provider)
        self.provider = provider
        self.providerConfig = providerConfig
        self.modelId = TalkConfigParsing.firstNonEmptyString(realtime, keys: ["model"])
            ?? TalkConfigParsing.firstNonEmptyString(providerConfig, keys: ["model"])
        self.voice = TalkConfigParsing.firstNonEmptyString(realtime, keys: ["voice"])
            ?? TalkConfigParsing.firstNonEmptyString(providerConfig, keys: ["voice"])
        // macOS accepts speakerVoice; iOS consumes only voice. Keep both projections.
        self.speakerVoice = TalkConfigParsing.firstNonEmptyString(realtime, keys: ["speakerVoice", "voice"])
            ?? TalkConfigParsing.firstNonEmptyString(providerConfig, keys: ["speakerVoice", "voice"])
        self.mode = TalkConfigParsing.firstNonEmptyString(realtime, keys: ["mode"])?.lowercased()
        self.transport = TalkConfigParsing.firstNonEmptyString(realtime, keys: ["transport"])?.lowercased()
        self.brain = TalkConfigParsing.firstNonEmptyString(realtime, keys: ["brain"])?.lowercased()
        self.consultRouting = TalkConfigParsing.firstNonEmptyString(realtime, keys: ["consultRouting"])?.lowercased()
        self.instructions = TalkConfigParsing.firstNonEmptyString(realtime, keys: ["instructions"])
    }

    /// Typed ``mode``; `nil` when unset or unknown.
    public var talkMode: TalkMode? {
        self.mode.flatMap(TalkMode.init(rawValue:))
    }

    /// Typed ``transport``; `nil` when unset or unknown.
    public var talkTransport: TalkTransport? {
        self.transport.flatMap(TalkTransport.init(rawValue:))
    }

    /// Typed ``brain``; `nil` when unset or unknown.
    public var talkBrain: TalkBrain? {
        self.brain.flatMap(TalkBrain.init(rawValue:))
    }

    /// Whether the config selects the gateway-relay realtime tuple (`realtime` / `gateway-relay` / `agent-consult`).
    public var usesGatewayRealtimeRelay: Bool {
        self.talkMode == .realtime && self.talkTransport == .gatewayRelay && self.talkBrain == .agentConsult
    }

    /// Model for a client-owned session: ``modelId``, else ``TalkRealtimeDefaults/openAIModel`` for OpenAI.
    ///
    /// Gateway-relay sessions should pass ``modelId`` unchanged so the gateway default applies.
    public var clientSessionModelId: String? {
        if let modelId { return modelId }
        return self.provider?.lowercased() == "openai" ? TalkRealtimeDefaults.openAIModel : nil
    }
}
