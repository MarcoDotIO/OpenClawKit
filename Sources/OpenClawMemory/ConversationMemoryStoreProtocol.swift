import Foundation

/// Shared interface for conversation memory persistence backends.
public protocol ConversationMemoryStoreProtocol: Actor {
    /// Loads persisted entries from backing storage.
    func load() throws

    /// Saves current in-memory state to backing storage.
    func save() throws

    /// Appends a user turn to conversation memory.
    func appendUserTurn(
        sessionKey: String,
        channel: String,
        accountID: String?,
        peerID: String,
        text: String
    )

    /// Appends an assistant turn to conversation memory.
    func appendAssistantTurn(
        sessionKey: String,
        channel: String,
        accountID: String?,
        peerID: String,
        text: String
    )

    /// Returns recent entries for a session, oldest to newest.
    func recentEntries(sessionKey: String, limit: Int) -> [ConversationMemoryEntry]

    /// Builds model-facing context from recent memory entries.
    func formattedContext(sessionKey: String, limit: Int) -> String

    /// Returns all memory entries across sessions in chronological order.
    func allEntries() -> [ConversationMemoryEntry]
}
