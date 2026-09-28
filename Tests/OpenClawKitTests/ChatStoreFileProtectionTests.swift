import Foundation
import Testing
@testable import OpenClawChatStore
@testable import OpenClawChatUI

/// SDK additions on top of the upstream client databases: private permissions and the default
/// directory helper.
struct ChatStoreFileProtectionTests {
    private static func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.posixPermissions] as? Int)
    }

    @Test func `store directory and database files are private to the owner`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-store-permissions-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("nested/ChatStore", isDirectory: true)
        let databases = try OpenClawClientDatabases(directoryURL: directory)
        defer { try? databases.close() }
        // Force WAL sidecars into existence before checking them.
        let store = databases.store(gatewayID: "gw-permissions")
        #expect(await store.enqueueCommand(OpenClawChatOutboxCommand(
            id: "cmd-1",
            sessionKey: "main",
            deliverySessionKey: "agent:main:main",
            routingContract: "per-sender|main|main",
            agentID: "main",
            text: "hello",
            thinking: "off",
            createdAt: Date().timeIntervalSince1970,
            status: .queued,
            retryCount: 0,
            lastError: nil)))

        #expect(try Self.permissions(directory) == 0o700)
        for name in [OpenClawClientDatabases.clientStateFilename, OpenClawClientDatabases.gatewayCacheFilename] {
            let url = directory.appendingPathComponent(name)
            #expect(try Self.permissions(url) == 0o600, "\(name) must be owner-only")
            let wal = URL(fileURLWithPath: url.path + "-wal")
            if FileManager.default.fileExists(atPath: wal.path) {
                #expect(try Self.permissions(wal) & 0o077 == 0, "\(name)-wal must not be group/world readable")
            }
        }
    }

    @Test func `reopening re-secures loosened permissions`() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-store-resecure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try OpenClawClientDatabases(directoryURL: directory).close()
        let stateURL = directory.appendingPathComponent(OpenClawClientDatabases.clientStateFilename)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: stateURL.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)

        try OpenClawClientDatabases(directoryURL: directory).close()

        #expect(try Self.permissions(directory) == 0o700)
        #expect(try Self.permissions(stateURL) == 0o600)
    }

    @Test func `default directory lives under Application Support`() throws {
        let url = try OpenClawClientDatabases.defaultDirectoryURL()
        #expect(url.lastPathComponent == "ChatStore")
        #expect(url.deletingLastPathComponent().lastPathComponent == "OpenClawKit")
        #expect(url.path.contains("Application Support"))
    }
}
