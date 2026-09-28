import Foundation

// Apple-native Foundation Models tools offered to Apple FM sessions (OS 27).
//
// - Vision (`_Vision_FoundationModels`): `BarcodeReaderTool` (iOS/macOS/visionOS/watchOS 27) and
//   `OCRTool` (not on watchOS). Offered when the request carries images and the model can call
//   tools; images are labeled `image-1...N` and the labels listed in the prompt so the model can fill
//   the tools' `attachmentLabel` argument.
// - Spotlight (`_CoreSpotlight_FoundationModels`, iOS/macOS/visionOS 27): `SpotlightSearchTool` for
//   semantic search over Core Spotlight (and optional file scopes). Its ~5,000-character description
//   consumes a large share of the on-device 8,192-token window, so it is offered to Private Cloud
//   Compute sessions and to the on-device model only with an explicit opt-in.
//
// These tools run inside the Foundation Models session and are never exposed to other providers.
// tvOS ships the overlay modules but Foundation Models is unavailable there.
#if compiler(>=6.4) && canImport(FoundationModels) && !os(tvOS)
import FoundationModels
// The overlays are imported explicitly: cross-import overlay discovery differs between SwiftPM and
// xcodebuild (macOS xcodebuild does not load them implicitly).
#if canImport(_Vision_FoundationModels)
import Vision
import _Vision_FoundationModels
#endif
#if canImport(_CoreSpotlight_FoundationModels)
import CoreSpotlight
import _CoreSpotlight_FoundationModels
#endif

/// Apple-native Foundation Models tools (Vision and Spotlight) for OS 27 sessions.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
public enum AppleIntelligenceTools {
    /// Vision tools: `BarcodeReaderTool` everywhere and `OCRTool` except on watchOS.
    ///
    /// Images must be attached to the prompt with a label (see `Attachment.label(_:)`).
    /// - Returns: The tools available on this platform (empty without `_Vision_FoundationModels`).
    public static func visionTools() -> [any Tool] {
        var tools: [any Tool] = []
        #if canImport(_Vision_FoundationModels)
        tools.append(BarcodeReaderTool())
        #if !os(watchOS)
        tools.append(OCRTool())
        #endif
        #endif
        return tools
    }

    #if canImport(_CoreSpotlight_FoundationModels) && !os(watchOS)
    /// Builds a `SpotlightSearchTool` over Core Spotlight (plus optional file scopes).
    ///
    /// Uses `CoreSpotlightSource(searchableIndexDelegate:fetchAttributes:)` with title, text content,
    /// domain identifier and creation date, a result cap, and the focused `items` guide.
    /// - Parameter options: Spotlight options.
    /// - Returns: The tool.
    @available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
    @available(watchOS, unavailable)
    public static func spotlightSearchTool(options: FoundationModelsSpotlightSearchOptions) -> SpotlightSearchTool {
        let fetchAttributes: [SearchableItemAttribute] = [.title, .textContent, .domainIdentifier, .contentCreationDate]
        var source = CoreSpotlightSource(
            searchableIndexDelegate: options.searchableIndexDelegate as? any CSSearchableIndexDelegate,
            fetchAttributes: fetchAttributes
        )
        source.maximumResultCount = options.maximumResultCount
        var sources: [SearchSource] = [.coreSpotlight(source)]
        if !options.fileScopes.isEmpty {
            var files = FileSource(fetchAttributes: fetchAttributes)
            files.scopes = options.fileScopes
            files.maximumResultCount = options.maximumResultCount
            sources.append(.files(files))
        }
        let configuration = SpotlightSearchTool.Configuration(
            sources: sources,
            guide: .focused(.items(.init(title: [.title], text: [.textContent]))),
            maximumResponseSize: options.maximumResponseSize
        )
        return SpotlightSearchTool(configuration: configuration)
    }
    #endif

    /// Native tools for one request: Vision tools when the transcript carries images (and the model
    /// has vision), Spotlight search when configured and allowed for the target.
    static func nativeTools(
        for plan: FoundationModelsTranscriptPlan,
        target: AppleFoundationModelTarget,
        options: FoundationModelsToolOptions,
        vision: Bool
    ) -> [any Tool] {
        var tools: [any Tool] = []
        if options.visionTools, vision, plan.containsImages {
            tools.append(contentsOf: Self.visionTools())
        }
        #if canImport(_CoreSpotlight_FoundationModels) && !os(watchOS)
        if let spotlight = options.spotlightSearch, target == .privateCloudCompute || spotlight.allowOnSystemModel {
            tools.append(Self.spotlightSearchTool(options: spotlight))
        }
        #else
        _ = target
        #endif
        return tools
    }
}
#endif
