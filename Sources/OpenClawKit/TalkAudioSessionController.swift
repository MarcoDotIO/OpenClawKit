import Foundation
#if canImport(AVFAudio) && !os(macOS)
import AVFAudio
#endif

/// Audio-session lifecycle events relevant to Talk.
public enum TalkAudioSessionEvent: Equatable, Sendable {
    /// The session became active.
    case activated
    /// The app deactivated the session.
    case deactivated
    /// A system interruption (call, alarm, another app) deactivated the session.
    case interrupted
    /// The system recommended whether to resume after an interruption ended.
    case resumptionRecommended(shouldResume: Bool)
}

/// Activates and deactivates the audio session for Talk (injectable for tests).
@MainActor
public protocol TalkAudioSessionControlling: AnyObject {
    /// Activates the session.
    func activate() async throws
    /// Deactivates the session, notifying other apps that they may resume.
    func deactivate() async throws
}

/// Talk mode audio-session lifecycle: activation, interruption, and resumption.
///
/// On iOS, tvOS, watchOS, and visionOS 27 activation uses the async
/// `AVAudioSession.activate(options:)` / `deactivate(options:)` APIs and interruptions arrive as
/// typed `didBecomeInactive` / `resumptionRecommendation` messages; earlier systems use
/// `setActive(_:)` and the string-keyed interruption notification. macOS has no audio session:
/// activation is a no-op there and events come only from ``handle(_:)``.
///
/// A system interruption stops ``speech`` (publishing an `interrupted` Now Playing state) and
/// reports the state label `interrupted`; a `shouldResume` recommendation calls ``onResume`` so
/// the host can resume push-to-talk listening.
@MainActor
public final class TalkAudioSessionController {
    /// Speech output stopped on interruption.
    public var speech: (any TalkSystemSpeaking)?
    /// Called for every audio-session event.
    public var onEvent: (@MainActor (TalkAudioSessionEvent) -> Void)?
    /// Called when the system recommends resuming after an interruption.
    public var onResume: (@MainActor () -> Void)?
    /// Called when the state label changes (`active`, `interrupted`, or `nil` when inactive).
    public var onStateLabelChange: (@MainActor (String?) -> Void)?
    /// Current state label: `active`, `interrupted`, or `nil`.
    public private(set) var stateLabel: String?

    private let session: any TalkAudioSessionControlling
    private let observers = TalkAudioSessionObserverBag()

    /// Creates a controller.
    /// - Parameters:
    ///   - session: Session control; defaults to the shared `AVAudioSession` (a no-op on macOS).
    ///   - observeSystemEvents: Whether to observe system interruption and resumption events.
    public init(session: (any TalkAudioSessionControlling)? = nil, observeSystemEvents: Bool = true) {
        self.session = session ?? Self.makeSystemSession()
        if observeSystemEvents {
            self.startObservingSystemEvents()
        }
    }

    /// Stops observing system audio-session events (also happens when the controller is released).
    public func invalidate() {
        self.observers.removeAll()
    }

    /// Activates the audio session and reports ``TalkAudioSessionEvent/activated``.
    public func activate() async throws {
        try await self.session.activate()
        self.handle(.activated)
    }

    /// Deactivates the audio session and reports ``TalkAudioSessionEvent/deactivated``.
    public func deactivate() async throws {
        try await self.session.deactivate()
        self.handle(.deactivated)
    }

    /// Applies one audio-session event (system observers call this; tests and hosts may too).
    public func handle(_ event: TalkAudioSessionEvent) {
        switch event {
        case .activated:
            self.setStateLabel("active")
        case .deactivated:
            self.setStateLabel(nil)
        case .interrupted:
            self.speech?.interruptForAudioSession()
            self.setStateLabel("interrupted")
        case let .resumptionRecommended(shouldResume):
            if shouldResume {
                self.setStateLabel("active")
                self.onResume?()
            }
        }
        self.onEvent?(event)
    }

    private func setStateLabel(_ label: String?) {
        guard self.stateLabel != label else { return }
        self.stateLabel = label
        self.onStateLabelChange?(label)
    }

    private static func makeSystemSession() -> any TalkAudioSessionControlling {
        #if canImport(AVFAudio) && !os(macOS)
        return SystemTalkAudioSession()
        #else
        return NoopTalkAudioSession()
        #endif
    }

    private func startObservingSystemEvents() {
        #if canImport(AVFAudio) && !os(macOS)
        #if compiler(>=6.4)
        if #available(iOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *) {
            self.observeTypedSessionMessages()
            return
        }
        #endif
        self.observeLegacyInterruptions()
        #endif
    }

    #if canImport(AVFAudio) && !os(macOS)
    #if compiler(>=6.4)
    @available(iOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
    private func observeTypedSessionMessages() {
        let center = NotificationCenter.default
        let audioSession = AVAudioSession.sharedInstance()
        self.observers.add(token: center.addObserver(of: audioSession, for: .didBecomeInactive) { [weak self] message in
            switch message.deactivationResult {
            case .systemInterruption:
                self?.handle(.interrupted)
            case .appDeactivated:
                self?.handle(.deactivated)
            @unknown default:
                break
            }
        })
        self.observers.add(token: center.addObserver(of: audioSession, for: .resumptionRecommendation) { [weak self] message in
            self?.handle(.resumptionRecommended(shouldResume: message.recommendation == .shouldResume))
        })
    }
    #endif

    private func observeLegacyInterruptions() {
        let observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main)
        { [weak self] notification in
            let info = notification.userInfo
            let rawType = (info?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
            let rawOptions = (info?[AVAudioSessionInterruptionOptionKey] as? NSNumber)?.uintValue ?? 0
            MainActor.assumeIsolated {
                switch rawType.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) {
                case .began:
                    self?.handle(.interrupted)
                case .ended:
                    let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
                    self?.handle(.resumptionRecommended(shouldResume: options.contains(.shouldResume)))
                case .none:
                    break
                @unknown default:
                    break
                }
            }
        }
        self.observers.add(legacy: observer)
    }
    #endif
}

extension TalkSystemSpeaking {
    /// Stops speech for a system audio interruption; the default implementation calls ``stop()``.
    public func interruptForAudioSession() {
        self.stop()
    }
}

/// Owns notification observers and removes them when released (NotificationCenter is thread-safe).
final class TalkAudioSessionObserverBag: @unchecked Sendable {
    private let lock = NSLock()
    private var legacy: [any NSObjectProtocol] = []
    private var tokens: [Any] = []

    func add(legacy observer: any NSObjectProtocol) {
        self.lock.withLock { self.legacy.append(observer) }
    }

    func add(token: Any) {
        self.lock.withLock { self.tokens.append(token) }
    }

    func removeAll() {
        let (legacy, tokens) = self.lock.withLock {
            defer {
                self.legacy.removeAll()
                self.tokens.removeAll()
            }
            return (self.legacy, self.tokens)
        }
        let center = NotificationCenter.default
        legacy.forEach { center.removeObserver($0) }
        #if compiler(>=6.4)
        if #available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *) {
            for case let token as NotificationCenter.ObservationToken in tokens {
                center.removeObserver(token)
            }
        }
        #endif
    }

    deinit {
        self.removeAll()
    }
}

@MainActor
final class NoopTalkAudioSession: TalkAudioSessionControlling {
    func activate() async throws {}
    func deactivate() async throws {}
}

#if canImport(AVFAudio) && !os(macOS)
/// `AVAudioSession`-backed Talk session control.
@MainActor
final class SystemTalkAudioSession: TalkAudioSessionControlling {
    func activate() async throws {
        let session = AVAudioSession.sharedInstance()
        #if compiler(>=6.4)
        if #available(iOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *) {
            guard try await session.activate(options: []) else {
                throw NSError(domain: "TalkAudioSession", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "The audio session was not activated",
                ])
            }
            return
        }
        #endif
        try session.setActive(true)
    }

    func deactivate() async throws {
        let session = AVAudioSession.sharedInstance()
        #if compiler(>=6.4)
        if #available(iOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *) {
            _ = try await session.deactivate(options: [.notifyOthersOnDeactivation])
            return
        }
        #endif
        try session.setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
#endif

#if canImport(AVFAudio) && (os(iOS) || os(macOS) || os(visionOS))
extension RealtimeTalkRelaySession {
    /// Applies an audio-session event: interruptions pause microphone input (the relay stays open)
    /// and a `shouldResume` recommendation resumes it.
    /// - Parameter event: Event from ``TalkAudioSessionController``.
    public func applyAudioSessionEvent(_ event: TalkAudioSessionEvent) {
        switch event {
        case .interrupted:
            try? self.setInputPaused(true)
        case .resumptionRecommended(shouldResume: true):
            try? self.setInputPaused(false)
        case .activated, .deactivated, .resumptionRecommended:
            break
        }
    }
}
#endif
