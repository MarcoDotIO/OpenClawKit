import Foundation
import Testing
import OpenClawKit

@Suite("Permissions snapshot")
struct PermissionsSnapshotTests {
    @Test
    func permissionsMapOmitsUnavailableCapabilities() {
        var snapshot = OpenClawPermissionsSnapshot(contacts: .authorized, calendar: .limited, camera: .denied)
        snapshot[.microphone] = .notDetermined
        #expect(snapshot[.camera] == .denied)
        #expect(snapshot.permissionsMap == [
            "contacts": true,
            "calendar": true,
            "camera": false,
            "microphone": false,
        ])
        #expect(OpenClawPermissionState.limited.isUsable)
        #expect(!OpenClawPermissionState.restricted.isUsable)
    }

    @Test
    func currentReadsOnlyRequestedKindsWithoutPrompting() async {
        let snapshot = await OpenClawPermissionsSnapshot.current([.notifications, .location], location: .limited)
        #expect(snapshot.location == .limited)
        // The test runner is not an app bundle, so notification settings are not read.
        #expect(snapshot.notifications == .unavailable)
        #expect(snapshot.contacts == .unavailable)
        #expect(snapshot.camera == .unavailable)

        let full = await OpenClawPermissionsSnapshot.current([.contacts, .calendar, .reminders, .camera, .microphone])
        for kind: OpenClawPermissionKind in [.contacts, .calendar, .reminders, .camera, .microphone] {
            #expect(OpenClawPermissionState.allCases.contains(full[kind]))
        }
    }

    @Test
    func snapshotIsCodable() throws {
        let snapshot = OpenClawPermissionsSnapshot(photos: .limited, notifications: .authorized)
        let decoded = try JSONDecoder().decode(OpenClawPermissionsSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded == snapshot)
    }

    @Test
    func localNetworkGateDefersDiscoveryUntilRequested() {
        var gate = OpenClawLocalNetworkAccessGate(deferUntilRequested: true)
        #expect(!gate.shouldRunDiscovery(discoveryEnabled: true, sceneIsBackground: false))
        let duringOnboarding = gate.maybeRequestAccess(
            reason: "root_appear", onboardingEvaluated: true, sceneIsActive: true, onboardingVisible: true)
        let beforeEvaluation = gate.maybeRequestAccess(
            reason: "root_appear", onboardingEvaluated: false, sceneIsActive: true, onboardingVisible: false)
        let afterOnboarding = gate.maybeRequestAccess(
            reason: "onboarding_dismissed", onboardingEvaluated: true, sceneIsActive: true, onboardingVisible: false)
        #expect(!duringOnboarding)
        #expect(!beforeEvaluation)
        #expect(afterOnboarding)
        #expect(gate.requestReason == "onboarding_dismissed")
        #expect(gate.shouldRunDiscovery(discoveryEnabled: true, sceneIsBackground: false))
        #expect(!gate.shouldRunDiscovery(discoveryEnabled: true, sceneIsBackground: true))
        #expect(!gate.shouldRunDiscovery(discoveryEnabled: false, sceneIsBackground: false))

        var existing = OpenClawLocalNetworkAccessGate(deferUntilRequested: false)
        #expect(existing.shouldRunDiscovery(discoveryEnabled: true, sceneIsBackground: false))
        existing.requestAccess(reason: "gateway_setup_deeplink")
        #expect(existing.requestReason == "gateway_setup_deeplink")
    }
}
