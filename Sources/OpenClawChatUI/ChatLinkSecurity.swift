import Foundation
import OpenClawKit
#if compiler(>=6.4) && canImport(LinkSecurity)
import LinkSecurity
#endif

// OpenClawKit-specific (no upstream counterpart): links that reach the transcript from untrusted
// provenance (tool results, inbound channel messages from other people) are flagged with the
// LinkSecurity framework (LSLinkSecurityManager, iOS/macOS/tvOS/watchOS/visionOS 27), and opening a
// flagged link from chat asks for confirmation showing its full host. Before 27 nothing is flagged.

/// Abstraction over the system link-security store, so the provenance policy is testable.
protocol ChatLinkFlagging: Sendable {
    /// Records `urls` as needing additional security consideration.
    func addFlaggedURLs(_ urls: [URL]) async
    /// Whether `url` was flagged.
    func isFlaggedURL(_ url: URL) async -> Bool
}

enum ChatLinkSecurity {
    /// Tools whose results carry third-party web content.
    private static let webToolNameFragments = ["web", "browser", "fetch", "search", "http", "url", "crawl", "scrape"]

    /// Whether a message's own content comes from an untrusted source.
    static func isUntrustedProvenance(_ message: OpenClawChatMessage) -> Bool {
        let role = message.role.lowercased()
        if ["tool", "toolresult", "tool_result"].contains(role) {
            return true
        }
        guard let provenance = message.provenance else { return false }
        switch provenance.kind {
        case "external_user":
            // Inbound channel traffic from someone other than the device owner.
            return true
        case "internal_system":
            return false
        default:
            return provenance.sourceChannel != nil
        }
    }

    /// Whether a tool (by name) returns third-party web content.
    static func isWebTool(_ name: String?) -> Bool {
        guard let name = name?.lowercased(), !name.isEmpty else { return false }
        return self.webToolNameFragments.contains(where: name.contains)
    }

    /// Links in `message` that should be flagged: every web link in untrusted messages, plus the
    /// links inside web/browser tool results merged into assistant messages. Deduplicated, in order.
    static func untrustedLinks(in message: OpenClawChatMessage) -> [URL] {
        var sources: [String] = []
        if self.isUntrustedProvenance(message) {
            sources.append(contentsOf: message.content.compactMap(\.text))
            sources.append(contentsOf: message.content.flatMap { [$0.url, $0.openUrl].compactMap(\.self) })
        } else {
            for block in message.content where block.isToolResult && self.isWebTool(block.name ?? message.toolName) {
                if let text = block.text {
                    sources.append(text)
                }
            }
        }
        var seen = Set<URL>()
        var links: [URL] = []
        for source in sources {
            for url in chatPreviewURLs(in: source) where seen.insert(url).inserted {
                links.append(url)
            }
        }
        return links
    }

    /// Flags the untrusted links in `message` with `flagger` (the system store on 27+ when nil).
    static func flagUntrustedLinks(in message: OpenClawChatMessage, flagger: (any ChatLinkFlagging)? = nil) async {
        let links = self.untrustedLinks(in: message)
        guard !links.isEmpty, let flagger = flagger ?? self.systemFlagger else { return }
        await flagger.addFlaggedURLs(links)
    }

    /// Whether opening `url` from chat needs confirmation.
    static func requiresConfirmation(_ url: URL, flagger: (any ChatLinkFlagging)? = nil) async -> Bool {
        guard let flagger = flagger ?? self.systemFlagger else { return false }
        return await flagger.isFlaggedURL(url)
    }

    /// The LinkSecurity-backed store, or nil before 27 / on SDKs without the framework.
    static var systemFlagger: (any ChatLinkFlagging)? {
        #if compiler(>=6.4) && canImport(LinkSecurity)
        if #available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *) {
            return SystemChatLinkFlagger()
        }
        #endif
        return nil
    }
}

#if compiler(>=6.4) && canImport(LinkSecurity)
@available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
struct SystemChatLinkFlagger: ChatLinkFlagging {
    func addFlaggedURLs(_ urls: [URL]) async {
        LSLinkSecurityManager.shared.addFlaggedURLs(urls)
    }

    func isFlaggedURL(_ url: URL) async -> Bool {
        await LSLinkSecurityManager.shared.isFlaggedURL(url)
    }
}
#endif

// ChatUI views ship on iOS, macOS and visionOS.
#if os(iOS) || os(macOS) || os(visionOS)
import SwiftUI

/// Flags a message's untrusted links and routes link taps through a confirmation when the system
/// marked the destination. Pass-through before 27.
struct ChatLinkSecurityModifier: ViewModifier {
    let message: OpenClawChatMessage
    @Environment(\.openURL) private var openURL
    @State private var pendingURL: URL?

    func body(content: Content) -> some View {
        if ChatLinkSecurity.systemFlagger == nil {
            content
        } else {
            content
                .task(id: self.message.id) {
                    await ChatLinkSecurity.flagUntrustedLinks(in: self.message)
                }
                .environment(\.openURL, OpenURLAction { url in
                    Task { @MainActor in
                        if await ChatLinkSecurity.requiresConfirmation(url) {
                            self.pendingURL = url
                        } else {
                            self.openURL(url)
                        }
                    }
                    return .handled
                })
                .alert(
                    Text("Open this link?"),
                    isPresented: Binding(
                        get: { self.pendingURL != nil },
                        set: { if !$0 { self.pendingURL = nil } }),
                    presenting: self.pendingURL)
                { url in
                    Button("Open") {
                        self.pendingURL = nil
                        self.openURL(url)
                    }
                    Button("Cancel", role: .cancel) {
                        self.pendingURL = nil
                    }
                } message: { url in
                    Text(String(
                        format: String(localized: "This link came from an untrusted source and goes to %@."),
                        url.host ?? url.absoluteString))
                }
        }
    }
}
#endif
