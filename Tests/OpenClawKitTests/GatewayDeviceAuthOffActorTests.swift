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

@Suite("Gateway device auth off the channel actor", .serialized, .timeLimit(.minutes(1)))
struct GatewayDeviceAuthOffActorTests {
    /// Ordering, not elapsed time, proves the actor stayed responsive: the lock is released only after
    /// the actor answers, so the token can reach disk only if the actor answered while the write was
    /// still pending. A write on the actor would hold every call until SQLite's 30 s busy timeout fails
    /// it; the token never lands and the final wait trips the time limit. The only timing left is that
    /// the healthy write must see the release within the same 30 s busy timeout.
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
            let (persistenceStarts, persistenceStarted) = AsyncStream.makeStream(of: Void.self)
            await channel._test_setDeviceTokenPersistenceStartedHandler { persistenceStarted.yield() }
            let connect = Task { try await channel.connect() }
            // Wait until hello-ok's token is handed to the persistence hop, which shutdown cannot stop.
            var starts = persistenceStarts.makeAsyncIterator()
            guard await starts.next() != nil else { throw CancellationError() }
            try #require(writeLock.isHeld)

            // The write cannot finish while the lock is held; the actor must still answer.
            #expect(await channel.currentConnectionGeneration() == nil)
            await channel.shutdown()

            writeLock.release()
            _ = try? await connect.value
            try await gatewayCoreWaitUntil("token persisted after the lock") {
                DeviceAuthStore.loadToken(deviceId: identity.deviceId, role: "operator")?.token == "issued"
            }
        }
    }
}
