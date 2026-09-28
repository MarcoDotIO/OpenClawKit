import Foundation
import OpenClawKit
import SwiftUI

/// Chat display preferences from the gateway's `ui.prefs` (the canonical cross-client home, read via
/// `config.get`), plus the user accent (`ui.prefs.accent`, then `ui.seamColor`).
///
/// Pass it to ``OpenClawChatView`` (or ``OpenClawChatSplitView``): `chatShowThinking` and `chatShowToolCalls`
/// drive the transcript display options, `chatSendShortcut` = `modifier-enter` makes ⌘-Return send on macOS
/// (Return then inserts a line break), `themeMode` forces a color scheme for the chat (`system` follows the
/// host), and the accent colors the user bubbles and send button.
public struct OpenClawChatUIPreferences: Equatable, Sendable {
    /// `ui.prefs.chatShowThinking`; `nil` keeps the host default.
    public var showsThinking: Bool?
    /// `ui.prefs.chatShowToolCalls`; `nil` keeps the host default.
    public var showsToolCalls: Bool?
    /// `ui.prefs.chatSendShortcut == "modifier-enter"`.
    public var sendRequiresModifier: Bool
    /// `ui.prefs.themeMode` (`light`, `dark` or `system`).
    public var themeMode: OpenClawConfigDocument.UI.ThemeMode?
    /// Canonical `#rrggbb` user accent, when configured and valid.
    public var accentHex: String?

    /// Creates preferences from explicit values.
    public init(
        showsThinking: Bool? = nil,
        showsToolCalls: Bool? = nil,
        sendRequiresModifier: Bool = false,
        themeMode: OpenClawConfigDocument.UI.ThemeMode? = nil,
        accentHex: String? = nil)
    {
        self.showsThinking = showsThinking
        self.showsToolCalls = showsToolCalls
        self.sendRequiresModifier = sendRequiresModifier
        self.themeMode = themeMode
        self.accentHex = GatewayUserPreferences.normalizedAccentHex(accentHex)
    }

    /// Reads a config document's `ui` section.
    /// - Parameter ui: `ui` from ``OpenClawConfigDocument``.
    public init(ui: OpenClawConfigDocument.UI?) {
        let prefs = ui?.prefs
        self.init(
            showsThinking: prefs?.chatShowThinking,
            showsToolCalls: prefs?.chatShowToolCalls,
            sendRequiresModifier: prefs?.sendRequiresModifier ?? false,
            themeMode: prefs?.themeMode,
            accentHex: GatewayUserPreferences.gatewayUserAccentHex(ui: ui))
    }

    /// Reads the `ui` section of a config document (for example a decoded `config.get` snapshot).
    /// - Parameter document: The config document.
    public init(document: OpenClawConfigDocument) {
        self.init(ui: document.ui)
    }

    /// Color scheme forced by `themeMode`; `system` and unknown modes yield `nil` (follow the host).
    public var colorScheme: ColorScheme? {
        switch self.themeMode {
        case .some(.light): .light
        case .some(.dark): .dark
        default: nil
        }
    }

    /// The user accent as a color, when configured.
    public var accentColor: Color? {
        guard let accentHex, let rgb = UInt32(accentHex.dropFirst(), radix: 16) else { return nil }
        return Color(
            .sRGB,
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255,
            opacity: 1)
    }

    /// Display options with the configured visibility applied over `fallback`.
    /// - Parameter fallback: Options used for unset preferences.
    /// - Returns: The effective display options.
    public func displayOptions(fallback: OpenClawChatDisplayOptions) -> OpenClawChatDisplayOptions {
        var options = fallback
        if let showsThinking {
            if showsThinking { options.insert(.reasoning) } else { options.remove(.reasoning) }
        }
        if let showsToolCalls {
            if showsToolCalls { options.insert(.toolActivity) } else { options.remove(.toolActivity) }
        }
        return options
    }
}
