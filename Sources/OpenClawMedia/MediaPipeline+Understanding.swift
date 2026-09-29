import Foundation
import OpenClawProtocol

// Media-understanding hooks on the staged media pipeline. They live in an extension so the
// pipeline's staging code stays unchanged; files staged by the pipeline are read in place.

public extension MediaPipeline {
    /// Classifies a MIME type without actor hops (`image/*`, `audio/*`, `video/*`, `application/*` and
    /// `text/*` as document, everything else unknown).
    /// - Parameter mimeType: MIME type string; parameters after `;` are ignored.
    /// - Returns: Detected media kind.
    static func classify(mimeType: String) -> MediaKind {
        let normalized = mimeType
            .split(separator: ";", maxSplits: 1)
            .first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } ?? ""
        if normalized.hasPrefix("image/") { return .image }
        if normalized.hasPrefix("audio/") { return .audio }
        if normalized.hasPrefix("video/") { return .video }
        if normalized.hasPrefix("application/") || normalized.hasPrefix("text/") { return .document }
        return .unknown
    }

    /// Replaces video attachments with representative JPEG frames (key frame plus highlight midpoints)
    /// and a `text/plain` summary line, for image-capable models that cannot read video.
    ///
    /// Other attachments pass through unchanged, as do videos when no analyzer is available (for
    /// example on Linux, watchOS, or before iOS/macOS/tvOS/visionOS 27) or when analysis fails.
    /// - Parameters:
    ///   - attachments: Attachments to expand.
    ///   - maxFrames: Maximum frames per video (default 4).
    ///   - analyzer: Video analyzer; defaults to the platform's MediaIntelligence analyzer.
    /// - Returns: Expanded attachments.
    func expandVideoAttachments(
        _ attachments: [MediaAttachment],
        maxFrames: Int = 4,
        analyzer: (any VideoUnderstandingAnalyzing)? = MediaUnderstandingServices.platformDefault.video
    ) async -> [MediaAttachment] {
        let preprocessor = MediaUnderstandingPreprocessor(
            services: MediaUnderstandingServices(video: analyzer),
            maxVideoFrames: maxFrames,
            scratchDirectory: self.understandingScratchDirectory(),
            trustedHandleRoots: [self.stagingDirectory()]
        )
        let policy = MediaUnderstandingInputPolicy(acceptsImages: true, acceptsVideo: false, acceptsAudio: true)
        return await preprocessor.process(attachments, policy: policy).attachments
    }

    /// Converts attachments the target model cannot read (see ``MediaUnderstandingPreprocessor``).
    /// Files staged by this pipeline are read in place; other media is copied to a scratch directory
    /// next to the staging directory and removed afterwards.
    /// - Parameters:
    ///   - attachments: Attachments to convert.
    ///   - policy: What the target model accepts.
    ///   - services: Media-understanding services; defaults to the platform's on-device services.
    ///   - maxVideoFrames: Maximum frames per video (default 4).
    /// - Returns: Converted attachments with notes and issues.
    func applyMediaUnderstanding(
        _ attachments: [MediaAttachment],
        policy: MediaUnderstandingInputPolicy,
        services: MediaUnderstandingServices = .platformDefault,
        maxVideoFrames: Int = 4
    ) async -> MediaUnderstandingOutcome {
        let preprocessor = MediaUnderstandingPreprocessor(
            services: services,
            maxVideoFrames: maxVideoFrames,
            scratchDirectory: self.understandingScratchDirectory(),
            trustedHandleRoots: [self.stagingDirectory()]
        )
        return await preprocessor.process(attachments, policy: policy)
    }

    private func understandingScratchDirectory() -> URL {
        self.stagingDirectory()
            .deletingLastPathComponent()
            .appendingPathComponent("media-understanding", isDirectory: true)
    }
}
