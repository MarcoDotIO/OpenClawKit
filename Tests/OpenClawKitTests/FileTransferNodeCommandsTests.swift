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
        let malformed = try await self.invoke(sandbox.commands, "file.write", ["path": path, "contentBase64": "aGk"])
        #expect(malformed["code"] as? String == "INVALID_BASE64")

        let missingParent = try await self.invoke(sandbox.commands, "file.write", ["path": path, "contentBase64": "aGk="])
        #expect(missingParent["code"] as? String == "NOT_FOUND")

        let written = try await self.invoke(sandbox.commands, "file.write", [
            "path": path, "contentBase64": "aGk=", "createParents": true,
        ])
        #expect(written["ok"] as? Bool == true)
        #expect(written["overwritten"] as? Bool == false)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "hi")

        let refused = try await self.invoke(sandbox.commands, "file.write", ["path": path, "contentBase64": "aGk="])
        #expect(refused["code"] as? String == "EXISTS")

        let outside = try await self.invoke(sandbox.commands, "file.write", [
            "path": sandbox.outside + "/x.txt", "contentBase64": "aGk=",
        ])
        #expect(outside["code"] as? String == "PATH_TRAVERSAL")

        let mismatch = try await self.invoke(sandbox.commands, "file.write", [
            "path": path, "contentBase64": "aGk=", "overwrite": true, "expectedSha256": "00",
        ])
        #expect(mismatch["code"] as? String == "SHA256_MISMATCH")
    }

    @Test func `other commands are not handled`() async {
        let commands = FileTransferNodeCommands(policy: FileTransferPolicy())
        #expect(await commands.handle(BridgeInvokeRequest(id: "1", command: "camera.snap")) == nil)
        #expect(FileTransferNodeCommands.strictBase64Decode("aGk=\n") == nil)
        #expect(FileTransferNodeCommands.strictBase64Decode("aGk=") == Data("hi".utf8))
    }
}
#endif
