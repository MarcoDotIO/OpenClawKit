// ChatUI views ship on iOS, macOS and visionOS. tvOS and watchOS get only the non-UI chat core.
//
// OS 27 building blocks for gateway-hosted media, for the transcript media and link-preview views:
// - `ChatAuthenticatedImage` loads an image through a `URLRequest` carrying the gateway HTTP authorization,
//   using `AsyncImage(request:)` + `asyncImageURLSession(_:)` on OS 27 and a manual download + decode before.
// `EnvironmentValues.openClawChatPrefersReducedResourceUsage` (TalkWaveformView.swift) bridges the OS 27
// `systemPrefersReducedResourceUsage` for throttling.
#if os(iOS) || os(macOS) || os(visionOS)
import Foundation
import ImageIO
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Loads an image from an authenticated gateway request.
///
/// Pass a request whose headers carry the gateway HTTP authorization, and a dedicated session (for example an
/// ephemeral one bound to the gateway's TLS pinning delegate). Only `http`/`https` requests load; anything else
/// shows the placeholder.
struct ChatAuthenticatedImage<Placeholder: View>: View {
    let request: URLRequest?
    let session: URLSession
    let maximumPixelSize: Int
    @ViewBuilder let placeholder: () -> Placeholder

    @State private var legacyImage: OpenClawPlatformImage?
    @State private var legacyFailed = false

    init(
        request: URLRequest?,
        session: URLSession = .shared,
        maximumPixelSize: Int = 2048,
        @ViewBuilder placeholder: @escaping () -> Placeholder)
    {
        self.request = request.map(Self.isLoadable) == true ? request : nil
        self.session = session
        self.maximumPixelSize = maximumPixelSize
        self.placeholder = placeholder
    }

    var body: some View {
        #if compiler(>=6.4)
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
            AsyncImage(request: self.request) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                self.placeholder()
            }
            .asyncImageURLSession(self.session)
        } else {
            self.legacyBody
        }
        #else
        self.legacyBody
        #endif
    }

    private var legacyBody: some View {
        Group {
            if let legacyImage {
                OpenClawPlatformImageFactory.image(legacyImage).resizable().scaledToFit()
            } else {
                self.placeholder()
            }
        }
        .task(id: self.request?.url) {
            await self.loadLegacy()
        }
    }

    private func loadLegacy() async {
        self.legacyImage = nil
        self.legacyFailed = false
        guard let request = self.request else { return }
        do {
            let (data, response) = try await self.session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                self.legacyFailed = true
                return
            }
            let maximumPixelSize = self.maximumPixelSize
            let image = await Task.detached(priority: .userInitiated) {
                ChatAuthenticatedImageDecoder.thumbnail(from: data, maximumPixelSize: maximumPixelSize)
            }.value
            guard !Task.isCancelled else { return }
            self.legacyImage = image
            self.legacyFailed = image == nil
        } catch {
            self.legacyFailed = true
        }
    }

    static func isLoadable(_ request: URLRequest) -> Bool {
        guard let scheme = request.url?.scheme?.lowercased() else { return false }
        return scheme == "https" || scheme == "http"
    }
}

enum ChatAuthenticatedImageDecoder {
    /// Downsampled decode (ImageIO thumbnail) so large gateway images do not decode at full size.
    static func thumbnail(from data: Data, maximumPixelSize: Int) -> OpenClawPlatformImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maximumPixelSize),
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        #if os(macOS)
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #else
        return UIImage(cgImage: cgImage)
        #endif
    }
}
#endif
