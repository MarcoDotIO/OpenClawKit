import Foundation

/// Node command that mirrors the Anthropic `computer_20251124` action set. One
/// action per invoke; pointer coordinates are in reference-screenshot pixels
/// (the `screen.snapshot` frame captured at `maxWidth == refWidth`), which the
/// fulfilling node maps back to display points.
public enum OpenClawComputerCommand: String, Codable, Sendable {
    /// `computer.act`.
    case act = "computer.act"
}

/// Discriminates the requested computer action. The macOS node maps each case
/// onto the embedded Peekaboo automation engine plus a narrow CoreGraphics
/// path for primitives Peekaboo does not express (middle/triple click,
/// separate mouse down/up, modifier-held clicks/scroll).
public enum OpenClawComputerAction: String, Codable, CaseIterable, Sendable {
    /// Capture a reference screenshot.
    case screenshot
    /// Left click at `x`/`y`.
    case leftClick = "left_click"
    /// Right click at `x`/`y`.
    case rightClick = "right_click"
    /// Middle click at `x`/`y`.
    case middleClick = "middle_click"
    /// Double click at `x`/`y`.
    case doubleClick = "double_click"
    /// Triple click at `x`/`y`.
    case tripleClick = "triple_click"
    /// Move the pointer to `x`/`y`.
    case mouseMove = "mouse_move"
    /// Drag from `fromX`/`fromY` to `x`/`y`.
    case leftClickDrag = "left_click_drag"
    /// Press the left button without releasing it.
    case leftMouseDown = "left_mouse_down"
    /// Release the left button.
    case leftMouseUp = "left_mouse_up"
    /// Scroll by `scrollAmount` ticks in `scrollDirection`.
    case scroll
    /// Type `text`.
    case type
    /// Press the `keys` chord.
    case key
    /// Hold the `keys` chord for `durationMs`.
    case holdKey = "hold_key"
    /// Wait (agent-side only; rejected on the native wire).
    case wait
    /// List running apps.
    case listApps = "list_apps"
    /// List windows.
    case listWindows = "list_windows"
    /// Read the accessibility tree of `windowRef`.
    case getAccessibilityTree = "get_accessibility_tree"
    /// Read the pointer position.
    case getCursorPosition = "get_cursor_position"
    /// Read the state (and optionally a screenshot) of `windowRef`.
    case getWindowState = "get_window_state"
    /// Launch `app`.
    case launchApp = "launch_app"
    /// Quit `app`.
    case killApp = "kill_app"
    /// Bring `app` or `windowRef` to the front.
    case bringToFront = "bring_to_front"
    /// Set `value` on `elementRef`.
    case setValue = "set_value"
    /// Zoom a screenshot region (agent-side only).
    case zoom
    /// Browser state (browser tool only).
    case getBrowserState = "get_browser_state"
    /// Browser preparation (browser tool only).
    case browserPrepare = "browser_prepare"
    /// Browser navigation (browser tool only).
    case browserNavigate = "browser_navigate"
    /// Browser click (browser tool only).
    case browserClick = "browser_click"
    /// Browser typing (browser tool only).
    case browserType = "browser_type"
    /// Browser dialog handling (browser tool only).
    case browserDialog = "browser_dialog"
    /// Browser file input (browser tool only).
    case browserSetInputFiles = "browser_set_input_files"
    /// Browser download (browser tool only).
    case browserDownload = "browser_download"
    /// Browser pointer action (browser tool only).
    case browserPointer = "browser_pointer"
    /// Scope escalation (agent-side only).
    case escalateScope = "escalate_scope"
    /// Recording state (agent-side only).
    case getRecordingState = "get_recording_state"
    /// Start a trajectory recording (agent-side only).
    case startRecording = "start_recording"
    /// Stop a trajectory recording (agent-side only).
    case stopRecording = "stop_recording"
    /// Replay a trajectory (agent-side only).
    case replayTrajectory = "replay_trajectory"
    /// Invoke the menu item at `path` in `app`.
    case invokeMenu = "invoke_menu"

    private var isNativeWireAction: Bool {
        switch self {
        case .wait, .zoom, .getBrowserState, .browserPrepare, .browserNavigate,
             .browserClick, .browserType, .browserDialog, .browserSetInputFiles,
             .browserDownload, .browserPointer, .escalateScope, .getRecordingState,
             .startRecording, .stopRecording, .replayTrajectory:
            false
        default:
            true
        }
    }

    /// Decodes a raw action, rejecting actions the native node never fulfills.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let action = Self(rawValue: rawValue), action.isNativeWireAction else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported native computer action: \(rawValue)")
        }
        self = action
    }

    /// Encodes the raw action name.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.rawValue)
    }
}

/// Scroll direction for `scroll` actions.
public enum OpenClawComputerScrollDirection: String, Codable, Sendable {
    /// Scroll up.
    case up
    /// Scroll down.
    case down
    /// Scroll left.
    case left
    /// Scroll right.
    case right
}

/// How input is delivered to the target window.
public enum OpenClawComputerDeliveryMode: String, Codable, Sendable {
    /// Deliver input without activating the target.
    case background
    /// Activate the target before delivering input.
    case foreground
}

/// Reason code for recommending a scope escalation.
public enum OpenClawComputerEscalationReason: String, Codable, Sendable {
    /// Accessibility tree and pixels disagree.
    case axTreePixelMismatch = "ax_tree_pixel_mismatch"
    /// Background delivery failed.
    case backgroundDeliveryFailed = "background_delivery_failed"
    /// Foreground delivery had no effect.
    case foregroundIneffective = "foreground_ineffective"
    /// No window target was available.
    case noWindowTarget = "no_window_target"
    /// Other reason.
    case other
}

/// Wire params for `computer.act`. All coordinate fields are reference-screenshot
/// pixels at `refWidth`; `keys` is a chord for key/hold_key; `modifiers` are
/// modifier keys held during pointer actions; `scrollAmount` is wheel ticks.
public struct OpenClawComputerActParams: Codable, Sendable, Equatable {
    /// Requested action.
    public var action: OpenClawComputerAction
    /// Opaque identity returned with the screenshot that supplied coordinates.
    public var displayFrameId: String?
    /// Target x in reference-screenshot pixels.
    public var x: Double?
    /// Target y in reference-screenshot pixels.
    public var y: Double?
    /// Drag start x in reference-screenshot pixels.
    public var fromX: Double?
    /// Drag start y in reference-screenshot pixels.
    public var fromY: Double?
    /// Text to type.
    public var text: String?
    /// Key chord such as `cmd+return`.
    public var keys: String?
    /// Modifier keys held during pointer actions.
    public var modifiers: String?
    /// Scroll direction.
    public var scrollDirection: OpenClawComputerScrollDirection?
    /// Scroll amount in wheel ticks.
    public var scrollAmount: Int?
    /// Duration for hold/wait actions, in milliseconds.
    public var durationMs: Int?
    /// Target display index.
    public var screenIndex: Int?
    /// Reference screenshot width the coordinates were taken at.
    public var refWidth: Int?
    /// Opaque window reference from a previous observation.
    public var windowRef: String?
    /// Opaque accessibility element reference.
    public var elementRef: String?
    /// Observation the references belong to.
    public var observationId: String?
    /// Background or foreground input delivery.
    public var deliveryMode: OpenClawComputerDeliveryMode?
    /// Accessibility tree search query.
    public var query: String?
    /// Maximum accessibility tree depth.
    public var depth: Int?
    /// Maximum accessibility elements to return.
    public var maxElements: Int?
    /// Whether window state includes a screenshot.
    public var includeScreenshot: Bool?
    /// Target application name or reference.
    public var app: String?
    /// Value for `set_value`.
    public var value: String?
    /// Menu path for `invoke_menu`.
    public var path: [String]?
    /// Region left edge (zoom).
    public var x1: Double?
    /// Region top edge (zoom).
    public var y1: Double?
    /// Region right edge (zoom).
    public var x2: Double?
    /// Region bottom edge (zoom).
    public var y2: Double?
    /// Escalation reason.
    public var reason: OpenClawComputerEscalationReason?

    /// Creates a value with the given fields.
    public init(
        action: OpenClawComputerAction,
        displayFrameId: String? = nil,
        x: Double? = nil,
        y: Double? = nil,
        fromX: Double? = nil,
        fromY: Double? = nil,
        text: String? = nil,
        keys: String? = nil,
        modifiers: String? = nil,
        scrollDirection: OpenClawComputerScrollDirection? = nil,
        scrollAmount: Int? = nil,
        durationMs: Int? = nil,
        screenIndex: Int? = nil,
        refWidth: Int? = nil,
        windowRef: String? = nil,
        elementRef: String? = nil,
        observationId: String? = nil,
        deliveryMode: OpenClawComputerDeliveryMode? = nil,
        query: String? = nil,
        depth: Int? = nil,
        maxElements: Int? = nil,
        includeScreenshot: Bool? = nil,
        app: String? = nil,
        value: String? = nil,
        path: [String]? = nil,
        x1: Double? = nil,
        y1: Double? = nil,
        x2: Double? = nil,
        y2: Double? = nil,
        reason: OpenClawComputerEscalationReason? = nil)
    {
        self.action = action
        self.displayFrameId = displayFrameId
        self.x = x
        self.y = y
        self.fromX = fromX
        self.fromY = fromY
        self.text = text
        self.keys = keys
        self.modifiers = modifiers
        self.scrollDirection = scrollDirection
        self.scrollAmount = scrollAmount
        self.durationMs = durationMs
        self.screenIndex = screenIndex
        self.refWidth = refWidth
        self.windowRef = windowRef
        self.elementRef = elementRef
        self.observationId = observationId
        self.deliveryMode = deliveryMode
        self.query = query
        self.depth = depth
        self.maxElements = maxElements
        self.includeScreenshot = includeScreenshot
        self.app = app
        self.value = value
        self.path = path
        self.x1 = x1
        self.y1 = y1
        self.x2 = x2
        self.y2 = y2
        self.reason = reason
    }
}

/// Verified effect of a computer action.
public enum OpenClawComputerActionEffect: String, Codable, Sendable {
    /// The effect was verified.
    case confirmed
    /// The effect could not be verified.
    case unverifiable
    /// The action appears to have had no effect.
    case suspectedNoop = "suspected_noop"
}

/// Rectangle in global display points.
public struct OpenClawComputerBounds: Codable, Sendable, Equatable {
    /// Left edge in points.
    public var x: Double
    /// Top edge in points.
    public var y: Double
    /// Width in points.
    public var width: Double
    /// Height in points.
    public var height: Double

    /// Creates a value with the given fields.
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// One accessibility element in an observation.
public struct OpenClawComputerObservationElement: Codable, Sendable, Equatable {
    /// Opaque element reference.
    public var elementRef: String
    /// Accessibility role.
    public var role: String
    /// Accessibility label.
    public var label: String?
    /// Current value.
    public var value: String?
    /// Element bounds.
    public var bounds: OpenClawComputerBounds

    /// Creates a value with the given fields.
    public init(
        elementRef: String,
        role: String,
        label: String? = nil,
        value: String? = nil,
        bounds: OpenClawComputerBounds)
    {
        self.elementRef = elementRef
        self.role = role
        self.label = label
        self.value = value
        self.bounds = bounds
    }
}

/// Observation (screenshot or accessibility snapshot) returned by an action.
public struct OpenClawComputerObservation: Codable, Sendable, Equatable {
    /// Observation kind (for example `screenshot` or `accessibility_tree`).
    public var kind: String
    /// Base64 image payload.
    public var base64: String?
    /// Image format.
    public var format: String?
    /// Image width in pixels.
    public var width: Int?
    /// Image height in pixels.
    public var height: Int?
    /// Observation identifier for later references.
    public var observationId: String?
    /// Accessibility elements.
    public var elements: [OpenClawComputerObservationElement]?

    /// Creates a value with the given fields.
    public init(
        kind: String,
        base64: String? = nil,
        format: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        observationId: String? = nil,
        elements: [OpenClawComputerObservationElement]? = nil)
    {
        self.kind = kind
        self.base64 = base64
        self.format = format
        self.width = width
        self.height = height
        self.observationId = observationId
        self.elements = elements
    }
}

/// Recommendation to escalate to a different delivery mode or scope.
public struct OpenClawComputerEscalation: Codable, Sendable, Equatable {
    /// Recommended next mode.
    public var recommended: String
    /// Machine-readable reason code.
    public var reasonCode: String

    /// Creates a value with the given fields.
    public init(recommended: String, reasonCode: String) {
        self.recommended = recommended
        self.reasonCode = reasonCode
    }
}

/// Canonical result of a `computer.act` action.
public struct OpenClawComputerActResult: Codable, Sendable, Equatable {
    /// Whether the action succeeded.
    public var ok: Bool
    /// Verified effect of the action.
    public var effect: OpenClawComputerActionEffect?
    /// Observation captured by the action.
    public var observation: OpenClawComputerObservation?
    /// Escalation recommendation.
    public var escalation: OpenClawComputerEscalation?
    /// Additional structured details.
    public var details: [String: AnyCodable]?

    /// Creates a value with the given fields.
    public init(
        ok: Bool,
        effect: OpenClawComputerActionEffect? = nil,
        observation: OpenClawComputerObservation? = nil,
        escalation: OpenClawComputerEscalation? = nil,
        details: [String: AnyCodable]? = nil)
    {
        self.ok = ok
        self.effect = effect
        self.observation = observation
        self.escalation = escalation
        self.details = details
    }
}
