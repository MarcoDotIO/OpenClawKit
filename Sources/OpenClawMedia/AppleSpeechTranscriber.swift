#if canImport(Speech) && canImport(AVFoundation) && !os(watchOS)
import AVFoundation
import CoreMedia
import Foundation
import Speech

/// On-device speech transcription of audio files with `SpeechAnalyzer` (iOS, macOS, tvOS and visionOS
/// 26; the Speech module does not exist on watchOS).
///
/// ``Engine/automatic`` uses `SpeechTranscriber` when the device supports it and otherwise falls back to
/// `DictationTranscriber` (long-dictation preset; not available on tvOS). Supported inputs are files
/// `AVAudioFile` can read (WAV, AIFF, CAF, M4A/AAC, MP3, FLAC); Ogg/Opus needs converting first.
///
/// Speech models are per-locale system assets: when they are missing, the transcriber downloads them
/// only if ``installMissingAssets`` is `true`, otherwise it throws
/// ``MediaUnderstandingError/unavailable(_:)``. Microphone/speech authorization is not needed for file
/// transcription and stays with the app (see the Skills speech connector).
public struct AppleSpeechTranscriber: AudioTranscribing {
    /// Speech module used for transcription.
    public enum Engine: String, Sendable, Equatable, CaseIterable {
        /// `SpeechTranscriber` when available, otherwise `DictationTranscriber`.
        case automatic
        /// Always `SpeechTranscriber` (general-purpose transcription).
        case transcriber
        /// Always `DictationTranscriber` (punctuated dictation; unavailable on tvOS).
        case dictation
    }

    /// Default recognition locale identifier; `nil` uses the current locale.
    public var locale: String?
    /// Whether missing speech assets may be downloaded and installed.
    public var installMissingAssets: Bool
    /// Speech module selection.
    public var engine: Engine

    /// Creates a transcriber.
    /// - Parameters:
    ///   - locale: Default BCP-47 locale; `nil` uses the current locale.
    ///   - installMissingAssets: Allow downloading missing speech assets.
    ///   - engine: Speech module selection.
    public init(locale: String? = nil, installMissingAssets: Bool = true, engine: Engine = .automatic) {
        self.locale = locale
        self.installMissingAssets = installMissingAssets
        self.engine = engine
    }

    /// Whether any speech module usable for file transcription is available on the running OS.
    public static var isSupported: Bool {
        guard #available(iOS 26.0, macOS 26.0, tvOS 26.0, visionOS 26.0, *) else {
            return false
        }
        #if os(tvOS)
        return SpeechTranscriber.isAvailable
        #else
        return true
        #endif
    }

    /// Locales `SpeechTranscriber` supports, as BCP-47 identifiers (empty before OS 26).
    /// - Returns: Supported locale identifiers.
    public static func supportedLocales() async -> [String] {
        guard #available(iOS 26.0, macOS 26.0, tvOS 26.0, visionOS 26.0, *) else {
            return []
        }
        return await SpeechTranscriber.supportedLocales.map { $0.identifier(.bcp47) }.sorted()
    }

    /// Locales whose `SpeechTranscriber` assets are installed, as BCP-47 identifiers (empty before OS 26).
    /// - Returns: Installed locale identifiers.
    public static func installedLocales() async -> [String] {
        guard #available(iOS 26.0, macOS 26.0, tvOS 26.0, visionOS 26.0, *) else {
            return []
        }
        return await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) }.sorted()
    }

    /// Transcribes a local audio file.
    /// - Parameters:
    ///   - url: Local audio file URL.
    ///   - locale: BCP-47 locale; `nil` uses ``locale`` or the current locale.
    /// - Returns: Transcript text and timed segments.
    /// - Throws: ``MediaUnderstandingError`` when the OS, locale, assets, or file are not usable.
    public func transcribe(audioAt url: URL, locale: String?) async throws -> AudioTranscriptionResult {
        guard #available(iOS 26.0, macOS 26.0, tvOS 26.0, visionOS 26.0, *) else {
            throw MediaUnderstandingError.unavailable("SpeechAnalyzer needs iOS, macOS, tvOS, or visionOS 26")
        }
        guard url.isFileURL else {
            throw MediaUnderstandingError.invalidAsset("speech transcription needs a local file URL")
        }
        let identifier = locale ?? self.locale ?? Locale.current.identifier
        let useTranscriber: Bool
        switch self.engine {
        case .transcriber:
            guard SpeechTranscriber.isAvailable else {
                throw MediaUnderstandingError.unavailable("SpeechTranscriber is not available on this device")
            }
            useTranscriber = true
        case .dictation:
            useTranscriber = false
        case .automatic:
            useTranscriber = SpeechTranscriber.isAvailable
        }
        do {
            if useTranscriber {
                return try await self.transcribeWithSpeechTranscriber(url: url, identifier: identifier)
            }
            #if os(tvOS)
            throw MediaUnderstandingError.unavailable("DictationTranscriber is not available on tvOS")
            #else
            return try await self.transcribeWithDictation(url: url, identifier: identifier)
            #endif
        } catch let error as MediaUnderstandingError {
            throw error
        } catch {
            throw MediaUnderstandingError.analysisFailed(String(describing: error))
        }
    }

    @available(iOS 26.0, macOS 26.0, tvOS 26.0, visionOS 26.0, *)
    private func transcribeWithSpeechTranscriber(url: URL, identifier: String) async throws -> AudioTranscriptionResult {
        guard let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier)) else {
            throw MediaUnderstandingError.unsupportedMedia("speech transcription does not support locale \(identifier)")
        }
        let module = SpeechTranscriber(locale: resolved, preset: .transcription)
        try await self.ensureAssets(for: module, locale: resolved)
        let analyzer = try await SpeechAnalyzer(inputAudioFile: try Self.openAudioFile(url), modules: [module], finishAfterFile: true)
        var collector = TranscriptCollector()
        for try await result in module.results {
            collector.append(text: result.text, range: result.range)
        }
        // The analyzer drives the module's results; keep it alive until they are drained.
        withExtendedLifetime(analyzer) {}
        return collector.result(locale: resolved)
    }

    #if !os(tvOS)
    @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
    private func transcribeWithDictation(url: URL, identifier: String) async throws -> AudioTranscriptionResult {
        guard let resolved = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier)) else {
            throw MediaUnderstandingError.unsupportedMedia("dictation does not support locale \(identifier)")
        }
        let module = DictationTranscriber(locale: resolved, preset: .timeIndexedLongDictation)
        try await self.ensureAssets(for: module, locale: resolved)
        let analyzer = try await SpeechAnalyzer(inputAudioFile: try Self.openAudioFile(url), modules: [module], finishAfterFile: true)
        var collector = TranscriptCollector()
        for try await result in module.results {
            collector.append(text: result.text, range: result.range)
        }
        withExtendedLifetime(analyzer) {}
        return collector.result(locale: resolved)
    }
    #endif

    @available(iOS 26.0, macOS 26.0, tvOS 26.0, visionOS 26.0, *)
    private func ensureAssets(for module: any SpeechModule, locale: Locale) async throws {
        let status = await AssetInventory.status(forModules: [module])
        switch status {
        case .installed:
            return
        case .unsupported:
            throw MediaUnderstandingError.unavailable("speech assets for \(locale.identifier(.bcp47)) are not supported on this device")
        default:
            guard self.installMissingAssets else {
                throw MediaUnderstandingError.unavailable(
                    "speech assets for \(locale.identifier(.bcp47)) are not installed; enable installMissingAssets to download them"
                )
            }
            do {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                    try await request.downloadAndInstall()
                }
            } catch {
                throw MediaUnderstandingError.unavailable("speech asset installation failed: \(error.localizedDescription)")
            }
        }
    }

    private static func openAudioFile(_ url: URL) throws -> AVAudioFile {
        do {
            return try AVAudioFile(forReading: url)
        } catch {
            throw MediaUnderstandingError.invalidAsset("AVAudioFile could not read \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }
}

/// Accumulates speech results into text and timed segments.
private struct TranscriptCollector {
    var text = ""
    var segments: [AudioTranscriptionSegment] = []

    mutating func append(text attributed: AttributedString, range: CMTimeRange) {
        let segmentText = String(attributed.characters)
        self.text += segmentText
        let trimmed = segmentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, let start = Self.seconds(range.start), let duration = Self.seconds(range.duration) {
            self.segments.append(AudioTranscriptionSegment(startSeconds: start, durationSeconds: duration, text: trimmed))
        }
    }

    func result(locale: Locale) -> AudioTranscriptionResult {
        AudioTranscriptionResult(
            text: self.text.trimmingCharacters(in: .whitespacesAndNewlines),
            locale: locale.identifier(.bcp47),
            segments: self.segments
        )
    }

    private static func seconds(_ time: CMTime) -> Double? {
        guard time.isNumeric else {
            return nil
        }
        let value = time.seconds
        return value.isFinite ? Swift.max(0, value) : nil
    }
}
#endif
