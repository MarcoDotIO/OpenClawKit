import Foundation

extension DeviceIdentityStore {
    /// Async counterpart of ``loadOrCreatePersistedOrThrow(profile:)`` that runs the blocking SQLite
    /// work on the dedicated native-state queue instead of a cooperative thread.
    ///
    /// First-time creation can wait up to 30 s on the identity coordinators when another process is
    /// creating the same identity; calling the synchronous API from an actor would block one of the
    /// Swift concurrency pool's threads for that long. A test-scoped state directory is carried
    /// across the hop.
    public static func loadOrCreatePersistedInBackground(
        profile: GatewayDeviceIdentityProfile = .primary) async throws -> DeviceIdentity
    {
        try await DeviceIdentityPaths.runOnNativeStateQueue {
            try DeviceIdentityStore.loadOrCreatePersistedOrThrow(profile: profile)
        }
    }
}
