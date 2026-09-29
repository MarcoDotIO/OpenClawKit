import Foundation
import OpenClawProtocol

/// Background "still alive" beacons for paired nodes (`node.presence.alive`, upstream #63123).
///
/// A beacon marks the node recently alive (`lastSeenAtMs` / `lastSeenReason` in `node.list` and
/// environment summaries) without treating it as connected, so it must not flip local "connected" UI.
/// Hosts send one from app-background transitions (`.background`), silent pushes (`.silentPush`),
/// `BGAppRefreshTask` handlers (`.bgAppRefresh`), significant-location wakes (`.significantLocation`)
/// and right after connecting (`.connect`), skipping it while connected and a beacon succeeded in the
/// last ``minSuccessInterval``.
public enum NodePresenceAliveBeacon {
    /// Node event name.
    public static let eventName = "node.presence.alive"
    /// Minimum interval between successful beacons while connected (10 minutes).
    public static let minSuccessInterval: TimeInterval = 10 * 60

    /// Beacon payload (`NodePresenceAlivePayload` wire shape with an `Int64` timestamp so it is safe on
    /// 32-bit watchOS).
    public struct Payload: Codable, Sendable, Equatable {
        /// Wake trigger.
        public var trigger: NodePresenceAliveReason
        /// Send time in milliseconds since the Unix epoch.
        public var sentAtMs: Int64
        /// Node display name.
        public var displayName: String?
        /// App version.
        public var version: String?
        /// Platform label (same value as `connect.client.platform`).
        public var platform: String?
        /// Device family (same value as `connect.client.deviceFamily`).
        public var deviceFamily: String?
        /// Hardware model identifier.
        public var modelIdentifier: String?
        /// Push transport in use (`direct` or `relay`).
        public var pushTransport: String?

        /// Creates a payload.
        public init(
            trigger: NodePresenceAliveReason,
            sentAtMs: Int64,
            displayName: String? = nil,
            version: String? = nil,
            platform: String? = nil,
            deviceFamily: String? = nil,
            modelIdentifier: String? = nil,
            pushTransport: String? = nil)
        {
            self.trigger = trigger
            self.sentAtMs = sentAtMs
            self.displayName = displayName
            self.version = version
            self.platform = platform
            self.deviceFamily = deviceFamily
            self.modelIdentifier = modelIdentifier
            self.pushTransport = pushTransport
        }
    }

    /// Maps a raw trigger string to a reason; unknown values become `.background`.
    public static func normalizeTrigger(_ raw: String) -> NodePresenceAliveReason {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return NodePresenceAliveReason(rawValue: normalized) ?? .background
    }

    /// Whether to skip a beacon: only while connected and when the last success is younger than
    /// `minInterval`.
    public static func shouldSkipRecentSuccess(
        isGatewayConnected: Bool,
        now: Date,
        lastSuccessAtMs: Int64?,
        minInterval: TimeInterval = Self.minSuccessInterval) -> Bool
    {
        guard isGatewayConnected else { return false }
        guard let lastSuccessAtMs, lastSuccessAtMs > 0 else { return false }
        let elapsed = now.timeIntervalSince1970 - (Double(lastSuccessAtMs) / 1000.0)
        return elapsed >= 0 && elapsed < minInterval
    }

    /// Builds a payload from ``InstanceIdentity`` (the same stable metadata used during connect, so a
    /// beacon never changes the node's device family) and the main bundle's version.
    public static func makePayload(
        trigger: NodePresenceAliveReason,
        displayName: String? = nil,
        pushTransport: String? = nil,
        now: Date = Date()) -> Payload
    {
        Payload(
            trigger: trigger,
            sentAtMs: Int64((now.timeIntervalSince1970 * 1000).rounded()),
            displayName: displayName ?? InstanceIdentity.displayName,
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            platform: InstanceIdentity.platformString,
            deviceFamily: InstanceIdentity.deviceFamily,
            modelIdentifier: InstanceIdentity.modelIdentifier,
            pushTransport: pushTransport)
    }

    /// `node.event` request params JSON: `{"event":"node.presence.alive","payloadJSON":"<payload>"}`.
    public static func nodeEventParamsJSON(for payload: Payload) throws -> String {
        let payloadData = try JSONEncoder().encode(payload)
        let payloadJSON = String(decoding: payloadData, as: UTF8.self)
        let params: [String: String] = ["event": self.eventName, "payloadJSON": payloadJSON]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(params), as: UTF8.self)
    }

    /// Sends a beacon over the authenticated node session and returns the gateway's verdict.
    public static func send(
        _ payload: Payload,
        on session: some GatewayNodeRequestSending,
        timeoutSeconds: Int = 15) async throws -> NodeEventResult
    {
        let data = try await session.sendNodeRequest(
            method: "node.event",
            paramsJSON: self.nodeEventParamsJSON(for: payload),
            timeoutSeconds: timeoutSeconds)
        return try GatewayRPCCoding.decode(NodeEventResult.self, from: data, method: "node.event")
    }
}
