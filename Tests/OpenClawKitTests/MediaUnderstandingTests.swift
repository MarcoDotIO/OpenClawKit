import Foundation
import Testing
@testable import OpenClawKit

@Suite("Media understanding")
struct MediaUnderstandingTests {
    // MARK: Fakes

    struct FakeImageText: ImageTextExtracting {
        var result = ImageTextExtractionResult(lines: ["Hello", "World"], barcodes: [ImageBarcode(payload: "https://openclaw.ai", symbology: "qr")])
        var error: MediaUnderstandingError?

        func extractText(from _: MediaAttachment) async throws -> ImageTextExtractionResult {
            if let error {
                throw error
            }
            return self.result
        }
    }

    actor VideoRecorder {
        var calls: [(url: URL, maxFrames: Int, existed: Bool)] = []

        func record(_ url: URL, maxFrames: Int) {
            self.calls.append((url, maxFrames, FileManager.default.fileExists(atPath: url.path)))
        }
    }

    struct FakeVideo: VideoUnderstandingAnalyzing {
        let recorder = VideoRecorder()

        func analyze(videoAt url: URL, sourceAttachmentID: UUID?, sourceName: String?, maxFrames: Int) async throws -> VideoUnderstandingResult {
            await self.recorder.record(url, maxFrames: maxFrames)
            let highlights = [VideoHighlight(startSeconds: 4, durationSeconds: 2, level: 0.9)]
            let timestamps = VideoFrameSelection.timestamps(keyFrameSeconds: 1, highlights: highlights, durationSeconds: 10, maxFrames: maxFrames)
            let frames = timestamps.map { seconds in
                MediaAttachment(
                    mimeType: "image/jpeg",
                    data: Data([0xFF, 0xD8, 0xFF]),
                    fileName: "frame-\(seconds).jpg",
                    metadata: [
                        MediaUnderstandingMetadataKey.kind: "video-frame",
                        MediaUnderstandingMetadataKey.timestampSeconds: String(seconds),
                        MediaUnderstandingMetadataKey.sourceAttachmentID: sourceAttachmentID?.uuidString ?? "",
                    ]
                )
            }
            return VideoUnderstandingResult(
                sourceAttachmentID: sourceAttachmentID,
                sourceName: sourceName,
                durationSeconds: 10,
                keyFrameSeconds: 1,
                highlights: highlights,
                frames: frames
            )
        }
    }

    struct FakeTranscriber: AudioTranscribing {
        func transcribe(audioAt url: URL, locale: String?) async throws -> AudioTranscriptionResult {
            let bytes = try Data(contentsOf: url)
            return AudioTranscriptionResult(text: " heard \(bytes.count) bytes ", locale: locale ?? "en-US")
        }
    }

    // MARK: Value types

    @Test
    func frameSelectionTakesKeyFrameThenTopHighlightsDeduplicated() {
        let highlights = [
            VideoHighlight(startSeconds: 0, durationSeconds: 2, level: 0.2),
            VideoHighlight(startSeconds: 10, durationSeconds: 4, level: 0.9),
            VideoHighlight(startSeconds: 20, durationSeconds: 2, level: 0.5),
            VideoHighlight(startSeconds: 2.8, durationSeconds: 0.2, level: 0.8),
        ]
        let timestamps = VideoFrameSelection.timestamps(keyFrameSeconds: 3, highlights: highlights, durationSeconds: 30, maxFrames: 3)
        // key frame 3s; best highlight midpoint 12s; 2.9s is within 0.5s of the key frame and skipped; then 21s.
        #expect(timestamps == [3, 12, 21])

        #expect(VideoFrameSelection.timestamps(keyFrameSeconds: 3, highlights: highlights, durationSeconds: 30, maxFrames: 0).isEmpty)
        #expect(VideoFrameSelection.timestamps(keyFrameSeconds: nil, highlights: [], durationSeconds: 8, maxFrames: 4) == [4])
        #expect(VideoFrameSelection.timestamps(keyFrameSeconds: nil, highlights: [], durationSeconds: nil, maxFrames: 4).isEmpty)
        // Clamped into the duration.
        #expect(VideoFrameSelection.timestamps(keyFrameSeconds: 50, highlights: [], durationSeconds: 10, maxFrames: 1) == [9.95])
    }

    @Test
    func videoSummaryLineListsKeyFrameHighlightsAndFrames() {
        let result = VideoUnderstandingResult(
            sourceName: "clip.mov",
            durationSeconds: 16,
            keyFrameSeconds: 3.24,
            highlights: [VideoHighlight(startSeconds: 1, durationSeconds: 3.5, level: 0.812)],
            frames: [MediaAttachment(mimeType: "image/jpeg", data: Data(), metadata: [MediaUnderstandingMetadataKey.timestampSeconds: "3.24"])]
        )
        #expect(result.summaryLine() == "Video clip.mov (16s): key frame at 3.2s; highlights 1s-4.5s (level 0.81); frames at 3.2s")
        #expect(VideoUnderstandingResult().summaryLine(name: "x") == "Video x: no highlights")
    }

    @Test
    func timeRangesClampAndOverlap() {
        let range = MediaTimeRange(startSeconds: -2, durationSeconds: .nan)
        #expect(range.startSeconds == 0)
        #expect(range.durationSeconds == 0)
        let lhs = MediaTimeRange(startSeconds: 0, durationSeconds: 2)
        #expect(lhs.overlaps(MediaTimeRange(startSeconds: 1.5, durationSeconds: 1)))
        #expect(!lhs.overlaps(MediaTimeRange(startSeconds: 2, durationSeconds: 1)))
        #expect(lhs.overlaps(MediaTimeRange(startSeconds: 1, durationSeconds: 0)))
        #expect(lhs.midpointSeconds == 1)
    }

    @Test
    func musicVocabularyAndSummary() throws {
        #expect(MusicAnalysisKind(normalizing: "BPM") == .rhythm)
        #expect(MusicAnalysisKind(normalizing: "instrument_activity") == .instrumentActivity)
        #expect(MusicAnalysisKind(normalizing: "sections") == .structure)
        #expect(MusicAnalysisKind(normalizing: "tonality") == .key)
        #expect(MusicAnalysisKind(normalizing: "vibes") == nil)

        #expect(MusicKeySegment.displayTonic(forRawValue: "d") == "D")
        #expect(MusicKeySegment.displayTonic(forRawValue: "cSharp") == "C#")
        #expect(MusicKeySegment.displayTonic(forRawValue: "aFlat") == "Ab")
        #expect(MusicKeySegment.displayTonic(forRawValue: "hSharp") == "hSharp")

        let summary = MusicAnalysisSummary(
            analyses: [.key, .rhythm],
            durationSeconds: 1.65,
            beatsPerMinute: 58.839,
            key: [
                MusicKeySegment(startSeconds: 0, durationSeconds: 0.5, tonic: "F", mode: "major"),
                MusicKeySegment(startSeconds: 0.5, durationSeconds: 1.15, tonic: "D", mode: "minor"),
            ],
            sections: [MediaTimeRange(startSeconds: 0.05, durationSeconds: 1.6)],
            integratedLoudness: -25.82,
            instruments: ["other": [MediaTimeRange(startSeconds: 0.05, durationSeconds: 0.7)], "vocal": []]
        )
        #expect(summary.dominantKey?.name == "D minor")
        #expect(summary.summaryLine == "Music: 58.8 BPM; key D minor; 1 section; integrated loudness -25.8 LUFS; instruments other")

        let data = try JSONEncoder().encode(summary)
        let decoded = try JSONDecoder().decode(MusicAnalysisSummary.self, from: data)
        #expect(decoded == summary)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["beatsPerMinute"] as? Double == 58.839)
        #expect((json["analyses"] as? [String]) == ["key", "rhythm"])
    }

    @Test
    func imageTextResultRendersLinesAndBarcodes() {
        let result = ImageTextExtractionResult(
            lines: ["  ", "Total: $4"],
            barcodes: [ImageBarcode(payload: "123"), ImageBarcode(payload: "x", symbology: "qr")]
        )
        #expect(!result.isEmpty)
        #expect(result.text == "Total: $4\nbarcode: 123\nbarcode (qr): x")
        #expect(ImageTextExtractionResult(lines: [" "]).isEmpty)
    }

    // MARK: Policy

    @Test
    func policyDerivesFromCatalogInputsAndHints() {
        let textOnly = MediaUnderstandingInputPolicy(inputs: [.text])
        #expect(textOnly.wantsImageText)
        #expect(textOnly.wantsVideoUnderstanding)
        #expect(textOnly.wantsTranscription)

        let vision = MediaUnderstandingInputPolicy(inputs: [.text, .image])
        #expect(!vision.wantsImageText)
        #expect(vision.wantsVideoUnderstanding)

        let forced = MediaUnderstandingInputPolicy(inputs: [.text, .image], hints: ["ocrImages": "true", "transcriptionLocale": " fr-FR "])
        #expect(forced.wantsImageText)
        #expect(forced.transcriptionLocale == "fr-FR")

        let disabled = MediaUnderstandingInputPolicy(inputs: [.text], hints: ["mediaUnderstanding": "off"])
        #expect(!disabled.wantsImageText && !disabled.wantsVideoUnderstanding && !disabled.wantsTranscription)

        let provider = ModelProviderConfig(models: [
            ModelDefinitionConfig(id: "text-model", input: [.text]),
            ModelDefinitionConfig(id: "omni", input: [.text, .image, .audio, .video]),
        ])
        #expect(MediaUnderstandingInputPolicy.resolve(providerConfig: provider, modelID: "omni", hints: [:]) == .passthrough)
        #expect(MediaUnderstandingInputPolicy.resolve(providerConfig: provider, modelID: nil, hints: [:]) == .textOnly)
        // Unknown models keep today's behavior (pass through) but still honor hints.
        let unknown = MediaUnderstandingInputPolicy.resolve(providerConfig: provider, modelID: "missing", hints: ["ocrImages": "1"])
        #expect(unknown.acceptsImages && unknown.forceImageText)
    }

    // MARK: Preprocessor

    @Test
    func textOnlyModelsGetOCRTextFramesSummaryAndTranscripts() async throws {
        let scratch = Self.makeTemporaryDirectory("mu-text-only")
        let video = FakeVideo()
        let preprocessor = MediaUnderstandingPreprocessor(
            services: MediaUnderstandingServices(imageText: FakeImageText(), video: video, audio: FakeTranscriber()),
            scratchDirectory: scratch
        )
        let image = MediaAttachment(mimeType: "image/png", data: Data([0x89, 0x50]), fileName: "receipt.png")
        let clip = MediaAttachment(mimeType: "video/mp4", data: Data(repeating: 1, count: 12), fileName: "clip.mp4")
        let voice = MediaAttachment(mimeType: "audio/wav", data: Data(repeating: 2, count: 7), fileName: "memo.wav")
        let note = MediaAttachment(mimeType: "text/plain", data: Data("hi".utf8), fileName: "note.txt")

        let outcome = await preprocessor.process([image, clip, voice, note], policy: .textOnly)

        #expect(outcome.issues.isEmpty)
        #expect(outcome.attachments.count == 4)
        let texts = outcome.attachments.map { String(decoding: $0.data, as: UTF8.self) }
        #expect(texts[0] == "[image-1 text]:\nHello\nWorld\nbarcode (qr): https://openclaw.ai")
        #expect(outcome.attachments[0].metadata[MediaUnderstandingMetadataKey.kind] == "ocr")
        #expect(outcome.attachments[0].metadata[MediaUnderstandingMetadataKey.sourceAttachmentID] == image.id.uuidString)
        #expect(outcome.attachments[0].fileName == "receipt.ocr.txt")
        #expect(texts[1].hasPrefix("[video-1]: Video clip.mp4 (10s): key frame at 1s; highlights 4s-6s (level 0.9)"))
        #expect(outcome.attachments[1].metadata[MediaUnderstandingMetadataKey.kind] == "video-summary")
        #expect(texts[2] == "[audio-1 transcript]:\nheard 7 bytes")
        #expect(outcome.attachments[2].metadata[MediaUnderstandingMetadataKey.kind] == "transcript")
        #expect(outcome.attachments[3] == note)
        #expect(outcome.attachments.allSatisfy { $0.mimeType == "text/plain" })
        #expect(outcome.notes.count == 3)

        // Text-only models get no frames; the in-memory video was copied to scratch and removed afterwards.
        let calls = await video.recorder.calls
        #expect(calls.count == 1)
        #expect(calls[0].maxFrames == 0)
        #expect(calls[0].existed)
        #expect(calls[0].url.path.hasPrefix(scratch.resolvingSymlinksInPath().path) || calls[0].url.path.hasPrefix(scratch.path))
        #expect(calls[0].url.pathExtension == "mp4")
        #expect(!FileManager.default.fileExists(atPath: calls[0].url.path))
    }

    @Test
    func visionModelsKeepImagesAndReceiveVideoFrames() async throws {
        let preprocessor = MediaUnderstandingPreprocessor(
            services: MediaUnderstandingServices(imageText: FakeImageText(), video: FakeVideo()),
            maxVideoFrames: 2,
            scratchDirectory: Self.makeTemporaryDirectory("mu-vision")
        )
        let image = MediaAttachment(mimeType: "image/jpeg", data: Data([0xFF, 0xD8]), fileName: "photo.jpg")
        let clip = MediaAttachment(mimeType: "video/quicktime", data: Data(repeating: 3, count: 5), fileName: "clip.mov")

        let plain = await preprocessor.process([image, clip], policy: MediaUnderstandingInputPolicy(inputs: [.text, .image]))
        #expect(plain.attachments.first == image)
        let frames = plain.attachments.filter { $0.metadata[MediaUnderstandingMetadataKey.kind] == "video-frame" }
        #expect(frames.count == 2)
        #expect(frames.allSatisfy { $0.metadata[MediaUnderstandingMetadataKey.sourceAttachmentID] == clip.id.uuidString })
        #expect(plain.attachments.last?.metadata[MediaUnderstandingMetadataKey.kind] == "video-summary")
        #expect(!plain.attachments.contains(clip))

        // Forced OCR keeps the image and adds the text right after it.
        let forced = await preprocessor.process([image], policy: MediaUnderstandingInputPolicy(inputs: [.text, .image], hints: ["ocrImages": "yes"]))
        #expect(forced.attachments.count == 2)
        #expect(forced.attachments[0] == image)
        #expect(forced.attachments[1].metadata[MediaUnderstandingMetadataKey.kind] == "ocr")
    }

    @Test
    func missingOrFailingServicesPassMediaThrough() async {
        let image = MediaAttachment(mimeType: "image/png", data: Data([1]), fileName: "a.png")
        let audio = MediaAttachment(mimeType: "audio/mpeg", data: Data([2]), fileName: "b.mp3")

        let none = await MediaUnderstandingPreprocessor(services: .none).process([image, audio], policy: .textOnly)
        #expect(none.attachments == [image, audio])
        #expect(none.issues.count == 2)

        let failing = MediaUnderstandingPreprocessor(
            services: MediaUnderstandingServices(imageText: FakeImageText(error: .protectedContent))
        )
        let failed = await failing.process([image], policy: .textOnly)
        #expect(failed.attachments == [image])
        #expect(failed.issues == ["image-1: The media contains protected content and cannot be analyzed"])

        let empty = MediaUnderstandingPreprocessor(services: MediaUnderstandingServices(imageText: FakeImageText(result: ImageTextExtractionResult())))
        let emptyOutcome = await empty.process([image], policy: .textOnly)
        #expect(String(decoding: emptyOutcome.attachments[0].data, as: UTF8.self) == "[image-1 text]:\n(no text or barcodes recognized)")

        let disabled = await MediaUnderstandingPreprocessor(services: MediaUnderstandingServices(imageText: FakeImageText()))
            .process([image], policy: MediaUnderstandingInputPolicy(inputs: [.text], hints: ["mediaUnderstanding": "disabled"]))
        #expect(disabled.attachments == [image])
        #expect(disabled.issues.isEmpty)
    }

    @Test
    func stagedHandlesAreReadInPlaceOnlyUnderTrustedRoots() async throws {
        let staging = Self.makeTemporaryDirectory("mu-staging")
        let pipeline = MediaPipeline(maxBytes: 1_024, storageDirectory: staging)
        let prepared = try await pipeline.prepare(MediaAttachment(mimeType: "video/mp4", data: Data(repeating: 9, count: 16), fileName: "clip.mp4"))
        let video = FakeVideo()

        let expanded = await pipeline.expandVideoAttachments([prepared.attachment], maxFrames: 3, analyzer: video)
        var calls = await video.recorder.calls
        #expect(calls.count == 1)
        #expect(calls[0].url.path == prepared.handle.storageURL.resolvingSymlinksInPath().standardizedFileURL.path)
        #expect(calls[0].maxFrames == 3)
        #expect(FileManager.default.fileExists(atPath: prepared.handle.storageURL.path))
        // Key frame plus the single highlight midpoint: two frames even though three were allowed.
        #expect(expanded.filter { $0.mimeType == "image/jpeg" }.count == 2)
        #expect(expanded.last?.mimeType == "text/plain")

        // A spoofed handle path outside the trusted roots is ignored: the bytes are copied instead.
        var spoofedMetadata = prepared.attachment.metadata
        spoofedMetadata["mediaHandlePath"] = "/etc/hosts"
        let spoofed = MediaAttachment(mimeType: "video/mp4", data: prepared.attachment.data, fileName: "clip.mp4", metadata: spoofedMetadata)
        _ = await pipeline.expandVideoAttachments([spoofed], analyzer: video)
        calls = await video.recorder.calls
        #expect(calls.count == 2)
        #expect(calls[1].url.path != "/etc/hosts")
        #expect(calls[1].existed)

        // Without an analyzer, videos pass through.
        #expect(await pipeline.expandVideoAttachments([prepared.attachment], analyzer: nil) == [prepared.attachment])
    }

    @Test
    func classifyMatchesPipelineKinds() async {
        let pipeline = MediaPipeline()
        for mimeType in ["image/png", "audio/wav; rate=1", "VIDEO/MP4", "application/pdf", "text/plain", "font/woff", ""] {
            #expect(MediaPipeline.classify(mimeType: mimeType) == (await pipeline.kind(for: mimeType)))
        }
    }

    static func makeTemporaryDirectory(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclaw-tests", isDirectory: true)
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
