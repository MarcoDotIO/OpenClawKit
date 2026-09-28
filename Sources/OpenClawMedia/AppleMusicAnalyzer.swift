import Foundation

/// Music analyzer backed by MusicUnderstanding (`MusicUnderstandingSession`), available on every Apple
/// platform at version 27. Elsewhere (Linux, earlier OS versions) ``isSupported`` is `false` and
/// ``analyze(audioAt:analyses:)`` throws ``MediaUnderstandingError/unavailable(_:)``.
public struct AppleMusicAnalyzerService: MusicAnalyzing {
    /// Creates the analyzer.
    public init() {}

    /// Whether MusicUnderstanding is available on the running OS.
    public static var isSupported: Bool {
        #if compiler(>=6.4) && canImport(MusicUnderstanding) && canImport(AVFoundation)
        if #available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *) {
            return true
        }
        #endif
        return false
    }

    /// Analyzes a local audio file.
    /// - Parameters:
    ///   - url: Local audio file URL (any format AVFoundation reads).
    ///   - analyses: Analyses to run; empty runs all six.
    /// - Returns: Compact analysis summary.
    public func analyze(audioAt url: URL, analyses: Set<MusicAnalysisKind>) async throws -> MusicAnalysisSummary {
        #if compiler(>=6.4) && canImport(MusicUnderstanding) && canImport(AVFoundation)
        if #available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *) {
            return try await AppleMusicAnalyzer.analyze(url: url, analyses: analyses)
        }
        #endif
        throw MediaUnderstandingError.unavailable("MusicUnderstanding needs iOS, macOS, tvOS, watchOS, or visionOS 27")
    }
}

#if compiler(>=6.4) && canImport(MusicUnderstanding) && canImport(AVFoundation)
import AVFoundation
import CoreMedia
import MusicUnderstanding

/// MusicUnderstanding analysis (key, rhythm/BPM, structure, loudness, pace, instrument activity) turned
/// into a ``MusicAnalysisSummary`` with plain seconds.
///
/// Protected (DRM) content fails with ``MediaUnderstandingError/protectedContent``.
@available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
public enum AppleMusicAnalyzer {
    /// Analyzes a local audio file.
    /// - Parameters:
    ///   - url: Local audio file URL.
    ///   - analyses: Analyses to run; empty runs all six.
    /// - Returns: Compact analysis summary.
    /// - Throws: ``MediaUnderstandingError`` when the asset cannot be analyzed.
    public static func analyze(url: URL, analyses: Set<MusicAnalysisKind> = []) async throws -> MusicAnalysisSummary {
        guard url.isFileURL else {
            throw MediaUnderstandingError.invalidAsset("music analysis needs a local file URL")
        }
        let requested = analyses.isEmpty ? Set(MusicAnalysisKind.allCases) : analyses
        let asset = AVURLAsset(url: url)
        let result: MusicUnderstandingSession.SessionResult
        do {
            let session = try await MusicUnderstandingSession(asset: asset)
            result = try await session.analyze(for: Set(requested.map(Self.analysisType(for:))))
        } catch {
            throw Self.mapError(error)
        }
        let durationSeconds = (try? await asset.load(.duration)).flatMap(Self.seconds)
        return Self.summary(
            from: result,
            analyses: MusicAnalysisKind.allCases.filter(requested.contains),
            durationSeconds: durationSeconds
        )
    }

    /// Converts a MusicUnderstanding session result into a summary.
    /// - Parameters:
    ///   - result: Session result.
    ///   - analyses: Analyses that were requested.
    ///   - durationSeconds: Media duration in seconds.
    /// - Returns: Summary with times in seconds.
    public static func summary(
        from result: MusicUnderstandingSession.SessionResult,
        analyses: [MusicAnalysisKind],
        durationSeconds: Double?
    ) -> MusicAnalysisSummary {
        var summary = MusicAnalysisSummary(analyses: analyses, durationSeconds: durationSeconds)
        if let rhythm = result.rhythm {
            summary.beatsPerMinute = rhythm.beatsPerMinute.flatMap { $0.isFinite ? Double($0) : nil }
            summary.beatCount = rhythm.beats.count
            summary.barCount = rhythm.bars.count
        }
        if let key = result.key {
            summary.key = key.ranges.compactMap { entry in
                guard let range = Self.range(entry.range) else {
                    return nil
                }
                return MusicKeySegment(
                    startSeconds: range.startSeconds,
                    durationSeconds: range.durationSeconds,
                    tonic: MusicKeySegment.displayTonic(forRawValue: entry.value.tonic.rawValue),
                    mode: entry.value.mode.rawValue
                )
            }
        }
        if let structure = result.structure {
            summary.sections = structure.sections.compactMap(Self.range)
        }
        if let loudness = result.loudness {
            summary.integratedLoudness = loudness.integrated.value.isFinite ? Double(loudness.integrated.value) : nil
            summary.peakLoudness = loudness.peak.value.isFinite ? Double(loudness.peak.value) : nil
        }
        if let pace = result.pace {
            summary.pace = pace.ranges.compactMap { entry in
                guard let range = Self.range(entry.range), entry.value.isFinite else {
                    return nil
                }
                return MusicPaceSegment(startSeconds: range.startSeconds, durationSeconds: range.durationSeconds, value: entry.value)
            }
        }
        if let activity = result.instrumentActivity {
            var instruments: [String: [MediaTimeRange]] = [:]
            for (instrument, ranges) in activity.ranges {
                instruments[instrument.rawValue] = ranges.compactMap(Self.range).sorted { $0.startSeconds < $1.startSeconds }
            }
            summary.instruments = instruments
        }
        return summary
    }

    private static func analysisType(for kind: MusicAnalysisKind) -> AnalysisType {
        switch kind {
        case .instrumentActivity: return .instrumentActivity
        case .loudness: return .loudness
        case .pace: return .pace
        case .rhythm: return .rhythm
        case .structure: return .structure
        case .key: return .key
        }
    }

    private static func mapError(_ error: any Error) -> MediaUnderstandingError {
        if let error = error as? MediaUnderstandingError {
            return error
        }
        guard let error = error as? MusicUnderstandingError else {
            return .analysisFailed(String(describing: error))
        }
        switch error {
        case .hasProtectedContent:
            return .protectedContent
        case .invalidAsset:
            return .invalidAsset("MusicUnderstanding could not read the audio asset")
        case .emptyAnalysisSet:
            return .analysisFailed("no analyses were requested")
        case .sessionInProgress:
            return .analysisFailed("a music analysis session is already running")
        case .internalError:
            return .analysisFailed("MusicUnderstanding reported an internal error")
        @unknown default:
            return .analysisFailed(String(describing: error))
        }
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
}
#endif
