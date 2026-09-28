import Foundation
import Testing
import OpenClawAgents
import OpenClawCore
import OpenClawMedia
import OpenClawModels
import OpenClawProtocol

/// Cross-platform smoke checks for the media-understanding and CoreAI adapter surfaces; on Linux the
/// Apple framework adapters compile out and report themselves unavailable.
@Suite("Media understanding and CoreAI smoke")
struct MediaUnderstandingSmokeTests {
    struct UppercaseOCR: ImageTextExtracting {
        func extractText(from attachment: MediaAttachment) async throws -> ImageTextExtractionResult {
            ImageTextExtractionResult(lines: [attachment.fileName?.uppercased() ?? "?"])
        }
    }

    struct EchoTokenizer: CoreAITokenizer {
        let eosTokenIDs: Set<Int32> = [0]

        func encode(_ text: String) -> [Int32] {
            text.utf8.map { Int32($0) }
        }

        func decode(_ tokens: [Int32]) -> String {
            String(decoding: tokens.map { UInt8(truncatingIfNeeded: $0) }, as: UTF8.self)
        }
    }

    /// Always predicts `!` (33) and then EOS.
    actor BangExecutor: CoreAITensorExecuting {
        private var calls = 0

        func describe() async throws -> CoreAIModelDescriptor {
            CoreAIModelDescriptor(path: "/m.aimodel")
        }

        func run(function _: String, inputs _: [String: CoreAITensor]) async throws -> [String: CoreAITensor] {
            self.calls += 1
            var logits = [Float](repeating: 0, count: 64)
            logits[self.calls == 1 ? 33 : 0] = 1
            return ["logits": try CoreAITensor(float32: logits, shape: [1, 64])]
        }
    }

    @Test
    func preprocessorConvertsImagesForTextOnlyModels() async {
        let image = MediaAttachment(mimeType: "image/png", data: Data([1]), fileName: "sign.png")
        let outcome = await MediaUnderstandingPreprocessor(services: MediaUnderstandingServices(imageText: UppercaseOCR()))
            .process([image], policy: MediaUnderstandingInputPolicy(inputs: [.text]))
        #expect(outcome.attachments.count == 1)
        #expect(String(decoding: outcome.attachments[0].data, as: UTF8.self) == "[image-1 text]:\nSIGN.PNG")

        let untouched = await MediaUnderstandingPreprocessor(services: .none).process([image], policy: .textOnly)
        #expect(untouched.attachments == [image])
    }

    @Test
    func appleAdaptersReportAvailabilityPerPlatform() {
        #if os(Linux)
        #expect(!AppleVideoUnderstandingAnalyzer.isSupported)
        #expect(!AppleMusicAnalyzerService.isSupported)
        #expect(!CoreAIModelRuntime.isSupported)
        #expect(CoreAIModelRuntime.availableComputeUnits.isEmpty)
        #expect(MediaUnderstandingServices.platformDefault.imageText == nil)
        #expect(MediaUnderstandingServices.platformDefault.music == nil)
        #endif
        #expect(MusicAnalyzeTool.isAvailable == AppleMusicAnalyzerService.isSupported)
    }

    @Test
    func coreAIEngineDecodesWithAFakeExecutor() async throws {
        let engine = CoreAILocalModelEngine(tokenizer: EchoTokenizer(), executorFactory: { _, _ in BangExecutor() })
        var configuration = LocalModelConfig(enabled: true, runtime: CoreAILocalModelEngine.runtimeID, modelPath: "/m.aimodel")
        configuration.temperature = 0
        try await engine.loadModel(path: "/m.aimodel", configuration: configuration)
        let text = try await engine.generate(prompt: "hi", systemPrompt: nil, configuration: configuration, onToken: nil)
        #expect(text == "!")
    }

    @Test
    func musicToolReportsMissingAnalyzer() async throws {
        let output = try await MusicAnalyzeTool(analyzer: nil).invoke(AgentToolInvocation(arguments: ["path": AnyCodable("/x.wav")]), update: nil)
        #expect(output.isError)
    }
}
