#if canImport(Vision)
import Foundation
import OpenClawProtocol
import Vision

/// On-device OCR and barcode extraction with the Swift Vision API, used to turn images into text for
/// models without image input (see ``MediaUnderstandingPreprocessor``).
///
/// Platform support:
/// - Text recognition (`RecognizeTextRequest`): iOS 18, macOS 15, tvOS 18, visionOS 2. Not watchOS.
/// - Barcodes (`DetectBarcodesRequest`): iOS 18, macOS 15, tvOS 18, visionOS 2, and watchOS 27.
///
/// On watchOS 27 only barcodes are extracted; earlier OS versions throw
/// ``MediaUnderstandingError/unavailable(_:)``.
public struct AppleImageTextExtractor: ImageTextExtracting {
    /// Text recognition quality/speed trade-off.
    public enum RecognitionLevel: String, Sendable, Equatable, CaseIterable {
        /// Slower, more accurate recognition (default).
        case accurate
        /// Faster, less accurate recognition.
        case fast
    }

    /// Text recognition level.
    public var recognitionLevel: RecognitionLevel
    /// Whether Vision applies language correction to recognized text.
    public var usesLanguageCorrection: Bool
    /// Preferred recognition languages as BCP-47 identifiers; empty lets Vision detect the language.
    public var recognitionLanguages: [String]
    /// Whether barcodes are decoded in addition to text.
    public var detectsBarcodes: Bool

    /// Creates an extractor.
    /// - Parameters:
    ///   - recognitionLevel: Text recognition level.
    ///   - usesLanguageCorrection: Apply language correction.
    ///   - recognitionLanguages: Preferred BCP-47 languages; empty detects automatically.
    ///   - detectsBarcodes: Decode barcodes too.
    public init(
        recognitionLevel: RecognitionLevel = .accurate,
        usesLanguageCorrection: Bool = true,
        recognitionLanguages: [String] = [],
        detectsBarcodes: Bool = true
    ) {
        self.recognitionLevel = recognitionLevel
        self.usesLanguageCorrection = usesLanguageCorrection
        self.recognitionLanguages = recognitionLanguages
        self.detectsBarcodes = detectsBarcodes
    }

    /// Whether text recognition is available on the running OS.
    public static var supportsTextRecognition: Bool {
        #if os(watchOS)
        return false
        #else
        if #available(iOS 18.0, macOS 15.0, tvOS 18.0, visionOS 2.0, *) {
            return true
        }
        return false
        #endif
    }

    /// Whether barcode detection is available on the running OS.
    public static var supportsBarcodeDetection: Bool {
        #if os(watchOS)
        #if compiler(>=6.4)
        if #available(watchOS 27.0, *) {
            return true
        }
        #endif
        return false
        #else
        return Self.supportsTextRecognition
        #endif
    }

    /// Whether any extraction is available on the running OS.
    public static var isSupported: Bool {
        Self.supportsTextRecognition || Self.supportsBarcodeDetection
    }

    /// Extracts text lines and barcodes from an image attachment.
    /// - Parameter attachment: Image attachment.
    /// - Returns: Recognized lines and barcodes.
    /// - Throws: ``MediaUnderstandingError`` when the input is not an image or Vision is unavailable.
    public func extractText(from attachment: MediaAttachment) async throws -> ImageTextExtractionResult {
        guard MediaPipeline.classify(mimeType: attachment.mimeType) == .image else {
            throw MediaUnderstandingError.unsupportedMedia("expected an image, got \(attachment.mimeType)")
        }
        guard Self.isSupported else {
            throw MediaUnderstandingError.unavailable("Vision text recognition needs iOS 18, macOS 15, tvOS 18, visionOS 2, or watchOS 27")
        }
        var result = ImageTextExtractionResult()
        do {
            result.lines = try await self.recognizeText(in: attachment.data)
            if self.detectsBarcodes {
                result.barcodes = try await Self.detectBarcodes(in: attachment.data)
            }
        } catch let error as MediaUnderstandingError {
            throw error
        } catch {
            throw MediaUnderstandingError.analysisFailed(String(describing: error))
        }
        return result
    }

    private func recognizeText(in data: Data) async throws -> [String] {
        #if os(watchOS)
        return []
        #else
        guard #available(iOS 18.0, macOS 15.0, tvOS 18.0, visionOS 2.0, *) else {
            return []
        }
        var request = RecognizeTextRequest()
        request.recognitionLevel = self.recognitionLevel == .fast ? .fast : .accurate
        request.usesLanguageCorrection = self.usesLanguageCorrection
        let languages = self.recognitionLanguages
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !languages.isEmpty {
            request.recognitionLanguages = languages.map { Locale.Language(identifier: $0) }
            request.automaticallyDetectsLanguage = false
        }
        let observations = try await request.perform(on: data)
        return observations.compactMap { observation in
            let text = observation.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty ? nil : text
        }
        #endif
    }

    private static func detectBarcodes(in data: Data) async throws -> [ImageBarcode] {
        #if os(watchOS)
        #if compiler(>=6.4)
        if #available(watchOS 27.0, *) {
            return try await Self.performBarcodeRequest(on: data)
        }
        #endif
        return []
        #else
        if #available(iOS 18.0, macOS 15.0, tvOS 18.0, visionOS 2.0, *) {
            return try await Self.performBarcodeRequest(on: data)
        }
        return []
        #endif
    }

    #if !os(watchOS) || compiler(>=6.4)
    @available(iOS 18.0, macOS 15.0, tvOS 18.0, visionOS 2.0, watchOS 27.0, *)
    private static func performBarcodeRequest(on data: Data) async throws -> [ImageBarcode] {
        let observations = try await DetectBarcodesRequest().perform(on: data)
        var seen = Set<String>()
        var barcodes: [ImageBarcode] = []
        for observation in observations {
            guard let payload = observation.payloadString, !payload.isEmpty else {
                continue
            }
            let symbology = String(describing: observation.symbology)
            if seen.insert("\(symbology):\(payload)").inserted {
                barcodes.append(ImageBarcode(payload: payload, symbology: symbology))
            }
        }
        return barcodes
    }
    #endif
}
#endif
