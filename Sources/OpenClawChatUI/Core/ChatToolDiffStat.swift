import Foundation

/// Added/removed line counts reported for an edit tool call or subagent task.
///
/// Upstream declares this in `ChatToolDiff.swift`; it lives in the chat core so live tool-call
/// state can carry it without the diff renderer.
package struct ChatToolDiffStat: Equatable, Hashable, Sendable {
    /// Files touched, when known.
    package let files: Int?
    /// Added lines.
    package let added: Int
    /// Removed lines.
    package let removed: Int

    /// Creates diff statistics.
    package init(files: Int? = nil, added: Int, removed: Int) {
        self.files = files
        self.added = added
        self.removed = removed
    }
}
