import Foundation
import Testing
import OpenClawCore
import OpenClawProtocol
@testable import OpenClawAgents

/// JSONL transcript durability: torn writes, glued lines and Unicode line separators.
@Suite("Session transcript durability")
struct SessionTranscriptDurabilityTests {
    private func store(_ label: String) throws -> (JSONLSessionTranscriptStore, URL) {
        let directory = try RuntimeExtTestSupport.temporaryDirectory(label)
        return (JSONLSessionTranscriptStore(directory: directory), directory)
    }

    private func appendRaw(_ bytes: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: bytes)
    }

    private func pathTexts(_ store: JSONLSessionTranscriptStore, _ sessionID: String) async throws -> [String] {
        try await store.activePath(sessionID: sessionID).compactMap { $0.message?.text }
    }

    // MARK: JSONL durability

    @Test
    func appendsAfterATornTailStartOnAFreshLine() async throws {
        let (store, directory) = try self.store("torn-tail")
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await store.createSession(id: "s", cwd: "", parentSession: nil)
        for index in 1...3 {
            try await store.appendMessage(.userText("e\(index)", timestamp: Int64(index)), sessionID: "s")
        }
        // A crash or a full disk left half an entry without a trailing newline.
        let fragment = #"{"type":"message","id":"torn","parentId":"x","message":{"role":"user","content":"hal"#
        try self.appendRaw(Data(fragment.utf8), to: directory.appendingPathComponent("s.jsonl"))
        try await store.appendMessage(.userText("e4", timestamp: 4), sessionID: "s")
        try await store.appendMessage(.userText("e5", timestamp: 5), sessionID: "s")

        let reopened = JSONLSessionTranscriptStore(directory: directory)
        #expect(try await self.pathTexts(reopened, "s") == ["e1", "e2", "e3", "e4", "e5"])
    }

    @Test
    func aGluedLineNoLongerHidesEarlierHistory() async throws {
        let (scratch, scratchDirectory) = try self.store("glued-src")
        defer { try? FileManager.default.removeItem(at: scratchDirectory) }
        _ = try await scratch.createSession(id: "s", cwd: "", parentSession: nil)
        for index in 1...5 {
            try await scratch.appendMessage(.userText("e\(index)", timestamp: Int64(index)), sessionID: "s")
        }
        let lines = try String(contentsOf: scratchDirectory.appendingPathComponent("s.jsonl"), encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        #expect(lines.count == 6)
        // Legacy damage: e4 was appended straight after a torn fragment, so its line is unreadable
        // and e5's parent is missing.
        let damaged = [lines[0], lines[1], lines[2], lines[3], #"{"type":"message","id":"tor"# + lines[4], lines[5]].joined(separator: "\n") + "\n"
        let (store, directory) = try self.store("glued")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try damaged.write(to: directory.appendingPathComponent("s.jsonl"), atomically: true, encoding: .utf8)
        #expect(try await self.pathTexts(store, "s") == ["e1", "e2", "e3", "e5"])
        try await store.appendMessage(.userText("e6", timestamp: 6), sessionID: "s")
        #expect(try await self.pathTexts(JSONLSessionTranscriptStore(directory: directory), "s") == ["e1", "e2", "e3", "e5", "e6"])
    }

    @Test
    func unicodeLineSeparatorsInContentSurviveReload() async throws {
        let (store, directory) = try self.store("unicode-lines")
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await store.createSession(id: "s", cwd: "", parentSession: nil)
        let text = "a\u{2028}b\u{2029}c\u{0085}d"
        try await store.appendMessage(.userText("before", timestamp: 1), sessionID: "s")
        try await store.appendMessage(.userText(text, timestamp: 2), sessionID: "s")
        try await store.appendMessage(.userText("after", timestamp: 3), sessionID: "s")
        #expect(try await self.pathTexts(JSONLSessionTranscriptStore(directory: directory), "s") == ["before", text, "after"])
    }

    @Test
    func aTornMultibyteCharacterCostsOnlyItsOwnLine() async throws {
        let (store, directory) = try self.store("torn-utf8")
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await store.createSession(id: "s", cwd: "", parentSession: nil)
        try await store.appendMessage(.userText("e1", timestamp: 1), sessionID: "s")
        try self.appendRaw(Data([0x7B, 0x22, 0xE2, 0x80]), to: directory.appendingPathComponent("s.jsonl"))
        let reopened = JSONLSessionTranscriptStore(directory: directory)
        try await reopened.appendMessage(.userText("e2", timestamp: 2), sessionID: "s")
        #expect(try await self.pathTexts(JSONLSessionTranscriptStore(directory: directory), "s") == ["e1", "e2"])
    }
}
