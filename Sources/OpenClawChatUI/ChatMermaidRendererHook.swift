// ChatUI views ship on iOS, macOS and visionOS. tvOS and watchOS get only the non-UI chat core
// (view model, transport, models, parsers), because these views rely on APIs such as TextEditor,
// textSelection and PhotosPicker that are unavailable there.
#if os(iOS) || os(macOS) || os(visionOS)
import CoreGraphics
import Foundation
import OpenClawKit
import SwiftUI

// Upstream OpenClaw 2026.9.6 renders ```mermaid fences with a bundled, offscreen WKWebView running
// mermaid.min.js + DOMPurify (ChatMermaidRenderer/ChatMermaidResources). OpenClawKit bundles no
// JavaScript: a host that wants diagrams supplies a renderer through
// `.openClawChatMermaidRenderer(_:)` (for example one built from upstream's
// `packages/mermaid-renderer`, which must carry the Mermaid MIT and DOMPurify notices). Without a
// renderer, mermaid fences render as ordinary code blocks.

/// Colors and font the transcript expects a Mermaid diagram to use, as CSS color strings.
public struct OpenClawChatMermaidTheme: Hashable, Sendable {
    /// Diagram background (the assistant bubble color).
    public let background: String
    /// Primary text and line color.
    public let foreground: String
    /// Secondary text color.
    public let muted: String
    /// Node border color.
    public let border: String
    /// Accent color for highlighted nodes.
    public let accent: String
    /// CSS font family.
    public let fontFamily: String
    /// Whether the transcript is in dark mode.
    public let darkMode: Bool

    /// Creates a theme.
    public init(
        background: String,
        foreground: String,
        muted: String,
        border: String,
        accent: String,
        fontFamily: String,
        darkMode: Bool)
    {
        self.background = background
        self.foreground = foreground
        self.muted = muted
        self.border = border
        self.accent = accent
        self.fontFamily = fontFamily
        self.darkMode = darkMode
    }
}

/// One diagram render request. Requests are admitted only within upstream's renderer limits
/// (non-empty source of at most 20,000 UTF-16 units, width 1...8192 points, finite scale, and at
/// most 8192 physical pixels wide), so a renderer never sees hostile sizes.
public struct OpenClawChatMermaidRenderRequest: Hashable, Sendable {
    /// Mermaid source from the fenced block.
    public let source: String
    /// Available width in points.
    public let width: Int
    /// Display scale of the target screen.
    public let displayScale: Double
    /// Transcript colors.
    public let theme: OpenClawChatMermaidTheme

    /// Creates a request.
    public init(source: String, width: Int, displayScale: Double, theme: OpenClawChatMermaidTheme) {
        self.source = source
        self.width = width
        self.displayScale = displayScale
        self.theme = theme
    }
}

/// A rendered diagram bitmap and its size in points.
public struct OpenClawChatMermaidDiagram {
    /// The rendered bitmap.
    public let image: OpenClawPlatformImage
    /// Size in points; the transcript preserves this aspect ratio.
    public let size: CGSize

    /// Creates a rendered diagram.
    public init(image: OpenClawPlatformImage, size: CGSize) {
        self.image = image
        self.size = size
    }
}

/// Errors a Mermaid renderer can report. `retryable` failures offer a Retry action.
public struct OpenClawChatMermaidRenderError: Error, Equatable, Sendable {
    /// Human-readable reason (shown to the user only as a generic status).
    public let message: String
    /// Whether retrying the same request may succeed.
    public let retryable: Bool

    /// Creates a render error.
    public init(message: String, retryable: Bool) {
        self.message = message
        self.retryable = retryable
    }
}

/// Host-supplied Mermaid renderer. It runs on the main actor and should render off-screen,
/// honor task cancellation, and throw `OpenClawChatMermaidRenderError` for syntax or capacity
/// failures.
public struct OpenClawChatMermaidRenderer: Sendable {
    /// Render closure.
    public typealias Render = @MainActor @Sendable (OpenClawChatMermaidRenderRequest) async throws
        -> OpenClawChatMermaidDiagram

    let render: Render

    /// Creates a renderer from a render closure.
    public init(render: @escaping Render) {
        self.render = render
    }
}

extension EnvironmentValues {
    /// Host-supplied Mermaid renderer; nil (the default) renders mermaid fences as code.
    @Entry public var openClawChatMermaidRenderer: OpenClawChatMermaidRenderer? = nil
}

extension View {
    /// Renders ```mermaid fences in chat transcripts with `renderer` (nil keeps them as code blocks).
    public func openClawChatMermaidRenderer(_ renderer: OpenClawChatMermaidRenderer?) -> some View {
        self.environment(\.openClawChatMermaidRenderer, renderer)
    }
}

extension OpenClawChatMermaidRenderRequest {
    /// Upstream's shared renderer admission limits, checked before a host renderer runs.
    var isAdmissible: Bool {
        ChatMermaidRequest(
            source: self.source,
            width: self.width,
            displayScale: self.displayScale,
            theme: ChatMermaidTheme(
                background: self.theme.background,
                foreground: self.theme.foreground,
                muted: self.theme.muted,
                border: self.theme.border,
                accent: self.theme.accent,
                fontFamily: self.theme.fontFamily,
                darkMode: self.theme.darkMode)).isValid
    }
}
#endif
