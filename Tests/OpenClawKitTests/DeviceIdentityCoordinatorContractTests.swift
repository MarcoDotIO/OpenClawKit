import Darwin
import Foundation
import Testing
@testable import OpenClawKit

private struct DeviceIdentityCoordinatorContractFixture: Decodable, Equatable {
    let databasePath: String
    let stateDirectory: String
    let runtimeDirectory: String
    let uid: UInt32
    let stateCoordinatorPath: String
    let orderedExpectedPaths: [String]
}

private enum DeviceIdentityCoordinatorContractFixtureLoader {
    /// Verbatim copy of upstream `test/fixtures/device-identity-coordinator-contract.json` (v2026.9.6).
    /// Embedded so the test target needs no resource bundle; `upstreamFixture()` checks for drift.
    static let embeddedJSON = """
    {
      "databasePath": "/openclaw-device-identity-contract/state/openclaw.sqlite",
      "stateDirectory": "/openclaw-device-identity-contract",
      "runtimeDirectory": "/openclaw-state-runtime",
      "uid": 501,
      "stateCoordinatorPath": "/openclaw-state-runtime/openclaw-state-locks-501/state-lifecycle.e5c82e32.lock.sqlite",
      "orderedExpectedPaths": [
        "/openclaw-device-identity-contract/tmp/openclaw-501/device-identity.e5c82e32.lock.sqlite"
      ]
    }
    """

    static func load() throws -> DeviceIdentityCoordinatorContractFixture {
        try JSONDecoder().decode(
            DeviceIdentityCoordinatorContractFixture.self,
            from: Data(self.embeddedJSON.utf8))
    }

    /// The upstream fixture when the parity checkout (`.codex/openclaw`) is present above this file.
    static func upstreamFixture() throws -> DeviceIdentityCoordinatorContractFixture? {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory.appendingPathComponent(
                ".codex/openclaw/test/fixtures/device-identity-coordinator-contract.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try JSONDecoder().decode(
                    DeviceIdentityCoordinatorContractFixture.self,
                    from: Data(contentsOf: candidate))
            }
            directory.deleteLastPathComponent()
        }
        return nil
    }
}

struct DeviceIdentityCoordinatorContractTests {
    @Test func `uses a sandbox writable lifecycle runtime`() {
        let stateDirectory = URL(fileURLWithPath: "/sandbox/group/OpenClaw", isDirectory: true)

        #expect(
            DeviceIdentitySQLiteStore.resolveStateLifecycleRuntimeDirectory(
                destinationStateDirURL: stateDirectory,
                appSandboxed: true).path == "/sandbox/group/OpenClaw/tmp")
        #expect(
            DeviceIdentitySQLiteStore.resolveStateLifecycleRuntimeDirectory(
                destinationStateDirURL: stateDirectory,
                appSandboxed: false).path == "/tmp")
    }

    @Test func `matches shared ordered path vector`() throws {
        let fixture = try DeviceIdentityCoordinatorContractFixtureLoader.load()
        let databaseURL = URL(fileURLWithPath: fixture.databasePath)
        let resolved = DeviceIdentitySQLiteStore.resolveDeviceIdentityCoordinatorURLs(
            databaseURL: databaseURL,
            destinationStateDirURL: URL(fileURLWithPath: fixture.stateDirectory, isDirectory: true),
            uid: uid_t(fixture.uid))
        let stateCoordinator = DeviceIdentitySQLiteStore.resolveStateDatabaseCoordinatorURL(
            databaseURL: databaseURL,
            runtimeDirectory: URL(fileURLWithPath: fixture.runtimeDirectory, isDirectory: true),
            uid: uid_t(fixture.uid))

        #expect(stateCoordinator.path == fixture.stateCoordinatorPath)
        #expect(resolved.map(\.path) == fixture.orderedExpectedPaths)
    }

    @Test func `embedded fixture matches the upstream parity checkout when present`() throws {
        guard let upstream = try DeviceIdentityCoordinatorContractFixtureLoader.upstreamFixture() else {
            return
        }
        #expect(try DeviceIdentityCoordinatorContractFixtureLoader.load() == upstream)
    }
}
