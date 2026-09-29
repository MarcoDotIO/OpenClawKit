import OpenClawProtocol

/// Binds operator event delivery to one gateway user profile on one socket (`profile-binding-v1`).
///
/// A view bound to the account a user selected must only render events addressed to that
/// profile. Gateways that advertise `profile-binding-v1` stamp events with `recipientProfileId`;
/// the binding drops events that are missing it, address another profile, or come from another
/// socket generation, and reports why so the view can re-bind (for example after `users.self`).
/// Profile ids are opaque and compared exactly (no trimming or case folding).
public struct GatewayProfileEventBinding: Sendable, Equatable {
    /// Why an event was not delivered.
    public enum DropReason: String, Sendable, Equatable {
        /// The event arrived on a different socket generation than the binding.
        case staleConnectionGeneration
        /// The event carries no `recipientProfileId`.
        case missingRecipientProfile
        /// The event addresses a different profile.
        case recipientProfileMismatch
    }

    /// Admission outcome for one event.
    public enum Decision: Sendable, Equatable {
        /// Deliver the event.
        case deliver
        /// Drop the event; a binding failure the owner should surface or repair.
        case drop(DropReason)
    }

    /// Socket generation the binding belongs to (``GatewayChannelActor/currentConnectionGeneration()``).
    public let connectionGeneration: UInt64
    /// Canonical profile id from `users.self`.
    public let profileID: String

    /// Creates a binding for one socket generation and profile.
    public init(connectionGeneration: UInt64, profileID: String) {
        self.connectionGeneration = connectionGeneration
        self.profileID = profileID
    }

    /// Decides whether `event`, received on `connectionGeneration`, belongs to this binding.
    public func admit(_ event: EventFrame, connectionGeneration: UInt64) -> Decision {
        guard connectionGeneration == self.connectionGeneration else {
            return .drop(.staleConnectionGeneration)
        }
        guard let recipient = event.recipientprofileid else {
            return .drop(.missingRecipientProfile)
        }
        return recipient == self.profileID ? .deliver : .drop(.recipientProfileMismatch)
    }
}
