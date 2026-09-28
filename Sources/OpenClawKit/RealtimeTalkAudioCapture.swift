#if canImport(AVFAudio) && (os(iOS) || os(macOS) || os(visionOS))
import AVFAudio
import Foundation
import OSLog
#if os(macOS)
import CoreAudio
#endif

/// Gate that lets a stopped capture drop frames still in flight on Core Audio's queue.
///
/// `stop()` deactivates the gate before removing the tap; a callback already running finishes
/// under the lock, and later callbacks see a stale token and drop their frames.
final class RealtimeTalkAudioDeliveryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var active = true

    func activate() -> UInt64 {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.generation &+= 1
        self.active = true
        return self.generation
    }

    func deactivate() {
        self.lock.lock()
        self.generation &+= 1
        self.active = false
        self.lock.unlock()
    }

    func isActive(_ generation: UInt64) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.active && self.generation == generation
    }

    @discardableResult
    func deliver(ifActive generation: UInt64, _ body: () -> Void) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard self.active, self.generation == generation else { return false }
        body()
        return true
    }
}

/// Builds tap callbacks from a nonisolated context so they never inherit the capture's main-actor
/// isolation (Core Audio calls them on its realtime queue).
enum RealtimeTalkTapHandlerFactory {
    nonisolated static func makeTapBlock(
        targetSampleRate: Double,
        deliveryGate: RealtimeTalkAudioDeliveryGate,
        deliveryToken: UInt64,
        onAudio: @escaping @Sendable (RealtimeTalkAudioFrame) -> Void) -> AVAudioNodeTapBlock
    {
        { buffer, _ in
            guard deliveryGate.isActive(deliveryToken) else { return }
            // The encoder downmixes every input channel to mono before the relay sees it.
            let encoded = RealtimeTalkPCM16Encoder.encode(
                buffer: buffer,
                inputSampleRate: buffer.format.sampleRate,
                targetSampleRate: targetSampleRate)
            guard !encoded.isEmpty else { return }
            let frame = RealtimeTalkAudioFrame(
                data: encoded,
                timestampMs: (ProcessInfo.processInfo.systemUptime * 1000).rounded(),
                rms: Float(TalkAudioLevel.rms(buffer: buffer)))
            deliveryGate.deliver(ifActive: deliveryToken) {
                onAudio(frame)
            }
        }
    }

    #if compiler(>=6.4)
    @available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
    nonisolated static func makeTapProvider(
        targetSampleRate: Double,
        deliveryGate: RealtimeTalkAudioDeliveryGate,
        deliveryToken: UInt64,
        onAudio: @escaping @Sendable (RealtimeTalkAudioFrame) -> Void)
        -> @Sendable (AVReadOnlyAudioPCMBuffer, AVAudioTime) -> Void
    {
        { buffer, _ in
            guard deliveryGate.isActive(deliveryToken) else { return }
            let encoded = RealtimeTalkPCM16Encoder.encode(
                buffer: buffer,
                inputSampleRate: buffer.format.sampleRate,
                targetSampleRate: targetSampleRate)
            guard !encoded.isEmpty else { return }
            let frame = RealtimeTalkAudioFrame(
                data: encoded,
                timestampMs: (ProcessInfo.processInfo.systemUptime * 1000).rounded(),
                rms: Float(TalkAudioLevel.rms(buffer: buffer)))
            deliveryGate.deliver(ifActive: deliveryToken) {
                onAudio(frame)
            }
        }
    }
    #endif
}

/// Errors thrown by ``AVAudioEngineRealtimeTalkAudioCapture``.
public enum RealtimeTalkAudioCaptureError: Error, Equatable, Sendable {
    /// The relay requested a non-finite or non-positive sample rate.
    case invalidTargetSampleRate
    /// No usable input device is available.
    case inputUnavailable
    /// The input device reports no usable format.
    case invalidInputFormat
}

extension RealtimeTalkAudioCaptureError: LocalizedError {
    /// Human-readable description.
    public var errorDescription: String? {
        switch self {
        case .invalidTargetSampleRate:
            "Realtime Talk requested an invalid audio sample rate"
        case .inputUnavailable:
            "No realtime audio input device is available"
        case .invalidInputFormat:
            "Invalid realtime audio input format"
        }
    }
}

/// Default microphone capture for ``RealtimeTalkRelaySession`` built on `AVAudioEngine`.
///
/// Installs a 2048-frame tap on the input node, downmixes to mono, resamples to the relay rate,
/// and restarts after engine configuration changes (route or device changes); a failed restart is
/// reported through `onFailure`. On AVFAudio 27 the tap delivers Sendable
/// `AVReadOnlyAudioPCMBuffer`s. The host configures and activates the audio session on iOS and
/// visionOS (`.playAndRecord`, mode `.voiceChat`).
@MainActor
public final class AVAudioEngineRealtimeTalkAudioCapture: RealtimeTalkAudioCapturing {
    static let bufferSize: AVAudioFrameCount = 2048

    private let logger = Logger(subsystem: "ai.openclaw", category: "talk.realtime.capture")
    private let deliveryGate = RealtimeTalkAudioDeliveryGate()
    private var audioEngine: AVAudioEngine?
    private var tappedInputNode: AVAudioInputNode?
    private var configurationObserver: NSObjectProtocol?
    private var targetSampleRate: Double?
    private var onAudio: (@Sendable (RealtimeTalkAudioFrame) -> Void)?
    private var onFailure: (@MainActor (String) -> Void)?

    /// Creates an idle capture.
    public init() {}

    /// Whether relay output can bleed into the microphone.
    ///
    /// iOS/visionOS: `true` while the route plays through the built-in speaker (headsets keep
    /// full-duplex barge-in). macOS: always `true`, since speaker/mic isolation is unknown.
    public var suppressesInputDuringOutput: Bool {
        #if os(macOS)
        return true
        #else
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        return outputs.contains { $0.portType == .builtInSpeaker }
        #endif
    }

    /// Starts capture; see ``RealtimeTalkAudioCapturing/start(targetSampleRate:onAudio:onFailure:)``.
    public func start(
        targetSampleRate: Double,
        onAudio: @escaping @Sendable (RealtimeTalkAudioFrame) -> Void,
        onFailure: @escaping @MainActor (String) -> Void) throws
    {
        guard targetSampleRate.isFinite, targetSampleRate > 0 else {
            throw RealtimeTalkAudioCaptureError.invalidTargetSampleRate
        }
        self.stop()
        self.targetSampleRate = targetSampleRate
        self.onAudio = onAudio
        self.onFailure = onFailure
        do {
            try self.startEngine(targetSampleRate: targetSampleRate, onAudio: onAudio)
        } catch {
            self.stop()
            throw error
        }
    }

    /// Stops capture; frames still in flight are dropped.
    public func stop() {
        // Close delivery before removing the tap so late Core Audio callbacks drop their frames.
        self.deliveryGate.deactivate()
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        self.configurationObserver = nil
        self.teardownEngine()
        self.targetSampleRate = nil
        self.onAudio = nil
        self.onFailure = nil
    }

    private func startEngine(
        targetSampleRate: Double,
        onAudio: @escaping @Sendable (RealtimeTalkAudioFrame) -> Void) throws
    {
        #if os(macOS)
        // AVAudioEngine materializes inputNode from the system default device; without one,
        // touching inputNode can abort the process.
        guard Self.hasDefaultInputDevice() else { throw RealtimeTalkAudioCaptureError.inputUnavailable }
        #endif
        let engine = AVAudioEngine()
        let input = engine.inputNode
        #if os(macOS)
        let format = input.outputFormat(forBus: 0)
        #else
        let format = input.inputFormat(forBus: 0)
        #endif
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw RealtimeTalkAudioCaptureError.invalidInputFormat
        }
        let deliveryToken = self.deliveryGate.activate()
        try Self.installTap(
            on: input,
            format: format,
            targetSampleRate: targetSampleRate,
            deliveryGate: self.deliveryGate,
            deliveryToken: deliveryToken,
            onAudio: onAudio)
        self.audioEngine = engine
        self.tappedInputNode = input
        self.observeConfigurationChanges(of: engine)
        engine.prepare()
        try engine.start()
    }

    private static func installTap(
        on input: AVAudioInputNode,
        format: AVAudioFormat,
        targetSampleRate: Double,
        deliveryGate: RealtimeTalkAudioDeliveryGate,
        deliveryToken: UInt64,
        onAudio: @escaping @Sendable (RealtimeTalkAudioFrame) -> Void) throws
    {
        #if compiler(>=6.4)
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
            try input.installAudioTap(
                onBus: 0,
                bufferSize: Self.bufferSize,
                format: format,
                tapProvider: RealtimeTalkTapHandlerFactory.makeTapProvider(
                    targetSampleRate: targetSampleRate,
                    deliveryGate: deliveryGate,
                    deliveryToken: deliveryToken,
                    onAudio: onAudio))
            return
        }
        #endif
        input.installTap(
            onBus: 0,
            bufferSize: Self.bufferSize,
            format: format,
            block: RealtimeTalkTapHandlerFactory.makeTapBlock(
                targetSampleRate: targetSampleRate,
                deliveryGate: deliveryGate,
                deliveryToken: deliveryToken,
                onAudio: onAudio))
    }

    private func observeConfigurationChanges(of engine: AVAudioEngine) {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        self.configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main)
        { [weak self] _ in
            MainActor.assumeIsolated {
                self?.restartAfterConfigurationChange()
            }
        }
    }

    private func restartAfterConfigurationChange() {
        guard let targetSampleRate, let onAudio else { return }
        self.logger.info("realtime capture engine configuration changed; restarting")
        self.deliveryGate.deactivate()
        self.teardownEngine()
        do {
            try self.startEngine(targetSampleRate: targetSampleRate, onAudio: onAudio)
        } catch {
            self.logger.error("realtime capture restart failed: \(error.localizedDescription, privacy: .public)")
            let onFailure = self.onFailure
            self.stop()
            onFailure?(String(
                format: String(
                    localized: "Realtime microphone became unavailable: %@",
                    bundle: OpenClawKitResources.bundle),
                error.localizedDescription))
        }
    }

    private func teardownEngine() {
        // Reading inputNode creates the I/O unit even when capture never started, so only
        // remove a tap that was actually installed.
        self.tappedInputNode?.removeTap(onBus: 0)
        self.tappedInputNode = nil
        self.audioEngine?.stop()
        self.audioEngine = nil
    }

    #if os(macOS)
    private static func hasDefaultInputDevice() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID)
        return status == noErr && deviceID != 0
    }
    #endif
}
#endif
