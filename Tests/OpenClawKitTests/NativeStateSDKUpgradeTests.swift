import CryptoKit
import Foundation
import OpenClawNativeState
import SQLite3
import Testing
@testable import OpenClawKit

/// SDK-specific coverage for the move from the JSON identity/auth files to the native state database.
@Suite(.serialized)
struct NativeStateSDKUpgradeTests {
    @Test(.stateDirectoryIsolated)
    func `existing SDK identity and device auth files upgrade without re-pairing`() throws {
        let stateDirectory = try Self.stateDirectoryURL()
        let identityDirectory = stateDirectory.appendingPathComponent("identity", isDirectory: true)
        try FileManager.default.createDirectory(at: identityDirectory, withIntermediateDirectories: true)

        // Exactly what the 2026.2 SDK wrote: JSONEncoder output of the raw-key DeviceIdentity and a
        // v1 device-auth store keyed by role.
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKeyData = privateKey.publicKey.rawRepresentation
        let deviceID = SHA256.hash(data: publicKeyData).compactMap { String(format: "%02x", $0) }.joined()
        let identityJSON: [String: Any] = [
            "deviceId": deviceID,
            "publicKey": publicKeyData.base64EncodedString(),
            "privateKey": privateKey.rawRepresentation.base64EncodedString(),
            "createdAtMs": 1_760_000_000_000 as Int64,
        ]
        let authJSON: [String: Any] = [
            "version": 1,
            "deviceId": deviceID,
            "tokens": [
                "operator": [
                    "token": "paired-operator-token",
                    "role": "operator",
                    "scopes": ["operator.write", "operator.read"],
                    "updatedAtMs": 1_760_000_000_500 as Int64,
                ],
            ],
        ]
        let identityURL = identityDirectory.appendingPathComponent("device.json")
        let authURL = identityDirectory.appendingPathComponent("device-auth.json")
        try JSONSerialization.data(withJSONObject: identityJSON).write(to: identityURL, options: [.atomic])
        try JSONSerialization.data(withJSONObject: authJSON).write(to: authURL, options: [.atomic])

        let identity = try DeviceIdentityStore.loadOrCreatePersistedOrThrow()

        #expect(identity.deviceId == deviceID)
        #expect(identity.publicKey == publicKeyData.base64EncodedString())
        #expect(identity.createdAtMs == 1_760_000_000_000)
        let token = try #require(DeviceAuthStore.loadToken(deviceId: deviceID, role: "operator"))
        #expect(token.token == "paired-operator-token")
        #expect(token.scopes == ["operator.read", "operator.write"])
        #expect(token.updatedAtMs == 1_760_000_000_500)
        #expect(token.gatewayID == nil)

        for url in [identityURL, authURL] {
            #expect(!FileManager.default.fileExists(atPath: url.path))
            #expect(!FileManager.default.fileExists(atPath: url.path + ".native-importing"))
        }
        let databaseURL = stateDirectory.appendingPathComponent("state/openclaw.sqlite")
        #expect(try Self.scalarInt(databaseURL, "PRAGMA user_version") == 0)
        #expect(try DeviceIdentityStore.loadOrCreatePersistedOrThrow() == identity)
    }

    @Test
    func `device identity round-trips epoch milliseconds beyond Int32`() throws {
        let identity = DeviceIdentity(
            deviceId: "device",
            publicKey: "public",
            privateKey: "private",
            createdAtMs: 1_800_000_000_000)
        let decoded = try JSONDecoder().decode(DeviceIdentity.self, from: JSONEncoder().encode(identity))
        #expect(decoded == identity)
        #expect(decoded.createdAtMs > Int64(Int32.max))
    }

    @Test(.stateDirectoryIsolated)
    func `deprecated load falls back to a stable ephemeral identity instead of crashing`() throws {
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclaw-blocker-\(UUID().uuidString)", isDirectory: false)
        try Data().write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        // The isolation trait restores OPENCLAW_STATE_DIR afterwards.
        setenv("OPENCLAW_STATE_DIR", blocker.path, 1)

        let first = DeviceIdentityStore.loadOrCreateOrEphemeral(profile: .node)
        let second = DeviceIdentityStore.loadOrCreateOrEphemeral(profile: .node)

        #expect(first == second)
        #expect(DeviceIdentityStore.signPayload("payload", identity: first) != nil)
        #expect(DeviceIdentityStore.lastPersistenceFailureDescription()?
            .contains("Could not access the persisted device identity") == true)
        #expect(DeviceIdentityStore.loadOrCreatePersisted(profile: .node) == nil)
    }

    @Test(.stateDirectoryIsolated)
    func `background variants match the synchronous stores`() async throws {
        let identity = try await DeviceIdentityStore.loadOrCreatePersistedInBackground()
        #expect(try DeviceIdentityStore.loadOrCreatePersistedOrThrow() == identity)

        #expect(await DeviceAuthStore.storeTokenPersistedInBackground(
            deviceId: identity.deviceId,
            role: " operator ",
            token: "scoped",
            scopes: ["b", "a"],
            gatewayID: "gateway-a"))
        let loaded = await DeviceAuthStore.loadTokenInBackground(
            deviceId: identity.deviceId,
            role: "operator",
            gatewayID: "gateway-a")
        #expect(loaded?.token == "scoped")
        #expect(loaded?.scopes == ["a", "b"])
        #expect(DeviceAuthStore.loadToken(
            deviceId: identity.deviceId,
            role: "operator",
            gatewayID: "gateway-a") == loaded)

        let result = await DeviceAuthStore.storeTokenResultInBackground(
            deviceId: identity.deviceId,
            role: "node",
            token: "node-token")
        #expect(result.persisted)
        #expect(result.entry.role == "node")

        await DeviceAuthStore.clearTokenInBackground(deviceId: identity.deviceId, role: "node")
        #expect(await DeviceAuthStore.loadTokenInBackground(deviceId: identity.deviceId, role: "node") == nil)
        #expect(await DeviceAuthStore.clearGatewayTokensPersistedInBackground(
            deviceId: identity.deviceId,
            gatewayID: "gateway-a"))
        #expect(await DeviceAuthStore.loadTokenInBackground(
            deviceId: identity.deviceId,
            role: "operator",
            gatewayID: "gateway-a") == nil)
    }

    @Test
    func `background variants carry a task scoped state directory across the queue hop`() async throws {
        let stateDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclaw-scoped-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stateDirectory) }

        let identity = try await DeviceIdentityStore.withStateDirectory(stateDirectory) {
            try await DeviceIdentityStore.loadOrCreatePersistedInBackground(profile: .shareExtension)
        }

        #expect(FileManager.default.fileExists(
            atPath: stateDirectory.appendingPathComponent("state/openclaw.sqlite").path))
        let reloaded = try await DeviceIdentityStore.withStateDirectory(stateDirectory) {
            try DeviceIdentityStore.loadOrCreatePersistedOrThrow(profile: .shareExtension)
        }
        #expect(reloaded == identity)
    }

    @Test
    func `native state queue returns values and propagates errors`() async throws {
        #expect(try await OpenClawNativeStateQueue.run { 40 + 2 } == 42)
        await #expect(throws: OpenClawNativeStateError.self) {
            try await OpenClawNativeStateQueue.run { () throws -> Int in
                throw OpenClawNativeStateError("expected")
            }
        }
    }

    @Test
    func `schema status reports version zero and newer schemas`() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try OpenClawNativeStateSQLite(
            databaseURL: directory.appendingPathComponent("openclaw.sqlite"))

        #expect(try database.schemaStatus() == OpenClawNativeStateSchemaStatus(
            userVersion: 0,
            isVersionZero: true,
            isSupported: true))
        try database.execute("PRAGMA user_version = 19")
        #expect(try database.schemaStatus().isSupported == false)
        #expect(OpenClawNativeStateSQLite.supportedSchemaVersion == 18)
        #expect(throws: OpenClawNativeStateError.self) {
            try database.ensureCanonicalTable(.deviceIdentities)
        }
    }

    @Test
    func `SDK hosts without an App Group key keep the Application Support default`() {
        #expect(DeviceIdentityPaths.appGroupIdentifier == nil)
        #expect(DeviceIdentityPaths.appGroupStateDirURL() == nil)
    }

    #if os(macOS)
    @Test
    func `CLI shared state directory mirrors the OpenClaw CLI resolution`() {
        let home = "/Users/example"
        #expect(OpenClawStateDirectory.cliShared(environment: ["HOME": home]).path == "/Users/example/.openclaw")
        #expect(OpenClawStateDirectory.cliShared(profile: "work", environment: ["HOME": home]).path ==
            "/Users/example/.openclaw-work")
        #expect(OpenClawStateDirectory.cliShared(
            profile: "default",
            environment: ["HOME": home, "OPENCLAW_PROFILE": "ignored"]).path == "/Users/example/.openclaw")
        #expect(OpenClawStateDirectory.cliShared(environment: ["HOME": home, "OPENCLAW_PROFILE": "lab"]).path ==
            "/Users/example/.openclaw-lab")
        #expect(OpenClawStateDirectory.cliShared(environment: [
            "HOME": home,
            "OPENCLAW_HOME": "~/alt-home",
        ]).path == "/Users/example/alt-home/.openclaw")
        #expect(OpenClawStateDirectory.cliShared(environment: [
            "HOME": home,
            "OPENCLAW_HOME": "/srv/openclaw",
            "OPENCLAW_STATE_DIR": " ~/state ",
        ]).path == "/srv/openclaw/state")
        #expect(OpenClawStateDirectory.cliShared(environment: [
            "HOME": home,
            "OPENCLAW_STATE_DIR": "/var/openclaw/state",
            "OPENCLAW_PROFILE": "ignored",
        ]).path == "/var/openclaw/state")
        #expect(OpenClawStateDirectory.cliShared(environment: [
            "HOME": home,
            "OPENCLAW_HOME": "undefined",
            "OPENCLAW_STATE_DIR": "null",
        ]).path == "/Users/example/.openclaw")
    }
    #endif

    @Test
    func `portable policy snapshot deduplicates and sorts rules by UTF-8 bytes`() throws {
        let data = Data(#"""
        {
          "security": "allowlist",
          "ask": "on-miss",
          "askFallback": "deny",
          "autoAllowSkills": false,
          "allowlistRules": [
            {"pattern": "/ä"},
            {"pattern": "/A", "source": "allow-always"},
            {"pattern": "/", "argPattern": "é"},
            {"pattern": "/"},
            {"pattern": "/", "argPattern": "A"},
            {"pattern": "/"},
            {"pattern": "/A"},
            {"pattern": "/é"},
            {"pattern": "/é"}
          ]
        }
        """#.utf8)

        let snapshot = try JSONDecoder().decode(OpenClawSystemRunApprovalPolicySnapshot.self, from: data)

        // Compare UTF-8 bytes: Swift String equality would conflate "/é" and "/e\u{301}".
        func key(_ pattern: String, _ argPattern: String? = nil) -> [UInt8] {
            Array(pattern.utf8) + [0] + Array((argPattern ?? "").utf8)
        }
        let expected: [[UInt8]] = [
            key("/"),
            key("/", "A"),
            key("/", "é"),
            key("/A"),
            key("/A"),
            key("/e\u{0301}"),
            key("/ä"),
            key("/é"),
        ]
        #expect(snapshot.allowlistRules.map { key($0.pattern, $0.argPattern) } == expected)
        #expect(snapshot.allowlistRules[3].source == nil)
        #expect(snapshot.allowlistRules[4].source == .allowAlways)
        let reencoded = try JSONDecoder().decode(
            OpenClawSystemRunApprovalPolicySnapshot.self,
            from: JSONEncoder().encode(snapshot))
        #expect(reencoded == snapshot)
    }

    private static func stateDirectoryURL() throws -> URL {
        let path = try #require(getenv("OPENCLAW_STATE_DIR").map { String(cString: $0) })
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func scalarInt(_ databaseURL: URL, _ sql: String) throws -> Int64 {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
            throw DeviceIdentityStore.storageError("Could not open test database")
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw DeviceIdentityStore.storageError(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw DeviceIdentityStore.storageError(String(cString: sqlite3_errmsg(database)))
        }
        return sqlite3_column_int64(statement, 0)
    }
}
