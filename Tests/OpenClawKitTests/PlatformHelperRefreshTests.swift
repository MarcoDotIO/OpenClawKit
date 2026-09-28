import CoreLocation
import Foundation
import Testing
@testable import OpenClawKit

@MainActor
private final class FakeConcurrentLocationService: NSObject, ConcurrentLocationServiceCommon, @unchecked Sendable {
    let locationManager = CLLocationManager()
    var locationRequestContinuation: CheckedContinuation<CLLocation, Error>?
    var locationRequestContinuations: [UUID: CheckedContinuation<CLLocation, Error>] = [:]
}

struct PlatformHelperRefreshTests {
    @Test @MainActor
    func `completing location requests resumes every waiter exactly once`() async throws {
        let service = FakeConcurrentLocationService()
        let fix = CLLocation(latitude: 1, longitude: 2)
        let first = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CLLocation, Error>) in
            service.locationRequestContinuations[UUID()] = cont
            service.completeLocationRequests(with: .success(fix))
        }
        #expect(first === fix)
        #expect(service.locationRequestContinuations.isEmpty)
        #expect(service.locationRequestContinuation == nil)

        // A late second result finds nothing left to resume.
        service.completeLocationRequests(with: .failure(CancellationError()))

        let legacy = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CLLocation, Error>) in
            service.locationRequestContinuation = cont
            service.completeLocationRequests(with: .success(fix))
        }
        #expect(legacy === fix)
    }

    @Test func `camera selection distinguishes missing and unknown devices`() throws {
        struct Unavailable: Error {}
        struct NotFound: Error, Equatable { let id: String }

        let named = try CameraCapturePipelineSupport.selectCamera(
            deviceId: "cam-2",
            matching: { $0 == "cam-2" ? "device-2" : nil },
            fallback: { "default" },
            unavailableError: Unavailable(),
            deviceNotFoundError: { NotFound(id: $0) })
        #expect(named == "device-2")

        let fallback = try CameraCapturePipelineSupport.selectCamera(
            deviceId: "",
            matching: { _ in nil as String? },
            fallback: { "default" },
            unavailableError: Unavailable(),
            deviceNotFoundError: { NotFound(id: $0) })
        #expect(fallback == "default")

        #expect(throws: NotFound(id: "missing")) {
            _ = try CameraCapturePipelineSupport.selectCamera(
                deviceId: "missing",
                matching: { _ in nil as String? },
                fallback: { "default" },
                unavailableError: Unavailable(),
                deviceNotFoundError: { NotFound(id: $0) })
        }
        #expect(throws: Unavailable.self) {
            _ = try CameraCapturePipelineSupport.selectCamera(
                deviceId: nil,
                matching: { _ in nil as String? },
                fallback: { nil as String? },
                unavailableError: Unavailable(),
                deviceNotFoundError: { NotFound(id: $0) })
        }
    }

    @Test func `interface enumeration skips addressless interfaces without crashing`() {
        let addresses = NetworkInterfaceIPv4.addresses()
        #expect(addresses.allSatisfy { !$0.ip.hasPrefix("127.") })
    }

    @Test func `discovery text prettifies names and reads optional TXT fields`() {
        #expect(GatewayDiscoveryText.prettifyInstanceName("Peter's   Mac (OpenClaw) (2)") == "Peter's Mac")
        #expect(GatewayDiscoveryText.txtValue(["a": "  x "], key: "a") == "x")
        #expect(GatewayDiscoveryText.txtValue(["a": "  "], key: "a") == nil)
        #expect(GatewayDiscoveryText.txtBoolValue(["tls": "YES"], key: "tls"))
        #expect(!GatewayDiscoveryText.txtBoolValue([:], key: "tls"))
        #expect(GatewayDiscoveryText.displayName(instanceName: "Studio\\032Mac", txt: [:]) == "Studio Mac")
        #expect(GatewayDiscoveryText.displayName(instanceName: "Studio", txt: ["displayName": "Full Name"]) == "Full Name")
    }

    @Test func `truncated multibyte instance names still match their gateway`() {
        let fullName = String(repeating: "é", count: 40) // 80 UTF-8 bytes
        let truncated = GatewayDiscoveryText.truncatedToDNSLabel(fullName)
        #expect(truncated.utf8.count <= 63)
        #expect(truncated.count == 31)
        #expect(fullName.hasPrefix(truncated))

        let escaped = truncated.utf8.map { String(format: "\\%03d", $0) }.joined()
        #expect(BonjourEscapes.decode(escaped) == truncated)
        #expect(GatewayDiscoveryText.instanceName(escaped, matches: fullName))
        #expect(!GatewayDiscoveryText.instanceName("Other", matches: fullName))
    }

    @Test func `escaped UTF-8 byte sequences decode as text`() {
        #expect(BonjourEscapes.decode("Caf\\195\\169") == "Café")
        #expect(BonjourEscapes.decode("Mac\\032\\240\\159\\166\\158") == "Mac 🦞")
        // Invalid UTF-8 keeps the legacy per-scalar decoding.
        #expect(BonjourEscapes.decode("x\\233y") == "xéy")
    }

    @Test func `discovery status offers a no-gateways hint`() {
        #expect(GatewayDiscoveryStatusText.idle == "Idle")
        #expect(GatewayDiscoveryStatusText.noGatewaysFoundHint.contains("openclaw plugins enable bonjour"))
    }
}
