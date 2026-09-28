import Foundation
import OpenClawKit
import Testing
@testable import OpenClawChatUI

@MainActor
private final class BridgeNowPlayingOwner: ChatMediaNowPlayingOwner {
    var nowPlayingMetadata = ChatMediaNowPlayingMetadata(
        title: "voice-note.m4a",
        duration: 42,
        elapsed: 3,
        playbackRate: 1)
    private(set) var commands: [ChatMediaRemoteCommand] = []
    private(set) var interruptions = 0

    func stopForMediaPlaybackInterruption() {
        self.interruptions += 1
    }

    func handleRemoteCommand(_ command: ChatMediaRemoteCommand) {
        self.commands.append(command)
        self.nowPlayingMetadata = ChatMediaNowPlayingMetadata(
            title: "voice-note.m4a",
            duration: 42,
            elapsed: 4,
            playbackRate: command == .pause ? 0 : 1)
    }
}

/// Chat media Now Playing goes through the kit's `OpenClawNowPlayingPublishing` (W3) instead of
/// upstream's private MPNowPlayingInfoCenter wrapper.
@MainActor
@Suite("Chat media Now Playing bridge")
struct ChatMediaNowPlayingBridgeTests {
    @Test func `metadata maps onto kit Now Playing metadata`() {
        let publisher = RecordingNowPlayingPublisher()
        let coordinator = ChatMediaPlaybackCoordinator(
            nowPlayingCenter: ChatMediaNowPlayingPublisherAdapter(publisher: publisher))
        let owner = BridgeNowPlayingOwner()

        coordinator.activate(owner)

        #expect(publisher.calls.contains(.setHandler(installed: true)))
        #expect(publisher.calls.last == .publish(OpenClawNowPlayingMetadata(
            contentID: ChatMediaNowPlayingPublisherAdapter.contentID,
            title: "voice-note.m4a",
            duration: 42,
            elapsed: 3,
            playbackRate: 1,
            state: .playing)))
    }

    @Test func `remote commands reach the active owner and republish`() {
        let publisher = RecordingNowPlayingPublisher()
        let coordinator = ChatMediaPlaybackCoordinator(
            nowPlayingCenter: ChatMediaNowPlayingPublisherAdapter(publisher: publisher))
        let owner = BridgeNowPlayingOwner()
        coordinator.activate(owner)

        publisher.send(.pause)
        publisher.send(.togglePlayPause)
        publisher.send(.play)
        publisher.send(.stop)
        publisher.send(.skipForward(15))

        #expect(owner.commands == [.pause, .toggle, .play, .pause])
        guard case let .publish(metadata)? = publisher.calls.last else {
            Issue.record("expected a republish after the last command")
            return
        }
        #expect(metadata.state == .paused)
        #expect(metadata.elapsed == 4)
    }

    @Test func `release clears the kit publisher and ignores stale owners`() {
        let publisher = RecordingNowPlayingPublisher()
        let coordinator = ChatMediaPlaybackCoordinator(
            nowPlayingCenter: ChatMediaNowPlayingPublisherAdapter(publisher: publisher))
        let first = BridgeNowPlayingOwner()
        let second = BridgeNowPlayingOwner()

        coordinator.activate(first)
        coordinator.activate(second)
        coordinator.release(first)
        #expect(first.interruptions == 1)
        #expect(publisher.calls.last != .clear)

        coordinator.release(second)
        #expect(publisher.calls.last == .clear)
    }

    @Test func `non finite durations publish as live content`() {
        let publisher = RecordingNowPlayingPublisher()
        let adapter = ChatMediaNowPlayingPublisherAdapter(publisher: publisher)

        adapter.publish(ChatMediaNowPlayingMetadata(title: "stream", duration: .nan, elapsed: .infinity, playbackRate: 0))

        #expect(publisher.calls == [.publish(OpenClawNowPlayingMetadata(
            contentID: ChatMediaNowPlayingPublisherAdapter.contentID,
            title: "stream",
            duration: nil,
            elapsed: 0,
            playbackRate: 1,
            state: .paused))])
    }

    @Test func `replacing the publisher clears the old one and re-publishes the active owner`() {
        let old = RecordingNowPlayingPublisher()
        let replacement = RecordingNowPlayingPublisher()
        let coordinator = ChatMediaPlaybackCoordinator(
            nowPlayingCenter: ChatMediaNowPlayingPublisherAdapter(publisher: old))
        let owner = BridgeNowPlayingOwner()
        coordinator.activate(owner)

        coordinator.replaceNowPlayingCenter(ChatMediaNowPlayingPublisherAdapter(publisher: replacement))

        #expect(old.calls.last == .clear)
        #expect(replacement.calls.contains(.setHandler(installed: true)))
        guard case let .publish(metadata)? = replacement.calls.last else {
            Issue.record("expected the active owner to be republished")
            return
        }
        #expect(metadata.title == "voice-note.m4a")
    }
}
