// ChatUI views ship on iOS, macOS and visionOS. tvOS and watchOS get only the non-UI chat core
// (view model, transport, models, parsers), because these views rely on APIs such as TextEditor,
// textSelection and PhotosPicker that are unavailable there.
#if os(iOS) || os(macOS) || os(visionOS)
import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// Ported from upstream OpenClaw 2026.9.6 `ChatTypography.swift`.
//
// Upstream's iOS app bundles Inter, Red Hat Display and JetBrains Mono. An SDK host may not, so on
// iOS and visionOS each family is used only when the host registered it; otherwise the matching
// system text style (default or monospaced design) keeps Dynamic Type scaling and a real
// monospaced face for code.
enum OpenClawChatTypography {
    static let bodySize: CGFloat = 17

    static var headline: Font {
        display(size: 17, weight: .semibold, relativeTo: .headline)
    }

    static func heading(level: Int) -> Font {
        switch level {
        case 1:
            self.display(size: 24, weight: .bold, relativeTo: .title2)
        case 2:
            self.display(size: 21, weight: .bold, relativeTo: .title3)
        case 3:
            self.display(size: 19, weight: .semibold, relativeTo: .headline)
        case 4:
            self.body(size: 17, weight: .semibold, relativeTo: .body)
        case 5:
            self.body(size: 16, weight: .semibold, relativeTo: .callout)
        default:
            self.body(size: 15, weight: .semibold, relativeTo: .subheadline)
        }
    }

    static var callout: Font {
        body(size: 16, weight: .regular, relativeTo: .callout)
    }

    static var body: Font {
        body(size: self.bodySize, weight: .regular, relativeTo: .body)
    }

    static var formControl: Font {
        #if os(macOS)
        OpenClawChatTypography.body(size: 13, weight: .regular, relativeTo: .body)
        #else
        OpenClawChatTypography.body
        #endif
    }

    #if os(iOS) || os(visionOS)
    static var bodyUIFont: UIFont {
        let base = UIFont(name: self.bodyPostScriptName, size: self.bodySize) ??
            UIFont.systemFont(ofSize: self.bodySize)
        return UIFontMetrics(forTextStyle: .body).scaledFont(for: base)
    }
    #endif

    static var footnote: Font {
        body(size: 13, weight: .regular, relativeTo: .footnote)
    }

    static var footnoteSemiBold: Font {
        body(size: 13, weight: .semibold, relativeTo: .footnote)
    }

    static var caption: Font {
        body(size: 12, weight: .regular, relativeTo: .caption)
    }

    static var captionSemiBold: Font {
        body(size: 12, weight: .semibold, relativeTo: .caption)
    }

    static var caption2: Font {
        body(size: 11, weight: .regular, relativeTo: .caption2)
    }

    static func avatar(size: CGFloat) -> Font {
        self.body(size: size, weight: .bold, relativeTo: .caption)
    }

    static func body(size: CGFloat, weight: Font.Weight, relativeTo textStyle: Font.TextStyle) -> Font {
        #if os(macOS)
        Font.custom(self.macSystemFontName(size: size), size: size, relativeTo: textStyle).weight(weight)
        #else
        if FontAvailability.body {
            Font.custom(self.bodyPostScriptName, size: size, relativeTo: textStyle).weight(weight)
        } else {
            Font.system(textStyle, design: .default, weight: weight)
        }
        #endif
    }

    static func display(size: CGFloat, weight: Font.Weight, relativeTo textStyle: Font.TextStyle) -> Font {
        #if os(macOS)
        Font.custom(self.macSystemFontName(size: size), size: size, relativeTo: textStyle).weight(weight)
        #else
        if FontAvailability.display {
            Font.custom(self.displayPostScriptName, size: size, relativeTo: textStyle).weight(weight)
        } else {
            Font.system(textStyle, design: .default, weight: weight)
        }
        #endif
    }

    static func mono(size: CGFloat, weight: Font.Weight = .regular, relativeTo textStyle: Font.TextStyle) -> Font {
        #if os(macOS)
        return Font.custom(self.macMonospacedSystemFontName(size: size), size: size, relativeTo: textStyle)
            .weight(weight)
        #else
        let name = weight == .semibold ? Self.monoSemiBoldPostScriptName : Self.monoPostScriptName
        if FontAvailability.mono {
            return Font.custom(name, size: size, relativeTo: textStyle)
        }
        return Font.system(textStyle, design: .monospaced, weight: weight)
        #endif
    }

    private static let displayPostScriptName = "RedHatDisplay-Regular"
    private static let bodyPostScriptName = "Inter-Regular"
    private static let monoPostScriptName = "JetBrainsMono-Regular"
    private static let monoSemiBoldPostScriptName = "JetBrainsMono-SemiBold"

    #if os(iOS) || os(visionOS)
    /// Whether the host app registered upstream's brand font families. Resolved once per process.
    private enum FontAvailability {
        static let body = UIFont(name: OpenClawChatTypography.bodyPostScriptName, size: 12) != nil
        static let display = UIFont(name: OpenClawChatTypography.displayPostScriptName, size: 12) != nil
        static let mono = UIFont(name: OpenClawChatTypography.monoPostScriptName, size: 12) != nil &&
            UIFont(name: OpenClawChatTypography.monoSemiBoldPostScriptName, size: 12) != nil
    }
    #endif

    #if os(macOS)
    /// Navigation badges retain the system constructor and contextual design.
    /// Using body here would alter font resolution and text-style scaling.
    static func navigationAvatar(size: CGFloat) -> Font {
        Font.system(size: size, weight: .medium)
    }

    private static func macSystemFontName(size: CGFloat) -> String {
        NSFont.systemFont(ofSize: size).fontName
    }

    private static func macMonospacedSystemFontName(size: CGFloat) -> String {
        NSFont.monospacedSystemFont(ofSize: size, weight: .regular).fontName
    }
    #endif
}
#endif
