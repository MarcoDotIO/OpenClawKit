import Foundation

/// Size budget for node invoke results.
///
/// A result travels as the `payloadJSON` string of a `node.invoke.result` request frame. When that
/// frame exceeds the gateway's `policy.maxPayload` (25 MiB by default) the gateway closes the socket,
/// so node handlers must project the frame size *before* sending and return a stable error instead.
public enum OpenClawNodeInvokePayloadBudget {
    /// Default gateway `policy.maxPayload` in bytes (25 MiB).
    public static let defaultMaxPayloadBytes = 25 * 1024 * 1024

    /// Largest raw byte count whose base64 encoding fits in `maxPayloadBytes`
    /// (`(maxPayloadBytes / 4) * 3`); a cheap pre-check before encoding.
    public static func maxRawBytesBeforeBase64(maxPayloadBytes: Int = Self.defaultMaxPayloadBytes) -> Int {
        (max(0, maxPayloadBytes) / 4) * 3
    }

    /// Base64 length of `byteCount` raw bytes (`ceil(n / 3) * 4`).
    public static func base64Length(ofByteCount byteCount: Int) -> Int {
        ((max(0, byteCount) + 2) / 3) * 4
    }

    /// Encoded size of the `node.invoke.result` frame that would carry `payloadJSON`, including the
    /// JSON escaping of the payload string and the request envelope.
    public static func projectedResultFrameBytes(
        payloadJSON: String,
        requestId: String,
        nodeId: String?) throws -> Int
    {
        struct InvokeResultFrame: Encodable {
            let type = "req"
            let id = "00000000-0000-0000-0000-000000000000"
            let method = "node.invoke.result"
            let params: Params

            struct Params: Encodable {
                let id: String
                let nodeId: String
                let ok: Bool
                let payloadJSON: String
            }
        }

        let frame = InvokeResultFrame(params: InvokeResultFrame.Params(
            id: requestId,
            nodeId: nodeId ?? "",
            ok: true,
            payloadJSON: payloadJSON))
        return try JSONEncoder().encode(frame).count
    }

    /// Whether a result with `payloadJSON` fits within `maxPayloadBytes` once framed.
    public static func fits(
        payloadJSON: String,
        requestId: String,
        nodeId: String?,
        maxPayloadBytes: Int = Self.defaultMaxPayloadBytes) -> Bool
    {
        guard let projected = try? self.projectedResultFrameBytes(
            payloadJSON: payloadJSON,
            requestId: requestId,
            nodeId: nodeId)
        else { return false }
        return projected <= maxPayloadBytes
    }
}
