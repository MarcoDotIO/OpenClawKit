// ChatUI views ship on iOS, macOS and visionOS. tvOS and watchOS get only the non-UI chat core
// (view model, transport, models, parsers), because these views rely on APIs such as TextEditor,
// textSelection and PhotosPicker that are unavailable there.
#if os(iOS) || os(macOS) || os(visionOS)
import CryptoKit
import Foundation
import OpenClawKit
import SwiftUI

#if canImport(WebKit) && (os(iOS) || os(macOS) || os(visionOS))
import Security
import WebKit

#if os(iOS) || os(visionOS)
import UIKit
#elseif os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif
#endif

// Ported from upstream OpenClaw 2026.9.6 `ChatInlineWidgetView.swift` (widget host view, sandboxed WKWebView,
// snapshot export). `OpenClawChatWidgetResource` and `OpenClawChatWidgetURLResolver` live in
// Core/ChatInlineWidgetResources.swift. WebKit hosting covers iOS, macOS and visionOS; the route-aware
// `resolveResource(target:replacing:currentSurfaceRoutes:...)` waits for the kit's GatewayCanvasHostRoute.

enum ChatInlineWidgetExport {
    static func filename(title: String?) -> String {
        var name = title ?? ""
        name.removeAll { character in
            character == "/" ||
                character == "\\" ||
                character.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(name.isEmpty ? "widget" : name).png"
    }
}

@MainActor
struct ChatInlineWidgetView: View {
    let preview: OpenClawChatCanvasPreview
    let resolverReady: Bool
    let resolveResource: @MainActor @Sendable (
        String,
        OpenClawChatWidgetResource?) async -> OpenClawChatWidgetResource?

    @State private var resolvedResource: OpenClawChatWidgetResource?
    @State private var recoveryAttempts = 0
    @State private var refreshInFlight = false
    @State private var unavailable = false
    @State private var activePath: String?
    /// A reset can keep the same path while installing a new connection route.
    /// Its generation prevents older resolver completions from restoring stale trust state.
    @State private var loadGeneration = UUID()

    #if canImport(WebKit) && (os(iOS) || os(macOS) || os(visionOS))
    @State private var snapshotRequest: ChatInlineWidgetSnapshotRequest?
    @State private var exportErrorMessage: String?

    #if os(iOS) || os(visionOS)
    @State private var sharedImage: ChatInlineWidgetSharedImage?
    #endif

    private var isPresentingExportError: Binding<Bool> {
        Binding(
            get: { self.exportErrorMessage != nil },
            set: { if !$0 { self.exportErrorMessage = nil } })
    }
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title = self.preview.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                Text(title)
                    .font(OpenClawChatTypography.footnote)
                    .fontWeight(.semibold)
                    .foregroundStyle(OpenClawChatTheme.muted)
            }

            #if canImport(WebKit) && (os(iOS) || os(macOS) || os(visionOS))
            if let resolvedResource {
                self.renderedWidget(resource: resolvedResource)
            } else if self.unavailable {
                Text("Widget unavailable")
                    .font(OpenClawChatTypography.footnote)
                    .foregroundStyle(OpenClawChatTheme.muted)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            #else
            Text("Widget unavailable")
                .font(OpenClawChatTypography.footnote)
                .foregroundStyle(OpenClawChatTheme.muted)
            #endif
        }
        .task(id: LoadID(path: self.preview.inlineWidgetPath, resolverReady: self.resolverReady)) {
            let path = self.preview.inlineWidgetPath
            if self.activePath != path {
                self.reset(path: path)
            }
            guard self.resolverReady else { return }
            self.reset(path: path)
            guard let path else {
                self.unavailable = true
                return
            }
            await self.load(path: path, replacing: nil, generation: self.loadGeneration)
        }
        #if canImport(WebKit) && (os(iOS) || os(macOS) || os(visionOS))
        .alert("Widget export failed", isPresented: self.isPresentingExportError) {
            Button(role: .cancel) {
                self.exportErrorMessage = nil
            } label: {
                Text("OK")
                    .font(OpenClawChatTypography.body)
            }
        } message: {
            if let exportErrorMessage {
                Text(exportErrorMessage)
                    .font(OpenClawChatTypography.body)
            }
        }
        #if os(iOS) || os(visionOS)
        .sheet(item: self.$sharedImage) { item in
            ChatInlineWidgetShareSheet(image: item.image)
        }
        #endif
        #endif
    }

    #if canImport(WebKit) && (os(iOS) || os(macOS) || os(visionOS))
    private func renderedWidget(resource: OpenClawChatWidgetResource) -> some View {
        ChatInlineWidgetWebView(
            resource: resource,
            loadGeneration: self.loadGeneration,
            allowsScripts: self.preview.sandbox == "scripts",
            snapshotRequest: self.snapshotRequest,
            onFailure: { self.handleLoadFailure(resource: resource) },
            onSnapshot: self.handleSnapshot)
            .id([
                resource.url.absoluteString,
                resource.tlsFingerprintSHA256 ?? "",
                self.preview.sandbox ?? "",
            ].joined(separator: "\u{0}"))
            .frame(height: self.preview.inlineWidgetHeight)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(OpenClawChatTheme.muted.opacity(0.24), lineWidth: 1)
            }
            .contentShape(Rectangle())
            .contextMenu {
                Button {
                    self.requestSnapshot(for: .copy)
                } label: {
                    Text("Copy image")
                        .font(OpenClawChatTypography.body)
                }

                Button {
                    self.requestSnapshot(for: .save)
                } label: {
                    #if os(macOS)
                    Text("Save image…")
                        .font(OpenClawChatTypography.body)
                    #else
                    Text("Save image")
                        .font(OpenClawChatTypography.body)
                    #endif
                }
            }
    }

    private func requestSnapshot(for action: ChatInlineWidgetSnapshotRequest.Action) {
        guard let resource = self.resolvedResource else { return }
        self.snapshotRequest = ChatInlineWidgetSnapshotRequest(
            action: action,
            generation: self.loadGeneration,
            resource: resource)
    }

    private func handleSnapshot(_ outcome: ChatInlineWidgetSnapshotOutcome) {
        switch outcome {
        case let .failure(request):
            guard self.consumeSnapshotRequest(request) else { return }
            self.exportErrorMessage = String(localized: "The widget image could not be captured.")
        case let .success(request, image):
            guard self.consumeSnapshotRequest(request) else { return }
            switch request.action {
            case .copy:
                self.copySnapshot(image)
            case .save:
                self.saveSnapshot(image)
            }
        }
    }

    private func consumeSnapshotRequest(_ request: ChatInlineWidgetSnapshotRequest) -> Bool {
        guard self.snapshotRequest == request,
              request.generation == self.loadGeneration,
              request.resource == self.resolvedResource
        else { return false }
        self.snapshotRequest = nil
        return true
    }

    #if os(iOS) || os(visionOS)
    private func copySnapshot(_ image: ChatInlineWidgetSnapshotImage) {
        UIPasteboard.general.image = image
    }

    private func saveSnapshot(_ image: ChatInlineWidgetSnapshotImage) {
        self.sharedImage = ChatInlineWidgetSharedImage(image: image)
    }
    #elseif os(macOS)
    private func copySnapshot(_ image: ChatInlineWidgetSnapshotImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.writeObjects([image]) else {
            self.exportErrorMessage = String(localized: "The widget image could not be copied.")
            return
        }
    }

    private func saveSnapshot(_ image: ChatInlineWidgetSnapshotImage) {
        guard let pngData = image.chatInlineWidgetPNGData else {
            self.exportErrorMessage = String(localized: "The widget image could not be encoded as PNG.")
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = ChatInlineWidgetExport.filename(title: self.preview.title)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try pngData.write(to: url, options: .atomic)
            } catch {
                self.exportErrorMessage = String(localized: "The widget image could not be saved.")
            }
        }
    }
    #endif
    #endif

    private struct LoadID: Hashable {
        let path: String?
        let resolverReady: Bool
    }

    private func reset(path: String?) {
        self.loadGeneration = UUID()
        self.activePath = path
        self.setResolvedResource(nil)
        self.recoveryAttempts = 0
        self.refreshInFlight = false
        self.unavailable = false
    }

    private func load(
        path: String,
        replacing failedResource: OpenClawChatWidgetResource?,
        generation: UUID) async
    {
        let candidate = await self.resolveResource(path, failedResource)
        guard !Task.isCancelled,
              self.activePath == path,
              self.loadGeneration == generation
        else { return }
        let resource = candidate?.hasValidTLSBinding == true ? candidate : nil
        self.setResolvedResource(resource)
        self.unavailable = resource == nil
    }

    private func setResolvedResource(_ resource: OpenClawChatWidgetResource?) {
        #if canImport(WebKit) && (os(iOS) || os(macOS) || os(visionOS))
        if self.resolvedResource != resource || resource == nil {
            self.snapshotRequest = nil
        }
        #endif
        self.resolvedResource = resource
    }

    private func handleLoadFailure(resource: OpenClawChatWidgetResource) {
        guard self.resolvedResource == resource,
              let path = self.activePath,
              !self.refreshInFlight
        else { return }
        guard self.recoveryAttempts < 3 else {
            self.setResolvedResource(nil)
            self.unavailable = true
            return
        }
        self.recoveryAttempts += 1
        self.refreshInFlight = true
        let generation = self.loadGeneration
        Task { @MainActor in
            await self.load(path: path, replacing: resource, generation: generation)
            guard self.activePath == path, self.loadGeneration == generation else { return }
            self.refreshInFlight = false
        }
    }
}

#if canImport(WebKit) && (os(iOS) || os(macOS) || os(visionOS))
enum ChatInlineWidgetResourcePolicy {
    static func allowsStaticResources(contentSecurityPolicy: String?) -> Bool {
        guard let contentSecurityPolicy else { return false }
        let directives = contentSecurityPolicy.split(separator: ";").map { directive in
            directive.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
        }
        let defaultSource = directives.first { $0.first == "default-src" }?.dropFirst()
        let sandbox = directives.first { $0.first == "sandbox" }?.dropFirst()
        return defaultSource == ["'none'"] && sandbox == ["allow-scripts"]
    }
}

enum ChatInlineWidgetTLSPin {
    static func normalize(_ raw: String) -> String? {
        let stripped = raw.replacingOccurrences(
            of: #"(?i)^sha-?256\s*:?\s*"#,
            with: "",
            options: .regularExpression)
        let normalized = stripped.lowercased().filter(\.isHexDigit)
        return normalized.count == 64 ? normalized : nil
    }

    static func fingerprint(certificateData: Data) -> String {
        SHA256.hash(data: certificateData).map { String(format: "%02x", $0) }.joined()
    }

    static func matches(_ expected: String, trust: SecTrust) -> Bool {
        guard let expected = normalize(expected),
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let certificate = chain.first
        else { return false }
        return self.fingerprint(certificateData: SecCertificateCopyData(certificate) as Data) == expected
    }
}

struct ChatInlineWidgetContentProcessRecovery {
    enum Action: Equatable {
        case reload
        case fail
    }

    private var didReload = false

    mutating func nextAction() -> Action {
        guard !self.didReload else { return .fail }
        self.didReload = true
        return .reload
    }

    mutating func reset() {
        self.didReload = false
    }
}

@MainActor
private final class ChatInlineWidgetNavigationDelegate: NSObject, WKNavigationDelegate {
    var resource: OpenClawChatWidgetResource {
        didSet {
            if self.resource != oldValue {
                self.allowsStaticResources = false
                self.contentProcessRecovery.reset()
                self.snapshotCapture.invalidate()
            }
        }
    }

    let onFailure: @MainActor @Sendable () -> Void
    var onSnapshot: @MainActor @Sendable (ChatInlineWidgetSnapshotOutcome) -> Void
    private var contentProcessRecovery = ChatInlineWidgetContentProcessRecovery()
    private var allowsStaticResources = false
    let snapshotCapture = ChatInlineWidgetSnapshotCapture()

    init(
        resource: OpenClawChatWidgetResource,
        onFailure: @escaping @MainActor @Sendable () -> Void,
        onSnapshot: @escaping @MainActor @Sendable (ChatInlineWidgetSnapshotOutcome) -> Void)
    {
        self.resource = resource
        self.onFailure = onFailure
        self.onSnapshot = onSnapshot
    }

    func webView(
        _: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void)
    {
        if navigationAction.targetFrame?.isMainFrame == false {
            decisionHandler(.cancel)
            return
        }
        guard navigationAction.request.httpMethod?.caseInsensitiveCompare("GET") == .orderedSame,
              let url = navigationAction.request.url,
              self.matchesExpectedDocument(url)
        else {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(
        _: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void)
    {
        if navigationResponse.isForMainFrame {
            let response = navigationResponse.response as? HTTPURLResponse
            self.allowsStaticResources = ChatInlineWidgetResourcePolicy.allowsStaticResources(
                contentSecurityPolicy: response?.value(forHTTPHeaderField: "Content-Security-Policy"))
        }
        if navigationResponse.isForMainFrame,
           let response = navigationResponse.response as? HTTPURLResponse,
           response.statusCode >= 400
        {
            self.onFailure()
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation?, withError _: any Error) {
        self.onFailure()
    }

    func webView(_: WKWebView, didFail _: WKNavigation?, withError _: any Error) {
        self.onFailure()
    }

    func webView(
        _: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @MainActor @Sendable (
            URLSession.AuthChallengeDisposition,
            URLCredential?) -> Void)
    {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let expectedFingerprint = resource.tlsFingerprintSHA256
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        if !self.matchesExpectedProtectionSpace(challenge.protectionSpace), self.allowsStaticResources {
            // The Gateway's response CSP owns static origins; its certificate pin does not cover CDN hosts.
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard self.matchesExpectedProtectionSpace(challenge.protectionSpace),
              let trust = challenge.protectionSpace.serverTrust,
              ChatInlineWidgetTLSPin.matches(expectedFingerprint, trust: trust)
        else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            self.onFailure()
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // One same-document recovery handles incidental process loss. A second
        // termination enters the view's bounded capability-refresh/failure path.
        switch self.contentProcessRecovery.nextAction() {
        case .reload:
            webView.load(URLRequest(url: self.resource.url, cachePolicy: .reloadIgnoringLocalCacheData))
        case .fail:
            self.onFailure()
        }
    }

    private func matchesExpectedDocument(_ candidate: URL) -> Bool {
        guard var expected = URLComponents(url: self.resource.url, resolvingAgainstBaseURL: false),
              var candidate = URLComponents(url: candidate, resolvingAgainstBaseURL: false)
        else { return false }
        expected.fragment = nil
        candidate.fragment = nil
        return expected == candidate
    }

    private func matchesExpectedProtectionSpace(_ protectionSpace: URLProtectionSpace) -> Bool {
        GatewayTLSAuthority(url: self.resource.url)?.matches(
            host: protectionSpace.host,
            port: protectionSpace.port) == true
    }
}

@MainActor
private func makeChatInlineWidgetWebView(
    resource: OpenClawChatWidgetResource,
    allowsScripts: Bool,
    coordinator: ChatInlineWidgetNavigationDelegate) -> WKWebView
{
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = allowsScripts
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = coordinator
    webView.allowsLinkPreview = false
    webView.load(URLRequest(url: resource.url, cachePolicy: .reloadIgnoringLocalCacheData))
    return webView
}

#if os(iOS) || os(visionOS)
private struct ChatInlineWidgetWebView: UIViewRepresentable {
    let resource: OpenClawChatWidgetResource
    let loadGeneration: UUID
    let allowsScripts: Bool
    let snapshotRequest: ChatInlineWidgetSnapshotRequest?
    let onFailure: @MainActor @Sendable () -> Void
    let onSnapshot: @MainActor @Sendable (ChatInlineWidgetSnapshotOutcome) -> Void

    func makeCoordinator() -> ChatInlineWidgetNavigationDelegate {
        ChatInlineWidgetNavigationDelegate(
            resource: self.resource,
            onFailure: self.onFailure,
            onSnapshot: self.onSnapshot)
    }

    func makeUIView(context: Context) -> WKWebView {
        makeChatInlineWidgetWebView(
            resource: self.resource,
            allowsScripts: self.allowsScripts,
            coordinator: context.coordinator)
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onSnapshot = self.onSnapshot
        if context.coordinator.resource != self.resource {
            context.coordinator.resource = self.resource
            webView.load(URLRequest(url: self.resource.url, cachePolicy: .reloadIgnoringLocalCacheData))
        }
        context.coordinator.snapshotCapture.capture(
            self.snapshotRequest,
            from: webView,
            generation: self.loadGeneration,
            resource: self.resource,
            onSnapshot: context.coordinator.onSnapshot)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: ChatInlineWidgetNavigationDelegate) {
        coordinator.snapshotCapture.invalidate()
        webView.stopLoading()
        webView.navigationDelegate = nil
    }
}
#elseif os(macOS)
private struct ChatInlineWidgetWebView: NSViewRepresentable {
    let resource: OpenClawChatWidgetResource
    let loadGeneration: UUID
    let allowsScripts: Bool
    let snapshotRequest: ChatInlineWidgetSnapshotRequest?
    let onFailure: @MainActor @Sendable () -> Void
    let onSnapshot: @MainActor @Sendable (ChatInlineWidgetSnapshotOutcome) -> Void

    func makeCoordinator() -> ChatInlineWidgetNavigationDelegate {
        ChatInlineWidgetNavigationDelegate(
            resource: self.resource,
            onFailure: self.onFailure,
            onSnapshot: self.onSnapshot)
    }

    func makeNSView(context: Context) -> WKWebView {
        makeChatInlineWidgetWebView(
            resource: self.resource,
            allowsScripts: self.allowsScripts,
            coordinator: context.coordinator)
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onSnapshot = self.onSnapshot
        if context.coordinator.resource != self.resource {
            context.coordinator.resource = self.resource
            webView.load(URLRequest(url: self.resource.url, cachePolicy: .reloadIgnoringLocalCacheData))
        }
        context.coordinator.snapshotCapture.capture(
            self.snapshotRequest,
            from: webView,
            generation: self.loadGeneration,
            resource: self.resource,
            onSnapshot: context.coordinator.onSnapshot)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: ChatInlineWidgetNavigationDelegate) {
        coordinator.snapshotCapture.invalidate()
        webView.stopLoading()
        webView.navigationDelegate = nil
    }
}
#endif

#if os(iOS) || os(visionOS)
private struct ChatInlineWidgetSharedImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

private struct ChatInlineWidgetShareSheet: UIViewControllerRepresentable {
    let image: UIImage

    func makeUIViewController(context _: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [self.image], applicationActivities: nil)
    }

    func updateUIViewController(_: UIActivityViewController, context _: Context) {}
}
#elseif os(macOS)
extension NSImage {
    fileprivate var chatInlineWidgetPNGData: Data? {
        guard let tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiffRepresentation)
        else { return nil }
        return representation.representation(using: .png, properties: [:])
    }
}
#endif
#endif
#endif
