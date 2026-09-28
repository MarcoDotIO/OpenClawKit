import Foundation
import OpenClawProtocol

/// Minimal request seam for typed gateway RPC helpers.
///
/// `GatewayChannelActor` conforms (see `GatewayRequestSending+Conformances.swift`); tests and hosts can
/// provide their own conformers (for example a loopback server or a recording fake).
public protocol GatewayRequestSending: Sendable {
    /// Sends one request frame and returns the JSON-encoded response payload.
    func request(method: String, params: [String: AnyCodable]?, timeoutMs: Double?) async throws -> Data
}

/// Node-session request seam used by node-side helpers such as ``NodePresenceAliveBeacon``.
///
/// `GatewayNodeSession` conforms (see `GatewayRequestSending+Conformances.swift`).
public protocol GatewayNodeRequestSending: Sendable {
    /// Sends one request over the authenticated node session and returns the JSON payload.
    func sendNodeRequest(method: String, paramsJSON: String?, timeoutSeconds: Int) async throws -> Data
}

/// Fire-and-forget node event seam (`node.event`) used by ``GatewayPushRegistrar``.
///
/// `GatewayNodeSession` conforms (see `GatewayRequestSending+Conformances.swift`).
public protocol GatewayNodeEventSending: Sendable {
    /// Sends one node event; delivery failures are logged by the session, not thrown.
    func sendNodeEvent(event: String, payloadJSON: String?) async
}

/// Errors raised by the typed RPC helpers before or after the gateway round trip.
public enum GatewayRPCClientError: Error, Equatable, LocalizedError, Sendable {
    /// Params could not be encoded as a JSON object.
    case invalidParams(method: String, reason: String)
    /// The response payload could not be decoded into the expected type.
    case invalidResponse(method: String, reason: String)
    /// The method is not listed in the gateway's advertised `features.methods`.
    case methodUnavailable(method: String)

    /// Human-readable description.
    public var errorDescription: String? {
        switch self {
        case let .invalidParams(method, reason):
            "\(method): invalid params (\(reason))"
        case let .invalidResponse(method, reason):
            "\(method): unexpected response (\(reason))"
        case let .methodUnavailable(method):
            "\(method): not available on this gateway"
        }
    }
}

enum GatewayRPCCoding {
    static func encodeParams(_ params: some Encodable, method: String) throws -> [String: AnyCodable] {
        let encoded: AnyCodable
        do {
            encoded = try AnyCodable(encoding: params)
        } catch {
            throw GatewayRPCClientError.invalidParams(method: method, reason: error.localizedDescription)
        }
        guard let object = encoded.dictionaryValue else {
            throw GatewayRPCClientError.invalidParams(method: method, reason: "params must encode as a JSON object")
        }
        return object
    }

    static func decode<Response: Decodable>(_ type: Response.Type, from data: Data, method: String) throws -> Response {
        do {
            return try JSONDecoder().decode(type, from: data.isEmpty ? Data("null".utf8) : data)
        } catch {
            throw GatewayRPCClientError.invalidResponse(method: method, reason: String(describing: error))
        }
    }
}

extension GatewayRequestSending {
    /// Sends typed params and decodes a typed response.
    public func request<Params: Encodable, Response: Decodable>(
        method: String,
        params: Params,
        as responseType: Response.Type = Response.self,
        timeoutMs: Double? = nil) async throws -> Response
    {
        let encoded = try GatewayRPCCoding.encodeParams(params, method: method)
        let data = try await self.request(method: method, params: encoded, timeoutMs: timeoutMs)
        return try GatewayRPCCoding.decode(responseType, from: data, method: method)
    }

    /// Sends a request without params (`{}`) and decodes a typed response.
    public func request<Response: Decodable>(
        method: String,
        as responseType: Response.Type = Response.self,
        timeoutMs: Double? = nil) async throws -> Response
    {
        let data = try await self.request(method: method, params: [:], timeoutMs: timeoutMs)
        return try GatewayRPCCoding.decode(responseType, from: data, method: method)
    }
}
