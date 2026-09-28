#if canImport(AppIntents)
import AppIntents
import Foundation
import OpenClawKit
#if compiler(>=6.4) && canImport(UserNotifications)
import UserNotifications
#endif
#if compiler(>=6.4) && canImport(NowPlaying)
import NowPlaying
#endif

extension OpenClawAppIntents {
    /// Entity identifier of the session entity for a session key.
    /// - Parameter sessionKey: Session key.
    /// - Returns: Identifier usable for notification, Now Playing and relevance linking.
    public static func sessionEntityIdentifier(_ sessionKey: String) -> EntityIdentifier {
        EntityIdentifier(for: OpenClawSessionAppEntity.self, identifier: sessionKey)
    }
}

/// Publishes which OpenClaw session is relevant to the system (Siri, Apple Intelligence) while
/// talk mode plays audio.
public protocol OpenClawRelevantEntitiesUpdating: Sendable {
    /// Marks a session as relevant to Now Playing audio.
    /// - Parameter session: Session entity.
    func setNowPlayingSession(_ session: OpenClawSessionAppEntity) async throws

    /// Clears the Now Playing relevance.
    func clearNowPlayingSession() async throws
}

/// Relevance updater that does nothing (pre-27 systems).
public struct NoopRelevantEntitiesUpdater: OpenClawRelevantEntitiesUpdating {
    /// Creates a no-op updater.
    public init() {}

    /// Does nothing.
    public func setNowPlayingSession(_ session: OpenClawSessionAppEntity) async throws {}

    /// Does nothing.
    public func clearNowPlayingSession() async throws {}
}

/// Keeps the Now Playing relevance in sync with talk mode.
///
/// Call ``talkStarted(sessionKey:title:)`` when talk playback starts and ``talkStopped()`` when it ends.
public actor OpenClawTalkRelevanceCoordinator {
    private let updater: any OpenClawRelevantEntitiesUpdating
    /// Session currently marked relevant.
    public private(set) var activeSessionKey: String?

    /// Creates a coordinator.
    /// - Parameter updater: Relevance updater; `nil` uses `RelevantEntities` on OS 27, otherwise a no-op.
    public init(updater: (any OpenClawRelevantEntitiesUpdating)? = nil) {
        self.updater = updater ?? Self.makeSystemUpdater()
    }

    /// Marks the talk session as relevant.
    /// - Parameters:
    ///   - sessionKey: Session key.
    ///   - title: Optional session title.
    public func talkStarted(sessionKey: String, title: String? = nil) async {
        guard self.activeSessionKey != sessionKey else { return }
        self.activeSessionKey = sessionKey
        try? await self.updater.setNowPlayingSession(OpenClawSessionAppEntity(sessionKey: sessionKey, title: title))
    }

    /// Clears the relevance when talk stops.
    public func talkStopped() async {
        guard self.activeSessionKey != nil else { return }
        self.activeSessionKey = nil
        try? await self.updater.clearNowPlayingSession()
    }

    static func makeSystemUpdater() -> any OpenClawRelevantEntitiesUpdating {
        #if compiler(>=6.4)
        if #available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *) {
            return SystemRelevantEntitiesUpdater()
        }
        #endif
        return NoopRelevantEntitiesUpdater()
    }
}

#if compiler(>=6.4)
/// `RelevantEntities`-backed relevance updater (OS 27).
@available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
public struct SystemRelevantEntitiesUpdater: OpenClawRelevantEntitiesUpdating {
    /// Creates the system updater.
    public init() {}

    /// Updates `RelevantEntities` for the Now Playing audio context.
    public func setNowPlayingSession(_ session: OpenClawSessionAppEntity) async throws {
        try await RelevantEntities.shared.updateEntities([session], for: .audio(.nowPlaying))
    }

    /// Removes all Now Playing relevance.
    public func clearNowPlayingSession() async throws {
        try await RelevantEntities.shared.removeAllEntities(for: .audio(.nowPlaying))
    }
}
#endif

#if compiler(>=6.4) && canImport(UserNotifications)
@available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
extension UNMutableNotificationContent {
    /// Links the notification to an OpenClaw session so Siri and Apple Intelligence can act on it
    /// ("reply to this"). Use for `system.notify` payloads with a `sessionKey`, exec-approval prompts
    /// and inbound-message notifications.
    /// - Parameter sessionKey: Session key.
    public func linkOpenClawSession(_ sessionKey: String) {
        self.appEntityIdentifiers = [OpenClawAppIntents.sessionEntityIdentifier(sessionKey)]
    }
}
#endif

#if compiler(>=6.4) && canImport(NowPlaying)
@available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
@available(iOSApplicationExtension, unavailable)
extension MediaContentRepresentable {
    /// Links Now Playing content to an OpenClaw session.
    /// - Parameter sessionKey: Session key.
    public mutating func linkOpenClawSession(_ sessionKey: String) {
        self.appEntityIdentifiers = [OpenClawAppIntents.sessionEntityIdentifier(sessionKey)]
    }
}

extension OpenClawAppIntents {
    /// Content decorator for a Now Playing publisher that links the content to a session
    /// (assign it to the publisher's `contentDecorator`).
    /// - Parameter sessionKey: Session key.
    /// - Returns: Decorator closure.
    @available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
    @available(iOSApplicationExtension, unavailable)
    public static func nowPlayingContentDecorator(sessionKey: String) -> @MainActor (inout GenericContent) -> Void {
        { content in
            content.linkOpenClawSession(sessionKey)
        }
    }
}
#endif
#endif
