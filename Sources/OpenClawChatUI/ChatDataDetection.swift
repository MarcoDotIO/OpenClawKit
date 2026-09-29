// ChatUI views ship on iOS, macOS and visionOS. tvOS and watchOS get only the non-UI chat core
// (view model, transport, models, parsers), because these views rely on APIs such as TextEditor,
// textSelection and PhotosPicker that are unavailable there.
#if os(iOS) || os(macOS) || os(visionOS)
import Foundation
import SwiftUI
#if compiler(>=6.4) && canImport(DataDetection) && (os(iOS) || os(visionOS))
import DataDetection
#endif

// OpenClawKit-specific (no upstream counterpart): assistant text gets system data detection on iOS and
// visionOS 27 (`View.dataDetection`, unavailable on macOS/tvOS). Links stay owned by Markdown and
// LinkSecurity, so only phone numbers, addresses, events, flights and shipment numbers are detected.

extension EnvironmentValues {
    /// Whether assistant message text uses system data detection (iOS/visionOS 27+). Default true.
    @Entry public var openClawChatDataDetectionEnabled = true
}

extension View {
    /// Enables or disables system data detection on assistant message text (iOS/visionOS 27+).
    public func openClawChatDataDetection(_ enabled: Bool) -> some View {
        self.environment(\.openClawChatDataDetectionEnabled, enabled)
    }
}

/// Applies `.dataDetection` to assistant text where the platform supports it.
struct ChatDataDetectionModifier: ViewModifier {
    let isAssistant: Bool
    let documentDate: Date?
    @Environment(\.openClawChatDataDetectionEnabled) private var isEnabled

    func body(content: Content) -> some View {
        #if compiler(>=6.4) && canImport(DataDetection) && (os(iOS) || os(visionOS))
        if self.isAssistant, self.isEnabled, #available(iOS 27.0, visionOS 27.0, *) {
            content.dataDetection(
                [.phoneNumber, .postalAddress, .calendarEvent, .flightNumber, .shipmentTrackingNumber],
                options: Self.options(documentDate: self.documentDate))
        } else {
            content
        }
        #else
        content
        #endif
    }

    #if compiler(>=6.4) && canImport(DataDetection) && (os(iOS) || os(visionOS))
    @available(iOS 27.0, visionOS 27.0, *)
    private static func options(documentDate: Date?) -> DataDetector.Options {
        var options = DataDetector.Options()
        options.documentDate = documentDate
        return options
    }
    #endif
}
#endif
