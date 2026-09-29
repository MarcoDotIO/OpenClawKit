import Foundation

/// Async counterparts of the synchronous ``DeviceAuthStore`` API.
///
/// Each variant runs the blocking SQLite work on the dedicated native-state queue (see
/// `OpenClawNativeStateQueue`) so actors such as the gateway channel never block a cooperative
/// thread on SQLite locks. Semantics are identical to the synchronous methods; a test-scoped state
/// directory is carried across the hop.
extension DeviceAuthStore {
    /// Async counterpart of ``loadToken(deviceId:role:gatewayID:profile:)``.
    public static func loadTokenInBackground(
        deviceId: String,
        role: String,
        gatewayID: String? = nil,
        profile: GatewayDeviceIdentityProfile = .primary) async -> DeviceAuthEntry?
    {
        (try? await DeviceIdentityPaths.runOnNativeStateQueue {
            DeviceAuthStore.loadToken(deviceId: deviceId, role: role, gatewayID: gatewayID, profile: profile)
        }) ?? nil
    }

    /// Async counterpart of ``storeTokenPersisted(deviceId:role:token:scopes:gatewayID:profile:)``.
    @discardableResult
    public static func storeTokenPersistedInBackground(
        deviceId: String,
        role: String,
        token: String,
        scopes: [String] = [],
        gatewayID: String? = nil,
        profile: GatewayDeviceIdentityProfile = .primary) async -> Bool
    {
        await self.storeTokenResultInBackground(
            deviceId: deviceId,
            role: role,
            token: token,
            scopes: scopes,
            gatewayID: gatewayID,
            profile: profile).persisted
    }

    /// Async counterpart of ``clearToken(deviceId:role:gatewayID:profile:)``.
    public static func clearTokenInBackground(
        deviceId: String,
        role: String,
        gatewayID: String? = nil,
        profile: GatewayDeviceIdentityProfile = .primary) async
    {
        _ = try? await DeviceIdentityPaths.runOnNativeStateQueue {
            DeviceAuthStore.clearToken(deviceId: deviceId, role: role, gatewayID: gatewayID, profile: profile)
        }
    }

    /// Async counterpart of ``clearGatewayTokensPersisted(deviceId:gatewayID:profile:)``.
    public static func clearGatewayTokensPersistedInBackground(
        deviceId: String,
        gatewayID: String,
        profile: GatewayDeviceIdentityProfile = .primary) async -> Bool
    {
        (try? await DeviceIdentityPaths.runOnNativeStateQueue {
            DeviceAuthStore.clearGatewayTokensPersisted(deviceId: deviceId, gatewayID: gatewayID, profile: profile)
        }) ?? false
    }

    /// Async counterpart of the internal `storeTokenResult`, used by gateway connect paths that need
    /// both the normalized entry and whether it reached disk.
    static func storeTokenResultInBackground(
        deviceId: String,
        role: String,
        token: String,
        scopes: [String] = [],
        gatewayID: String? = nil,
        profile: GatewayDeviceIdentityProfile = .primary) async -> (entry: DeviceAuthEntry, persisted: Bool)
    {
        let result = try? await DeviceIdentityPaths.runOnNativeStateQueue {
            let stored = DeviceAuthStore.storeTokenResult(
                deviceId: deviceId,
                role: role,
                token: token,
                scopes: scopes,
                gatewayID: gatewayID,
                profile: profile)
            return StoredTokenResult(entry: stored.entry, persisted: stored.persisted)
        }
        if let result {
            return (result.entry, result.persisted)
        }
        // Unreachable (the work does not throw); report an unpersisted entry rather than write twice.
        let entry = DeviceAuthEntry(
            token: token,
            role: role.trimmingCharacters(in: .whitespacesAndNewlines),
            scopes: scopes,
            updatedAtMs: Int64(Date().timeIntervalSince1970 * 1000),
            gatewayID: gatewayID)
        return (entry, false)
    }
}

private struct StoredTokenResult: Sendable {
    let entry: DeviceAuthEntry
    let persisted: Bool
}
