// Ported from upstream OpenClaw 2026.9.6 `OpenClawChatTalkControl.swift`. Plain value types with main-actor
// closures, so ChatUI stays independent of the host's realtime Talk engine.

/// A selectable audio input (microphone) for realtime Talk.
public struct OpenClawChatAudioInputDevice: Equatable, Identifiable, Sendable {
    /// Device identifier passed back to ``OpenClawChatTalkControl/selectInputDevice``.
    public var id: String
    /// Display name.
    public var name: String

    /// Creates an input device.
    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Which camera a Talk session with video uses.
public enum OpenClawCameraFacingSelection: String, Equatable, Sendable {
    /// Rear camera.
    case back
    /// Front (selfie) camera.
    case front
}

/// Host-provided realtime Talk state and actions for the composer's Talk button and activity strip.
public struct OpenClawChatTalkControl {
    /// Whether a Talk session is running.
    public var isEnabled: Bool
    /// Whether Talk is capturing the user's voice.
    public var isListening: Bool
    /// Whether the agent's voice is playing.
    public var isSpeaking: Bool
    /// Whether the gateway connection is up (Talk cannot start without it).
    public var isGatewayConnected: Bool
    /// Short status line ("Listening", "Thinking", …).
    public var statusText: String
    /// Realtime provider label for accessibility.
    public var providerLabel: String
    /// Live audio level in 0...1 driving the waveform.
    public var level: Double
    /// In-progress transcript of the current utterance.
    public var partialTranscript: String
    /// Recent final transcript lines (the strip shows the last 20).
    public var recentTranscript: [String]
    /// Selectable microphones (macOS input menu).
    public var inputDevices: [OpenClawChatAudioInputDevice]
    /// Selected microphone, or `nil` for the system default.
    public var selectedInputDeviceID: String?
    /// Selects a microphone (`nil` = system default); `nil` hides the input menu.
    public var selectInputDevice: (@MainActor (_ deviceID: String?) -> Void)?
    /// Active camera for video Talk, when a camera is in use.
    public var cameraFacing: OpenClawCameraFacingSelection?
    /// Flips the camera; `nil` hides the flip button.
    public var flipCamera: (@MainActor () -> Void)?
    /// Starts or stops Talk for a session key.
    public var toggle: @MainActor (_ sessionKey: String) -> Void

    /// Creates a Talk control.
    public init(
        isEnabled: Bool,
        isListening: Bool,
        isSpeaking: Bool,
        isGatewayConnected: Bool,
        statusText: String,
        providerLabel: String,
        level: Double = 0,
        partialTranscript: String = "",
        recentTranscript: [String] = [],
        inputDevices: [OpenClawChatAudioInputDevice] = [],
        selectedInputDeviceID: String? = nil,
        selectInputDevice: (@MainActor (_ deviceID: String?) -> Void)? = nil,
        cameraFacing: OpenClawCameraFacingSelection? = nil,
        flipCamera: (@MainActor () -> Void)? = nil,
        toggle: @escaping @MainActor (_ sessionKey: String) -> Void)
    {
        self.isEnabled = isEnabled
        self.isListening = isListening
        self.isSpeaking = isSpeaking
        self.isGatewayConnected = isGatewayConnected
        self.statusText = statusText
        self.providerLabel = providerLabel
        self.level = level
        self.partialTranscript = partialTranscript
        self.recentTranscript = recentTranscript
        self.inputDevices = inputDevices
        self.selectedInputDeviceID = selectedInputDeviceID
        self.selectInputDevice = selectInputDevice
        self.cameraFacing = cameraFacing
        self.flipCamera = flipCamera
        self.toggle = toggle
    }
}
