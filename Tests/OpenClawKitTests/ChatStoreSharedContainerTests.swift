import Foundation
import GRDB
import SQLite3
import Testing
@testable import OpenClawChatStore
@testable import OpenClawChatUI

// App-group placement (`defaultDirectoryURL(appGroupIdentifier:)`) shares the store with other
// processes: suspension support, coordinated first open, and no cache deletion on lock
// contention (FX3 / F3). Tests never post GRDB's process-wide suspend notification, because it
// would suspend the databases of tests running in parallel.

private func makeSharedStoreDirectory(_ label: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("chat-store-shared-\(label)-\(UUID().uuidString)", isDirectory: true)
}

private final class OpenOutcomes: @unchecked Sendable {
    private let lock = NSLock()
    private var errors: [String] = []
    private var successes = 0

    func record(_ result: Result<Void, Error>) {
        self.lock.lock()
        defer { self.lock.unlock() }
        switch result {
        case .success: self.successes += 1
        case let .failure(error): self.errors.append(String(describing: error))
        }
    }

    var snapshot: (successes: Int, errors: [String]) {
        self.lock.lock()
        defer { self.lock.unlock() }
        return (self.successes, self.errors)
    }
}

@Suite("Chat store shared container safety")
struct ChatStoreSharedContainerTests {
    @Test func `both databases observe GRDB suspension notifications`() throws {
        let directory = makeSharedStoreDirectory("suspension")
        defer { try? FileManager.default.removeItem(at: directory) }
        let databases = try OpenClawClientDatabases(directoryURL: directory)
        defer { try? databases.close() }

        #expect(databases.stateQueue.configuration.observesSuspensionNotifications)
        #expect(databases.cacheQueue.configuration.observesSuspensionNotifications)
    }

    @Test func `concurrent first opens of one directory all succeed`() throws {
        let directory = makeSharedStoreDirectory("concurrent")
        defer { try? FileManager.default.removeItem(at: directory) }
        let outcomes = OpenOutcomes()

        DispatchQueue.concurrentPerform(iterations: 4) { _ in
            outcomes.record(Result {
                let databases = try OpenClawClientDatabases(directoryURL: directory)
                try databases.close()
            })
        }

        let snapshot = outcomes.snapshot
        #expect(snapshot.errors.isEmpty, "\(snapshot.errors)")
        #expect(snapshot.successes == 4)
    }

    @Test func `coordinated open returns the body result and propagates its error`() throws {
        let directory = makeSharedStoreDirectory("coordination")
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try OpenClawClientDatabases.coordinatingFirstOpen(of: directory) { 42 } == 42)
        struct OpenFailure: Error {}
        #expect(throws: OpenFailure.self) {
            _ = try OpenClawClientDatabases.coordinatingFirstOpen(of: directory) { () throws -> Int in
                throw OpenFailure()
            }
        }
    }

    @Test func `lock contention during cache open never deletes the cache`() throws {
        let directory = makeSharedStoreDirectory("contention")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cacheURL = directory.appendingPathComponent(OpenClawClientDatabases.gatewayCacheFilename)
        try OpenClawClientDatabases(directoryURL: directory).close()
        let fileNumber = try #require(
            FileManager.default.attributesOfItem(atPath: cacheURL.path)[.systemFileNumber] as? Int)

        // Another connection (standing in for another process) holds the cache's write lock.
        var handle: OpaquePointer?
        #expect(sqlite3_open(cacheURL.path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        #expect(sqlite3_exec(handle, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)

        #expect(throws: DatabaseError.self) {
            _ = try OpenClawClientDatabases(directoryURL: directory)
        }
        #expect(sqlite3_exec(handle, "ROLLBACK", nil, nil, nil) == SQLITE_OK)

        // The same file survived, still carrying its schema, and opens normally again.
        let survivingFileNumber = try #require(
            FileManager.default.attributesOfItem(atPath: cacheURL.path)[.systemFileNumber] as? Int)
        #expect(survivingFileNumber == fileNumber)
        let reopened = try OpenClawClientDatabases(directoryURL: directory)
        defer { try? reopened.close() }
        let formatVersion = try reopened.cacheQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT format_version FROM cache_metadata WHERE id = 1")
        }
        #expect(formatVersion == OpenClawClientDatabases.gatewayCacheFormatVersion)
    }

    @Test func `contention errors are distinguished from corruption`() {
        #expect(OpenClawClientDatabases.isContentionError(DatabaseError(resultCode: .SQLITE_BUSY)))
        #expect(OpenClawClientDatabases.isContentionError(DatabaseError(resultCode: .SQLITE_LOCKED)))
        #expect(OpenClawClientDatabases.isContentionError(DatabaseError(resultCode: .SQLITE_INTERRUPT)))
        #expect(OpenClawClientDatabases.isContentionError(DatabaseError(resultCode: .SQLITE_ABORT)))
        #expect(!OpenClawClientDatabases.isContentionError(DatabaseError(resultCode: .SQLITE_CORRUPT)))
        #expect(!OpenClawClientDatabases.isContentionError(DatabaseError(resultCode: .SQLITE_NOTADB)))
        #expect(!OpenClawClientDatabases.isContentionError(CocoaError(.fileReadCorruptFile)))
    }
}
