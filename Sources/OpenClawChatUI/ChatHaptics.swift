import Foundation

#if os(iOS)
import UIKit
#endif

/// Haptic feedback for chat run milestones; injectable so tests and hosts can observe or replace it.
public struct OpenClawChatHaptics: Sendable {
    /// Haptic milestone.
    public enum Event: Sendable, Equatable {
        /// The user's message was accepted.
        case messageSent
        /// A run completed.
        case runCompleted
        /// A run failed.
        case runFailed
    }

    private let performer: @Sendable (Event) -> Void

    /// Creates the platform default performer (UIKit feedback generators on iOS; no-op elsewhere).
    public init() {
        self.performer = Self.defaultPerformer
    }

    /// Creates haptics with a custom performer.
    public init(performer: @escaping @Sendable (Event) -> Void) {
        self.performer = performer
    }

    /// Performs a haptic event.
    public func perform(_ event: Event) {
        self.performer(event)
    }

    private static let defaultPerformer: @Sendable (Event) -> Void = { event in
        #if os(iOS)
        Task { @MainActor in
            switch event {
            case .messageSent:
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            case .runCompleted:
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            case .runFailed:
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
        #else
        // NSHapticFeedbackManager only fires reliably from gesture contexts, so macOS is a no-op.
        _ = event
        #endif
    }
}
