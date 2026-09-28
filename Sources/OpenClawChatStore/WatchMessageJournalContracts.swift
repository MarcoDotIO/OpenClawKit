import Foundation
import OpenClawChatUI
import OpenClawKit

// Ported from upstream OpenClaw 2026.9.6 `apps/shared/OpenClawKit/Sources/OpenClawChatUI/WatchMessageJournalContracts.swift`.

/// The gateway route that owns a Watch message. Gateway identifiers compare as exact UTF-8 bytes.
public struct OpenClawWatchMessageOwner: Equatable, Sendable {
    /// Stable gateway owner id.
    public let gatewayStableID: String
    /// Phone-minted route generation; `nil` for ownerless legacy rows.
    public let routeGeneration: String?

    /// Creates an owner.
    public init(gatewayStableID: String, routeGeneration: String?) {
        self.gatewayStableID = gatewayStableID
        self.routeGeneration = routeGeneration
    }

    /// Creates the owner a delivery context was captured under.
    public init(context: OpenClawWatchChatDeliveryContext) {
        self.init(gatewayStableID: context.gatewayStableID, routeGeneration: context.routeGeneration)
    }

    /// Byte-exact equality.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        Data(lhs.gatewayStableID.utf8) == Data(rhs.gatewayStableID.utf8) &&
            lhs.routeGeneration == rhs.routeGeneration
    }
}

/// The route the phone hands the Watch before it accepts input.
public struct OpenClawWatchMessageRoute: Equatable, Sendable {
    /// Owning gateway route.
    public let owner: OpenClawWatchMessageOwner
    /// Session routing identity persisted for that gateway.
    public let routingIdentity: OpenClawChatSessionRoutingIdentity
}

/// Lifecycle phase of a journaled Watch message.
public enum OpenClawWatchMessagePhase: String, Codable, Sendable {
    /// Admitted and waiting for dispatch.
    case queued
    /// Claimed by a dispatcher (`chat.send` may be in flight).
    case sending
    /// The gateway accepted the run.
    case accepted
    /// A terminal receipt is waiting for the Watch to acknowledge it.
    case receiptReady
    /// The terminal receipt reached its destination.
    case received
    /// Imported legacy text that needs user review; it never sends automatically.
    case needsReview
    /// An identity-only marker that blocks replay of a retired message ID.
    case tombstone
}

/// Where a terminal receipt is delivered.
public enum OpenClawWatchMessageReceiptDestination: String, Codable, Sendable {
    /// The Watch acknowledges the receipt.
    case watch
    /// The phone consumes the receipt itself.
    case phone
}

/// One journaled Watch message.
public struct OpenClawWatchMessageEntry: Identifiable, Equatable, Sendable {
    /// Command identity.
    public let commandId: String
    /// SQLite and the wire protocol distinguish canonically equivalent UTF-8 identifiers.
    public var id: Data {
        Data(self.commandId.utf8)
    }

    /// Owning route; `nil` for ownerless legacy rows.
    public let owner: OpenClawWatchMessageOwner?
    /// The admitted command; `nil` for legacy or dismissed rows.
    public let command: OpenClawWatchChatDeliveryCommand?
    /// Text shown for the row.
    public let displayText: String?
    /// Lifecycle phase.
    public let phase: OpenClawWatchMessagePhase
    /// Receipt destination.
    public let destination: OpenClawWatchMessageReceiptDestination
    /// Admission time (ms since 1970).
    public let admittedAtMs: Int64
    /// Original send deadline; `nil` for imported rows without one.
    public let expiresAtMs: Int64?
    /// Dispatch attempt version (incremented by every claim).
    public let attemptVersion: Int64
    /// Gateway run that accepted the message.
    public let acceptedRunID: String?
    /// Latest receipt.
    public let receipt: OpenClawWatchChatDeliveryReceipt?

    /// Field-by-field equality with a byte-exact command identity.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id &&
            lhs.owner == rhs.owner &&
            lhs.command == rhs.command &&
            lhs.displayText == rhs.displayText &&
            lhs.phase == rhs.phase &&
            lhs.destination == rhs.destination &&
            lhs.admittedAtMs == rhs.admittedAtMs &&
            lhs.expiresAtMs == rhs.expiresAtMs &&
            lhs.attemptVersion == rhs.attemptVersion &&
            lhs.acceptedRunID == rhs.acceptedRunID &&
            lhs.receipt == rhs.receipt
    }
}

/// Result of a conditional journal transition.
public enum OpenClawWatchMessageMutation: Equatable, Sendable {
    /// The row changed.
    case applied
    /// The row no longer exists.
    case missing
    /// The row changed since the caller observed it.
    case superseded
}

/// A decoded legacy snapshot, not a second runtime queue. Missing ownership
/// never becomes permission to send an imported message.
public struct OpenClawWatchMessageLegacyImport: Sendable {
    /// One legacy message.
    public struct Message: Sendable {
        /// Legacy message id.
        public let id: String
        /// Gateway the message was queued for, when recorded.
        public let gatewayStableID: String?
        /// Message text.
        public let text: String
        /// Submission time (ms since 1970), when recorded.
        public let submittedAtMs: Int64?

        /// Creates a legacy message.
        public init(id: String, gatewayStableID: String?, text: String, submittedAtMs: Int64?) {
            self.id = id
            self.gatewayStableID = gatewayStableID
            self.text = text
            self.submittedAtMs = submittedAtMs
        }
    }

    /// Legacy queued messages.
    public let messages: [Message]
    /// Recently delivered legacy message ids (they only block replay).
    public let recentMessageIDs: [String]

    /// Creates a legacy snapshot.
    public init(messages: [Message], recentMessageIDs: [String]) {
        self.messages = messages
        self.recentMessageIDs = recentMessageIDs
    }
}
