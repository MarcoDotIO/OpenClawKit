import Foundation

/// Encodes `screen.snapshot` results within the `node.invoke.result` frame budget.
///
/// The encoder projects the framed size before sending (see ``OpenClawNodeInvokePayloadBudget``). When
/// the image would not fit, it recompresses once to a smaller JPEG through ``JPEGTranscoder``; if that
/// still does not fit it throws ``OpenClawNodeError/screenSnapshotPayloadTooLarge`` instead of sending
/// a frame that would make the gateway close the socket.
public enum ScreenSnapshotPayloadEncoder {
    /// Returns `payloadJSON` for a snapshot.
    ///
    /// - Parameters:
    ///   - imageData: Encoded image bytes (must match `format`).
    ///   - format: Image format.
    ///   - width: Image width in pixels.
    ///   - height: Image height in pixels.
    ///   - displayFrameId: Display frame identity for later `computer.act` coordinates.
    ///   - screenIndex: Captured display index.
    ///   - capturedAtMs: Capture time in milliseconds since the Unix epoch.
    ///   - requestId: Invoke identifier (part of the framed size).
    ///   - nodeId: Node identifier (part of the framed size).
    ///   - maxPayloadBytes: Gateway `policy.maxPayload` (25 MiB by default).
    public static func payloadJSON(
        imageData: Data,
        format: OpenClawScreenSnapshotFormat,
        width: Int,
        height: Int,
        displayFrameId: String? = nil,
        screenIndex: Int? = nil,
        capturedAtMs: Int64,
        requestId: String,
        nodeId: String?,
        maxPayloadBytes: Int = OpenClawNodeInvokePayloadBudget.defaultMaxPayloadBytes) throws -> String
    {
        guard OpenClawScreenSnapshotFormat(sniffing: imageData) == format else {
            throw OpenClawNodeError.screenSnapshotFailed
        }
        func encode(_ data: Data, _ format: OpenClawScreenSnapshotFormat, _ width: Int, _ height: Int) throws -> String? {
            guard data.count <= OpenClawNodeInvokePayloadBudget.maxRawBytesBeforeBase64(maxPayloadBytes: maxPayloadBytes)
            else { return nil }
            let payload = OpenClawScreenSnapshotPayload(
                format: format.rawValue,
                base64: data.base64EncodedString(),
                displayFrameId: displayFrameId,
                width: width,
                height: height,
                screenIndex: screenIndex,
                capturedAtMs: capturedAtMs)
            let json = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
            return OpenClawNodeInvokePayloadBudget.fits(
                payloadJSON: json,
                requestId: requestId,
                nodeId: nodeId,
                maxPayloadBytes: maxPayloadBytes) ? json : nil
        }

        if let json = try encode(imageData, format, width, height) {
            return json
        }
        // One recompression attempt: a JPEG with a byte budget that leaves room for base64 and the envelope.
        let budget = OpenClawNodeInvokePayloadBudget.maxRawBytesBeforeBase64(maxPayloadBytes: maxPayloadBytes) - 4096
        guard budget > 0,
              let smaller = try? JPEGTranscoder.transcodeToJPEG(
                  imageData: imageData,
                  maxLongEdgePx: max(width, height),
                  quality: 0.6,
                  maxBytes: budget),
              let json = try encode(smaller.data, .jpeg, smaller.widthPx, smaller.heightPx)
        else {
            throw OpenClawNodeError.screenSnapshotPayloadTooLarge
        }
        return json
    }
}
