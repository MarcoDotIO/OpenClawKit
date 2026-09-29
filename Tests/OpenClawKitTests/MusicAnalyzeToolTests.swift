import Foundation
import Testing
@testable import OpenClawKit

@Suite("music_analyze tool")
struct MusicAnalyzeToolTests {
    actor AnalyzerLog {
        var calls: [(path: String, analyses: Set<MusicAnalysisKind>, bytes: Int)] = []

        func record(_ url: URL, _ analyses: Set<MusicAnalysisKind>) {
            let bytes = (try? Data(contentsOf: url).count) ?? -1
            self.calls.append((url.path, analyses, bytes))
        }
    }

    struct FakeMusicAnalyzer: MusicAnalyzing {
        let log = AnalyzerLog()
        var error: MediaUnderstandingError?

        func analyze(audioAt url: URL, analyses: Set<MusicAnalysisKind>) async throws -> MusicAnalysisSummary {
            await self.log.record(url, analyses)
            if let error {
                throw error
            }
            return MusicAnalysisSummary(
                analyses: MusicAnalysisKind.allCases.filter(analyses.contains),
                durationSeconds: 1.65,
                beatsPerMinute: 58.8,
                key: [MusicKeySegment(startSeconds: 0, durationSeconds: 1.65, tonic: "D", mode: "minor")]
            )
        }
    }

    @Test
    func descriptorIsAValidModelTool() {
        let tool = MusicAnalyzeTool(analyzer: FakeMusicAnalyzer())
        let descriptor = tool.descriptor
        #expect(descriptor.name == "music_analyze")
        #expect(descriptor.hasValidName)
        #expect(descriptor.risk == .low)
        #expect(descriptor.parameters["type"]?.stringValue == "object")
        let properties = descriptor.parameters["properties"]?.dictionaryValue
        #expect(properties?.keys.sorted() == ["analyses", "attachmentId", "path"])
        let enumValues = properties?["analyses"]?.dictionaryValue?["items"]?.dictionaryValue?["enum"]?.arrayValue?.compactMap(\.stringValue)
        #expect(enumValues == MusicAnalysisKind.allCases.map(\.rawValue))
        #expect(descriptor.modelToolDefinition.name == "music_analyze")
    }

    @Test
    func analyzesAttachmentsByIDOrFileNameWithRequestedAnalyses() async throws {
        let analyzer = FakeMusicAnalyzer()
        let audio = MediaAttachment(mimeType: "audio/x-aiff", data: Data(repeating: 7, count: 11), fileName: "Glass.aiff")
        let tool = MusicAnalyzeTool(attachments: [audio], analyzer: analyzer)

        let output = try await tool.invoke(
            AgentToolInvocation(arguments: ["attachmentId": AnyCodable(audio.id.uuidString), "analyses": AnyCodable(["BPM", "key"])]),
            update: nil
        )
        #expect(!output.isError)
        let details = try #require(output.details?.dictionaryValue)
        #expect(details["beatsPerMinute"]?.doubleValue == 58.8)
        #expect(details["analyses"]?.arrayValue?.compactMap(\.stringValue) == ["rhythm", "key"])
        #expect(details["key"]?.arrayValue?.first?.dictionaryValue?["tonic"]?.stringValue == "D")
        #expect(output.text.contains("\"beatsPerMinute\":58.8"))

        let byName = try await tool.invoke(AgentToolInvocation(arguments: ["attachment_id": AnyCodable("glass.AIFF")]), update: nil)
        #expect(!byName.isError)

        let calls = await analyzer.log.calls
        #expect(calls.count == 2)
        #expect(calls[0].analyses == [.rhythm, .key])
        #expect(calls[0].bytes == 11)
        #expect(calls[0].path.hasSuffix(".aiff"))
        #expect(calls[1].analyses == Set(MusicAnalysisKind.allCases))
        // Temporary copies are removed after the analysis.
        #expect(!FileManager.default.fileExists(atPath: calls[0].path))
    }

    @Test
    func rejectsBadArgumentsAndNonAudio() async throws {
        let image = MediaAttachment(mimeType: "image/png", data: Data([1]), fileName: "a.png")
        let tool = MusicAnalyzeTool(attachments: [image], analyzer: FakeMusicAnalyzer())

        let missing = try await tool.invoke(AgentToolInvocation(arguments: [:]), update: nil)
        #expect(missing.isError)
        #expect(missing.text == "Pass attachmentId or path.")

        let unknown = try await tool.invoke(AgentToolInvocation(arguments: ["attachmentId": AnyCodable("nope.wav")]), update: nil)
        #expect(unknown.text == "No attachment matches 'nope.wav'.")

        let notAudio = try await tool.invoke(AgentToolInvocation(arguments: ["attachmentId": AnyCodable("a.png")]), update: nil)
        #expect(notAudio.isError)
        #expect(notAudio.text.contains("not audio"))

        let badAnalyses = try await tool.invoke(
            AgentToolInvocation(arguments: ["attachmentId": AnyCodable("a.png"), "analyses": AnyCodable(["key", "vibes"])]),
            update: nil
        )
        #expect(badAnalyses.isError)
        #expect(badAnalyses.text.hasPrefix("Unknown analyses: vibes."))

        let wrongType = try await tool.invoke(AgentToolInvocation(arguments: ["path": AnyCodable("/x"), "analyses": AnyCodable(3)]), update: nil)
        #expect(wrongType.text == "analyses must be an array of strings.")
    }

    @Test
    func pathsMustStayInsideAllowedRoots() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclaw-tests", isDirectory: true)
            .appendingPathComponent("music-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("song.wav")
        try Data(repeating: 1, count: 4).write(to: file)
        let analyzer = FakeMusicAnalyzer()
        let tool = MusicAnalyzeTool(analyzer: analyzer, allowedRoots: [root])

        let allowed = try await tool.invoke(AgentToolInvocation(arguments: ["path": AnyCodable(file.path)]), update: nil)
        #expect(!allowed.isError)
        #expect(await analyzer.log.calls.first?.path == file.resolvingSymlinksInPath().path)

        let outside = try await tool.invoke(AgentToolInvocation(arguments: ["path": AnyCodable("/etc/hosts")]), update: nil)
        #expect(outside.text == "path is outside the allowed media folders.")

        let traversal = try await tool.invoke(
            AgentToolInvocation(arguments: ["path": AnyCodable(root.path + "/../../../../etc/hosts")]),
            update: nil
        )
        #expect(traversal.text == "path is outside the allowed media folders.")

        let relative = try await tool.invoke(AgentToolInvocation(arguments: ["path": AnyCodable("song.wav")]), update: nil)
        #expect(relative.text == "path must be an absolute file path.")

        let absent = try await tool.invoke(AgentToolInvocation(arguments: ["path": AnyCodable(root.appendingPathComponent("gone.wav").path)]), update: nil)
        #expect(absent.text.hasPrefix("No file exists at"))
    }

    @Test
    func protectedContentAndUnavailableAnalyzerAreClearErrors() async throws {
        let audio = MediaAttachment(mimeType: "audio/mpeg", data: Data([1, 2]), fileName: "drm.mp3")
        let protected = MusicAnalyzeTool(attachments: [audio], analyzer: FakeMusicAnalyzer(error: .protectedContent))
        let output = try await protected.invoke(AgentToolInvocation(arguments: ["attachmentId": AnyCodable("drm.mp3")]), update: nil)
        #expect(output.isError)
        #expect(output.text == "The audio contains protected (DRM) content and cannot be analyzed.")

        let unavailable = MusicAnalyzeTool(attachments: [audio], analyzer: nil)
        let unavailableOutput = try await unavailable.invoke(AgentToolInvocation(arguments: ["attachmentId": AnyCodable("drm.mp3")]), update: nil)
        #expect(unavailableOutput.isError)
        #expect(unavailableOutput.text.hasPrefix("music_analyze is unavailable"))

        // The v1 bridge surfaces error outputs as thrown errors, as for every other tool.
        await #expect(throws: OpenClawCoreError.self) {
            _ = try await protected.execute(arguments: ["attachmentId": AnyCodable("drm.mp3")])
        }
    }

    @Test
    func registersInTheToolRegistry() async throws {
        let registry = AgentToolRegistry()
        try await registry.register(MusicAnalyzeTool(analyzer: FakeMusicAnalyzer()), ownerPluginID: nil)
        let names = await registry.descriptors().map(\.name)
        #expect(names.contains("music_analyze"))
    }
}
