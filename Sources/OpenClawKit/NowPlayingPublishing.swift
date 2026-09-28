import Foundation
#if canImport(MediaPlayer)
import MediaPlayer
#endif
#if compiler(>=6.4) && canImport(NowPlaying)
import NowPlaying
import Observation
#if os(iOS) && canImport(UIKit)
import UIKit
#endif
#endif

/// What Talk or chat playback publishes to the system Now Playing surfaces.
public struct OpenClawNowPlayingMetadata: Equatable, Sendable {
    /// Playback state shown by Now Playing.
    public enum State: Equatable, Sendable {
        /// Audio is playing at ``OpenClawNowPlayingMetadata/playbackRate``.
        case playing
        /// Playback is paused.
        case paused
        /// Playback is waiting for audio.
        case buffering
        /// Playback stopped.
        case stopped
        /// Playback was interrupted by the system (call, alarm, another app).
        case interrupted
    }

    /// Stable content identifier (for example `talk:<utterance id>`).
    public var contentID: String
    /// Title (agent or message name).
    public var title: String
    /// Subtitle (for example `Talk`).
    public var subtitle: String?
    /// Total duration in seconds; `nil` for live content such as Talk speech.
    public var duration: TimeInterval?
    /// Elapsed playback time in seconds.
    public var elapsed: TimeInterval
    /// Playback rate while playing (1 = normal speed).
    public var playbackRate: Double
    /// Playback state.
    public var state: State

    /// Creates Now Playing metadata.
    /// - Parameters:
    ///   - contentID: Stable content identifier.
    ///   - title: Title.
    ///   - subtitle: Subtitle.
    ///   - duration: Total duration, or `nil` for live content.
    ///   - elapsed: Elapsed playback time.
    ///   - playbackRate: Playback rate while playing.
    ///   - state: Playback state.
    public init(
        contentID: String,
        title: String,
        subtitle: String? = nil,
        duration: TimeInterval? = nil,
        elapsed: TimeInterval = 0,
        playbackRate: Double = 1,
        state: State = .playing)
    {
        self.contentID = contentID
        self.title = title
        self.subtitle = subtitle
        self.duration = duration
        self.elapsed = elapsed
        self.playbackRate = playbackRate
        self.state = state
    }
}

/// A remote command delivered from Now Playing (lock screen, Control Center, headset, watch).
public enum OpenClawNowPlayingCommand: Equatable, Sendable {
    /// Resume playback.
    case play
    /// Pause playback.
    case pause
    /// Toggle play/pause.
    case togglePlayPause
    /// Stop playback.
    case stop
    /// Skip forward by the interval in seconds.
    case skipForward(TimeInterval)
    /// Skip backward by the interval in seconds.
    case skipBackward(TimeInterval)
}

/// Publishes playback to the system Now Playing surfaces.
///
/// Use ``OpenClawNowPlaying/makeSystemPublisher()`` for the platform default (NowPlaying
/// `MediaSession` on OS 27, `MPNowPlayingInfoCenter` before), or inject a fake in tests.
@MainActor
public protocol OpenClawNowPlayingPublishing: AnyObject {
    /// Publishes or updates the current item.
    func publish(_ metadata: OpenClawNowPlayingMetadata)
    /// Installs (or removes, with `nil`) the handler for remote commands.
    func setCommandHandler(_ handler: (@MainActor @Sendable (OpenClawNowPlayingCommand) -> Void)?)
    /// Clears Now Playing and removes command handlers.
    func clear()
}

/// Factories for the system Now Playing publisher.
public enum OpenClawNowPlaying {
    /// Returns the platform publisher: NowPlaying `MediaSession` on iOS/macOS/tvOS/watchOS/visionOS 27,
    /// otherwise `MPNowPlayingInfoCenter`.
    ///
    /// `MediaSession` is unavailable in iOS app extensions; extensions use
    /// ``makeExtensionSafePublisher()``.
    @available(iOSApplicationExtension, unavailable)
    @MainActor
    public static func makeSystemPublisher() -> any OpenClawNowPlayingPublishing {
        #if compiler(>=6.4) && canImport(NowPlaying)
        if #available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *) {
            return MediaSessionNowPlayingPublisher()
        }
        #endif
        return self.makeExtensionSafePublisher()
    }

    /// Returns the `MPNowPlayingInfoCenter` publisher, which is the only path compiled for app extensions.
    @MainActor
    public static func makeExtensionSafePublisher() -> any OpenClawNowPlayingPublishing {
        #if canImport(MediaPlayer)
        return MediaPlayerNowPlayingPublisher()
        #else
        return NoopNowPlayingPublisher()
        #endif
    }
}

@MainActor
final class NoopNowPlayingPublisher: OpenClawNowPlayingPublishing {
    func publish(_: OpenClawNowPlayingMetadata) {}
    func setCommandHandler(_: (@MainActor @Sendable (OpenClawNowPlayingCommand) -> Void)?) {}
    func clear() {}
}

#if canImport(MediaPlayer)
/// Now Playing publisher backed by `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter`.
@MainActor
public final class MediaPlayerNowPlayingPublisher: OpenClawNowPlayingPublishing {
    /// Preferred skip interval, in seconds, for finite content.
    nonisolated public static let skipInterval: TimeInterval = 15

    private var commandTargets: [(command: MPRemoteCommand, token: Any)] = []
    private var handler: (@MainActor @Sendable (OpenClawNowPlayingCommand) -> Void)?

    /// Creates a publisher that writes to the process-wide Now Playing info center.
    public init() {}

    /// Publishes `nowPlayingInfo` (title, artist, duration, elapsed, rate, live flag).
    public func publish(_ metadata: OpenClawNowPlayingMetadata) {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = Self.makeNowPlayingInfo(metadata)
        #if os(macOS)
        MPNowPlayingInfoCenter.default().playbackState = Self.playbackState(metadata.state)
        #endif
        self.updateSkipCommands(enabled: metadata.duration != nil)
    }

    /// Registers remote command targets; `nil` removes them.
    public func setCommandHandler(_ handler: (@MainActor @Sendable (OpenClawNowPlayingCommand) -> Void)?) {
        for target in self.commandTargets {
            target.command.removeTarget(target.token)
        }
        self.commandTargets.removeAll()
        self.handler = handler
        guard handler != nil else { return }

        let center = MPRemoteCommandCenter.shared()
        self.addTarget(to: center.playCommand) { _ in .play }
        self.addTarget(to: center.pauseCommand) { _ in .pause }
        self.addTarget(to: center.togglePlayPauseCommand) { _ in .togglePlayPause }
        self.addTarget(to: center.stopCommand) { _ in .stop }
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.skipInterval)]
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.skipInterval)]
        self.addTarget(to: center.skipForwardCommand) { event in
            .skipForward((event as? MPSkipIntervalCommandEvent)?.interval ?? Self.skipInterval)
        }
        self.addTarget(to: center.skipBackwardCommand) { event in
            .skipBackward((event as? MPSkipIntervalCommandEvent)?.interval ?? Self.skipInterval)
        }
    }

    /// Clears `nowPlayingInfo` and removes command targets.
    public func clear() {
        self.setCommandHandler(nil)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        #if os(macOS)
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        #endif
    }

    /// Builds the `nowPlayingInfo` dictionary for `metadata`.
    nonisolated static func makeNowPlayingInfo(_ metadata: OpenClawNowPlayingMetadata) -> [String: Any] {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: metadata.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: metadata.elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: metadata.state == .playing ? metadata.playbackRate : 0,
            MPNowPlayingInfoPropertyIsLiveStream: metadata.duration == nil,
        ]
        if let subtitle = metadata.subtitle {
            info[MPMediaItemPropertyArtist] = subtitle
        }
        if let duration = metadata.duration {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        return info
    }

    #if os(macOS)
    private static func playbackState(_ state: OpenClawNowPlayingMetadata.State) -> MPNowPlayingPlaybackState {
        switch state {
        case .playing: .playing
        case .paused, .buffering: .paused
        case .stopped: .stopped
        case .interrupted: .interrupted
        }
    }
    #endif

    private func updateSkipCommands(enabled: Bool) {
        let center = MPRemoteCommandCenter.shared()
        center.skipForwardCommand.isEnabled = enabled && self.handler != nil
        center.skipBackwardCommand.isEnabled = enabled && self.handler != nil
    }

    private func addTarget(
        to remoteCommand: MPRemoteCommand,
        command: @escaping @Sendable (MPRemoteCommandEvent) -> OpenClawNowPlayingCommand)
    {
        let token = remoteCommand.addTarget { [weak self] event in
            let resolved = command(event)
            Task { @MainActor [weak self] in
                self?.handler?(resolved)
            }
            return .success
        }
        self.commandTargets.append((remoteCommand, token))
    }
}
#endif

#if compiler(>=6.4) && canImport(NowPlaying)
/// Now Playing publisher backed by the NowPlaying framework's `MediaSession` (OS 27).
///
/// The session is created lazily on first publish and asks to become the application's primary
/// session (and, on iOS while the app is in the foreground, the system primary session).
/// `MediaSession` is unavailable in iOS app extensions.
@available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
@available(iOSApplicationExtension, unavailable)
@MainActor
public final class MediaSessionNowPlayingPublisher: OpenClawNowPlayingPublishing {
    /// Identifier of the SDK's media session representable.
    public static let representableID = "ai.openclaw.nowplaying"
    /// Preferred skip interval, in seconds, for finite content.
    nonisolated public static let skipInterval: TimeInterval = 15

    /// Observable model that `MediaSession` reads; every mutation republishes Now Playing.
    @Observable
    @MainActor
    final class Representable: MediaSessionRepresentable {
        let id = MediaSessionNowPlayingPublisher.representableID
        var content: (any MediaContentRepresentable)?
        var playbackSnapshot: MediaPlaybackSnapshot?
        var commands: [MediaCommand] = []
    }

    /// Adjusts the published content before it reaches the session, for example to set
    /// `appEntityIdentifiers` (OpenClawAppIntents) or `genre`.
    public var contentDecorator: (@MainActor (inout GenericContent) -> Void)?
    /// Artwork attached to published content.
    public var artwork: Artwork?

    let representable = Representable()
    private var session: MediaSession<Representable>?
    private var handler: (@MainActor @Sendable (OpenClawNowPlayingCommand) -> Void)?
    private var lastMetadata: OpenClawNowPlayingMetadata?

    /// Creates a publisher; no session exists until the first ``publish(_:)``.
    public init() {}

    /// Whether the media session is the application's primary session.
    public var isApplicationPrimary: Bool {
        self.session?.isApplicationPrimary ?? false
    }

    /// Publishes content, playback snapshot, and commands, creating the session on first use.
    public func publish(_ metadata: OpenClawNowPlayingMetadata) {
        self.lastMetadata = metadata
        var content = GenericContent(
            id: metadata.contentID,
            title: metadata.title,
            subtitle: metadata.subtitle,
            type: .audio,
            duration: Self.mediaDuration(metadata),
            artwork: self.artwork)
        self.contentDecorator?(&content)
        self.representable.content = content
        self.representable.playbackSnapshot = Self.makeSnapshot(metadata, timestamp: Date())
        self.representable.commands = self.makeCommands(for: metadata)
        self.ensureSession()
    }

    /// Installs (or removes) the remote command handler and republishes commands.
    public func setCommandHandler(_ handler: (@MainActor @Sendable (OpenClawNowPlayingCommand) -> Void)?) {
        self.handler = handler
        if let lastMetadata {
            self.representable.commands = self.makeCommands(for: lastMetadata)
        }
    }

    /// Clears content, publishes a stopped snapshot, and drops the session.
    public func clear() {
        self.handler = nil
        self.lastMetadata = nil
        self.representable.content = nil
        self.representable.playbackSnapshot = MediaPlaybackSnapshot(state: .stopped)
        self.representable.commands = []
        self.session = nil
    }

    /// Maps SDK metadata onto a NowPlaying playback snapshot.
    static func makeSnapshot(_ metadata: OpenClawNowPlayingMetadata, timestamp: Date) -> MediaPlaybackSnapshot {
        let state: MediaPlaybackSnapshot.PlaybackState = switch metadata.state {
        case .playing: .playing(rate: Float(metadata.playbackRate))
        case .paused: .paused
        case .buffering: .buffering
        case .stopped: .stopped
        case .interrupted: .interrupted
        }
        return MediaPlaybackSnapshot(
            state: state,
            defaultPlaybackRate: 1,
            elapsedTime: metadata.elapsed,
            timestamp: timestamp)
    }

    static func mediaDuration(_ metadata: OpenClawNowPlayingMetadata) -> MediaDuration {
        metadata.duration.map { .finite($0) } ?? .live
    }

    private func makeCommands(for metadata: OpenClawNowPlayingMetadata) -> [MediaCommand] {
        guard self.handler != nil else { return [] }
        var commands: [MediaCommand] = [
            .play { [weak self] in self?.dispatch(.play) },
            .pause { [weak self] in self?.dispatch(.pause) },
            .togglePlayPause { [weak self] in self?.dispatch(.togglePlayPause) },
            .stop { [weak self] in self?.dispatch(.stop) },
        ]
        if metadata.duration != nil {
            commands.append(.skipForward(preferredIntervals: [Self.skipInterval]) { [weak self] interval in
                self?.dispatch(.skipForward(interval))
            })
            commands.append(.skipBackward(preferredIntervals: [Self.skipInterval]) { [weak self] interval in
                self?.dispatch(.skipBackward(interval))
            })
        }
        return commands
    }

    private func dispatch(_ command: OpenClawNowPlayingCommand) {
        self.handler?(command)
    }

    private func ensureSession() {
        guard self.session == nil else { return }
        let session = MediaSession(self.representable)
        self.session = session
        Task { @MainActor [weak self, session] in
            guard self?.session === session else { return }
            if session.canBecomeApplicationPrimary {
                try? await session.requestToBecomeApplicationPrimary()
            }
            #if os(iOS) && canImport(UIKit)
            // The system-primary request has no effect unless the app is in the foreground.
            if UIApplication.shared.applicationState == .active, self?.session === session {
                try? await session.requestToBecomeSystemPrimary()
            }
            #endif
        }
    }
}
#endif
