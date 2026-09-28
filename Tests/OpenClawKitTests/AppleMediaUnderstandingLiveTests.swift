import Foundation
import Testing
@testable import OpenClawKit
#if canImport(CoreGraphics) && canImport(CoreText) && canImport(ImageIO)
import CoreGraphics
import CoreText
import ImageIO
#endif

/// Live checks of the Apple media-understanding adapters against the real frameworks.
///
/// Opt in with `OPENCLAW_LIVE_APPLE_MEDIA=1` (they need macOS 15+ for Vision and macOS 27 for
/// MusicUnderstanding / MediaIntelligence, and use files that ship with macOS). Speech transcription
/// additionally needs `OPENCLAW_LIVE_SPEECH=1` and installed en-US speech assets.
@Suite(
    "Apple media understanding (live)",
    .enabled(if: ProcessInfo.processInfo.environment["OPENCLAW_LIVE_APPLE_MEDIA"] == "1"),
    .serialized
)
struct AppleMediaUnderstandingLiveTests {
    static let glassSound = URL(fileURLWithPath: "/System/Library/Sounds/Glass.aiff")
    static let sampleVideo = URL(fileURLWithPath: "/System/Library/CoreServices/ControlCenter.app/Contents/Resources/BentoGalleryIntroduction.mov")

    #if canImport(Vision) && canImport(CoreGraphics) && canImport(CoreText) && canImport(ImageIO)
    @Test
    func visionRecognizesRenderedText() async throws {
        guard AppleImageTextExtractor.supportsTextRecognition else {
            return
        }
        let png = try #require(Self.renderTextPNG("OPENCLAW 2026"))
        let image = MediaAttachment(mimeType: "image/png", data: png, fileName: "banner.png")
        let result = try await AppleImageTextExtractor().extractText(from: image)
        #expect(result.lines.joined(separator: " ").contains("OPENCLAW 2026"))
        #expect(result.barcodes.isEmpty)

        let outcome = await MediaUnderstandingPreprocessor().process([image], policy: .textOnly)
        #expect(outcome.issues.isEmpty)
        #expect(String(decoding: outcome.attachments[0].data, as: UTF8.self).contains("OPENCLAW 2026"))
    }
    #endif

    @Test
    func musicUnderstandingAnalyzesTheGlassSound() async throws {
        guard AppleMusicAnalyzerService.isSupported, FileManager.default.fileExists(atPath: Self.glassSound.path) else {
            return
        }
        let summary = try await AppleMusicAnalyzerService().analyze(audioAt: Self.glassSound, analyses: [])
        #expect(summary.analyses == MusicAnalysisKind.allCases)
        let bpm = try #require(summary.beatsPerMinute)
        #expect(abs(bpm - 58.8) < 2)
        #expect(summary.dominantKey?.name == "D minor")
        #expect(abs((summary.durationSeconds ?? 0) - 1.65) < 0.1)
        #expect(summary.integratedLoudness != nil)

        let tool = MusicAnalyzeTool(allowedRoots: [Self.glassSound.deletingLastPathComponent()])
        let output = try await tool.invoke(
            AgentToolInvocation(arguments: ["path": AnyCodable(Self.glassSound.path), "analyses": AnyCodable(["key"])]),
            update: nil
        )
        #expect(!output.isError)
        #expect(output.details?.dictionaryValue?["key"]?.arrayValue?.first?.dictionaryValue?["mode"]?.stringValue == "minor")
    }

    @Test
    func mediaIntelligenceFindsKeyFrameAndExtractsJPEGFrames() async throws {
        guard AppleVideoUnderstandingAnalyzer.isSupported, FileManager.default.fileExists(atPath: Self.sampleVideo.path) else {
            return
        }
        let id = UUID()
        let result = try await AppleVideoUnderstandingAnalyzer().analyze(
            videoAt: Self.sampleVideo,
            sourceAttachmentID: id,
            sourceName: "intro.mov",
            maxFrames: 3
        )
        #expect(result.keyFrameSeconds != nil)
        #expect(abs((result.durationSeconds ?? 0) - 16) < 1)
        #expect(!result.frames.isEmpty && result.frames.count <= 3)
        for frame in result.frames {
            #expect(frame.mimeType == "image/jpeg")
            #expect(frame.data.starts(with: [0xFF, 0xD8, 0xFF]))
            #expect(frame.metadata[MediaUnderstandingMetadataKey.sourceAttachmentID] == id.uuidString)
            #expect(frame.metadata[MediaUnderstandingMetadataKey.timestampSeconds].flatMap(Double.init) != nil)
        }
        #expect(result.summaryLine().hasPrefix("Video intro.mov (16s): key frame at"))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["OPENCLAW_LIVE_SPEECH"] == "1"))
    func speechTranscriberTranscribesSynthesizedSpeech() async throws {
        #if os(macOS) && canImport(Speech)
        guard AppleSpeechTranscriber.isSupported, await AppleSpeechTranscriber.installedLocales().contains("en-US") else {
            return
        }
        let directory = MediaUnderstandingTests.makeTemporaryDirectory("speech-live")
        let file = directory.appendingPathComponent("hello.aiff")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", file.path, "hello world from open claw"]
        try say.run()
        say.waitUntilExit()
        let result = try await AppleSpeechTranscriber(locale: "en-US", installMissingAssets: false).transcribe(audioAt: file, locale: nil)
        #expect(result.text.lowercased().contains("hello"))
        #expect(result.locale == "en-US")
        #endif
    }

    #if canImport(CoreGraphics) && canImport(CoreText) && canImport(ImageIO)
    static func renderTextPNG(_ text: String) -> Data? {
        let width = 800
        let height = 200
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 64, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.textPosition = CGPoint(x: 40, y: 80)
        CTLineDraw(line, context)
        guard let image = context.makeImage() else {
            return nil
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return data as Data
    }
    #endif
}
