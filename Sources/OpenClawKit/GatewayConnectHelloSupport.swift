import Foundation
import OpenClawProtocol

/// Server capabilities native clients gate features on (hello-ok `features.capabilities`).
///
/// The full generated vocabulary lives in ``GatewayServerCapabilityName``; this enum lists the
/// capabilities the Swift clients consult.
public enum GatewayServerCapability: String, CaseIterable, Sendable {
    /// `chat.send` accepts explicit routing.
    case chatSendRoutingContract = "chat-send-routing-contract"
    /// Chat metadata is scoped per session.
    case sessionScopedChatMetadata = "session-scoped-chat-metadata"
    /// The gateway publishes its model catalog.
    case publishedModelCatalog = "published-model-catalog"
    /// Session unread acknowledgements are supported.
    case sessionUnreadAckContract = "session-unread-ack-contract"
    /// Session settings RPCs are supported.
    case sessionSettingsContract = "session-settings-contract"
    /// Session settings support compare-and-swap writes.
    case sessionSettingsCAS = "session-settings-cas-v1"
    /// Progress cards carry agent scope.
    case progressCardAgentScope = "progress-card-agent-scope-v1"
    /// The system agent setup flow accepts a model ref.
    case systemAgentSetupModelRef = "openclaw-setup-model-ref"
    /// Requests may bind `expectedProfileId` and events carry `recipientProfileId`.
    case profileBinding = "profile-binding-v1"
}

extension HelloOk {
    /// Methods advertised in `features.methods`.
    ///
    /// `nil` when the hello carries no method catalog: gates must treat that as unknown, not
    /// "advertises nothing", so pre-catalog gateways keep working.
    public func advertisedServerMethods() -> Set<String>? {
        guard let values = self.features["methods"]?.arrayValue else { return nil }
        return Set(values.compactMap(\.stringValue))
    }

    /// Whether `features.capabilities` lists `capability`.
    public func supportsServerCapability(_ capability: GatewayServerCapability) -> Bool {
        let values = self.features["capabilities"]?.arrayValue ?? []
        return values.contains { $0.stringValue == capability.rawValue }
    }

    /// Raw capability strings from `features.capabilities`, including ones this SDK does not model.
    public func advertisedServerCapabilityNames() -> [String] {
        self.features["capabilities"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    /// Scopes granted to this socket (`auth.scopes`).
    ///
    /// The hello grant is authoritative for this socket. Persisted device-token scopes may be
    /// broader after reconnect or narrower after a downgrade.
    public func advertisedOperatorScopes() -> Set<String>? {
        guard let values = self.auth["scopes"]?.arrayValue else { return nil }
        return Set(values.compactMap(\.stringValue))
    }

    /// Transport policy advertised in `policy`, with upstream defaults for missing values.
    public var gatewayPolicy: GatewayHelloPolicy {
        GatewayHelloPolicy(policy: self.policy)
    }
}

/// Transport policy a gateway advertises in hello-ok `policy`.
public struct GatewayHelloPolicy: Sendable, Equatable {
    /// Default tick interval before hello (and when a gateway omits it).
    public static let defaultTickIntervalMs: Double = 30000
    /// Default frame ceiling (25 MiB) when a gateway omits `maxPayload`.
    public static let defaultMaxPayloadBytes = 25 * 1024 * 1024
    /// Upstream default decoded attachment ceiling (20 MiB) for gateways that do not advertise one.
    public static let defaultAttachmentMaxBytes = 20 * 1024 * 1024
    /// Upstream image ceiling (6 MiB); images are limited to the smaller of this and the attachment ceiling.
    public static let defaultAttachmentMaxImageBytes = 6 * 1024 * 1024

    /// Server tick cadence in milliseconds; the client treats 2x this as a missed tick.
    public let tickIntervalMs: Double
    /// Largest frame the gateway accepts, in bytes.
    public let maxPayloadBytes: Int
    /// Largest buffered outbound backlog the gateway tolerates, in bytes, when advertised.
    public let maxBufferedBytes: Int?
    /// Decoded per-attachment ceiling (`policy.attachments.maxBytes`), when advertised.
    public let attachmentMaxBytes: Int?
    /// Decoded per-image ceiling (`policy.attachments.maxImageBytes`), when advertised.
    public let attachmentMaxImageBytes: Int?

    /// Creates a policy value.
    public init(
        tickIntervalMs: Double = GatewayHelloPolicy.defaultTickIntervalMs,
        maxPayloadBytes: Int = GatewayHelloPolicy.defaultMaxPayloadBytes,
        maxBufferedBytes: Int? = nil,
        attachmentMaxBytes: Int? = nil,
        attachmentMaxImageBytes: Int? = nil)
    {
        self.tickIntervalMs = tickIntervalMs
        self.maxPayloadBytes = maxPayloadBytes
        self.maxBufferedBytes = maxBufferedBytes
        self.attachmentMaxBytes = attachmentMaxBytes
        self.attachmentMaxImageBytes = attachmentMaxImageBytes
    }

    /// Tick intervals a gateway may advertise; values outside are clamped so a hostile or buggy
    /// hello-ok cannot disable (or trap) the tick watchdog.
    public static let advertisedTickIntervalRangeMs: ClosedRange<Double> = 1000...600_000

    /// Reads a hello-ok `policy` object, ignoring non-positive values and clamping `tickIntervalMs`
    /// to ``advertisedTickIntervalRangeMs``.
    public init(policy: [String: AnyCodable]) {
        func positive(_ value: AnyCodable?) -> Int? {
            value?.intValue.flatMap { $0 > 0 ? $0 : nil }
        }
        let range = Self.advertisedTickIntervalRangeMs
        let tick = policy["tickIntervalMs"]?.doubleValue
            .flatMap { $0.isFinite && $0 > 0 ? min(max($0, range.lowerBound), range.upperBound) : nil }
        let attachments = policy["attachments"]?.dictionaryValue
        self.init(
            tickIntervalMs: tick ?? Self.defaultTickIntervalMs,
            maxPayloadBytes: positive(policy["maxPayload"]) ?? Self.defaultMaxPayloadBytes,
            maxBufferedBytes: positive(policy["maxBufferedBytes"]),
            attachmentMaxBytes: positive(attachments?["maxBytes"]),
            attachmentMaxImageBytes: positive(attachments?["maxImageBytes"]))
    }

    /// Attachment ceiling to validate against: the advertised value or the upstream default.
    public var effectiveAttachmentMaxBytes: Int {
        self.attachmentMaxBytes ?? Self.defaultAttachmentMaxBytes
    }

    /// Image ceiling to validate against: the advertised value, else min(attachment ceiling, 6 MiB).
    public var effectiveAttachmentMaxImageBytes: Int {
        self.attachmentMaxImageBytes ?? min(self.effectiveAttachmentMaxBytes, Self.defaultAttachmentMaxImageBytes)
    }
}

/// Defensive hello-ok decoding.
///
/// The generated models are strict: an unknown union discriminator, an extra key in a strict
/// decoder, or (on 32-bit watchOS) a millisecond timestamp in an `Int` field fails a typed
/// decode. A newer gateway must never fail the connect for that, so the fallback decodes the
/// payload as JSON and rebuilds `HelloOk` field by field, dropping only the parts it cannot read.
enum GatewayHelloDecoding {
    static func decode(_ payload: AnyCodable) throws -> HelloOk {
        if let typed = try? GatewayPayloadCodec.decode(HelloOk.self, from: payload) {
            return typed
        }
        guard let object = payload.dictionaryValue else {
            throw GatewayDecodingError(method: "connect", message: "hello-ok payload is not an object")
        }
        guard let protocolVersion = object["protocol"]?.intValue else {
            throw GatewayDecodingError(method: "connect", message: "hello-ok payload is missing protocol")
        }
        return HelloOk(
            type: object["type"]?.stringValue ?? "hello-ok",
            _protocol: protocolVersion,
            server: object["server"]?.dictionaryValue ?? [:],
            features: object["features"]?.dictionaryValue ?? [:],
            snapshot: self.decodeSnapshot(object["snapshot"]),
            controluiurl: object["controlUiUrl"]?.stringValue,
            controluitabs: self.lossyArray(ControlUiPluginTab.self, object["controlUiTabs"]),
            controluiwidgetkinds: self.lossyArray(ControlUiPluginWidgetKind.self, object["controlUiWidgetKinds"]),
            controluilinkreaders: self.lossyArray(ControlUiLinkReaderDescriptor.self, object["controlUiLinkReaders"]),
            pluginsurfaceurls: object["pluginSurfaceUrls"]?.dictionaryValue,
            auth: object["auth"]?.dictionaryValue ?? [:],
            policy: object["policy"]?.dictionaryValue ?? [:])
    }

    static func decodeSnapshot(_ raw: AnyCodable?) -> Snapshot {
        if let raw, let typed = try? GatewayPayloadCodec.decode(Snapshot.self, from: raw) {
            return typed
        }
        let object = raw?.dictionaryValue ?? [:]
        let stateVersion = object["stateVersion"].flatMap { try? GatewayPayloadCodec.decode(StateVersion.self, from: $0) }
        return Snapshot(
            suspension: self.lossyValue(GatewaySuspension.self, object["suspension"]),
            presence: self.lossyArray(PresenceEntry.self, object["presence"]) ?? [],
            health: object["health"]?.dictionaryValue ?? [:],
            stateversion: stateVersion ?? StateVersion(presence: 0, health: 0),
            uptimems: object["uptimeMs"]?.intValue ?? 0,
            appliedconfighash: object["appliedConfigHash"],
            configpath: object["configPath"]?.stringValue,
            statedir: object["stateDir"]?.stringValue,
            sessiondefaults: object["sessionDefaults"]?.dictionaryValue,
            controluiidentityurl: object["controlUiIdentityUrl"]?.stringValue,
            authmode: object["authMode"],
            updateavailable: self.lossyValue(UpdateAvailable.self, object["updateAvailable"]),
            updateschedule: self.lossyValue(UpdateScheduleState.self, object["updateSchedule"]))
    }

    private static func lossyValue<T: Decodable>(_ type: T.Type, _ raw: AnyCodable?) -> T? {
        guard let raw, !raw.isNull else { return nil }
        return try? GatewayPayloadCodec.decode(type, from: raw)
    }

    private static func lossyArray<T: Decodable>(_ type: T.Type, _ raw: AnyCodable?) -> [T]? {
        guard let values = raw?.arrayValue else { return nil }
        return values.compactMap { try? GatewayPayloadCodec.decode(type, from: $0) }
    }
}
