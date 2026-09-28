// TEMPORARY wave-2 shim (W5b chatui-render). Upstream OpenClaw 2026.9.6 declares every symbol in this
// file in files owned by the chat-shell worker (W5c): ChatTheme.swift (theme tokens, the desktop
// layout environment), ChatView.swift (OpenClawChatDisplayOptions), ChatContextUsage.swift
// (ChatMessageUsagePresentation), ChatCompactTokenCountFormatter.swift and VoiceNoteRecorder.swift
// (openClawVoiceNoteDurationLabel). The message-rendering views reference them by their upstream
// names, so they are ported verbatim here; delete each declaration once the owner's upstream port
// provides it (a duplicate-declaration error names exactly what to remove).
import Foundation

#if os(iOS) || os(macOS) || os(visionOS)
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - ChatTheme.swift

extension EnvironmentValues {
    /// Whether chat renders in the desktop reading layout (760 pt column, collapsed completed work).
    @Entry public var openClawChatDesktopLayout = false
}

extension OpenClawChatTheme {
    static func desktopCanvas(in colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(.sRGB, red: 14 / 255.0, green: 16 / 255.0, blue: 21 / 255.0)
            : Color(.sRGB, red: 250 / 255.0, green: 249 / 255.0, blue: 247 / 255.0)
    }

    static func desktopAccent(in colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(.sRGB, red: 255 / 255.0, green: 92 / 255.0, blue: 92 / 255.0)
            : Color(.sRGB, red: 189 / 255.0, green: 69 / 255.0, blue: 49 / 255.0)
    }

    static func desktopText(in colorScheme: ColorScheme, contrast: ColorSchemeContrast) -> Color {
        if contrast == .increased {
            return colorScheme == .dark
                ? Color(.sRGB, red: 238 / 255.0, green: 239 / 255.0, blue: 241 / 255.0)
                : Color(.sRGB, red: 32 / 255.0, green: 33 / 255.0, blue: 36 / 255.0)
        }
        return colorScheme == .dark
            ? Color(.sRGB, red: 200 / 255.0, green: 200 / 255.0, blue: 204 / 255.0)
            : Color(.sRGB, red: 64 / 255.0, green: 60 / 255.0, blue: 53 / 255.0)
    }

    static func desktopUserBubble(in colorScheme: ColorScheme, accent: Color?) -> Color {
        // Bound the accent contribution so even its lightest/darkest extremes retain reading contrast.
        let tint = accent ?? self.desktopAccent(in: colorScheme)
        if #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) {
            return self.desktopCanvas(in: colorScheme).mix(with: tint, by: 0.15, in: .device)
        }
        return tint.opacity(0.15)
    }

    static var accent: Color {
        self.userBubble
    }

    static var danger: Color {
        #if os(macOS)
        Color(nsColor: .systemRed)
        #else
        Color(uiColor: .systemRed)
        #endif
    }

    static var muted: Color {
        .secondary
    }

    static var warning: Color {
        #if os(macOS)
        Color(nsColor: .systemOrange)
        #else
        Color(uiColor: .systemOrange)
        #endif
    }

    static var success: Color {
        #if os(macOS)
        Color(nsColor: .systemGreen)
        #else
        Color(uiColor: .systemGreen)
        #endif
    }

    /// Readable ink for text rendered on a host-supplied user accent. Mirrors the
    /// Control UI accent contract (ui/src/app/control-ui-presentation.ts): WCAG
    /// relative luminance, black/white reach equal contrast at 0.179.
    static func userText(on accent: Color?) -> Color {
        guard let accent else { return self.userText }
        return self.relativeLuminance(of: accent) > 0.179 ? .black : .white
    }

    static func relativeLuminance(of color: Color) -> Double {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        #if os(macOS)
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return 0 }
        rgb.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        #else
        guard UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return 0 }
        #endif
        func linear(_ channel: CGFloat) -> Double {
            let c = Double(channel)
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
}

// MARK: - ChatView.swift

/// Which assistant trace surfaces the transcript shows.
public struct OpenClawChatDisplayOptions: OptionSet, Sendable {
    /// Raw option bits.
    public let rawValue: UInt8

    /// Creates options from raw bits.
    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// Show assistant thinking/reasoning segments.
    public static let reasoning = Self(rawValue: 1 << 0)
    /// Show tool call activity rows.
    public static let toolActivity = Self(rawValue: 1 << 1)
    /// Reasoning plus tool activity.
    public static let assistantTrace: Self = [.reasoning, .toolActivity]

    /// `.assistantTrace` when `isVisible`, otherwise no trace surfaces.
    public static func assistantTrace(_ isVisible: Bool) -> Self {
        isVisible ? .assistantTrace : []
    }
}
#endif

// MARK: - ChatCompactTokenCountFormatter.swift

enum ChatCompactTokenCountFormatter {
    static func string(_ tokens: Double) -> String {
        if tokens >= 1_000_000 {
            return "\(self.oneDecimal(tokens / 1_000_000))M"
        }
        if tokens >= 1000 {
            let thousands = self.oneDecimal(tokens / 1000)
            if Double(thousands) ?? 0 >= 1000 {
                return "\(self.oneDecimal(tokens / 1_000_000))M"
            }
            return "\(thousands)k"
        }
        return String(Int(tokens))
    }

    private static func oneDecimal(_ value: Double) -> String {
        let rounded = (value * 10).rounded(.toNearestOrAwayFromZero) / 10
        let formatted = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), rounded)
        return formatted.hasSuffix(".0") ? String(formatted.dropLast(2)) : formatted
    }
}

// MARK: - ChatContextUsage.swift

struct ChatMessageUsagePresentation: Equatable {
    enum Pressure: Equatable {
        case normal
        case warning
        case danger
    }

    let text: String
    let accessibilityValue: String
    let pressure: Pressure

    static func make(
        message: OpenClawChatMessage,
        contextWindowTokens: Int?) -> ChatMessageUsagePresentation?
    {
        guard message.role.lowercased() == "assistant", let usage = message.usage else { return nil }

        var visualParts: [String] = []
        var accessibilityParts: [String] = []
        let input = self.positive(usage.input)
        let output = self.positive(usage.output)
        let cacheRead = self.positive(usage.cacheRead)
        let cacheWrite = self.positive(usage.cacheWrite)

        if let input {
            visualParts.append("↑\(ChatCompactTokenCountFormatter.string(Double(input)))")
            accessibilityParts.append(String(
                format: String(localized: "Input tokens: %@"),
                input.formatted()))
        }
        if let output {
            visualParts.append("↓\(ChatCompactTokenCountFormatter.string(Double(output)))")
            accessibilityParts.append(String(
                format: String(localized: "Output tokens: %@"),
                output.formatted()))
        }
        if let cacheRead {
            visualParts.append("R\(ChatCompactTokenCountFormatter.string(Double(cacheRead)))")
            accessibilityParts.append(String(
                format: String(localized: "Cache read tokens: %@"),
                cacheRead.formatted()))
        }
        if let cacheWrite {
            visualParts.append("W\(ChatCompactTokenCountFormatter.string(Double(cacheWrite)))")
            accessibilityParts.append(String(
                format: String(localized: "Cache write tokens: %@"),
                cacheWrite.formatted()))
        }
        if let cost = usage.cost?.total, cost > 0 {
            let formattedCost = String(format: "$%.4f", locale: Locale(identifier: "en_US_POSIX"), cost)
            visualParts.append(formattedCost)
            accessibilityParts.append(String(
                format: String(localized: "Cost: %@"),
                formattedCost))
        }

        // Context pressure mirrors the Control UI prompt size. Output is response data;
        // input plus cache reads/writes is the context the model received for this run.
        let promptTokens = Double(input ?? 0) + Double(cacheRead ?? 0) + Double(cacheWrite ?? 0)
        let contextPercent: Int?
        if let contextWindowTokens, contextWindowTokens > 0, promptTokens > 0 {
            let roundedPercent = (promptTokens / Double(contextWindowTokens) * 100).rounded()
            contextPercent = Int(min(100, roundedPercent))
        } else {
            contextPercent = nil
        }
        let pressure = self.pressure(for: contextPercent)
        if let contextPercent {
            let warningPrefix = pressure == .normal ? "" : "⚠︎ "
            visualParts.append("\(warningPrefix)\(contextPercent)% \(String(localized: "ctx"))")
            switch pressure {
            case .normal:
                accessibilityParts.append(String(
                    format: String(localized: "%@ percent of context used"),
                    contextPercent.formatted()))
            case .warning:
                accessibilityParts.append(String(
                    format: String(localized: "Warning: %@ percent of context used"),
                    contextPercent.formatted()))
            case .danger:
                accessibilityParts.append(String(
                    format: String(localized: "Critical: %@ percent of context used"),
                    contextPercent.formatted()))
            }
        }

        guard !visualParts.isEmpty else { return nil }
        return ChatMessageUsagePresentation(
            text: visualParts.joined(separator: " "),
            accessibilityValue: accessibilityParts.joined(separator: ", "),
            pressure: pressure)
    }

    private static func pressure(for percent: Int?) -> Pressure {
        guard let percent else { return .normal }
        if percent >= 90 { return .danger }
        if percent >= 75 { return .warning }
        return .normal
    }

    private static func positive(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }
}

// MARK: - VoiceNoteRecorder.swift

private let voiceNoteMaximumDurationSeconds: TimeInterval = 180

func openClawVoiceNoteDurationLabel(_ durationSeconds: TimeInterval) -> String {
    guard durationSeconds.isFinite else { return "0:00" }
    let boundedDuration = min(
        max(0, durationSeconds),
        voiceNoteMaximumDurationSeconds)
    let totalSeconds = Int(boundedDuration)
    return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
}
