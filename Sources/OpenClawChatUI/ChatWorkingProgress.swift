import Foundation
import OpenClawKit

// Ported subset of upstream OpenClaw 2026.9.6 `ChatWorkingProgress.swift`: the working-indicator identity
// used by the view model. The working progress/recap presentation types belong with the transcript views.

/// Stable identity for the "working" indicator so it survives run-id adoption without flicker.
enum ChatWorkingIdentity {
    static func resolve(
        sessionKey: String,
        pendingRunIDs: Set<String>,
        localUserMessageIDsByRunID: [String: UUID],
        fallbackGeneration: UInt64) -> String
    {
        if let messageID = pendingRunIDs.compactMap({ localUserMessageIDsByRunID[$0]?.uuidString }).min() {
            return "\(sessionKey):user:\(messageID)"
        }
        if let runID = pendingRunIDs.min() {
            return "\(sessionKey):run:\(runID)"
        }
        return "\(sessionKey):generation:\(fallbackGeneration)"
    }
}
