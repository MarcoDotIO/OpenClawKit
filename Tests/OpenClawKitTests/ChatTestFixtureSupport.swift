import Foundation
import OpenClawProtocol
@testable import OpenClawChatUI

// Shared transcript fixtures (upstream defines these in ChatTranscriptCacheStoreTests.swift,
// which ports with the SQLite transcript cache store).

func cacheMessage(
    role: String,
    text: String,
    timestamp: Double,
    idempotencyKey: String? = nil) -> OpenClawChatMessage
{
    OpenClawChatMessage(
        role: role,
        content: [
            OpenClawChatMessageContent(
                type: "text",
                text: text,
                mimeType: nil,
                fileName: nil,
                content: nil),
        ],
        timestamp: timestamp,
        idempotencyKey: idempotencyKey)
}

func cacheSessionEntry(
    key: String,
    updatedAt: Double,
    agentID: String? = nil) -> OpenClawChatSessionEntry
{
    OpenClawChatSessionEntry(
        key: key,
        kind: nil,
        displayName: nil,
        agentId: agentID,
        surface: nil,
        subject: nil,
        room: nil,
        space: nil,
        updatedAt: updatedAt,
        sessionId: nil,
        systemSent: nil,
        abortedLastRun: nil,
        thinkingLevel: nil,
        verboseLevel: nil,
        inputTokens: nil,
        outputTokens: nil,
        totalTokens: nil,
        modelProvider: nil,
        model: nil,
        contextTokens: nil)
}

// Upstream chat fixtures build heterogeneous JSON literals with the `Any`-backed
// `AnyCodable(_:)`. The local wrapper is enum-backed and Sendable, so ported
// fixtures spell heterogeneous literals as `AnyCodable(json:)`, which normalizes
// them through `AnyCodable.fromFoundation(_:)`.
extension AnyCodable {
    init(json object: [String: Any]) {
        self = AnyCodable.fromFoundation(object) ?? .nullValue
    }

    init(json array: [Any]) {
        self = AnyCodable.fromFoundation(array) ?? .nullValue
    }
}
