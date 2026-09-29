import Foundation

import OpenClawKit

@MainActor
protocol ChatMediaPlaybackOwner: AnyObject {
    func stopForMediaPlaybackInterruption()
}

struct ChatMediaNowPlayingMetadata: Equatable, Sendable {
    let title: String
    let duration: TimeInterval
    let elapsed: TimeInterval
    let playbackRate: Double
}

enum ChatMediaRemoteCommand: Equatable, Sendable {
    case play
    case pause
    case toggle
}

@MainActor
protocol ChatMediaNowPlayingOwner: ChatMediaPlaybackOwner {
    var nowPlayingMetadata: ChatMediaNowPlayingMetadata { get }
    func handleRemoteCommand(_ command: ChatMediaRemoteCommand)
}

@MainActor
protocol ChatMediaNowPlayingPublishing: AnyObject {
    func publish(_ metadata: ChatMediaNowPlayingMetadata)
    func setRemoteCommandHandler(
        _ handler: (@MainActor @Sendable (ChatMediaRemoteCommand) -> Void)?)
    func clear()
}

/// Bridges chat media Now Playing onto the kit's `OpenClawNowPlayingPublishing` (upstream keeps a private
/// MPNowPlayingInfoCenter wrapper here). The default publisher is the extension-safe
/// `MPNowPlayingInfoCenter` one; apps can route through `OpenClawNowPlaying.makeSystemPublisher()`
/// (NowPlaying `MediaSession` on 27) with `OpenClawChatMediaPlayback.setNowPlayingPublisher(_:)`.
@MainActor
final class ChatMediaNowPlayingPublisherAdapter: ChatMediaNowPlayingPublishing {
    static let contentID = "openclaw-chat-media"

    private let publisher: any OpenClawNowPlayingPublishing

    init(publisher: any OpenClawNowPlayingPublishing) {
        self.publisher = publisher
    }

    func publish(_ metadata: ChatMediaNowPlayingMetadata) {
        self.publisher.publish(OpenClawNowPlayingMetadata(
            contentID: Self.contentID,
            title: metadata.title,
            duration: metadata.duration.isFinite && metadata.duration > 0 ? metadata.duration : nil,
            elapsed: metadata.elapsed.isFinite ? max(0, metadata.elapsed) : 0,
            playbackRate: metadata.playbackRate > 0 ? metadata.playbackRate : 1,
            state: metadata.playbackRate > 0 ? .playing : .paused))
    }

    func setRemoteCommandHandler(
        _ handler: (@MainActor @Sendable (ChatMediaRemoteCommand) -> Void)?)
    {
        guard let handler else {
            self.publisher.setCommandHandler(nil)
            return
        }
        self.publisher.setCommandHandler { command in
            switch command {
            case .play:
                handler(.play)
            case .pause, .stop:
                handler(.pause)
            case .togglePlayPause:
                handler(.toggle)
            case .skipForward, .skipBackward:
                break
            }
        }
    }

    func clear() {
        self.publisher.clear()
    }
}

/// Configuration for chat media playback (audio and video attachments).
public enum OpenClawChatMediaPlayback {
    /// Routes chat media Now Playing metadata and remote commands through `publisher`; nil restores the
    /// default extension-safe `MPNowPlayingInfoCenter` publisher. Call it before playback starts, for
    /// example with `OpenClawNowPlaying.makeSystemPublisher()` in an app target.
    @MainActor
    public static func setNowPlayingPublisher(_ publisher: (any OpenClawNowPlayingPublishing)?) {
        ChatMediaPlaybackCoordinator.shared.replaceNowPlayingCenter(ChatMediaNowPlayingPublisherAdapter(
            publisher: publisher ?? OpenClawNowPlaying.makeExtensionSafePublisher()))
    }
}

/// AVAudioSession and audible chat media are process-wide resources. Keeping the
/// active owner here prevents Listen, audio attachments, and videos from talking
/// over one another across separate chat views. This is also the sole Now Playing
/// publisher, so speech/Talk ownership clears attachment metadata instead of
/// competing with it.
@MainActor
final class ChatMediaPlaybackCoordinator {
    static let shared = ChatMediaPlaybackCoordinator()

    private weak var activeOwner: (any ChatMediaPlaybackOwner)?
    private var nowPlayingCenter: any ChatMediaNowPlayingPublishing

    init(nowPlayingCenter: any ChatMediaNowPlayingPublishing = ChatMediaNowPlayingPublisherAdapter(
        publisher: OpenClawNowPlaying.makeExtensionSafePublisher()))
    {
        self.nowPlayingCenter = nowPlayingCenter
    }

    /// Swaps the Now Playing publisher, clearing whatever the previous one showed.
    func replaceNowPlayingCenter(_ center: any ChatMediaNowPlayingPublishing) {
        self.nowPlayingCenter.clear()
        self.nowPlayingCenter = center
        if let owner = self.activeOwner {
            self.configureNowPlaying(for: owner)
        }
    }

    func activate(_ owner: any ChatMediaPlaybackOwner) {
        guard self.activeOwner !== owner else {
            self.updateNowPlaying(owner)
            return
        }
        let previous = self.activeOwner
        // Install the new owner before stopping the old one: its release callback
        // must not clear the replacement that already owns playback.
        self.activeOwner = owner
        previous?.stopForMediaPlaybackInterruption()
        self.configureNowPlaying(for: owner)
    }

    func release(_ owner: any ChatMediaPlaybackOwner) {
        guard self.activeOwner === owner else { return }
        self.activeOwner = nil
        self.nowPlayingCenter.clear()
    }

    func isActive(_ owner: any ChatMediaPlaybackOwner) -> Bool {
        self.activeOwner === owner
    }

    func updateNowPlaying(_ owner: any ChatMediaPlaybackOwner) {
        guard self.activeOwner === owner,
              let owner = owner as? any ChatMediaNowPlayingOwner
        else { return }
        self.nowPlayingCenter.publish(owner.nowPlayingMetadata)
    }

    private func configureNowPlaying(for owner: any ChatMediaPlaybackOwner) {
        guard let owner = owner as? any ChatMediaNowPlayingOwner else {
            self.nowPlayingCenter.clear()
            return
        }
        self.nowPlayingCenter.setRemoteCommandHandler { [weak self, weak owner] command in
            guard let self,
                  let owner,
                  self.activeOwner === owner
            else { return }
            owner.handleRemoteCommand(command)
            self.updateNowPlaying(owner)
        }
        self.nowPlayingCenter.publish(owner.nowPlayingMetadata)
    }
}
