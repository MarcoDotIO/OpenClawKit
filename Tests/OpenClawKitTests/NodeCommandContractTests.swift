import Foundation
import Testing
@testable import OpenClawKit

struct NodeCommandContractTests {
    @Test func `new command wire names match the gateway policy`() {
        #expect(OpenClawComputerCommand.act.rawValue == "computer.act")
        #expect(OpenClawCameraCommand.ptzStatus.rawValue == "camera.ptz.status")
        #expect(OpenClawCameraCommand.ptzControl.rawValue == "camera.ptz.control")
        #expect(OpenClawScreenCommand.snapshot.rawValue == "screen.snapshot")
        #expect(OpenClawFileSystemCommand.listDir.rawValue == "fs.listDir")
        #expect(OpenClawNodeCommandName.systemRunPrepare == "system.run.prepare")
        #expect(OpenClawNodeCommandName.mcpToolsCall == "mcp.tools.call.v1")
        #expect(OpenClawCapability.computer.rawValue == "computer")
        #expect(OpenClawCapability.talk.rawValue == "talk")
        #expect(OpenClawCapability.health.rawValue == "health")
        #expect(OpenClawNodeErrorCode.notReady.rawValue == "NODE_NOT_READY")
        #expect(OpenClawNodeErrorCode.systemRunDenied.rawValue == "SYSTEM_RUN_DENIED")
    }

    @Test func `camera PTZ control round-trips its wire shape`() throws {
        let json = #"{"deviceId":"cam-1","operation":"move","delta":{"panDegrees":5,"zoomPercent":-10}}"#
        let params = try JSONDecoder().decode(OpenClawCameraPTZControlParams.self, from: Data(json.utf8))
        #expect(params.deviceId == "cam-1")
        #expect(params.operation == .move)
        #expect(params.delta?.panDegrees == 5)
        #expect(params.delta?.tiltDegrees == nil)
        #expect(params.delta?.zoomPercent == -10)
        #expect(params.target == nil)
        let reencoded = try JSONDecoder().decode(
            OpenClawCameraPTZControlParams.self,
            from: JSONEncoder().encode(params))
        #expect(reencoded == params)
    }

    @Test func `screen snapshot params decode strictly before capture`() throws {
        #expect(try OpenClawScreenSnapshotParams.decodeInvokeParams(nil) == OpenClawScreenSnapshotParams())
        #expect(try OpenClawScreenSnapshotParams.decodeInvokeParams("  ") == OpenClawScreenSnapshotParams())
        let decoded = try OpenClawScreenSnapshotParams.decodeInvokeParams(
            #"{"screenIndex":1,"maxWidth":1280,"quality":0.5,"format":"png"}"#)
        #expect(decoded == OpenClawScreenSnapshotParams(screenIndex: 1, maxWidth: 1280, quality: 0.5, format: .png))

        for malformed in [#"{"format":"gif"}"#, #"{"maxWidth":"wide"}"#, "not json", #"{"screenIndex":-1}"#] {
            #expect(throws: OpenClawScreenSnapshotParams.invalidParamsError) {
                _ = try OpenClawScreenSnapshotParams.decodeInvokeParams(malformed)
            }
        }
    }

    @Test func `screen snapshot params normalize like the macOS node`() {
        let defaults = OpenClawScreenSnapshotParams().normalized
        #expect(defaults.format == .jpeg)
        #expect(defaults.maxWidth == 1600)
        #expect(defaults.quality == 0.72)

        let png = OpenClawScreenSnapshotParams(maxWidth: 0, quality: 7, format: .png).normalized
        #expect(png.maxWidth == 900)
        #expect(png.quality == 1)
        #expect(OpenClawScreenSnapshotParams(quality: -1).normalized.quality == 0.05)
    }

    @Test func `snapshot format sniffing validates image headers`() {
        #expect(OpenClawScreenSnapshotFormat(sniffing: Data([0xFF, 0xD8, 0xFF, 0xE0])) == .jpeg)
        #expect(OpenClawScreenSnapshotFormat(sniffing: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0])) == .png)
        #expect(OpenClawScreenSnapshotFormat(sniffing: Data("GIF89a".utf8)) == nil)
        #expect(OpenClawScreenSnapshotFormat(sniffing: Data()) == nil)
    }

    @Test func `invoke result budget projects the framed size`() throws {
        #expect(OpenClawNodeInvokePayloadBudget.maxRawBytesBeforeBase64() == (25 * 1024 * 1024 / 4) * 3)
        #expect(OpenClawNodeInvokePayloadBudget.base64Length(ofByteCount: 0) == 0)
        #expect(OpenClawNodeInvokePayloadBudget.base64Length(ofByteCount: 1) == 4)
        #expect(OpenClawNodeInvokePayloadBudget.base64Length(ofByteCount: 3) == 4)
        #expect(OpenClawNodeInvokePayloadBudget.base64Length(ofByteCount: 4) == 8)

        let payload = #"{"format":"jpeg","base64":"AAAA"}"#
        let projected = try OpenClawNodeInvokePayloadBudget.projectedResultFrameBytes(
            payloadJSON: payload,
            requestId: "req-1",
            nodeId: "node-1")
        // Escaped quotes make the framed payload larger than the raw JSON.
        #expect(projected > payload.utf8.count + 60)
        #expect(OpenClawNodeInvokePayloadBudget.fits(payloadJSON: payload, requestId: "req-1", nodeId: nil))
        #expect(!OpenClawNodeInvokePayloadBudget.fits(
            payloadJSON: payload,
            requestId: "req-1",
            nodeId: nil,
            maxPayloadBytes: 64))
    }

    @Test func `system run params carry runId and approval metadata`() throws {
        let json = #"""
        {"command":["ls","-la"],"approved":true,"approvalDecision":"allow-once","runId":"run-9",
         "approvalSource":"operator","suppressNotifyOnExit":true,"systemRunPlan":{"argv":["ls"]}}
        """#
        let params = try JSONDecoder().decode(OpenClawSystemRunParams.self, from: Data(json.utf8))
        #expect(params.runId == "run-9")
        #expect(params.approved == true)
        #expect(params.approvalDecision == "allow-once")
        #expect(params.approvalSource == "operator")
        #expect(params.suppressNotifyOnExit == true)
        #expect(params.systemRunPlan?.dictionaryValue?["argv"]?.arrayValue?.first?.stringValue == "ls")

        #expect(params.effectiveTimeoutMs(defaultTimeoutSec: 30) == 30_000)
        #expect(OpenClawSystemRunParams(command: ["x"], timeoutMs: 500).effectiveTimeoutMs(defaultTimeoutSec: 30) == 500)
        #expect(OpenClawSystemRunParams(command: ["x"]).effectiveTimeoutMs(defaultTimeoutSec: nil) == nil)
    }

    @Test func `permission required errors never prompt and use stable prefixes`() {
        let error = OpenClawNodeError.permissionRequired(.calendar, hint: "enable Calendar access")
        #expect(error.code == .unavailable)
        #expect(error.message == "CALENDAR_PERMISSION_REQUIRED: enable Calendar access")
        #expect(OpenClawNodeError.permissionRequired(.photos).message.hasPrefix("PHOTOS_PERMISSION_REQUIRED: "))
        let notReady = OpenClawNodeError.notReady(retryAfterMs: 250)
        #expect(notReady.code == .notReady)
        #expect(notReady.retryable == true)
        #expect(notReady.retryAfterMs == 250)
    }

    @Test func `battery percent helper rounds and rejects unavailable levels`() {
        #expect(OpenClawBatteryStatusPayload.percent(fromLevel: 0.125) == 13)
        #expect(OpenClawBatteryStatusPayload.percent(fromLevel: 1) == 100)
        #expect(OpenClawBatteryStatusPayload.percent(fromLevel: -1) == nil)
        #expect(OpenClawBatteryStatusPayload.percent(fromLevel: nil) == nil)
        #expect(OpenClawBatteryStatusPayload.percent(fromLevel: .nan) == nil)
    }
}
