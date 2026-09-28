import Foundation
import OpenClawKit

// Ported subset of upstream OpenClaw 2026.9.6 `ChatSessionAttention.swift`: attention request models, the
// sidebar summary, and the view model's pending-question projection. `OpenClawChatAttentionBadge` belongs
// with the session sidebar views.

/// A pending question or approval that needs the user's attention.
public struct OpenClawChatAttentionRequest: Identifiable, Equatable, Sendable {
    /// Attention request kind.
    public enum Kind: String, Hashable, Sendable {
        /// An agent question awaiting an answer.
        case question
        /// A tool approval awaiting a decision.
        case approval
    }

    /// Request identifier.
    public let id: String
    /// Request kind.
    public let kind: Kind
    /// Session the request belongs to.
    public let sessionKey: String?
    /// Agent that owns the session.
    public let agentID: String?
    /// Creation time (ms since 1970).
    public let createdAtMs: Double
    /// Expiry time (ms since 1970).
    public let expiresAtMs: Double
    /// Single-line preview (at most 240 UTF-16 units).
    public let preview: String
    /// Number of prompts the request bundles.
    public let count: Int
    /// Identity of the surface that produced the request.
    public let ownerID: String?

    /// Creates a request; the preview is collapsed to one line and truncated.
    public init(
        id: String,
        kind: Kind,
        sessionKey: String?,
        agentID: String?,
        createdAtMs: Double,
        expiresAtMs: Double,
        preview: String,
        count: Int = 1,
        ownerID: String? = nil)
    {
        self.id = id
        self.kind = kind
        self.sessionKey = sessionKey
        self.agentID = agentID
        self.createdAtMs = createdAtMs
        self.expiresAtMs = expiresAtMs
        self.preview = Self.normalizedPreview(preview)
        self.count = count
        self.ownerID = ownerID
    }

    private static func normalizedPreview(_ preview: String) -> String {
        let line = preview.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard line.utf16.count > 240 else { return line }
        var result = ""
        var length = 0
        for scalar in line.unicodeScalars {
            let scalarLength = scalar.value > 0xFFFF ? 2 : 1
            guard length + scalarLength <= 239 else { break }
            result.unicodeScalars.append(scalar)
            length += scalarLength
        }
        return result + "…"
    }
}

/// The oldest pending attention request of one kind, with the total count.
public struct OpenClawChatAttentionSummary: Identifiable, Equatable, Sendable {
    /// Stable identity used to dedupe attention disclosures.
    public struct DisclosureIdentity: Hashable, Sendable {
        let ownerID: Data?
        let kind: OpenClawChatAttentionRequest.Kind
        let requestID: Data
        let sessionKey: Data?
        let createdAtMs: Double
    }

    /// Summarized kind.
    public let kind: OpenClawChatAttentionRequest.Kind
    /// Oldest pending request.
    public let oldest: OpenClawChatAttentionRequest
    /// Total prompts across the summarized requests.
    public let count: Int
    /// Identifier (the kind).
    public var id: OpenClawChatAttentionRequest.Kind {
        self.kind
    }

    /// Disclosure identity of the oldest request.
    public var disclosureIdentity: DisclosureIdentity {
        DisclosureIdentity(
            ownerID: self.oldest.ownerID.map { Data($0.utf8) },
            kind: self.kind,
            requestID: Data(self.oldest.id.utf8),
            sessionKey: self.oldest.sessionKey.map { Data($0.utf8) },
            createdAtMs: self.oldest.createdAtMs)
    }

    /// Localized title.
    public var title: String {
        self.kind == .question ? String(localized: "Waiting for answer") : String(localized: "Waiting for approval")
    }

    /// Localized count of additional requests, when more than one.
    public var additionalRequestsText: String? {
        guard self.count > 1 else { return nil }
        if self.count == 2 {
            return self.kind == .question ? String(localized: "1 more question") : String(localized: "1 more approval")
        }
        return self.kind == .question
            ? String(format: String(localized: "%lld more questions"), self.count - 1)
            : String(format: String(localized: "%lld more approvals"), self.count - 1)
    }

    /// Accessibility label combining title, preview, and count.
    public var accessibilityText: String {
        [self.title, self.oldest.preview, self.additionalRequestsText]
            .compactMap(\.self).joined(separator: ". ")
    }
}

extension ChatSessionSidebarModel {
    /// Summarizes unexpired requests whose sessions are listed in the active agent scope.
    @MainActor
    public static func attentionSummary(
        requests: [OpenClawChatAttentionRequest],
        sessions: [OpenClawChatSessionEntry],
        mainSessionKey: String,
        activeAgentID: String?,
        sessionRoutingContract: String?,
        now: Date = Date()) -> OpenClawChatAttentionSummary?
    {
        let nowMs = now.timeIntervalSince1970 * 1000
        let pending = requests.filter { request in
            guard request.expiresAtMs > nowMs, let source = request.sessionKey else { return false }
            return sessions.contains { session in
                let agentID = session.agentId ?? activeAgentID
                return self.isSessionInActiveAgentScope(
                    key: source, agentID: request.agentID, activeAgentID: agentID) &&
                    OpenClawChatViewModel.matchesCurrentSessionKey(
                        incoming: source,
                        agentId: request.agentID,
                        current: session.key,
                        mainSessionKey: mainSessionKey,
                        activeAgentId: agentID,
                        sessionRoutingContract: sessionRoutingContract)
            }
        }.sorted {
            if $0.createdAtMs != $1.createdAtMs { return $0.createdAtMs < $1.createdAtMs }
            if !Data($0.id.utf8).elementsEqual(Data($1.id.utf8)) {
                return $0.id.utf8.lexicographicallyPrecedes($1.id.utf8)
            }
            return $0.kind.rawValue < $1.kind.rawValue
        }
        guard let oldest = pending.first else { return nil }
        var seen = Set<Data>()
        let requests = pending.filter { $0.kind == oldest.kind && seen.insert(Data($0.id.utf8)).inserted }
        return OpenClawChatAttentionSummary(
            kind: oldest.kind, oldest: oldest, count: requests.reduce(0) { $0 + $1.count })
    }
}

extension OpenClawChatViewModel {
    /// Attention requests for pending question cards.
    public var pendingQuestionAttentionRequests: [OpenClawChatAttentionRequest] {
        self.questionCards.compactMap { card in
            guard card.status() == .pending || card.status() == .submitting else { return nil }
            let record = card.record
            let preview = record.questions.first?.question.trimmingCharacters(in: .whitespacesAndNewlines)
            return OpenClawChatAttentionRequest(
                id: record.id,
                kind: .question,
                sessionKey: record.sessionkey,
                agentID: record.agentid,
                createdAtMs: Double(record.createdatms),
                expiresAtMs: Double(record.expiresatms),
                preview: preview.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "Question needs an answer"),
                count: record.questions.count,
                ownerID: self.questionAttentionOwnerID.uuidString)
        }
    }
}

/// Presentation identity for an attention disclosure anchored to a target.
public struct OpenClawChatAttentionPresentation: Equatable, Sendable {
    private let targetID: Data
    private let requestID: OpenClawChatAttentionSummary.DisclosureIdentity

    /// Creates a presentation identity.
    public init(targetID: String, requestID: OpenClawChatAttentionSummary.DisclosureIdentity) {
        self.targetID = Data(targetID.utf8)
        self.requestID = requestID
    }
}
