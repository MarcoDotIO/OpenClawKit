import Foundation
import OpenClawProtocol

/// Helpers for constructing device-auth payloads used in gateway connect flows.
public enum GatewayDeviceAuthPayload {
    /// Client identity fields signed into the device proof.
    public struct Client: Sendable {
        /// Client id from the gateway registry.
        public let id: String
        /// Client mode.
        public let mode: String

        /// Creates signed client fields.
        public init(id: String, mode: String) {
            self.id = id
            self.mode = mode
        }
    }

    /// Fields every device-proof payload version signs.
    public struct Fields: Sendable {
        /// Device id (hex SHA-256 of the public key).
        public let deviceId: String
        /// Client identity.
        public let client: Client
        /// Connect role.
        public let role: String
        /// Connect scopes, in wire order.
        public let scopes: [String]
        /// Signing time in milliseconds; the connect path uses the server challenge `ts`.
        public let signedAtMs: Int64
        /// Credential the proof binds (shared, device, or bootstrap token), if any.
        public let token: String?
        /// Challenge nonce.
        public let nonce: String

        /// Creates signed fields.
        public init(
            deviceId: String,
            client: Client,
            role: String,
            scopes: [String],
            signedAtMs: Int64,
            token: String?,
            nonce: String)
        {
            self.deviceId = deviceId
            self.client = client
            self.role = role
            self.scopes = scopes
            self.signedAtMs = signedAtMs
            self.token = token
            self.nonce = nonce
        }
    }

    /// Builds the v2 payload every managed gateway verifies:
    /// `v2|deviceId|clientId|clientMode|role|scopes|signedAtMs|token|nonce`.
    ///
    /// Managed gateways deployed before v3 metadata payload support still verify only v2, so the
    /// connect signer uses this payload by default.
    public static func buildConnectCompatibilityPayload(fields: Fields) -> String {
        let scopeString = fields.scopes.joined(separator: ",")
        let authToken = fields.token ?? ""
        return [
            "v2",
            fields.deviceId,
            fields.client.id,
            fields.client.mode,
            fields.role,
            scopeString,
            String(fields.signedAtMs),
            authToken,
            fields.nonce,
        ].joined(separator: "|")
    }

    /// Builds the canonical v3 payload, which also signs normalized platform and device family.
    public static func buildV3(
        fields: Fields,
        platform: String?,
        deviceFamily: String?) -> String
    {
        let scopeString = fields.scopes.joined(separator: ",")
        let authToken = fields.token ?? ""
        let normalizedPlatform = self.normalizeMetadataField(platform)
        let normalizedDeviceFamily = self.normalizeMetadataField(deviceFamily)
        return [
            "v3",
            fields.deviceId,
            fields.client.id,
            fields.client.mode,
            fields.role,
            scopeString,
            String(fields.signedAtMs),
            authToken,
            fields.nonce,
            normalizedPlatform,
            normalizedDeviceFamily,
        ].joined(separator: "|")
    }

    /// Builds the canonical v3 device-auth payload string for signing (flat-argument form).
    public static func buildV3(
        deviceId: String,
        clientId: String,
        clientMode: String,
        role: String,
        scopes: [String],
        signedAtMs: Int64,
        token: String?,
        nonce: String,
        platform: String?,
        deviceFamily: String?) -> String
    {
        self.buildV3(
            fields: Fields(
                deviceId: deviceId,
                client: Client(id: clientId, mode: clientMode),
                role: role,
                scopes: scopes,
                signedAtMs: signedAtMs,
                token: token,
                nonce: nonce),
            platform: platform,
            deviceFamily: deviceFamily)
    }

    static func normalizeMetadataField(_ value: String?) -> String {
        guard let value else { return "" }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return ""
        }
        // Keep cross-runtime normalization deterministic (TS/Swift/Kotlin):
        // lowercase ASCII A-Z only for auth payload metadata fields.
        var output = String()
        output.reserveCapacity(trimmed.count)
        for scalar in trimmed.unicodeScalars {
            let codePoint = scalar.value
            if codePoint >= 65, codePoint <= 90, let lowered = UnicodeScalar(codePoint + 32) {
                output.unicodeScalars.append(lowered)
            } else {
                output.unicodeScalars.append(scalar)
            }
        }
        return output
    }

    /// Builds the `device` dictionary sent during gateway connect once the payload is signed.
    ///
    /// Keys are exactly `id`, `publicKey`, `signature`, `signedAt`, and `nonce`.
    public static func signedDeviceDictionary(
        payload: String,
        identity: DeviceIdentity,
        signedAtMs: Int64,
        nonce: String) -> [String: OpenClawProtocol.AnyCodable]?
    {
        guard let signature = DeviceIdentityStore.signPayload(payload, identity: identity),
              let publicKey = DeviceIdentityStore.publicKeyBase64Url(identity)
        else {
            return nil
        }
        return [
            "id": OpenClawProtocol.AnyCodable(identity.deviceId),
            "publicKey": OpenClawProtocol.AnyCodable(publicKey),
            "signature": OpenClawProtocol.AnyCodable(signature),
            "signedAt": OpenClawProtocol.AnyCodable(signedAtMs),
            "nonce": OpenClawProtocol.AnyCodable(nonce),
        ]
    }
}
