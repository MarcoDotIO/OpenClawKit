import Foundation
#if canImport(Contacts)
import Contacts
#endif
#if canImport(EventKit)
import EventKit
#endif
#if canImport(Photos)
import Photos
#endif
#if canImport(Speech)
import Speech
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(CoreLocation)
import CoreLocation
#endif
#if canImport(HealthKit)
import HealthKit
#endif

/// Authorization status for a personal-data connector adapter.
public enum ConnectorAuthorizationStatus: Sendable, Equatable {
    case authorized
    case denied
    case notDetermined
    case unavailable
}

/// Adapter interface for connector authorization mediation.
public protocol PersonalDataConnectorAdapter: Sendable {
    var connector: SkillConnectorType { get }
    func authorizationStatus() -> ConnectorAuthorizationStatus
    func requestAccess() async -> Bool
}

/// EventKit calendar connector adapter.
public struct EventKitConnectorAdapter: PersonalDataConnectorAdapter {
    public var connector: SkillConnectorType { .eventKit }

    public init() {}

    public func authorizationStatus() -> ConnectorAuthorizationStatus {
        #if canImport(EventKit)
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .fullAccess, .writeOnly, .authorized:
            return .authorized
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .denied
        }
        #else
        return .unavailable
        #endif
    }

    public func requestAccess() async -> Bool {
        #if canImport(EventKit)
        let eventStore = EKEventStore()
        return await withCheckedContinuation { continuation in
            if #available(iOS 17.0, macOS 14.0, watchOS 10.0, tvOS 17.0, *) {
                eventStore.requestFullAccessToEvents { granted, _ in
                    continuation.resume(returning: granted)
                }
            } else {
                eventStore.requestAccess(to: .event) { granted, _ in
                    continuation.resume(returning: granted)
                }
            }
        }
        #else
        return false
        #endif
    }
}

/// EventKit reminders connector adapter.
public struct RemindersConnectorAdapter: PersonalDataConnectorAdapter {
    public var connector: SkillConnectorType { .reminders }

    public init() {}

    public func authorizationStatus() -> ConnectorAuthorizationStatus {
        #if canImport(EventKit)
        let status = EKEventStore.authorizationStatus(for: .reminder)
        switch status {
        case .fullAccess, .writeOnly, .authorized:
            return .authorized
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .denied
        }
        #else
        return .unavailable
        #endif
    }

    public func requestAccess() async -> Bool {
        #if canImport(EventKit)
        let eventStore = EKEventStore()
        return await withCheckedContinuation { continuation in
            if #available(iOS 17.0, macOS 14.0, watchOS 10.0, tvOS 17.0, *) {
                eventStore.requestFullAccessToReminders { granted, _ in
                    continuation.resume(returning: granted)
                }
            } else {
                eventStore.requestAccess(to: .reminder) { granted, _ in
                    continuation.resume(returning: granted)
                }
            }
        }
        #else
        return false
        #endif
    }
}

/// Contacts connector adapter.
public struct ContactsConnectorAdapter: PersonalDataConnectorAdapter {
    public var connector: SkillConnectorType { .contacts }

    public init() {}

    public func authorizationStatus() -> ConnectorAuthorizationStatus {
        #if canImport(Contacts)
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized:
            return .authorized
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .denied
        }
        #else
        return .unavailable
        #endif
    }

    public func requestAccess() async -> Bool {
        #if canImport(Contacts)
        let store = CNContactStore()
        return await withCheckedContinuation { continuation in
            store.requestAccess(for: .contacts) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
        #else
        return false
        #endif
    }
}

/// Photos connector adapter.
public struct PhotosConnectorAdapter: PersonalDataConnectorAdapter {
    public var connector: SkillConnectorType { .photos }

    public init() {}

    public func authorizationStatus() -> ConnectorAuthorizationStatus {
        #if canImport(Photos)
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized, .limited:
            return .authorized
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .denied
        }
        #else
        return .unavailable
        #endif
    }

    public func requestAccess() async -> Bool {
        #if canImport(Photos)
        let status = await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { value in
                continuation.resume(returning: value)
            }
        }
        return status == .authorized || status == .limited
        #else
        return false
        #endif
    }
}

/// Speech recognition connector adapter.
public struct SpeechConnectorAdapter: PersonalDataConnectorAdapter {
    public var connector: SkillConnectorType { .speech }

    public init() {}

    public func authorizationStatus() -> ConnectorAuthorizationStatus {
        #if canImport(Speech)
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return .authorized
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .denied
        }
        #else
        return .unavailable
        #endif
    }

    public func requestAccess() async -> Bool {
        #if canImport(Speech)
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { value in
                continuation.resume(returning: value)
            }
        }
        return status == .authorized
        #else
        return false
        #endif
    }
}

/// Camera connector adapter.
public struct CameraConnectorAdapter: PersonalDataConnectorAdapter {
    public var connector: SkillConnectorType { .camera }

    public init() {}

    public func authorizationStatus() -> ConnectorAuthorizationStatus {
        #if canImport(AVFoundation)
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return .authorized
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .denied
        }
        #else
        return .unavailable
        #endif
    }

    public func requestAccess() async -> Bool {
        #if canImport(AVFoundation)
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .video) { granted in
                continuation.resume(returning: granted)
            }
        }
        #else
        return false
        #endif
    }
}

/// Microphone connector adapter.
public struct MicrophoneConnectorAdapter: PersonalDataConnectorAdapter {
    public var connector: SkillConnectorType { .microphone }

    public init() {}

    public func authorizationStatus() -> ConnectorAuthorizationStatus {
        #if canImport(AVFoundation)
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .authorized
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .denied
        }
        #else
        return .unavailable
        #endif
    }

    public func requestAccess() async -> Bool {
        #if canImport(AVFoundation)
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
        #else
        return false
        #endif
    }
}

/// Location connector adapter.
public struct LocationConnectorAdapter: PersonalDataConnectorAdapter {
    public var connector: SkillConnectorType { .location }

    public init() {}

    public func authorizationStatus() -> ConnectorAuthorizationStatus {
        #if canImport(CoreLocation)
        switch CLLocationManager().authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            return .authorized
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .denied
        }
        #else
        return .unavailable
        #endif
    }

    public func requestAccess() async -> Bool {
        false
    }
}

/// HealthKit connector adapter.
public struct HealthKitConnectorAdapter: PersonalDataConnectorAdapter {
    public var connector: SkillConnectorType { .healthKit }

    public init() {}

    public func authorizationStatus() -> ConnectorAuthorizationStatus {
        #if canImport(HealthKit)
        return HKHealthStore.isHealthDataAvailable() ? .notDetermined : .unavailable
        #else
        return .unavailable
        #endif
    }

    public func requestAccess() async -> Bool {
        false
    }
}

/// HomeKit connector adapter.
public struct HomeKitConnectorAdapter: PersonalDataConnectorAdapter {
    public var connector: SkillConnectorType { .homeKit }

    public init() {}

    public func authorizationStatus() -> ConnectorAuthorizationStatus {
        .notDetermined
    }

    public func requestAccess() async -> Bool {
        false
    }
}

/// Local storage connector adapters that require no OS-level prompt.
public struct LocalStorageConnectorAdapter: PersonalDataConnectorAdapter {
    public let connector: SkillConnectorType

    public init(connector: SkillConnectorType) {
        self.connector = connector
    }

    public func authorizationStatus() -> ConnectorAuthorizationStatus { .authorized }
    public func requestAccess() async -> Bool { true }
}

/// Convenience registry for Apple's personal-data connector adapters.
public enum AppleConnectorAdapters {
    public static func defaults() -> [any PersonalDataConnectorAdapter] {
        [
            EventKitConnectorAdapter(),
            RemindersConnectorAdapter(),
            ContactsConnectorAdapter(),
            PhotosConnectorAdapter(),
            SpeechConnectorAdapter(),
            CameraConnectorAdapter(),
            MicrophoneConnectorAdapter(),
            LocationConnectorAdapter(),
            HealthKitConnectorAdapter(),
            HomeKitConnectorAdapter(),
            LocalStorageConnectorAdapter(connector: .fileBookmarks),
            LocalStorageConnectorAdapter(connector: .clipboard),
            LocalStorageConnectorAdapter(connector: .keychain),
            LocalStorageConnectorAdapter(connector: .userDefaults),
            LocalStorageConnectorAdapter(connector: .appIntents)
        ]
    }
}
