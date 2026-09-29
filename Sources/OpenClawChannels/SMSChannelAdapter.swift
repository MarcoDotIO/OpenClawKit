import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenClawCore
import OpenClawProtocol

/// Twilio helpers shared by the SMS adapter (port of upstream `extensions/sms/src/twilio.ts`,
/// `phone.ts` and `public-webhook-url.ts`).
public enum TwilioSMS {
    /// Twilio REST API host; outbound calls and media downloads are restricted to it.
    public static let apiHost = "api.twilio.com"
    /// Maximum `Body` length accepted by Twilio.
    public static let messageBodyMaxLength = 1_600
    /// Maximum outbound media URLs per MMS.
    public static let maxOutboundMedia = 10
    /// Maximum inbound media downloads per message.
    public static let maxInboundMedia = 10
    /// MMS size budget (5 MiB).
    public static let mmsMaxBytes = 5 * 1_024 * 1_024
    /// Empty TwiML acknowledgement.
    public static let emptyTwiML = #"<?xml version="1.0" encoding="UTF-8"?><Response></Response>"#
    /// TwiML content type.
    public static let twimlContentType = "text/xml; charset=utf-8"

    /// Normalizes a phone number: strips `sms:`/`twilio-sms:`, adds `+`, keeps digits.
    /// - Parameter raw: Raw number.
    /// - Returns: Normalized number (empty for blank input).
    public static func normalizePhoneNumber(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["twilio-sms:", "sms:"] where trimmed.lowercased().hasPrefix(prefix) {
            trimmed = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !trimmed.isEmpty else { return "" }
        let withPlus = trimmed.hasPrefix("+") ? trimmed : "+" + trimmed
        return String(withPlus.filter { $0 == "+" || $0.isASCII && $0.isNumber })
    }

    /// Whether a value is an E.164 phone number (`^\+[1-9]\d{6,14}$`).
    /// - Parameter raw: Candidate.
    /// - Returns: `true` when valid.
    public static func looksLikePhoneNumber(_ raw: String) -> Bool {
        self.normalizePhoneNumber(raw).range(of: "^\\+[1-9][0-9]{6,14}$", options: .regularExpression) != nil
    }

    /// Resolves the inbound sender from Twilio's `From` (plain numbers and `rcs:` addresses only).
    /// - Parameter from: Raw `From` field.
    /// - Returns: Normalized E.164 sender, or `nil` for other channel addresses.
    public static func inboundSender(_ from: String) -> String? {
        let trimmed = from.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var address = trimmed
        if let match = trimmed.range(of: "^([A-Za-z][A-Za-z0-9-]*):", options: .regularExpression) {
            let kind = trimmed[match].dropLast().lowercased()
            guard kind == "rcs" else { return nil }
            address = String(trimmed[match.upperBound...])
        }
        let phone = self.normalizePhoneNumber(address)
        return self.looksLikePhoneNumber(phone) ? phone : nil
    }

    /// Whether a public webhook URL is usable (absolute http(s), no credentials, valid host).
    /// - Parameter value: Candidate URL.
    /// - Returns: `true` when valid.
    public static func isValidPublicWebhookURL(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: "^https?://", options: [.regularExpression, .caseInsensitive]) != nil,
              !trimmed.contains(where: { $0.isWhitespace || $0 == "\\" }),
              let components = URLComponents(string: trimmed),
              components.user == nil, components.password == nil,
              let host = components.host?.lowercased(), !host.isEmpty
        else {
            return false
        }
        let blocked: Set<String> = ["localhost", "0.0.0.0", "127.0.0.1", "::1"]
        return !blocked.contains(host) && (host.contains(".") || host.contains(":"))
    }

    /// The URL Twilio signed: the public URL without its fragment; the request query is appended
    /// when the public URL has none.
    /// - Parameters:
    ///   - publicWebhookURL: Configured public webhook URL.
    ///   - requestURL: URL of the received request.
    /// - Returns: Signature base URL.
    public static func signatureURL(publicWebhookURL: String, requestURL: URL?) -> String {
        let trimmed = publicWebhookURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? trimmed
        if base.contains("?") {
            return base
        }
        guard let query = requestURL?.query, !query.isEmpty else { return base }
        return base + "?" + query
    }

    /// Delivery `StatusCallback` URL with Twilio connection overrides (`rp`, `rt`, `rc`) in the fragment.
    /// - Parameter publicWebhookURL: Configured public webhook URL.
    /// - Returns: Callback URL, or `nil` when the public URL is invalid.
    public static func statusCallbackURL(publicWebhookURL: String) -> String? {
        let trimmed = publicWebhookURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, self.isValidPublicWebhookURL(trimmed) else { return nil }
        let pieces = trimmed.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let base = String(pieces[0])
        var overrides: [(String, String)] = pieces.count > 1
            ? (URLComponents(string: "x:?" + pieces[1])?.queryItems ?? []).map { ($0.name, $0.value ?? "") }
            : []
        func set(_ key: String, _ value: String) {
            if let index = overrides.firstIndex(where: { $0.0 == key }) {
                overrides[index] = (key, value)
                overrides = overrides.enumerated().filter { $0.offset == index || $0.element.0 != key }.map(\.element)
            } else {
                overrides.append((key, value))
            }
        }
        var policies: [String] = []
        for (key, value) in overrides where key == "rp" {
            for policy in value.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !policy.isEmpty {
                if !policies.contains(policy) {
                    policies.append(policy)
                }
            }
        }
        if policies.isEmpty {
            policies = ["ct"]
        }
        let lowered = Set(policies.map { $0.lowercased() })
        if !lowered.contains("all") {
            for required in ["ct", "rt", "5xx"] where !lowered.contains(required) {
                policies.append(required)
            }
        }
        set("rp", policies.joined(separator: ","))
        let readTimeout = overrides.first { $0.0 == "rt" }.flatMap { Int($0.1) }.flatMap { (100...15_000).contains($0) ? $0 : nil } ?? 5_000
        set("rt", String(readTimeout))
        let retries = overrides.first { $0.0 == "rc" }.flatMap { Int($0.1) }.flatMap { (1...5).contains($0) ? $0 : nil } ?? 1
        set("rc", String(retries))
        let fragment = overrides.map { "\(ChannelHTTP.formEscape($0.0))=\(ChannelHTTP.formEscape($0.1))" }.joined(separator: "&")
            .replacingOccurrences(of: "%2C", with: ",")
        let callback = "\(base)#\(fragment)"
        return callback.count <= 4_000 ? callback : nil
    }

    /// Renders agent Markdown as plain SMS text: code fences flattened, links as `label (url)`,
    /// emphasis/heading markers removed.
    /// - Parameter markdown: Markdown text.
    /// - Returns: Plain text.
    public static func renderPlainText(_ markdown: String) -> String {
        var lines: [String] = []
        for line in markdown.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                continue
            }
            var value = line
            if let heading = value.range(of: "^\\s{0,3}#{1,6}\\s+", options: .regularExpression) {
                value.removeSubrange(heading)
            }
            lines.append(value)
        }
        var text = lines.joined(separator: "\n")
        text = text.replacingOccurrences(of: "!\\[([^\\]]*)\\]\\(([^)\\s]+)\\)", with: "$1 ($2)", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\[([^\\]]+)\\]\\(([^)\\s]+)\\)", with: "$1 ($2)", options: .regularExpression)
        for marker in ["**", "__", "~~"] {
            text = text.replacingOccurrences(of: marker, with: "")
        }
        text = text.replacingOccurrences(of: "`", with: "")
        text = text.replacingOccurrences(of: "(?<![\\w*])\\*(?!\\s)([^*\\n]+?)(?<!\\s)\\*(?![\\w*])", with: "$1", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Native SMS channel adapter backed by Twilio Programmable Messaging (upstream `sms` plugin).
///
/// - Outbound: `POST https://api.twilio.com/2010-04-01/Accounts/<sid>/Messages.json` (Basic auth,
///   form fields `To`, `Body` ≤ 1,600, `From` or `MessagingServiceSid`, repeated `MediaUrl`, and a
///   `StatusCallback` derived from `publicWebhookUrl`). Markdown is rendered as plain text and
///   chunked at `textChunkLimit` (1,500). MMS needs publicly reachable HTTPS media URLs, so media
///   sends require ``mediaURLProvider``. Receipts carry the Twilio `sid`.
/// - Inbound: route the webhook (default `/webhooks/sms`) to ``handleWebhook(requestURL:headers:body:)``;
///   it verifies `X-Twilio-Signature` (HMAC-SHA1 over the exact public URL and sorted form
///   fields), dedupes by `MessageSid` (512), turns delivery callbacks into `sms.delivery.status`
///   diagnostics, downloads at most 10 media / 5 MiB only for authorized senders, and answers
///   with empty TwiML.
///
/// - Note: US A2P 10DLC registration is required for application-to-person SMS from US long codes.
public actor SMSChannelAdapter: InboundChannelAdapter, ReceiptingChannelAdapter, ChannelConfigurationReporting {
    /// Returns a public HTTPS URL Twilio can fetch for an outbound attachment.
    public typealias MediaURLProvider = @Sendable (MediaAttachment) async throws -> URL
    /// Decides whether media from a sender may be downloaded (for example a pairing-store lookup).
    public typealias MediaDownloadAuthorizer = @Sendable (_ senderID: String) async -> Bool

    /// Adapter channel identifier.
    public let id: ChannelID = .sms

    private let config: SMSChannelConfig
    private let accountID: String?
    private let transport: any ChannelHTTPTransport
    private let mediaURLProvider: MediaURLProvider?
    private let mediaDownloadAuthorizer: MediaDownloadAuthorizer?
    private let diagnosticsSink: RuntimeDiagnosticSink?

    private var started = false
    private var inboundHandler: InboundMessageHandler?
    private var recentMessageSids = ChannelRecentIDs(capacity: 512)

    /// Creates an SMS adapter.
    /// - Parameters:
    ///   - config: `channels.sms` settings (resolve SecretRefs first).
    ///   - accountID: Account to resolve (`nil` = default account, which also receives env fallbacks).
    ///   - environment: Environment for `TWILIO_*` fallbacks.
    ///   - transport: HTTP transport.
    ///   - mediaURLProvider: Serves outbound attachments at public HTTPS URLs.
    ///   - mediaDownloadAuthorizer: Authorizes inbound media downloads (default: `allowFrom` match).
    ///   - diagnosticsSink: Diagnostics sink (`sms.delivery.status`).
    public init(
        config: SMSChannelConfig,
        accountID: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        transport: any ChannelHTTPTransport = HTTPClient(),
        mediaURLProvider: MediaURLProvider? = nil,
        mediaDownloadAuthorizer: MediaDownloadAuthorizer? = nil,
        diagnosticsSink: RuntimeDiagnosticSink? = nil
    ) {
        self.config = config.resolvedAccount(accountID).applyingEnvironmentFallbacks(environment, accountID: accountID)
        self.accountID = accountID?.channelTrimmedNonEmpty
        self.transport = transport
        self.mediaURLProvider = mediaURLProvider
        self.mediaDownloadAuthorizer = mediaDownloadAuthorizer
        self.diagnosticsSink = diagnosticsSink
    }

    /// Registers or clears the inbound callback.
    /// - Parameter handler: Inbound handler.
    public func setInboundHandler(_ handler: InboundMessageHandler?) async {
        self.inboundHandler = handler
    }

    /// Resolved account settings (after account merge and env fallbacks).
    nonisolated public var resolvedConfig: SMSChannelConfig {
        self.config
    }

    /// Webhook path the host must route to ``handleWebhook(requestURL:headers:body:)``.
    nonisolated public var webhookPath: String {
        self.config.webhookPath
    }

    /// Configured when `accountSid`, `authToken` and a sender are present.
    nonisolated public var configurationStatus: ChannelConfigurationStatus {
        self.config.isConfigured ? .configured : .unconfigured(reason: SMSChannelConfig.unconfiguredReason)
    }

    /// Starts the adapter (validates credentials; inbound arrives through the webhook).
    public func start() async throws {
        guard self.config.enabled else {
            throw OpenClawCoreError.unavailable("SMS channel is disabled")
        }
        guard self.config.transport == .twilio else {
            throw OpenClawCoreError.invalidConfiguration("channels.sms.transport is carrier; use CarrierMessagingChannelAdapter")
        }
        guard self.config.isConfigured else {
            throw OpenClawCoreError.invalidConfiguration(SMSChannelConfig.unconfiguredReason)
        }
        self.started = true
    }

    /// Stops the adapter.
    public func stop() async {
        self.started = false
    }

    /// Probes credentials with `GET /2010-04-01/Accounts/<sid>.json`.
    /// - Parameter timeoutMs: Probe timeout.
    /// - Returns: Probe result.
    public func probe(timeoutMs: Int) async -> ChannelProbeResult {
        if case .unconfigured(let reason) = self.configurationStatus {
            return ChannelProbeResult(ok: false, detail: reason)
        }
        return await ChannelAsync.probe(timeoutMs: timeoutMs) { [self] in
            try await self.performProbe()
        }
    }

    private func performProbe() async throws -> String {
        let sid = try self.accountSid()
        var request = URLRequest(url: try self.apiURL("/2010-04-01/Accounts/\(sid).json"))
        request.httpMethod = "GET"
        try self.authorize(&request)
        let response = try await self.transport.data(for: request)
        try ChannelHTTP.check(response)
        return self.config.fromNumber ?? self.config.messagingServiceSid ?? "SMS"
    }

    // MARK: Outbound

    /// Sends an SMS/MMS.
    /// - Parameter message: Outbound payload.
    public func send(_ message: OutboundMessage) async throws {
        _ = try await self.sendReturningReceipt(message)
    }

    /// Sends plain-text chunks (and MMS media on the first chunk); returns the Twilio `sid`s.
    /// - Parameter message: Outbound payload.
    /// - Returns: Receipt.
    public func sendReturningReceipt(_ message: OutboundMessage) async throws -> ChannelSendReceipt {
        guard self.started else {
            throw OpenClawCoreError.unavailable("SMS adapter is not started")
        }
        let to = TwilioSMS.normalizePhoneNumber(message.peerID.channelTrimmedNonEmpty ?? self.config.policy.defaultTo ?? "")
        guard TwilioSMS.looksLikePhoneNumber(to) else {
            throw ChannelSendError.rejected(status: 0, detail: "SMS recipient must be an E.164 phone number")
        }
        var mediaURLs: [String] = []
        if !message.attachments.isEmpty {
            guard let mediaURLProvider else {
                throw ChannelSendError.rejected(
                    status: 0,
                    detail: "SMS media sends require a mediaURLProvider that serves attachments at public HTTPS URLs"
                )
            }
            guard message.attachments.count <= TwilioSMS.maxOutboundMedia else {
                throw ChannelSendError.rejected(status: 0, detail: "Twilio MMS supports at most \(TwilioSMS.maxOutboundMedia) media URLs")
            }
            for attachment in message.attachments {
                mediaURLs.append(try await mediaURLProvider(attachment).absoluteString)
            }
        }
        let plain = TwilioSMS.renderPlainText(message.text)
        var chunks = ChannelTextChunker.chunk(plain, limit: self.config.textChunkLimit)
        if chunks.isEmpty {
            guard !mediaURLs.isEmpty else {
                throw OpenClawCoreError.invalidConfiguration("SMS outbound text is required")
            }
            chunks = [""]
        }
        var parts: [ChannelSendReceipt.Part] = []
        for (index, chunk) in chunks.enumerated() {
            let sid = try await self.postMessage(to: to, body: chunk, mediaURLs: index == 0 ? mediaURLs : [])
            parts.append(ChannelSendReceipt.Part(platformMessageID: sid, kind: index == 0 && !mediaURLs.isEmpty ? .media : .text, index: index))
        }
        return ChannelSendReceipt(parts: parts)
    }

    private func postMessage(to: String, body: String, mediaURLs: [String]) async throws -> String {
        guard body.count <= TwilioSMS.messageBodyMaxLength else {
            throw ChannelSendError.rejected(status: 0, detail: "Twilio SMS/MMS Body supports at most \(TwilioSMS.messageBodyMaxLength) characters.")
        }
        var fields: [(String, String)] = [("To", to)]
        if !body.isEmpty {
            fields.append(("Body", body))
        }
        for url in mediaURLs {
            fields.append(("MediaUrl", url))
        }
        if let from = self.config.fromNumber.map(TwilioSMS.normalizePhoneNumber), !from.isEmpty {
            fields.append(("From", from))
        } else if let service = self.config.messagingServiceSid?.channelTrimmedNonEmpty {
            fields.append(("MessagingServiceSid", service))
        } else {
            throw OpenClawCoreError.invalidConfiguration("Twilio SMS send requires fromNumber or messagingServiceSid.")
        }
        if let callback = self.config.publicWebhookUrl.flatMap(TwilioSMS.statusCallbackURL(publicWebhookURL:)) {
            fields.append(("StatusCallback", callback))
        }
        let sid = try self.accountSid()
        var request = URLRequest(url: try self.apiURL("/2010-04-01/Accounts/\(sid)/Messages.json"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = ChannelHTTP.formEncoded(fields)
        request.timeoutInterval = 30
        try self.authorize(&request)
        let response = try await self.transport.data(for: request)
        try ChannelHTTP.check(response)
        guard let object = ChannelHTTP.jsonObject(response.body), let messageSid = (object["sid"] as? String)?.channelTrimmedNonEmpty else {
            throw ChannelSendError.unknownOutcome(underlying: "Twilio SMS send response did not include a Message SID.")
        }
        return messageSid
    }

    // MARK: Inbound

    /// Handles one Twilio webhook request (incoming message or delivery status callback).
    /// - Parameters:
    ///   - requestURL: URL of the received request (its query joins the signature base).
    ///   - headers: Request headers (`X-Twilio-Signature`).
    ///   - body: Raw `application/x-www-form-urlencoded` body.
    /// - Returns: HTTP status, content type and body to send back to Twilio.
    public func handleWebhook(requestURL: URL, headers: [String: String], body: Data) async -> (status: Int, contentType: String, body: String) {
        let form = ChannelHTTP.parseForm(body)
        if !self.config.dangerouslyDisableSignatureValidation {
            guard let token = self.config.authToken?.channelTrimmedNonEmpty,
                  let publicURL = self.config.publicWebhookUrl?.channelTrimmedNonEmpty,
                  let signature = ChannelHTTP.header("X-Twilio-Signature", in: headers)?.channelTrimmedNonEmpty
            else {
                return (403, "text/plain; charset=utf-8", "Invalid signature")
            }
            let url = TwilioSMS.signatureURL(publicWebhookURL: publicURL, requestURL: requestURL)
            let expected = ChannelWebhookSignature.twilioSignature(authToken: token, url: url, form: form)
            guard ChannelWebhookSignature.constantTimeEquals(expected, signature) else {
                return (403, "text/plain; charset=utf-8", "Invalid signature")
            }
        }
        let messageSid = (form["MessageSid"] ?? form["SmsSid"] ?? form["SmsMessageSid"])?.channelTrimmedNonEmpty
        if let status = form["MessageStatus"]?.channelTrimmedNonEmpty ?? form["SmsStatus"]?.channelTrimmedNonEmpty,
           form["Body"] == nil, form["NumMedia"] == nil
        {
            var metadata = ["status": status]
            metadata["messageSid"] = messageSid
            metadata["errorCode"] = form["ErrorCode"]
            await self.emitDiagnostic("sms.delivery.status", metadata)
            return (200, TwilioSMS.twimlContentType, TwilioSMS.emptyTwiML)
        }
        guard let messageSid else {
            return (400, "text/plain; charset=utf-8", "Missing MessageSid")
        }
        guard self.recentMessageSids.insert(messageSid) else {
            return (200, TwilioSMS.twimlContentType, TwilioSMS.emptyTwiML)
        }
        guard let sender = TwilioSMS.inboundSender(form["From"] ?? "") else {
            return (200, TwilioSMS.twimlContentType, TwilioSMS.emptyTwiML)
        }
        Task { [weak self, form] in
            await self?.dispatchInbound(form: form, sender: sender, messageSid: messageSid)
        }
        return (200, TwilioSMS.twimlContentType, TwilioSMS.emptyTwiML)
    }

    private func dispatchInbound(form: [String: String], sender: String, messageSid: String) async {
        let body = form["Body"] ?? ""
        let mediaCount = max(0, Int(form["NumMedia"]?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0)
        var notices: [String] = []
        var attachments: [MediaAttachment] = []
        if mediaCount > 0 {
            if await self.mayDownloadMedia(from: sender) {
                let result = await self.downloadMedia(form: form, count: mediaCount)
                attachments = result.attachments
                if result.unavailable > 0 {
                    notices.append("[\(result.unavailable) attachment(s) could not be included (limit 10 files / 5 MiB or unavailable)]")
                }
            } else {
                notices.append("[\(mediaCount) attachment(s) not downloaded: sender is not yet authorized]")
            }
        }
        let text = ([body] + notices).filter { !$0.isEmpty }.joined(separator: "\n")
        guard !text.isEmpty || !attachments.isEmpty else { return }
        var metadata: [String: String] = [:]
        metadata["to"] = form["To"]
        metadata["messagingServiceSid"] = form["MessagingServiceSid"]
        let inbound = InboundMessage(
            channel: .sms,
            accountID: self.accountID,
            peerID: sender,
            text: text,
            attachments: attachments,
            senderID: sender,
            chatType: .direct,
            messageID: messageSid,
            recipientID: form["To"].map(TwilioSMS.normalizePhoneNumber),
            metadata: metadata,
            legacyRoutingAccountID: sender
        )
        if let inboundHandler {
            await inboundHandler(inbound)
        }
    }

    private func mayDownloadMedia(from sender: String) async -> Bool {
        if let mediaDownloadAuthorizer {
            return await mediaDownloadAuthorizer(sender)
        }
        let allowFrom = (self.config.policy.allowFrom ?? []).map { $0 == "*" ? "*" : TwilioSMS.normalizePhoneNumber($0) }
        return allowFrom.contains("*") || allowFrom.contains(sender)
    }

    private func downloadMedia(form: [String: String], count: Int) async -> (attachments: [MediaAttachment], unavailable: Int) {
        var attachments: [MediaAttachment] = []
        var unavailable = max(0, count - TwilioSMS.maxInboundMedia)
        var totalBytes = 0
        for index in 0..<min(count, TwilioSMS.maxInboundMedia) {
            guard let raw = form["MediaUrl\(index)"]?.channelTrimmedNonEmpty,
                  let url = URL(string: raw), url.scheme?.lowercased() == "https", url.host?.lowercased() == TwilioSMS.apiHost
            else {
                unavailable += 1
                continue
            }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 30
            guard (try? self.authorize(&request)) != nil,
                  let response = try? await self.transport.data(for: request),
                  (200..<300).contains(response.statusCode),
                  totalBytes + response.body.count <= TwilioSMS.mmsMaxBytes
            else {
                unavailable += 1
                continue
            }
            totalBytes += response.body.count
            let mimeType = form["MediaContentType\(index)"]?.channelTrimmedNonEmpty
                ?? ChannelHTTP.header("Content-Type", in: response.headers) ?? "application/octet-stream"
            attachments.append(MediaAttachment(mimeType: mimeType, data: response.body, metadata: ["source": "twilio"]))
        }
        return (attachments, unavailable)
    }

    // MARK: Helpers

    private func accountSid() throws -> String {
        guard let sid = self.config.accountSid?.channelTrimmedNonEmpty else {
            throw OpenClawCoreError.invalidConfiguration(SMSChannelConfig.unconfiguredReason)
        }
        return sid
    }

    private func authorize(_ request: inout URLRequest) throws {
        guard let sid = self.config.accountSid?.channelTrimmedNonEmpty, let token = self.config.authToken?.channelTrimmedNonEmpty else {
            throw OpenClawCoreError.invalidConfiguration(SMSChannelConfig.unconfiguredReason)
        }
        guard request.url?.host?.lowercased() == TwilioSMS.apiHost, request.url?.scheme == "https" else {
            throw OpenClawCoreError.invalidConfiguration("Twilio credentials are only sent to https://\(TwilioSMS.apiHost)")
        }
        request.setValue("Basic \(Data("\(sid):\(token)".utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
    }

    private func apiURL(_ path: String) throws -> URL {
        guard let url = URL(string: "https://\(TwilioSMS.apiHost)\(path)") else {
            throw OpenClawCoreError.invalidConfiguration("Invalid Twilio API path")
        }
        return url
    }

    private func emitDiagnostic(_ name: String, _ metadata: [String: String]) async {
        guard let diagnosticsSink else { return }
        await diagnosticsSink(RuntimeDiagnosticEvent(subsystem: "channel", name: name, metadata: metadata))
    }
}
