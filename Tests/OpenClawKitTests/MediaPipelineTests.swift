import Foundation
import Testing
@testable import OpenClawKit
#if os(Linux)
import Glibc
#else
import Darwin
#endif

@Suite("Media pipeline")
struct MediaPipelineTests {
    @Test
    func normalizeRejectsEmptyMimeTypeAndOversizedPayloads() async throws {
        let pipeline = MediaPipeline(maxBytes: 8)

        do {
            _ = try await pipeline.normalize(MediaBlob(mimeType: "   ", data: Data([0x01])))
            Issue.record("Expected empty mime type failure")
        } catch {
            #expect(String(describing: error).contains("mimeType must not be empty"))
        }

        do {
            _ = try await pipeline.normalize(MediaBlob(mimeType: "application/octet-stream", data: Data(repeating: 0x01, count: 32)))
            Issue.record("Expected size validation failure")
        } catch {
            #expect(String(describing: error).contains("maximum supported size"))
        }
    }

    @Test
    func preparesBlobSourcesAndStagesMemoryHandles() async throws {
        let stagingDirectory = self.makeTemporaryDirectory(named: "media-blob-stage")
        let pipeline = MediaPipeline(maxBytes: 1_024, storageDirectory: stagingDirectory, allowedLocalRoots: [])
        let prepared = try await pipeline.prepare(
            source: .blob(
                MediaBlob(
                    id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
                    mimeType: "image/png; charset=binary",
                    data: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])
                ),
                fileName: "  picture  "
            )
        )

        #expect(await pipeline.kind(for: prepared.attachment.mimeType) == .image)
        #expect(prepared.handle.source == .memory)
        #expect(prepared.handle.kind == .image)
        #expect(prepared.attachment.fileName == "picture.png")
        #expect(prepared.attachment.metadata["mediaSource"] == "memory")
        #expect(prepared.attachment.metadata["mediaHandleID"] == "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
        #expect(prepared.attachment.metadata["mediaHandlePath"] == prepared.handle.storageURL.path)
        #expect(FileManager.default.fileExists(atPath: prepared.handle.storageURL.path))

        try await pipeline.cleanup([prepared.handle])
        #expect(FileManager.default.fileExists(atPath: prepared.handle.storageURL.path) == false)
    }

    @Test
    func preparesAttachmentSourcesWithStagedMetadata() async throws {
        let stagingDirectory = self.makeTemporaryDirectory(named: "media-attachment-stage")
        let pipeline = MediaPipeline(maxBytes: 1_024, storageDirectory: stagingDirectory)
        let prepared = try await pipeline.prepare(
            MediaAttachment(
                id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
                mimeType: "text/plain",
                data: Data("hello".utf8),
                fileName: "notes.txt",
                metadata: ["existing": "value"]
            )
        )

        #expect(prepared.attachment.metadata["existing"] == "value")
        #expect(prepared.attachment.metadata["bytes"] == "5")
        #expect(prepared.attachment.metadata["kind"] == "document")
        #expect(prepared.handle.source == .memory)
        #expect(prepared.handle.fileName == "notes.txt")
    }

    @Test
    func preparesLocalFilesOnlyInsideAllowedRoots() async throws {
        let allowedRoot = self.makeTemporaryDirectory(named: "media-local-root")
        let stagingDirectory = self.makeTemporaryDirectory(named: "media-local-stage")
        let nestedDirectory = allowedRoot.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        let fileURL = nestedDirectory.appendingPathComponent("sample.json", isDirectory: false)
        try Data("{\"ok\":true}".utf8).write(to: fileURL, options: [.atomic])

        let pipeline = MediaPipeline(
            maxBytes: 1_024,
            storageDirectory: stagingDirectory,
            allowedLocalRoots: [URL(string: "https://example.com/not-a-file-root")!, allowedRoot]
        )
        let prepared = try await pipeline.prepare(source: .file(fileURL))

        #expect(prepared.handle.source == .localFile)
        #expect(prepared.handle.originalURL == fileURL.standardizedFileURL)
        #expect(prepared.attachment.mimeType == "application/json")
        #expect(prepared.attachment.metadata["mediaSource"] == "localFile")
        #expect(FileManager.default.fileExists(atPath: prepared.handle.storageURL.path))

        let blockedURL = self.makeTemporaryDirectory(named: "media-local-blocked")
            .appendingPathComponent("blocked.txt", isDirectory: false)
        try Data("blocked".utf8).write(to: blockedURL, options: [.atomic])

        do {
            _ = try await pipeline.prepare(source: .file(blockedURL))
            Issue.record("Expected local-root rejection")
        } catch {
            #expect(String(describing: error).contains("outside allowed local roots"))
        }

        do {
            _ = try await pipeline.prepare(source: .file(URL(string: "https://example.com/file.txt")!))
            Issue.record("Expected file URL validation failure")
        } catch {
            #expect(String(describing: error).contains("file URL"))
        }
    }

    @Test
    func preparesRemoteSourcesUsingInjectedFetcherAndHonorsLimits() async throws {
        let stagingDirectory = self.makeTemporaryDirectory(named: "media-remote-stage")
        let requests = Locked<[String]>([])
        let pipeline = MediaPipeline(
            maxBytes: 6,
            storageDirectory: stagingDirectory,
            remoteFetcher: { url, headers, maxBytes in
                requests.withLock { $0.append("\(url.absoluteString)|\(headers["Authorization"] ?? "")|\(maxBytes)") }
                return MediaRemoteFetchResult(
                    data: Data([0x89, 0x50, 0x4E, 0x47, 0x0D]),
                    mimeType: nil,
                    fileName: "avatar",
                    finalURL: URL(string: "https://cdn.example.com/avatar")!
                )
            }
        )
        let prepared = try await pipeline.prepare(
            source: .remote(
                URL(string: "https://example.com/media")!,
                headers: ["Authorization": "Bearer test"],
                fileNameHint: nil
            )
        )

        #expect(requests.value == ["https://example.com/media|Bearer test|6"])
        #expect(prepared.handle.source == .remote)
        #expect(prepared.attachment.fileName == "avatar.png")
        #expect(prepared.attachment.metadata["mediaOriginalURL"] == "https://cdn.example.com/avatar")

        let failingPipeline = MediaPipeline(
            maxBytes: 4,
            storageDirectory: self.makeTemporaryDirectory(named: "media-remote-limit"),
            remoteFetcher: { _, _, _ in
                MediaRemoteFetchResult(data: Data(repeating: 0x01, count: 8), mimeType: "application/octet-stream")
            }
        )
        do {
            _ = try await failingPipeline.prepare(source: .remote(URL(string: "https://example.com/too-large")!))
            Issue.record("Expected remote max-bytes rejection")
        } catch {
            #expect(String(describing: error).contains("maximum supported size"))
        }

        let hintedPipeline = MediaPipeline(
            maxBytes: 32,
            storageDirectory: self.makeTemporaryDirectory(named: "media-remote-hinted"),
            remoteFetcher: { _, _, _ in
                MediaRemoteFetchResult(data: Data([0x01, 0x02, 0x03]), mimeType: nil, fileName: nil, finalURL: nil)
            }
        )
        let hintedURL = URL(string: "https://example.com/path/fallback.dat")!
        let hintedPrepared = try await hintedPipeline.prepare(
            source: .remote(
                hintedURL,
                headers: [:],
                fileNameHint: "manual-name.bin"
            )
        )
        #expect(hintedPrepared.attachment.fileName == "manual-name.bin")
        #expect(hintedPrepared.attachment.metadata["mediaOriginalURL"] == hintedURL.absoluteString)
    }

    @Test
    func cleanupExpiredRemovesOnlyStaleFilesAndHandlesMissingDirectories() async throws {
        let missingPipeline = MediaPipeline(
            maxBytes: 1_024,
            storageDirectory: self.makeTemporaryDirectory(named: "media-cleanup-missing").appendingPathComponent("missing", isDirectory: true)
        )
        #expect(try await missingPipeline.cleanupExpired(olderThan: -1) == 0)
        #expect(try await missingPipeline.cleanupExpired(olderThan: 1) == 0)

        let stagingDirectory = self.makeTemporaryDirectory(named: "media-cleanup-stage")
        let pipeline = MediaPipeline(maxBytes: 1_024, storageDirectory: stagingDirectory)
        try FileManager.default.createDirectory(at: stagingDirectory.appendingPathComponent("subdir", isDirectory: true), withIntermediateDirectories: true)
        let stale = try await pipeline.prepare(source: .blob(MediaBlob(mimeType: "text/plain", data: Data("stale".utf8))))
        let fresh = try await pipeline.prepare(source: .blob(MediaBlob(mimeType: "text/plain", data: Data("fresh".utf8))))

        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -120)],
            ofItemAtPath: stale.handle.storageURL.path
        )
        let removedCount = try await pipeline.cleanupExpired(olderThan: 60)
        #expect(removedCount == 1)
        #expect(FileManager.default.fileExists(atPath: stale.handle.storageURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: fresh.handle.storageURL.path))
    }

    @Test
    func infersMimeKindsAndNormalizedFileNamesAcrossCommonFormats() async throws {
        let stagingDirectory = self.makeTemporaryDirectory(named: "media-format-stage")
        let pipeline = MediaPipeline(maxBytes: 2_048, storageDirectory: stagingDirectory)
        #expect(await pipeline.stagingDirectory() == stagingDirectory.standardizedFileURL)
        #expect(await pipeline.kind(for: "audio/ogg") == .audio)
        #expect(await pipeline.kind(for: "video/mp4") == .video)
        #expect(await pipeline.kind(for: "  ; charset=utf-8") == .unknown)
        #expect(MediaPipeline.defaultLocalRoots(storageDirectory: stagingDirectory).contains(stagingDirectory.standardizedFileURL))
        #expect(MediaPipeline.defaultLocalRoots().isEmpty == false)

        let cases: [(String, Data, String?, String, MediaKind)] = [
            ("image/jpeg", Data([0xFF, 0xD8, 0xFF, 0x00]), nil, ".jpg", .image),
            ("image/gif", Data("GIF89a".utf8), "gif name", ".gif", .image),
            ("application/pdf", Data("%PDF-1.7".utf8), "paper", ".pdf", .document),
            ("audio/mpeg", Data("ID3tag".utf8), "song", ".mp3", .audio),
            ("audio/ogg", Data("OggSstream".utf8), "voice", ".ogg", .audio),
            ("audio/wav", Data([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x41, 0x56, 0x45]), "clip", ".wav", .audio),
            ("video/mp4", Data(), "movie.mp4", ".mp4", .video),
            ("video/quicktime", Data(), "movie.mov", ".mov", .video),
            ("application/json", Data("{\"ok\":true}".utf8), "payload", ".json", .document),
            ("text/plain", Data("hello".utf8), "notes", ".txt", .document),
            ("image/jpeg", Data(), "poster.jpg", ".jpg", .image),
            ("image/gif", Data(), "sprite.gif", ".gif", .image),
            ("application/pdf", Data(), "sheet.pdf", ".pdf", .document),
            ("audio/wav", Data(), "clip.wav", ".wav", .audio),
            ("audio/ogg", Data(), "voice.ogg", ".ogg", .audio),
            ("audio/mpeg", Data(), "track.mp3", ".mp3", .audio),
        ]

        for (expectedMimeType, bytes, fileName, expectedSuffix, expectedKind) in cases {
            let prepared = try await pipeline.prepare(
                source: .blob(MediaBlob(mimeType: "application/octet-stream", data: bytes), fileName: fileName)
            )
            #expect(prepared.attachment.mimeType == expectedMimeType)
            #expect(prepared.handle.kind == expectedKind)
            if prepared.attachment.fileName?.hasSuffix(expectedSuffix) != true {
                Issue.record("Expected suffix \(expectedSuffix) for \(expectedMimeType), got \(prepared.attachment.fileName ?? "<nil>")")
            }
            try await pipeline.cleanup(prepared.handle)
        }

        let sanitized = try await pipeline.prepare(
            source: .blob(
                MediaBlob(
                    id: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!,
                    mimeType: "application/octet-stream",
                    data: Data([0xFF, 0x00, 0xFF])
                ),
                fileName: " ??? "
            )
        )
        #expect(sanitized.attachment.mimeType == "application/octet-stream")
        #expect(sanitized.attachment.fileName == "attachment-CCCCCCCC")
        #expect(sanitized.handle.storageURL.lastPathComponent == "attachment-CCCCCCCC---CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")

        let videoHeaderCases: [(String, String)] = [
            ("video/mp4", "attachment-DDDDDDDD.mp4"),
            ("video/quicktime", "attachment-EEEEEEEE.mov"),
        ]
        let ids = [
            UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!,
            UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")!,
        ]

        for (index, videoHeaderCase) in videoHeaderCases.enumerated() {
            let prepared = try await pipeline.prepare(
                source: .blob(
                    MediaBlob(
                        id: ids[index],
                        mimeType: videoHeaderCase.0,
                        data: Data()
                    )
                )
            )
            #expect(prepared.attachment.mimeType == videoHeaderCase.0)
            #expect(prepared.attachment.fileName == videoHeaderCase.1)
            #expect(prepared.handle.kind == .video)
            try await pipeline.cleanup(prepared.handle)
        }
    }

    @Test
    func enforcesLocalFileRootEqualityAndOversizeChecks() async throws {
        let exactFile = self.makeTemporaryDirectory(named: "media-exact-root").appendingPathComponent("only.txt", isDirectory: false)
        try Data("ok".utf8).write(to: exactFile, options: [.atomic])
        let exactPipeline = MediaPipeline(
            maxBytes: 32,
            storageDirectory: self.makeTemporaryDirectory(named: "media-exact-stage"),
            allowedLocalRoots: [exactFile]
        )
        let exactPrepared = try await exactPipeline.prepare(source: .file(exactFile))
        #expect(exactPrepared.attachment.fileName == "only.txt")
        #expect(exactPrepared.handle.originalURL == exactFile.standardizedFileURL)

        let allowedRoot = self.makeTemporaryDirectory(named: "media-large-local")
        let bigFile = allowedRoot.appendingPathComponent("big.bin", isDirectory: false)
        try Data(repeating: 0x01, count: 64).write(to: bigFile, options: [.atomic])
        let largePipeline = MediaPipeline(
            maxBytes: 8,
            storageDirectory: self.makeTemporaryDirectory(named: "media-large-stage"),
            allowedLocalRoots: [allowedRoot]
        )
        do {
            _ = try await largePipeline.prepare(source: .file(bigFile))
            Issue.record("Expected local-file size rejection")
        } catch {
            #expect(String(describing: error).contains("maximum supported size"))
        }
    }

    @Test
    func defaultRemoteFetcherSupportsSuccessAndFailurePaths() async throws {
        let serverRoot = self.makeTemporaryDirectory(named: "media-http-root")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A]).write(
            to: serverRoot.appendingPathComponent("tiny.png", isDirectory: false),
            options: [.atomic]
        )
        try Data(repeating: 0x41, count: 128).write(
            to: serverRoot.appendingPathComponent("large.bin", isDirectory: false),
            options: [.atomic]
        )

        try await self.withHTTPServer(directory: serverRoot) { baseURL in
            let pipeline = MediaPipeline(
                maxBytes: 32,
                storageDirectory: self.makeTemporaryDirectory(named: "media-http-stage")
            )
            let prepared = try await pipeline.prepare(
                source: .remote(
                    baseURL.appendingPathComponent("tiny.png", isDirectory: false),
                    headers: ["X-Test": "1"],
                    fileNameHint: "remote-image"
                )
            )
            #expect(prepared.handle.source == .remote)
            #expect(prepared.attachment.mimeType == "image/png")
            #expect(prepared.attachment.fileName == "tiny.png")

            do {
                _ = try await pipeline.prepare(source: .remote(URL(string: "ftp://example.com/blocked")!))
                Issue.record("Expected invalid remote scheme failure")
            } catch {
                #expect(String(describing: error).contains("HTTP or HTTPS"))
            }

            do {
                _ = try await pipeline.prepare(source: .remote(baseURL.appendingPathComponent("missing.png", isDirectory: false)))
                Issue.record("Expected remote HTTP status failure")
            } catch {
                #expect(String(describing: error).contains("status 404"))
            }

            let limitedPipeline = MediaPipeline(
                maxBytes: 4,
                storageDirectory: self.makeTemporaryDirectory(named: "media-http-limit")
            )
            do {
                _ = try await limitedPipeline.prepare(source: .remote(baseURL.appendingPathComponent("large.bin", isDirectory: false)))
                Issue.record("Expected remote max-bytes failure")
            } catch {
                #expect(String(describing: error).contains("maximum supported size"))
            }
        }
    }

    private func makeTemporaryDirectory(named name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclawkit-tests", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func withHTTPServer(
        directory: URL,
        body: (URL) async throws -> Void
    ) async throws {
        let port = try self.reserveTCPPort()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "python3",
            "-m",
            "http.server",
            String(port),
            "--bind",
            "127.0.0.1",
            "--directory",
            directory.path,
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }

        let baseURL = URL(string: "http://127.0.0.1:\(port)/")!
        try await self.waitForHTTPServer(baseURL: baseURL)
        try await body(baseURL)
    }

    private func waitForHTTPServer(baseURL: URL) async throws {
        var lastError: (any Error)?
        for _ in 0..<20 {
            do {
                _ = try Data(contentsOf: baseURL)
                return
            } catch {
                lastError = error
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        throw lastError ?? OpenClawCoreError.unavailable("Local HTTP server did not start")
    }

    private func reserveTCPPort() throws -> Int {
        #if os(Linux)
        let streamSocketType = Int32(SOCK_STREAM.rawValue)
        #else
        let streamSocketType = Int32(SOCK_STREAM)
        #endif
        let fd = socket(AF_INET, streamSocketType, 0)
        guard fd >= 0 else {
            throw OpenClawCoreError.unavailable("Unable to reserve TCP port")
        }
        defer { _ = close(fd) }

        var address = sockaddr_in()
#if !os(Linux)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
#endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rawPointer in
                bind(fd, rawPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            throw OpenClawCoreError.unavailable("Unable to bind ephemeral TCP port")
        }

        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rawPointer in
                getsockname(fd, rawPointer, &length)
            }
        }
        guard nameResult == 0 else {
            throw OpenClawCoreError.unavailable("Unable to inspect reserved TCP port")
        }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        self.storage = value
    }

    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        self.lock.lock()
        defer { self.lock.unlock() }
        return body(&self.storage)
    }

    var value: Value {
        self.withLock { $0 }
    }
}
