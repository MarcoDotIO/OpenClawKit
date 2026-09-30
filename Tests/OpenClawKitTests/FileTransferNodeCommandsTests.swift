#if os(macOS)
import Foundation
import Testing
@testable import OpenClawKit

private struct FileTransferSandbox {
    let root: String
    let outside: String

    init() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ft-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // Canonicalize (/var -> /private/var) so requests do not trip the symlink guard.
        let canonical = try #require(FileTransferNodeCommands.realPath(base.path))
        self.root = canonical + "/allowed"
        self.outside = canonical + "/outside"
        try FileManager.default.createDirectory(atPath: self.root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: self.outside, withIntermediateDirectories: true)
    }

    var commands: FileTransferNodeCommands {
        FileTransferNodeCommands(policy: FileTransferPolicy(allowedRoots: [self.root]))
    }

    func cleanUp() {
        try? FileManager.default.removeItem(atPath: (self.root as NSString).deletingLastPathComponent)
    }
}

struct FileTransferNodeCommandsTests {
    private func invoke(_ commands: FileTransferNodeCommands, _ command: String, _ params: [String: Any]) async throws
        -> [String: Any]
    {
        let json = String(decoding: try JSONSerialization.data(withJSONObject: params), as: UTF8.self)
        let response = try #require(await commands.handle(BridgeInvokeRequest(id: "r1", command: command, paramsJSON: json)))
        #expect(response.ok)
        let payload = try #require(response.payloadJSON)
        return try #require(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
    }

    @Test func `commands are advertised only on protocol 4`() {
        let commands = FileTransferNodeCommands(policy: FileTransferPolicy())
        #expect(commands.advertisedCommands(negotiatedProtocol: 3).isEmpty)
        #expect(commands.advertisedCommands(negotiatedProtocol: 4) == ["file.fetch", "dir.list", "file.write"])
    }

    @Test func `default policy denies every path`() async throws {
        let sandbox = try FileTransferSandbox()
        defer { sandbox.cleanUp() }
        try Data("x".utf8).write(to: URL(fileURLWithPath: sandbox.root + "/a.txt"))
        let result = try await self.invoke(
            FileTransferNodeCommands(policy: FileTransferPolicy()),
            "file.fetch",
            ["path": sandbox.root + "/a.txt"])
        #expect(result["ok"] as? Bool == false)
        #expect(result["code"] as? String == "PATH_TRAVERSAL")
    }

    @Test func `file fetch returns bounded base64 with a binding`() async throws {
        let sandbox = try FileTransferSandbox()
        defer { sandbox.cleanUp() }
        let path = sandbox.root + "/notes.txt"
        try Data("hello".utf8).write(to: URL(fileURLWithPath: path))
        let result = try await self.invoke(sandbox.commands, "file.fetch", ["path": path])
        #expect(result["ok"] as? Bool == true)
        #expect(result["base64"] as? String == "aGVsbG8=")
        #expect(result["size"] as? Int == 5)
        #expect(result["mimeType"] as? String == "text/plain")
        #expect(result["sha256"] as? String == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
        let binding = try #require(result["binding"] as? [String: Any])
        #expect(binding["kind"] as? String == "existing")

        let preflight = try await self.invoke(sandbox.commands, "file.fetch", ["path": path, "preflightOnly": true])
        #expect(preflight["base64"] as? String == "")
        #expect(preflight["preflightOnly"] as? Bool == true)

        let tooSmall = try await self.invoke(sandbox.commands, "file.fetch", ["path": path, "maxBytes": 2])
        #expect(tooSmall["code"] as? String == "FILE_TOO_LARGE")

        let rebound = try await self.invoke(sandbox.commands, "file.fetch", [
            "path": path,
            "expectedBinding": ["kind": "existing", "device": "0", "inode": "0"],
        ])
        #expect(rebound["code"] as? String == "CANONICAL_PATH_CHANGED")
    }

    @Test func `symlinks are refused unless followed and roots still apply`() async throws {
        let sandbox = try FileTransferSandbox()
        defer { sandbox.cleanUp() }
        let secret = sandbox.outside + "/secret.txt"
        try Data("secret".utf8).write(to: URL(fileURLWithPath: secret))
        let link = sandbox.root + "/link.txt"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: secret)

        let refused = try await self.invoke(sandbox.commands, "file.fetch", ["path": link])
        #expect(refused["code"] as? String == "SYMLINK_REDIRECT")
        let escaped = try await self.invoke(sandbox.commands, "file.fetch", ["path": link, "followSymlinks": true])
        #expect(escaped["code"] as? String == "PATH_TRAVERSAL")
    }

    @Test func `dir list pages sorted entries`() async throws {
        let sandbox = try FileTransferSandbox()
        defer { sandbox.cleanUp() }
        for name in ["c.txt", "a.txt", "b.txt"] {
            try Data(name.utf8).write(to: URL(fileURLWithPath: sandbox.root + "/" + name))
        }
        try FileManager.default.createDirectory(atPath: sandbox.root + "/dir", withIntermediateDirectories: false)
        let first = try await self.invoke(sandbox.commands, "dir.list", ["path": sandbox.root, "maxEntries": 2])
        let entries = try #require(first["entries"] as? [[String: Any]])
        #expect(entries.compactMap { $0["name"] as? String } == ["a.txt", "b.txt"])
        #expect(first["truncated"] as? Bool == true)
        let token = try #require(first["nextPageToken"] as? String)
        let second = try await self.invoke(sandbox.commands, "dir.list", ["path": sandbox.root, "pageToken": token])
        let rest = try #require(second["entries"] as? [[String: Any]])
        #expect(rest.compactMap { $0["name"] as? String } == ["c.txt", "dir"])
        #expect(rest.last?["isDir"] as? Bool == true)
        #expect(second["truncated"] as? Bool == false)
    }

    @Test func `file write requires strict base64 and respects overwrite`() async throws {
        let sandbox = try FileTransferSandbox()
        defer { sandbox.cleanUp() }
        let path = sandbox.root + "/nested/out.txt"
        let malformed = try await self.invoke(sandbox.commands, "file.write", ["path": path, "contentBase64": "A"])
        #expect(malformed["code"] as? String == "INVALID_BASE64")

        let missingParent = try await self.invoke(sandbox.commands, "file.write", ["path": path, "contentBase64": "aGk="])
        #expect(missingParent["code"] as? String == "PARENT_NOT_FOUND")

        let written = try await self.invoke(sandbox.commands, "file.write", [
            "path": path, "contentBase64": "aGk=", "createParents": true,
        ])
        #expect(written["ok"] as? Bool == true)
        #expect(written["overwritten"] as? Bool == false)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "hi")

        let refused = try await self.invoke(sandbox.commands, "file.write", ["path": path, "contentBase64": "aGk="])
        #expect(refused["code"] as? String == "EXISTS_NO_OVERWRITE")

        let outside = try await self.invoke(sandbox.commands, "file.write", [
            "path": sandbox.outside + "/x.txt", "contentBase64": "aGk=",
        ])
        #expect(outside["code"] as? String == "PATH_TRAVERSAL")

        let mismatch = try await self.invoke(sandbox.commands, "file.write", [
            "path": path, "contentBase64": "aGk=", "overwrite": true, "expectedSha256": "00",
        ])
        #expect(mismatch["code"] as? String == "INTEGRITY_FAILURE")
    }

    @Test func `other commands are not handled`() async {
        let commands = FileTransferNodeCommands(policy: FileTransferPolicy())
        #expect(await commands.handle(BridgeInvokeRequest(id: "1", command: "camera.snap")) == nil)
        #expect(FileTransferNodeCommands.strictBase64Decode("aGk=\n") == nil)
        #expect(FileTransferNodeCommands.strictBase64Decode("aGk=") == Data("hi".utf8))
    }

    // MARK: - Upstream base64 and error vocabulary

    @Test func `file write accepts unpadded and URL-safe base64 like upstream`() async throws {
        #expect(FileTransferNodeCommands.strictBase64Decode("aGk") == Data("hi".utf8))
        #expect(FileTransferNodeCommands.strictBase64Decode("aGVsbG8") == Data("hello".utf8))
        #expect(FileTransferNodeCommands.strictBase64Decode("-_8=") == Data([0xFB, 0xFF]))
        #expect(FileTransferNodeCommands.strictBase64Decode("-_8") == Data([0xFB, 0xFF]))
        #expect(FileTransferNodeCommands.strictBase64Decode("") == Data())
        for malformed in ["A", "A===", "aG k=", "aGk==", "=", "aG=k", "aGl="] {
            #expect(FileTransferNodeCommands.strictBase64Decode(malformed) == nil, "\(malformed)")
        }
        #expect(FileTransferNodeCommands.inspectStrictBase64("aGk") == 2)
        #expect(FileTransferNodeCommands.inspectStrictBase64("-_8=") == 2)

        let sandbox = try FileTransferSandbox()
        defer { sandbox.cleanUp() }
        let path = sandbox.root + "/unpadded.txt"
        let written = try await self.invoke(sandbox.commands, "file.write", ["path": path, "contentBase64": "aGVsbG8"])
        #expect(written["ok"] as? Bool == true)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "hello")
        let binding = try #require(written["binding"] as? [String: Any])
        #expect(binding["kind"] as? String == "existing", "the final write reports the written file like upstream")
    }

    @Test func `file write never writes through a final symlink`() async throws {
        let sandbox = try FileTransferSandbox()
        defer { sandbox.cleanUp() }
        let real = sandbox.root + "/real.txt"
        let link = sandbox.root + "/link.txt"
        try Data("untouched".utf8).write(to: URL(fileURLWithPath: real))
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
        let redirect = try await self.invoke(sandbox.commands, "file.write", [
            "path": link, "contentBase64": "ZXZpbA==", "overwrite": true,
        ])
        #expect(redirect["code"] as? String == "SYMLINK_REDIRECT")
        #expect(redirect["canonicalPath"] as? String == real)
        let denied = try await self.invoke(sandbox.commands, "file.write", [
            "path": link, "contentBase64": "ZXZpbA==", "overwrite": true, "followSymlinks": true,
        ])
        #expect(denied["code"] as? String == "SYMLINK_TARGET_DENIED")
        #expect(try String(contentsOfFile: real, encoding: .utf8) == "untouched")
    }

    @Test func `hardlink rejection is echoed by preflight and enforced`() async throws {
        let sandbox = try FileTransferSandbox()
        defer { sandbox.cleanUp() }
        let path = sandbox.root + "/doc.md"
        try Data("v1".utf8).write(to: URL(fileURLWithPath: path))
        let preflight = try await self.invoke(sandbox.commands, "file.write", [
            "path": path, "contentBase64": "djI=", "overwrite": true, "rejectHardlinks": true, "preflightOnly": true,
        ])
        #expect(preflight["rejectHardlinks"] as? Bool == true)
        try FileManager.default.linkItem(atPath: path, toPath: sandbox.outside + "/alias.md")
        let refused = try await self.invoke(sandbox.commands, "file.write", [
            "path": path, "contentBase64": "djI=", "overwrite": true, "rejectHardlinks": true,
        ])
        #expect(refused["code"] as? String == "HARDLINK_TARGET_DENIED")
        #expect(try String(contentsOfFile: sandbox.outside + "/alias.md", encoding: .utf8) == "v1")
    }

    // MARK: - Drift between preflight and the final call

    /// A fetch that opened the FIFO without `O_NONBLOCK` would wait forever for a writer and trip the
    /// time limit. That hang is a syscall, not an await, so the time limit's cancellation opens the write
    /// end once to release the reader and let the test body end. No wall-clock bound: a saturated test
    /// pool can stall the run for seconds.
    @Test(.timeLimit(.minutes(1)))
    func `file fetch refuses a FIFO promptly`() async throws {
        let sandbox = try FileTransferSandbox()
        defer { sandbox.cleanUp() }
        let fifo = sandbox.root + "/pipe"
        try #require(mkfifo(fifo, 0o600) == 0)
        let commands = sandbox.commands
        let result = try await withTaskCancellationHandler {
            try await self.invoke(commands, "file.fetch", ["path": fifo])
        } onCancel: {
            let writer = open(fifo, O_WRONLY | O_NONBLOCK)
            if writer >= 0 { close(writer) }
        }
        #expect(result["ok"] as? Bool == false)
        #expect(result["code"] as? String == "IS_DIRECTORY")
    }

    @Test func `file fetch verifies the opened descriptor, not the path`() throws {
        let sandbox = try FileTransferSandbox()
        defer { sandbox.cleanUp() }
        let commands = sandbox.commands
        let report = sandbox.root + "/report.txt"
        try Data("approved".utf8).write(to: URL(fileURLWithPath: report))
        guard case let .success(resolved) = commands.resolveExisting(["path": AnyCodable(report)]) else {
            Issue.record("expected the report to resolve")
            return
        }

        // The file is replaced by a symlink to a secret after the path checks.
        let secret = sandbox.outside + "/id_ed25519"
        try Data("secret".utf8).write(to: URL(fileURLWithPath: secret))
        try FileManager.default.removeItem(atPath: report)
        try FileManager.default.createSymbolicLink(atPath: report, withDestinationPath: secret)
        guard case let .failure(swapped) = commands.openVerified(resolved, params: [:], directory: false) else {
            Issue.record("a final symlink must never be opened")
            return
        }
        #expect(swapped.payload.dictionaryValue?["code"]?.stringValue == "SYMLINK_REDIRECT")

        // A parent directory alias reaches a file with the checked identity but another real path.
        try FileManager.default.removeItem(atPath: report)
        try Data("approved".utf8).write(to: URL(fileURLWithPath: report))
        let alias = sandbox.root + "/alias"
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: sandbox.root)
        guard case let .success(current) = commands.resolveExisting(["path": AnyCodable(report)]) else {
            Issue.record("expected the report to resolve")
            return
        }
        let throughAlias = FileTransferNodeCommands.ResolvedPath(
            canonical: alias + "/report.txt",
            isDirectory: false,
            identity: current.identity)
        guard case let .failure(moved) = commands.openVerified(throughAlias, params: [:], directory: false) else {
            Issue.record("a parent directory swap must be caught through F_GETPATH")
            return
        }
        #expect(moved.payload.dictionaryValue?["code"]?.stringValue == "CANONICAL_PATH_CHANGED")

        // A different file at the authorized path fails the identity check.
        try FileManager.default.removeItem(atPath: report)
        try Data("replacement".utf8).write(to: URL(fileURLWithPath: report))
        guard case let .failure(replaced) = commands.openVerified(current, params: [:], directory: false) else {
            Issue.record("a replaced file must be refused")
            return
        }
        #expect(replaced.payload.dictionaryValue?["code"]?.stringValue == "CANONICAL_PATH_CHANGED")
    }

    @Test func `file write rejects a canonical path change before touching disk`() async throws {
        let sandbox = try FileTransferSandbox()
        defer { sandbox.cleanUp() }
        let first = sandbox.root + "/first"
        let second = sandbox.root + "/second"
        let current = sandbox.root + "/current"
        try FileManager.default.createDirectory(atPath: first, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(atPath: second, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(atPath: current, withDestinationPath: first)
        let requested = current + "/out.txt"
        let preflight = try await self.invoke(sandbox.commands, "file.write", [
            "path": requested, "contentBase64": "YXBwcm92ZWQ=", "followSymlinks": true, "preflightOnly": true,
        ])
        #expect(preflight["path"] as? String == first + "/out.txt")
        try FileManager.default.removeItem(atPath: current)
        try FileManager.default.createSymbolicLink(atPath: current, withDestinationPath: second)

        let result = try await self.invoke(sandbox.commands, "file.write", [
            "path": requested, "contentBase64": "bm90IGFwcHJvdmVk", "followSymlinks": true,
            "expectedCanonicalPath": try #require(preflight["path"] as? String),
            "expectedBinding": try #require(preflight["binding"] as? [String: Any]),
        ])
        #expect(result["code"] as? String == "CANONICAL_PATH_CHANGED")
        #expect(!FileManager.default.fileExists(atPath: first + "/out.txt"))
        #expect(!FileManager.default.fileExists(atPath: second + "/out.txt"))
    }

    @Test func `file write rejects a same-inode symlinked anchor under createParents`() async throws {
        let sandbox = try FileTransferSandbox()
        defer { sandbox.cleanUp() }
        let anchor = sandbox.root + "/a"
        try FileManager.default.createDirectory(atPath: anchor, withIntermediateDirectories: false)
        let requested = anchor + "/b/c/out.txt"
        let preflight = try await self.invoke(sandbox.commands, "file.write", [
            "path": requested, "contentBase64": "aGk=", "createParents": true, "followSymlinks": true,
            "preflightOnly": true,
        ])
        #expect(preflight["path"] as? String == requested)
        // `b` now points back at the anchor, so the same anchor inode would drop a path component.
        try FileManager.default.createSymbolicLink(atPath: anchor + "/b", withDestinationPath: anchor)

        let result = try await self.invoke(sandbox.commands, "file.write", [
            "path": requested, "contentBase64": "aGk=", "createParents": true, "followSymlinks": true,
            "expectedCanonicalPath": requested,
            "expectedBinding": try #require(preflight["binding"] as? [String: Any]),
        ])
        #expect(result["code"] as? String == "CANONICAL_PATH_CHANGED")
        #expect(!FileManager.default.fileExists(atPath: anchor + "/c/out.txt"))
    }

    @Test func `file write rejects targets created or swapped after preflight`() async throws {
        let sandbox = try FileTransferSandbox()
        defer { sandbox.cleanUp() }
        let created = sandbox.root + "/created.txt"
        let createPreflight = try await self.invoke(sandbox.commands, "file.write", [
            "path": created, "contentBase64": "aGk=", "overwrite": true, "preflightOnly": true,
        ])
        let createBinding = try #require(createPreflight["binding"] as? [String: Any])
        #expect(createBinding["targetInode"] == nil)
        try Data("planted".utf8).write(to: URL(fileURLWithPath: created))
        let planted = try await self.invoke(sandbox.commands, "file.write", [
            "path": created, "contentBase64": "aGk=", "overwrite": true,
            "expectedCanonicalPath": created, "expectedBinding": createBinding,
        ])
        #expect(planted["code"] as? String == "CANONICAL_PATH_CHANGED")
        #expect(try String(contentsOfFile: created, encoding: .utf8) == "planted")

        let target = sandbox.root + "/target.txt"
        try Data("approved".utf8).write(to: URL(fileURLWithPath: target))
        let overwritePreflight = try await self.invoke(sandbox.commands, "file.write", [
            "path": target, "contentBase64": "bmV3", "overwrite": true, "preflightOnly": true,
        ])
        let overwriteBinding = try #require(overwritePreflight["binding"] as? [String: Any])
        #expect(overwriteBinding["targetInode"] is String)
        // Same pathname, different file.
        try FileManager.default.moveItem(atPath: target, toPath: sandbox.root + "/moved.txt")
        try Data("replacement".utf8).write(to: URL(fileURLWithPath: target))
        let swapped = try await self.invoke(sandbox.commands, "file.write", [
            "path": target, "contentBase64": "bmV3", "overwrite": true,
            "expectedCanonicalPath": target, "expectedBinding": overwriteBinding,
        ])
        #expect(swapped["code"] as? String == "CANONICAL_PATH_CHANGED")
        #expect(try String(contentsOfFile: target, encoding: .utf8) == "replacement")

        // The authorized inode is overwritten in place.
        let moved = sandbox.root + "/moved.txt"
        let inPlacePreflight = try await self.invoke(sandbox.commands, "file.write", [
            "path": moved, "contentBase64": "bmV3", "overwrite": true, "preflightOnly": true,
        ])
        let inode = try FileManager.default.attributesOfItem(atPath: moved)[.systemFileNumber] as? Int
        let overwritten = try await self.invoke(sandbox.commands, "file.write", [
            "path": moved, "contentBase64": "bmV3", "overwrite": true,
            "expectedCanonicalPath": moved, "expectedBinding": try #require(inPlacePreflight["binding"] as? [String: Any]),
        ])
        #expect(overwritten["ok"] as? Bool == true)
        #expect(overwritten["overwritten"] as? Bool == true)
        #expect(try String(contentsOfFile: moved, encoding: .utf8) == "new")
        #expect(try FileManager.default.attributesOfItem(atPath: moved)[.systemFileNumber] as? Int == inode)
    }
}
#endif
