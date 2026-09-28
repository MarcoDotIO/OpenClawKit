import Foundation

/// Host-implemented desktop control for `computer.act`.
///
/// The SDK ships only the contract; macOS apps implement this with Accessibility, CGEvent and
/// ScreenCaptureKit (see ``OpenClawComputerInputGeometry`` for coordinate mapping) and route
/// `computer.act` invokes to ``handle(_:)``. Declare capability `computer` and the command only while
/// the host's "Allow Computer Control" setting is on; pairing approval of that surface is the grant.
public protocol OpenClawComputerActHandler: Sendable {
    /// Performs one action. Throw ``OpenClawNodeError`` for stable, agent-visible failures.
    func perform(_ params: OpenClawComputerActParams) async throws -> OpenClawComputerActResult
}

extension OpenClawComputerActHandler {
    /// Stable error for params that fail strict decoding (including agent-side-only actions).
    public static var invalidParamsError: OpenClawNodeError {
        OpenClawNodeError(code: .invalidRequest, message: "INVALID_REQUEST: invalid computer.act params")
    }

    /// Decodes `computer.act` params strictly, performs the action and encodes the result; returns
    /// `nil` for other commands.
    public func handle(_ request: BridgeInvokeRequest) async -> BridgeInvokeResponse? {
        guard request.command == OpenClawComputerCommand.act.rawValue else { return nil }
        guard let json = request.paramsJSON,
              let params = try? JSONDecoder().decode(OpenClawComputerActParams.self, from: Data(json.utf8))
        else {
            return BridgeInvokeResponse(id: request.id, ok: false, error: Self.invalidParamsError)
        }
        do {
            let result = try await self.perform(params)
            let payload = try JSONEncoder().encode(result)
            return BridgeInvokeResponse(id: request.id, ok: true, payloadJSON: String(decoding: payload, as: UTF8.self))
        } catch let error as OpenClawNodeError {
            return BridgeInvokeResponse(id: request.id, ok: false, error: error)
        } catch is CancellationError {
            return BridgeInvokeResponse(
                id: request.id,
                ok: false,
                error: OpenClawNodeError(code: .unavailable, message: "UNAVAILABLE: computer.act cancelled"))
        } catch {
            return BridgeInvokeResponse(
                id: request.id,
                ok: false,
                error: OpenClawNodeError(code: .unavailable, message: "UNAVAILABLE: \(error.localizedDescription)"))
        }
    }
}
