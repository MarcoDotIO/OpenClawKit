import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(Contacts)
import Contacts
#endif
#if canImport(CoreLocation)
import CoreLocation
#endif
#if canImport(EventKit)
import EventKit
#endif
#if canImport(Photos)
import Photos
#endif
// Speech ships on tvOS, but SFSpeechRecognizer is unavailable there.
#if canImport(Speech) && !os(tvOS)
import Speech
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Authorization state of one privacy-protected capability.
public enum OpenClawPermissionState: String, Sendable, Codable, CaseIterable {
    /// The user has not been asked yet.
    case notDetermined
    /// The user denied access.
    case denied
    /// Access is restricted (parental controls, MDM).
    case restricted
    /// Access is granted.
    case authorized
    /// Access is granted with limits (limited photos/contacts, write-only calendar,
    /// when-in-use location, provisional notifications).
    case limited
    /// The capability does not exist on this platform or build.
    case unavailable

    /// Whether the capability can be used (fully or with limits).
    public var isUsable: Bool {
        self == .authorized || self == .limited
    }
}

/// Capabilities covered by ``OpenClawPermissionsSnapshot``.
public enum OpenClawPermissionKind: String, Sendable, Codable, CaseIterable {
    /// Contacts.
    case contacts
    /// Calendar events.
    case calendar
    /// Reminders.
    case reminders
    /// Photo library.
    case photos
    /// Camera.
    case camera
    /// Microphone.
    case microphone
    /// Speech recognition.
    case speechRecognition
    /// Location.
    case location
    /// Notifications.
    case notifications
}

/// Read-only summary of the app's privacy permissions (a "Privacy & Access" settings screen).
///
/// ``current(_:location:)`` reads each framework's status API without prompting. Node commands can
/// report ``permissionsMap`` in connect/pairing requests and fail fast with stable errors when a
/// capability is not usable.
///
/// Prompting guidance (upstream iOS 2026.5–2026.6): request Contacts, Calendar and Reminders on
/// first use; request notification authorization only from the host's Settings screen; and defer
/// local-network access (Bonjour/NWBrowser discovery) until onboarding finished or the user opened
/// gateway setup (see ``OpenClawLocalNetworkAccessGate``). The SDK never triggers any of these prompts
/// at initialization.
public struct OpenClawPermissionsSnapshot: Sendable, Equatable, Codable {
    /// Contacts.
    public var contacts: OpenClawPermissionState
    /// Calendar events.
    public var calendar: OpenClawPermissionState
    /// Reminders.
    public var reminders: OpenClawPermissionState
    /// Photo library.
    public var photos: OpenClawPermissionState
    /// Camera.
    public var camera: OpenClawPermissionState
    /// Microphone.
    public var microphone: OpenClawPermissionState
    /// Speech recognition.
    public var speechRecognition: OpenClawPermissionState
    /// Location.
    public var location: OpenClawPermissionState
    /// Notifications.
    public var notifications: OpenClawPermissionState

    /// Creates a snapshot (unspecified capabilities default to ``OpenClawPermissionState/unavailable``).
    public init(
        contacts: OpenClawPermissionState = .unavailable,
        calendar: OpenClawPermissionState = .unavailable,
        reminders: OpenClawPermissionState = .unavailable,
        photos: OpenClawPermissionState = .unavailable,
        camera: OpenClawPermissionState = .unavailable,
        microphone: OpenClawPermissionState = .unavailable,
        speechRecognition: OpenClawPermissionState = .unavailable,
        location: OpenClawPermissionState = .unavailable,
        notifications: OpenClawPermissionState = .unavailable)
    {
        self.contacts = contacts
        self.calendar = calendar
        self.reminders = reminders
        self.photos = photos
        self.camera = camera
        self.microphone = microphone
        self.speechRecognition = speechRecognition
        self.location = location
        self.notifications = notifications
    }

    /// State of one capability.
    /// - Parameter kind: Capability.
    public subscript(kind: OpenClawPermissionKind) -> OpenClawPermissionState {
        get {
            switch kind {
            case .contacts: return self.contacts
            case .calendar: return self.calendar
            case .reminders: return self.reminders
            case .photos: return self.photos
            case .camera: return self.camera
            case .microphone: return self.microphone
            case .speechRecognition: return self.speechRecognition
            case .location: return self.location
            case .notifications: return self.notifications
            }
        }
        set {
            switch kind {
            case .contacts: self.contacts = newValue
            case .calendar: self.calendar = newValue
            case .reminders: self.reminders = newValue
            case .photos: self.photos = newValue
            case .camera: self.camera = newValue
            case .microphone: self.microphone = newValue
            case .speechRecognition: self.speechRecognition = newValue
            case .location: self.location = newValue
            case .notifications: self.notifications = newValue
            }
        }
    }

    /// Usable-or-not map for connect `permissions` (`GatewayConnectOptions.permissions`); capabilities
    /// that are unavailable on this platform are omitted.
    public var permissionsMap: [String: Bool] {
        var map: [String: Bool] = [:]
        for kind in OpenClawPermissionKind.allCases where self[kind] != .unavailable {
            map[kind.rawValue] = self[kind].isUsable
        }
        return map
    }

    /// Reads the current permission states without prompting.
    ///
    /// Location is read off the calling actor (constructing `CLLocationManager` can block); pass a
    /// cached `location` value from the host's location delegate to skip that read. Notifications
    /// are only read inside an app bundle (the notification center traps in bare processes).
    /// - Parameters:
    ///   - kinds: Capabilities to read; others are reported as unavailable.
    ///   - location: Optional cached location state.
    /// - Returns: Snapshot.
    public static func current(
        _ kinds: Set<OpenClawPermissionKind> = Set(OpenClawPermissionKind.allCases),
        location: OpenClawPermissionState? = nil) async -> OpenClawPermissionsSnapshot
    {
        var snapshot = OpenClawPermissionsSnapshot()
        for kind in kinds where kind != .location && kind != .notifications {
            snapshot[kind] = Self.readStatus(kind)
        }
        if kinds.contains(.location) {
            if let location {
                snapshot.location = location
            } else {
                snapshot.location = await Task.detached(priority: .utility) {
                    Self.readLocationStatus()
                }.value
            }
        }
        if kinds.contains(.notifications) {
            snapshot.notifications = await Self.readNotificationStatus()
        }
        return snapshot
    }

    static func readStatus(_ kind: OpenClawPermissionKind) -> OpenClawPermissionState {
        switch kind {
        case .contacts:
            #if canImport(Contacts) && !os(tvOS)
            return Self.map(contacts: CNContactStore.authorizationStatus(for: .contacts))
            #else
            return .unavailable
            #endif
        case .calendar:
            #if canImport(EventKit) && !os(tvOS)
            return Self.map(eventKit: EKEventStore.authorizationStatus(for: .event))
            #else
            return .unavailable
            #endif
        case .reminders:
            #if canImport(EventKit) && !os(tvOS)
            return Self.map(eventKit: EKEventStore.authorizationStatus(for: .reminder))
            #else
            return .unavailable
            #endif
        case .photos:
            #if canImport(Photos) && !os(watchOS)
            return Self.map(photos: PHPhotoLibrary.authorizationStatus(for: .readWrite))
            #else
            return .unavailable
            #endif
        case .camera:
            #if canImport(AVFoundation) && !os(watchOS) && !os(tvOS)
            return Self.map(capture: AVCaptureDevice.authorizationStatus(for: .video))
            #else
            return .unavailable
            #endif
        case .microphone:
            #if canImport(AVFoundation) && !os(tvOS)
            return Self.map(record: AVAudioApplication.shared.recordPermission)
            #else
            return .unavailable
            #endif
        case .speechRecognition:
            #if canImport(Speech) && !os(tvOS)
            return Self.map(speech: SFSpeechRecognizer.authorizationStatus())
            #else
            return .unavailable
            #endif
        case .location:
            return Self.readLocationStatus()
        case .notifications:
            return .unavailable
        }
    }

    static func readLocationStatus() -> OpenClawPermissionState {
        #if canImport(CoreLocation)
        return Self.map(location: CLLocationManager().authorizationStatus)
        #else
        return .unavailable
        #endif
    }

    static func readNotificationStatus() async -> OpenClawPermissionState {
        #if canImport(UserNotifications)
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else {
            return .unavailable
        }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return Self.map(notifications: settings.authorizationStatus)
        #else
        return .unavailable
        #endif
    }

    #if canImport(Contacts) && !os(tvOS)
    static func map(contacts status: CNAuthorizationStatus) -> OpenClawPermissionState {
        switch status {
        case .authorized: return .authorized
        case .limited: return .limited
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }
    #endif

    #if canImport(EventKit) && !os(tvOS)
    static func map(eventKit status: EKAuthorizationStatus) -> OpenClawPermissionState {
        switch status {
        case .fullAccess, .authorized: return .authorized
        case .writeOnly: return .limited
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }
    #endif

    #if canImport(Photos) && !os(watchOS)
    static func map(photos status: PHAuthorizationStatus) -> OpenClawPermissionState {
        switch status {
        case .authorized: return .authorized
        case .limited: return .limited
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }
    #endif

    #if canImport(AVFoundation) && !os(watchOS) && !os(tvOS)
    static func map(capture status: AVAuthorizationStatus) -> OpenClawPermissionState {
        switch status {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }
    #endif

    #if canImport(AVFoundation) && !os(tvOS)
    static func map(record permission: AVAudioApplication.recordPermission) -> OpenClawPermissionState {
        switch permission {
        case .granted: return .authorized
        case .denied: return .denied
        case .undetermined: return .notDetermined
        @unknown default: return .denied
        }
    }
    #endif

    #if canImport(Speech) && !os(tvOS)
    static func map(speech status: SFSpeechRecognizerAuthorizationStatus) -> OpenClawPermissionState {
        switch status {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }
    #endif

    #if canImport(CoreLocation)
    static func map(location status: CLAuthorizationStatus) -> OpenClawPermissionState {
        switch status {
        case .authorizedAlways: return .authorized
        case .authorizedWhenInUse: return .limited
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }
    #endif

    #if canImport(UserNotifications)
    static func map(notifications status: UNAuthorizationStatus) -> OpenClawPermissionState {
        switch status {
        case .authorized: return .authorized
        case .provisional: return .limited
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        #if os(iOS) || os(visionOS)
        case .ephemeral: return .limited
        #endif
        @unknown default: return .denied
        }
    }
    #endif
}

/// Defers local-network access (Bonjour discovery) until the app may trigger the system prompt.
///
/// Port of upstream iOS's `deferDiscoveryUntilLocalNetworkRequest` behavior: new users reach
/// onboarding before iOS asks for local-network access, while existing users still get the request
/// when opening gateway setup or otherwise needing LAN discovery.
public struct OpenClawLocalNetworkAccessGate: Sendable, Equatable {
    /// Whether local-network access was requested (discovery may run).
    public private(set) var isAccessRequested: Bool
    /// Reason of the first request, for diagnostics.
    public private(set) var requestReason: String?

    /// Creates a gate.
    /// - Parameter deferUntilRequested: When true, discovery waits for ``requestAccess(reason:)``.
    public init(deferUntilRequested: Bool) {
        self.isAccessRequested = !deferUntilRequested
        self.requestReason = nil
    }

    /// Marks local-network access as requested (gateway setup, deep link, settings preflight).
    /// - Parameter reason: Diagnostic reason.
    public mutating func requestAccess(reason: String) {
        if !self.isAccessRequested || self.requestReason == nil {
            self.requestReason = reason
        }
        self.isAccessRequested = true
    }

    /// Requests access only when onboarding no longer blocks it (upstream `maybeRequestLocalNetworkAccess`).
    /// - Parameters:
    ///   - reason: Diagnostic reason.
    ///   - onboardingEvaluated: Whether the host decided whether to show onboarding.
    ///   - sceneIsActive: Whether the app is in the foreground.
    ///   - onboardingVisible: Whether onboarding is on screen.
    /// - Returns: Whether access is now requested.
    @discardableResult
    public mutating func maybeRequestAccess(
        reason: String,
        onboardingEvaluated: Bool,
        sceneIsActive: Bool,
        onboardingVisible: Bool) -> Bool
    {
        guard onboardingEvaluated, sceneIsActive, !onboardingVisible else {
            return self.isAccessRequested
        }
        self.requestAccess(reason: reason)
        return true
    }

    /// Whether discovery should run now.
    /// - Parameters:
    ///   - discoveryEnabled: Whether the host enabled discovery at all.
    ///   - sceneIsBackground: Whether the app is in the background.
    /// - Returns: Whether to start (or keep running) discovery.
    public func shouldRunDiscovery(discoveryEnabled: Bool, sceneIsBackground: Bool) -> Bool {
        discoveryEnabled && self.isAccessRequested && !sceneIsBackground
    }
}
