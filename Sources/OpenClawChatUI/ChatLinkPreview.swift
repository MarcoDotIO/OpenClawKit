import Darwin
import Foundation
import ImageIO
import Markdown
import Observation
import SwiftUI

let chatLinkPreviewTitleMaxCharacters = 120
let chatLinkPreviewDescriptionMaxCharacters = 200
let chatLinkPreviewBodyMaxBytes = 512 * 1024
let chatLinkPreviewImageBodyMaxBytes = 1024 * 1024
let chatLinkPreviewImageMaxPixelSize = 600
let chatLinkPreviewImageMaxSourcePixels = 64 * 1024 * 1024
private let chatLinkPreviewMaxRedirects = 3
private let chatLinkPreviewTimeout: TimeInterval = 6
private let chatLinkPreviewCacheEntries = 64
private let chatLinkPreviewImageCacheEntries = 32

struct ChatLinkPreviewMetadata: Equatable {
    let url: URL
    let title: String?
    let description: String?
    let imageURL: URL?
}

enum ChatLinkPreviewResult: Equatable {
    case loaded(ChatLinkPreviewMetadata)
    case failed
}

struct ChatLinkPreviewThumbnail: @unchecked Sendable {
    let image: CGImage
}

enum ChatLinkPreviewImageResult: @unchecked Sendable {
    case loaded(ChatLinkPreviewThumbnail)
    case failed
}

/// Returns HTTP(S) links in reading order, without treating code or image labels as citations.
func chatPreviewURLs(in markdown: String) -> [URL] {
    chatPreviewURLs(in: Document(parsing: markdown))
}

func chatFirstPreviewURL(in markdown: String) -> URL? {
    chatPreviewURLs(in: markdown).first
}

private func chatPreviewURLs(in markup: any Markup) -> [URL] {
    if markup is InlineCode || markup is CodeBlock || markup is Markdown.Image {
        return []
    }
    if let link = markup as? Markdown.Link {
        return link.destination.flatMap(chatSafeWebURL).map { [$0] } ?? []
    }
    if let text = markup as? Markdown.Text {
        return chatBarePreviewURLs(in: text.string)
    }
    return markup.children.flatMap(chatPreviewURLs)
}

private func chatBarePreviewURLs(in text: String) -> [URL] {
    let pattern = #"(?i)https?://[^\s<>\"`]+"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
        guard let range = Range(match.range, in: text) else { return nil }
        var candidate = String(text[range])
        while let last = candidate.last, ".,;:!?".contains(last) {
            candidate.removeLast()
        }
        for pair: (open: Character, close: Character) in [("(", ")"), ("[", "]"), ("{", "}")] {
            while candidate.hasSuffix(String(pair.close)),
                  candidate.count(of: pair.close) > candidate.count(of: pair.open)
            {
                candidate.removeLast()
            }
        }
        return chatSafeWebURL(candidate)
    }
}

extension String {
    fileprivate func count(of character: Character) -> Int {
        self.reduce(into: 0) { count, current in
            if current == character {
                count += 1
            }
        }
    }
}

private func chatSafeWebURL(_ value: String) -> URL? {
    guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
          let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https",
          url.host != nil
    else { return nil }
    return url
}

func parseChatOpenGraph(html: String, baseURL: URL) -> ChatLinkPreviewResult {
    var title: String?
    var description: String?
    var image: String?

    for tag in chatHTMLTags(named: "meta", in: html) {
        let attributes = chatHTMLAttributes(in: tag)
        let property = (attributes["property"] ?? attributes["name"])?.lowercased()
        guard let content = attributes["content"] else { continue }
        switch property {
        case "og:title" where title == nil:
            title = content
        case "og:description" where description == nil:
            description = content
        case "og:image" where image == nil, "og:image:url" where image == nil:
            image = content
        default:
            break
        }
    }

    let parsedTitle = chatSanitizeMetadataText(
        title ?? chatHTMLTitle(in: html),
        maxCharacters: chatLinkPreviewTitleMaxCharacters)
    let parsedDescription = chatSanitizeMetadataText(
        description,
        maxCharacters: chatLinkPreviewDescriptionMaxCharacters)
    let imageURL = image.flatMap { value -> URL? in
        let decoded = chatDecodeHTMLEntities(value).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let resolved = URL(string: decoded, relativeTo: baseURL)?.absoluteURL,
              chatSafeWebURL(resolved.absoluteString) != nil
        else { return nil }
        return resolved
    }
    guard parsedTitle != nil || parsedDescription != nil || imageURL != nil else {
        return .failed
    }
    return .loaded(ChatLinkPreviewMetadata(
        url: baseURL,
        title: parsedTitle,
        description: parsedDescription,
        imageURL: imageURL))
}

private func chatHTMLTags(named name: String, in html: String) -> [String] {
    var tags: [String] = []
    var searchStart = html.startIndex
    let prefix = "<\(name)"
    while searchStart < html.endIndex,
          let start = html.range(
              of: prefix,
              options: [.caseInsensitive],
              range: searchStart..<html.endIndex)?.lowerBound
    {
        let boundaryIndex = html.index(start, offsetBy: prefix.count, limitedBy: html.endIndex)
        if let boundaryIndex,
           boundaryIndex < html.endIndex,
           !html[boundaryIndex].isWhitespace,
           html[boundaryIndex] != "/",
           html[boundaryIndex] != ">"
        {
            searchStart = html.index(after: start)
            continue
        }
        guard let end = chatHTMLTagEnd(in: html, after: boundaryIndex ?? html.endIndex) else { break }
        tags.append(String(html[start...end]))
        searchStart = html.index(after: end)
    }
    return tags
}

private func chatHTMLTagEnd(in html: String, after start: String.Index) -> String.Index? {
    var quote: Character?
    var index = start
    while index < html.endIndex {
        let character = html[index]
        if quote == nil, character == "\"" || character == "'" {
            quote = character
        } else if character == quote {
            quote = nil
        } else if character == ">", quote == nil {
            return index
        }
        index = html.index(after: index)
    }
    return nil
}

private func chatHTMLAttributes(in tag: String) -> [String: String] {
    let pattern = #"([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s>]+))"#
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return [:] }
    let range = NSRange(tag.startIndex..<tag.endIndex, in: tag)
    var attributes: [String: String] = [:]
    for match in expression.matches(in: tag, range: range) {
        guard let nameRange = Range(match.range(at: 1), in: tag) else { continue }
        let valueRange = (2...4).lazy
            .map { match.range(at: $0) }
            .first { $0.location != NSNotFound }
            .flatMap { Range($0, in: tag) }
        guard let valueRange else { continue }
        let name = String(tag[nameRange]).lowercased()
        if attributes[name] == nil {
            attributes[name] = String(tag[valueRange])
        }
    }
    return attributes
}

private func chatHTMLTitle(in html: String) -> String? {
    let pattern = #"(?is)<title(?:\s[^>]*)?>(.*?)</title\s*>"#
    guard let expression = try? NSRegularExpression(pattern: pattern),
          let match = expression.firstMatch(
              in: html,
              range: NSRange(html.startIndex..<html.endIndex, in: html)),
          let range = Range(match.range(at: 1), in: html)
    else { return nil }
    return String(html[range])
}

private func chatSanitizeMetadataText(_ value: String?, maxCharacters: Int) -> String? {
    guard let value else { return nil }
    let withoutControls = chatDecodeHTMLEntities(value).unicodeScalars.filter {
        !CharacterSet.controlCharacters.contains($0)
    }
    let collapsed = String(String.UnicodeScalarView(withoutControls))
        .split(whereSeparator: \.isWhitespace)
        .joined(separator: " ")
    return collapsed.isEmpty ? nil : String(collapsed.prefix(maxCharacters))
}

private func chatDecodeHTMLEntities(_ value: String) -> String {
    let pattern = #"&#(x[0-9a-fA-F]+|[0-9]+);?|&(amp|lt|gt|quot|apos|nbsp);"#
    guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
        return value
    }
    var decoded = value
    let matches = expression.matches(
        in: value,
        range: NSRange(value.startIndex..<value.endIndex, in: value))
    for match in matches.reversed() {
        guard let fullRange = Range(match.range, in: decoded) else { continue }
        let numeric = Range(match.range(at: 1), in: value).map { String(value[$0]) }
        let named = Range(match.range(at: 2), in: value).map { String(value[$0]).lowercased() }
        let replacement: String
        if let numeric {
            let isHex = numeric.lowercased().hasPrefix("x")
            let digits = isHex ? String(numeric.dropFirst()) : numeric
            replacement = Int(digits, radix: isHex ? 16 : 10)
                .flatMap(UnicodeScalar.init)
                .map(String.init) ?? String(decoded[fullRange])
        } else {
            replacement = switch named {
            case "amp": "&"
            case "lt": "<"
            case "gt": ">"
            case "quot": "\""
            case "apos": "'"
            case "nbsp": " "
            default: String(decoded[fullRange])
            }
        }
        decoded.replaceSubrange(fullRange, with: replacement)
    }
    return decoded
}

/// Private-network name suffixes that never resolve on the public internet (RFC 6762, RFC 8375,
/// ICANN's reserved `.internal`, and common split-horizon zones).
private let chatLinkPreviewPrivateHostSuffixes = [
    ".localhost", ".local", ".internal", ".home.arpa", ".lan", ".intranet", ".corp", ".localdomain",
]

/// Pre-connect host check: rejects unsafe literals and names that can only address a private network.
func chatLinkPreviewAllowsHost(_ url: URL) -> Bool {
    guard chatSafeWebURL(url.absoluteString) != nil, let rawHost = chatLinkPreviewHost(url) else { return false }
    if let address = chatParsedIPAddress(rawHost) {
        return chatLinkPreviewAllowsAddress(address)
    }
    // Single-label names (`router`, `nas`) resolve through local search domains and are exempt
    // from App Transport Security under NSAllowsLocalNetworking.
    return rawHost.contains(".")
        && rawHost != "localhost"
        && !chatLinkPreviewPrivateHostSuffixes.contains(where: { rawHost.hasSuffix($0) })
}

/// Lowercased host without surrounding dots or IPv6 brackets; `nil` for zone ids or no host.
private func chatLinkPreviewHost(_ url: URL) -> String? {
    guard var host = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")),
          !host.isEmpty,
          !host.contains("%")
    else { return nil }
    if host.hasPrefix("["), host.hasSuffix("]") {
        host.removeFirst()
        host.removeLast()
    }
    return host
}

/// Resolves the URL's host before any request is sent and requires every address to be public.
///
/// URLSession resolves again when it connects, so this does not stop DNS rebinding; the
/// post-connect peer check (`publicConnectionsOnly`) still discards those responses. It does keep
/// the request (path and query included) from reaching hosts whose public DNS already points at a
/// private network. Fails closed when resolution fails or exceeds the preview timeout.
func chatLinkPreviewResolvesToPublicAddresses(_ url: URL) async -> Bool {
    guard let host = chatLinkPreviewHost(url) else { return false }
    if let address = chatParsedIPAddress(host) {
        return chatLinkPreviewAllowsAddress(address)
    }
    return await withCheckedContinuation { continuation in
        let resume = ChatLinkPreviewResumeOnce(continuation)
        let queue = DispatchQueue.global(qos: .utility)
        queue.asyncAfter(deadline: .now() + chatLinkPreviewTimeout) { resume.resume(false) }
        queue.async {
            let addresses = chatResolvedIPAddresses(host)
            resume.resume(!addresses.isEmpty && addresses.allSatisfy(chatLinkPreviewAllowsAddress))
        }
    }
}

private final class ChatLinkPreviewResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Bool) {
        let continuation = self.lock.withLock { () -> CheckedContinuation<Bool, Never>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: value)
    }
}

/// Every address `getaddrinfo` returns for `host` (empty on failure). Blocking; call off the main thread.
private func chatResolvedIPAddresses(_ host: String) -> [ChatIPAddress] {
    var hints = addrinfo()
    hints.ai_family = AF_UNSPEC
    hints.ai_socktype = SOCK_STREAM
    hints.ai_flags = AI_DEFAULT
    var list: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, nil, &hints, &list) == 0, let list else { return [] }
    defer { freeaddrinfo(list) }
    var addresses: [ChatIPAddress] = []
    var cursor: UnsafeMutablePointer<addrinfo>? = list
    while let entry = cursor?.pointee {
        defer { cursor = entry.ai_next }
        guard let socketAddress = entry.ai_addr else { continue }
        switch Int32(socketAddress.pointee.sa_family) {
        case AF_INET:
            let address = socketAddress.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            addresses.append(.v4(withUnsafeBytes(of: address) { Array($0) }))
        case AF_INET6:
            let address = socketAddress.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
            addresses.append(.v6(withUnsafeBytes(of: address) { Array($0) }))
        default:
            continue
        }
    }
    return addresses
}

private enum ChatIPAddress {
    case v4([UInt8])
    case v6([UInt8])
}

private func chatParsedIPAddress(_ host: String) -> ChatIPAddress? {
    var ipv4 = in_addr()
    if host.withCString({ inet_aton($0, &ipv4) }) == 1 {
        return .v4(withUnsafeBytes(of: &ipv4) { Array($0) })
    }
    var ipv6 = in6_addr()
    if host.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
        return .v6(withUnsafeBytes(of: &ipv6) { Array($0) })
    }
    return nil
}

private func chatLinkPreviewAllowsAddress(_ address: ChatIPAddress) -> Bool {
    switch address {
    case let .v4(bytes):
        guard bytes.count == 4 else { return false }
        let first = Int(bytes[0])
        let second = Int(bytes[1])
        let third = Int(bytes[2])
        return !(first == 0
            || first == 10
            || (first == 100 && (64...127).contains(second))
            || first == 127
            || (first == 169 && second == 254)
            || (first == 172 && (16...31).contains(second))
            || (first == 192 && second == 0 && (third == 0 || third == 2))
            || (first == 192 && second == 88 && third == 99)
            || (first == 192 && second == 168)
            || (first == 198 && (18...19).contains(second))
            || (first == 198 && second == 51 && third == 100)
            || (first == 203 && second == 0 && third == 113)
            || first >= 224)
    case let .v6(bytes):
        guard bytes.count == 16 else { return false }
        // IPv4-mapped (::ffff:0:0/96) and well-known-prefix NAT64 (64:ff9b::/96, RFC 6052) peers embed
        // the real IPv4 destination: judge that address. DNS64 synthesizes these on IPv6-only networks.
        // 64:ff9b:1::/48 (RFC 8215 local use) falls through and is rejected as non-global below.
        if bytes.hasPrefix([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF])
            || bytes.hasPrefix([0x00, 0x64, 0xFF, 0x9B, 0, 0, 0, 0, 0, 0, 0, 0])
        {
            return chatLinkPreviewAllowsAddress(.v4(Array(bytes[12..<16])))
        }
        let globalUnicast = bytes[0] & 0xE0 == 0x20
        let special2001 = bytes.hasPrefix([0x20, 0x01, 0x00])
        let orchid = special2001 && (bytes[3] & 0xF0 == 0x10 || bytes[3] & 0xF0 == 0x20)
        return globalUnicast
            && !bytes.hasPrefix([0x20, 0x01, 0x00, 0x00])
            && !bytes.hasPrefix([0x20, 0x01, 0x00, 0x02])
            && !orchid
            && !bytes.hasPrefix([0x20, 0x01, 0x0D, 0xB8])
            && !bytes.hasPrefix([0x20, 0x02])
            && !(bytes.hasPrefix([0x3F, 0xFF]) && bytes[2] & 0xF0 == 0)
    }
}

/// Post-connect check for one transaction's peer address as URLSession metrics report it.
func chatLinkPreviewAllowsRemoteAddress(_ address: String) -> Bool {
    guard let parsed = chatParsedIPAddress(address) else { return false }
    return chatLinkPreviewAllowsAddress(parsed)
}

extension [UInt8] {
    fileprivate func hasPrefix(_ prefix: [UInt8]) -> Bool {
        self.count >= prefix.count && self.indices.prefix(prefix.count).allSatisfy { self[$0] == prefix[$0] }
    }
}

func chatLinkPreviewRedirectURL(
    request: URLRequest,
    redirectCount: Int,
    hostPolicy: (URL) -> Bool = chatLinkPreviewAllowsHost) -> URL?
{
    guard redirectCount < chatLinkPreviewMaxRedirects,
          let url = request.url,
          chatSafeWebURL(url.absoluteString) != nil,
          hostPolicy(url)
    else { return nil }
    return url
}

struct ChatLinkPreviewBodyAccumulator {
    private let maxBytes: Int
    private(set) var data = Data()

    init(maxBytes: Int = chatLinkPreviewBodyMaxBytes) {
        self.maxBytes = maxBytes
    }

    mutating func append(_ chunk: Data) -> Bool {
        let remaining = self.maxBytes - self.data.count
        guard remaining > 0 else { return true }
        self.data.append(chunk.prefix(remaining))
        return chunk.count > remaining
    }
}

private enum ChatLinkPreviewFetchMode {
    case metadata
    case image

    var accept: String {
        switch self {
        case .metadata: "text/html"
        case .image: "image/*"
        }
    }

    var allowedMIMETypes: Set<String> {
        switch self {
        case .metadata: ["text/html"]
        case .image: ["image/jpeg", "image/png", "image/webp", "image/gif"]
        }
    }

    var maxBodyBytes: Int {
        switch self {
        case .metadata: chatLinkPreviewBodyMaxBytes
        case .image: chatLinkPreviewImageBodyMaxBytes
        }
    }

    var rejectsCappedBody: Bool {
        self == .image
    }
}

final class ChatLinkPreviewFetcher: @unchecked Sendable {
    typealias HostPolicy = @Sendable (URL) -> Bool
    typealias ResolutionPolicy = @Sendable (URL) async -> Bool
    typealias ConnectionPolicy = @Sendable ([String?]) -> Bool

    private let configuration: URLSessionConfiguration
    private let timeout: TimeInterval
    private let hostPolicy: HostPolicy
    private let resolutionPolicy: ResolutionPolicy
    private let connectionPolicy: ConnectionPolicy

    /// Three checks guard every request and redirect hop: the host literal/name (`hostPolicy`),
    /// the resolved addresses before sending (`resolutionPolicy`), and each transaction's actual
    /// peer address after connecting (`connectionPolicy`).
    init(
        configuration: URLSessionConfiguration = .chatLinkPreview,
        timeout: TimeInterval = chatLinkPreviewTimeout,
        hostPolicy: @escaping HostPolicy = chatLinkPreviewAllowsHost,
        resolutionPolicy: @escaping ResolutionPolicy = chatLinkPreviewResolvesToPublicAddresses,
        connectionPolicy: @escaping ConnectionPolicy = ChatLinkPreviewFetcher.publicConnectionsOnly)
    {
        self.configuration = configuration
        self.timeout = timeout
        self.hostPolicy = hostPolicy
        self.resolutionPolicy = resolutionPolicy
        self.connectionPolicy = connectionPolicy
    }

    func fetch(_ originalURL: URL) async -> ChatLinkPreviewResult {
        guard let response = await self.fetchResponse(originalURL, mode: .metadata),
              let html = String(bytes: response.data, encoding: .utf8)
        else { return .failed }
        return switch parseChatOpenGraph(html: html, baseURL: response.url) {
        case let .loaded(metadata):
            .loaded(ChatLinkPreviewMetadata(
                url: originalURL,
                title: metadata.title,
                description: metadata.description,
                imageURL: metadata.imageURL))
        case .failed:
            .failed
        }
    }

    func fetchImage(_ originalURL: URL) async -> ChatLinkPreviewImageResult {
        guard let response = await self.fetchResponse(originalURL, mode: .image),
              let thumbnail = chatDecodeLinkPreviewThumbnail(
                  response.data,
                  mimeType: response.mimeType)
        else { return .failed }
        return .loaded(thumbnail)
    }

    private func fetchResponse(
        _ originalURL: URL,
        mode: ChatLinkPreviewFetchMode) async -> ChatLinkPreviewResponse?
    {
        guard chatSafeWebURL(originalURL.absoluteString) != nil,
              self.hostPolicy(originalURL),
              await self.resolutionPolicy(originalURL),
              !Task.isCancelled
        else {
            return nil
        }
        let delegate = ChatLinkPreviewSessionDelegate(
            mode: mode,
            hostPolicy: self.hostPolicy,
            resolutionPolicy: self.resolutionPolicy,
            connectionPolicy: self.connectionPolicy)
        let session = URLSession(configuration: self.configuration, delegate: delegate, delegateQueue: nil)
        var request = URLRequest(url: originalURL, timeoutInterval: self.timeout)
        request.httpMethod = "GET"
        request.setValue(mode.accept, forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false
        let task = session.dataTask(with: request)
        let deadline = Task {
            try? await Task.sleep(for: .seconds(self.timeout))
            guard !Task.isCancelled else { return }
            delegate.abort(task)
        }
        let response = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                delegate.start(continuation)
                task.resume()
            }
        } onCancel: {
            delegate.abort(task)
        }
        deadline.cancel()
        session.finishTasksAndInvalidate()

        return response
    }

    static func publicConnectionsOnly(_ addresses: [String?]) -> Bool {
        !addresses.isEmpty && addresses.allSatisfy { address in
            address.map(chatLinkPreviewAllowsRemoteAddress) == true
        }
    }
}

extension URLSessionConfiguration {
    fileprivate static var chatLinkPreview: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = chatLinkPreviewTimeout
        configuration.timeoutIntervalForResource = chatLinkPreviewTimeout
        configuration.connectionProxyDictionary = [:]
        return configuration
    }
}

private struct ChatLinkPreviewResponse {
    let url: URL
    let mimeType: String
    let data: Data
}

private final class ChatLinkPreviewSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let mode: ChatLinkPreviewFetchMode
    private let hostPolicy: ChatLinkPreviewFetcher.HostPolicy
    private let resolutionPolicy: ChatLinkPreviewFetcher.ResolutionPolicy
    private let connectionPolicy: ChatLinkPreviewFetcher.ConnectionPolicy
    private var continuation: CheckedContinuation<ChatLinkPreviewResponse?, Never>?
    private var responseURL: URL?
    private var body: ChatLinkPreviewBodyAccumulator
    private var responseMIMEType: String?
    private var redirectCount = 0
    private var remoteAddresses: [String?] = []
    private var bodyCapped = false
    private var failed = false
    private var completed = false

    init(
        mode: ChatLinkPreviewFetchMode,
        hostPolicy: @escaping ChatLinkPreviewFetcher.HostPolicy,
        resolutionPolicy: @escaping ChatLinkPreviewFetcher.ResolutionPolicy,
        connectionPolicy: @escaping ChatLinkPreviewFetcher.ConnectionPolicy)
    {
        self.mode = mode
        self.hostPolicy = hostPolicy
        self.resolutionPolicy = resolutionPolicy
        self.connectionPolicy = connectionPolicy
        self.body = ChatLinkPreviewBodyAccumulator(maxBytes: mode.maxBodyBytes)
    }

    func start(_ continuation: CheckedContinuation<ChatLinkPreviewResponse?, Never>) {
        let didAlreadyComplete = self.lock.withLock {
            if self.completed {
                return true
            }
            self.continuation = continuation
            return false
        }
        if didAlreadyComplete {
            continuation.resume(returning: nil)
        }
    }

    func abort(_ task: URLSessionTask) {
        task.cancel()
        self.complete(nil)
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void)
    {
        let nextURL = self.lock.withLock {
            let url = chatLinkPreviewRedirectURL(
                request: request,
                redirectCount: self.redirectCount,
                hostPolicy: self.hostPolicy)
            if url != nil {
                self.redirectCount += 1
            }
            return url
        }
        guard let nextURL else {
            completionHandler(nil)
            return
        }
        // Each hop gets the same pre-send address check as the original URL.
        let resolutionPolicy = self.resolutionPolicy
        Task {
            completionHandler(await resolutionPolicy(nextURL) ? request : nil)
        }
    }

    func urlSession(
        _: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void)
    {
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let mimeType = http.mimeType?.lowercased(),
              self.mode.allowedMIMETypes.contains(mimeType),
              let url = http.url
        else {
            self.lock.withLock { self.failed = true }
            completionHandler(.cancel)
            return
        }
        self.lock.withLock {
            self.responseURL = url
            self.responseMIMEType = mimeType
        }
        completionHandler(.allow)
    }

    func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let reachedCap = self.lock.withLock {
            let reachedCap = self.body.append(data)
            if reachedCap {
                self.bodyCapped = true
            }
            return reachedCap
        }
        if reachedCap {
            dataTask.cancel()
        }
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        // URLSession has no DNS hook. Pre-flight rejects unsafe literals and names, then resolves
        // the host; after connection, every transaction's actual peer address is required and
        // re-validated (DNS rebinding). The body is discarded if Foundation omits metrics or
        // reports any non-public address.
        self.lock.withLock {
            self.remoteAddresses.append(contentsOf: metrics.transactionMetrics.map(\.remoteAddress))
        }
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let result = self.lock.withLock { () -> ChatLinkPreviewResponse? in
            guard !self.failed,
                  error == nil || self.bodyCapped,
                  let responseURL,
                  let responseMIMEType,
                  !(self.mode.rejectsCappedBody && self.bodyCapped),
                  self.connectionPolicy(self.remoteAddresses)
            else { return nil }
            return ChatLinkPreviewResponse(
                url: responseURL,
                mimeType: responseMIMEType,
                data: self.body.data)
        }
        self.complete(result)
    }

    private func complete(_ result: ChatLinkPreviewResponse?) {
        let continuation = self.lock.withLock { () -> CheckedContinuation<ChatLinkPreviewResponse?, Never>? in
            guard !self.completed else { return nil }
            self.completed = true
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: result)
    }
}

func chatDecodeLinkPreviewThumbnail(
    _ data: Data,
    mimeType: String,
    maxSourcePixels: Int = chatLinkPreviewImageMaxSourcePixels) -> ChatLinkPreviewThumbnail?
{
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          CGImageSourceGetCount(source) > 0,
          mimeType != "image/gif" || CGImageSourceGetCount(source) == 1,
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
          let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
          width > 0,
          height > 0,
          height <= maxSourcePixels,
          width <= maxSourcePixels / height
    else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: chatLinkPreviewImageMaxPixelSize,
        kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
        return nil
    }
    return ChatLinkPreviewThumbnail(image: image)
}

@MainActor
final class ChatLinkPreviewStore {
    typealias Fetch = @Sendable (URL) async -> ChatLinkPreviewResult

    private let fetch: Fetch
    private let maxEntries: Int
    private var cache: [URL: ChatLinkPreviewResult] = [:]
    private var recency: [URL] = []

    init(maxEntries: Int = chatLinkPreviewCacheEntries, fetch: @escaping Fetch) {
        self.maxEntries = maxEntries
        self.fetch = fetch
    }

    func get(_ url: URL) async -> ChatLinkPreviewResult {
        if let cached = self.cache[url] {
            self.touch(url)
            return cached
        }
        let result = await self.fetch(url)
        guard !Task.isCancelled else { return result }
        self.cache[url] = result
        self.touch(url)
        while self.recency.count > self.maxEntries, let evicted = self.recency.first {
            self.recency.removeFirst()
            self.cache.removeValue(forKey: evicted)
        }
        return result
    }

    private func touch(_ url: URL) {
        self.recency.removeAll { $0 == url }
        self.recency.append(url)
    }
}

@MainActor
final class ChatLinkPreviewImageStore {
    typealias Fetch = @Sendable (URL) async -> ChatLinkPreviewImageResult

    private let fetch: Fetch
    private let maxEntries: Int
    private var cache: [URL: ChatLinkPreviewImageResult] = [:]
    private var recency: [URL] = []

    init(maxEntries: Int = chatLinkPreviewImageCacheEntries, fetch: @escaping Fetch) {
        self.maxEntries = maxEntries
        self.fetch = fetch
    }

    func get(_ url: URL) async -> ChatLinkPreviewImageResult {
        if let cached = self.cache[url] {
            self.touch(url)
            return cached
        }
        let result = await self.fetch(url)
        guard !Task.isCancelled else { return result }
        self.cache[url] = result
        self.touch(url)
        while self.recency.count > self.maxEntries, let evicted = self.recency.first {
            self.recency.removeFirst()
            self.cache.removeValue(forKey: evicted)
        }
        return result
    }

    private func touch(_ url: URL) {
        self.recency.removeAll { $0 == url }
        self.recency.append(url)
    }
}

@MainActor
private let chatLinkPreviewStore = ChatLinkPreviewStore(fetch: ChatLinkPreviewFetcher().fetch)

@MainActor
private let chatLinkPreviewImageStore = ChatLinkPreviewImageStore(fetch: ChatLinkPreviewFetcher().fetchImage)

@MainActor
@Observable
final class ChatLinkPreviewModel {
    typealias MetadataFetch = @Sendable (URL) async -> ChatLinkPreviewResult
    typealias ImageFetch = @Sendable (URL) async -> ChatLinkPreviewImageResult

    var expanded = false
    private(set) var result: ChatLinkPreviewResult?
    private(set) var imageResult: ChatLinkPreviewImageResult?
    private let metadataFetch: MetadataFetch
    private let imageFetch: ImageFetch

    init(metadataFetch: @escaping MetadataFetch, imageFetch: @escaping ImageFetch) {
        self.metadataFetch = metadataFetch
        self.imageFetch = imageFetch
    }

    var imageURL: URL? {
        guard case let .loaded(metadata) = self.result else { return nil }
        return metadata.imageURL
    }

    func loadMetadata(_ url: URL) async {
        guard self.expanded, self.result == nil else { return }
        self.result = await self.metadataFetch(url)
    }

    func loadImage() async {
        guard self.expanded,
              self.imageResult == nil,
              let imageURL = self.imageURL
        else { return }
        let result = await self.imageFetch(imageURL)
        guard !Task.isCancelled else { return }
        self.imageResult = result
    }
}

// ChatUI views ship on iOS, macOS and visionOS; the fetcher, parser and address policy above build everywhere.
#if os(iOS) || os(macOS) || os(visionOS)
extension OpenClawChatDisplayOptions {
    /// Shows a collapsed preview chip for the first web link in user and assistant messages. Off by
    /// default: expanding a chip fetches the page and its image from this device (size- and
    /// redirect-capped, without cookies or credentials), which reveals the viewer's network address to
    /// that site. Private-network literals and names are refused, and hostnames must resolve to public
    /// addresses before each request is sent. A host that switches its DNS to a private address between
    /// that check and the connection (DNS rebinding) can still receive one cookie-less GET; its
    /// response is discarded after the peer address check.
    public static let linkPreviews = Self(rawValue: 1 << 2)
}

@MainActor
struct ChatLinkPreview: View {
    @Environment(\.openURL) private var openURL
    let url: URL
    @State private var model: ChatLinkPreviewModel

    init(url: URL) {
        self.url = url
        self._model = State(initialValue: ChatLinkPreviewModel(
            metadataFetch: chatLinkPreviewStore.get,
            imageFetch: chatLinkPreviewImageStore.get))
    }

    var body: some View {
        if self.model.expanded {
            self.expandedCard
                .task(id: self.url) {
                    await self.model.loadMetadata(self.url)
                }
                .task(id: self.model.imageURL) {
                    await self.model.loadImage()
                }
        } else {
            self.collapsedChip
        }
    }

    private var collapsedChip: some View {
        Button {
            self.model.expanded = true
        } label: {
            HStack(spacing: 6) {
                Text(verbatim: String(
                    format: String(localized: "Preview · %@"),
                    self.domain))
                    .font(OpenClawChatTypography.captionSemiBold)
                    .foregroundStyle(OpenClawChatTheme.assistantText.opacity(0.65))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .foregroundStyle(OpenClawChatTheme.assistantText.opacity(0.65))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(OpenClawChatTheme.subtleCard)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(OpenClawChatTheme.divider, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            String(
                format: String(localized: "Expand link preview for %@"),
                self.domain))
    }

    private var expandedCard: some View {
        Button {
            self.openURL(self.url)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                if case let .loaded(thumbnail) = self.model.imageResult {
                    Image(decorative: thumbnail.image, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .frame(height: 120)
                        .clipped()
                        .accessibilityHidden(true)
                }
                Text(self.domain)
                    .font(OpenClawChatTypography.caption2)
                    .foregroundStyle(OpenClawChatTheme.assistantText.opacity(0.65))
                    .lineLimit(1)
                switch self.model.result {
                case nil:
                    Text("Loading preview…")
                        .font(OpenClawChatTypography.caption)
                        .foregroundStyle(OpenClawChatTheme.assistantText.opacity(0.65))
                case .failed:
                    Text("No preview available")
                        .font(OpenClawChatTypography.callout)
                        .foregroundStyle(OpenClawChatTheme.assistantText.opacity(0.65))
                case let .loaded(metadata):
                    if let title = metadata.title {
                        Text(title)
                            .font(OpenClawChatTypography.footnoteSemiBold)
                            .foregroundStyle(OpenClawChatTheme.assistantText)
                            .lineLimit(2)
                    }
                    if let description = metadata.description {
                        Text(description)
                            .font(OpenClawChatTypography.caption)
                            .foregroundStyle(OpenClawChatTheme.assistantText.opacity(0.65))
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(OpenClawChatTheme.subtleCard)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(OpenClawChatTheme.divider, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            String(
                format: String(localized: "Open %@"),
                self.domain))
    }

    private var domain: String {
        let host = self.url.host?.lowercased() ?? self.url.absoluteString
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
#endif
