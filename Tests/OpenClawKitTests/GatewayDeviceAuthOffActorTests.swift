import Foundation
import SQLite3
import Testing
@testable import OpenClawKit

/// A second SQLite connection holding the state database's write lock (another process's writer).
private final class StateDatabaseWriteLock: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: OpaquePointer?

    var isHeld: Bool {
        self.lock.withLock { self.handle != nil }
    }

    func acquire(databaseURL: URL) {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let database else {
            return
        }
        guard sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(database)
            return
        }
        self.lock.withLock { self.handle = database }
    }

    func release() {
        let database = self.lock.withLock { () -> OpaquePointer? in
            defer { self.handle = nil }
            return self.handle
        }
        guard let database else { return }
        sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
        sqlite3_close(database)
    }
}

@Suite("Gateway device auth off the channel actor", .serialized)
struct GatewayDeviceAuthOffActorTests {
    @Test
    func issuedTokenPersistenceNeverBlocksTheChannelActor() async throws {
        let directory = try gatewayCoreTemporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await DeviceIdentityStore.withStateDirectory(directory) {
            let identity = try DeviceIdentityStore.loadOrCreatePersistedOrThrow(profile: .primary)
            let databaseURL = directory.appendingPathComponent("state/openclaw.sqlite")
            let writeLock = StateDatabaseWriteLock()
            defer { writeLock.release() }
            let session = GatewayCoreFakeSession(fixedScript: GatewayCoreSocketScript(
                connectReply: { _ in
                    // Another process takes the write lock just as hello-ok issues a device token.
                    writeLock.acquire(databaseURL: databaseURL)
                    return .ok(GatewayCoreFrames.hello(auth: [
                        "role": "operator", "deviceToken": "issued", "scopes": ["operator.read"],
                    ]))
                }))
            let channel = GatewayChannelActor(
                url: try #require(URL(string: "wss://gateway.example.com")),
                token: "shared",
                session: WebSocketSessionBox(session: session),
                connectOptions: gatewayCoreOptions(includeDeviceIdentity: true))
            let connect = Task { try await channel.connect() }
            try await gatewayCoreWaitUntil("write lock held") { writeLock.isHeld }
            try await Task.sleep(for: .milliseconds(200))

            // The token write waits on SQLite's 30 s busy timeout; the actor must stay responsive.
            let started = ContinuousClock.now
            #expect(await channel.currentConnectionGeneration() == nil)
            await channel.shutdown()
            #expect(ContinuousClock.now - started < .seconds(3))

            writeLock.release()
            _ = try? await connect.value
            try await gatewayCoreWaitUntil("token persisted after the lock") {
                DeviceAuthStore.loadToken(deviceId: identity.deviceId, role: "operator")?.token == "issued"
            }
        }
    }
}
