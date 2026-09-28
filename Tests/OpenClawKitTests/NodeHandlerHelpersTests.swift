import Foundation
import Testing
@testable import OpenClawKit

private struct EchoComputerHandler: OpenClawComputerActHandler {
    func perform(_ params: OpenClawComputerActParams) async throws -> OpenClawComputerActResult {
        if params.action == .killApp {
            throw OpenClawNodeError(code: .invalidRequest, message: "INVALID_REQUEST: refusing to kill apps")
        }
        return OpenClawComputerActResult(ok: true, effect: .confirmed, details: ["action": AnyCodable(params.action.rawValue)])
    }
}

struct NodeHandlerHelpersTests {
    @Test func `computer act handler decodes strictly and encodes results`() async throws {
        let handler = EchoComputerHandler()
        #expect(await handler.handle(BridgeInvokeRequest(id: "1", command: "camera.snap")) == nil)

        let ok = try #require(await handler.handle(BridgeInvokeRequest(
            id: "2",
            command: "computer.act",
            paramsJSON: #"{"action":"left_click","x":1,"y":2}"#)))
        #expect(ok.ok)
        let result = try JSONDecoder().decode(OpenClawComputerActResult.self, from: Data(try #require(ok.payloadJSON).utf8))
        #expect(result.effect == .confirmed)
        #expect(result.details?["action"]?.stringValue == "left_click")

        let rejected = try #require(await handler.handle(BridgeInvokeRequest(
            id: "3",
            command: "computer.act",
            paramsJSON: #"{"action":"browser_click"}"#)))
        #expect(!rejected.ok)
        #expect(rejected.error == EchoComputerHandler.invalidParamsError)

        let failed = try #require(await handler.handle(BridgeInvokeRequest(
            id: "4",
            command: "computer.act",
            paramsJSON: #"{"action":"kill_app","app":"Finder"}"#)))
        #expect(failed.error?.message == "INVALID_REQUEST: refusing to kill apps")
    }

    @Test func `snapshot encoder keeps small images and recompresses oversized ones`() throws {
        let jpeg = try makeNoiseJPEGFixture(width: 400, height: 300, quality: 1.0)
        let json = try ScreenSnapshotPayloadEncoder.payloadJSON(
            imageData: jpeg,
            format: .jpeg,
            width: 400,
            height: 300,
            screenIndex: 0,
            capturedAtMs: 1_800_000_000_000,
            requestId: "r",
            nodeId: "n")
        let payload = try JSONDecoder().decode(OpenClawScreenSnapshotPayload.self, from: Data(json.utf8))
        #expect(payload.capturedAtMs == 1_800_000_000_000)
        #expect(Data(base64Encoded: payload.base64) == jpeg)

        // A tight budget forces one recompression that still fits.
        let budget = jpeg.count + 400
        let recompressed = try ScreenSnapshotPayloadEncoder.payloadJSON(
            imageData: jpeg,
            format: .jpeg,
            width: 400,
            height: 300,
            capturedAtMs: 1,
            requestId: "r",
            nodeId: "n",
            maxPayloadBytes: budget)
        #expect(OpenClawNodeInvokePayloadBudget.fits(payloadJSON: recompressed, requestId: "r", nodeId: "n", maxPayloadBytes: budget))

        #expect(throws: OpenClawNodeError.screenSnapshotPayloadTooLarge) {
            _ = try ScreenSnapshotPayloadEncoder.payloadJSON(
                imageData: jpeg,
                format: .jpeg,
                width: 400,
                height: 300,
                capturedAtMs: 1,
                requestId: "r",
                nodeId: "n",
                maxPayloadBytes: 1000)
        }
        #expect(throws: OpenClawNodeError.screenSnapshotFailed) {
            _ = try ScreenSnapshotPayloadEncoder.payloadJSON(
                imageData: jpeg,
                format: .png,
                width: 400,
                height: 300,
                capturedAtMs: 1,
                requestId: "r",
                nodeId: "n")
        }
    }
}
