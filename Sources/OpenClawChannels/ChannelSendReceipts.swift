import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenClawCore

/// Platform receipt for one delivered outbound message (upstream `MessageReceipt`).
public struct ChannelSendReceipt: Codable, Sendable, Equatable {
    /// Kind of one delivered part.
    public enum PartKind: String, Codable, Sendable, Equatable, CaseIterable {
        /// Text message.
        case text
        /// Media attachment.
        case media
        /// Voice note.
        case voice
        /// Poll.
        case poll
        /// Card or rich block.
        case card
        /// Streaming preview.
        case preview
        /// Unknown part kind.
        case unknown
    }

    /// One delivered platform message.
    public struct Part: Codable, Sendable, Equatable {
        /// Platform message id.
        public var platformMessageID: String
        /// Part kind.
        public var kind: PartKind
        /// Zero-based position within the delivery.
        public var index: Int
        /// Thread the part was posted into.
        public var threadID: String?
        /// Message the part replies to.
        public var replyToID: String?

        /// Creates a receipt part.
        /// - Parameters:
        ///   - platformMessageID: Platform message id.
        ///   - kind: Part kind.
        ///   - index: Zero-based position.
        ///   - threadID: Thread id.
        ///   - replyToID: Replied-to message id.
        public init(platformMessageID: String, kind: PartKind = .text, index: Int = 0, threadID: String? = nil, replyToID: String? = nil) {
            self.platformMessageID = platformMessageID
            self.kind = kind
            self.index = max(0, index)
            self.threadID = threadID
            self.replyToID = replyToID
        }
    }

    /// Primary platform message id (the first part).
    public var primaryPlatformMessageID: String?
    /// Every platform message id, in delivery order.
    public var platformMessageIDs: [String]
    /// Delivered parts.
    public var parts: [Part]
    /// Thread the delivery was posted into.
    public var threadID: String?
    /// Message the delivery replies to.
    public var replyToID: String?
    /// Delivery time.
    public var sentAt: Date

    /// Creates a receipt from parts.
    /// - Parameters:
    ///   - parts: Delivered parts.
    ///   - threadID: Thread id.
    ///   - replyToID: Replied-to message id.
    ///   - sentAt: Delivery time.
    public init(parts: [Part], threadID: String? = nil, replyToID: String? = nil, sentAt: Date = Date()) {
        self.parts = parts
        self.platformMessageIDs = parts.map(\.platformMessageID)
        self.primaryPlatformMessageID = parts.first?.platformMessageID
        self.threadID = threadID ?? parts.first?.threadID
        self.replyToID = replyToID ?? parts.first?.replyToID
        self.sentAt = sentAt
    }

    /// Creates a single-part receipt.
    /// - Parameters:
    ///   - platformMessageID: Platform message id (Telegram `message_id`, Discord `id`, Slack `ts`, ...).
    ///   - kind: Part kind.
    ///   - threadID: Thread id.
    ///   - replyToID: Replied-to message id.
    ///   - sentAt: Delivery time.
    public init(platformMessageID: String, kind: PartKind = .text, threadID: String? = nil, replyToID: String? = nil, sentAt: Date = Date()) {
        self.init(
            parts: [Part(platformMessageID: platformMessageID, kind: kind, index: 0, threadID: threadID, replyToID: replyToID)],
            threadID: threadID,
            replyToID: replyToID,
            sentAt: sentAt
        )
    }

    /// Merges receipts of chunked deliveries into one receipt, re-indexing parts.
    /// - Parameter receipts: Receipts in delivery order.
    /// - Returns: Combined receipt, or `nil` for an empty list.
    public static func combined(_ receipts: [ChannelSendReceipt]) -> ChannelSendReceipt? {
        guard let first = receipts.first else { return nil }
        var parts: [Part] = []
        for receipt in receipts {
            for part in receipt.parts {
                var copy = part
                copy.index = parts.count
                parts.append(copy)
            }
        }
        return ChannelSendReceipt(parts: parts, threadID: first.threadID, replyToID: first.replyToID, sentAt: first.sentAt)
    }
}

/// Adapter capability: sends and returns the platform receipt.
public protocol ReceiptingChannelAdapter: ChannelAdapter {
    /// Sends an outbound message and returns its platform receipt.
    /// - Parameter message: Outbound message.
    /// - Returns: Platform receipt.
    func sendReturningReceipt(_ message: OutboundMessage) async throws -> ChannelSendReceipt
}

/// Classified outbound send failure used for safe retries.
///
/// ``ChannelRegistry`` retries only ``notSent(underlying:retryAfterMs:)`` and
/// ``rateLimited(retryAfterMs:)``. ``unknownOutcome(underlying:)`` is never retried blindly
/// (that would duplicate messages after a timeout) unless the adapter conforms to
/// ``UnknownSendReconciling``; ``rejected(status:detail:)`` is permanent.
public enum ChannelSendError: Error, LocalizedError, Sendable, Equatable {
    /// The platform did not accept the message (connection refused, DNS failure, HTTP 5xx before
    /// acceptance, ...); safe to retry.
    case notSent(underlying: String, retryAfterMs: Int? = nil)
    /// The request may or may not have been delivered (timeout or reset after the body was written).
    case unknownOutcome(underlying: String)
    /// Permanent rejection (4xx other than 429).
    case rejected(status: Int, detail: String)
    /// Rate limited (HTTP 429); retry after the given delay.
    case rateLimited(retryAfterMs: Int?)

    /// Maximum honored Retry-After delay (upstream `TELEGRAM_OUTBOUND_RETRY_AFTER_CAP_MS`).
    public static let retryAfterCapMs = 60_000

    /// Whether the registry may retry the send.
    public var isRetryable: Bool {
        switch self {
        case .notSent, .rateLimited: true
        case .unknownOutcome, .rejected: false
        }
    }

    /// Retry-After delay, capped at ``retryAfterCapMs``.
    public var retryAfterMs: Int? {
        switch self {
        case .notSent(_, let retryAfterMs), .rateLimited(let retryAfterMs):
            retryAfterMs.map { min(max(0, $0), Self.retryAfterCapMs) }
        case .unknownOutcome, .rejected:
            nil
        }
    }

    /// Localized description.
    public var errorDescription: String? {
        switch self {
        case .notSent(let underlying, _):
            "Message not sent: \(underlying)"
        case .unknownOutcome(let underlying):
            "Message delivery outcome unknown: \(underlying)"
        case .rejected(let status, let detail):
            "Message rejected (\(status)): \(detail)"
        case .rateLimited(let retryAfterMs):
            "Rate limited" + (retryAfterMs.map { "; retry after \($0) ms" } ?? "")
        }
    }

    /// Classifies an HTTP response from a channel API.
    ///
    /// 2xx returns `nil`. 429 becomes ``rateLimited(retryAfterMs:)`` with the `Retry-After`
    /// header or a Telegram/Discord JSON `retry_after`; 5xx becomes ``notSent(underlying:retryAfterMs:)``;
    /// other statuses become ``rejected(status:detail:)``.
    /// - Parameters:
    ///   - statusCode: HTTP status.
    ///   - headers: Response headers (case-insensitive lookup).
    ///   - body: Response body.
    /// - Returns: The classified error, or `nil` for success.
    public static func classify(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) -> ChannelSendError? {
        let detail = String(data: body.prefix(512), encoding: .utf8) ?? "HTTP \(statusCode)"
        switch statusCode {
        case 200..<300:
            return nil
        case 429:
            let header = headers.first { $0.key.lowercased() == "retry-after" }?.value
            let retryAfter = header.flatMap { self.parseRetryAfterHeader($0) }
                ?? self.telegramRetryAfterMs(body: body)
                ?? self.discordRetryAfterMs(body: body)
            return .rateLimited(retryAfterMs: retryAfter)
        case 500..<600:
            return .notSent(underlying: detail, retryAfterMs: nil)
        default:
            return .rejected(status: statusCode, detail: detail)
        }
    }

    /// Classifies a transport error thrown while sending.
    ///
    /// Connection/DNS failures before the request was written are ``notSent(underlying:retryAfterMs:)``;
    /// timeouts and dropped connections are ``unknownOutcome(underlying:)``.
    /// `OpenClawCoreError.invalidConfiguration` is permanent; `.unavailable` is treated as not sent.
    /// Other errors keep the pre-2026.3.0 behavior (retried as not sent).
    /// - Parameter error: Thrown error.
    /// - Returns: Classified error.
    public static func classify(_ error: Error) -> ChannelSendError {
        if let classified = error as? ChannelSendError {
            return classified
        }
        if let core = error as? OpenClawCoreError {
            switch core {
            case .invalidConfiguration(let detail):
                return .rejected(status: 0, detail: detail)
            case .unavailable(let detail):
                return .notSent(underlying: detail, retryAfterMs: nil)
            }
        }
        if error is CancellationError {
            return .unknownOutcome(underlying: "cancelled")
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet,
                 .secureConnectionFailed, .serverCertificateUntrusted, .badURL, .unsupportedURL:
                return .notSent(underlying: urlError.localizedDescription, retryAfterMs: nil)
            default:
                return .unknownOutcome(underlying: urlError.localizedDescription)
            }
        }
        return .notSent(underlying: ChannelErrorText.describe(error), retryAfterMs: nil)
    }

    /// Parses an HTTP `Retry-After` header (delta seconds or HTTP date) into milliseconds.
    /// - Parameters:
    ///   - value: Header value.
    ///   - now: Reference time for HTTP dates.
    /// - Returns: Delay in milliseconds, capped at ``retryAfterCapMs``.
    public static func parseRetryAfterHeader(_ value: String, now: Date = Date()) -> Int? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = Double(trimmed), seconds.isFinite, seconds >= 0 {
            return min(Int((seconds * 1_000).rounded(.up)), Self.retryAfterCapMs)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: trimmed) else { return nil }
        return min(max(0, Int((date.timeIntervalSince(now) * 1_000).rounded(.up))), Self.retryAfterCapMs)
    }

    /// Reads Telegram's `{ok: false, error_code: 429, parameters: {retry_after: seconds}}`.
    /// - Parameter body: Response body.
    /// - Returns: Delay in milliseconds, capped.
    public static func telegramRetryAfterMs(body: Data) -> Int? {
        guard let payload = try? JSONDecoder().decode(TelegramRetryPayload.self, from: body),
              let seconds = payload.parameters?.retryAfter, seconds.isFinite, seconds >= 0
        else {
            return nil
        }
        return min(Int((seconds * 1_000).rounded(.up)), Self.retryAfterCapMs)
    }

    /// Reads Discord's 429 JSON `retry_after` (seconds, possibly fractional).
    /// - Parameter body: Response body.
    /// - Returns: Delay in milliseconds, capped.
    public static func discordRetryAfterMs(body: Data) -> Int? {
        guard let payload = try? JSONDecoder().decode(DiscordRetryPayload.self, from: body),
              let seconds = payload.retryAfter, seconds.isFinite, seconds >= 0
        else {
            return nil
        }
        return min(Int((seconds * 1_000).rounded(.up)), Self.retryAfterCapMs)
    }
}

private struct TelegramRetryPayload: Decodable {
    struct Parameters: Decodable {
        let retryAfter: Double?

        private enum CodingKeys: String, CodingKey {
            case retryAfter = "retry_after"
        }
    }

    let parameters: Parameters?
}

private struct DiscordRetryPayload: Decodable {
    let retryAfter: Double?

    private enum CodingKeys: String, CodingKey {
        case retryAfter = "retry_after"
    }
}

/// Result of reconciling a send whose outcome was unknown (upstream unknown-send reconciliation).
public enum ChannelUnknownSendReconciliation: Sendable, Equatable {
    /// The message was delivered; the receipt identifies it.
    case sent(ChannelSendReceipt)
    /// The message was not delivered; the registry may retry.
    case notSent
    /// The outcome is still unknown; the registry gives up without retrying.
    case unresolved
}

/// Adapter capability: determines whether a send with an unknown outcome was delivered.
public protocol UnknownSendReconciling: ChannelAdapter {
    /// Reconciles a send whose outcome is unknown (for example by listing recent messages).
    /// - Parameters:
    ///   - message: The message that was being sent.
    ///   - attemptStartedAt: When the failed attempt started.
    /// - Returns: Reconciliation result.
    func reconcile(_ message: OutboundMessage, attemptStartedAt: Date) async -> ChannelUnknownSendReconciliation
}
