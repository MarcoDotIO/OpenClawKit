import Foundation
import Testing
@testable import OpenClawCore

@Suite("Core state file privacy", .serialized)
struct CoreStatePrivacyTests {
    private func permissions(_ url: URL) -> Int? {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber).map { $0.intValue & 0o777 }
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("openclawkit-privacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test
    func storesCreatePrivateDirectoriesAndOwnerOnlyFiles() async throws {
        let root = try self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let configURL = root.appendingPathComponent("config/openclaw-sdk.json")
        try await ConfigStore(fileURL: configURL).save(OpenClawConfig())
        #expect(self.permissions(configURL.deletingLastPathComponent()) == 0o700)
        #expect(self.permissions(configURL) == 0o600)

        let sessionsURL = root.appendingPathComponent("sessions/sessions.json")
        let sessions = SessionStore(fileURL: sessionsURL)
        try await sessions.save()
        #expect(self.permissions(sessionsURL.deletingLastPathComponent()) == 0o700)
        #expect(self.permissions(sessionsURL) == 0o600)

        let transcripts = JSONLSessionTranscriptStore(directory: root.appendingPathComponent("transcripts"))
        _ = try await transcripts.createSession(id: "s1", cwd: "/", parentSession: nil)
        #expect(self.permissions(root.appendingPathComponent("transcripts")) == 0o700)
        #expect(self.permissions(root.appendingPathComponent("transcripts/s1.jsonl")) == 0o600)

        let documentURL = root.appendingPathComponent("state/openclaw.json")
        try await OpenClawConfigDocumentStore(fileURL: documentURL, environment: [:]).save(OpenClawConfigDocument(), expectedHash: nil)
        #expect(self.permissions(documentURL.deletingLastPathComponent()) == 0o700)
        #expect(self.permissions(documentURL) == 0o600)
    }

    @Test
    func existingDirectoriesKeepTheirPermissions() throws {
        let root = try self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: root.path)
        try OpenClawFileSystem.ensurePrivateDirectory(root)
        #expect(self.permissions(root) == 0o755)
    }
}
