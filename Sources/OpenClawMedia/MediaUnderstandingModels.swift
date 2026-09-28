import Foundation
import OpenClawProtocol

// Cross-platform value types for on-device media understanding (video key frames and highlights,
// music analysis, speech transcription, image text extraction). The Apple framework adapters
// (MediaIntelligence, MusicUnderstanding, Speech, Vision) live in the `Apple*` files and compile out
// on Linux; these types, the service protocols, and the preprocessor are available everywhere.

// MARK: - Time ranges

/// Time range in seconds used by media-understanding results.
public struct MediaTimeRange: Codable, Sendable, Equatable, Hashable {
    /// Range start, in seconds from the beginning of the media.
    public var startSeconds: Double
    /// Range duration, in seconds.
    public var durationSeconds: Double

    /// Creates a time range; negative or non-finite values are clamped to `0`.
    /// - Parameters:
    ///   - startSeconds: Range start in seconds.
    ///   - durationSeconds: Range duration in seconds.
    public init(startSeconds: Double, durationSeconds: Double) {
        self.startSeconds = Self.sanitized(startSeconds)
        self.durationSeconds = Self.sanitized(durationSeconds)
    }

    /// Range end, in seconds.
    public var endSeconds: Double {
        self.startSeconds + self.durationSeconds
    }

    /// Range midpoint, in seconds.
    public var midpointSeconds: Double {
        self.startSeconds + self.durationSeconds / 2
    }

    /// Returns whether two ranges share any time; an empty range overlaps a range that contains its start.
    /// - Parameter other: Range to compare with.
    /// - Returns: `true` when the ranges intersect.
    public func overlaps(_ other: MediaTimeRange) -> Bool {
        if self.durationSeconds == 0 {
            return other.startSeconds <= self.startSeconds && self.startSeconds <= other.endSeconds
        }
        if other.durationSeconds == 0 {
            return self.startSeconds <= other.startSeconds && other.startSeconds <= self.endSeconds
        }
        return self.startSeconds < other.endSeconds && other.startSeconds < self.endSeconds
    }

    static func sanitized(_ value: Double) -> Double {
        value.isFinite ? Swift.max(0, value) : 0
    }
}

/// Formats seconds for prompt text (`"3.2s"`, one decimal place).
enum MediaSecondsFormatter {
    static func format(_ seconds: Double) -> String {
        let tenths = (seconds * 10).rounded() / 10
        // Int is 32-bit on watchOS arm64_32; only take the integer path for small values.
        if tenths == tenths.rounded(), abs(tenths) < 1_000_000 {
            return "\(Int(tenths))s"
        }
        return "\(tenths)s"
    }

    static func format(_ range: MediaTimeRange) -> String {
        "\(Self.format(range.startSeconds))-\(Self.format(range.endSeconds))"
    }
}

// MARK: - Video understanding

/// One highlight segment reported by video analysis.
public struct VideoHighlight: Codable, Sendable, Equatable {
    /// Highlight start, in seconds.
    public var startSeconds: Double
    /// Highlight duration, in seconds.
    public var durationSeconds: Double
    /// Highlight level in `0...1` (higher is more interesting), when the analyzer reports one.
    public var level: Double?

    /// Creates a highlight segment.
    /// - Parameters:
    ///   - startSeconds: Highlight start in seconds.
    ///   - durationSeconds: Highlight duration in seconds.
    ///   - level: Optional highlight level.
    public init(startSeconds: Double, durationSeconds: Double, level: Double? = nil) {
        let range = MediaTimeRange(startSeconds: startSeconds, durationSeconds: durationSeconds)
        self.startSeconds = range.startSeconds
        self.durationSeconds = range.durationSeconds
        self.level = level.flatMap { $0.isFinite ? $0 : nil }
    }

    /// Highlight time range.
    public var range: MediaTimeRange {
        MediaTimeRange(startSeconds: self.startSeconds, durationSeconds: self.durationSeconds)
    }
}

/// Result of analyzing one video: key frame, highlights, and extracted frame attachments.
///
/// Frames are JPEG ``MediaAttachment`` values whose metadata carries `sourceAttachmentID`,
/// `timestampSeconds` and `mediaUnderstanding = "video-frame"`, so image-capable models that cannot
/// read video still see representative frames.
public struct VideoUnderstandingResult: Codable, Sendable, Equatable {
    /// Identifier of the source video attachment, when known.
    public var sourceAttachmentID: UUID?
    /// Display name of the source video, when known.
    public var sourceName: String?
    /// Video duration in seconds, when known.
    public var durationSeconds: Double?
    /// Timestamp of the representative key frame, in seconds.
    public var keyFrameSeconds: Double?
    /// Highlight segments in chronological order.
    public var highlights: [VideoHighlight]
    /// Extracted JPEG frames in chronological order.
    public var frames: [MediaAttachment]

    /// Creates a video understanding result.
    /// - Parameters:
    ///   - sourceAttachmentID: Source attachment identifier.
    ///   - sourceName: Source display name.
    ///   - durationSeconds: Video duration in seconds.
    ///   - keyFrameSeconds: Key frame timestamp in seconds.
    ///   - highlights: Highlight segments.
    ///   - frames: Extracted frame attachments.
    public init(
        sourceAttachmentID: UUID? = nil,
        sourceName: String? = nil,
        durationSeconds: Double? = nil,
        keyFrameSeconds: Double? = nil,
        highlights: [VideoHighlight] = [],
        frames: [MediaAttachment] = []
    ) {
        self.sourceAttachmentID = sourceAttachmentID
        self.sourceName = sourceName
        self.durationSeconds = durationSeconds
        self.keyFrameSeconds = keyFrameSeconds
        self.highlights = highlights
        self.frames = frames
    }

    /// Frame timestamps in seconds, read from the frames' `timestampSeconds` metadata.
    public var frameTimestamps: [Double] {
        self.frames.compactMap { $0.metadata[MediaUnderstandingMetadataKey.timestampSeconds].flatMap(Double.init) }
    }

    /// One-line description for prompt text, for example
    /// `Video clip.mov (16s): key frame at 3.2s; highlights 1s-4.5s (level 0.8); frames at 1s, 3.2s`.
    /// - Parameter name: Display name; defaults to ``sourceName`` or `video`.
    /// - Returns: A single summary line.
    public func summaryLine(name: String? = nil) -> String {
        let displayName = name ?? self.sourceName ?? "video"
        var header = "Video \(displayName)"
        if let durationSeconds {
            header += " (\(MediaSecondsFormatter.format(durationSeconds)))"
        }
        var parts: [String] = []
        if let keyFrameSeconds {
            parts.append("key frame at \(MediaSecondsFormatter.format(keyFrameSeconds))")
        }
        if self.highlights.isEmpty {
            parts.append("no highlights")
        } else {
            let rendered = self.highlights.map { highlight -> String in
                var text = MediaSecondsFormatter.format(highlight.range)
                if let level = highlight.level {
                    text += " (level \(Self.formatLevel(level)))"
                }
                return text
            }
            parts.append("highlights " + rendered.joined(separator: ", "))
        }
        let timestamps = self.frameTimestamps
        if !timestamps.isEmpty {
            parts.append("frames at " + timestamps.map(MediaSecondsFormatter.format).joined(separator: ", "))
        }
        return header + ": " + parts.joined(separator: "; ")
    }

    private static func formatLevel(_ level: Double) -> String {
        let hundredths = (level * 100).rounded() / 100
        return "\(hundredths)"
    }
}

/// Chooses which video timestamps to extract as frames.
public enum VideoFrameSelection {
    /// Default minimum spacing between two selected frames, in seconds.
    public static let defaultMinimumSpacingSeconds = 0.5

    /// Selects frame timestamps: the key frame first, then the midpoints of the highlights with the
    /// highest level, skipping candidates closer than `minimumSpacing` to an already selected one.
    ///
    /// When there is neither a key frame nor a highlight and the duration is known, the midpoint of the
    /// video is used so the model still sees one frame. Timestamps are clamped into the video duration.
    /// - Parameters:
    ///   - keyFrameSeconds: Key frame timestamp in seconds.
    ///   - highlights: Highlight segments in any order.
    ///   - durationSeconds: Video duration in seconds, when known.
    ///   - maxFrames: Maximum number of frames; `0` or less selects none.
    ///   - minimumSpacing: Minimum spacing between selected timestamps, in seconds.
    /// - Returns: Selected timestamps in ascending order.
    public static func timestamps(
        keyFrameSeconds: Double?,
        highlights: [VideoHighlight],
        durationSeconds: Double?,
        maxFrames: Int,
        minimumSpacing: Double = VideoFrameSelection.defaultMinimumSpacingSeconds
    ) -> [Double] {
        guard maxFrames > 0 else {
            return []
        }
        let duration = durationSeconds.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        var candidates: [Double] = []
        if let keyFrameSeconds, keyFrameSeconds.isFinite {
            candidates.append(keyFrameSeconds)
        }
        let ranked = highlights.enumerated().sorted { lhs, rhs in
            let lhsLevel = lhs.element.level ?? 0
            let rhsLevel = rhs.element.level ?? 0
            if lhsLevel != rhsLevel {
                return lhsLevel > rhsLevel
            }
            return lhs.offset < rhs.offset
        }
        candidates.append(contentsOf: ranked.map { $0.element.range.midpointSeconds })
        if candidates.isEmpty, let duration {
            candidates.append(duration / 2)
        }

        let spacing = minimumSpacing.isFinite ? Swift.max(0, minimumSpacing) : 0
        var selected: [Double] = []
        for candidate in candidates {
            let clamped = Self.clamp(candidate, duration: duration)
            if selected.contains(where: { abs($0 - clamped) < spacing || $0 == clamped }) {
                continue
            }
            selected.append(clamped)
            if selected.count == maxFrames {
                break
            }
        }
        return selected.sorted()
    }

    private static func clamp(_ seconds: Double, duration: Double?) -> Double {
        let nonNegative = Swift.max(0, seconds)
        guard let duration else {
            return nonNegative
        }
        // Stay slightly inside the last frame so image generators can decode it.
        return Swift.min(nonNegative, Swift.max(0, duration - 0.05))
    }
}

// MARK: - Music analysis

/// Music analyses supported by ``MusicAnalyzing`` implementations (MusicUnderstanding `AnalysisType`).
public enum MusicAnalysisKind: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    /// Per-instrument activity (vocal, drum, bass, other).
    case instrumentActivity
    /// Integrated, peak, momentary and short-term loudness.
    case loudness
    /// Pace over time.
    case pace
    /// Beats, bars, and tempo (BPM).
    case rhythm
    /// Sections, segments, and phrases.
    case structure
    /// Musical key over time.
    case key

    /// Parses a user- or model-supplied analysis name, accepting common aliases
    /// (`instruments`, `bpm`, `tempo`, `beats`, `sections`, `tonality`, snake/kebab case).
    /// - Parameter value: Analysis name.
    public init?(normalizing value: String) {
        let compact = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
        switch compact {
        case "instrumentactivity", "instruments", "instrument":
            self = .instrumentActivity
        case "loudness", "volume", "lufs":
            self = .loudness
        case "pace":
            self = .pace
        case "rhythm", "bpm", "tempo", "beats", "bars":
            self = .rhythm
        case "structure", "sections", "segments", "phrases":
            self = .structure
        case "key", "keys", "tonality":
            self = .key
        default:
            return nil
        }
    }
}

/// One key-signature segment of a music analysis.
public struct MusicKeySegment: Codable, Sendable, Equatable {
    /// Segment start, in seconds.
    public var startSeconds: Double
    /// Segment duration, in seconds.
    public var durationSeconds: Double
    /// Tonic in musical notation (`C`, `C#`, `Db`, ...).
    public var tonic: String
    /// Mode (`major` or `minor`).
    public var mode: String

    /// Creates a key segment.
    /// - Parameters:
    ///   - startSeconds: Segment start in seconds.
    ///   - durationSeconds: Segment duration in seconds.
    ///   - tonic: Tonic in musical notation.
    ///   - mode: Mode name.
    public init(startSeconds: Double, durationSeconds: Double, tonic: String, mode: String) {
        let range = MediaTimeRange(startSeconds: startSeconds, durationSeconds: durationSeconds)
        self.startSeconds = range.startSeconds
        self.durationSeconds = range.durationSeconds
        self.tonic = tonic
        self.mode = mode
    }

    /// Key name, for example `D minor`.
    public var name: String {
        "\(self.tonic) \(self.mode)"
    }

    /// Converts a MusicUnderstanding tonic raw value (`a`, `aFlat`, `cSharp`, ...) to musical notation
    /// (`A`, `Ab`, `C#`); unknown values are returned unchanged.
    /// - Parameter rawValue: Framework tonic raw value.
    /// - Returns: Tonic in musical notation.
    public static func displayTonic(forRawValue rawValue: String) -> String {
        guard let letter = rawValue.first, "abcdefg".contains(letter) else {
            return rawValue
        }
        let accidental = rawValue.dropFirst().lowercased()
        switch accidental {
        case "":
            return letter.uppercased()
        case "sharp":
            return letter.uppercased() + "#"
        case "flat":
            return letter.uppercased() + "b"
        default:
            return rawValue
        }
    }
}

/// One pace segment of a music analysis.
public struct MusicPaceSegment: Codable, Sendable, Equatable {
    /// Segment start, in seconds.
    public var startSeconds: Double
    /// Segment duration, in seconds.
    public var durationSeconds: Double
    /// Pace value on the analyzer's own scale.
    public var value: Double

    /// Creates a pace segment.
    /// - Parameters:
    ///   - startSeconds: Segment start in seconds.
    ///   - durationSeconds: Segment duration in seconds.
    ///   - value: Pace value.
    public init(startSeconds: Double, durationSeconds: Double, value: Double) {
        let range = MediaTimeRange(startSeconds: startSeconds, durationSeconds: durationSeconds)
        self.startSeconds = range.startSeconds
        self.durationSeconds = range.durationSeconds
        self.value = value
    }
}

/// Compact, model-friendly music analysis (all times in seconds).
///
/// Built from MusicUnderstanding's `SessionResult`, whose default Codable form encodes every `CMTime`
/// as `{epoch, flags, timescale, value}`; this summary keeps plain seconds instead.
public struct MusicAnalysisSummary: Codable, Sendable, Equatable {
    /// Analyses that were requested.
    public var analyses: [MusicAnalysisKind]
    /// Media duration in seconds, when known.
    public var durationSeconds: Double?
    /// Tempo in beats per minute, when detected.
    public var beatsPerMinute: Double?
    /// Number of detected beats.
    public var beatCount: Int?
    /// Number of detected bars.
    public var barCount: Int?
    /// Key segments in chronological order.
    public var key: [MusicKeySegment]
    /// Structural sections in chronological order.
    public var sections: [MediaTimeRange]
    /// Integrated loudness (LUFS, as reported by the analyzer).
    public var integratedLoudness: Double?
    /// Peak momentary loudness (LUFS, as reported by the analyzer).
    public var peakLoudness: Double?
    /// Pace segments in chronological order.
    public var pace: [MusicPaceSegment]
    /// Active time ranges per instrument (`vocal`, `drum`, `bass`, `other`).
    public var instruments: [String: [MediaTimeRange]]

    /// Creates a music analysis summary.
    /// - Parameters:
    ///   - analyses: Requested analyses.
    ///   - durationSeconds: Media duration in seconds.
    ///   - beatsPerMinute: Tempo in BPM.
    ///   - beatCount: Number of beats.
    ///   - barCount: Number of bars.
    ///   - key: Key segments.
    ///   - sections: Structural sections.
    ///   - integratedLoudness: Integrated loudness.
    ///   - peakLoudness: Peak loudness.
    ///   - pace: Pace segments.
    ///   - instruments: Active ranges per instrument.
    public init(
        analyses: [MusicAnalysisKind] = [],
        durationSeconds: Double? = nil,
        beatsPerMinute: Double? = nil,
        beatCount: Int? = nil,
        barCount: Int? = nil,
        key: [MusicKeySegment] = [],
        sections: [MediaTimeRange] = [],
        integratedLoudness: Double? = nil,
        peakLoudness: Double? = nil,
        pace: [MusicPaceSegment] = [],
        instruments: [String: [MediaTimeRange]] = [:]
    ) {
        self.analyses = analyses
        self.durationSeconds = durationSeconds
        self.beatsPerMinute = beatsPerMinute
        self.beatCount = beatCount
        self.barCount = barCount
        self.key = key
        self.sections = sections
        self.integratedLoudness = integratedLoudness
        self.peakLoudness = peakLoudness
        self.pace = pace
        self.instruments = instruments
    }

    /// Key that covers the most time, when any key was detected.
    public var dominantKey: MusicKeySegment? {
        self.key.enumerated().max { lhs, rhs in
            if lhs.element.durationSeconds != rhs.element.durationSeconds {
                return lhs.element.durationSeconds < rhs.element.durationSeconds
            }
            return lhs.offset > rhs.offset
        }?.element
    }

    /// One-line description for prompt text, for example `Music: 58.8 BPM; key D minor; 1 section`.
    public var summaryLine: String {
        var parts: [String] = []
        if let beatsPerMinute {
            parts.append("\((beatsPerMinute * 10).rounded() / 10) BPM")
        }
        if let dominantKey {
            parts.append("key \(dominantKey.name)")
        }
        if !self.sections.isEmpty {
            parts.append("\(self.sections.count) section\(self.sections.count == 1 ? "" : "s")")
        }
        if let integratedLoudness {
            parts.append("integrated loudness \((integratedLoudness * 10).rounded() / 10) LUFS")
        }
        let activeInstruments = self.instruments.filter { !$0.value.isEmpty }.keys.sorted()
        if !activeInstruments.isEmpty {
            parts.append("instruments " + activeInstruments.joined(separator: ", "))
        }
        return "Music: " + (parts.isEmpty ? "no features detected" : parts.joined(separator: "; "))
    }
}

// MARK: - Speech transcription

/// One transcribed speech segment.
public struct AudioTranscriptionSegment: Codable, Sendable, Equatable {
    /// Segment start, in seconds.
    public var startSeconds: Double
    /// Segment duration, in seconds.
    public var durationSeconds: Double
    /// Segment text.
    public var text: String

    /// Creates a transcription segment.
    /// - Parameters:
    ///   - startSeconds: Segment start in seconds.
    ///   - durationSeconds: Segment duration in seconds.
    ///   - text: Segment text.
    public init(startSeconds: Double, durationSeconds: Double, text: String) {
        let range = MediaTimeRange(startSeconds: startSeconds, durationSeconds: durationSeconds)
        self.startSeconds = range.startSeconds
        self.durationSeconds = range.durationSeconds
        self.text = text
    }
}

/// Transcript of one audio input.
public struct AudioTranscriptionResult: Codable, Sendable, Equatable {
    /// Full transcript text.
    public var text: String
    /// BCP-47 identifier of the locale used for recognition.
    public var locale: String
    /// Timed segments, when the transcriber reports them.
    public var segments: [AudioTranscriptionSegment]

    /// Creates a transcription result.
    /// - Parameters:
    ///   - text: Transcript text.
    ///   - locale: Recognition locale identifier.
    ///   - segments: Timed segments.
    public init(text: String, locale: String, segments: [AudioTranscriptionSegment] = []) {
        self.text = text
        self.locale = locale
        self.segments = segments
    }
}

// MARK: - Image text extraction

/// Barcode payload found in an image.
public struct ImageBarcode: Codable, Sendable, Equatable {
    /// Decoded payload text.
    public var payload: String
    /// Symbology name (for example `QR`, `EAN13`), when known.
    public var symbology: String?

    /// Creates a barcode payload.
    /// - Parameters:
    ///   - payload: Decoded payload text.
    ///   - symbology: Symbology name.
    public init(payload: String, symbology: String? = nil) {
        self.payload = payload
        self.symbology = symbology
    }
}

/// Text and barcodes recognized in one image.
public struct ImageTextExtractionResult: Codable, Sendable, Equatable {
    /// Recognized text lines in reading order.
    public var lines: [String]
    /// Decoded barcodes.
    public var barcodes: [ImageBarcode]

    /// Creates an extraction result.
    /// - Parameters:
    ///   - lines: Recognized text lines.
    ///   - barcodes: Decoded barcodes.
    public init(lines: [String] = [], barcodes: [ImageBarcode] = []) {
        self.lines = lines
        self.barcodes = barcodes
    }

    /// Whether neither text nor barcodes were found.
    public var isEmpty: Bool {
        self.lines.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } && self.barcodes.isEmpty
    }

    /// Recognized text followed by one `barcode (<symbology>): <payload>` line per barcode.
    public var text: String {
        var output = self.lines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        for barcode in self.barcodes {
            if let symbology = barcode.symbology, !symbology.isEmpty {
                output.append("barcode (\(symbology)): \(barcode.payload)")
            } else {
                output.append("barcode: \(barcode.payload)")
            }
        }
        return output.joined(separator: "\n")
    }
}

// MARK: - Errors and metadata keys

/// Errors reported by media-understanding services.
public enum MediaUnderstandingError: Error, LocalizedError, Sendable, Equatable {
    /// The framework or OS version needed for this analysis is not available on this device.
    case unavailable(String)
    /// The input media kind or format is not supported by this analysis.
    case unsupportedMedia(String)
    /// The asset contains protected (DRM) content that cannot be analyzed.
    case protectedContent
    /// The asset could not be opened or decoded.
    case invalidAsset(String)
    /// The analysis ran but failed.
    case analysisFailed(String)

    /// Human-readable description.
    public var errorDescription: String? {
        switch self {
        case .unavailable(let detail):
            return "Media understanding is unavailable: \(detail)"
        case .unsupportedMedia(let detail):
            return "Unsupported media: \(detail)"
        case .protectedContent:
            return "The media contains protected content and cannot be analyzed"
        case .invalidAsset(let detail):
            return "The media could not be read: \(detail)"
        case .analysisFailed(let detail):
            return "Media analysis failed: \(detail)"
        }
    }
}

/// Metadata keys written on attachments derived by media understanding.
public enum MediaUnderstandingMetadataKey {
    /// Kind of derived attachment: `ocr`, `video-frame`, `video-summary`, or `transcript`.
    public static let kind = "mediaUnderstanding"
    /// UUID string of the attachment the derived attachment was produced from.
    public static let sourceAttachmentID = "sourceAttachmentID"
    /// File name of the source attachment.
    public static let sourceFileName = "sourceFileName"
    /// Frame timestamp in seconds (video frames).
    public static let timestampSeconds = "timestampSeconds"
}
