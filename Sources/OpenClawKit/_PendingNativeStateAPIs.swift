// TEMPORARY SHIM (worker W1, release 2026.3.0).
//
// Implements exactly the upstream v2026.9.6 signatures that the gateway client codes against:
// `GatewayDeviceIdentityProfile`, `DeviceIdentityStore.loadOrCreatePersistedOrThrow(profile:)`,
// `DeviceIdentityStore.withStateDirectory(_:operation:)`, and the gateway/profile-scoped
// `DeviceAuthStore` token APIs. Worker W4 lands the real implementations on OpenClawNativeState;
// the orchestrator deletes this file at merge. Do not add other symbols here.
//
// This shim keeps the existing JSON files (`<stateDir>/identity/<profile file>`), using the same
// `{version:1, deviceId, tokens}` layout and the upstream scoped key encoding
// (`"v2." + base64url(gatewayID) + "." + base64url(role)`) so W4's import sees the same data.
import CryptoKit
import Foundation

/// Separate device identities (and device-token stores) for app profiles sharing one state root.
public enum GatewayDeviceIdentityProfile: String, Sendable {
    /// Main app identity.
    case primary
    /// Node-role identity.
    case node
    /// Share-extension identity.
    case shareExtension

    var identityFileName: String {
        switch self {
        case .primary: "device.json"
        case .node: "node-device.json"
        case .shareExtension: "share-device.json"
        }
    }

    var authFileName: String {
        switch self {
        case .primary: "device-auth.json"
        case .node: "node-device-auth.json"
        case .shareExtension: "share-device-auth.json"
        }
    }
}

/// Test-only state-directory scope honored by the shim's store functions.
enum PendingNativeStateScope {
    @TaskLocal static var stateDirURL: URL?

    static func resolvedStateDirURL() -> URL {
        self.stateDirURL ?? DeviceIdentityPaths.stateDirURL()
    }

    static func identityDirURL() -> URL {
        self.resolvedStateDirURL().appendingPathComponent("identity", isDirectory: true)
    }

    static func nowMs() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded(.down))
    }

    static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

private struct PendingIdentityFile: Codable {
    var deviceId: String
    var publicKey: String
    var privateKey: String
    var createdAtMs: Int64
}

extension DeviceIdentityStore {
    /// Loads or creates an identity and preserves the storage failure for callers that can report it.
    /// - Parameter profile: Identity profile to load.
    /// - Returns: A durably persisted identity.
    /// - Throws: When the identity cannot be read or written.
    public static func loadOrCreatePersistedOrThrow(
        profile: GatewayDeviceIdentityProfile = .primary) throws -> DeviceIdentity
    {
        let url = PendingNativeStateScope.identityDirURL()
            .appendingPathComponent(profile.identityFileName, isDirectory: false)
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(PendingIdentityFile.self, from: data),
           self.isValidPendingIdentity(decoded)
        {
            return DeviceIdentity(
                deviceId: decoded.deviceId,
                publicKey: decoded.publicKey,
                privateKey: decoded.privateKey,
                createdAtMs: Int(clamping: decoded.createdAtMs))
        }
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKeyData = privateKey.publicKey.rawRepresentation
        let file = PendingIdentityFile(
            deviceId: SHA256.hash(data: publicKeyData).map { String(format: "%02x", $0) }.joined(),
            publicKey: publicKeyData.base64EncodedString(),
            privateKey: privateKey.rawRepresentation.base64EncodedString(),
            createdAtMs: PendingNativeStateScope.nowMs())
        do {
            try PendingNativeStateScope.write(try JSONEncoder().encode(file), to: url)
        } catch {
            throw NSError(
                domain: "ai.openclaw.device-identity-store",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Could not access the persisted device identity: \(error.localizedDescription)",
                    NSUnderlyingErrorKey: error,
                ])
        }
        return DeviceIdentity(
            deviceId: file.deviceId,
            publicKey: file.publicKey,
            privateKey: file.privateKey,
            createdAtMs: Int(clamping: file.createdAtMs))
    }

    #if compiler(>=6.4)
    nonisolated(nonsending) static func withStateDirectory<T>(
        _ url: URL,
        operation: () async throws -> T) async rethrows -> T
    {
        try await PendingNativeStateScope.$stateDirURL.withValue(url) {
            try await operation()
        }
    }
    #else
    static func withStateDirectory<T>(
        _ url: URL,
        operation: () async throws -> T,
        isolation: isolated (any Actor)? = #isolation) async rethrows -> T
    {
        try await PendingNativeStateScope.$stateDirURL.withValue(
            url,
            operation: operation,
            isolation: isolation)
    }
    #endif

    private static func isValidPendingIdentity(_ identity: PendingIdentityFile) -> Bool {
        guard let publicKeyData = Data(base64Encoded: identity.publicKey),
              let privateKeyData = Data(base64Encoded: identity.privateKey),
              let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData),
              privateKey.publicKey.rawRepresentation == publicKeyData
        else { return false }
        let expectedID = SHA256.hash(data: publicKeyData).map { String(format: "%02x", $0) }.joined()
        return identity.deviceId == expectedID
    }
}

private struct PendingDeviceAuthEntry: Codable {
    var token: String
    var role: String
    var scopes: [String]
    var updatedAtMs: Int64
}

private struct PendingDeviceAuthFile: Codable {
    var version: Int
    var deviceId: String
    var tokens: [String: PendingDeviceAuthEntry]
}

extension DeviceAuthStore {
    /// Loads the stored token for a device, role, gateway owner and identity profile.
    public static func loadToken(
        deviceId: String,
        role: String,
        gatewayID: String?,
        profile: GatewayDeviceIdentityProfile) -> DeviceAuthEntry?
    {
        guard let key = self.pendingTokenKey(role: role, gatewayID: gatewayID),
              let store = self.pendingReadStore(profile: profile),
              store.deviceId == deviceId,
              let entry = store.tokens[key]
        else { return nil }
        return self.pendingPublicEntry(entry)
    }

    /// Stores a token and reports whether the durable write succeeded.
    static func storeTokenResult(
        deviceId: String,
        role: String,
        token: String,
        scopes: [String],
        gatewayID: String?,
        profile: GatewayDeviceIdentityProfile) -> (entry: DeviceAuthEntry, persisted: Bool)
    {
        let normalizedRole = role.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedGatewayID = self.pendingNormalizeGatewayID(gatewayID)
        let entry = PendingDeviceAuthEntry(
            token: token,
            role: normalizedRole,
            scopes: Array(Set(scopes
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }))
                .sorted(),
            updatedAtMs: PendingNativeStateScope.nowMs())
        guard gatewayID == nil || normalizedGatewayID != nil,
              let key = self.pendingTokenKey(role: normalizedRole, gatewayID: normalizedGatewayID)
        else { return (self.pendingPublicEntry(entry), false) }
        var store = self.pendingReadStore(profile: profile)
        if store?.deviceId != deviceId {
            store = PendingDeviceAuthFile(version: 1, deviceId: deviceId, tokens: [:])
        }
        store?.tokens[key] = entry
        let persisted = store.map { self.pendingWriteStore($0, profile: profile) } ?? false
        return (self.pendingPublicEntry(entry), persisted)
    }

    /// Deletes stored tokens for a role; a nil gateway owner clears every owner's token for the role.
    public static func clearToken(
        deviceId: String,
        role: String,
        gatewayID: String?,
        profile: GatewayDeviceIdentityProfile)
    {
        guard var store = self.pendingReadStore(profile: profile), store.deviceId == deviceId else { return }
        let normalizedRole = role.trimmingCharacters(in: .whitespacesAndNewlines)
        let before = store.tokens.count
        if gatewayID == nil {
            store.tokens = store.tokens.filter { key, _ in
                self.pendingDecodeTokenKey(key).role != normalizedRole
            }
        } else if let key = self.pendingTokenKey(role: normalizedRole, gatewayID: gatewayID) {
            store.tokens.removeValue(forKey: key)
        }
        if store.tokens.count != before {
            _ = self.pendingWriteStore(store, profile: profile)
        }
    }

    /// Retires one gateway owner's tokens and reports whether the write succeeded.
    public static func clearGatewayTokensPersisted(
        deviceId: String,
        gatewayID: String,
        profile: GatewayDeviceIdentityProfile) -> Bool
    {
        guard let gatewayID = self.pendingNormalizeGatewayID(gatewayID) else { return false }
        guard var store = self.pendingReadStore(profile: profile), store.deviceId == deviceId else { return true }
        store.tokens = store.tokens.filter { key, _ in
            self.pendingDecodeTokenKey(key).gatewayID != gatewayID
        }
        return self.pendingWriteStore(store, profile: profile)
    }

    /// Moves one legacy unscoped role token to a gateway-scoped key.
    @discardableResult
    public static func migrateUnscopedToken(
        deviceId: String,
        role: String,
        toGatewayID gatewayID: String,
        profile: GatewayDeviceIdentityProfile) -> Bool
    {
        guard let gatewayID = self.pendingNormalizeGatewayID(gatewayID) else { return false }
        let normalizedRole = role.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let legacyKey = self.pendingTokenKey(role: normalizedRole, gatewayID: nil),
              let scopedKey = self.pendingTokenKey(role: normalizedRole, gatewayID: gatewayID),
              var store = self.pendingReadStore(profile: profile),
              store.deviceId == deviceId,
              let entry = store.tokens[legacyKey]
        else { return false }
        if store.tokens[scopedKey] == nil {
            store.tokens[scopedKey] = entry
        }
        store.tokens.removeValue(forKey: legacyKey)
        return self.pendingWriteStore(store, profile: profile)
    }

    private static func pendingPublicEntry(_ entry: PendingDeviceAuthEntry) -> DeviceAuthEntry {
        DeviceAuthEntry(
            token: entry.token,
            role: entry.role,
            scopes: entry.scopes,
            updatedAtMs: Int(clamping: entry.updatedAtMs))
    }

    private static func pendingFileURL(profile: GatewayDeviceIdentityProfile) -> URL {
        PendingNativeStateScope.identityDirURL()
            .appendingPathComponent(profile.authFileName, isDirectory: false)
    }

    private static func pendingReadStore(profile: GatewayDeviceIdentityProfile) -> PendingDeviceAuthFile? {
        guard let data = try? Data(contentsOf: self.pendingFileURL(profile: profile)),
              let decoded = try? JSONDecoder().decode(PendingDeviceAuthFile.self, from: data),
              decoded.version == 1
        else { return nil }
        return decoded
    }

    private static func pendingWriteStore(_ store: PendingDeviceAuthFile, profile: GatewayDeviceIdentityProfile) -> Bool {
        do {
            try PendingNativeStateScope.write(try JSONEncoder().encode(store), to: self.pendingFileURL(profile: profile))
            return true
        } catch {
            return false
        }
    }

    private static func pendingNormalizeGatewayID(_ gatewayID: String?) -> String? {
        guard let gatewayID, !gatewayID.isEmpty else { return nil }
        return gatewayID
    }

    private static func pendingTokenKey(role: String, gatewayID: String?) -> String? {
        let normalizedRole = role.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedRole.isEmpty else { return nil }
        guard let gatewayID = self.pendingNormalizeGatewayID(gatewayID) else { return normalizedRole }
        return "v2.\(self.pendingStorageComponent(gatewayID)).\(self.pendingStorageComponent(normalizedRole))"
    }

    private static func pendingStorageComponent(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func pendingDecodeStorageComponent(_ value: String) -> String? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 {
            base64.append("=")
        }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func pendingDecodeTokenKey(_ key: String) -> (role: String, gatewayID: String?) {
        let parts = key.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "v2",
              let gatewayID = self.pendingDecodeStorageComponent(String(parts[1])),
              let role = self.pendingDecodeStorageComponent(String(parts[2]))
        else { return (key, nil) }
        return (role, gatewayID)
    }
}
