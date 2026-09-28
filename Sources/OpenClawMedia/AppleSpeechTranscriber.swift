#if canImport(Speech) && canImport(AVFoundation) && !os(watchOS)
import AVFoundation
import CoreMedia
import Foundation
import Speech

/// On-device speech transcription of audio files with `SpeechAnalyzer` + `SpeechTranscriber`
/// (iOS, macOS, tvOS and visionOS 26; the Speech module does not exist on watchOS).
///
/// Supported inputs are files `AVAudioFile` can read (WAV, AIFF, CAF, M4A/AAC, MP3, FLAC); Ogg/Opus
/// needs converting first. Speech models are per-locale system assets: when they are missing, the
/// transcriber downloads them only if ``installMissingAssets`` is `true`, otherwise it throws
/// ``MediaUnderstandingError/unavailable(_:)``. Microphone/speech authorization is not needed for file
/// transcription and stays with the app (see the Skills speech connector).
public struct AppleSpeechTranscriber: AudioTranscribing {
    /// Default recognition locale identifier; `nil` uses the current locale.
    public var locale: String?
    /// Whether missing speech assets may be downloaded and installed.
    public var installMissingAssets: Bool

    /// Creates a transcriber.
    /// - Parameters:
    ///   - locale: Default BCP-47 locale; `nil` uses the current locale.
    ///   - installMissingAssets: Allow downloading missing speech assets.
    public init(locale: String? = nil, installMissingAssets: Bool = true) {
        self.locale = locale
        self.installMissingAssets = installMissingAssets
    }

    /// Whether `SpeechTranscriber` is available on the running OS and device.
    public static var isSupported: Bool {
        if #available(iOS 26.0, macOS 26.0, tvOS 26.0, visionOS 26.0, *) {
            return SpeechTranscriber.isAvailable
        }
        return false
    }

    /// Locales `SpeechTranscriber` supports, as BCP-47 identifiers (empty before OS 26).
    /// - Returns: Supported locale identifiers.
    public static func supportedLocales() async -> [String] {
        guard #available(iOS 26.0, macOS 26.0, tvOS 26.0, visionOS 26.0, *) else {
            return []
        }
        return await SpeechTranscriber.supportedLocales.map { $0.identifier(.bcp47) }.sorted()
    }

    /// Locales whose speech assets are installed, as BCP-47 identifiers (empty before OS 26).
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
            throw MediaUnderstandingError.unavailable("SpeechTranscriber needs iOS, macOS, tvOS, or visionOS 26")
        }
        guard url.isFileURL else {
            throw MediaUnderstandingError.invalidAsset("speech transcription needs a local file URL")
        }
        guard SpeechTranscriber.isAvailable else {
            throw MediaUnderstandingError.unavailable("SpeechTranscriber is not available on this device")
        }
        let identifier = locale ?? self.locale ?? Locale.current.identifier
        guard let resolvedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier)) else {
            throw MediaUnderstandingError.unsupportedMedia("speech transcription does not support locale \(identifier)")
        }
        let transcriber = SpeechTranscriber(locale: resolvedLocale, preset: .transcription)
        try await self.ensureAssets(for: transcriber, locale: resolvedLocale)

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            throw MediaUnderstandingError.invalidAsset("AVAudioFile could not read \(url.lastPathComponent): \(error.localizedDescription)")
        }
        do {
            let analyzer = try await SpeechAnalyzer(inputAudioFile: audioFile, modules: [transcriber], finishAfterFile: true)
            var text = ""
            var segments: [AudioTranscriptionSegment] = []
            for try await result in transcriber.results {
                let segmentText = String(result.text.characters)
                text += segmentText
                let trimmed = segmentText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, let start = Self.seconds(result.range.start), let duration = Self.seconds(result.range.duration) {
                    segments.append(AudioTranscriptionSegment(startSeconds: start, durationSeconds: duration, text: trimmed))
                }
            }
            // The analyzer drives the module's results; keep it alive until they are drained.
            withExtendedLifetime(analyzer) {}
            return AudioTranscriptionResult(
                text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                locale: resolvedLocale.identifier(.bcp47),
                segments: segments
            )
        } catch let error as MediaUnderstandingError {
            throw error
        } catch {
            throw MediaUnderstandingError.analysisFailed(String(describing: error))
        }
    }

    @available(iOS 26.0, macOS 26.0, tvOS 26.0, visionOS 26.0, *)
    private func ensureAssets(for transcriber: SpeechTranscriber, locale: Locale) async throws {
        let status = await AssetInventory.status(forModules: [transcriber])
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
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    try await request.downloadAndInstall()
                }
            } catch {
                throw MediaUnderstandingError.unavailable("speech asset installation failed: \(error.localizedDescription)")
            }
        }
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
