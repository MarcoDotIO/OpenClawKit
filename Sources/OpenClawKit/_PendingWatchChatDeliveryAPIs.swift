import Foundation

// TEMPORARY SHIM (W5d, wave 2): verbatim port of upstream OpenClaw 2026.9.6
// `apps/shared/OpenClawKit/Sources/OpenClawKit/WatchChatDelivery.swift` plus the upstream
// `OpenClawWatchPayloadType` vocabulary from `WatchCommands.swift`, so the OpenClawChatStore watch
// message journal compiles before the watch slice (W16) lands. W16 owns these contracts: delete this
// file at merge once `WatchChatDelivery.swift` and `OpenClawWatchPayloadType` exist (the duplicate
// declarations make the merge fail loudly until then). Nobody else may define these symbols.

/// Companion payload types exchanged between the iPhone and Apple Watch apps.
public enum OpenClawWatchPayloadType: String, Codable, Sendable, Equatable {
    /// `watch.notify`.
    case notify = "watch.notify"
    /// `watch.node.setup`.
    case directNodeSetup = "watch.node.setup"
    /// `watch.reply`.
    case reply = "watch.reply"
    /// `watch.app.snapshot`.
    case appSnapshot = "watch.app.snapshot"
    /// `watch.app.snapshotRequest`.
    case appSnapshotRequest = "watch.app.snapshotRequest"
    /// `watch.app.command`.
    case appCommand = "watch.app.command"
    /// `watch.chat.completion`.
    case chatCompletion = "watch.chat.completion"
    /// `watch.chat.delivery.command`.
    case chatDeliveryCommand = "watch.chat.delivery.command"
    /// `watch.chat.delivery.receipt`.
    case chatDeliveryReceipt = "watch.chat.delivery.receipt"
    /// `watch.chat.delivery.receiptAck`.
    case chatDeliveryReceiptAck = "watch.chat.delivery.receiptAck"
    /// `watch.execApproval.prompt`.
    case execApprovalPrompt = "watch.execApproval.prompt"
    /// `watch.execApproval.resolve`.
    case execApprovalResolve = "watch.execApproval.resolve"
    /// `watch.execApproval.resolved`.
    case execApprovalResolved = "watch.execApproval.resolved"
    /// `watch.execApproval.expired`.
    case execApprovalExpired = "watch.execApproval.expired"
    /// `watch.execApproval.snapshot`.
    case execApprovalSnapshot = "watch.execApproval.snapshot"
    /// `watch.execApproval.snapshotRequest`.
    case execApprovalSnapshotRequest = "watch.execApproval.snapshotRequest"
}

/// A phone-committed routing owner, captured before the Watch accepts user input.
public struct OpenClawWatchChatDeliveryContext: Codable, Sendable, Hashable {
    /// Contract version (currently 1).
    public let version: Int
    /// Stable gateway owner id (exact UTF-8 bytes).
    public let gatewayStableID: String
    /// Phone-minted route generation the Watch captured.
    public let routeGeneration: String
    /// Owning agent.
    public let agentId: String
    /// Presentation session key.
    public let sessionKey: String
    /// Canonical delivery session key.
    public let deliverySessionKey: String
    /// Gateway session routing contract.
    public let sessionRoutingContract: String

    /// Creates a delivery context.
    public init(
        gatewayStableID: String,
        routeGeneration: String,
        agentId: String,
        sessionKey: String,
        deliverySessionKey: String,
        sessionRoutingContract: String,
        version: Int = 1)
    {
        self.version = version
        self.gatewayStableID = gatewayStableID
        self.routeGeneration = routeGeneration
        self.agentId = agentId
        self.sessionKey = sessionKey
        self.deliverySessionKey = deliverySessionKey
        self.sessionRoutingContract = sessionRoutingContract
    }

    /// Byte-exact equality.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.version == rhs.version && lhs.identityBytes == rhs.identityBytes
    }

    /// Byte-exact hashing.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(self.version)
        hasher.combine(self.identityBytes)
    }

    private var identityBytes: [Data] {
        [
            self.gatewayStableID,
            self.routeGeneration,
            self.agentId,
            self.sessionKey,
            self.deliverySessionKey,
            self.sessionRoutingContract,
        ].map { Data($0.utf8) }
    }
}

/// Kind of Watch chat command.
public enum OpenClawWatchChatDeliveryKind: String, Codable, Sendable {
    /// A free-form chat message.
    case chat
    /// A quick reply to a prompt.
    case quickReply
}

/// Body of a Watch chat command.
public enum OpenClawWatchChatDeliveryBody: Codable, Sendable, Equatable {
    /// Free-form text.
    case chat(text: String)
    /// A quick-reply action.
    case quickReply(promptId: String, actionId: String, actionLabel: String?, note: String?)

    /// Command kind.
    public var kind: OpenClawWatchChatDeliveryKind {
        switch self {
        case .chat: .chat
        case .quickReply: .quickReply
        }
    }

    /// Byte-exact equality.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case let (.chat(left), .chat(right)):
            left.utf8.elementsEqual(right.utf8)
        case let (.quickReply(lp, la, ll, ln), .quickReply(rp, ra, rl, rn)):
            lp.utf8.elementsEqual(rp.utf8) && la.utf8.elementsEqual(ra.utf8)
                && ll.map { Data($0.utf8) } == rl.map { Data($0.utf8) }
                && ln.map { Data($0.utf8) } == rn.map { Data($0.utf8) }
        default:
            false
        }
    }
}

/// One Watch-originated chat command.
public struct OpenClawWatchChatDeliveryCommand: Codable, Sendable, Equatable {
    /// Payload type discriminator.
    public let type: OpenClawWatchPayloadType
    /// Routing owner captured before input.
    public let context: OpenClawWatchChatDeliveryContext
    /// Command identity (also the idempotency key).
    public let commandId: String
    /// Watch submission time (ms since 1970).
    public let submittedAtMs: Int64
    /// Command body.
    public let body: OpenClawWatchChatDeliveryBody

    /// Creates a command.
    public init(
        context: OpenClawWatchChatDeliveryContext,
        commandId: String,
        submittedAtMs: Int64,
        body: OpenClawWatchChatDeliveryBody)
    {
        self.type = .chatDeliveryCommand
        self.context = context
        self.commandId = commandId
        self.submittedAtMs = submittedAtMs
        self.body = body
    }

    /// Command kind.
    public var kind: OpenClawWatchChatDeliveryKind {
        self.body.kind
    }

    /// Send deadline (submission plus the 48 h lifetime).
    public var expiresAtMs: Int64 {
        let sum = self.submittedAtMs.addingReportingOverflow(OpenClawWatchChatDeliveryCodec.lifetimeMs)
        // Validation rejects overflow before admission; diagnostics must not trap on an invalid DTO.
        return sum.overflow ? Int64.max : sum.partialValue
    }

    /// Text sent to the gateway.
    public var text: String {
        switch self.body {
        case let .chat(text):
            return text
        case let .quickReply(promptId, actionId, actionLabel, note):
            let label = actionLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
            var lines = [
                "Watch reply: \(label?.isEmpty == false ? label! : actionId)",
                "promptId=\(promptId)",
                "actionId=\(actionId)",
                "replyId=\(self.commandId)",
                "sentAtMs=\(self.submittedAtMs)",
            ]
            if let note, !note.isEmpty { lines.append("note=\(note)") }
            return lines.joined(separator: "\n")
        }
    }

    /// Byte-exact equality.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.type == rhs.type && lhs.context == rhs.context
            && lhs.commandId.utf8.elementsEqual(rhs.commandId.utf8)
            && lhs.submittedAtMs == rhs.submittedAtMs && lhs.body == rhs.body
    }
}

/// Terminal outcome of a Watch command.
public enum OpenClawWatchChatDeliveryOutcome: Codable, Sendable, Equatable {
    /// The agent replied.
    case reply(text: String)
    /// The message was forwarded without an inline reply.
    case forwarded
    /// Delivery failed.
    case failed(code: String, message: String)
    /// Delivery could not be confirmed.
    case uncertain(message: String)

    /// Byte-exact equality.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case let (.reply(left), .reply(right)), let (.uncertain(left), .uncertain(right)):
            left.utf8.elementsEqual(right.utf8)
        case (.forwarded, .forwarded):
            true
        case let (.failed(lc, lm), .failed(rc, rm)):
            lc.utf8.elementsEqual(rc.utf8) && lm.utf8.elementsEqual(rm.utf8)
        default:
            false
        }
    }
}

/// Terminal receipt details.
public struct OpenClawWatchChatDeliveryTerminal: Codable, Sendable, Equatable {
    /// Receipt identity.
    public let receiptId: String
    /// Outcome.
    public let outcome: OpenClawWatchChatDeliveryOutcome
    /// Gateway run, when accepted.
    public let runId: String?
    /// Completion time (ms since 1970).
    public let completedAtMs: Int64

    /// Creates a terminal receipt.
    public init(
        receiptId: String,
        outcome: OpenClawWatchChatDeliveryOutcome,
        runId: String? = nil,
        completedAtMs: Int64)
    {
        self.receiptId = receiptId
        self.outcome = outcome
        self.runId = runId
        self.completedAtMs = completedAtMs
    }

    /// Byte-exact equality.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.receiptId.utf8.elementsEqual(rhs.receiptId.utf8)
            && lhs.outcome == rhs.outcome && lhs.completedAtMs == rhs.completedAtMs
            && lhs.runId.map { Data($0.utf8) } == rhs.runId.map { Data($0.utf8) }
    }
}

/// Receipt the phone returns for a Watch command.
public struct OpenClawWatchChatDeliveryReceipt: Codable, Sendable, Equatable {
    /// Receipt state.
    public enum State: Codable, Sendable, Equatable {
        /// The phone took custody.
        case admitted(atMs: Int64)
        /// The command finished.
        case terminal(OpenClawWatchChatDeliveryTerminal)
        /// The phone rejected the command permanently.
        case rejected(code: String, message: String)

        /// Byte-exact equality.
        public static func == (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case let (.admitted(left), .admitted(right)): left == right
            case let (.terminal(left), .terminal(right)): left == right
            case let (.rejected(lc, lm), .rejected(rc, rm)):
                lc.utf8.elementsEqual(rc.utf8) && lm.utf8.elementsEqual(rm.utf8)
            default: false
            }
        }
    }

    /// Payload type discriminator.
    public let type: OpenClawWatchPayloadType
    /// Routing owner captured before input.
    public let context: OpenClawWatchChatDeliveryContext
    /// Command identity (also the idempotency key).
    public let commandId: String
    /// Receipt state.
    public let state: State

    /// Creates a receipt.
    public init(context: OpenClawWatchChatDeliveryContext, commandId: String, state: State) {
        self.type = .chatDeliveryReceipt
        self.context = context
        self.commandId = commandId
        self.state = state
    }

    /// Terminal details, when finished.
    public var terminal: OpenClawWatchChatDeliveryTerminal? {
        guard case let .terminal(value) = self.state else { return nil }
        return value
    }

    /// Rejections are final presentation, not evidence that the phone took custody.
    public var outcome: OpenClawWatchChatDeliveryOutcome? {
        switch self.state {
        case .admitted: nil
        case let .terminal(terminal): terminal.outcome
        case let .rejected(code, message): .failed(code: code, message: message)
        }
    }

    /// Whether the receipt ends the command.
    public var isFinal: Bool {
        self.outcome != nil
    }

    /// Byte-exact equality.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.type == rhs.type && lhs.context == rhs.context && lhs.state == rhs.state
            && lhs.commandId.utf8.elementsEqual(rhs.commandId.utf8)
    }
}

/// Watch acknowledgement of a terminal receipt.
public struct OpenClawWatchChatDeliveryReceiptAck: Codable, Sendable, Equatable {
    /// Payload type discriminator.
    public let type: OpenClawWatchPayloadType
    /// Routing owner captured before input.
    public let context: OpenClawWatchChatDeliveryContext
    /// Command identity (also the idempotency key).
    public let commandId: String
    /// Receipt identity.
    public let receiptId: String

    /// Creates an acknowledgement.
    public init(context: OpenClawWatchChatDeliveryContext, commandId: String, receiptId: String) {
        self.type = .chatDeliveryReceiptAck
        self.context = context
        self.commandId = commandId
        self.receiptId = receiptId
    }

    /// Byte-exact equality.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.type == rhs.type && lhs.context == rhs.context
            && lhs.commandId.utf8.elementsEqual(rhs.commandId.utf8)
            && lhs.receiptId.utf8.elementsEqual(rhs.receiptId.utf8)
    }
}

/// Typed Watch delivery failure.
public struct OpenClawWatchChatDeliveryError: Error, LocalizedError, Sendable, Equatable {
    /// Stable failure code.
    public let code: String
    /// User-facing message.
    public let message: String

    /// Creates an error.
    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    /// User-facing message.
    public var errorDescription: String? {
        self.message
    }
}

/// The closed, bounded companion contract. These are app limits, not Gateway schema limits.
public enum OpenClawWatchChatDeliveryCodec {
    /// Command lifetime (48 h).
    public static let lifetimeMs: Int64 = 48 * 60 * 60 * 1000
    /// Largest tolerated Watch clock lead (5 min).
    public static let maxFutureSkewMs: Int64 = 5 * 60 * 1000
    /// Largest encoded envelope (48 KiB).
    public static let maxEnvelopeBytes = 48 * 1024
    /// Longest text in characters.
    public static let maxTextCharacters = 4000
    /// Longest text in UTF-8 bytes.
    public static let maxTextUTF8Bytes = 16 * 1024
    /// Most unexpired commands the phone keeps.
    public static let maxUnexpiredCommands = 1024
    /// Most commands awaiting dispatch.
    public static let maxPendingCommands = 128
    /// Rejection code for retired routes.
    public static let staleRouteCode = "stale_route"

    /// Encodes a value as a validated WatchConnectivity dictionary.
    public static func encode(_ value: some Encodable) throws -> [String: Any] {
        let data = try self.canonicalData(value)
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw self.invalidPayload()
        }
        try self.validateEnvelopeSize(payload)
        return payload
    }

    /// Canonical sorted-key JSON, bounded by the envelope limit.
    public static func canonicalData(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= self.maxEnvelopeBytes else { throw self.tooLarge() }
        return data
    }

    /// Decodes and validates a context.
    public static func decodeContext(_ payload: [String: Any]) throws -> OpenClawWatchChatDeliveryContext {
        let context: OpenClawWatchChatDeliveryContext = try self.decode(payload)
        try self.validateContext(context)
        return context
    }

    /// Decodes and structurally validates a command.
    public static func decodeCommandStructure(_ payload: [String: Any]) throws -> OpenClawWatchChatDeliveryCommand {
        let command: OpenClawWatchChatDeliveryCommand = try self.decode(payload)
        try self.validateCommandStructure(command)
        return command
    }

    /// Decodes and validates a receipt.
    public static func decodeReceipt(_ payload: [String: Any]) throws -> OpenClawWatchChatDeliveryReceipt {
        let receipt: OpenClawWatchChatDeliveryReceipt = try self.decode(payload)
        try self.validateReceipt(receipt)
        return receipt
    }

    /// Decodes and validates a receipt acknowledgement.
    public static func decodeReceiptAck(_ payload: [String: Any]) throws -> OpenClawWatchChatDeliveryReceiptAck {
        let ack: OpenClawWatchChatDeliveryReceiptAck = try self.decode(payload)
        try self.validateReceiptAck(ack)
        return ack
    }

    /// Validates a receipt acknowledgement.
    public static func validateReceiptAck(_ ack: OpenClawWatchChatDeliveryReceiptAck) throws {
        guard ack.type == .chatDeliveryReceiptAck else { throw self.invalidPayload() }
        try self.validateContext(ack.context)
        try self.identifier(ack.commandId)
        try self.identifier(ack.receiptId)
        _ = try self.encode(ack)
    }

    /// Validates a context.
    public static func validateContext(_ context: OpenClawWatchChatDeliveryContext) throws {
        guard context.version == 1 else {
            throw OpenClawWatchChatDeliveryError(
                code: "upgrade_required",
                message: String(localized: "Update OpenClaw on iPhone and Watch."))
        }
        try self.identifier(context.gatewayStableID, limit: 2048)
        try self.identifier(context.routeGeneration)
        try self.identifier(context.agentId)
        try self.identifier(context.sessionKey, limit: 512)
        try self.identifier(context.deliverySessionKey, limit: 512)
        try self.identifier(context.sessionRoutingContract, limit: 2048)
    }

    /// Validates a command against the clock.
    public static func validateCommand(_ command: OpenClawWatchChatDeliveryCommand, nowMs: Int64) throws {
        try self.validateCommandStructure(command)
        guard nowMs >= 0,
              nowMs <= Int64.max - self.maxFutureSkewMs,
              command.submittedAtMs <= nowMs + self.maxFutureSkewMs
        else {
            throw OpenClawWatchChatDeliveryError(
                code: "clock_error",
                message: String(localized: "Check the date and time on iPhone and Watch."))
        }
        guard nowMs < command.expiresAtMs else {
            throw OpenClawWatchChatDeliveryError(
                code: "expired",
                message: String(localized: "This Watch message expired. Check Chat on iPhone."))
        }
    }

    /// Validates a command's structure.
    public static func validateCommandStructure(_ command: OpenClawWatchChatDeliveryCommand) throws {
        guard command.type == .chatDeliveryCommand else { throw self.invalidPayload() }
        try self.validateContext(command.context)
        try self.identifier(command.commandId)
        guard command.submittedAtMs >= 0,
              command.submittedAtMs <= Int64.max - self.lifetimeMs
        else {
            throw OpenClawWatchChatDeliveryError(
                code: "clock_error", message: String(localized: "Invalid Watch message submission time."))
        }
        if case let .quickReply(promptId, actionId, actionLabel, note) = command.body {
            try self.identifier(promptId)
            try self.identifier(actionId)
            if let actionLabel { try self.text(actionLabel, allowEmpty: true) }
            if let note { try self.text(note, allowEmpty: true) }
        }
        try self.text(command.text)
        _ = try self.encode(command)
    }

    /// Validates a receipt.
    public static func validateReceipt(_ receipt: OpenClawWatchChatDeliveryReceipt) throws {
        guard receipt.type == .chatDeliveryReceipt else { throw self.invalidPayload() }
        try self.validateContext(receipt.context)
        try self.identifier(receipt.commandId)
        switch receipt.state {
        case let .admitted(atMs):
            guard atMs >= 0 else { throw self.invalidPayload() }
        case let .rejected(code, message):
            guard self.isPermanentRejectionCode(code) else { throw self.invalidPayload() }
            try self.text(message)
        case let .terminal(terminal):
            try self.identifier(terminal.receiptId)
            if let runId = terminal.runId { try self.identifier(runId) }
            guard terminal.completedAtMs >= 0 else { throw self.invalidPayload() }
            switch terminal.outcome {
            case let .reply(text): try self.text(text)
            case .forwarded: break
            case let .failed(code, message):
                try self.identifier(code)
                try self.text(message)
            case let .uncertain(message): try self.text(message)
            }
        }
        _ = try self.encode(receipt)
    }

    /// Whether a rejection code is permanent.
    public static func isPermanentRejectionCode(_ code: String) -> Bool {
        switch code {
        case self.staleRouteCode, "expired", "routing_changed", "identity_conflict", "clock_error": true
        default: false
        }
    }

    /// Trims and truncates reply text to the contract limits.
    public static func boundedReplyText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = ""
        var bytes = 0
        var count = 0
        for character in trimmed {
            let part = String(character)
            guard count < self.maxTextCharacters, bytes + part.utf8.count <= self.maxTextUTF8Bytes else {
                while !result.isEmpty, count >= self.maxTextCharacters || bytes + 3 > self.maxTextUTF8Bytes {
                    bytes -= String(result.removeLast()).utf8.count
                    count -= 1
                }
                return result + "…"
            }
            result.append(character)
            bytes += part.utf8.count
            count += 1
        }
        return result
    }

    private static func decode<Value: Codable>(_ payload: [String: Any]) throws -> Value {
        try self.validateEnvelopeSize(payload)
        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            guard data.count <= self.maxEnvelopeBytes else { throw self.tooLarge() }
            let value = try JSONDecoder().decode(Value.self, from: data)
            let canonical = try JSONSerialization.jsonObject(with: self.canonicalData(value))
            guard self.sameFields(payload, canonical) else { throw self.invalidPayload() }
            return value
        } catch let error as OpenClawWatchChatDeliveryError {
            throw error
        } catch {
            throw self.invalidPayload()
        }
    }

    private static func sameFields(_ value: Any, _ canonical: Any) -> Bool {
        if let expected = canonical as? [String: Any] {
            guard let actual = value as? [String: Any], Set(actual.keys) == Set(expected.keys) else { return false }
            return expected.allSatisfy { key, value in
                actual[key].map { self.sameFields($0, value) } == true
            }
        }
        if let expected = canonical as? [Any] {
            guard let actual = value as? [Any], actual.count == expected.count else { return false }
            return zip(actual, expected).allSatisfy { self.sameFields($0, $1) }
        }
        return true
    }

    private static func validateEnvelopeSize(_ payload: [String: Any]) throws {
        guard PropertyListSerialization.propertyList(payload, isValidFor: .binary) else {
            throw self.invalidPayload()
        }
        let data = try PropertyListSerialization.data(fromPropertyList: payload, format: .binary, options: 0)
        guard data.count <= self.maxEnvelopeBytes else { throw self.tooLarge() }
    }

    private static func identifier(_ value: String, limit: Int = 256) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.count <= limit,
              value.utf8.count <= limit * 4,
              !value.utf8.contains(0)
        else { throw self.invalidPayload() }
    }

    private static func text(_ value: String, allowEmpty: Bool = false) throws {
        guard allowEmpty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw self.invalidPayload()
        }
        guard value.count <= self.maxTextCharacters, value.utf8.count <= self.maxTextUTF8Bytes else {
            throw self.tooLarge()
        }
    }

    private static func invalidPayload() -> OpenClawWatchChatDeliveryError {
        OpenClawWatchChatDeliveryError(
            code: "invalid_payload", message: String(localized: "Invalid Watch chat delivery message."))
    }

    private static func tooLarge() -> OpenClawWatchChatDeliveryError {
        OpenClawWatchChatDeliveryError(
            code: "too_large",
            message: String(localized: "This Watch message is too large. Shorten it and try again."))
    }
}
