import Foundation
import OpenClawCore
import OpenClawProtocol

// MARK: - Service protocols

/// Recognizes text and barcodes in an image attachment (Apple: Vision `RecognizeTextRequest` and
/// `DetectBarcodesRequest`).
public protocol ImageTextExtracting: Sendable {
    /// Extracts text lines and barcodes from an image.
    /// - Parameter attachment: Image attachment (PNG, JPEG, HEIC, ...).
    /// - Returns: Recognized lines and barcodes.
    func extractText(from attachment: MediaAttachment) async throws -> ImageTextExtractionResult
}

/// Analyzes a video file and extracts representative frames (Apple: MediaIntelligence
/// key-frame and highlight requests plus AVFoundation frame extraction; see ``AppleVideoUnderstandingAnalyzer``).
public protocol VideoUnderstandingAnalyzing: Sendable {
    /// Analyzes a local video file.
    /// - Parameters:
    ///   - url: Local file URL of the video.
    ///   - sourceAttachmentID: Identifier stamped into frame metadata.
    ///   - sourceName: Display name of the video.
    ///   - maxFrames: Maximum number of frames to extract; `0` extracts none.
    /// - Returns: Key frame, highlights, and frames.
    func analyze(
        videoAt url: URL,
        sourceAttachmentID: UUID?,
        sourceName: String?,
        maxFrames: Int
    ) async throws -> VideoUnderstandingResult
}

/// Transcribes speech in an audio file (Apple: Speech `SpeechAnalyzer` + `SpeechTranscriber`).
public protocol AudioTranscribing: Sendable {
    /// Transcribes a local audio file.
    /// - Parameters:
    ///   - url: Local file URL of the audio (formats AVAudioFile can read).
    ///   - locale: Recognition locale identifier (BCP-47); `nil` uses the current locale.
    /// - Returns: Transcript text and segments.
    func transcribe(audioAt url: URL, locale: String?) async throws -> AudioTranscriptionResult
}

/// Analyzes music in an audio file (Apple: MusicUnderstanding sessions; see ``AppleMusicAnalyzerService``).
public protocol MusicAnalyzing: Sendable {
    /// Analyzes a local audio file.
    /// - Parameters:
    ///   - url: Local file URL of the audio.
    ///   - analyses: Analyses to run; an empty set runs all of them.
    /// - Returns: Compact analysis summary with times in seconds.
    func analyze(audioAt url: URL, analyses: Set<MusicAnalysisKind>) async throws -> MusicAnalysisSummary
}

// MARK: - Service container

/// Set of media-understanding services used by ``MediaUnderstandingPreprocessor`` and tools.
///
/// Every service is optional: a missing service leaves the matching media untouched.
/// ``platformDefault`` picks the on-device Apple implementations available on the running OS.
public struct MediaUnderstandingServices: Sendable {
    /// Image text and barcode extraction.
    public var imageText: (any ImageTextExtracting)?
    /// Video key-frame and highlight analysis.
    public var video: (any VideoUnderstandingAnalyzing)?
    /// Speech transcription.
    public var audio: (any AudioTranscribing)?
    /// Music analysis.
    public var music: (any MusicAnalyzing)?

    /// Creates a service set.
    /// - Parameters:
    ///   - imageText: Image text extraction service.
    ///   - video: Video analysis service.
    ///   - audio: Speech transcription service.
    ///   - music: Music analysis service.
    public init(
        imageText: (any ImageTextExtracting)? = nil,
        video: (any VideoUnderstandingAnalyzing)? = nil,
        audio: (any AudioTranscribing)? = nil,
        music: (any MusicAnalyzing)? = nil
    ) {
        self.imageText = imageText
        self.video = video
        self.audio = audio
        self.music = music
    }

    /// Service set with no services (every media kind passes through unchanged).
    public static let none = MediaUnderstandingServices()

    /// On-device services available on the running OS.
    ///
    /// - Image text: Vision (iOS 18 / macOS 15 / tvOS 18 / visionOS 2; barcodes only on watchOS 27).
    /// - Video: MediaIntelligence (iOS / macOS / tvOS / visionOS 27; not watchOS).
    /// - Audio: Speech `SpeechTranscriber` (iOS / macOS / tvOS / visionOS 26; not watchOS). The default
    ///   instance never downloads speech models; construct ``AppleSpeechTranscriber`` with
    ///   `installMissingAssets: true` to allow that.
    /// - Music: MusicUnderstanding (all Apple platforms, 27).
    ///
    /// Linux and older OS versions get ``none`` for the missing pieces.
    public static var platformDefault: MediaUnderstandingServices {
        var services = MediaUnderstandingServices()
        #if canImport(Vision)
        if AppleImageTextExtractor.isSupported {
            services.imageText = AppleImageTextExtractor()
        }
        #endif
        if AppleVideoUnderstandingAnalyzer.isSupported {
            services.video = AppleVideoUnderstandingAnalyzer()
        }
        #if canImport(Speech) && canImport(AVFoundation) && !os(watchOS)
        if AppleSpeechTranscriber.isSupported {
            services.audio = AppleSpeechTranscriber(installMissingAssets: false)
        }
        #endif
        if AppleMusicAnalyzerService.isSupported {
            services.music = AppleMusicAnalyzerService()
        }
        return services
    }
}

// MARK: - Input policy

/// What the target model accepts, and therefore which media must be converted before dispatch.
///
/// Build it from the model's catalog `input` list (``init(inputs:hints:)``): images become OCR text
/// when `.image` is missing, videos become frames plus a summary line when `.video` is missing, and
/// audio becomes a transcript when `.audio` is missing.
public struct MediaUnderstandingInputPolicy: Sendable, Equatable {
    /// Request hint that forces OCR text next to images even when the model accepts images.
    public static let ocrImagesHintKey = "ocrImages"
    /// Request hint that disables media understanding when set to `off`, `false`, `0`, or `disabled`.
    public static let enabledHintKey = "mediaUnderstanding"
    /// Request hint with the BCP-47 locale used for speech transcription.
    public static let transcriptionLocaleHintKey = "transcriptionLocale"

    /// Whether the model accepts image input.
    public var acceptsImages: Bool
    /// Whether the model accepts video input.
    public var acceptsVideo: Bool
    /// Whether the model accepts audio input.
    public var acceptsAudio: Bool
    /// Add OCR text next to images even when the model accepts images.
    public var forceImageText: Bool
    /// Master switch; when `false` attachments pass through unchanged.
    public var isEnabled: Bool
    /// BCP-47 locale used for speech transcription; `nil` uses the current locale.
    public var transcriptionLocale: String?

    /// Creates an input policy.
    /// - Parameters:
    ///   - acceptsImages: Whether the model accepts images.
    ///   - acceptsVideo: Whether the model accepts video.
    ///   - acceptsAudio: Whether the model accepts audio.
    ///   - forceImageText: Add OCR text even when images are accepted.
    ///   - isEnabled: Master switch.
    ///   - transcriptionLocale: Speech transcription locale.
    public init(
        acceptsImages: Bool = true,
        acceptsVideo: Bool = true,
        acceptsAudio: Bool = true,
        forceImageText: Bool = false,
        isEnabled: Bool = true,
        transcriptionLocale: String? = nil
    ) {
        self.acceptsImages = acceptsImages
        self.acceptsVideo = acceptsVideo
        self.acceptsAudio = acceptsAudio
        self.forceImageText = forceImageText
        self.isEnabled = isEnabled
        self.transcriptionLocale = transcriptionLocale
    }

    /// Creates a policy from a model's catalog input list and optional request hints
    /// (``ocrImagesHintKey``, ``enabledHintKey``, ``transcriptionLocaleHintKey``).
    /// - Parameters:
    ///   - inputs: Input modalities the model accepts.
    ///   - hints: Request hints such as `ModelGenerationPolicy.localRuntimeHints`.
    public init(inputs: [ModelInputType], hints: [String: String] = [:]) {
        let accepted = Set(inputs)
        self.init(
            acceptsImages: accepted.contains(.image),
            acceptsVideo: accepted.contains(.video),
            acceptsAudio: accepted.contains(.audio),
            forceImageText: Self.hintIsOn(hints[Self.ocrImagesHintKey]),
            isEnabled: !Self.hintIsOff(hints[Self.enabledHintKey]),
            transcriptionLocale: hints[Self.transcriptionLocaleHintKey].flatMap(Self.nonEmpty)
        )
    }

    /// Resolves the policy for a configured model; unknown models pass media through unchanged.
    /// - Parameters:
    ///   - providerConfig: Provider configuration holding the model definitions.
    ///   - modelID: Model identifier; `nil` uses the provider's first model.
    ///   - hints: Request hints.
    /// - Returns: The model's policy, or ``passthrough`` (with hints applied) when the model is unknown.
    public static func resolve(
        providerConfig: ModelProviderConfig?,
        modelID: String?,
        hints: [String: String] = [:]
    ) -> MediaUnderstandingInputPolicy {
        let models = providerConfig?.models ?? []
        let definition: ModelDefinitionConfig?
        if let modelID = modelID.flatMap(Self.nonEmpty) {
            definition = models.first { $0.id == modelID }
        } else {
            definition = models.first
        }
        if let definition {
            return MediaUnderstandingInputPolicy(inputs: definition.input, hints: hints)
        }
        var policy = MediaUnderstandingInputPolicy.passthrough
        policy.forceImageText = Self.hintIsOn(hints[Self.ocrImagesHintKey])
        policy.isEnabled = !Self.hintIsOff(hints[Self.enabledHintKey])
        policy.transcriptionLocale = hints[Self.transcriptionLocaleHintKey].flatMap(Self.nonEmpty)
        return policy
    }

    /// Accepts every modality; nothing is converted.
    public static let passthrough = MediaUnderstandingInputPolicy()

    /// Text-only model: images, video, and audio are all converted to text.
    public static let textOnly = MediaUnderstandingInputPolicy(acceptsImages: false, acceptsVideo: false, acceptsAudio: false)

    /// Whether images should be converted to (or supplemented with) OCR text.
    public var wantsImageText: Bool {
        self.isEnabled && (!self.acceptsImages || self.forceImageText)
    }

    /// Whether videos should be converted to frames and a summary.
    public var wantsVideoUnderstanding: Bool {
        self.isEnabled && !self.acceptsVideo
    }

    /// Whether audio should be converted to a transcript.
    public var wantsTranscription: Bool {
        self.isEnabled && !self.acceptsAudio
    }

    private static func hintIsOn(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }
        return ["1", "true", "yes", "on", "enabled"].contains(value)
    }

    private static func hintIsOff(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }
        return ["0", "false", "no", "off", "disabled", "none"].contains(value)
    }

    private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Preprocessor

/// Result of ``MediaUnderstandingPreprocessor/process(_:policy:)``.
public struct MediaUnderstandingOutcome: Sendable, Equatable {
    /// Attachments to send to the model, in the original order with derived attachments in place.
    public var attachments: [MediaAttachment]
    /// One line per conversion that happened (for logs and diagnostics).
    public var notes: [String]
    /// Non-fatal problems; the affected attachment was passed through unchanged.
    public var issues: [String]

    /// Creates an outcome.
    /// - Parameters:
    ///   - attachments: Resulting attachments.
    ///   - notes: Conversion notes.
    ///   - issues: Non-fatal problems.
    public init(attachments: [MediaAttachment], notes: [String] = [], issues: [String] = []) {
        self.attachments = attachments
        self.notes = notes
        self.issues = issues
    }
}

/// Converts attachments a model cannot read into ones it can, before dispatch.
///
/// For each attachment, by kind:
/// - image, when ``MediaUnderstandingInputPolicy/wantsImageText``: adds a `text/plain` attachment
///   `[image-N text]:\n…` (OCR lines and barcodes). The image is dropped when the model does not accept
///   images and kept when OCR was only forced.
/// - video, when ``MediaUnderstandingInputPolicy/wantsVideoUnderstanding``: replaced by JPEG frames
///   (only when the model accepts images) plus a `text/plain` line `[video-N]: Video <name>: key frame at
///   Xs; highlights …`.
/// - audio, when ``MediaUnderstandingInputPolicy/wantsTranscription``: replaced by a `text/plain`
///   attachment `[audio-N transcript]:\n…`.
///
/// Derived attachments carry ``MediaUnderstandingMetadataKey`` metadata. When a service is missing or
/// fails, the original attachment is kept and the problem is reported in
/// ``MediaUnderstandingOutcome/issues``; processing never throws.
public struct MediaUnderstandingPreprocessor: Sendable {
    /// Services used for the conversions.
    public var services: MediaUnderstandingServices
    /// Maximum frames extracted per video.
    public var maxVideoFrames: Int
    /// Directory for temporary copies of in-memory media.
    public var scratchDirectory: URL
    /// Roots under which an attachment's `mediaHandlePath` metadata is trusted (for example the
    /// ``MediaPipeline`` staging directory); other attachments are copied to ``scratchDirectory``.
    public var trustedHandleRoots: [URL]

    /// Creates a preprocessor.
    /// - Parameters:
    ///   - services: Services used for the conversions; defaults to ``MediaUnderstandingServices/platformDefault``.
    ///   - maxVideoFrames: Maximum frames per video (default 4).
    ///   - scratchDirectory: Directory for temporary files; defaults to `<tmp>/openclaw/media-understanding`.
    ///   - trustedHandleRoots: Roots whose staged files may be read in place.
    public init(
        services: MediaUnderstandingServices = .platformDefault,
        maxVideoFrames: Int = 4,
        scratchDirectory: URL? = nil,
        trustedHandleRoots: [URL] = []
    ) {
        self.services = services
        self.maxVideoFrames = Swift.max(0, maxVideoFrames)
        self.scratchDirectory = scratchDirectory
            ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("openclaw", isDirectory: true)
            .appendingPathComponent("media-understanding", isDirectory: true)
        self.trustedHandleRoots = trustedHandleRoots
    }

    /// Converts attachments according to `policy`.
    /// - Parameters:
    ///   - attachments: Attachments to process.
    ///   - policy: What the target model accepts.
    /// - Returns: Converted attachments plus notes and issues.
    public func process(
        _ attachments: [MediaAttachment],
        policy: MediaUnderstandingInputPolicy
    ) async -> MediaUnderstandingOutcome {
        guard policy.isEnabled, !attachments.isEmpty else {
            return MediaUnderstandingOutcome(attachments: attachments)
        }
        var outcome = MediaUnderstandingOutcome(attachments: [])
        var ordinals: [MediaKind: Int] = [:]
        for attachment in attachments {
            let kind = MediaPipeline.classify(mimeType: attachment.mimeType)
            ordinals[kind, default: 0] += 1
            let ordinal = ordinals[kind] ?? 1
            switch kind {
            case .image where policy.wantsImageText:
                await self.processImage(attachment, ordinal: ordinal, policy: policy, into: &outcome)
            case .video where policy.wantsVideoUnderstanding:
                await self.processVideo(attachment, ordinal: ordinal, policy: policy, into: &outcome)
            case .audio where policy.wantsTranscription:
                await self.processAudio(attachment, ordinal: ordinal, policy: policy, into: &outcome)
            default:
                outcome.attachments.append(attachment)
            }
        }
        return outcome
    }

    private func processImage(
        _ attachment: MediaAttachment,
        ordinal: Int,
        policy: MediaUnderstandingInputPolicy,
        into outcome: inout MediaUnderstandingOutcome
    ) async {
        let label = "image-\(ordinal)"
        guard let extractor = self.services.imageText else {
            outcome.issues.append("\(label): no image text recognizer is available on this platform")
            outcome.attachments.append(attachment)
            return
        }
        do {
            let result = try await extractor.extractText(from: attachment)
            let body = result.isEmpty ? "(no text or barcodes recognized)" : result.text
            if policy.acceptsImages {
                outcome.attachments.append(attachment)
            }
            outcome.attachments.append(
                Self.textAttachment("[\(label) text]:\n\(body)", derivedFrom: attachment, kind: "ocr", suffix: "ocr")
            )
            outcome.notes.append("\(label): recognized \(result.lines.count) text lines and \(result.barcodes.count) barcodes")
        } catch {
            outcome.issues.append("\(label): \(Self.describe(error))")
            outcome.attachments.append(attachment)
        }
    }

    private func processVideo(
        _ attachment: MediaAttachment,
        ordinal: Int,
        policy: MediaUnderstandingInputPolicy,
        into outcome: inout MediaUnderstandingOutcome
    ) async {
        let label = "video-\(ordinal)"
        guard let analyzer = self.services.video else {
            outcome.issues.append("\(label): no video analyzer is available on this platform")
            outcome.attachments.append(attachment)
            return
        }
        let name = Self.displayName(for: attachment)
        do {
            let file = try self.localFile(for: attachment, defaultExtension: "mp4")
            defer { file.cleanup() }
            let result = try await analyzer.analyze(
                videoAt: file.url,
                sourceAttachmentID: attachment.id,
                sourceName: name,
                maxFrames: policy.acceptsImages ? self.maxVideoFrames : 0
            )
            let summary = result.summaryLine(name: name)
            if policy.acceptsImages {
                outcome.attachments.append(contentsOf: result.frames)
            }
            outcome.attachments.append(
                Self.textAttachment("[\(label)]: \(summary)", derivedFrom: attachment, kind: "video-summary", suffix: "video")
            )
            outcome.notes.append("\(label): \(summary)")
        } catch {
            outcome.issues.append("\(label): \(Self.describe(error))")
            outcome.attachments.append(attachment)
        }
    }

    private func processAudio(
        _ attachment: MediaAttachment,
        ordinal: Int,
        policy: MediaUnderstandingInputPolicy,
        into outcome: inout MediaUnderstandingOutcome
    ) async {
        let label = "audio-\(ordinal)"
        guard let transcriber = self.services.audio else {
            outcome.issues.append("\(label): no speech transcriber is available on this platform")
            outcome.attachments.append(attachment)
            return
        }
        do {
            let file = try self.localFile(for: attachment, defaultExtension: "wav")
            defer { file.cleanup() }
            let result = try await transcriber.transcribe(audioAt: file.url, locale: policy.transcriptionLocale)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = text.isEmpty ? "(no speech recognized)" : text
            outcome.attachments.append(
                Self.textAttachment("[\(label) transcript]:\n\(body)", derivedFrom: attachment, kind: "transcript", suffix: "transcript")
            )
            outcome.notes.append("\(label): transcribed \(text.count) characters (\(result.locale))")
        } catch {
            outcome.issues.append("\(label): \(Self.describe(error))")
            outcome.attachments.append(attachment)
        }
    }

    /// Runs `body` with a readable local file for `attachment`: its staged `mediaHandlePath` when that
    /// file sits under ``trustedHandleRoots`` and matches the attachment size, otherwise a temporary copy
    /// in ``scratchDirectory`` that is removed when `body` returns.
    /// - Parameters:
    ///   - attachment: Attachment to materialize.
    ///   - defaultExtension: File extension used when neither the file name nor the MIME type gives one.
    ///   - body: Work to run with the file URL.
    /// - Returns: The value returned by `body`.
    public func withLocalFile<T>(
        for attachment: MediaAttachment,
        defaultExtension: String,
        _ body: (URL) async throws -> T
    ) async throws -> T {
        let file = try self.localFile(for: attachment, defaultExtension: defaultExtension)
        defer { file.cleanup() }
        return try await body(file.url)
    }

    // MARK: Helpers

    struct LocalFile {
        let url: URL
        let isTemporary: Bool

        func cleanup() {
            if self.isTemporary {
                try? FileManager.default.removeItem(at: self.url)
            }
        }
    }

    /// Returns a readable local file for an attachment: its staged handle when that sits under a trusted
    /// root and matches the attachment size, otherwise a temporary copy of the bytes.
    func localFile(for attachment: MediaAttachment, defaultExtension: String) throws -> LocalFile {
        if let path = attachment.metadata["mediaHandlePath"], !path.isEmpty {
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
            let isTrusted = self.trustedHandleRoots.contains { root in
                let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
                return url.path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
            }
            if isTrusted,
               let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               size == attachment.data.count
            {
                return LocalFile(url: url, isTemporary: false)
            }
        }
        try FileManager.default.createDirectory(at: self.scratchDirectory, withIntermediateDirectories: true)
        let ext = Self.fileExtension(for: attachment) ?? defaultExtension
        let url = self.scratchDirectory.appendingPathComponent("\(attachment.id.uuidString)-\(UUID().uuidString).\(ext)")
        try attachment.data.write(to: url, options: [.atomic])
        return LocalFile(url: url, isTemporary: true)
    }

    static func textAttachment(
        _ text: String,
        derivedFrom source: MediaAttachment,
        kind: String,
        suffix: String
    ) -> MediaAttachment {
        let baseName = URL(fileURLWithPath: Self.displayName(for: source)).deletingPathExtension().lastPathComponent
        var metadata: [String: String] = [
            MediaUnderstandingMetadataKey.kind: kind,
            MediaUnderstandingMetadataKey.sourceAttachmentID: source.id.uuidString,
        ]
        if let fileName = source.fileName {
            metadata[MediaUnderstandingMetadataKey.sourceFileName] = fileName
        }
        return MediaAttachment(
            mimeType: "text/plain",
            data: Data(text.utf8),
            fileName: "\(baseName).\(suffix).txt",
            metadata: metadata
        )
    }

    static func displayName(for attachment: MediaAttachment) -> String {
        let trimmed = attachment.fileName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "attachment-\(attachment.id.uuidString.prefix(8))" : trimmed
    }

    static func fileExtension(for attachment: MediaAttachment) -> String? {
        if let fileName = attachment.fileName {
            let ext = URL(fileURLWithPath: fileName).pathExtension.lowercased()
            if !ext.isEmpty, ext.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) {
                return ext
            }
        }
        let mimeType = attachment.mimeType
            .split(separator: ";", maxSplits: 1)
            .first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } ?? ""
        switch mimeType {
        case "video/mp4": return "mp4"
        case "video/quicktime": return "mov"
        case "video/x-m4v": return "m4v"
        case "audio/wav", "audio/x-wav", "audio/wave": return "wav"
        case "audio/mpeg", "audio/mp3": return "mp3"
        case "audio/mp4", "audio/x-m4a", "audio/m4a", "audio/aac": return "m4a"
        case "audio/aiff", "audio/x-aiff": return "aiff"
        case "audio/flac", "audio/x-flac": return "flac"
        case "audio/ogg": return "ogg"
        case "audio/caf", "audio/x-caf": return "caf"
        default: return nil
        }
    }

    static func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }
}
