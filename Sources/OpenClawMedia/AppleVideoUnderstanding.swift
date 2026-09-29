import Foundation
import OpenClawProtocol

/// Video analyzer backed by MediaIntelligence (`VideoAnalyzer`, key-frame and highlight requests) and
/// AVFoundation frame extraction. Available on iOS, macOS, tvOS and visionOS 27; everywhere else
/// (watchOS, Linux, earlier OS versions) ``isSupported`` is `false` and ``analyze(videoAt:sourceAttachmentID:sourceName:maxFrames:)``
/// throws ``MediaUnderstandingError/unavailable(_:)``.
public struct AppleVideoUnderstandingAnalyzer: VideoUnderstandingAnalyzing {
    /// Creates the analyzer.
    public init() {}

    /// Whether MediaIntelligence video analysis is available on the running OS.
    public static var isSupported: Bool {
        #if compiler(>=6.4) && canImport(MediaIntelligence) && canImport(AVFoundation) && canImport(ImageIO) && !os(watchOS)
        if #available(iOS 27.0, macOS 27.0, tvOS 27.0, visionOS 27.0, *) {
            return true
        }
        #endif
        return false
    }

    /// Analyzes a local video file: key frame, highlights, and up to `maxFrames` JPEG frames.
    /// - Parameters:
    ///   - url: Local video file URL.
    ///   - sourceAttachmentID: Identifier stamped into frame metadata.
    ///   - sourceName: Display name used in frame file names.
    ///   - maxFrames: Maximum frames to extract.
    /// - Returns: The analysis result.
    public func analyze(
        videoAt url: URL,
        sourceAttachmentID: UUID?,
        sourceName: String?,
        maxFrames: Int
    ) async throws -> VideoUnderstandingResult {
        #if compiler(>=6.4) && canImport(MediaIntelligence) && canImport(AVFoundation) && canImport(ImageIO) && !os(watchOS)
        if #available(iOS 27.0, macOS 27.0, tvOS 27.0, visionOS 27.0, *) {
            return try await AppleVideoUnderstanding.analyze(
                videoAt: url,
                sourceAttachmentID: sourceAttachmentID,
                sourceName: sourceName,
                maxFrames: maxFrames
            )
        }
        #endif
        throw MediaUnderstandingError.unavailable("MediaIntelligence video analysis needs iOS, macOS, tvOS, or visionOS 27")
    }
}

#if compiler(>=6.4) && canImport(MediaIntelligence) && canImport(AVFoundation) && canImport(ImageIO) && !os(watchOS)
import AVFoundation
import CoreMedia
import ImageIO
import MediaIntelligence

/// MediaIntelligence video understanding: the key frame and highlight segments of a video, plus
/// representative JPEG frames for vision models that cannot read video.
///
/// Frames are the key frame plus the midpoints of the highest-level highlights (see
/// ``VideoFrameSelection``), extracted with `AVAssetImageGenerator` at up to ``maxFrameDimension``
/// pixels and encoded as JPEG at quality ``jpegQuality``.
@available(iOS 27.0, macOS 27.0, tvOS 27.0, visionOS 27.0, *)
public enum AppleVideoUnderstanding {
    /// Default maximum number of extracted frames.
    public static let defaultMaxFrames = 4
    /// Maximum width or height of an extracted frame, in pixels.
    public static let maxFrameDimension = 1536
    /// JPEG compression quality of extracted frames.
    public static let jpegQuality = 0.8

    /// Analyzes a staged video handle (`video/mp4`, `video/quicktime`, ...).
    /// - Parameters:
    ///   - handle: Staged media handle from ``MediaPipeline``.
    ///   - maxFrames: Maximum frames to extract.
    /// - Returns: Key frame, highlights, and frames.
    /// - Throws: ``MediaUnderstandingError`` for non-video handles and analysis failures.
    public static func analyze(_ handle: MediaHandle, maxFrames: Int = AppleVideoUnderstanding.defaultMaxFrames) async throws -> VideoUnderstandingResult {
        guard handle.kind == .video else {
            throw MediaUnderstandingError.unsupportedMedia("expected a video, got \(handle.mimeType)")
        }
        return try await Self.analyze(
            videoAt: handle.storageURL,
            sourceAttachmentID: handle.id,
            sourceName: handle.fileName,
            maxFrames: maxFrames
        )
    }

    /// Analyzes a local video file.
    /// - Parameters:
    ///   - url: Local video file URL.
    ///   - sourceAttachmentID: Identifier stamped into frame metadata.
    ///   - sourceName: Display name used in frame file names.
    ///   - maxFrames: Maximum frames to extract; `0` skips frame extraction.
    /// - Returns: Key frame, highlights, and frames.
    /// - Throws: ``MediaUnderstandingError`` when the analysis fails.
    public static func analyze(
        videoAt url: URL,
        sourceAttachmentID: UUID? = nil,
        sourceName: String? = nil,
        maxFrames: Int = AppleVideoUnderstanding.defaultMaxFrames
    ) async throws -> VideoUnderstandingResult {
        guard url.isFileURL else {
            throw MediaUnderstandingError.invalidAsset("video analysis needs a local file URL")
        }
        let asset = MediaIntelligenceVideoAsset(
            id: MediaIntelligenceVideoAsset.ID(sourceAttachmentID?.uuidString ?? UUID().uuidString),
            kind: .url(url)
        )
        let keyFrameOutcome: Result<KeyFrameAnalysisRequest.Result, any Error>
        let highlightOutcome: Result<HighlightAnalysisRequest.Result, any Error>
        do {
            (keyFrameOutcome, highlightOutcome) = try await VideoAnalyzer.shared.analyze(
                asset,
                for: KeyFrameAnalysisRequest(),
                HighlightAnalysisRequest()
            )
        } catch {
            throw Self.mapError(error)
        }
        let keyFrame = try? keyFrameOutcome.get()
        let highlightResult = try? highlightOutcome.get()
        if keyFrame == nil, highlightResult == nil, case .failure(let error) = keyFrameOutcome {
            throw Self.mapError(error)
        }
        let highlights = highlightResult.map(Self.highlights(from:)) ?? []
        let keyFrameSeconds = keyFrame.flatMap { Self.seconds($0.timestamp) }

        let videoAsset = AVURLAsset(url: url)
        let durationSeconds = (try? await videoAsset.load(.duration)).flatMap(Self.seconds)
        let timestamps = VideoFrameSelection.timestamps(
            keyFrameSeconds: keyFrameSeconds,
            highlights: highlights,
            durationSeconds: durationSeconds,
            maxFrames: maxFrames
        )
        let frames = await Self.extractFrames(
            from: videoAsset,
            at: timestamps,
            sourceAttachmentID: sourceAttachmentID,
            sourceName: sourceName
        )
        return VideoUnderstandingResult(
            sourceAttachmentID: sourceAttachmentID,
            sourceName: sourceName,
            durationSeconds: durationSeconds,
            keyFrameSeconds: keyFrameSeconds,
            highlights: highlights,
            frames: frames
        )
    }

    /// Highlight segments with the strongest overlapping level, in chronological order.
    static func highlights(from result: HighlightAnalysisRequest.Result) -> [VideoHighlight] {
        let levels: [(range: MediaTimeRange, level: Double)] = result.levels.compactMap { entry in
            guard let range = Self.range(entry.timeRange), entry.level.isFinite else {
                return nil
            }
            return (range, Double(entry.level))
        }
        let highlights = result.highlights.compactMap { timeRange -> VideoHighlight? in
            guard let range = Self.range(timeRange) else {
                return nil
            }
            let level = levels.filter { $0.range.overlaps(range) }.map(\.level).max()
            return VideoHighlight(startSeconds: range.startSeconds, durationSeconds: range.durationSeconds, level: level)
        }
        return highlights.sorted { $0.startSeconds < $1.startSeconds }
    }

    private static func extractFrames(
        from asset: AVURLAsset,
        at timestamps: [Double],
        sourceAttachmentID: UUID?,
        sourceName: String?
    ) async -> [MediaAttachment] {
        guard !timestamps.isEmpty else {
            return []
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: Self.maxFrameDimension, height: Self.maxFrameDimension)
        let tolerance = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        let baseName = sourceName
            .map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
            .flatMap { $0.isEmpty ? nil : $0 } ?? "video"
        var frames: [MediaAttachment] = []
        for timestamp in timestamps {
            guard let (image, actualTime) = try? await generator.image(at: CMTime(seconds: timestamp, preferredTimescale: 600)),
                  let jpeg = Self.jpegData(from: image)
            else {
                continue
            }
            let frameSeconds = Self.seconds(actualTime) ?? timestamp
            let milliseconds = Int64((frameSeconds * 1000).rounded())
            var metadata: [String: String] = [
                MediaUnderstandingMetadataKey.kind: "video-frame",
                MediaUnderstandingMetadataKey.timestampSeconds: String(frameSeconds),
            ]
            if let sourceAttachmentID {
                metadata[MediaUnderstandingMetadataKey.sourceAttachmentID] = sourceAttachmentID.uuidString
            }
            if let sourceName {
                metadata[MediaUnderstandingMetadataKey.sourceFileName] = sourceName
            }
            frames.append(
                MediaAttachment(
                    mimeType: "image/jpeg",
                    data: jpeg,
                    fileName: "\(baseName)-frame-\(milliseconds)ms.jpg",
                    metadata: metadata
                )
            )
        }
        return frames
    }

    private static func jpegData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        let options = [kCGImageDestinationLossyCompressionQuality: Self.jpegQuality] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return data as Data
    }

    private static func seconds(_ time: CMTime) -> Double? {
        guard time.isNumeric else {
            return nil
        }
        let value = time.seconds
        return value.isFinite ? Swift.max(0, value) : nil
    }

    private static func range(_ timeRange: CMTimeRange) -> MediaTimeRange? {
        guard let start = Self.seconds(timeRange.start), let duration = Self.seconds(timeRange.duration) else {
            return nil
        }
        return MediaTimeRange(startSeconds: start, durationSeconds: duration)
    }

    private static func mapError(_ error: any Error) -> MediaUnderstandingError {
        if let error = error as? MediaUnderstandingError {
            return error
        }
        if let error = error as? MediaIntelligenceError {
            return .analysisFailed(error.errorDescription ?? String(describing: error))
        }
        return .analysisFailed(String(describing: error))
    }
}
#endif
