import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import OpenClawKit

struct ChatImageHEICConversionTests {
    /// Encodes a synthetic HEIC photo with GPS metadata; `nil` where the platform has no HEIC encoder.
    private func syntheticHEIC(width: Int, height: Int) -> Data? {
        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.heic.identifier as CFString, 1, nil)
        else { return nil }
        let properties: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 48.85,
                kCGImagePropertyGPSLatitudeRef: "N",
            ] as CFDictionary,
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    @Test func `HEIC photos become capped metadata-free JPEGs`() throws {
        guard let heic = self.syntheticHEIC(width: 3024, height: 4032) else {
            // No HEIC encoder on this host (for example some CI simulators); nothing to verify.
            return
        }
        let output = try ChatImageProcessor.processForUpload(data: heic)
        #expect(OpenClawScreenSnapshotFormat(sniffing: output) == .jpeg)

        let source = try #require(CGImageSourceCreateWithData(output as CFData, nil))
        let type = try #require(CGImageSourceGetType(source) as String?)
        #expect(type == UTType.jpeg.identifier)
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let width = try #require((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue)
        let height = try #require((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue)
        #expect(max(width, height) <= ChatImageProcessor.maxLongEdgePx)
        #expect(height > width)
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
    }

    @Test func `long edge overload takes precedence over max width`() throws {
        let input = try makeNoiseJPEGFixture(width: 1200, height: 2400)
        let out = try JPEGTranscoder.transcodeToJPEG(
            imageData: input,
            maxWidthPx: 1000,
            maxLongEdgePx: 1600,
            quality: 0.8)
        #expect(out.heightPx == 1600)
        #expect(abs(out.widthPx - 800) <= 1)
    }
}
